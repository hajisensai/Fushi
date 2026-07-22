import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

/// 书架卡片 footer / 勾选圈 / 选中罩的共享实现。
///
/// 巡检（PR-3）发现 `series_shelf_card.dart` 与
/// `reader_history/card_widgets.part.dart` 各持一份逐行相同的 footer 与勾选圈
/// 手抄（两处 40px 标题 footer、三处圆形对勾、两处选中罩），本文件收口为共享
/// 组件；eink 主题的实心色替代（半透明 alpha 在墨水屏合成抖动灰）也只写在这里。

/// 书架卡片封面下方的固定高标题 footer（两行省略、居中、加粗 metadata 字号）。
///
/// 高度由调用方的 SizedBox 固定（书卡用 `kShelfTitleFooterHeight`，系列折叠卡
/// 用 [ShelfCardFooter.height]，二者同值），长书名换行不得撑动网格。
class ShelfCardFooter extends StatelessWidget {
  const ShelfCardFooter({required this.title, super.key});

  /// 与 `kShelfTitleFooterHeight` 同值的 footer 固定高（系列卡无法 import
  /// part-of 常量，挂在组件上共享）。
  static const double height = 40.0;

  final String title;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.spacing.gap * 0.75,
        tokens.spacing.gap / 2,
        tokens.spacing.gap * 0.75,
        0,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: Text(
          title,
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
          textAlign: TextAlign.center,
          softWrap: true,
          style: tokens.type.metadata.copyWith(
            color: tokens.surfaces.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// 多选态的圆形对勾（书卡封面左上角 / 合集行头 / 系列折叠卡共用）。
///
/// 点击穿透由内建 [IgnorePointer] 保证（勾选切换走卡片/行头自身的 onTap）。
/// eink：未选中底色不再用 `page.withValues(alpha: 0.7)`（半透明在墨水屏合成
/// 抖动中间灰），改实心页面色 + 描边。
class ShelfSelectionCheck extends StatelessWidget {
  const ShelfSelectionCheck({required this.selected, super.key});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final Color selectionColor = tokens.surfaces.primary;
    final bool eink = isEinkTheme(context);
    final Color idleFill = eink
        ? tokens.surfaces.page
        : tokens.surfaces.page.withValues(alpha: 0.7);
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          color: selected ? selectionColor : idleFill,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? selectionColor : tokens.surfaces.outline,
            width: 1.5,
          ),
        ),
        padding: EdgeInsets.all(tokens.spacing.gap / 4),
        child: Icon(
          Icons.check,
          size: tokens.spacing.gap * 1.75,
          color: selected ? theme.colorScheme.onPrimary : Colors.transparent,
        ),
      ),
    );
  }
}

/// 选中态整卡覆盖罩（书卡 / 系列折叠卡共用），配 `Positioned.fill` 使用。
///
/// 常规主题为 primary 12% 半透明罩；eink 半透明罩合成抖动灰且 primary 已塌缩，
/// 改 2px 实心描边作唯一选中信号（与 HibikiCard eink 选中态同语义）。
class ShelfSelectedOverlay extends StatelessWidget {
  const ShelfSelectedOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    return IgnorePointer(
      child: DecoratedBox(
        decoration: eink
            ? BoxDecoration(
                border: Border.all(color: tokens.surfaces.outline, width: 2),
                borderRadius: tokens.radii.cardRadius,
              )
            : BoxDecoration(
                color: tokens.surfaces.primary.withValues(alpha: 0.12),
                borderRadius: tokens.radii.cardRadius,
              ),
      ),
    );
  }
}
