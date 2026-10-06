import 'package:flutter/material.dart';

import 'package:fushi/src/media/library_progress_reset.dart';
import 'package:fushi/src/sync/deletion_disclosure.dart'
    show DeleteConfirmCheckboxRow;
import 'package:fushi/utils.dart';

/// 「重置阅读状态 / 清除观看进度」确认框（书架、漫画库、视频库共用，单卡与批量同一份）。
///
/// 正文说清会发生什么（进度归零、改为未读 / 未看、离开「继续」区）；下面两条互斥的
/// 可选勾选决定学习记录怎么处理，**默认都不勾**——统计是用户的学习数据，误删代价高：
///  * 「同时撤销最近一次打开的记录」：误点场景专用，只撤最近那一次会话；
///  * 「同时清除它的全部学习记录」：破坏性最强，红色勾选。
///
/// 结构与删除确认框（`ReaderHistoryDeleteDialog` / `StatDeleteConfirmDialog`）一致：
/// [FushiDialogFrame] + [FushiModalSheetFrame] + 破坏性确认动作。
class LibraryProgressResetDialog extends StatefulWidget {
  const LibraryProgressResetDialog({
    required this.title,
    required this.message,
    this.itemTitle,
    this.showRecordOptions = true,
    super.key,
  });

  /// 对话框标题（书 = 「重置阅读状态」，视频 = 「清除观看进度」）。
  final String title;

  /// 正文说明。
  final String message;

  /// 单项时显示在正文上方的条目名；批量时为 null（正文里已写数量）。
  final String? itemTitle;

  /// false = 这一处没有可安全处理的统计身份（如纯字幕书），不摆勾选，恒返回
  /// [StudyRecordResetScope.keep]。
  final bool showRecordOptions;

  @override
  State<LibraryProgressResetDialog> createState() =>
      _LibraryProgressResetDialogState();
}

class _LibraryProgressResetDialogState
    extends State<LibraryProgressResetDialog> {
  StudyRecordResetScope _records = StudyRecordResetScope.keep;

  void _toggle(StudyRecordResetScope scope, bool on) {
    setState(() => _records = on ? scope : StudyRecordResetScope.keep);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? itemTitle = widget.itemTitle;
    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: FushiModalSheetFrame(
        title: widget.title,
        leadingIcon: Icons.restart_alt_outlined,
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
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (itemTitle != null && itemTitle.trim().isNotEmpty) ...<Widget>[
              Text(
                itemTitle,
                style: tokens.type.listTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: tokens.spacing.gap),
            ],
            Text(widget.message, style: tokens.type.listSubtitle),
            if (widget.showRecordOptions) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              DeleteConfirmCheckboxRow(
                key: const ValueKey<String>('library-progress-reset-last'),
                title: t.library_progress_reset_records_last_session,
                subtitle: t.library_progress_reset_records_last_session_desc,
                value: _records == StudyRecordResetScope.lastSession,
                onChanged: (bool v) =>
                    _toggle(StudyRecordResetScope.lastSession, v),
              ),
              DeleteConfirmCheckboxRow(
                key: const ValueKey<String>('library-progress-reset-all'),
                title: t.library_progress_reset_records_all,
                subtitle: t.library_progress_reset_records_all_desc,
                value: _records == StudyRecordResetScope.all,
                onChanged: (bool v) => _toggle(StudyRecordResetScope.all, v),
                destructive: true,
              ),
            ],
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(
                context,
                widget.showRecordOptions
                    ? _records
                    : StudyRecordResetScope.keep,
              ),
              child: Text(t.library_progress_reset_confirm),
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹出 [LibraryProgressResetDialog]；返回用户选的记录处理方式，取消 / 点外面关闭
/// 返回 null（调用方什么都不做）。
Future<StudyRecordResetScope?> showLibraryProgressResetDialog(
  BuildContext context, {
  required String title,
  required String message,
  String? itemTitle,
  bool showRecordOptions = true,
}) {
  return showAppDialog<StudyRecordResetScope>(
    context: context,
    builder: (BuildContext _) => LibraryProgressResetDialog(
      title: title,
      message: message,
      itemTitle: itemTitle,
      showRecordOptions: showRecordOptions,
    ),
  );
}
