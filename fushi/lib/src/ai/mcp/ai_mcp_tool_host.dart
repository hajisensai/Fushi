import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';

import 'package:fushi/src/ai/agent/ai_agent_toolbox.dart';

/// 外部 AI 的操作写进 `ai_agent_actions` 时会话 id 的前缀（`mcp:<MCP 会话 id>`）：
/// 「AI 操作记录」按会话分组列出、可撤销；`undo_action` 只认调用方这条连接自己
/// 的会话 id（[aiMcpActionSessionIdOf]）。
const String kAiMcpSessionPrefix = 'mcp:';

/// 一条 MCP 连接的操作记在 `ai_agent_actions` 里的会话 id。没带 / 带了不认识的
/// 会话 id 的调用一律是 [kMcpAnonymousSessionId]：它们彼此分不开，共用
/// `mcp:anonymous` 这一个名下（能互相撤销对方的记录——都持同一个配对令牌）。
String aiMcpActionSessionIdOf(McpCallContext context) =>
    '$kAiMcpSessionPrefix${context.sessionId}';

/// 撤销工具名。目录工具名只由「小写字母 / 数字 / `-` / `__`」组成（id 的点换成
/// `__`），单个下划线永远撞不上。
const String kAiMcpUndoTool = 'undo_action';

/// 外部 AI 要执行一条需要用户点头的操作时交给 app 的内容。
class AiMcpConfirmRequest {
  const AiMcpConfirmRequest({
    required this.client,
    required this.op,
    required this.arguments,
    this.cancellation = const McpCancellation.never(),
  });

  /// 客户端自报的身份（不可信，只作展示）。
  final McpClientInfo client;
  final FushiOpSpec op;

  /// 已过参数校验的参数（不含表态参数）。
  final Map<String, Object?> arguments;

  /// 客户端放弃了这次调用（MCP `notifications/cancelled`）：还在排队的确认不再
  /// 弹，已弹出的关掉，结论按 [AiMcpConfirmOutcome.cancelled]。
  final McpCancellation cancellation;
}

/// 确认的结论。
enum AiMcpConfirmOutcome {
  approved,
  declined,

  /// 超时没人答，按拒绝处理。
  expired,

  /// app 没有可弹窗的界面（还在启动 / 窗口已销毁），按拒绝处理。
  unavailable,

  /// 客户端在用户回答前取消了这次调用：不执行。
  cancelled,
}

typedef AiMcpConfirm =
    Future<AiMcpConfirmOutcome> Function(AiMcpConfirmRequest request);

/// 把操作目录适配成 MCP 工具（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §10 的「以后可以加」，所有者 2026-10-31 要求做完）。
///
/// - 清单：目录里当前可用、可对外的每条操作一个工具，由描述生成（[mcpToolOf]），
///   不另写一份；外加 [kAiMcpUndoTool]。
/// - 执行：一律以**模型**身份经 [AiAgentToolbox] 调用——与 app 内 AI 助手同一套
///   表态参数注入、凭据脱敏、记账与撤销。外部调用方填不出表态参数（`OpCaller.model`
///   见到就 400），也改不了风险级：`needsConfirmation` 的操作（不可逆、装扩展）先在
///   app 内弹确认（[confirm]），用户点了才注入表态参数执行。
/// - 记账：写操作进 `ai_agent_actions`（会话 id `mcp:<会话>`），「AI 操作记录」页
///   能看到、能撤销；`undo_action` 也能撤。
class AiMcpToolHost implements McpToolHost {
  AiMcpToolHost({
    required AiAgentToolbox Function() toolbox,
    required this.confirm,
    required this.isReady,
  }) : _toolboxFactory = toolbox;

  final AiAgentToolbox Function() _toolboxFactory;
  AiAgentToolbox? _toolbox;

  /// app 内确认（弹窗）。
  final AiMcpConfirm confirm;

  /// AppModel 初始化完成：之前目录的可用性谓词读不了 app 状态。
  final bool Function() isReady;

  AiAgentToolbox get _box {
    if (!isReady()) {
      throw StateError('Fushi is still starting up; retry in a moment.');
    }
    return _toolbox ??= _toolboxFactory();
  }

  @override
  List<McpTool> listTools() {
    final AiAgentToolbox box = _box;
    final List<FushiOp> ops =
        box.catalog
            .available()
            .where((FushiOp op) => mcpExposesOp(op.spec))
            .toList()
          ..sort((FushiOp a, FushiOp b) => a.id.compareTo(b.id));
    return <McpTool>[
      for (final FushiOp op in ops) mcpToolOf(op.spec),
      _undoTool,
    ];
  }

