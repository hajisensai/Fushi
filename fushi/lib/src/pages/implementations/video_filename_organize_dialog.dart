import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/startup/media_handle_registry.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_engine/media/video/organize/video_filename_organize.dart';
import 'package:fushi_engine/media/video/organize/video_filename_organize_service.dart';

/// 视频库「整理文件名」交互（反馈 ZDYNkAP3Ln）：排计划 → 预览确认（可切换「只改
/// 文件名 / 同时整理目录」，做种联动查不清时明确告诉用户、让用户选）→ 执行 →
/// 结果提示带「撤销」。
///
/// [onLibraryChanged] 在磁盘 / 库真的动过之后调（含撤销），让调用页重读视频行。
Future<void> runVideoFilenameOrganize(
  BuildContext context, {
  required VideoFilenameOrganizeService service,
  required List<String> bookUids,
  required Future<void> Function() onLibraryChanged,
}) async {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  Future<VideoFilenameOrganizePlan> planFor(VideoOrganizeLayout layout) =>
      service.plan(bookUids, layout: layout);
  VideoFilenameOrganizePlan initial;
  try {
    initial = await planFor(VideoOrganizeLayout.filenameOnly);
    // 只能归目录的条目（多集播放列表）：只改名没有可做的，直接按归目录预览。
    if (initial.ready.isEmpty &&
        initial.items.any(
          (VideoFilenameItemPlan item) =>
              item.status == VideoFilenamePlanStatus.playlistNeedsDirectories,
        )) {
      initial = await planFor(VideoOrganizeLayout.directories);
    }
  } catch (e, stack) {
    ErrorLogService.instance.log('video.filenameOrganize.plan', e, stack);
    FushiToast.show(
      msg: t.video_filename_organize_failed(reason: '$e'),
      severity: ToastSeverity.error,
    );
    return;
  }
  if (!context.mounted) return;
  if (initial.ready.isEmpty &&
      initial.layout == VideoOrganizeLayout.directories) {
    FushiToast.show(
      msg: t.video_filename_organize_nothing,
      severity: ToastSeverity.info,
    );
    return;
  }
  final VideoFilenameOrganizePlan? plan =
      await showAppDialog<VideoFilenameOrganizePlan>(
        context: context,
        builder: (BuildContext context) =>
            VideoFilenameOrganizeDialog(plan: initial, planFor: planFor),
      );
  if (plan == null || plan.ready.isEmpty || !context.mounted) return;
  final VideoFilenameOrganizeResult result = await _apply(service, plan);
  await onLibraryChanged();
  if (!context.mounted) return;
  if (result.failures.isNotEmpty || result.collectionErrors.isNotEmpty) {
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => _VideoFilenameOrganizeFailuresDialog(
        failures: result.failures,
        collectionErrors: result.collectionErrors,
      ),
    );
  }
  final VideoFilenameOrganizePlan? undo = result.undoPlan;
  if (undo == null) return;
  messenger?.showSnackBar(
    FushiSnackBar(
      content: Text(
        t.video_filename_organize_done(count: '${result.renamedCount}'),
      ),
      duration: const Duration(seconds: 10),
      action: SnackBarAction(
        label: t.video_filename_organize_undo,
        onPressed: () =>
            unawaited(_undo(service, undo, onLibraryChanged: onLibraryChanged)),
      ),
    ),
  );
}

/// 用户在预览里已经确认过（含「做种联动查不清仍然改名」），所以这里如实放行。
///
/// 改名前先让正握着这些文件的播放器放句柄（与删除本地文件同一纪律）：Windows 上
/// libmpv 开着文件时改名必然 errno 32，整条会回滚、用户白确认一次。
Future<VideoFilenameOrganizeResult> _apply(
  VideoFilenameOrganizeService service,
  VideoFilenameOrganizePlan plan,
) async {
  await MediaHandleRegistry.instance.releaseHolding(<String>[
    for (final VideoFilenameItemPlan item in plan.ready)
      for (final VideoFilenamePlannedMove m in item.moves) m.move.from,
  ]);
  return service.apply(
    plan,
    allowUnverifiedTorrents:
        plan.torrentCheck == VideoFilenameTorrentCheck.unverified,
  );
}

Future<void> _undo(
  VideoFilenameOrganizeService service,
  VideoFilenameOrganizePlan undo, {
  required Future<void> Function() onLibraryChanged,
}) async {
  final VideoFilenameOrganizeResult result = await _apply(service, undo);
  await onLibraryChanged();
  if (result.failures.isEmpty && result.collectionErrors.isEmpty) {
    FushiToast.show(
      msg: t.video_filename_organize_undone(count: '${result.renamedCount}'),
      severity: ToastSeverity.success,
    );
    return;
  }
  final String reason = result.failures.isEmpty
      ? result.collectionErrors.first
      : '${result.failures.first.item.title}: '
            '${result.failures.first.error ?? ''}';
  FushiToast.show(
    msg: t.video_filename_organize_failed(reason: reason),
    severity: ToastSeverity.error,
  );
}

