/// AI 助手的工具抽象（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §5、§6.1）。引擎只认这层抽象：app 把操作目录（`FushiOp`）适配成
/// [AgentToolbox]，服务端将来同样适配自己的 admin 操作。
library;

/// 工具的风险级（与 `fushi_cli` 的 `OpRisk` 一一对应）。
enum AgentToolRisk {
  read,
  write,
  irreversible;

  static AgentToolRisk fromName(String? name) {
    for (final AgentToolRisk risk in values) {
      if (risk.name == name) return risk;
    }
    return AgentToolRisk.read;
  }
}

/// 一个工具的描述。[name] 是目录 id（点分，如 `settings.set`）；发给模型时由
/// [agentWireToolName] 换成各家都认的形状。
class AgentToolSpec {
  const AgentToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
    this.risk = AgentToolRisk.read,
    this.confirm = false,
    this.undoable = false,
    this.longRunning = false,
  });

  final String name;
  final String description;

  /// JSON Schema（object），**已去掉**用户表态参数。
  final Map<String, Object?> parameters;
  final AgentToolRisk risk;

  /// 即使可撤销也要先确认（装扩展，spec D9）。
  final bool confirm;
  final bool undoable;
  final bool longRunning;

  /// 执行前要不要用户在 UI 上点确认。只由描述决定，模型改不了（spec §10）。
  bool get needsConfirmation => risk == AgentToolRisk.irreversible || confirm;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'description': description,
    'parameters': parameters,
    'risk': risk.name,
    if (confirm) 'confirm': true,
    if (undoable) 'undoable': true,
    if (longRunning) 'longRunning': true,
  };

  static AgentToolSpec fromJson(Map<String, Object?> json) => AgentToolSpec(
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    parameters: Map<String, Object?>.from(
      json['parameters'] as Map? ?? const <String, Object?>{},
    ),
    risk: AgentToolRisk.fromName(json['risk'] as String?),
    confirm: json['confirm'] == true,
    undoable: json['undoable'] == true,
    longRunning: json['longRunning'] == true,
  );
}

/// 目录 id → 发给模型的工具名。OpenAI 只认 `^[a-zA-Z0-9_-]{1,64}$`，点换成 `__`。
String agentWireToolName(String id) => id.replaceAll('.', '__');

/// 发给模型的工具名 → 目录 id。
String agentToolIdFromWire(String wire) => wire.replaceAll('__', '.');

/// 降级（无原生 tool calling）协议里一条工具描述最多带多少字摘要：完整描述与
/// 参数 schema 由 `ops__describe` 按需取，常驻清单只当索引（反馈 GewyVIt5oo）。
const int kAgentCompactDescriptionChars = 140;

/// 把参数 JSON Schema 压成一行签名，如 `(id: string, value: any, limit?: integer)`。
///
/// 降级协议每轮都把工具清单塞进系统提示；整份 schema（属性说明、嵌套 items）
/// 一条就上千字，十几条常驻工具就能把上下文 4k 的本地模型撑爆。签名只留参数名、
/// 是否必填、类型与枚举值——够模型直接调常驻工具；要细节时调 `ops__describe`。
String agentCompactSignature(Map<String, Object?> schema) {
  final Object? props = schema['properties'];
  if (props is! Map || props.isEmpty) return '()';
  final Set<String> required = <String>{
    if (schema['required'] case final List<Object?> list)
      for (final Object? e in list) '$e',
  };
  final List<String> parts = <String>[
    for (final MapEntry<Object?, Object?> e in props.entries)
      '${e.key}${required.contains('${e.key}') ? '' : '?'}: '
          '${_compactType(e.value)}',
  ];
  return '(${parts.join(', ')})';
}

String _compactType(Object? schema) {
  if (schema is! Map) return 'any';
  final Object? enumValues = schema['enum'];
  if (enumValues is List && enumValues.isNotEmpty) {
    return enumValues.map((Object? v) => _scalar(v)).join('|');
  }
  final Object? type = schema['type'];
  return switch (type) {
    'array' => '${_compactType(schema['items'])}[]',
    'object' => 'object',
    final String name => name,
    final List<Object?> names => names.join('|'),
    _ => 'any',
  };
}

/// 枚举值的签名写法：字符串带引号，其余原样。
String _scalar(Object? value) => value is String ? '"$value"' : '$value';

/// 一条描述截到 [kAgentCompactDescriptionChars]（优先截在第一句末尾）。
String agentCompactDescription(String description) {
  final String text = description.trim().replaceAll(RegExp(r'\s+'), ' ');
  final int sentenceEnd = text.indexOf('. ');
  final String first = sentenceEnd > 0
      ? text.substring(0, sentenceEnd + 1)
      : text;
  if (first.length <= kAgentCompactDescriptionChars) return first;
  return '${first.substring(0, kAgentCompactDescriptionChars - 1)}…';
}

/// 一次工具执行请求。
class AgentToolInvocation {
  const AgentToolInvocation({
    required this.sessionId,
    required this.name,
    required this.arguments,
    this.confirmed = false,
  });

  final String sessionId;
  final String name;
  final Map<String, Object?> arguments;

  /// 用户已在确认卡片上点了同意：工具箱据此注入表态参数。
  final bool confirmed;
}

