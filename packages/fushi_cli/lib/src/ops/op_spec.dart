/// 操作声明 [OpSpec] 与统一参数解析 [OpArgs]（架构重构 C1，
/// `docs/specs/2026-11-28-architecture-redesign.md`）。
///
/// 一个操作只声明一次：[OpSpec]（const，纯数据：id、method、pattern、带类型的
/// 参数表、风险级与几个标记）。CLI 命令按对象引用它（`CtlCommandSpec.op`），不写
/// 路径字面量；app / 服务端用 [OpSpec.bind] 把 handler、可用性、撤销挂上去，得到
/// 一条 [FushiOp]，控制通道路由（[FushiOp.route]）与操作目录条目都从它派生——不再
/// 有「路由一份、描述一份、靠 `METHOD pattern` 字符串配对」。
///
/// 参数解析只有一处：[OpArgs.parse]。HTTP 直连（[CtlServer]）与进程内调用
/// （[OpInvoker]：AI 助手、`/api/admin/ops/call`、MCP）都经它把原始调用按参数表
/// 转换、校验成 [OpArgs]，handler 只用 [OpArgs] 的带类型取值，不再自己
/// `optString` / 判空 / 判枚举。
library;

import 'dart:developer' as developer;

import '../ctl_routes.dart';
import 'fushi_op.dart';

/// handler：拿已按参数表校验、转换过的 [OpArgs]。返回值必须可 JSON 编码；
/// null 视为 `{"ok": true}`。
typedef OpHandler = Future<Object?> Function(OpArgs args);

/// 一个操作的声明。const、纯数据，CLI 与 app 共用同一个对象。
///
/// 构造期约束（[validateOpSpec]，在 [OpSpec.bind] / 组目录时执行，违反即抛
/// [ArgumentError]）：
/// - `inPath` 参数与 [pattern] 的 `:段` 一一对应；参数名不重复；
/// - 声明了 [OpParamRole.remoteUrl] 参数（向调用方给的地址发请求，撤销收不回，
///   spec §5.2）或 [installsCode]（装扩展 / 加仓库 = 执行不可信代码，D9）的操作，
///   必须 [needsConfirmation]。
class OpSpec {
  const OpSpec({
    required this.id,
    required this.method,
    required this.pattern,
    required this.summary,
    this.params = const <OpParam>[],
    this.risk = OpRisk.read,
    this.longRunning = false,
    this.needsUi = false,
    this.confirm = false,
    this.sensitiveResult = false,
    this.installsCode = false,
    this.requiresReady = true,
    this.inProcessOnly = false,
  });

  /// 点分域名（`url.import`），稳定，持久化进操作记录。
  final String id;

  /// `GET` / `POST` / `PUT` / `DELETE`。
  final String method;

  /// 路由模式（`/api/admin/library/items/:key`，`:name` 匹配一段）。
  final String pattern;

  /// 给模型和 `op ls` 用的英文一句话。
  final String summary;

  final List<OpParam> params;
  final OpRisk risk;

  /// 见 [FushiOpSpec.longRunning]。
  final bool longRunning;

  /// 见 [FushiOpSpec.needsUi]。
  final bool needsUi;

  /// 即使可撤销也必须先出确认卡片。
  final bool confirm;

  /// 见 [FushiOpSpec.sensitiveResult]。
  final bool sensitiveResult;

  /// 执行不可信代码（装扩展、加扩展仓库，spec D9）：声明了就必须先确认。
  final bool installsCode;

  /// app 未初始化完成时直接回 409（绝大多数操作都要 AppModel）。
  final bool requiresReady;

  /// 只在进程内有意义（导航类）：不进 HTTP / CLI。
  final bool inProcessOnly;

  /// AI 执行前要不要用户点确认：不可逆，或声明了强制确认。
  bool get needsConfirmation => risk == OpRisk.irreversible || confirm;

  /// 路由模式里的 `:name` 段名。
  List<String> get pathSegmentNames => <String>[
    for (final String seg in pattern.split('/'))
      if (seg.startsWith(':')) seg.substring(1),
  ];

