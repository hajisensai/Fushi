import 'package:flutter/foundation.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';

/// AI 助手对话界面（`AiAgentConversation`）依赖的控制器面：本机会话
/// （`AiAgentController`）与远端会话（`RemoteAiAgentSession`，整场在已配对电脑 /
/// 服务端上跑，spec §6.5）各实现一份，界面不区分两者。
///
/// 监听约定：条目、运行状态、待答卡片任何一样变了都要通知监听者（本机控制器把
/// 待答卡片的变化也并进来）。
abstract interface class AiAgentConversationController implements Listenable {
  /// 当前对话的条目（没有会话时为空）。
  List<AgentEntry> get entries;

  /// 本场还能撤销的写操作数。
  int get undoableCount;

  /// 本场累计 token 用量。
  int get totalTokens;

  /// 本场累计 token 用量的分项（输入 / 输出 / 缓存读写）。
  AiChatUsage get usage;

  /// 本场累计费用（币种 → 金额）；执行设备的提供商没填单价时为空。
  Map<String, double> get cost;

  /// 一轮正在跑（模型请求 / 工具执行 / 等用户点卡片）。
  bool get running;

  /// 有一张确认卡片 / 候选卡片在等用户点。
  bool get awaitingConfirm;
  bool get awaitingChoice;

  /// 作答确认卡片 / 候选卡片（null = 都不是）。
  void answerConfirm(bool approved);
  void answerChoice(String? id);

  /// 执行这场对话的模型能不能收图（提供商勾了「支持图片输入」）。远端会话按
  /// 不能处理：截图只在本机发给本机配的模型。
  bool get acceptsImages;

  /// 说一句话；[images] 只在 [acceptsImages] 时才给。本机没指派提供商时抛
  /// `StateError('ai_agent_no_provider')`。
  Future<void> send(
    String text, {
    AgentUiContext? context,
    List<AiChatImage> images = const <AiChatImage>[],
  });

  Future<AgentUndoResult> undoEntry(String entryId);

  Future<List<AgentUndoResult>> undoAll();

  /// 停止当前一轮；待答卡片按「拒绝 / 取消」收尾。
  void cancel();

  /// 开一场新对话。
  Future<void> newSession();

  /// 在哪台设备上执行（远端会话 = 那台设备的名字；本机 = null）。
  String? get executorLabel;
}
