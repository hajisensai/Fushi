/// 操作目录（spec `docs/specs/2026-10-26-ai-operations-agent-design.md` §4）：给
/// 控制通道路由加上「给模型 / `fushi_cli op` 看的描述」。
///
/// 一条 [FushiOp] = 稳定 id + 英文说明 + 参数 schema + 风险级 + 撤销 + 现有
/// [CtlRoute]。handler 原样复用路由的（即 UI 按钮背后的同一个方法），这里不写任何
/// 业务逻辑。纯 Dart：app、CLI、服务端都能依赖。
library;

import '../ctl_routes.dart';
import 'op_spec.dart';

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

/// 参数的语义角色：安全属性写在声明里，不靠参数名猜。只是附加元数据——给模型 /
/// MCP 的 JSON schema（[OpParam.toJsonSchema]）与 describe（[OpParam.toJson]）
/// 不变。
enum OpParamRole {
  /// 普通值。
  plain,

  /// 会被请求的外部地址，主机由调用方定（把数据发给已指派 LLM 以外的第三方，
  /// 撤销收不回，spec §5.2）：声明了它的操作必须先确认（[validateOpSpec]）。
  remoteUrl,

  /// 地址，但只发往固定主机（如 `url.probe` 只从 YouTube 地址里取 videoId 拼
  /// `www.youtube.com`）：调用方选不了目的主机。
  fixedHostUrl,

  /// 只存起来 / 只从已存列表里删的地址（书签、仓库表、白名单文本），操作本身不请求它。
  storedAddress,

  /// 本地条目引用（`book:<key>`、关联端点）或交给已装扩展自己解释的作品引用
  /// （扩展安装时用户已确认，D9）：不是由调用方定主机的网络地址。
  entityRef,
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
    this.role = OpParamRole.plain,
    this.httpOnly = false,
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

  /// 会被请求的外部地址（[OpParamRole.remoteUrl]）：声明即要求操作先确认。
  /// [httpOnly]：[OpArgs.parse] 只收 http(s) 且有主机的地址。
  const OpParam.remoteUrl(
    String name, {
    required String description,
    bool required = false,
    bool httpOnly = false,
  }) : this(
         name,
         OpParamType.string,
         description: description,
         required: required,
         role: OpParamRole.remoteUrl,
         httpOnly: httpOnly,
       );

  /// 只发往固定主机的地址（[OpParamRole.fixedHostUrl]）。
  const OpParam.fixedHostUrl(
    String name, {
    required String description,
    bool required = false,
    bool httpOnly = false,
  }) : this(
         name,
         OpParamType.string,
         description: description,
         required: required,
         role: OpParamRole.fixedHostUrl,
         httpOnly: httpOnly,
       );

  /// 只存不请求的地址（[OpParamRole.storedAddress]）。
  const OpParam.storedAddress(
    String name, {
    required String description,
    bool required = false,
    bool inPath = false,
  }) : this(
         name,
         OpParamType.string,
         description: description,
         required: required,
         inPath: inPath,
         role: OpParamRole.storedAddress,
       );

  /// 本地条目引用 / 扩展作品引用（[OpParamRole.entityRef]）。
  const OpParam.entityRef(
    String name, {
    required String description,
    bool required = false,
    bool inPath = false,
  }) : this(
         name,
         OpParamType.string,
         description: description,
         required: required,
         inPath: inPath,
         role: OpParamRole.entityRef,
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

  /// 语义角色（[OpParamRole]）。不进线上 schema。
  final OpParamRole role;

  /// 只收 http(s) 且有主机的地址（[OpArgs.parse] 校验，错误 400）。不进线上 schema。
  final bool httpOnly;

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

  /// 部分撤销：没被动过的部分回到执行前，之后又被改过的部分保留现值（[OpUndoOutcome.message] 列出是哪些）。
  partial,

  /// 撤销失败（对象已不存在等）。
  failed,
}

class OpUndoOutcome {
  const OpUndoOutcome.done([this.message]) : status = OpUndoStatus.done;
  const OpUndoOutcome.superseded([this.message])
    : status = OpUndoStatus.superseded;
  const OpUndoOutcome.failed([this.message]) : status = OpUndoStatus.failed;
  const OpUndoOutcome.partial([this.message]) : status = OpUndoStatus.partial;

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

