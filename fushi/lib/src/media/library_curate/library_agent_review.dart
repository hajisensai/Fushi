/// AI 管库自动复查（spec `docs/specs/2026-11-22-ai-library-agent-design.md` §7，所有者
/// 2026-11-22 拍板「流水线打底 + agent 自动复查」）：库管家流水线跑完后，起一场无人
/// 值守的 AI 助手会话——
///
/// - **增量**：把上次复查以来新入库的条目（连同它们所在的合集与作品）交给助手，
///   检查流水线做得对不对、补上它漏掉的；
/// - **全库**：第一次、累积新条目达到 [kLibraryAgentReviewFullAfterItems]、或距上次全库
///   复查满 [kLibraryAgentReviewFullEvery] 且这期间有新条目时，整库过一遍。
///
/// 会话以 [AiAgentController.unattended] 跑：确认卡一律拒绝、候选卡一律取消，拿不准的
/// 由模型写进汇报；对话照常存档，「AI 操作记录」里能看、能整场撤销。
///
/// 本文件依赖操作上下文（经它依赖 `AppModel`），只许大环外的文件 import（`main.dart`
/// 与设置页）；自动路径的叶子 `library_curate_auto.dart` 经
/// [registerLibraryAgentAutoReviewer] 拿到它。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_facts.dart'
    show organizeEntryKeysAddedSince;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/agent/ai_agent_controller.dart';
import 'package:fushi/src/media/library_curate/library_curate_auto.dart';
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/app_op_context.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 累积这么多新条目（自上次全库复查）就做一次全库复查。
const int kLibraryAgentReviewFullAfterItems = 100;

/// 距上次全库复查满这么久、且期间有新条目，就做一次全库复查。
const Duration kLibraryAgentReviewFullEvery = Duration(days: 30);

/// 存档里的场景名（「AI 操作记录」页据此分组）。
const String kLibraryAgentReviewScene = 'library_review';

/// 自动复查的本机状态（偏好 `library_agent_review_state`）。
class LibraryAgentReviewState {
  const LibraryAgentReviewState({
    this.lastReviewAt,
    this.lastFullAt,
    this.itemsSinceFull = 0,
  });

  /// 上一次跑完的复查开始的时刻（增量水位）；null = 还没复查过。
  final int? lastReviewAt;

  /// 上一次跑完的全库复查开始的时刻；null = 还没做过全库复查。
  final int? lastFullAt;

  /// 上次全库复查以来增量复查过的新条目数。
  final int itemsSinceFull;

  static LibraryAgentReviewState parse(String raw) {
    if (raw.trim().isEmpty) return const LibraryAgentReviewState();
    try {
      final Object? json = jsonDecode(raw);
      if (json is! Map) return const LibraryAgentReviewState();
      int? n(Object? v) => v is num ? v.toInt() : null;
      return LibraryAgentReviewState(
        lastReviewAt: n(json['lastReviewAt']),
        lastFullAt: n(json['lastFullAt']),
        itemsSinceFull: n(json['itemsSinceFull']) ?? 0,
      );
    } on FormatException {
      return const LibraryAgentReviewState();
    }
  }

  String encode() => jsonEncode(<String, Object?>{
    if (lastReviewAt != null) 'lastReviewAt': lastReviewAt,
    if (lastFullAt != null) 'lastFullAt': lastFullAt,
    'itemsSinceFull': itemsSinceFull,
  });
}

enum LibraryAgentReviewKind { incremental, full }

/// 这一次该做什么复查（纯函数）：null = 不必跑（没有新条目、也不到全库复查）。
LibraryAgentReviewKind? decideLibraryAgentReview({
  required LibraryAgentReviewState state,
  required int newItems,
  required int nowMs,
}) {
  final int? lastFull = state.lastFullAt;
  if (state.lastReviewAt == null || lastFull == null) {
    return LibraryAgentReviewKind.full;
  }
  if (newItems <= 0) return null;
  if (state.itemsSinceFull + newItems >= kLibraryAgentReviewFullAfterItems ||
      nowMs - lastFull >= kLibraryAgentReviewFullEvery.inMilliseconds) {
    return LibraryAgentReviewKind.full;
  }
  return LibraryAgentReviewKind.incremental;
}

