import 'package:flutter/material.dart';
import 'package:hibiki/utils.dart';

/// TODO-1204 后续：统计页 per-book / per-video 行长按删除该项统计的确认弹窗。
///
/// 删除范围只含**纯统计数字**（阅读 / 观看时长、字数、查词 / 制卡计数），不动用户
/// 收藏的词句与制卡历史（见 `HibikiDatabase.deleteReadingStatisticsForTitle` /
/// `deleteVideoStatisticsForTitle`）。自适应（Material / Cupertino）走 [showAppDialog]，
/// 与书架删除确认（`ReaderHistoryDeleteDialog` / `_SeriesConfirmDialog`）同结构。
@visibleForTesting
class StatDeleteConfirmDialog extends StatelessWidget {
  const StatDeleteConfirmDialog({required this.itemTitle, super.key});

  /// 被删项的展示名（书 / 视频标题），显示在正文首行。
  final String itemTitle;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: HibikiModalSheetFrame(
        title: t.stat_delete_title,
        leadingIcon: Icons.delete_outline,
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
        body: Text(
          '$itemTitle\n\n${t.stat_delete_message}',
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(context, true),
              child: Text(t.dialog_delete),
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹出统计删除确认框；仅当用户点「删除」时返回 true（取消 / 点外面关闭返回 false）。
Future<bool> confirmDeleteStatistics(
  BuildContext context,
  String itemTitle,
) async {
  final bool? confirmed = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext ctx) =>
        StatDeleteConfirmDialog(itemTitle: itemTitle),
  );
  return confirmed == true;
}
