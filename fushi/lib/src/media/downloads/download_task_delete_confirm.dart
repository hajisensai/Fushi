import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_destructive_confirm_dialog.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 下载任务「删除任务」确认框：正文 + 「同时删除已下载文件」勾选框。返回 null=取消，
/// 否则为勾选值。v78 任务面板与旧番剧计划面板共用，两处口径一致；测试按
/// `video-download-job-delete-files-<keySuffix>` / `…-confirm-<keySuffix>` 定位。
///
/// [offerDeleteFiles]=false 时不渲染勾选框、恒返回 false：删已下载的数据只能由下载
/// 后端执行，本机没有可用后端时那个勾选框兑现不了（与两个删除确认框「兑现不了就不
/// 显示」同一纪律）。
///
/// [message] 用于批量删除：整批只问一次，正文是「删除 N 个下载任务？」而不是
/// 单条的「删除《标题》的下载任务？」。给了 [message] 就不再用 [title] 拼正文。
Future<bool?> showDownloadTaskDeleteConfirm(
  BuildContext context, {
  required String title,
  required String keySuffix,
  bool offerDeleteFiles = true,
  String? message,
}) async {
  final FushiDestructiveConfirmResult? result =
      await showAppDialog<FushiDestructiveConfirmResult>(
    context: context,
    builder: (BuildContext dialogContext) => FushiDestructiveConfirmDialog(
      title: t.download_task_delete,
      message: message ?? t.download_task_delete_confirm(title: title),
      leadingIcon: FushiIcons.delete,
      confirmLabel: t.dialog_delete,
      checkboxLabel: offerDeleteFiles ? t.download_task_delete_files : null,
      checkboxKey: ValueKey<String>(
        'video-download-job-delete-files-$keySuffix',
      ),
      confirmKey: ValueKey<String>(
        'video-download-job-delete-confirm-$keySuffix',
      ),
    ),
  );
  if (result == null) return null;
  return offerDeleteFiles && result.checked;
}