/// 跑完后的新状态（纯函数）。[startedAtMs]：这一次复查开始的时刻（新入库的条目只
/// 要晚于它，下一次就还能看到）。
LibraryAgentReviewState advanceLibraryAgentReview(
  LibraryAgentReviewState state, {
  required LibraryAgentReviewKind kind,
  required int newItems,
  required int startedAtMs,
}) => switch (kind) {
  LibraryAgentReviewKind.full => LibraryAgentReviewState(
    lastReviewAt: startedAtMs,
    lastFullAt: startedAtMs,
  ),
  LibraryAgentReviewKind.incremental => LibraryAgentReviewState(
    lastReviewAt: startedAtMs,
    lastFullAt: state.lastFullAt,
    itemsSinceFull: state.itemsSinceFull + newItems,
  ),
};

/// 一场会话跑得算不算「跑完」：模型请求失败 / 被取消 / 中断时不推进水位（下次重来）；
/// 撞到调用上限 / 连错熔断算跑完——模型已经做了它能做的，重来只会再撞一次。
bool libraryAgentReviewCompleted(Iterable<String> stopCodes) => !stopCodes.any(
  (String c) =>
      c == AgentStopCode.llmError ||
      c == AgentStopCode.cancelled ||
      c == AgentStopCode.interrupted,
);

/// 跑一场复查会话：返回会话里出现过的停止码（空 = 正常结束）；null = 根本没跑起来。
typedef LibraryAgentReviewSessionRunner =
    Future<List<String>?> Function(String prompt);

/// 自动复查器。依赖全部注入，测试不必起 [OpContext]。
class LibraryAgentReviewer implements LibraryAgentAutoReviewer {
  LibraryAgentReviewer({
    required this.database,
    required this.prefs,
    required this.aiModuleEnabled,
    required this.agentAssigned,
    required this.runSession,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final FushiDatabase database;
  final PreferencesRepository prefs;
  final bool Function() aiModuleEnabled;
  final bool Function() agentAssigned;
  final LibraryAgentReviewSessionRunner runSession;
  final DateTime Function() _clock;

  bool _running = false;

  @override
  bool get enabled =>
      prefs.libraryAgentReviewAuto && aiModuleEnabled() && agentAssigned();

  /// 上次复查以来新入库的条目数（四个库页合计）。
  Future<int> _newItemsSince(int sinceMs) async {
    int n = 0;
    for (final CollectionShelfDomain d in CollectionShelfDomain.values) {
      n += (await organizeEntryKeysAddedSince(database, d, sinceMs)).length;
    }
    return n;
  }

  @override
  Future<void> review() async {
    if (_running || !enabled) return;
    _running = true;
    try {
      final int startedAt = _clock().millisecondsSinceEpoch;
      final LibraryAgentReviewState state = LibraryAgentReviewState.parse(
        prefs.libraryAgentReviewState,
      );
      final int? since = state.lastReviewAt;
      final int newItems = since == null ? 0 : await _newItemsSince(since);
      final LibraryAgentReviewKind? kind = decideLibraryAgentReview(
        state: state,
        newItems: newItems,
        nowMs: startedAt,
      );
      if (kind == null) return;
      final String prompt = switch (kind) {
        LibraryAgentReviewKind.full => t.library_agent_review_full_prompt,
        LibraryAgentReviewKind.incremental => t.library_agent_review_prompt(
          count: newItems,
          since: since!,
        ),
      };
      final List<String>? stops = await runSession(prompt);
      if (stops == null || !libraryAgentReviewCompleted(stops)) return;
      await prefs.setLibraryAgentReviewState(
        advanceLibraryAgentReview(
          state,
          kind: kind,
          newItems: newItems,
          startedAtMs: startedAt,
        ).encode(),
      );
    } on Object catch (error, stack) {
      engineLog.log('libraryAgentReview', error, stack);
    } finally {
      _running = false;
    }
  }
}

/// 生产用的会话执行：一场无人值守的助手对话，跑完存档、释放。
Future<List<String>?> runUnattendedLibraryReview(
  OpContext context,
  String prompt,
) async {
  final AiAgentController controller = AiAgentController.unattended(context);
  try {
    if (!controller.hasProvider) return null;
    await controller.send(
      prompt,
      context: const AgentUiContext(scene: kLibraryAgentReviewScene),
    );
    return <String>[
      for (final AgentEntry e
          in controller.session?.entries ?? const <AgentEntry>[])
        if (e.kind == AgentEntryKind.notice && e.errorCode != null)
          e.errorCode!,
    ];
  } finally {
    controller.dispose();
  }
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
