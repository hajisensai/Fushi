import 'dart:async';
import 'dart:convert';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';

import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 终端版 AI 助手（`fushi_cli ai ask / undo / log`，spec §8 P2）的控制通道路由。
///
/// 每次 `ask` 开一场不挂界面的会话（[AiAgentController.headless]），与 app 内的 AI
/// 浮层互不干扰；不可逆 / 装扩展的确认由终端 y/N 经 `answer` 作答——与 app 内一样，
/// 模型填不出表态参数。这些路由本身**不进操作目录**（AI 不能调 AI，见棘轮守卫的
/// 豁免表）。
List<CtlRoute> buildAiAgentCtlRoutes(OpContext context) {
  final Map<String, AiAgentController> sessions = <String, AiAgentController>{};

  AiAgentController session(CtlCall call) {
    final String id = call.params['id'] ?? '';
    final AiAgentController? controller = sessions[id];
    if (controller == null) throw CtlFailure.notFound('没有这场对话：$id');
    return controller;
  }

  return <CtlRoute>[
    CtlRoute.post('/api/admin/ai/agent/ask', (CtlCall call) async {
      final String text = call.requireString('text');
      final String? resumeId = call.optString('sessionId');
      AiAgentController? controller = resumeId == null
          ? null
          : sessions[resumeId];
      if (controller == null) {
        controller = AiAgentController.headless(context);
        if (!controller.hasProvider) {
          controller.dispose();
          throw const CtlFailure.rejected(
            'AI 助手还没指派提供商：先在「设置 › 模型 › LLM」指派'
            '（fushi_cli ai assign agent <提供商>）',
          );
        }
        if (resumeId != null && !await controller.resume(resumeId)) {
          controller.dispose();
          throw CtlFailure.notFound('没有这场对话：$resumeId');
        }
      }
      if (controller.running) {
        throw const CtlFailure.conflict('上一句还在执行');
      }
      final AgentSession agent = controller.ensureSession(scene: 'cli');
      sessions[agent.id] = controller;
      // 不等这一轮跑完：终端轮询 `sessions/:id` 渲染进度并回答确认卡片。
      unawaited(controller.send(text));
      return <String, Object?>{'sessionId': agent.id};
    }),
    CtlRoute.get('/api/admin/ai/agent/sessions/:id', (CtlCall call) async {
      final AiAgentController controller = session(call);
      final AgentSession? agent = controller.session;
      final List<AgentEntry> entries = agent?.entries ?? const <AgentEntry>[];
      String? pendingId(AgentEntryKind kind) {
        for (int i = entries.length - 1; i >= 0; i--) {
          if (entries[i].kind == kind) {
            return entries[i].status == AgentEntryStatus.pending
                ? entries[i].id
                : null;
          }
        }
        return null;
      }

      final String? confirm = controller.host.awaitingConfirm
          ? pendingId(AgentEntryKind.confirm)
          : null;
      final String? choice = controller.host.awaitingChoice
          ? pendingId(AgentEntryKind.choice)
          : null;
      return <String, Object?>{
        'sessionId': agent?.id,
        'running': controller.running,
        'tokens': agent?.totalTokens ?? 0,
        'entries': <Object?>[
          for (final AgentEntry e in entries) e.toJson(),
        ],
        if (confirm != null)
          'pending': <String, Object?>{'kind': 'confirm', 'entryId': confirm},
        if (choice != null)
          'pending': <String, Object?>{'kind': 'choice', 'entryId': choice},
      };
    }),
    CtlRoute.post('/api/admin/ai/agent/sessions/:id/answer', (
      CtlCall call,
    ) async {
      final AiAgentController controller = session(call);
      if (controller.host.awaitingConfirm) {
        final bool? approve = call.optBool('approve');
        if (approve == null) throw const CtlFailure.badRequest('approve 缺失');
        controller.host.answerConfirm(approve);
        return null;
      }
      if (controller.host.awaitingChoice) {
        controller.host.answerChoice(call.optString('choice'));
        return null;
      }
      throw const CtlFailure.conflict('没有待回答的卡片');
    }),
    CtlRoute.post('/api/admin/ai/agent/sessions/:id/cancel', (
      CtlCall call,
    ) async {
      session(call).cancel();
      return null;
    }),
    CtlRoute.get('/api/admin/ai/agent/actions', (CtlCall call) async {
      final FushiDatabase db = context.appModel.database;
      final List<AiAgentActionRow> rows = await db.listAiAgentActions(
        sessionId: call.optString('sessionId'),
        limit: call.optInt('limit') ?? 50,
      );
      return <String, Object?>{
        'actions': <Object?>[for (final AiAgentActionRow r in rows) _actionJson(r)],
      };
    }),
    CtlRoute.post('/api/admin/ai/agent/actions/:id/undo', (
      CtlCall call,
    ) async {
      final AiAgentController controller = AiAgentController.headless(context);
      try {
        final AgentUndoResult result = await controller.toolbox.undo(
          call.params['id'] ?? '',
        );
        if (result.status == AgentUndoStatus.notUndoable) {
          throw CtlFailure.rejected('这一条不可撤销：${call.params['id']}');
        }
        return <String, Object?>{
          'status': result.status.name,
          if (result.message != null) 'message': result.message,
          'ok': result.status != AgentUndoStatus.failed,
        };
      } finally {
        controller.dispose();
      }
    }),
  ];
}

Map<String, Object?> _actionJson(AiAgentActionRow r) => <String, Object?>{
  'id': r.id,
  'sessionId': r.sessionId,
  'op': r.opId,
  'args': _decode(r.argsJson),
  'risk': r.risk,
  'confirmation': r.confirmation,
  'result': r.resultCode,
  'undoable': r.undoPayloadJson != null && r.undoneAt == null,
  if (r.beforeText != null) 'before': r.beforeText,
  if (r.afterText != null) 'after': r.afterText,
  'createdAt': r.createdAt,
  if (r.undoneAt != null) 'undoneAt': r.undoneAt,
  if (r.undoStatus != null) 'undoStatus': r.undoStatus,
};

Object? _decode(String json) {
  try {
    return jsonDecode(json);
  } on FormatException {
    return json;
  }
}