/// 跳过原因的分组文案（按计划状态）；没有专门文案的归进通用的「跳过 N 项」。
List<String> videoFilenameOrganizeSkipLines(VideoFilenameOrganizePlan plan) {
  final Map<VideoFilenamePlanStatus, int> counts =
      <VideoFilenamePlanStatus, int>{};
  for (final VideoFilenameItemPlan item in plan.items) {
    if (item.status == VideoFilenamePlanStatus.ready) continue;
    counts[item.status] = (counts[item.status] ?? 0) + 1;
  }
  int other = 0;
  final List<String> lines = <String>[];
  for (final MapEntry<VideoFilenamePlanStatus, int> entry in counts.entries) {
    final String count = '${entry.value}';
    final String? line = switch (entry.key) {
      VideoFilenamePlanStatus.disc => t.video_filename_organize_skip_disc(
        count: count,
      ),
      VideoFilenamePlanStatus.playlistNeedsDirectories =>
        t.video_filename_organize_skip_playlist(count: count),
      VideoFilenamePlanStatus.outsideLibraryRoot =>
        t.video_filename_organize_skip_outside_library(count: count),
      VideoFilenamePlanStatus.torrentOutsideSaveRoot =>
        t.video_filename_organize_skip_torrent_root(count: count),
      VideoFilenamePlanStatus.folderCollectionSplit =>
        t.video_filename_organize_skip_folder_collection(count: count),
      _ => null,
    };
    if (line == null) {
      other += entry.value;
    } else {
      lines.add(line);
    }
  }
  if (other > 0) {
    lines.add(t.video_filename_organize_skipped(count: '$other'));
  }
  return lines;
}

/// 预览：布局切换（只改文件名 / 同时整理目录，切换时重新排计划）、逐条「旧名 →
/// 新名（新目录）」、做种标记、按原因分组的跳过数、跟着走的目录合集；查不清做种
/// 时给出警告并把确认按钮换成「仍然改名」。返回用户确认的那份计划，取消为 null。
class VideoFilenameOrganizeDialog extends StatefulWidget {
  const VideoFilenameOrganizeDialog({
    required this.plan,
    required this.planFor,
    super.key,
  });

  /// 打开时的计划。
  final VideoFilenameOrganizePlan plan;

  /// 切换布局时重新排计划。
  final Future<VideoFilenameOrganizePlan> Function(VideoOrganizeLayout layout)
  planFor;

  @override
  State<VideoFilenameOrganizeDialog> createState() =>
      _VideoFilenameOrganizeDialogState();
}

