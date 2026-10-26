/// app 当互联 host 时的「AI 助手」远端会话（spec
/// `docs/specs/2026-10-26-ai-operations-agent-design.md` §6.5）：手机没配 AI、但
/// 「下载执行设备」指向这台电脑时，整场 agent 会话在这里跑。
///
/// 与本机 AI 页同一套零件：工具箱是 [AiAgentToolbox]（同一份操作目录，写操作照常
/// 记进**本机** `ai_agent_actions`、可在本机「AI 操作记录」页撤销），模型是本机给
/// 「AI 助手」指派的提供商（[resolveAiAgentProvider]）。没指派 → `no_provider`，
/// 不发任何 AI 请求。只在进程内有意义的操作（`nav.open` 会在**这台**电脑上开设置
/// 页）不给远端用：远端用户看不见这台电脑的屏幕。
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/sync/assistant/agent_assistant_host.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/assistant/video_acquisition_assistant_host.dart';

import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/ai/agent/ai_agent_toolbox.dart';
import 'package:fushi/src/media/video/acquisition/app_video_acquisition_assembly.dart'
    show createVideoAcquisitionAssistantHost;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/src/ops/app_op_context.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';

/// 远端会话存进对话存档时的场景名（操作记录页据此分组）。
const String kAiAgentRemoteScene = 'remote';

/// 互联 host 的全部助手会话：AI 下视频 + AI 助手并存（`/api/assistant`）。
HostAssistantProvider createAppAssistantHost(AppModel appModel) =>
    CompositeHostAssistantProvider(<String, HostAssistantProvider>{
      // 第一个放 AI 下视频：老客户端只认顶层 reason，它取第一个 feature 的。
      kHostAssistantFeatureVideoAcquire: createVideoAcquisitionAssistantHost(
        appModel,
      ),
      kHostAssistantFeatureAgent: createAppAgentAssistantHost(appModel),
    });

/// AI 助手的远端会话 provider（生产装配）：进程级 [appOpContext] 的操作目录 + 本机
/// 偏好里的 AI 指派 + 本机数据库。
AgentAssistantHost createAppAgentAssistantHost(AppModel appModel) {
  OpInvoker? cached;
  OpContext? cachedFor;
  return createAgentAssistantHostWith(
    aiModuleEnabled: () => isAiModuleEnabled(appModel.moduleVisibility),
    settings: appModel.prefsRepo,
    database: appModel.database,
    invoker: () {
      final OpContext? ctx = appOpContext;
      if (ctx == null || !appModel.isInitialised) return null;
      if (cached != null && identical(cachedFor, ctx)) return cached;
      cachedFor = ctx;
      // 不带 buildAiAgentInProcessOps：那些操作作用在这台电脑的界面上。
      return cached = buildInProcessOpInvoker(ctx);
    },
  );
}

/// 同 [createAppAgentAssistantHost]，依赖全部可注入（测试用 stub 模型与假目录）。
///
/// - [aiModuleEnabled]：用户关了 AI 模块 → `disabled`（不是「没配 AI」）；
/// - [settings]：解析「AI 助手」指派，没指派 → `no_provider`，不发任何请求；
/// - [invoker]：本机操作目录；null（app 还没初始化完）→ `not_ready`。
AgentAssistantHost createAgentAssistantHostWith({
  required bool Function() aiModuleEnabled,
  required AiSettingsSource settings,
  required FushiDatabase database,
  required OpInvoker? Function() invoker,
  AgentLlm Function(AiProviderConfig provider)? llmFactory,
  DateTime Function()? clock,
}) {
  Future<String?> blocker() async {
    if (!aiModuleEnabled()) return kHostAssistantReasonDisabled;
    if (resolveAiAgentProvider(settings) == null) {
      return kHostAssistantReasonNoProvider;
    }
    if (invoker() == null) return kHostAssistantReasonNotReady;
    return null;
  }

  return AgentAssistantHost(
    blocker: blocker,
    source: 'app',
    clock: clock,
    toolCount: () =>
        invoker()?.catalog
            .available()
            .where((FushiOp op) => !op.inProcessOnly)
            .length ??
        0,
    persist: (AgentSession session) => saveAiAgentHostSession(
      database,
      session,
      scene: kAiAgentRemoteScene,
      now: (clock ?? DateTime.now)(),
    ),
    open: (String locale) async {
      final AiProviderConfig? provider = resolveAiAgentProvider(settings);
      final OpInvoker? ops = invoker();
      // 门在 open 之前刚查过；这里再落空只可能是恰好在两步之间被改掉。
      if (provider == null) {
        throw const HostAssistantUnavailable(kHostAssistantReasonNoProvider);
      }
      if (ops == null) {
        throw const HostAssistantUnavailable(kHostAssistantReasonNotReady);
      }
      final AiAgentToolbox toolbox = AiAgentToolbox(
        invoker: ops,
        database: database,
        clock: clock,
      );
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
        toolbox: toolbox,
        // 长任务结束：与本机 AI 页同一路径——在对话里报告并自动续一轮。
        attach: (AgentSession session) {
          toolbox.onTaskFinished =
              (
                String sessionId,
                String opId,
                String taskId,
                OpTaskStatus status,
              ) {
                if (sessionId != session.id) return;
                final Object? data = status.data;
                session.continueAfterTask(
                  taskId,
                  opId: opId,
                  succeeded: status.succeeded,
                  status: <String, Object?>{
                    if (status.summary != null) 'summary': status.summary,
                    'data': ?data,
                  },
                  summary: status.summary,
                );
              };
        },
        release: () {
          toolbox.dispose();
          client?.close();
        },
      );
    },
  );
}

/// 把一场（远端）会话写进本机对话存档 `ai_agent_sessions`：与本机 AI 页同一张表、
/// 同一种标题取法，「AI 操作记录」页能看到远端会话、过了会话也能撤销。
Future<void> saveAiAgentHostSession(
  FushiDatabase database,
  AgentSession session, {
  required String scene,
  required DateTime now,
}) async {
  if (session.entries.isEmpty) return;
  final String firstUser = session.entries
      .firstWhere(
        (AgentEntry e) => e.kind == AgentEntryKind.user,
        orElse: () => session.entries.first,
      )
      .text;
  await database.upsertAiAgentSession(
    AiAgentSessionsCompanion.insert(
      id: session.id,
      title: firstUser.length > 60
          ? '${firstUser.substring(0, 60)}…'
          : firstUser,
      scene: scene,
      payloadJson: jsonEncode(session.toJson()),
      totalTokens: Value<int>(session.totalTokens),
      createdAt: session.entries.first.createdAt,
      updatedAt: now.millisecondsSinceEpoch,
    ),
  );
}
