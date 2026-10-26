/// 服务端当互联 host 时的「AI 助手」远端会话（spec
/// `docs/specs/2026-10-26-ai-operations-agent-design.md` §6.5 / D8）：手机把「下载执行
/// 设备」设成服务端、本机又没配 AI 时，整场 agent 会话在这里跑。
///
/// - 模型：服务端配置文件的 `ai:` 段（[ServerAiSettings]，指派给 [AiFeature.agent]）；
///   没配 → `no_provider`，**不发任何 AI 请求**。
/// - 工具：服务端自己描述的 admin 操作（`admin_ops.dart`），不追求与 app 一一对应。
/// - 记账与撤销：服务端自己的 Drift 库（同一张 `ai_agent_actions` 表，设备本地、不
///   同步）。可撤销写直接执行并记撤销载荷；不可逆操作由 agent loop 先出确认卡片，
///   用户点了才注入表态参数——模型填不出来。
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/sync/assistant/agent_assistant_host.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/assistant/video_acquisition_assistant_host.dart';
import 'package:fushi_server/src/admin/admin_ops.dart';
import 'package:fushi_server/src/config/server_ai_config.dart';
import 'package:fushi_server/src/config/server_config.dart';

/// 常驻工具（每轮都带上）；其余经 `ops.search` → `ops.describe` 现取。
const List<String> kServerAgentResidentOps = <String>[
  'server.status',
  'server.library.list',
  'server.download.list',
  'server.subscription.list',
  'server.settings.get',
  'server.job.list',
];

/// 参数里看起来像凭据的键：记账前抹掉（与 app 侧同一口径）。
final RegExp _kSecretKey = RegExp(
  r'(api_?key|token|secret|password|passwd|cookie|authorization|credential)',
  caseSensitive: false,
);

/// 抹掉参数里像凭据的值（递归）。
Map<String, Object?> redactServerAgentArgs(Map<String, Object?> args) =>
    <String, Object?>{
      for (final MapEntry<String, Object?> e in args.entries)
        e.key: _kSecretKey.hasMatch(e.key)
            ? '<redacted>'
            : e.value is Map
            ? redactServerAgentArgs(Map<String, Object?>.from(e.value! as Map))
            : e.value,
    };

/// 目录操作 → agent 工具描述（表态参数不进 schema）。
AgentToolSpec serverAgentToolSpecOf(FushiOp op) {
  final FushiOpSpec spec = op.spec;
  return AgentToolSpec(
    name: spec.id,
    description: spec.summary,
    parameters: spec.modelSchema(),
    risk: AgentToolRisk.fromName(spec.risk.name),
    confirm: spec.confirm,
    undoable: spec.undoable,
    longRunning: spec.longRunning,
  );
}

/// 把服务端操作目录适配成 [AgentToolbox]；写操作记进服务端库的 `ai_agent_actions`。
///
/// 与 app 的 `AiAgentToolbox` 同一套执行规则（app 那份依赖 Flutter 侧装配，服务端
/// 不能直接复用）：可逆操作直接注入表态参数、不可逆 / 强制确认的只在
/// [AgentToolInvocation.confirmed] 时注入；撤销按记录里的载荷调 [OpUndo.revert]。
class ServerAgentToolbox implements AgentToolbox {
  ServerAgentToolbox({
    required this.invoker,
    required this.db,
    DateTime Function()? clock,
    this.resident = kServerAgentResidentOps,
  }) : _clock = clock ?? DateTime.now;

  final OpInvoker invoker;
  final FushiDatabase db;
  final List<String> resident;
  final DateTime Function() _clock;

  OpCatalog get catalog => invoker.catalog;

  @override
  List<AgentToolSpec> residentTools() => <AgentToolSpec>[
    for (final String id in resident)
      if (_available(id) case final FushiOp op) serverAgentToolSpecOf(op),
  ];

  @override
  List<AgentToolSpec> searchTools(String query, {int limit = 12}) =>
      <AgentToolSpec>[
        for (final FushiOp op in catalog.search(query, limit: limit))
          serverAgentToolSpecOf(op),
      ];

  @override
  AgentToolSpec? describeTool(String name) {
    final FushiOp? op = _available(name);
    return op == null ? null : serverAgentToolSpecOf(op);
  }

  FushiOp? _available(String id) {
    final FushiOp? op = catalog[id];
    if (op == null || !op.currentAvailability().isAvailable) return null;
    return op;
  }

  @override
  Future<AgentToolResult> execute(AgentToolInvocation invocation) async {
    final FushiOp? op = catalog[invocation.name];
    if (op == null) return const AgentToolResult.error('unknown_tool');
    final FushiOpSpec spec = op.spec;
    if (spec.needsConfirmation && !invocation.confirmed) {
      // agent loop 保证不会走到这里；万一走到，绝不替用户表态。
      return const AgentToolResult.error('confirmation_required');
    }
    final Set<String> gates = <String>{
      if (spec.risk != OpRisk.read &&
          (invocation.confirmed || !spec.needsConfirmation))
        for (final OpParam p in spec.gateParams) p.name,
    };
    final OpInvocation result;
    try {
      result = await invoker.invoke(
        invocation.name,
        invocation.arguments,
        caller: OpCaller.model,
        grantedGates: gates,
        captureUndo: op.undo != null,
      );
    } on CtlFailure catch (failure) {
      if (spec.risk != OpRisk.read) {
        await _record(invocation, spec, resultCode: failure.code);
      }
      return AgentToolResult.error(failure.code, failure.message);
    } on Object catch (error) {
      if (spec.risk != OpRisk.read) {
        await _record(invocation, spec, resultCode: 'internal');
      }
      return AgentToolResult.error('internal', '$error');
    }
    if (spec.risk == OpRisk.read) {
      return AgentToolResult.ok(result.result, taskId: _taskId(result.result));
    }
    final int actionId = await _record(
      invocation,
      spec,
      resultCode: 'ok',
      undo: result.undo,
    );
    return AgentToolResult.ok(
      result.result,
      actionId: result.undo == null ? null : '$actionId',
      before: result.undo?.before,
      after: result.undo?.after,
      taskId: _taskId(result.result),
    );
  }

