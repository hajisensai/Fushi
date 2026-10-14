import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart' show SyncChoice;
import 'package:fushi/src/sync/sync_orchestrator.dart' show SyncConflict;
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show formatFushiPlaybackTime;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

/// 一条待用户裁决的播放位置冲突（BUG-3367）：弹窗展示用的两端**此刻**位置。
class PlaybackPositionConflictView {
  const PlaybackPositionConflictView({
    required this.conflict,
    required this.sync,
    required this.local,
    required this.remote,
  });

  final SyncConflict conflict;
  final InterconnectPlaybackPositionSync sync;
  final PlaybackPosition local;
  final PlaybackPosition remote;

  PlaybackPositionKind get kind => sync.kind;
}

/// 从同步报告的冲突里挑出播放位置冲突、重新读取两端此刻位置并复核仍是分叉
/// （BUG-3367）。报告产出到弹窗之间两端都可能又动过：复核后已不是冲突的条目
/// 不进弹窗，留给下一轮 sweep 按正常规则收敛，避免拿旧快照替用户做决定。
///
/// [backend] 不是互联后端时返回空（播放位置冲突只产生于互联通道）。单条读取失败
/// 只跳过这一条。
Future<List<PlaybackPositionConflictView>> loadPlaybackPositionConflicts({
  required FushiDatabase db,
  required Object backend,
  required List<SyncConflict> conflicts,
}) async {
  if (backend is! InterconnectSyncBackend) {
    return const <PlaybackPositionConflictView>[];
  }
  final List<PlaybackPositionConflictView> views =
      <PlaybackPositionConflictView>[];
  for (final SyncConflict c in conflicts) {
    final PlaybackPositionKind? kind = playbackPositionKindOfDimension(
      c.dimension,
    );
    if (kind == null) continue;
    final InterconnectPlaybackPositionSync sync =
        InterconnectPlaybackPositionSync(db: db, backend: backend, kind: kind);
    try {
      final PlaybackPosition local = await sync.localPosition(c.assetKey);
      final PlaybackPosition remote = await sync.remotePosition(c.assetKey);
      final BookProgressSyncAction action = resolvePlaybackPositionThreeWay(
        local: local,
        remote: remote,
        basePositionMs: await sync.baseline(c.assetKey),
      );
      if (action != BookProgressSyncAction.conflict) continue;
      views.add(
        PlaybackPositionConflictView(
          conflict: c,
          sync: sync,
          local: local,
          remote: remote,
        ),
      );
    } catch (e) {
      debugPrint('[sync] reload position conflict "${c.assetKey}" failed: $e');
    }
  }
  return views;
}

/// 按用户裁决落地：选本机 → 推给 host；选对端 → 落回本机；跳过 → 不动（下一轮
/// sweep 仍会报这条冲突）。返回实际解决的条数。单条失败只记日志、不中断其余。
Future<int> applyPlaybackPositionDecisions(
  List<PlaybackPositionConflictView> views,
  Map<int, SyncChoice> decisions,
) async {
  int applied = 0;
  for (final MapEntry<int, SyncChoice> d in decisions.entries) {
    final PlaybackPositionConflictView v = views[d.key];
    final String key = v.conflict.assetKey;
    try {
      switch (d.value) {
        case SyncChoice.useLocal:
          await v.sync.pushLocal(key, local: v.local, remote: v.remote);
          applied++;
        case SyncChoice.useRemote:
          await v.sync.applyRemote(key, v.remote);
          applied++;
        case SyncChoice.skip:
          break;
      }
    } catch (e) {
      debugPrint('[sync] apply position decision "$key" failed: $e');
    }
  }
  return applied;
}

/// 「播放进度冲突」弹窗（BUG-3367）：本机与对端在上次同步后都有了新的播放进度，
/// 逐条选保留哪一端。返回「行下标 → 裁决」（只含选了本机 / 对端的行）；取消返回
/// null。纯展示，不做 IO。
class PlaybackPositionConflictDialog extends StatefulWidget {
  const PlaybackPositionConflictDialog({required this.views, super.key});