  /// 用 [pathArgs] 代入 `:段` 得到请求路径（逐段 URI 编码）。缺段抛 [ArgumentError]
  /// （调用方的编程错误，不是用户输入错误）。
  String fillPath([Map<String, String> pathArgs = const <String, String>{}]) =>
      pattern
          .split('/')
          .map((String seg) {
            if (!seg.startsWith(':')) return seg;
            final String name = seg.substring(1);
            final String? value = pathArgs[name];
            if (value == null) {
              throw ArgumentError('$id：缺路径参数 $name（$pattern）');
            }
            return Uri.encodeComponent(value);
          })
          .join('/');

  /// 挂上实现，得到可执行、可进目录的 [FushiOp]。
  FushiOp bind({
    required OpHandler handler,
    OpAvailability Function()? availability,
    OpUndo? undo,
    Future<OpTaskStatus> Function(String taskId)? taskStatus,
    String? Function(Object? result)? taskIdOf,
    bool Function()? consentGranted,
  }) => FushiOp.fromSpec(
    this,
    handler: handler,
    availability: availability,
    undo: undo,
    taskStatus: taskStatus,
    taskIdOf: taskIdOf,
    consentGranted: consentGranted,
  );
}

/// [OpSpec] 的构造期约束（见 [OpSpec] 文档）。违反抛 [ArgumentError]。
void validateOpSpec(OpSpec spec) {
  final Set<String> names = <String>{};
  for (final OpParam p in spec.params) {
    if (!names.add(p.name)) {
      throw ArgumentError('${spec.id}：参数 ${p.name} 重复声明');
    }
    if (p.userGate && p.type != OpParamType.boolean) {
      throw ArgumentError('${spec.id}：表态参数 ${p.name} 必须是布尔');
    }
  }
  final Set<String> inPath = <String>{
    for (final OpParam p in spec.params)
      if (p.inPath) p.name,
  };
  final Set<String> segments = spec.pathSegmentNames.toSet();
  if (inPath.length != segments.length || !inPath.containsAll(segments)) {
    throw ArgumentError(
      '${spec.id}：inPath 参数 $inPath 要与 ${spec.pattern} 的 :段 $segments 一致',
    );
  }
  if (!spec.needsConfirmation) {
    for (final OpParam p in spec.params) {
      if (p.role == OpParamRole.remoteUrl && !p.userGate) {
        throw ArgumentError(
          '${spec.id}：参数 ${p.name} 是会被请求的外部地址（remoteUrl），操作必须先确认'
          '（risk: irreversible，或可撤销写操作 confirm: true）',
        );
      }
    }
    if (spec.installsCode) {
      throw ArgumentError('${spec.id}：装扩展 / 执行不可信代码必须先确认（D9）');
    }
  }
}

/// 未声明的参数怎么处理。
enum OpUnknownParams {
  /// 拒绝（400 `未知参数：x`）：进程内调用器（AI / `ops/call` / MCP）。
  reject,

  /// 只告警、照常执行：HTTP 直连。现有调用方（CLI 顺手带的键、WebUI、互联客户端）
  /// 没逐个核对前不收紧——收紧是对外行为变化。
  warn,
}

/// 未声明参数的告警出口（HTTP 直连路径）。
void reportUnknownOpParams(OpSpec spec, Iterable<String> names) {
  developer.log(
    '${spec.id}（${spec.method} ${spec.pattern}）收到未声明的参数：'
    '${names.join(', ')}；已忽略',
    name: 'fushi.ops',
    level: 900,
  );
}

/// 一次调用按 [OpSpec] 参数表解析后的参数。
///
/// 是一个 [CtlCall]（原始 body / query / 路径参数原样保留，撤销闭包与旧 handler
/// 照旧能读），另带 [values]：每个已声明参数按类型转换后的值。handler 只用带类型的
/// 取值（[text] / [integer] / [boolean] …），参数对象必须是本操作声明里的那一个
/// ——传错参数或类型对不上是编程错误，抛 [StateError]。
class OpArgs extends CtlCall {
  const OpArgs._({
    required this.spec,
    required this.values,
    required super.method,
    required super.path,
    super.params,
    super.query,
    super.body,
    super.fromModel,
  });