  Future<int> _record(
    AgentToolInvocation invocation,
    FushiOpSpec spec, {
    required String resultCode,
    OpUndoRecord? undo,
  }) => db.insertAiAgentAction(
    AiAgentActionsCompanion.insert(
      sessionId: invocation.sessionId,
      opId: invocation.name,
      argsJson: jsonEncode(redactServerAgentArgs(invocation.arguments)),
      risk: spec.risk.name,
      confirmation: invocation.confirmed ? 'user' : 'auto',
      resultCode: resultCode,
      undoPayloadJson: Value<String?>(
        undo == null ? null : jsonEncode(undo.payload),
      ),
      beforeText: Value<String?>(undo?.before),
      afterText: Value<String?>(undo?.after),
      createdAt: _clock().millisecondsSinceEpoch,
    ),
  );

  @override
  Future<AgentUndoResult> undo(String actionId) async {
    final int? id = int.tryParse(actionId);
    final AiAgentActionRow? row = id == null
        ? null
        : await db.getAiAgentAction(id);
    if (row == null || row.undoPayloadJson == null) {
      return const AgentUndoResult(AgentUndoStatus.notUndoable);
    }
    if (row.undoneAt != null) {
      return AgentUndoResult(
        row.undoStatus == 'superseded'
            ? AgentUndoStatus.superseded
            : AgentUndoStatus.done,
      );
    }
    final OpUndo? undo = catalog[row.opId]?.undo;
    if (undo == null) return const AgentUndoResult(AgentUndoStatus.notUndoable);
    final Object? payload = jsonDecode(row.undoPayloadJson!);
    if (payload is! Map) {
      return const AgentUndoResult(AgentUndoStatus.failed, 'bad_payload');
    }
    final OpUndoOutcome outcome;
    try {
      outcome = await undo.revert(Map<String, Object?>.from(payload));
    } on Object catch (error) {
      return AgentUndoResult(AgentUndoStatus.failed, '$error');
    }
    final AgentUndoStatus status = switch (outcome.status) {
      OpUndoStatus.done => AgentUndoStatus.done,
      OpUndoStatus.superseded => AgentUndoStatus.superseded,
      OpUndoStatus.failed => AgentUndoStatus.failed,
    };
    if (status != AgentUndoStatus.failed) {
      await db.markAiAgentActionUndone(
        row.id,
        undoneAt: _clock().millisecondsSinceEpoch,
        status: outcome.status.name,
      );
    }
    return AgentUndoResult(status, outcome.message);
  }

  static String? _taskId(Object? result) {
    if (result is! Map) return null;
    final Object? id = result['taskId'] ?? result['jobId'];
    return id == null ? null : '$id';
  }
}

/// 服务端那一家 AI 是否指派给了 AI 助手（null = 没配 / 没配全）。
AiProviderConfig? resolveServerAgentProvider(ServerAiSettings settings) =>
    settings.aiFeatureAssignments.resolve(
      AiFeature.agent,
      settings.aiProviders,
    );

/// 装配服务端的 AI 助手 provider。[dispatch] 现取：admin API 在 host 启动之后才建，
/// 还没接上时报 `not_ready`。[llmFactory] / [clock] 只给测试注入。
AgentAssistantHost createServerAgentAssistantHost({
  required ServerConfig Function() config,
  required FushiDatabase db,
  required AdminDispatch? Function() dispatch,
  AgentLlm Function(AiProviderConfig provider)? llmFactory,
  DateTime Function()? clock,
}) {
  final ServerAiSettings settings = ServerAiSettings(() => config().ai);
  OpInvoker? cached;
  AdminDispatch? cachedFor;
  OpInvoker? invoker() {
    final AdminDispatch? current = dispatch();
    if (current == null) return null;
    if (cached != null && identical(cachedFor, current)) return cached;
    cachedFor = current;
    return cached = OpInvoker(buildServerAdminOpCatalog(() => current));
  }

  Future<String?> blocker() async {
    // 先判 AI：没指派时什么都不必看，更不会走到任何 AI 调用。
    if (resolveServerAgentProvider(settings) == null) {
      return kHostAssistantReasonNoProvider;
    }
    if (invoker() == null) return kHostAssistantReasonNotReady;
    return null;
  }

  return AgentAssistantHost(
    blocker: blocker,
    source: 'server',
    clock: clock,
    toolCount: () => invoker()?.catalog.available().length ?? 0,
    open: (String locale) async {
      final AiProviderConfig? provider = resolveServerAgentProvider(settings);
      final OpInvoker? ops = invoker();
      if (provider == null) {
        throw const HostAssistantUnavailable(kHostAssistantReasonNoProvider);
      }
      if (ops == null) {
        throw const HostAssistantUnavailable(kHostAssistantReasonNotReady);
      }
      AiChatClient? client;
      final AgentLlm llm;
      if (llmFactory != null) {
        llm = llmFactory(provider);
      } else {
        client = AiChatClient();
        llm = AiClientAgentLlm(client: client, provider: provider);
      }
      return AgentSessionParts(
        llm: llm,
        toolbox: ServerAgentToolbox(invoker: ops, db: db, clock: clock),
        release: () => client?.close(),
      );
    },
  );
}
