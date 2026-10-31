import 'package:flutter/widgets.dart';
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/playback_position_conflict_dialog.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_conflict_decider.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_core/fushi_core.dart';

/// 冲突来源：决定弹窗的时机约束。
enum ConflictSource { manual, auto, background }

/// 弹窗串行队列（BUG-1571）。
///
/// 双通道同步（云备份 + 互联）逐通道调 `onReport`（见 sync_auto_trigger 的 sweep
/// 循环与 AppModel.presentSyncPrompts），两条通道的 present 会在**同一次 sweep 内**
/// 先后到达同一个 prompter。旧实现只有一个 `dialogOpen` 单飞位：第一条通道的弹窗
/// 还开着时，第二条通道的候选被 `shouldPrompt` 直接判 false 丢掉——不是「稍后再问」，
/// 是**这批候选彻底消失**（删除确认那侧还会与消费基线推进复合，让那批删除永久不再
/// 出现）。
///
/// 单飞位本身没错（同一时刻只能有一个 barrier 弹窗），错的是「挡下就扔」。这里把它
/// 改成排队：后到的那批在前一个弹窗关闭后接着弹，一条也不丢。队列是纯内存、随会话
/// 失效，与两个 prompter 原有的 snooze 语义正交。
mixin PromptQueue {
  Future<void> _queue = Future<void>.value();

  /// 把 [task] 排到本 prompter 的串行队列尾部：前一个弹窗（若有）关闭后才轮到它。
  /// 返回的 future 在 [task] 自身完成时完成（异常照常抛给调用方）；队列内部对异常
  /// 免疫，一个弹窗炸了不会把后续候选一起卡死在队列里。
  @protected
  Future<void> enqueuePrompt(Future<void> Function() task) {
    final Future<void> next = _queue.then((_) => task());
    _queue = next.catchError((Object _) {
      // 队列不因单次弹窗失败而断链；异常本身已随返回的 [next] 抛给调用方。
    });
    return next;
  }
}

/// 决定冲突弹窗的「是否/此刻弹」+ 会话级防骚扰，并在该弹时经全局 navigatorKey
/// 弹出冲突解决对话框。决策逻辑（[shouldPrompt]）仍是纯函数；[present] 只是把
/// 「该弹就弹、用户没解就静默」这条策略接到真实 UI 上。纯内存、随会话失效。
class SyncConflictPrompter with PromptQueue {
  bool dialogOpen = false;
  final Set<String> _snoozed = <String>{};

  /// 是否此刻应当弹出冲突解决对话框。
  bool shouldPrompt({
    required List<SyncConflict> conflicts,
    required ConflictSource source,
    required bool inBook,
  }) {
    if (conflicts.isEmpty) return false;
    if (dialogOpen) return false; // 单飞：已有对话框
    if (source == ConflictSource.background) return false; // 切后台看不到
    if (source == ConflictSource.auto) {
      if (inBook) return false; // 阅读中不打断
      // 整组都被本会话忽略过才压制；任一新指纹则仍弹。
      final bool allSnoozed = conflicts.every(
        (SyncConflict c) => _snoozed.contains(c.fingerprint),
      );
      if (allSnoozed) return false;
    }
    return true; // manual 不受 in-book/snooze 约束
  }

  /// 用户取消/关闭（未解决）后调用：本会话内对这些指纹的 auto 弹窗静默。
  void markDismissed(List<SyncConflict> conflicts) {
    for (final SyncConflict c in conflicts) {
      _snoozed.add(c.fingerprint);
    }
  }

  /// 按 [shouldPrompt] 决策，必要时经全局 [navigatorKey] 弹出 conflictsOnly 的
  /// 冲突解决对话框。用户未解决（applied 计数为空/0）则把这组冲突指纹加入会话
  /// snooze，避免自动同步反复打扰。
  ///
  /// 直接渲染 [SyncCompareDialog]（注入已解析的 [backend]），而非走
  /// [showSyncCompareDialog] —— 后者从 db 自行解析 backend 且不回传 applied
  /// 计数，无法满足「用注入 backend + 观察是否已解决以决定 snooze」这两点。
  ///
  /// [decisions] 是同一轮 sweep 内跨通道共享的裁决簿（见
  /// [SyncCompareDialog.decisions]）：调用方按通道逐个 present 时传同一个 map，
  /// 前一条通道里用户裁决过的书在后一条通道不再弹。null = 单通道 / 不共享。
  ///
  /// [decider]：非交互裁决器（CLI / AI 经 `/api/admin/sync/run` 的 `conflicts` 策略）。
  /// 给了就不弹窗、不看 [shouldPrompt] 的时机约束与会话静默，冲突交给它按策略落地；
  /// 同样排进本 prompter 的串行队列（不与同时在开的弹窗交错写）。
  Future<void> present({
    required GlobalKey<NavigatorState> navigatorKey,
    required FushiDatabase db,
    required SyncBackend backend,
    required List<SyncConflict> conflicts,
    required ConflictSource source,
    required bool inBook,
    Map<String, SyncChoice>? decisions,
    SyncConflictDecider? decider,
  }) => enqueuePrompt(
    () => decider != null
        ? decider.decide(
            db: db,
            backend: backend,
            conflicts: conflicts,
            decisions: decisions,
          )
        : _presentNow(
            navigatorKey: navigatorKey,
            db: db,
            backend: backend,
            conflicts: conflicts,
            source: source,
            inBook: inBook,
            decisions: decisions,
          ),
  );

