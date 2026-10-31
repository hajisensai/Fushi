import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';

/// 一场会话的默认标题：首条用户消息的摘要（[aiAgentSessionAutoTitle]）。还没有
/// 用户消息时退到第一条条目的文字。
String aiAgentSessionTitleOf(AgentSession session) {
  if (session.entries.isEmpty) return '';
  final AgentEntry first = session.entries.firstWhere(
    (AgentEntry e) => e.kind == AgentEntryKind.user,
    orElse: () => session.entries.first,
  );
  return aiAgentSessionAutoTitle(first.text);
}

/// 把一场会话写进本机对话存档 `ai_agent_sessions`。本机 AI 页（`AiAgentController`）
/// 与互联 host 上替远端跑的会话（`buildAppAgentAssistantHost`）共用这一个写入口：
/// 同一种标题取法、同一套「首次落库定标题与归属、之后只更新内容」的规矩
/// （[FushiDatabase.saveAiAgentSessionSnapshot]）。没有条目的空会话不落库。
///
/// [profileUid] 省略 = 首次落库时按当前激活 Profile 盖戳。
Future<void> saveAiAgentSessionArchive(
  FushiDatabase database,
  AgentSession session, {
  required String scene,
  required DateTime now,
  String? profileUid,
}) async {
  if (session.entries.isEmpty) return;
  await database.saveAiAgentSessionSnapshot(
    id: session.id,
    title: aiAgentSessionTitleOf(session),
    scene: scene,
    payloadJson: jsonEncode(session.toJson()),
    totalTokens: session.totalTokens,
    createdAt: session.entries.first.createdAt,
    updatedAt: now.millisecondsSinceEpoch,
    profileUid: profileUid,
  );
}
