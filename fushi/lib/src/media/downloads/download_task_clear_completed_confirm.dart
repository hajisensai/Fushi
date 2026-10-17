import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_batch.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/utils/components/fushi_destructive_confirm_dialog.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 「清除已完成」确认框：写明要处理几条已完成任务，带一个默认不勾的「同时删除
/// 已下载文件」。返回 null = 取消，否则为勾选值。
///
/// 测试按 `download-clear-completed-delete-files` / `download-clear-completed-confirm`
/// 定位勾选行与确认按钮。
///
/// 正文按 [tasks] 的来源能力如实列出例外，因为勾与不勾对不同来源的效果不一样：
/// - 只能连文件一起删的（video job、扩展源成品没有「只清记录」）不勾时保持不动；
/// - 删不了文件的（直链 / mokuro 等）勾了也只移出列表；
/// - 两样都做不了的始终不动；
/// - 正在做种的，删文件会把种子一起摘掉。
/// - 勾选后会联动删媒体库条目的（video job），勾上时再追加一句说明。
///
/// 没有任何一条兑现得了删文件时不摆勾选框、恒返回 false（「兑现不了就不显示」）。
Future<bool?> showDownloadClearCompletedConfirm(
  BuildContext context, {
  required List<DownloadTaskEntry> tasks,
}) async {
  final bool offerDeleteFiles = tasks.any(downloadTaskCanDeleteFiles);
  int onlyWithFiles = 0;
  int keepsFiles = 0;
  int unsupported = 0;
  int seeding = 0;
  int removesLibraryEntries = 0;
  for (final DownloadTaskEntry task in tasks) {
    final bool hasClear = task.actions.clear != null;
    final bool canDeleteFiles = downloadTaskCanDeleteFiles(task);
    if (!hasClear && canDeleteFiles) onlyWithFiles++;
    if (hasClear && !canDeleteFiles) keepsFiles++;
    if (!hasClear && !canDeleteFiles) unsupported++;
    if (task.seeding && canDeleteFiles) seeding++;
    if (canDeleteFiles && task.actions.deleteFilesRemovesLibraryEntries) {
      removesLibraryEntries++;
    }
  }
  final String message = <String>[
    t.download_clear_completed_confirm(n: tasks.length),
    if (onlyWithFiles > 0)
      t.download_clear_completed_confirm_needs_delete(n: onlyWithFiles),
    if (offerDeleteFiles && keepsFiles > 0)
      t.download_clear_completed_confirm_keeps_files(n: keepsFiles),
    if (unsupported > 0)
      t.download_clear_completed_confirm_unsupported(n: unsupported),
    if (seeding > 0) t.download_clear_completed_confirm_seeding(n: seeding),
  ].join('\n');
  final FushiDestructiveConfirmResult? result =
      await showAppDialog<FushiDestructiveConfirmResult>(
        context: context,
        builder: (BuildContext dialogContext) => FushiDestructiveConfirmDialog(
          title: t.download_clear_finished,
          message: message,
          leadingIcon: FushiIcons.deleteSweep,
          confirmLabel: t.clear,
          checkboxLabel: offerDeleteFiles ? t.download_task_delete_files : null,
          // 只在勾选且确有条目会联动删库行时才说：不勾就不会发生。
          checkedNote: removesLibraryEntries > 0
              ? t.download_clear_completed_confirm_removes_library
              : null,
          checkboxKey: const ValueKey<String>(
            'download-clear-completed-delete-files',
          ),
          confirmKey: const ValueKey<String>(
            'download-clear-completed-confirm',
          ),
        ),
      );
  if (result == null) return null;
  return offerDeleteFiles && result.checked;
}
