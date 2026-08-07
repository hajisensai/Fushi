import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

/// 批量打标签对话框的共享外壳（视频 tab 与书架共用）。
///
/// 只封装两侧近逐字重复的对话框 chrome：[FushiDialogFrame]（520 宽 / 0.86 高上限）套
/// [FushiModalSheetFrame]（标题 + 标签图标 + 统一内边距 + 取消/应用底栏）。三态标签行与
/// apply 落库逻辑在两侧各自分叉（视频是单一 bookUid 集合、书架含 epub+srt 双类分支，且
/// 书架意图行走 TODO-308 文字+语义图标改版），故不在此共享——本组件只吃 [body] /
/// [canApply] / [onApply] 三个注入点，保持两侧原有 UI 行为不变。
class BatchTagPickerDialogFrame extends StatelessWidget {
  const BatchTagPickerDialogFrame({
    required this.body,
    required this.canApply,
    required this.onApply,
    super.key,
  });

  /// 对话框主体：逐标签三态意图行列表（各表面自行构造）。
  final Widget body;

  /// 是否有任何「添加/移除」意图待应用；为 false 时「应用」按钮禁用。
  final bool canApply;

  /// 点击「应用」的回调（各表面自行落库到对应 DB 方法）。
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.batch_tag_title,
        leadingIcon: Icons.sell_outlined,
        scrollable: true,
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
        body: body,
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
              isDefaultAction: true,
              onPressed: canApply ? onApply : null,
              child: Text(t.batch_tag_apply),
            ),
          ],
        ),
      ),
    );
  }
}
