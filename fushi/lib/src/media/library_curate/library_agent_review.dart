/// AI 管库自动复查（spec `docs/specs/2026-11-22-ai-library-agent-design.md` §7，所有者
/// 2026-11-22 拍板「流水线打底 + agent 自动复查」）：库管家流水线跑完后，起一场无人
/// 值守的 AI 助手会话——
///
/// - **增量**：把上次复查以来新入库的条目（连同它们所在的合集与作品）交给助手，
///   检查流水线做得对不对、补上它漏掉的；
/// - **全库**：第一次、累积新条目达到 [kLibraryAgentReviewFullAfterItems]、或距上次全库
///   复查满 [kLibraryAgentReviewFullEvery] 且这期间有新条目时，整库过一遍——分段：
///   每段是一场只看 `library.map` 一个窗口的独立会话，跑完一段落一次游标，下次接着
///   跑（BUG-5365：整库塞进一场对话会撑爆上下文，失败不记账会每次从头再来）。
///
/// 每次尝试都记账：失败指数退避、连败熔断；会话与单趟都有 token 上限。状态与排程的
/// 纯函数在 `library_agent_review_state.dart`。
///
/// 会话以 [AiAgentController.unattended] 跑：确认卡一律拒绝、候选卡一律取消，拿不准的
/// 由模型写进汇报；对话照常存档，「AI 操作记录」里能看、能整场撤销。
///
/// 本文件依赖操作上下文（经它依赖 `AppModel`），只许大环外的文件 import（`main.dart`
/// 与设置页）；自动路径的叶子 `library_curate_auto.dart` 经
/// [registerLibraryAgentAutoReviewer] 拿到它。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/library_agent/library_map.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_facts.dart'
    show organizeEntryKeysAddedSince;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/media/library_curate/library_agent_review_state.dart';
import 'package:fushi/src/media/library_curate/library_curate_auto.dart';
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/app_op_context.dart';
import 'package:fushi/src/ops/op_context.dart';

export 'package:fushi/src/media/library_curate/library_agent_review_state.dart';

/// 存档里的场景名（「AI 操作记录」页据此分组）。
const String kLibraryAgentReviewScene = 'library_review';

/// 一场会话算不算「这一段做完了」：模型请求失败 / 被取消 / 中断算失败（退避后从同一
/// 处重来）；撞到调用上限、连错熔断、token 上限算做完——模型已经做了它能做的，重来
/// 只会再撞一次。
bool libraryAgentReviewCompleted(Iterable<String> stopCodes) => !stopCodes.any(
  (String c) =>
      c == AgentStopCode.llmError ||
      c == AgentStopCode.cancelled ||
      c == AgentStopCode.interrupted,
);

/// 一场复查会话的结果。
class LibraryAgentReviewSessionResult {
  const LibraryAgentReviewSessionResult({
    this.stopCodes = const <String>[],
    this.totalTokens = 0,
  });

  /// 会话里出现过的停止码（空 = 正常结束）。
  final List<String> stopCodes;

  /// 这场会话累计的 token（[AgentSession.totalTokens]）。
  final int totalTokens;
}

/// 跑一场复查会话（token 上限 [kLibraryAgentReviewSessionTokens] 由实现执行）；
/// null = 根本没跑起来（没指派提供商）。
typedef LibraryAgentReviewSessionRunner =
    Future<LibraryAgentReviewSessionResult?> Function(String prompt);

/// [LibraryMapView] 当前的总行数（与模型读 `library.map` 看到的同一口径：上锁的不算）。
typedef LibraryAgentReviewViewTotal = Future<int> Function(LibraryMapView view);

/// 全库复查一段的提示词。
String libraryAgentReviewSegmentPrompt(
  LibraryAgentReviewCursor cursor, {
  required int total,
}) {
  final int limit = libraryAgentReviewWindow(cursor.view);
  final int end = cursor.offset + limit > total ? total : cursor.offset + limit;
  return t.library_agent_review_segment_prompt(
    view: cursor.view.wireName,
    offset: cursor.offset,
    limit: limit,
    end: end,
    total: total,
  );
}

