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