class _VideoFilenameOrganizeDialogState
    extends State<VideoFilenameOrganizeDialog> {
  late VideoFilenameOrganizePlan _plan = widget.plan;
  late VideoOrganizeLayout _layout = widget.plan.layout;
  bool _loading = false;
  String? _error;

  Future<void> _switchLayout(VideoOrganizeLayout layout) async {
    if (layout == _layout) return;
    setState(() {
      _layout = layout;
      _loading = true;
      _error = null;
    });
    try {
      final VideoFilenameOrganizePlan next = await widget.planFor(layout);
      if (!mounted || _layout != layout) return;
      setState(() {
        _plan = next;
        _loading = false;
      });
    } catch (e, stack) {
      ErrorLogService.instance.log('video.filenameOrganize.plan', e, stack);
      if (!mounted || _layout != layout) return;
      setState(() {
        _loading = false;
        _error = t.video_filename_organize_failed(reason: '$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final VideoFilenameOrganizePlan plan = _plan;
    final bool current = !_loading && _error == null && plan.layout == _layout;
    final List<VideoFilenameItemPlan> ready = current
        ? plan.ready
        : const <VideoFilenameItemPlan>[];
    final List<String> skipLines = current
        ? videoFilenameOrganizeSkipLines(plan)
        : const <String>[];
    final bool unverified =
        current && plan.torrentCheck == VideoFilenameTorrentCheck.unverified;
    final TextStyle? hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    return FushiAlertDialog(
      icon: const FushiIcon(FushiIcons.rename),
      title: Text(t.video_filename_organize_title),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            adaptiveSegmentedButton<VideoOrganizeLayout>(
              context: context,
              segments: <ButtonSegment<VideoOrganizeLayout>>[
                ButtonSegment<VideoOrganizeLayout>(
                  value: VideoOrganizeLayout.filenameOnly,
                  label: Text(t.video_filename_organize_layout_names),
                ),
                ButtonSegment<VideoOrganizeLayout>(
                  value: VideoOrganizeLayout.directories,
                  label: Text(t.video_filename_organize_layout_folders),
                ),
              ],
              selected: <VideoOrganizeLayout>{_layout},
              onSelectionChanged: (Set<VideoOrganizeLayout> values) {
                if (values.isEmpty) return;
                _switchLayout(values.first);
              },
            ),
            const SizedBox(height: 12),
            Text(
              _layout == VideoOrganizeLayout.directories
                  ? t.video_filename_organize_folders_hint
                  : t.video_filename_organize_hint,
              style: hintStyle,
            ),
            if (_loading) ...<Widget>[
              const SizedBox(height: 16),
              Center(child: adaptiveIndicator(context: context)),
            ],
            if (_error case final String error) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                error,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (unverified) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  FushiIcon(
                    FushiIcons.warning,
                    size: 20,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t.video_filename_organize_unverified(
                        reason: plan.torrentCheckError ?? '',
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (ready.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: FushiEntranceScope(
                    // 换布局 = 换一份清单：key 跟着布局走，错峰入场重新播一遍。
                    key: ValueKey<VideoOrganizeLayout>(plan.layout),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: ready.length,
                      itemBuilder: fushiStaggeredItemBuilder(
                        (BuildContext context, int index) =>
                            _VideoFilenameItemTile(item: ready[index]),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (current && plan.folderCollectionMoves.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                t.video_filename_organize_collections_follow(
                  count: '${plan.folderCollectionMoves.length}',
                ),
                style: hintStyle,
              ),
            ],
            for (final String line in skipLines) ...<Widget>[
              const SizedBox(height: 8),
              Text(line, style: hintStyle),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        FushiFilledButton(
          onPressed: ready.isEmpty ? null : () => Navigator.pop(context, plan),
          child: Text(
            unverified
                ? t.video_filename_organize_confirm_anyway
                : t.video_filename_organize_confirm,
          ),
        ),
      ],
    );
  }
}

class _VideoFilenameItemTile extends StatelessWidget {
  const _VideoFilenameItemTile({required this.item});

  final VideoFilenameItemPlan item;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final VideoFilenamePlannedMove video = item.moves.first;
    final int sidecars = item.moves.length - 1;
    // 换目录时显示库根之下的相对路径（`标题 (年份)/Season 01/…`），只改名时只显示
    // 文件名。
    final String? root = item.libraryRoot;
    final String target = item.changesDirectory && root != null
        ? p.relative(video.move.to, from: root)
        : p.basename(video.move.to);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  item.title,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (item.isSeeding)
                FushiTooltip(
                  message: t.video_filename_organize_seeding,
                  child: Semantics(
                    label: t.video_filename_organize_seeding,
                    child: FushiIcon(
                      FushiIcons.upload,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            p.basename(video.move.from),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
              decoration: TextDecoration.lineThrough,
            ),
          ),
          Text(target, style: theme.textTheme.bodySmall),
          if (sidecars > 0)
            Text(
              t.video_filename_organize_sidecars(count: '$sidecars'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
        ],
      ),
    );
  }
}

class _VideoFilenameOrganizeFailuresDialog extends StatelessWidget {
  const _VideoFilenameOrganizeFailuresDialog({
    required this.failures,
    required this.collectionErrors,
  });

  final List<VideoFilenameItemOutcome> failures;

  /// 目录合集换键失败（文件已搬好）。
  final List<String> collectionErrors;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FushiAlertDialog(
      icon: const FushiIcon(FushiIcons.warning),
      title: Text(t.video_filename_organize_failed_title),
      content: SizedBox(
        width: 520,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: FushiEntranceScope(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: failures.length + collectionErrors.length,
              itemBuilder: fushiStaggeredItemBuilder((
                BuildContext context,
                int index,
              ) {
                if (index >= failures.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: SelectableText(
                      t.video_filename_organize_collection_failed(
                        reason: collectionErrors[index - failures.length],
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  );
                }
                final VideoFilenameItemOutcome failure = failures[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        failure.item.title,
                        style: theme.textTheme.titleSmall,
                      ),
                      SelectableText(
                        failure.error ?? '',
                        style: theme.textTheme.bodySmall,
                      ),
                      if (failure.rollbackError != null)
                        SelectableText(
                          t.video_filename_organize_rollback_failed(
                            reason: failure.rollbackError!,
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                );
              }),
            ),
          ),
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_ok),
        ),
      ],
    );
  }
}
