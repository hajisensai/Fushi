import 'package:flutter/material.dart';
import 'package:hibiki/utils.dart';

/// 各导入对话框逐字相同的外框脚手架（HibikiDialogFrame 560/0.86 +
/// HibikiModalSheetFrame 同 padding + Wrap footer，空 actions 时无 footer）。
///
/// 标题渲染两态刻意各异——book 在 body 里渲 Widget 标题（2 行省略），其余对话框
/// 用 sheet 的 [title] 槽——由调用方各自保留，不在此归一。原寄生在
/// book_import_dialog.dart 里被反向依赖，迁出到共享目录（审计 §1-K）。
class ImportDialogFrame extends StatelessWidget {
  const ImportDialogFrame({
    required this.leadingIcon,
    required this.body,
    required this.actions,
    this.title,
    super.key,
  });

  final IconData leadingIcon;
  final String? title;
  final Widget body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 560,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: title,
        leadingIcon: leadingIcon,
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
        scrollable: true,
        body: body,
        footer: actions.isEmpty
            ? null
            : Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: actions,
              ),
      ),
    );
  }
}