/// 自动复查器。依赖全部注入，测试不必起 [OpContext]。
///
/// 一次 [review]：退避 / 熔断中就不跑；否则做一次增量复查，或把进行中的分段全库
/// 复查往前推几段（单趟 token 用满 [kLibraryAgentReviewRunTokens] 就不再开下一段）。
/// 每段 / 每次尝试的结果（成功推进游标与水位，失败记退避）都立即落盘（BUG-5365）。
class LibraryAgentReviewer implements LibraryAgentAutoReviewer {
  LibraryAgentReviewer({
    required this.database,
    required this.prefs,
    required this.aiModuleEnabled,
    required this.agentAssigned,
    required this.runSession,
    String Function()? providerKey,
    LibraryAgentReviewViewTotal? viewTotal,
    DateTime Function()? clock,
  }) : _providerKey = providerKey ?? (() => ''),
       _viewTotal = viewTotal,
       _clock = clock ?? DateTime.now;

  final FushiDatabase database;
  final PreferencesRepository prefs;
  final bool Function() aiModuleEnabled;
  final bool Function() agentAssigned;
  final LibraryAgentReviewSessionRunner runSession;
  final String Function() _providerKey;
  final LibraryAgentReviewViewTotal? _viewTotal;
  final DateTime Function() _clock;

  bool _running = false;

  @override
  bool get enabled =>
      prefs.libraryAgentReviewAuto && aiModuleEnabled() && agentAssigned();

  int _now() => _clock().millisecondsSinceEpoch;

  /// 上次复查以来新入库的条目数（四个库页合计）。
  Future<int> _newItemsSince(int sinceMs) async {
    int n = 0;
    for (final CollectionShelfDomain d in CollectionShelfDomain.values) {
      n += (await organizeEntryKeysAddedSince(database, d, sinceMs)).length;
    }
    return n;
  }

  Future<int> _totalOf(LibraryMapView view) async {
    final LibraryAgentReviewViewTotal? injected = _viewTotal;
    if (injected != null) return injected(view);
    final Map<String, Object?> page = await loadLibraryMap(
      database,
      LibraryMapQuery(view: view, limit: 1),
    );
    final Object? total = page['total'];
    return total is int ? total : 0;
  }

  Future<void> _save(LibraryAgentReviewState state) =>
      prefs.setLibraryAgentReviewState(state.encode());

  /// 跑一场会话；抛异常也按失败算（自动路径没人看着，不能因此无限重来）。
  Future<LibraryAgentReviewSessionResult?> _run(String prompt) async {
    try {
      return await runSession(prompt);
    } on Object catch (error, stack) {
      engineLog.log('libraryAgentReview.session', error, stack);
      return const LibraryAgentReviewSessionResult(
        stopCodes: <String>[AgentStopCode.llmError],
      );
    }
  }

  @override
  Future<void> review() async {
    if (_running || !enabled) return;
    _running = true;
    try {
      final int startedAt = _now();
      final String providerKey = _providerKey();
      LibraryAgentReviewState state = LibraryAgentReviewState.parse(
        prefs.libraryAgentReviewState,
      );
      // 熔断时记下的提供商已经换掉了：用户改过设置，恢复。
      if (state.paused && state.pausedFor != providerKey) {
        state = state.resumed();
        await _save(state);
      }
      if (libraryAgentReviewBlocked(
        state,
        nowMs: startedAt,
        providerKey: providerKey,
      )) {
        return;
      }
      final int? since = state.lastReviewAt;
      final int newItems = since == null || state.fullInProgress
          ? 0
          : await _newItemsSince(since);
      final LibraryAgentReviewKind? kind = decideLibraryAgentReview(
        state: state,
        newItems: newItems,
        nowMs: startedAt,
      );
      switch (kind) {
        case null:
          return;
        case LibraryAgentReviewKind.incremental:
          final LibraryAgentReviewSessionResult? result = await _run(
            t.library_agent_review_prompt(count: newItems, since: since!),
          );
          if (result == null) return;
          await _save(
            libraryAgentReviewCompleted(result.stopCodes)
                ? state
                      .finishIncremental(
                        newItems: newItems,
                        startedAtMs: startedAt,
                      )
                      .succeeded()
                : state.failed(nowMs: _now(), providerKey: providerKey),
          );
        case LibraryAgentReviewKind.full:
          await _reviewFull(state, startedAt, providerKey);
      }
    } on Object catch (error, stack) {
      engineLog.log('libraryAgentReview', error, stack);
    } finally {
      _running = false;
    }
  }

