/// 操作目录（spec `docs/specs/2026-10-26-ai-operations-agent-design.md` §4）：给
/// 控制通道路由加上「给模型 / `fushi_cli op` 看的描述」。
///
/// 一条 [FushiOp] = 稳定 id + 英文说明 + 参数 schema + 风险级 + 撤销 + 现有
/// [CtlRoute]。handler 原样复用路由的（即 UI 按钮背后的同一个方法），这里不写任何
/// 业务逻辑。纯 Dart：app、CLI、服务端都能依赖。
library;

import '../ctl_routes.dart';

/// 操作的风险级，决定 AI 前端怎么执行（spec §5.2）。
enum OpRisk {
  /// 只读：列表、查询、状态。直接执行。
  read,

  /// 写，且声明了 [FushiOp.undo]：直接执行，执行后带「撤销」。
  write,

  /// 写，但撤销不了（删用户磁盘文件、清扩展数据、执行不可信代码、把数据发给
  /// 已指派 LLM 以外的第三方）：执行前出确认卡片，用户点了才跑。
  irreversible;

  static OpRisk? fromWire(String? value) {
    for (final OpRisk risk in values) {
      if (risk.name == value) return risk;
    }
    return null;
  }
}

/// 参数类型：生成 JSON Schema 的一个子集。
enum OpParamType {
  string('string'),
  integer('integer'),
  number('number'),
  boolean('boolean'),
  stringList('array'),
  object('object'),

  /// 对象数组（如文本处理流水线的步骤列表）。
  objectList('array');

  const OpParamType(this.schemaType);

  final String schemaType;

  static OpParamType? fromWire(String? value) {
    for (final OpParamType type in values) {
      if (type.name == value) return type;
    }
    return null;
  }
}

/// 一个参数。
class OpParam {
  const OpParam(
    this.name,
    this.type, {
    required this.description,
    this.required = false,
    this.enumValues,
    this.userGate = false,
    this.inPath = false,
    this.spread = false,
  });

  const OpParam.string(
    String name, {
    required String description,
    bool required = false,
    List<String>? enumValues,
    bool inPath = false,
  }) : this(
         name,
         OpParamType.string,
         description: description,
         required: required,
         enumValues: enumValues,
         inPath: inPath,
       );

  const OpParam.integer(
    String name, {
    required String description,
    bool required = false,
  }) : this(
         name,
         OpParamType.integer,
         description: description,
         required: required,
       );

  const OpParam.number(
    String name, {
    required String description,
    bool required = false,
  }) : this(
         name,
         OpParamType.number,
         description: description,
         required: required,
       );

  const OpParam.boolean(
    String name, {
    required String description,
    bool required = false,
  }) : this(
         name,
         OpParamType.boolean,
         description: description,
         required: required,
       );

  const OpParam.stringList(
    String name, {
    required String description,
    bool required = false,
  }) : this(
         name,
         OpParamType.stringList,
         description: description,
         required: required,
       );

  /// [spread]：对象里的键值铺进 body 顶层（路由按动态键名读参数时用，如
  /// 设置动作行声明的参数）。
  const OpParam.objectList(
    String name, {
    required String description,
    bool required = false,
  }) : this(
         name,
         OpParamType.objectList,
         description: description,
         required: required,
       );

  const OpParam.object(
    String name, {
    required String description,
    bool required = false,
    bool spread = false,
  }) : this(
         name,
         OpParamType.object,
         description: description,
         required: required,
         spread: spread,
       );

  /// 用户表态参数（`confirm` / `yes` / `trustSigner` / `allowInsecure` /
  /// `consentUpload`…）：**从给模型看的 schema 里删掉**，只由 AI 运行时按 §5.2
  /// 填——可逆操作直接注入，不可逆 / 强制确认的只在用户点了确认卡片后注入。
  /// CLI 照旧是用户自己敲的 flag。值恒为布尔 true。
  const OpParam.userGate(String name, {required String description})
    : this(name, OpParamType.boolean, description: description, userGate: true);

  final String name;
  final OpParamType type;
  final String description;
  final bool required;
  final List<String>? enumValues;
  final bool userGate;

  /// 路由模式里的 `:name` 段：调用时代入路径，不进 body。
  final bool inPath;

  /// 对象参数的键值铺进 body 顶层，见 [OpParam.object]。
  final bool spread;

  Map<String, Object?> toJsonSchema() => <String, Object?>{
    'type': type.schemaType,
    'description': description,
    if (type == OpParamType.stringList)
      'items': const <String, Object?>{'type': 'string'},
    if (type == OpParamType.objectList)
      'items': const <String, Object?>{'type': 'object'},
    if (enumValues != null) 'enum': enumValues,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'type': type.name,
    'description': description,
    if (required) 'required': true,
    if (enumValues != null) 'enum': enumValues,
    if (userGate) 'userGate': true,
    if (inPath) 'inPath': true,
    if (spread) 'spread': true,
  };