/// 一次工具执行的结果。
class AgentToolResult {
  const AgentToolResult.ok(
    this.data, {
    this.actionId,
    this.before,
    this.after,
    this.taskId,
    this.userPreview,
  }) : errorCode = null,
       errorMessage = null;

  const AgentToolResult.error(String this.errorCode, [this.errorMessage])
    : data = null,
      actionId = null,
      before = null,
      after = null,
      taskId = null,
      userPreview = null;

  /// 可 JSON 编码的结果（交给模型前包进不可信数据块）。
  final Object? data;

  /// 写操作落进操作记录的 id（可撤销时 UI 据此出「撤销」按钮）。
  final String? actionId;

  /// 「改前 → 改后」（可空）。
  final String? before;
  final String? after;

  /// 长任务 id（`task.get` / `task.wait` 用）。
  final String? taskId;

  /// 只给用户看的结果（对话里折叠显示）；非空时 [data] 是交给模型的脱敏版本
  /// （一次性凭据类结果，见 `FushiOpSpec.sensitiveResult`）。
  final String? userPreview;

  final String? errorCode;
  final String? errorMessage;

  bool get isError => errorCode != null;
}

/// 撤销结果（与 `fushi_cli` 的 `OpUndoStatus` 对应）。
enum AgentUndoStatus { done, superseded, failed, notUndoable }

class AgentUndoResult {
  const AgentUndoResult(this.status, [this.message]);

  final AgentUndoStatus status;
  final String? message;
}

/// 工具箱：app 把操作目录适配成它。
abstract interface class AgentToolbox {
  /// 常驻工具（每轮都带上，约 15 个）。
  List<AgentToolSpec> residentTools();

  /// 按自然语言检索目录（`ops.search`）。
  List<AgentToolSpec> searchTools(String query, {int limit = 12});

  /// 按 id 取完整描述（`ops.describe`）；不存在或当前不可用返回 null。
  AgentToolSpec? describeTool(String name);

  /// 执行。参数校验失败、对象不存在等以 [AgentToolResult.error] 返回，不抛。
  Future<AgentToolResult> execute(AgentToolInvocation invocation);

  /// 撤销一条操作记录。
  Future<AgentUndoResult> undo(String actionId);
}

/// 确认卡片要展示的内容。
class AgentConfirmRequest {
  const AgentConfirmRequest({
    required this.tool,
    required this.arguments,
    this.reason,
  });

  final AgentToolSpec tool;
  final Map<String, Object?> arguments;

  /// 模型给的执行理由（不可信，只作展示）。
  final String? reason;
}

/// `ui.ask_choice` 的一项候选。
class AgentChoiceOption {
  const AgentChoiceOption({required this.id, required this.label, this.detail});

  final String id;
  final String label;
  final String? detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    if (detail != null) 'detail': detail,
  };

  static AgentChoiceOption fromJson(Map<String, Object?> json) =>
      AgentChoiceOption(
        id: '${json['id'] ?? ''}',
        label: '${json['label'] ?? json['id'] ?? ''}',
        detail: json['detail'] as String?,
      );
}

/// 需要界面的那几件事：确认卡片、候选卡片。由 AI 页 / 终端实现。
abstract interface class AgentHost {
  /// 不可逆 / 强制确认的操作执行前调用。返回 true = 用户点了同意。
  Future<bool> confirm(AgentConfirmRequest request);

  /// 把候选渲染成可点的卡片，返回用户选中的 id；用户取消返回 null。
  Future<String?> askChoice(String prompt, List<AgentChoiceOption> options);
}

/// 技能（spec §6.3）：确定性的多步配方。模型只负责选技能、填参数，步骤由代码编排；
/// 每一步经 [AgentSkillContext.call] 照常走确认 / 记账 / 撤销。
abstract interface class AgentSkill {
  /// 技能的工具描述（name 用 `skill.<名字>`）。
  AgentToolSpec get spec;

  /// 跑完返回给模型的汇总（可 JSON 编码）；整体失败抛 [AgentSkillFailure]。
  Future<Object?> run(AgentSkillContext context, Map<String, Object?> args);
}

/// 技能整体失败（参数不对、前置条件不满足）。单步失败不抛，记进汇总。
class AgentSkillFailure implements Exception {
  const AgentSkillFailure(this.code, [this.message]);

  final String code;
  final String? message;
}

/// 技能能做的事：调目录工具、出候选卡片。
abstract interface class AgentSkillContext {
  /// 调一个目录工具（与模型调用同一套确认 / 记账 / 撤销）。
  /// [userChoseThisStep]：用户刚在本技能出的候选卡片上点选了这一步本身，那张卡即
  /// 确认，不再追加确认卡。
  Future<AgentToolResult> call(
    String toolId,
    Map<String, Object?> args, {
    bool userChoseThisStep = false,
  });

  /// 出候选卡片等用户点；取消返回 null。
  Future<String?> askChoice(String prompt, List<AgentChoiceOption> options);

  /// 用户按了停止：技能应尽快收尾。
  bool get cancelled;
}

/// 工具箱可选实现：提供技能。
abstract interface class AgentSkillProvider {
  List<AgentSkill> skills();
}
