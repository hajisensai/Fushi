/// 收藏色的圆点选择器（高亮样式页「新收藏颜色」与收藏夹行「改颜色」共用）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';

/// 一个收藏色圆点：选中时描边；按下有缩放反馈；在 [FushiFocusRoot] 下注册成一个
/// 焦点停靠点（方向键 / 手柄能走到、Enter 选中）。
class FavoriteHighlightColorDot extends StatelessWidget {
  const FavoriteHighlightColorDot({
    super.key,
    required this.color,
    required this.selected,
    required this.semanticLabel,
    required this.onTap,
    this.focusIdPrefix = 'favorite-color-dot',
  });

  final Color color;
  final bool selected;
  final String semanticLabel;
  final VoidCallback onTap;
  final String focusIdPrefix;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool focusRoot = FushiFocusRoot.maybeControllerOf(context) != null;
    final Widget dot = Semantics(
      button: true,
      selected: selected,
      label: semanticLabel,
      child: FushiPressScale(
        child: InkResponse(
          onTap: onTap,
          radius: 20,
          // 焦点根下由外层 [FushiActivatableFocusTarget] 做唯一的焦点停靠点。
          canRequestFocus: !focusRoot,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: AnimatedContainer(
              duration: fushiMotionDuration(context, FushiMotion.short),
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? cs.onSurface : Colors.transparent,
                  width: 2.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!focusRoot) return dot;
    return FushiActivatableFocusTarget(
      focusIdPrefix: focusIdPrefix,
      onTap: onTap,
      child: dot,
    );
  }
}