  static OpParam fromJson(Map<String, Object?> json) => OpParam(
    json['name'] as String? ?? '',
    OpParamType.fromWire(json['type'] as String?) ?? OpParamType.string,
    description: json['description'] as String? ?? '',
    required: json['required'] == true,
    enumValues: (json['enum'] as List<Object?>?)
        ?.map((Object? e) => '$e')
        .toList(growable: false),
    userGate: json['userGate'] == true,
    inPath: json['inPath'] == true,
    spread: json['spread'] == true,
  );
}

/// 当前能不能用。不可用时带一个短码（`module_disabled` / `store_restricted` /
/// `platform_unsupported` / `not_configured`…）与可选说明。
class OpAvailability {
  const OpAvailability.available() : code = null, message = null;
  const OpAvailability.unavailable(String this.code, [this.message]);

  final String? code;
  final String? message;

  bool get isAvailable => code == null;
}

/// 撤销的结果。
enum OpUndoStatus {
  /// 已撤销，状态回到执行前。
  done,

  /// 执行之后又被手动改过：不覆盖用户的修改，跳过（spec §5.3）。
  superseded,

  /// 撤销失败（对象已不存在等）。
  failed,
}

class OpUndoOutcome {
  const OpUndoOutcome.done([this.message]) : status = OpUndoStatus.done;
  const OpUndoOutcome.superseded([this.message])
    : status = OpUndoStatus.superseded;
  const OpUndoOutcome.failed([this.message]) : status = OpUndoStatus.failed;

  final OpUndoStatus status;
  final String? message;
}

/// 一次执行留下的撤销载荷：可 JSON 编码，持久化进本机 `ai_agent_actions`，
/// 过了会话、重启 app 也能按 [FushiOp.undo] 的 [OpUndo.revert] 撤销。
class OpUndoRecord {
  const OpUndoRecord({required this.payload, this.before, this.after});

  final Map<String, Object?> payload;

  /// 给人看的「改前 → 改后」（对话里与操作记录页显示）。可空。
  final String? before;
  final String? after;
}

/// 可撤销写操作的撤销声明。
///
/// - [capture]：执行**前**抓快照（设置旧值、条目原状态…），返回可 JSON 编码的 Map。
/// - [record]：执行**后**用前态 + 执行结果拼出撤销载荷（如安装扩展后记下扩展 id）。
/// - [revert]：按载荷撤销；执行后又被手动改过时回 [OpUndoOutcome.superseded]。
class OpUndo {
  const OpUndo({this.capture, required this.record, required this.revert});

  final Future<Map<String, Object?>> Function(CtlCall call)? capture;
  final OpUndoRecord Function(
    CtlCall call,
    Map<String, Object?> before,
    Object? result,
  )
  record;
  final Future<OpUndoOutcome> Function(Map<String, Object?> payload) revert;
}

/// 长任务的一次状态读数（[FushiOp.taskStatus]）。
class OpTaskStatus {
  const OpTaskStatus({
    required this.terminal,
    this.succeeded = false,
    this.summary,
    this.data,
  });

  /// 任务已结束（成功、失败或被取消）。
  final bool terminal;

  /// 结束且成功。
  final bool succeeded;

  /// 给人看的一句话（可空）。
  final String? summary;

  /// 可 JSON 编码的原始状态（交给模型前包进不可信数据块）。
  final Object? data;

  Map<String, Object?> toJson() => <String, Object?>{
    'terminal': terminal,
    'succeeded': succeeded,
    if (summary != null) 'summary': summary,
    if (data != null) 'data': data,
  };
}

/// 可序列化的操作描述：`fushi_cli op ls/describe` 与 AI 工具 schema 都由它生成。
class FushiOpSpec {
  const FushiOpSpec({
    required this.id,
    required this.summary,
    required this.method,
    required this.pattern,
    this.params = const <OpParam>[],
    this.risk = OpRisk.read,
    this.longRunning = false,
    this.needsUi = false,
    this.confirm = false,
    this.undoable = false,
    this.inProcessOnly = false,
    this.sensitiveResult = false,
  });

  /// 点分域名（`video.subtitle.search`），稳定，可做持久化 key。
  final String id;

  /// 给模型和 `op ls` 用的英文一句话。
  final String summary;

  final String method;
  final String pattern;
  final List<OpParam> params;
  final OpRisk risk;

  /// 返回 taskId，进度经 `task.get` / `task.wait`。
  final bool longRunning;

  /// 要弹 app 内对话框或候选（AI 页能满足，CLI 需显式参数）。
  final bool needsUi;

  /// 即使可撤销也必须先出确认卡片（装扩展，spec D9）。
  final bool confirm;

  final bool undoable;

  /// 只在进程内有意义（`ui.ask_choice`、`nav.open`）：不进 HTTP / CLI。
  final bool inProcessOnly;

  /// 结果含一次性凭据（配对票据等）：AI 前端只给用户看，不交给模型。
  final bool sensitiveResult;

  /// AI 执行前要不要用户点确认：不可逆，或声明了强制确认。
  bool get needsConfirmation => risk == OpRisk.irreversible || confirm;