  Future<void> _presentNow({
    required GlobalKey<NavigatorState> navigatorKey,
    required FushiDatabase db,
    required SyncBackend backend,
    required List<SyncConflict> conflicts,
    required ConflictSource source,
    required bool inBook,
    Map<String, SyncChoice>? decisions,
  }) async {
    if (!shouldPrompt(conflicts: conflicts, source: source, inBook: inBook)) {
      return;
    }
    final BuildContext? ctx = navigatorKey.currentContext;
    if (ctx == null) return; // HBK-AUDIT-012：navigatorKey 未 attach 时 null 安全
    // BUG-3367：播放位置（视频 / 有声书）冲突走自己的弹窗——书籍对比弹窗只认
    // 书，把它们交过去只会弹出一个空窗。两类各弹各的，书在前。
    final List<SyncConflict> positionConflicts = <SyncConflict>[
      for (final SyncConflict c in conflicts)
        if (playbackPositionKindOfDimension(c.dimension) != null) c,
    ];
    final List<SyncConflict> bookConflicts = <SyncConflict>[
      for (final SyncConflict c in conflicts)
        if (playbackPositionKindOfDimension(c.dimension) == null) c,
    ];
    if (bookConflicts.isNotEmpty) {
      await _presentBookConflicts(
        ctx: ctx,
        db: db,
        backend: backend,
        conflicts: bookConflicts,
        decisions: decisions,
      );
    }
    if (positionConflicts.isNotEmpty) {
      await _presentPositionConflicts(
        navigatorKey: navigatorKey,
        db: db,
        backend: backend,
        conflicts: positionConflicts,
      );
    }
  }

  /// 播放位置冲突：先复核两端此刻仍分叉（[loadPlaybackPositionConflicts]），再弹
  /// [PlaybackPositionConflictDialog] 并落地裁决。一条都没解决则本会话静默这组。
  Future<void> _presentPositionConflicts({
    required GlobalKey<NavigatorState> navigatorKey,
    required FushiDatabase db,
    required SyncBackend backend,
    required List<SyncConflict> conflicts,
  }) async {
    final List<PlaybackPositionConflictView> views =
        await loadPlaybackPositionConflicts(
          db: db,
          backend: backend,
          conflicts: conflicts,
        );
    if (views.isEmpty) return;
    final BuildContext? ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    dialogOpen = true;
    int applied = 0;
    try {
      final Map<int, SyncChoice>? decisions =
          await showAppDialog<Map<int, SyncChoice>>(
            context: ctx,
            barrierDismissible: false,
            builder: (_) => PlaybackPositionConflictDialog(views: views),
          );
      if (decisions != null && decisions.isNotEmpty) {
        applied = await applyPlaybackPositionDecisions(views, decisions);
      }
    } finally {
      dialogOpen = false;
    }
    if (applied <= 0) markDismissed(conflicts);
  }

  Future<void> _presentBookConflicts({
    required BuildContext ctx,
    required FushiDatabase db,
    required SyncBackend backend,
    required List<SyncConflict> conflicts,
    Map<String, SyncChoice>? decisions,
  }) async {
    dialogOpen = true;
    try {
      final int? applied = await showAppDialog<int>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => SyncCompareDialog(
          db: db,
          backend: backend,
          conflictsOnly: true,
          decisions: decisions,
        ),
      );
      // applied>0 表示用户至少解决了一项；否则视为取消，本会话静默这组冲突。
      if (applied == null || applied <= 0) markDismissed(conflicts);
    } finally {
      dialogOpen = false;
    }
  }
}
