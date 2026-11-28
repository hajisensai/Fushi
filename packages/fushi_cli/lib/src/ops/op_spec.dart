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
/// （[OpInvoker]：AI 助手、`/api/admin/ops/call`、MCP）都经它得到 [OpArgs]，handler
/// 只用 [OpArgs] 的带类型取值，不再自己 `optString` / 判空 / 判枚举；转换与校验只有
/// [coerceOpParam] 一份。两面的口径不同（[OpCallSurface]）：进程内严格、当场校验；
/// HTTP 直连保持迁移前手写取值的线上行为（取值时才校验）。
library;

import 'dart:developer' as developer;

import '../ctl_routes.dart';
import 'fushi_op.dart';

/// handler：拿按参数表解析的 [OpArgs]（带类型取值）。返回值必须可 JSON 编码；
/// null 视为 `{"ok": true}`。
typedef OpHandler = Future<Object?> Function(OpArgs args);

/// 一个操作的声明。const、纯数据，CLI 与 app 共用同一个对象。
///
/// 构造期约束（[validateOpSpec]，在 [OpSpec.bind] / 组目录时执行，违反即抛
/// [ArgumentError]）：
/// - `inPath` 参数与 [pattern] 的 `:段` 一一对应；参数名不重复；
/// - 名字是地址类（[kAddressParamName]）的参数必须显式选语义角色（[OpParamRole]），
///   不许是 `plain`——默认拒绝；
/// - id 是「装第三方代码」形状（[kCodeInstallOpId]）的操作必须声明 [installsCode]；
/// - 声明了 [OpParamRole.remoteUrl] 参数（向调用方给的地址发请求，撤销收不回，
///   spec §5.2）或 [installsCode]（装扩展 / 加仓库 = 执行不可信代码，D9）的操作，
///   必须 [needsConfirmation]。
///
/// 执行期约束（[FushiOp.run]）：声明了表态参数（[OpParam.userGate]）的操作，实现
/// 必须经 [OpArgs.gate] 读过它才算完成（[OpArgs.requireGatesConsulted]）。
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

/// 「地址类」参数名：值可能是一个会被请求的位置。命中它的参数**必须**显式选语义
/// 角色（[OpParamRole.remoteUrl] / `fixedHostUrl` / `storedAddress` / `entityRef`），
/// 不许留在 [OpParamRole.plain]——默认拒绝，不靠作者记得标注。
final RegExp kAddressParamName = RegExp(
  r'(^|[a-z])(url|uri|link|endpoint|magnet|href|host|address)s?$',
  caseSensitive: false,
);

/// 「把第三方代码装进来」的操作 id 形状：名词段是扩展 / 插件 / 扩展仓库，动作是
/// 装 / 升级 / 加 / 导入（`online.extension.install`、`online.repo.add`、
/// `music.plugin.install`，以及以后的 `…extension.install-from-url` 这类变体）。命中它
/// 的操作**必须**声明 [OpSpec.installsCode]（于是必须先确认，spec D9）。
final RegExp kCodeInstallOpId = RegExp(
  r'(^|\.)(extension|plugin|addon|repo)\.'
  r'(install|update|upgrade|add|import|sideload)[a-z0-9-]*$',
);

