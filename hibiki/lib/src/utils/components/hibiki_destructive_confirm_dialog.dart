import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

/// [HibikiDestructiveConfirmDialog] 的返回值。
///
/// pop `null` = 取消；非 null = 已确认，[checked] 携带可选勾选项状态
/// （无 [HibikiDestructiveConfirmDialog.checkboxLabel] 时恒为 false）。
@immutable
class HibikiDestructiveConfirmResult {
  const HibikiDestructiveConfirmResult({required this.checked});

  final bool checked;
}

/// 全 app 统一的「确认销毁」对话框。
///
/// 巡检（docs/reviews/2026-07-22-ui-ux-survey.md）发现同一语义至少四种实现
/// 并存：ReaderHistoryDeleteDialog、CollectionDeleteDialog、两个合集详情页的
/// 裸 AlertDialog。本组件以 ReaderHistoryDeleteDialog 的观感为基准
/// （HibikiDialogFrame + HibikiModalSheetFrame + adaptiveDialogAction），
/// 增加可选勾选项（如「连同书籍本体一起删除」），供各处收口。
///
/// 用法：`showAppDialog<HibikiDestructiveConfirmResult>(...)` 后判空即可；
/// 确认按钮文案默认 t.dialog_delete，可换（如「清空」「移除」）。
class HibikiDestructiveConfirmDialog extends StatefulWidget {
  const HibikiDestructiveConfirmDialog({
    required this.title,
    required this.message,
    this.confirmLabel,
    this.leadingIcon = Icons.delete_outline,
    this.checkboxLabel,
    this.checkboxInitialValue = false,
    super.key,
  });

  final String title;
  final String message;

  /// 确认按钮文案；null 用 t.dialog_delete。
  final String? confirmLabel;

  final IconData leadingIcon;

  /// 非 null 时在正文下方渲染一个勾选行（如「连同本体删除」）。
  final String? checkboxLabel;

  final bool checkboxInitialValue;

  @override
  State<HibikiDestructiveConfirmDialog> createState() =>
      _HibikiDestructiveConfirmDialogState();
}

class _HibikiDestructiveConfirmDialogState
    extends State<HibikiDestructiveConfirmDialog> {
  late bool _checked = widget.checkboxInitialValue;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: HibikiModalSheetFrame(
        title: widget.title,
        leadingIcon: widget.leadingIcon,
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(widget.message, style: tokens.type.listSubtitle),
            if (widget.checkboxLabel != null) ...[
              SizedBox(height: tokens.spacing.gap),
              HibikiListItem(
                density: HibikiListDensity.compact,
                padding: EdgeInsets.zero,
                title: Text(widget.checkboxLabel!),
                // 勾选状态由整行 onTap 驱动；Checkbox 本身既不接指针也不进
                // 焦点遍历（单站点契约，行即唯一停靠点）。
                leading: ExcludeFocus(
                  child: IgnorePointer(
                    child: Checkbox(
                      value: _checked,
                      onChanged: (_) {},
                    ),
                  ),
                ),
                onTap: () => setState(() => _checked = !_checked),
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
                HibikiDestructiveConfirmResult(checked: _checked),
              ),
              child: Text(widget.confirmLabel ?? t.dialog_delete),
            ),
          ],
        ),
      ),
    );
  }
}
