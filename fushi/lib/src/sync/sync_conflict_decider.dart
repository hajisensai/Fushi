/// 同步中途冲突的**非交互**裁决（CLI / AI 助手：`/api/admin/sync/run` 的 `conflicts` 参数）。
///
/// 手动同步照旧走 [runManualSyncWithFeedback] → [SyncConflictPrompter.present]；给 present
/// 注入一个 [SyncConflictDecider] 后，冲突不弹窗，由裁决器按策略选、用弹窗同一套落地函数写：
/// 书 = [loadSyncCompareData] → [seedSyncCompareChoices]（跨通道裁决簿同一规则）→
/// [applySyncCompareChoices]；播放位置 = [loadPlaybackPositionConflicts] →
/// [applyPlaybackPositionDecisions]。不复制同步流程，只替换「弹窗里点哪个」这一步。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/sync/interconnect_playback_position_sync.dart'
    show PlaybackPositionKind, playbackPositionKindOfDimension;
import 'package:fushi/src/sync/playback_position_conflict_dialog.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';

/// 注入给 [SyncConflictPrompter.present] 的裁决器：拿到一条通道的冲突，自己决定并落地。
abstract interface class SyncConflictDecider {
  /// [decisions]：同一轮里跨通道共享的裁决簿（与弹窗同一本，见
  /// [SyncCompareDialog.decisions]）。
  Future<void> decide({
    required FushiDatabase db,
    required SyncBackend backend,
    required List<SyncConflict> conflicts,
    Map<String, SyncChoice>? decisions,
  });
}

/// 冲突策略（wire 值见 [wire]）。
enum SyncConflictPolicy {
  /// 一律保留本机这份（推给对端）。
  keepLocal('keep-local'),

  /// 一律采用对端这份。
  keepRemote('keep-remote'),

  /// 取更新时刻较新的一侧（同刻保留本机）。
  newest('newest'),

  /// 不裁决：冲突原样留着（下一轮同步仍会报），清单交给调用方。
  ask('ask');

  const SyncConflictPolicy(this.wire);

  final String wire;

  static SyncConflictPolicy? tryParse(String? raw) {
    for (final SyncConflictPolicy p in values) {
      if (p.wire == raw) return p;
    }
    return null;
  }
}

/// 按 [policy] 裁决的实现；跑完后 [resolved] / [unresolved] 是给调用方看的清单。
class SyncConflictPolicyDecider implements SyncConflictDecider {
  SyncConflictPolicyDecider(this.policy, {Directory? tempDir})
    : _tempDir = tempDir;

  final SyncConflictPolicy policy;
  final Directory? _tempDir;

  /// 已按策略落地的冲突。
  final List<Map<String, Object?>> resolved = <Map<String, Object?>>[];

  /// 没解决的冲突（`ask`，或落地失败 / 落地前对端又动过）。
  final List<Map<String, Object?>> unresolved = <Map<String, Object?>>[];

  /// 按策略在两侧之间选；`ask` 返回 null。
  SyncChoice? choose({required int? localAt, required int? remoteAt}) =>
      switch (policy) {
        SyncConflictPolicy.keepLocal => SyncChoice.useLocal,
        SyncConflictPolicy.keepRemote => SyncChoice.useRemote,
        SyncConflictPolicy.newest =>
          (localAt ?? 0) >= (remoteAt ?? 0)
              ? SyncChoice.useLocal
              : SyncChoice.useRemote,
        SyncConflictPolicy.ask => null,
      };

  static String _side(SyncChoice choice) =>
      choice == SyncChoice.useLocal ? 'local' : 'remote';

  @override
  Future<void> decide({
    required FushiDatabase db,
    required SyncBackend backend,
    required List<SyncConflict> conflicts,
    Map<String, SyncChoice>? decisions,
  }) async {
    // 与 [SyncConflictPrompter] 同一分流：播放位置冲突走自己的落地函数，其余是书。
    final List<SyncConflict> positions = <SyncConflict>[
      for (final SyncConflict c in conflicts)
        if (playbackPositionKindOfDimension(c.dimension) != null) c,
    ];
    if (conflicts.length > positions.length) {
      await _decideBooks(db, backend, decisions);
    }
    if (positions.isNotEmpty) await _decidePositions(db, backend, positions);
  }