/// 能装下一个地址的参数类型（布尔 / 数字装不下，不管名字）。
const Set<OpParamType> _addressCapableTypes = <OpParamType>{
  OpParamType.string,
  OpParamType.stringList,
  OpParamType.object,
  OpParamType.objectList,
};

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
    if (p.httpOnly && p.type != OpParamType.string) {
      throw ArgumentError('${spec.id}：httpOnly 参数 ${p.name} 必须是字符串');
    }
    if (p.role == OpParamRole.plain &&
        !p.userGate &&
        _addressCapableTypes.contains(p.type) &&
        kAddressParamName.hasMatch(p.name)) {
      throw ArgumentError(
        '${spec.id}：参数 ${p.name} 的名字是地址类，必须显式选语义角色：会去请求它用 '
        'OpParam.remoteUrl（操作先确认）；只发往固定主机用 fixedHostUrl；只存不请求用 '
        'storedAddress；本地条目 / 扩展作品引用用 entityRef',
      );
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
  if (kCodeInstallOpId.hasMatch(spec.id) && !spec.installsCode) {
    throw ArgumentError(
      '${spec.id}：装扩展 / 插件 / 加扩展仓库是执行不可信代码，必须声明 installsCode: true'
      '（于是必须先确认，D9）',
    );
  }
  if (!spec.needsConfirmation) {
    for (final OpParam p in spec.params) {
      if (p.role == OpParamRole.remoteUrl) {
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

/// 一次调用从哪一面进来，决定参数按哪套口径解析。
enum OpCallSurface {
  /// 进程内调用器（AI 助手 / `ops/call` / MCP / 撤销与组合）：**严格、急切**——
  /// [OpArgs.parse] 当场拒绝未知参数（400 `未知参数：x`）、查必填、把每个参数转换
  /// 成声明类型（`1.5` 不是整数、空白也按枚举判）。
  inProcess,

  /// HTTP 直连（`fushi_cli`、WebUI、互联客户端）：与手写 [CtlCall] 取值**同一口径**——
  /// 未声明的参数只告警、照常执行；参数在 handler 取值那一刻才转换与校验（所以
  /// handler 里先做的模块门 / 只读门仍先于参数错误报出）；数字按 [CtlCall.optInt]
  /// 截断成整数；空白字符串视为没给。把 HTTP 收紧成急切校验是对外行为变化，要另行
  /// 拍板，不在迁移声明方式时顺带做。
  http,
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
/// 照旧能读）。handler 只用带类型的取值（[text] / [integer] / [gate] …），转换与校验
/// 只有 [coerceOpParam] 一份实现。参数对象必须是本操作声明里的那一个（按对象身份
/// 比；两个操作里字面量完全相同的 const 参数是同一个对象，等价），类型对不上或拿
/// [boolean] 读表态参数都是编程错误，抛 [StateError]。
///
/// 表态参数（[OpParam.userGate]）只能经 [gate] 读，读过的记在这次调用上：
/// [FushiOp.run] 在实现成功返回后查 [requireGatesConsulted]——声明了表态参数、实现却
/// 没读它就完成了操作，当场抛 [StateError]（HTTP、进程内、撤销 / 组合都经同一个
/// [FushiOp.run]）。
class OpArgs extends CtlCall {
  OpArgs._({
    required this.spec,
    required this.surface,
    required Map<String, Object?> spread,
    required super.method,
    required super.path,
    super.params,
    super.query,
    super.body,
    super.fromModel,
  }) : _spread = spread;

  /// 这次调用的操作声明。
  final OpSpec spec;

  /// 从哪一面进来的（见 [OpCallSurface]）。
  final OpCallSurface surface;

  /// `spread` 参数收到的键值（顶层的未声明键）。
  final Map<String, Object?> _spread;

  /// 已转换过的参数值（按名字记，避免重复转换）。
  final Map<String, Object> _coerced = <String, Object>{};

  /// 实现读过的表态参数名。
  final Set<String> _gatesConsulted = <String>{};

  /// 唯一的参数解析入口：按 [spec] 的参数表读 [call] 的路径参数、body（优先）、query。
  /// [surface] 定口径（见 [OpCallSurface]）：进程内当场校验全部参数；HTTP 直连只在
  /// 取值时校验。错误一律 [CtlFailure.badRequest]。
  ///
  /// 带 `spread` 参数的操作按动态键名读 body，顶层的未声明键归进那个参数，不算未知。
  static OpArgs parse(
    OpSpec spec,
    CtlCall call, {
    required OpCallSurface surface,
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
      } else if (surface == OpCallSurface.inProcess) {
        throw CtlFailure.badRequest('未知参数：$key');
      } else {
        unknownNames.add(key);
      }
    }
    if (unknownNames.isNotEmpty) reportUnknownOpParams(spec, unknownNames);
    final OpArgs args = OpArgs._(
      spec: spec,
      surface: surface,
      spread: spreadValues,
      method: call.method,
      path: call.path,
      params: call.params,
      query: call.query,
      body: call.body,
      fromModel: call.fromModel,
    );
    if (surface == OpCallSurface.inProcess) {
      for (final OpParam param in spec.params) {
        args._coercedValue(param);
      }
    }
    return args;
  }

  /// 进程内直接调另一个操作（撤销、组合操作）时拼原始调用：路径参数代入
  /// [OpSpec.pattern]，其余进 body，再走 [parse]（进程内口径：拒绝未知参数——调用方
  /// 是本仓代码，写错参数名要立刻炸）。
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
    surface: OpCallSurface.inProcess,
  );

  /// [param] 的原始值按声明转换后的结果；没给返回 null，必填的没给回 400。
  Object? _coercedValue(OpParam param) {
    final Object? cached = _coerced[param.name];
    if (cached != null) return cached;
    final Object? raw = param.inPath
        ? params[param.name]
        : param.spread
        ? (_spread.isEmpty ? null : _spread)
        : body[param.name] ?? query[param.name];
    if (raw == null) {
      if (param.required) throw CtlFailure.badRequest('${param.name} 缺失');
      return null;
    }
    return _coerced[param.name] = coerceOpParam(param, raw, surface);
  }

  Object? _value(OpParam param, Set<OpParamType> types) {
    if (!spec.params.any((OpParam p) => identical(p, param))) {
      throw StateError('${spec.id} 没有声明参数 ${param.name}（传的是别的操作的参数对象？）');
    }
    if (!types.contains(param.type)) {
      throw StateError('${spec.id}：参数 ${param.name} 是 ${param.type.name}');
    }
    return _coercedValue(param);
  }

  String? _trimmed(OpParam param) {
    final Object? raw = _value(param, const <OpParamType>{OpParamType.string});
    if (raw == null) return null;
    final String trimmed = (raw as String).trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// [OpParam.httpOnly] 的校验。在取值时做（两种口径都是）：迁移前它就排在 handler 的
  /// 模块门 / 只读门之后。文案沿用迁移前手写校验的两种形态——必填地址不带参数名，
  /// 可选地址带参数名。
  void _requireHttp(OpParam param, String value, {required bool named}) {
    if (!param.httpOnly || isHttpUrl(value)) return;
    throw CtlFailure.badRequest(
      '${named ? '${param.name} ' : ''}只认 http(s) 地址：$value',
    );
  }

  /// 字符串参数（去首尾空白，空白视为没给）。
  String? text(OpParam param) {
    final String? value = _trimmed(param);
    if (value != null) _requireHttp(param, value, named: true);
    return value;
  }

  /// 必填的字符串参数：缺失或空白回 400 `name 缺失`。
  String requiredText(OpParam param) {
    final String? value = _trimmed(param);
    if (value == null) throw CtlFailure.badRequest('${param.name} 缺失');
    _requireHttp(param, value, named: false);
    return value;
  }

  /// 字符串参数原值（不去空白；正文类参数用）。
  String? rawText(OpParam param) {
    final String? raw =
        _value(param, const <OpParamType>{OpParamType.string}) as String?;
    if (raw != null) _requireHttp(param, raw.trim(), named: true);
    return raw;
  }

  int? integer(OpParam param) =>
      _value(param, const <OpParamType>{OpParamType.integer}) as int?;

  num? number(OpParam param) =>
      _value(param, const <OpParamType>{OpParamType.number}) as num?;

  /// 普通布尔参数。表态参数不许用它读（用 [gate]，读没读要记账）。
  bool? boolean(OpParam param) {
    if (param.userGate) {
      throw StateError('${spec.id}：${param.name} 是表态参数，用 gate() 读');
    }
    return _value(param, const <OpParamType>{OpParamType.boolean}) as bool?;
  }

  /// 表态参数（[OpParam.userGate]）：用户表过态返回 true。读过即记在这次调用上
  /// （见 [requireGatesConsulted]）。
  bool gate(OpParam param) {
    if (!param.userGate) {
      throw StateError('${spec.id}：${param.name} 不是表态参数，用 boolean() 读');
    }
    final Object? value = _value(param, const <OpParamType>{
      OpParamType.boolean,
    });
    _gatesConsulted.add(param.name);
    return value == true;
  }

  /// 声明了的表态参数必须都被实现读过（[gate]）。[FushiOp.run] 在实现成功返回后调：
  /// 没读就完成了操作 = 用户同意门被绕过，抛 [StateError]。
  void requireGatesConsulted() {
    final List<String> skipped = <String>[
      for (final OpParam p in spec.params)
        if (p.userGate && !_gatesConsulted.contains(p.name)) p.name,
    ];
    if (skipped.isNotEmpty) {
      throw StateError(
        '${spec.id}：声明了表态参数 ${skipped.join(' / ')}，实现却没读它（OpArgs.gate）'
        '就完成了操作——用户同意门没有生效',
      );
    }
  }

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

/// 把一个原始值按 [param] 的声明转换——唯一的一份转换实现。[surface] 定口径（见
/// [OpCallSurface]）：HTTP 直连与手写 [CtlCall] 取值一致（数字截断、空白视为没给、
/// 数组丢 null 项），进程内严格。错误回 [CtlFailure.badRequest]。
///
/// [OpParam.httpOnly] 不在这里查：它在取值时查（[OpArgs.text] / [OpArgs.requiredText]）。
Object coerceOpParam(OpParam param, Object value, OpCallSurface surface) {
  final bool lenient = surface == OpCallSurface.http;
  switch (param.type) {
    case OpParamType.string:
      final String text = value is String ? value : '$value';
      final List<String>? allowed = param.enumValues;
      if (allowed != null) {
        // HTTP 口径：空白 = 没给（[OpArgs.text] 读成 null），首尾空白不算数。
        final String probe = lenient ? text.trim() : text;
        if (!(lenient && probe.isEmpty) && !allowed.contains(probe)) {
          throw CtlFailure.badRequest(
            '${param.name} 只能是 ${allowed.join(' / ')}',
          );
        }
      }
      return text;
    case OpParamType.integer:
      if (value is int) return value;
      if (value is num && (lenient || value == value.roundToDouble())) {
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
        return <String>[
          for (final Object? item in value)
            if (!(lenient && item == null)) '$item',
        ];
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

/// http(s) 且有主机的地址——全仓唯一的一份判据（[OpParam.httpOnly]、CLI 本地拦截、
/// app 的 `isPlayableStreamUrl` 都是它）。纯字符串判定，不碰文件系统 / 网络。
bool isHttpUrl(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null) return false;
  final String scheme = uri.scheme.toLowerCase();
  return (scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty;
}
