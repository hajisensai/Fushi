import 'package:flutter/material.dart';

import 'package:fushi/src/pages/implementations/media_sources_dialog.dart';
import 'package:fushi/utils.dart';

/// 「后端没问题、只是还没有受管视频来源」的统一出口（发现页 / 详情页版）。
///
/// 与 `promptDownloadBackendSetup` 同一姿态：说清缺的是**下载完成后落地用的本地
/// 视频文件夹**，并就地开来源管理对话框补上，而不是甩一句「暂无来源」snackbar
/// 让用户自己猜缺什么、去哪补（下载页早已按 BUG-1706 把这一环拆开，首页发现路径
/// 此前漏改）。
///
/// 返回 true = 用户走进了「添加视频来源」对话框并把它关掉，**不表示真加成了**
/// （来源对话框是通用的增删界面，不回报增量）。调用方必须重新读取来源清单确认，
/// 并在仍为空时自己给回提示——本引导不是终点，静默结束比修前那句 snackbar 还糟。
/// 用户取消 = 明确放弃，不再补提示。
///
/// [openSourcesDialog] 只给测试注入：默认开 [MediaSourcesDialog]（视频域），它要
/// 真 AppModel。
Future<bool> promptManagedVideoSourceSetup({
  required BuildContext context,
  Future<void> Function(BuildContext context) openSourcesDialog =
      _openVideoSourcesDialog,
}) async {
  final bool? add = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => ManagedVideoSourcePromptDialog(
      onCancel: () => Navigator.pop(ctx, false),
      onAdd: () => Navigator.pop(ctx, true),
    ),
  );
  if (add != true || !context.mounted) return false;
  await openSourcesDialog(context);
  return true;
}

Future<void> _openVideoSourcesDialog(BuildContext context) =>
    showAppDialog<void>(
      context: context,
      builder: (BuildContext _) => const MediaSourcesDialog(mediaKind: 'video'),
    );

/// 「还没有受管视频来源」引导：一句说清缺什么 + 一个直接补上它的按钮。
class ManagedVideoSourcePromptDialog extends StatelessWidget {
  const ManagedVideoSourcePromptDialog({
    required this.onCancel,
    required this.onAdd,
    super.key,
  });

  final VoidCallback onCancel;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return FushiDialogFrame(
      maxWidth: 380,
      padding: EdgeInsets.all(tokens.spacing.card + 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 标题说**状态**、主按钮说**动作**：两处都用 `download_add_video_source`
          // 会让同一句「添加视频来源」在一个对话框里出现两遍。
          Text(
            t.download_video_source_required,
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: tokens.spacing.gap + 4),
          Text(
            t.download_no_managed_video_source,
            style: textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          SizedBox(height: tokens.spacing.card + tokens.spacing.gap),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              adaptiveDialogAction(
                context: context,
                onPressed: onCancel,
                child: Text(t.dialog_cancel),
              ),
              SizedBox(width: tokens.spacing.gap),
              KeyedSubtree(
                key: const ValueKey<String>('managed_video_source_prompt_add'),
                child: adaptiveDialogAction(
                  context: context,
                  isDefaultAction: true,
                  onPressed: onAdd,
                  child: Text(t.download_add_video_source),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