  final Future<Map<String, Object?>> Function(OpArgs call)? capture;
  final OpUndoRecord Function(
    OpArgs call,
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

//// 一条可执行、进操作目录的操作：声明（[decl]）+ 实现 + 可用性 + 撤销。
///
/// 两种来路：
/// - [OpSpec.bind]（[FushiOp.fromSpec]）：声明与实现一处写完，控制通道路由
///   [route] 由它派生，HTTP 直连也经 [OpArgs.parse] 按声明校验参数；
/// - 旧路径 [FushiOp.new]：还没迁到 [OpSpec] 的域（经 [OpDescription.bind]）与
///   进程内操作，拿一条现成的 [CtlRoute]，声明由路由的 method / pattern 现拼。
///
/// 两种来路都在构造时跑同一组约束（id 形状、[validateOpSpec]、风险与撤销的对应），
/// 违反抛 [ArgumentError]——描述写错在组目录时就炸，不靠事后守卫。
class FushiOp {
  /// 旧路径（还没迁到 [OpSpec] 的域、进程内操作）：描述 + 现成路由。
  FushiOp({
    required String id,
    required String summary,
    required CtlRoute route,
    List<OpParam> params = const <OpParam>[],
    OpRisk risk = OpRisk.read,
    bool longRunning = false,
    bool needsUi = false,
    bool confirm = false,
    OpAvailability Function()? availability,
    OpUndo? undo,
    bool inProcessOnly = false,
    bool sensitiveResult = false,
    bool installsCode = false,
    Future<OpTaskStatus> Function(String taskId)? taskStatus,
    String? Function(Object? result)? taskIdOf,
    bool Function()? consentGranted,
  }) : this._(
         OpSpec(
           id: id,
           method: route.method,
           pattern: route.pattern,
           summary: summary,
           params: params,
           risk: risk,
           longRunning: longRunning,
           needsUi: needsUi,
           confirm: confirm,
           sensitiveResult: sensitiveResult,
           installsCode: installsCode,
           requiresReady: route.requiresReady,
           inProcessOnly: inProcessOnly,
         ),
         run: route.handler,
         legacyRoute: route,
         availability: availability,
         undo: undo,
         taskStatus: taskStatus,
         taskIdOf: taskIdOf,
         consentGranted: consentGranted,
       );

  /// 声明 + 实现（[OpSpec.bind]）。
  FushiOp.fromSpec(
    OpSpec decl, {
    required OpHandler handler,
    OpAvailability Function()? availability,
    OpUndo? undo,
    Future<OpTaskStatus> Function(String taskId)? taskStatus,
    String? Function(Object? result)? taskIdOf,
    bool Function()? consentGranted,
  }) : this._(
         decl,
         run: handler,
         availability: availability,
         undo: undo,
         taskStatus: taskStatus,
         taskIdOf: taskIdOf,
         consentGranted: consentGranted,
       );

  FushiOp._(
    this.decl, {
    required OpHandler run,
    CtlRoute? legacyRoute,
    this.availability,
    this.undo,
    this.taskStatus,
    this.taskIdOf,
    this.consentGranted,
  }) : _run = run {
    _validate();
    route =
        legacyRoute ??
        CtlRoute(
          decl.method,
          decl.pattern,
          (CtlCall call) =>
              _run(OpArgs.parse(decl, call, unknown: OpUnknownParams.warn)),
          requiresReady: decl.requiresReady,
          op: this,
        );
  }

  /// 声明（[OpSpec.bind] 来路的是 const 声明本身；旧路径的由路由现拼）。
  final OpSpec decl;

  final OpHandler _run;

  /// 控制通道路由：[OpSpec] 来路的由声明派生（HTTP 直连按声明解析参数后调同一个
  /// 实现）；旧路径的是传进来的那条。
  late final CtlRoute route;

  String get id => decl.id;
  String get summary => decl.summary;
  List<OpParam> get params => decl.params;
  OpRisk get risk => decl.risk;
  bool get longRunning => decl.longRunning;
  bool get needsUi => decl.needsUi;
  bool get confirm => decl.confirm;
  bool get inProcessOnly => decl.inProcessOnly;
  bool get sensitiveResult => decl.sensitiveResult;

  /// 平台 / 合规 / 模块开关 / 前置条件。null = 恒可用。
  final OpAvailability Function()? availability;

  final OpUndo? undo;

  /// [longRunning] 操作的状态读数：按执行结果里的 taskId 读一次（用现有的状态路由）。
  /// AI 运行时据此轮询，结束后在对话里报告并自动续一轮（spec §6.1）。
  final Future<OpTaskStatus> Function(String taskId)? taskStatus;

  /// 从执行结果里取任务 id；null = 默认取顶层的 `taskId` / `jobId`
  /// （[defaultOpTaskIdOf]）。
  final String? Function(Object? result)? taskIdOf;

  /// 首次确认（长期同意）：返回 true 表示用户已对这条需确认的操作给过一次同意并
  /// 记在本机，AI 助手不再逐次出确认卡（spec §5.2 补「首次确认」）。返回 false /
  /// null 时照 [risk] / [confirm] 确认；用户点了确认后由路由经表态参数记下同意。
  /// 只放宽 AI 助手进程内的确认卡：[FushiOpSpec.needsConfirmation] 仍按静态描述算，
  /// MCP / 远端宿主照旧逐次确认。
  final bool Function()? consentGranted;

  /// 用已解析的参数执行（进程内调用器、撤销、组合操作走这里；HTTP 走 [route]）。
  Future<Object?> run(OpArgs args) => _run(args);

  /// 此刻是否已有长期同意（见 [consentGranted]）。
  bool get consentAlreadyGranted => consentGranted?.call() ?? false;

  /// 这次执行结果对应的任务 id（没有返回 null）。
  String? taskIdFrom(Object? result) => (taskIdOf ?? defaultOpTaskIdOf)(result);

  OpAvailability currentAvailability() =>
      availability?.call() ?? const OpAvailability.available();

  FushiOpSpec get spec => FushiOpSpec(
    id: id,
    summary: summary,
    method: decl.method,
    pattern: decl.pattern,
    params: params,
    risk: risk,
    longRunning: longRunning,
    needsUi: needsUi,
    confirm: confirm,
    undoable: undo != null,
    inProcessOnly: inProcessOnly,
    sensitiveResult: sensitiveResult,
  );

  /// id 进 AI 线上名时把点换成 `__`：形状只许点分小写段（不含下划线）。
  static final RegExp _idShape = RegExp(
    r'^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$',
  );

  void _validate() {
    if (!_idShape.hasMatch(id)) {
      throw ArgumentError('操作 id 要点分小写：$id');
    }
    if (summary.trim().isEmpty) throw ArgumentError('$id：summary 为空');
    validateOpSpec(decl);
    if (risk == OpRisk.read && undo != null) {
      throw ArgumentError('$id：read 操作不该声明撤销');
    }
    if (risk == OpRisk.write && undo == null) {
      throw ArgumentError('$id：写操作必须可撤销（AI 写操作必须可回滚），撤销不了就标 irreversible');
    }
    if (risk == OpRisk.irreversible && undo != null) {
      throw ArgumentError('$id：能撤销就该是 write，不是 irreversible');
    }
  }
}

/// **旧路径**：一条路由的描述，按 `METHOD pattern` 挂到 [CtlRoute] 上（见
/// [OpCatalog.build]）。还没迁到 [OpSpec] 的域才用它；新操作一律写 [OpSpec] 并
/// [OpSpec.bind]（声明与实现同一处，不靠字符串配对）。剩余的旧路径数由
/// `fushi/test/ops/op_catalog_ratchet_guard_test.dart` 只减不增地卡住。
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
    this.installsCode = false,
    this.taskStatus,
    this.taskIdOf,
    this.consentGranted,
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

  /// 见 [OpSpec.installsCode]。
  final bool installsCode;

  /// 见 [FushiOp.taskStatus]。
  final Future<OpTaskStatus> Function(String taskId)? taskStatus;

  /// 见 [FushiOp.taskIdOf]。
  final String? Function(Object? result)? taskIdOf;

  /// 见 [FushiOp.consentGranted]。
  final bool Function()? consentGranted;

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
    installsCode: installsCode,
    taskStatus: taskStatus,
    taskIdOf: taskIdOf,
    consentGranted: consentGranted,
  );
}

/// 默认的任务 id 提取：结果顶层的 `taskId`，其次 `jobId`。
String? defaultOpTaskIdOf(Object? result) {
  if (result is! Map) return null;
  final Object? id = result['taskId'] ?? result['jobId'];
  return id == null ? null : '$id';
}
