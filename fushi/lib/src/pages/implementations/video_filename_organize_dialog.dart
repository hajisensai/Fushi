import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/startup/media_handle_registry.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_engine/media/video/organize/video_filename_organize_service.dart';

/// 视频库「整理文件名」交互（反馈 ZDYNkAP3Ln）：排计划 → 预览确认（做种联动
/// 查不清时明确告诉用户、让用户选）→ 执行 → 结果提示带「撤销」。
///
/// [onLibraryChanged] 在磁盘 / 库真的动过之后调（含撤销），让调用页重读视频行。
Future<void> runVideoFilenameOrganize(
  BuildContext context, {
  required VideoFilenameOrganizeService service,
  required List<String> bookUids,
  required Future<void> Function() onLibraryChanged,
}) async {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final VideoFilenameOrganizePlan plan;
  try {
    plan = await service.plan(bookUids);
  } catch (e, stack) {
    ErrorLogService.instance.log('video.filenameOrganize.plan', e, stack);
    FushiToast.show(
      msg: t.video_filename_organize_failed(reason: '$e'),
      severity: ToastSeverity.error,
    );
    return;
  }
  if (!context.mounted) return;
  if (plan.ready.isEmpty) {
    FushiToast.show(
      msg: t.video_filename_organize_nothing,
      severity: ToastSeverity.info,
    );
    return;
  }
  final bool? confirmed = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext context) => VideoFilenameOrganizeDialog(plan: plan),
  );
  if (confirmed != true || !context.mounted) return;
  final VideoFilenameOrganizeResult result = await _apply(service, plan);
  await onLibraryChanged();
  if (!context.mounted) return;
  if (result.failures.isNotEmpty) {
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext context) =>
          _VideoFilenameOrganizeFailuresDialog(failures: result.failures),
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
  if (result.failures.isEmpty) {
    FushiToast.show(
      msg: t.video_filename_organize_undone(count: '${result.renamedCount}'),
      severity: ToastSeverity.success,
    );
    return;
  }
  final VideoFilenameItemOutcome first = result.failures.first;
  FushiToast.show(
    msg: t.video_filename_organize_failed(
      reason: '${first.item.title}: ${first.error ?? ''}',
    ),
    severity: ToastSeverity.error,
  );
}

/// 预览：逐条「旧名 → 新名」、做种标记、跳过数；查不清做种时给出警告并把
/// 确认按钮换成「仍然改名」。返回 true = 用户确认执行。
class VideoFilenameOrganizeDialog extends StatelessWidget {
  const VideoFilenameOrganizeDialog({required this.plan, super.key});

  final VideoFilenameOrganizePlan plan;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<VideoFilenameItemPlan> ready = plan.ready;
    final int skipped = plan.items.length - ready.length;
    final bool unverified =
        plan.torrentCheck == VideoFilenameTorrentCheck.unverified;
    return FushiAlertDialog(
      icon: const FushiIcon(FushiIcons.rename),
      title: Text(t.video_filename_organize_title),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.video_filename_organize_hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
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
            const SizedBox(height: 12),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: FushiEntranceScope(
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
            if (skipped > 0) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                t.video_filename_organize_skipped(count: '$skipped'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(t.dialog_cancel),
        ),
        FushiFilledButton(
          onPressed: () => Navigator.pop(context, true),
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
                Tooltip(
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
          Text(p.basename(video.move.to), style: theme.textTheme.bodySmall),
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
  const _VideoFilenameOrganizeFailuresDialog({required this.failures});

  final List<VideoFilenameItemOutcome> failures;

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
              itemCount: failures.length,
              itemBuilder: fushiStaggeredItemBuilder((
                BuildContext context,
                int index,
              ) {
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