  final List<PlaybackPositionConflictView> views;

  @override
  State<PlaybackPositionConflictDialog> createState() =>
      _PlaybackPositionConflictDialogState();
}

class _PlaybackPositionConflictDialogState
    extends State<PlaybackPositionConflictDialog> {
  /// 默认全部「跳过」：没有哪一端天然更对，必须由用户选。
  late final List<SyncChoice> _choices = List<SyncChoice>.filled(
    widget.views.length,
    SyncChoice.skip,
  );

  int get _decidedCount =>
      _choices.where((SyncChoice c) => c != SyncChoice.skip).length;

  String _sideLabel(String side, PlaybackPosition p) =>
      '$side · ${formatFushiPlaybackTime(Duration(milliseconds: p.positionMs))}';

  Widget _row(BuildContext context, int i) {
    final PlaybackPositionConflictView v = widget.views[i];
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SyncChoice choice = _choices[i];
    void select(SyncChoice value) => setState(() => _choices[i] = value);
    return Padding(
      padding: EdgeInsets.all(tokens.spacing.gap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              FushiIcon(
                v.kind == PlaybackPositionKind.video
                    ? FushiIcons.video
                    : FushiIcons.audiobook,
                size: 18,
              ),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Text(
                  v.conflict.title,
                  style: tokens.type.listTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap),
          // 单个手柄 / 键盘焦点站（左右键切换裁决），与书籍对比弹窗同一组件。
          FushiAdjustableSegmented<SyncChoice>(
            focusIdPrefix: 'sync-position-choice',
            values: const <SyncChoice>[
              SyncChoice.useLocal,
              SyncChoice.skip,
              SyncChoice.useRemote,
            ],
            selected: choice,
            onChanged: select,
            child: FushiSegmentedButton<SyncChoice>(
              expandedInsets: EdgeInsets.zero,
              showSelectedIcon: false,
              style: FushiSegmentedButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: context.fushiType.labelMedium,
              ),
              segments: [
                ButtonSegment<SyncChoice>(
                  value: SyncChoice.useLocal,
                  icon: const FushiIcon(FushiIcons.devices, size: 16),
                  label: Text(_sideLabel(t.sync_compare_use_local, v.local)),
                  tooltip: t.sync_compare_use_local,
                ),
                ButtonSegment<SyncChoice>(
                  value: SyncChoice.skip,
                  icon: const FushiIcon(FushiIcons.block, size: 16),
                  label: Text(t.sync_compare_skip),
                  tooltip: t.sync_compare_skip,
                ),
                ButtonSegment<SyncChoice>(
                  value: SyncChoice.useRemote,
                  icon: const FushiIcon(FushiIcons.cloud, size: 16),
                  label: Text(_sideLabel(t.sync_compare_use_remote, v.remote)),
                  tooltip: t.sync_compare_use_remote,
                ),
              ],
              selected: <SyncChoice>{choice},
              onSelectionChanged: (Set<SyncChoice> sel) => select(sel.first),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.8,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.sync_position_conflict_title,
        leadingIcon: FushiIcons.syncProblem,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap),
              child: Text(
                t.sync_position_conflict_message,
                style: tokens.type.listSubtitle,
              ),
            ),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: FushiEntranceScope(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: widget.views.length,
                    itemBuilder: fushiStaggeredItemBuilder(
                      (BuildContext context, int i) => FushiGroupedListItem(
                        index: i,
                        count: widget.views.length,
                        child: _row(context, i),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, null),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: _decidedCount == 0
                  ? null
                  : () => Navigator.pop(context, <int, SyncChoice>{
                      for (int i = 0; i < _choices.length; i++)
                        if (_choices[i] != SyncChoice.skip) i: _choices[i],
                    }),
              child: Text(t.sync_compare_apply(count: _decidedCount)),
            ),
          ],
        ),
      ),
    );
  }
}