  static const McpTool _undoTool = McpTool(
    name: kAiMcpUndoTool,
    title: 'undo_action',
    description:
        'Undo one change you made earlier through this MCP connection (this '
        'MCP session), by the actionId returned in that tool result. Changes '
        'made through other connections or by the in-app assistant cannot be '
        'undone here. If the user changed the same thing again afterwards, '
        'their change is kept and the undo reports "superseded".',
    inputSchema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'actionId': <String, Object?>{
          'type': 'string',
          'description': 'actionId from the earlier tool result.',
        },
      },
      'required': <String>['actionId'],
    },
  );

  @override
  Future<McpToolResult> callTool(
    String name,
    Map<String, Object?> arguments,
    McpCallContext context,
  ) async {
    final AiAgentToolbox box = _box;
    if (name == kAiMcpUndoTool) return _undo(box, arguments, context);
    final String id = mcpOpIdOf(name);
    final FushiOp? op = box.catalog[id];
    // 进程内专有 / 含一次性凭据的不在清单里，按不认识处理；不可用的（模块关了…）
    // 由 [AiAgentToolbox] 按与清单同一判据拒绝（下面的预检与 execute）。
    if (op == null || !mcpExposesOp(op.spec)) throw McpUnknownTool(name);
    final FushiOpSpec spec = op.spec;
    bool confirmed = false;
    if (spec.needsConfirmation) {
      // 先过可用性与参数校验，别为一个注定被拒的调用打扰用户。
      final AgentToolResult? unavailable = box.unavailableResultOf(op);
      if (unavailable != null) return _errorOf(unavailable);
      try {
        box.invoker.buildCall(op, arguments, caller: OpCaller.model);
      } on CtlFailure catch (failure) {
        return McpToolResult.error(failure.code, failure.message);
      }
      if (context.cancellation.isCancelled) return _cancelled;
      final AiMcpConfirmOutcome outcome = await confirm(
        AiMcpConfirmRequest(
          client: context.client,
          op: spec,
          arguments: arguments,
          cancellation: context.cancellation,
        ),
      );
      switch (outcome) {
        case AiMcpConfirmOutcome.approved:
          confirmed = true;
        case AiMcpConfirmOutcome.declined:
          return const McpToolResult.error(
            'user_declined',
            'The user declined this operation in the Fushi app.',
          );
        case AiMcpConfirmOutcome.expired:
          return const McpToolResult.error(
            'confirmation_expired',
            'Nobody answered the confirmation in the Fushi app in time.',
          );
        case AiMcpConfirmOutcome.unavailable:
          return const McpToolResult.error(
            'confirmation_unavailable',
            'The Fushi app cannot show a confirmation right now.',
          );
        case AiMcpConfirmOutcome.cancelled:
          return _cancelled;
      }
    }
    // 客户端已放弃（确认期间、或还没轮到执行就取消了）：不执行。客户端重试时
    // 不会因为旧调用在背后照样跑完而做两遍。
    if (context.cancellation.isCancelled) return _cancelled;
    final AgentToolResult result = await box.execute(
      AgentToolInvocation(
        sessionId: aiMcpActionSessionIdOf(context),
        name: id,
        arguments: arguments,
        confirmed: confirmed,
      ),
    );
    if (result.isError) return _errorOf(result);
    return McpToolResult.ok(<String, Object?>{
      'result': result.data,
      if (result.actionId != null) 'actionId': result.actionId,
      if (spec.risk != OpRisk.read) 'undoable': result.actionId != null,
      if (result.before != null) 'before': result.before,
      if (result.after != null) 'after': result.after,
      if (result.taskId != null) 'taskId': result.taskId,
    });
  }

  static const McpToolResult _cancelled = McpToolResult.error(
    'cancelled',
    'The client cancelled this call; it was not executed.',
  );

  static McpToolResult _errorOf(AgentToolResult result) =>
      McpToolResult.error(result.errorCode!, result.errorMessage);

  Future<McpToolResult> _undo(
    AiAgentToolbox box,
    Map<String, Object?> arguments,
    McpCallContext context,
  ) async {
    final Object? raw = arguments['actionId'];
    final int? id = raw is int ? raw : int.tryParse('${raw ?? ''}'.trim());
    if (id == null) {
      return const McpToolResult.error('bad_request', 'actionId is required');
    }
    final AiAgentActionRow? row = await box.database.getAiAgentAction(id);
    // 只撤这条连接自己做的：别的 MCP 连接、app 内 AI 助手的记录由用户在 app 的
    // 「AI 操作记录」里撤。别人的记录与不存在一样回 not_found，不透露有没有。
    if (row == null || row.sessionId != aiMcpActionSessionIdOf(context)) {
      return McpToolResult.error('not_found', 'No such action: $id');
    }
    final AgentUndoResult result = await box.undo('$id');
    return switch (result.status) {
      AgentUndoStatus.done => McpToolResult.ok(<String, Object?>{
        'status': 'done',
        if (result.message != null) 'message': result.message,
      }),
      AgentUndoStatus.superseded => McpToolResult.ok(<String, Object?>{
        'status': 'superseded',
        'message':
            result.message ??
            'Changed again afterwards; the later change was kept.',
      }),
      AgentUndoStatus.notUndoable => McpToolResult.error(
        'not_undoable',
        'This action cannot be undone.',
      ),
      AgentUndoStatus.failed => McpToolResult.error(
        'undo_failed',
        result.message,
      ),
    };
  }
}
