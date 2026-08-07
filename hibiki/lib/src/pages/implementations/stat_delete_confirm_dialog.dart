import 'package:flutter/material.dart';
import 'package:fushi/utils.dart';

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

/// TODO-1322：统计页「清空全部统计」的危险操作确认弹窗。与 [StatDeleteConfirmDialog]
/// 同结构（自适应 [showAppDialog] + [HibikiModalSheetFrame] + 破坏性动作），但清空范围
/// 是**整个域**（全部书 / 全部视频）的纯统计数字，故独立标题、破坏性确认按钮，正文
/// [message] 由调用页按阅读 / 视频域各自传入（明确列出清什么、保留什么、不可逆）。
@visibleForTesting
class StatClearAllConfirmDialog extends StatelessWidget {
  const StatClearAllConfirmDialog({required this.message, super.key});

  /// 正文：本域清空范围 + 保留项说明（阅读页传 `t.stat_clear_all_reading_message`，
  /// 视频页传 `t.stat_clear_all_video_message`）。
  final String message;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: HibikiModalSheetFrame(
        title: t.stat_clear_all_title,
        leadingIcon: Icons.delete_sweep_outlined,
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
        body: Text(message, style: tokens.type.listSubtitle),
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
              child: Text(t.stat_clear_all_confirm),
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹出「清空全部统计」确认框；仅当用户点确认时返回 true（取消 / 点外面关闭返回 false）。
Future<bool> confirmClearAllStatistics(
  BuildContext context,
  String message,
) async {
  final bool? confirmed = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => StatClearAllConfirmDialog(message: message),
  );
  return confirmed == true;
}