  /// 这次调用的操作声明。
  final OpSpec spec;

  /// 已声明参数按类型转换后的值（缺省 / null 的不在里面）。
  final Map<String, Object> values;

  /// 唯一的参数解析：按 [spec] 的参数表把 [call] 的路径参数、body（优先）、query
  /// 转换成声明类型（GET 的 query 值都是字符串，按类型转），校验枚举、必填与语义
  /// 类型（[OpParam.httpOnly]）。错误一律 [CtlFailure.badRequest]。
  ///
  /// [unknown]：未声明参数拒绝还是只告警（见 [OpUnknownParams]）。带 `spread`
  /// 参数的操作按动态键名读 body，顶层的未声明键归进那个参数，不算未知。
  static OpArgs parse(
    OpSpec spec,
    CtlCall call, {
    required OpUnknownParams unknown,
  }) {
    final Map<String, OpParam> declared = <String, OpParam>{
      for (final OpParam p in spec.params)
        if (!p.inPath) p.name: p,
    };
    final OpParam? spread = spec.params
        .where((OpParam p) => p.spread)
        .firstOrNull;
    final List<String> unknownNames = <String>[];
    final Map<String, Object?> spreadValues = <String, Object?>{};
    for (final String key in <String>{...call.body.keys, ...call.query.keys}) {
      if (declared.containsKey(key)) continue;
      if (spread != null) {
        spreadValues[key] = call.body[key] ?? call.query[key];
      } else if (unknown == OpUnknownParams.reject) {
        throw CtlFailure.badRequest('未知参数：$key');
      } else {
        unknownNames.add(key);
      }
    }
    if (unknownNames.isNotEmpty) reportUnknownOpParams(spec, unknownNames);
    final Map<String, Object> values = <String, Object>{};
    for (final OpParam param in spec.params) {
      final Object? raw = param.inPath
          ? call.params[param.name]
          : param.spread
          ? (spreadValues.isEmpty ? null : spreadValues)
          : call.body[param.name] ?? call.query[param.name];
      if (raw == null) {
        if (param.required) throw CtlFailure.badRequest('${param.name} 缺失');
        continue;
      }
      values[param.name] = coerceOpParam(param, raw);
    }
    return OpArgs._(
      spec: spec,
      values: values,
      method: call.method,
      path: call.path,
      params: call.params,
      query: call.query,
      body: call.body,
      fromModel: call.fromModel,
    );
  }

  /// 进程内直接调另一个操作（撤销、组合操作）时拼原始调用：路径参数代入
  /// [OpSpec.pattern]，其余进 body，再走 [parse]（拒绝未知参数——调用方是本仓代码，
  /// 写错参数名要立刻炸）。
  static OpArgs direct(
    OpSpec spec, {
    Map<String, String> pathArgs = const <String, String>{},
    Map<String, Object?> body = const <String, Object?>{},
  }) => parse(
    spec,
    CtlCall(
      method: spec.method,
      path: spec.fillPath(pathArgs),
      params: pathArgs,
      body: body,
    ),
    unknown: OpUnknownParams.reject,
  );

  Object? _value(OpParam param, Set<OpParamType> types) {
    if (!spec.params.contains(param)) {
      throw StateError('${spec.id} 没有声明参数 ${param.name}（传的是别的操作的参数对象？）');
    }
    if (!types.contains(param.type)) {
      throw StateError('${spec.id}：参数 ${param.name} 是 ${param.type.name}');
    }
    return values[param.name];
  }