  Future<void> _decideBooks(
    FushiDatabase db,
    SyncBackend backend,
    Map<String, SyncChoice>? decisions,
  ) async {
    // 与冲突弹窗同一条链路：重新拉差异（不拿报告里的旧快照替用户做决定），只看真分叉。
    final ({List<SyncCompareEntry> books, List<SyncDictEntry> dicts}) data =
        await loadSyncCompareData(db, backend);
    final List<SyncCompareEntry> inPlay = <SyncCompareEntry>[
      for (final SyncCompareEntry e in data.books)
        if (e.hasConflict) e,
    ];
    if (inPlay.isEmpty) return;
    final ({Map<String, SyncChoice> choices, Set<String> undecided}) seeded =
        seedSyncCompareChoices(data.books, decisions);
    final Map<String, SyncChoice> choices = seeded.choices;
    final List<SyncCompareEntry> actionable = <SyncCompareEntry>[];
    for (final SyncCompareEntry e in inPlay) {
      if (seeded.undecided.contains(e.title)) {
        final SyncChoice? pick = choose(
          localAt: e.localUpdatedAt,
          remoteAt: e.remoteUpdatedAt,
        );
        if (pick == null) {
          unresolved.add(_bookJson(e));
          continue;
        }
        choices[e.title] = pick;
      }
      final SyncChoice choice = choices[e.title] ?? SyncChoice.skip;
      if (choice == SyncChoice.skip || e.bookKey == null) {
        // 簿上记过「跳过」：本轮两端都不动（与弹窗同口径），下一轮仍会报。
        unresolved.add(_bookJson(e));
        continue;
      }
      actionable.add(e);
    }
    if (actionable.isEmpty) return;
    final SyncCompareApplyResult result = await applySyncCompareChoices(
      db: db,
      backend: backend,
      actionable: actionable,
      choices: choices,
      tempDir: _tempDir ?? Directory.systemTemp,
      decisions: decisions,
    );
    final Set<String> failed = result.errors.toSet();
    for (final SyncCompareEntry e in actionable) {
      if (failed.contains(e.title)) {
        unresolved.add(<String, Object?>{
          ..._bookJson(e),
          'error': 'apply_failed',
        });
      } else {
        resolved.add(<String, Object?>{
          ..._bookJson(e),
          'kept': _side(choices[e.title]!),
        });
      }
    }
  }

  Future<void> _decidePositions(
    FushiDatabase db,
    SyncBackend backend,
    List<SyncConflict> conflicts,
  ) async {
    final List<PlaybackPositionConflictView> views =
        await loadPlaybackPositionConflicts(
          db: db,
          backend: backend,
          conflicts: conflicts,
        );
    for (int i = 0; i < views.length; i++) {
      final PlaybackPositionConflictView v = views[i];
      final Map<String, Object?> row = <String, Object?>{
        'type': v.kind == PlaybackPositionKind.video ? 'video' : 'audiobook',
        'title': v.conflict.title,
        'key': v.conflict.assetKey,
        'localPositionMs': v.local.positionMs,
        'localUpdatedAt': v.local.updatedAtMs,
        'remotePositionMs': v.remote.positionMs,
        'remoteUpdatedAt': v.remote.updatedAtMs,
      };
      final SyncChoice? pick = choose(
        localAt: v.local.updatedAtMs,
        remoteAt: v.remote.updatedAtMs,
      );
      if (pick == null) {
        unresolved.add(row);
        continue;
      }
      // 逐条落地：对端在这期间又改过时 applyRemote 不落地（BUG-3537），这条算没解决。
      final int applied = await applyPlaybackPositionDecisions(
        views,
        <int, SyncChoice>{i: pick},
      );
      if (applied > 0) {
        resolved.add(<String, Object?>{...row, 'kept': _side(pick)});
      } else {
        unresolved.add(<String, Object?>{...row, 'error': 'not_applied'});
      }
    }
  }

  static Map<String, Object?> _bookJson(SyncCompareEntry e) =>
      <String, Object?>{
        'type': 'book',
        'title': e.title,
        if (e.bookKey != null) 'key': e.bookKey,
        if (e.localProgress != null) 'localProgress': e.localProgress,
        if (e.localUpdatedAt != null) 'localUpdatedAt': e.localUpdatedAt,
        if (e.remoteProgress != null) 'remoteProgress': e.remoteProgress,
        if (e.remoteUpdatedAt != null) 'remoteUpdatedAt': e.remoteUpdatedAt,
      };

  /// 给调用方的结果。
  Map<String, Object?> toJson() => <String, Object?>{
    'policy': policy.wire,
    'resolved': resolved,
    'unresolved': unresolved,
  };
}
