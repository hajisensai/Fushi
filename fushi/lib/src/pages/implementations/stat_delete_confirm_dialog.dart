import 'package:flutter/material.dart';
import 'package:fushi/utils.dart';

/// TODO-1204 后续：统计页 per-book / per-video 行长按删除该项统计的确认弹窗。
///
/// 删除范围只含**纯统计数字**（阅读 / 观看时长、字数、查词 / 制卡计数），不动用户
/// 收藏的词句与制卡历史（见 `FushiDatabase.deleteReadingStatisticsForTitle` /
/// `deleteVideoStatisticsForIdentity`）。自适应（Material / Cupertino）走 [showAppDialog]，
/// 与书架删除确认（`ReaderHistoryDeleteDialog` / `_SeriesConfirmDialog`）同结构。
@visibleForTesting
class StatDeleteConfirmDialog extends StatelessWidget {
  const StatDeleteConfirmDialog({
    required this.itemTitle,
    this.message,
    super.key,
  });

  /// 被删项的展示名（书 / 视频标题），显示在正文首行。
  final String itemTitle;

  /// 正文说明；null = 默认的「删该项全部统计」文案（`stat_delete_message`）。会话流
  /// 删单次会话传 `stat_session_delete_message`。
  final String? message;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: FushiModalSheetFrame(
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
          '$itemTitle\n\n${message ?? t.stat_delete_message}',
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
  String itemTitle, {
  String? message,
}) async {
  final bool? confirmed = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext ctx) =>
        StatDeleteConfirmDialog(itemTitle: itemTitle, message: message),
  );
  return confirmed == true;
}

/// TODO-1322：统计页「清空全部统计」的危险操作确认弹窗。与 [StatDeleteConfirmDialog]
/// 同结构（自适应 [showAppDialog] + [FushiModalSheetFrame] + 破坏性动作），但清空范围
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: FushiModalSheetFrame(
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

/// 「清除全部会话记录」的**防呆**确认弹窗（用户 2026-09-10：「再加个清除所有会话
/// 记录并且防呆」）。
///
/// 不自己造第五个确认框：全 app 的破坏性确认早已收口到
/// [FushiDestructiveConfirmDialog]（docs/reviews/2026-07-22-ui-ux-survey.md 巡检把
/// 四种并存实现合成了它），这里只是给它开**防呆闸**（`requireCheckboxToConfirm`）。
/// 闸的理由：这颗按钮就长在会话区块的标题行上（四个 tab 都有），紧挨着「全部会话」
/// ——一个纯确认框在这种位置等同于「点两下删光半年数据」。勾选项把条数复述一遍，
/// 用户至少得读到那个数字。
///
/// 与顶栏那颗「清空全部统计」（[StatClearAllConfirmDialog]）的范围差着一个数量级：
/// 这里只清会话事实，收藏 / 制卡历史 / 查词计数 / 游戏库一个都不动。
@visibleForTesting
class StatClearSessionsConfirmDialog extends StatelessWidget {
  const StatClearSessionsConfirmDialog({required this.count, super.key});

  /// 待清除的会话条数（正文与勾选项都复述它）。
  final int count;

  /// 勾选行的 key（widget 测试与集成测试焦点驱动都按它定位）。
  static const Key ackKey = ValueKey<String>('stat-clear-sessions-ack');

  @override
  Widget build(BuildContext context) => FushiDestructiveConfirmDialog(
        title: t.stat_sessions_clear_all_title,
        message: t.stat_sessions_clear_all_message(n: count),
        leadingIcon: Icons.playlist_remove,
        confirmLabel: t.stat_clear_all_confirm,
        checkboxLabel: t.stat_sessions_clear_all_ack(n: count),
        checkboxKey: ackKey,
        requireCheckboxToConfirm: true,
      );
}

/// 弹出「清除全部会话」的防呆确认框；仅当用户**勾了确认再点清除**时返回 true。
/// [count] <= 0 时连框都不弹（没有会话可清，弹一个空框只是噪音）。
Future<bool> confirmClearAllStatSessions(
  BuildContext context,
  int count,
) async {
  if (count <= 0) return false;
  final FushiDestructiveConfirmResult? result =
      await showAppDialog<FushiDestructiveConfirmResult>(
    context: context,
    builder: (BuildContext ctx) => StatClearSessionsConfirmDialog(count: count),
  );
  return result != null;
}