  /// 把分段全库复查往前推：一段一场会话，每段结束都落盘；全部走完就收尾。
  Future<void> _reviewFull(
    LibraryAgentReviewState initial,
    int startedAt,
    String providerKey,
  ) async {
    LibraryAgentReviewState state = initial.fullInProgress
        ? initial
        : initial.startFull(startedAt);
    if (!initial.fullInProgress) await _save(state);
    int spent = 0;
    while (true) {
      final LibraryAgentReviewCursor? cursor = state.cursor;
      if (cursor == null) {
        await _save(state.finishFull());
        return;
      }
      if (spent >= kLibraryAgentReviewRunTokens) return;
      final int total = await _totalOf(cursor.view);
      if (cursor.offset >= total) {
        // 空视图 / 库变小了：这一段没东西可看，不开会话。
        state = state.advanceCursor(total: total);
        await _save(state);
        continue;
      }
      final LibraryAgentReviewSessionResult? result = await _run(
        libraryAgentReviewSegmentPrompt(cursor, total: total),
      );
      if (result == null) return;
      spent += result.totalTokens;
      if (!libraryAgentReviewCompleted(result.stopCodes)) {
        await _save(state.failed(nowMs: _now(), providerKey: providerKey));
        return;
      }
      state = state.advanceCursor(total: total).succeeded();
      await _save(state);
    }
  }
}

/// 生产用的会话执行：一场无人值守的助手对话（token 上限
/// [kLibraryAgentReviewSessionTokens]），跑完存档、释放。
Future<LibraryAgentReviewSessionResult?> runUnattendedLibraryReview(
  OpContext context,
  String prompt,
) async {
  final AiAgentController controller = AiAgentController.unattended(
    context,
    limits: const AgentLimits(
      maxSessionTokens: kLibraryAgentReviewSessionTokens,
    ),
  );
  try {
    if (!controller.hasProvider) return null;
    await controller.send(
      prompt,
      context: const AgentUiContext(scene: kLibraryAgentReviewScene),
    );
    return LibraryAgentReviewSessionResult(
      stopCodes: <String>[
        for (final AgentEntry e
            in controller.session?.entries ?? const <AgentEntry>[])
          if (e.kind == AgentEntryKind.notice && e.errorCode != null)
            e.errorCode!,
      ],
      totalTokens: controller.totalTokens,
    );
  } finally {
    controller.dispose();
  }
}

/// 当前「AI 助手」提供商的指纹（熔断据此判断「设置换过了」）；没指派时为空串。
String appLibraryAgentReviewProviderKey(PreferencesRepository prefs) {
  final AiProviderConfig? provider = resolveAiAgentProvider(prefs);
  if (provider == null) return '';
  return libraryAgentReviewProviderKey(
    id: provider.id,
    model: provider.model,
    baseUrl: provider.baseUrl.toString(),
  );
}

LibraryAgentReviewer? _shared;
OpContext? _sharedFor;

/// [context] 的进程级复查器（[context] 换了才重建）。
LibraryAgentReviewer libraryAgentReviewerFor(OpContext context) {
  final LibraryAgentReviewer? cached = _shared;
  if (cached != null && identical(_sharedFor, context)) return cached;
  _sharedFor = context;
  return _shared = LibraryAgentReviewer(
    database: context.appModel.database,
    prefs: context.appModel.prefsRepo,
    aiModuleEnabled: () => isAiModuleEnabled(context.appModel.moduleVisibility),
    agentAssigned: () =>
        resolveAiAgentProvider(context.appModel.prefsRepo) != null,
    runSession: (String prompt) => runUnattendedLibraryReview(context, prompt),
    providerKey: () =>
        appLibraryAgentReviewProviderKey(context.appModel.prefsRepo),
  );
}

/// 根组件登记操作上下文后调（`main.dart`）。
void registerAppLibraryAgentReviewer() => registerLibraryAgentAutoReviewer(() {
  final OpContext? context = appOpContext;
  return context == null ? null : libraryAgentReviewerFor(context);
});

@visibleForTesting
void debugResetLibraryAgentReviewer() {
  _shared = null;
  _sharedFor = null;
}
