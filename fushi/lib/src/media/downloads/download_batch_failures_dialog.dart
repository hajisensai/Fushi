import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_batch.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 批量操作里失败的条目逐条列出：任务名 + 原因（BUG-5212）。
///
/// 批量提示条只放得下「N 项失败」，用户却要知道是哪条、为什么，才能决定重试、
/// 删掉还是去后端看——提示条上的「查看原因」打开这里。
Future<void> showDownloadBatchFailuresDialog(
  BuildContext context,
  List<DownloadBatchFailedTask> failures,
) {
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      key: const ValueKey<String>('download_batch_failures_dialog'),
      title: Text(t.download_batch_failed_details_title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final DownloadBatchFailedTask failure in failures)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      failure.title,
                      style: Theme.of(dialogContext).textTheme.titleSmall,
                    ),
                    SelectableText(failure.reason),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(t.dialog_ok),
        ),
      ],
    ),
  );
}