  Iterable<OpParam> get modelParams => params.where((OpParam p) => !p.userGate);

  Iterable<OpParam> get gateParams => params.where((OpParam p) => p.userGate);

  /// 给模型看的 JSON Schema：**不含** [OpParam.userGate] 参数。
  Map<String, Object?> modelSchema() => <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      for (final OpParam p in modelParams) p.name: p.toJsonSchema(),
    },
    'required': <String>[
      for (final OpParam p in modelParams)
        if (p.required) p.name,
    ],
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'summary': summary,
    'method': method,
    'path': pattern,
    'risk': risk.name,
    if (longRunning) 'longRunning': true,
    if (needsUi) 'needsUi': true,
    if (confirm) 'confirm': true,
    if (undoable) 'undoable': true,
    if (inProcessOnly) 'inProcessOnly': true,
    if (sensitiveResult) 'sensitiveResult': true,
    'params': <Map<String, Object?>>[
      for (final OpParam p in params) p.toJson(),
    ],
  };

  static FushiOpSpec fromJson(Map<String, Object?> json) => FushiOpSpec(
    id: json['id'] as String? ?? '',
    summary: json['summary'] as String? ?? '',
    method: json['method'] as String? ?? 'GET',
    pattern: json['path'] as String? ?? '',
    risk: OpRisk.fromWire(json['risk'] as String?) ?? OpRisk.read,
    longRunning: json['longRunning'] == true,
    needsUi: json['needsUi'] == true,
    confirm: json['confirm'] == true,
    undoable: json['undoable'] == true,
    inProcessOnly: json['inProcessOnly'] == true,
    sensitiveResult: json['sensitiveResult'] == true,
    params: <OpParam>[
      for (final Object? p in (json['params'] as List<Object?>? ?? const []))
        if (p is Map<String, Object?>) OpParam.fromJson(p),
    ],
  );
}

/// 一条带描述的操作：描述 + 可用性 + 撤销 + 现有路由。
class FushiOp {
  FushiOp({
    required this.id,
    required this.summary,
    required this.route,
    this.params = const <OpParam>[],
    this.risk = OpRisk.read,
    this.longRunning = false,
    this.needsUi = false,
    this.confirm = false,
    this.availability,
    this.undo,
    this.inProcessOnly = false,
    this.sensitiveResult = false,
    this.taskStatus,
  });

  final String id;
  final String summary;
  final CtlRoute route;
  final List<OpParam> params;
  final OpRisk risk;
  final bool longRunning;
  final bool needsUi;
  final bool confirm;
  final bool inProcessOnly;
  final bool sensitiveResult;

  /// 平台 / 合规 / 模块开关 / 前置条件。null = 恒可用。
  final OpAvailability Function()? availability;

  final OpUndo? undo;

  /// [longRunning] 操作的状态读数：按执行结果里的 taskId 读一次（用现有的状态路由）。
  /// AI 运行时据此轮询，结束后在对话里报告并自动续一轮（spec §6.1）。
  final Future<OpTaskStatus> Function(String taskId)? taskStatus;

  OpAvailability currentAvailability() =>
      availability?.call() ?? const OpAvailability.available();

  FushiOpSpec get spec => FushiOpSpec(
    id: id,
    summary: summary,
    method: route.method,
    pattern: route.pattern,
    params: params,
    risk: risk,
    longRunning: longRunning,
    needsUi: needsUi,
    confirm: confirm,
    undoable: undo != null,
    inProcessOnly: inProcessOnly,
    sensitiveResult: sensitiveResult,
  );
}

/// 一条路由的描述，按 `METHOD pattern` 挂到 [CtlRoute] 上（见 [OpCatalog.build]）。
/// 描述与路由分开写在各域的 `op_<域>_descriptions.dart`，不改庞大的路由文件。
class OpDescription {
  const OpDescription({
    required this.id,
    required this.method,
    required this.pattern,
    required this.summary,
    this.params = const <OpParam>[],
    this.risk = OpRisk.read,
    this.longRunning = false,
    this.needsUi = false,
    this.confirm = false,
    this.availability,
    this.undo,
    this.sensitiveResult = false,
    this.taskStatus,
  });

  final String id;
  final String method;
  final String pattern;
  final String summary;
  final List<OpParam> params;
  final OpRisk risk;
  final bool longRunning;
  final bool needsUi;
  final bool confirm;
  final OpAvailability Function()? availability;
  final OpUndo? undo;

  /// 见 [FushiOpSpec.sensitiveResult]。
  final bool sensitiveResult;

  /// 见 [FushiOp.taskStatus]。
  final Future<OpTaskStatus> Function(String taskId)? taskStatus;

  String get routeKey => '$method $pattern';

  FushiOp bind(CtlRoute route) => FushiOp(
    id: id,
    summary: summary,
    route: route,
    params: params,
    risk: risk,
    longRunning: longRunning,
    needsUi: needsUi,
    confirm: confirm,
    availability: availability,
    undo: undo,
    sensitiveResult: sensitiveResult,
    taskStatus: taskStatus,
  );
}
