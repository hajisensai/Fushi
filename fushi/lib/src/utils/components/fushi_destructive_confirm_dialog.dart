import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

/// [FushiDestructiveConfirmDialog] 的返回值。
///
/// pop `null` = 取消；非 null = 已确认，[checked] 携带可选勾选项状态
/// （无 [FushiDestructiveConfirmDialog.checkboxLabel] 时恒为 false）。
@immutable
class FushiDestructiveConfirmResult {
  const FushiDestructiveConfirmResult({required this.checked});

  final bool checked;
}

/// 全 app 统一的「确认销毁」对话框。
///
/// 巡检（docs/reviews/2026-07-22-ui-ux-survey.md）发现同一语义至少四种实现
/// 并存：ReaderHistoryDeleteDialog、CollectionDeleteDialog、两个合集详情页的
/// 裸 AlertDialog。本组件以 ReaderHistoryDeleteDialog 的观感为基准
/// （FushiDialogFrame + FushiModalSheetFrame + adaptiveDialogAction），
/// 增加可选勾选项（如「连同书籍本体一起删除」），供各处收口。
///
/// 用法：`showAppDialog<FushiDestructiveConfirmResult>(...)` 后判空即可；
/// 确认按钮文案默认 t.dialog_delete，可换（如「清空」「移除」）。
class FushiDestructiveConfirmDialog extends StatefulWidget {
  const FushiDestructiveConfirmDialog({
    required this.title,
    required this.message,
    this.confirmLabel,
    this.leadingIcon = Icons.delete_outline,
    this.checkboxLabel,
    this.checkboxInitialValue = false,
    this.checkedDisclosure,
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

  /// 勾选框被勾上后追加渲染的「会被删除 / 会被保留」逐项披露。
  ///
  /// 根因（BUG-1305）：本对话框的正文 [message] 与勾选行是两个静态节点，勾选翻转
  /// 语义时正文不跟随。合集删除因此出现「删除合集不会删除其中的视频」与「同时删除
  /// 其中的书」同屏并存，而代码按勾选递归删了每本书的解压目录和有声书目录。披露挂
  /// 在勾选状态上，正文才不会再和实际行为说反话。
  final DeletionDisclosure? checkedDisclosure;

  @override
  State<FushiDestructiveConfirmDialog> createState() =>
      _FushiDestructiveConfirmDialogState();
}

class _FushiDestructiveConfirmDialogState
    extends State<FushiDestructiveConfirmDialog> {
  late bool _checked = widget.checkboxInitialValue;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: FushiModalSheetFrame(
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
              FushiListItem(
                density: FushiListDensity.compact,
                padding: EdgeInsets.zero,
                // BUG-1291：勾选文案是整句解释（「同时删除其中的视频（保留你的
                // 原始视频文件）」），不是列表里的标题短语。[FushiListItem] 的
                // titleMaxLines 默认 1 + ellipsis，在 420 宽的对话框里会把括号
                // 里的免责说明整段吃掉，用户读到的是「…保留你的原始视…」——恰好
                // 是最需要看清的那半句。此处父容器高度自由（外层
                // [FushiDialogFrame] 默认 scrollable），放开行数不会像
                // BUG-1184 的固定高容器那样撑破布局。
                titleMaxLines: 3,
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
              if (_checked && widget.checkedDisclosure != null) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                DeletionDisclosureView(
                  disclosure: widget.checkedDisclosure!,
                ),
              ],
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
                FushiDestructiveConfirmResult(checked: _checked),
              ),
              child: Text(widget.confirmLabel ?? t.dialog_delete),
            ),
          ],
        ),
      ),
    );
  }
}
