import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
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
}) {
  bool deleteFiles = false;
  return showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => StatefulBuilder(
      builder: (
        BuildContext context,
        void Function(void Function()) setDialogState,
      ) =>
          AlertDialog(
        title: Text(t.download_task_delete),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(message ?? t.download_task_delete_confirm(title: title)),
            if (offerDeleteFiles) ...<Widget>[
              const SizedBox(height: 12),
              // 共享 MD3 行 + 裸 [Checkbox] 作 leading，整行 onTap 翻转——等价旧
              // CheckboxListTile 的取值/回调/标题，但行高与内边距走设计令牌。
              //
              // 这里刻意**不**换成两个删除确认框用的 [DeleteConfirmCheckboxRow]：
              // 那个行基于 `AdaptiveSettingsRow`，内部有 `LayoutBuilder`，而
              // `AlertDialog` 会对 content 做 intrinsic 测量——
              // 「LayoutBuilder does not support returning intrinsic dimensions」
              // 直接崩。两个删除确认框用的是 `FushiModalSheetFrame`，不测 intrinsic。
              // 要统一得先把本弹窗换成同一个 frame，那是另一件事。
              FushiListItem(
                key: ValueKey<String>(
                  'video-download-job-delete-files-$keySuffix',
                ),
                density: FushiListDensity.compact,
                padding: EdgeInsets.zero,
                onTap: () => setDialogState(
                  () => deleteFiles = !deleteFiles,
                ),
                leading: Checkbox(
                  value: deleteFiles,
                  onChanged: (bool? value) => setDialogState(
                    () => deleteFiles = value ?? false,
                  ),
                ),
                title: Text(t.download_task_delete_files),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(t.dialog_cancel),
          ),
          FilledButton(
            key: ValueKey<String>(
              'video-download-job-delete-confirm-$keySuffix',
            ),
            onPressed: () => Navigator.pop(
              dialogContext,
              offerDeleteFiles && deleteFiles,
            ),
            child: Text(t.dialog_delete),
          ),
        ],
      ),
    ),
  );
}