  /// 字符串参数（去首尾空白，空白视为没给）。
  String? text(OpParam param) {
    final Object? raw = _value(param, const <OpParamType>{OpParamType.string});
    if (raw == null) return null;
    final String trimmed = (raw as String).trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 必填的字符串参数：缺失或空白回 400 `name 缺失`。
  String requiredText(OpParam param) {
    final String? value = text(param);
    if (value == null) throw CtlFailure.badRequest('${param.name} 缺失');
    return value;
  }

  /// 字符串参数原值（不去空白；正文类参数用）。
  String? rawText(OpParam param) =>
      _value(param, const <OpParamType>{OpParamType.string}) as String?;

  int? integer(OpParam param) =>
      _value(param, const <OpParamType>{OpParamType.integer}) as int?;

  num? number(OpParam param) =>
      _value(param, const <OpParamType>{OpParamType.number}) as num?;

  bool? boolean(OpParam param) =>
      _value(param, const <OpParamType>{OpParamType.boolean}) as bool?;

  /// 字符串数组（去空白、丢空项；缺省为空表）。
  List<String> strings(OpParam param) {
    final Object? raw = _value(param, const <OpParamType>{
      OpParamType.stringList,
    });
    if (raw == null) return const <String>[];
    return <String>[
      for (final String item in raw as List<String>)
        if (item.trim().isNotEmpty) item.trim(),
    ];
  }

  Map<String, Object?>? object(OpParam param) =>
      _value(param, const <OpParamType>{OpParamType.object})
          as Map<String, Object?>?;

  List<Map<String, Object?>>? objects(OpParam param) =>
      _value(param, const <OpParamType>{OpParamType.objectList})
          as List<Map<String, Object?>>?;
}

/// 把一个原始值按 [param] 的声明转换。错误回 [CtlFailure.badRequest]。
Object coerceOpParam(OpParam param, Object value) {
  switch (param.type) {
    case OpParamType.string:
      final String text = value is String ? value : '$value';
      // 空白 = 没给（handler 的 [OpArgs.text] 读成 null），不按枚举 / 地址判。
      if (text.trim().isEmpty) return text;
      final List<String>? allowed = param.enumValues;
      if (allowed != null && !allowed.contains(text)) {
        throw CtlFailure.badRequest('${param.name} 只能是 ${allowed.join(' / ')}');
      }
      if (param.httpOnly && !isHttpUrl(text)) {
        throw CtlFailure.badRequest(
          '${param.name} 只认 http(s) 地址：${text.trim()}',
        );
      }
      return text;
    case OpParamType.integer:
      if (value is int) return value;
      if (value is num && value == value.roundToDouble()) {
        return value.toInt();
      }
      final int? parsed = int.tryParse('$value'.trim());
      if (parsed == null) {
        throw CtlFailure.badRequest('${param.name} 必须是整数');
      }
      return parsed;
    case OpParamType.number:
      if (value is num) return value;
      final num? parsed = num.tryParse('$value'.trim());
      if (parsed == null) {
        throw CtlFailure.badRequest('${param.name} 必须是数字');
      }
      return parsed;
    case OpParamType.boolean:
      if (value is bool) return value;
      switch ('$value'.trim().toLowerCase()) {
        case 'true' || '1' || 'yes' || 'on':
          return true;
        case 'false' || '0' || 'no' || 'off':
          return false;
      }
      throw CtlFailure.badRequest('${param.name} 必须是布尔值');
    case OpParamType.stringList:
      if (value is List) {
        return <String>[for (final Object? item in value) '$item'];
      }
      if (value is String) return <String>[value];
      throw CtlFailure.badRequest('${param.name} 必须是字符串数组');
    case OpParamType.object:
      if (value is Map) return Map<String, Object?>.from(value);
      throw CtlFailure.badRequest('${param.name} 必须是对象');
    case OpParamType.objectList:
      if (value is List && value.every((Object? e) => e is Map)) {
        return <Map<String, Object?>>[
          for (final Object? e in value) Map<String, Object?>.from(e! as Map),
        ];
      }
      throw CtlFailure.badRequest('${param.name} 必须是对象数组');
  }
}

/// http(s) 且有主机的地址（[OpParam.httpOnly] 的判据）。
bool isHttpUrl(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null) return false;
  final String scheme = uri.scheme.toLowerCase();
  return (scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty;
}
