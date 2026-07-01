import 'package:flutter/material.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

/// 单个手柄按钮图（TODO-1050a / TODO-1060①：把 [GamepadGlyphs] 数据层接进可视化配置页）。
///
/// 纯展示 + 点击入口：按 [brand] 用 [GamepadGlyphs.glyphFor] 取显示符号/品牌强调色，
/// 圆形按钮观感（面键在真手柄上是圆钮）。已绑（[bound]）用 primary 容器高亮，未绑用 card
/// 底色。品牌只决定显示符号/配色，绝不进入任何 binding 序列化（[GamepadButton.label] 恒定）。
///
/// `Key('gamepad_btn_<label>')` 由 [KeyboardLayoutView] 注入，供 widget 行为测试定位。
/// 本 widget 不持有绑定状态，高亮与否完全由上层 `ReverseBindingIndex` 决定后传入。
class GamepadButtonWidget extends StatelessWidget {
  const GamepadButtonWidget({
    super.key,
    required this.button,
    required this.brand,
    required this.bound,
    this.onTap,
    this.diameter = 40,
  });

  /// 本图代表的手柄按钮（用于上层判定高亮 / 路由点击；本 widget 不直接读绑定）。
  final GamepadButton button;

  /// 显示品牌（Xbox/PlayStation）——只换符号/配色，不改序列化。
  final GamepadBrand brand;

  /// 是否已绑（已绑高亮）。
  final bool bound;

  /// 点击回调；null 表示不可点。
  final VoidCallback? onTap;

  /// 圆形按钮直径。
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final GamepadButtonGlyph glyph = GamepadGlyphs.glyphFor(button, brand);

    // 三态配色，全走 scheme / token 派生（过 md3 静态守卫，无裸颜色字面量）：
    // - bound：primaryContainer 底 / primary 边 / onPrimaryContainer 字。
    // - unbound：card 底 / outlineVariant 边 / onSurfaceVariant 字。
    // 面键品牌强调色（glyph.accent）叠加为字色，让 A/B/X/Y、✕○□△ 保留品牌识别度。
    final Color faceColor =
        bound ? scheme.primaryContainer : tokens.surfaces.card;
    final Color borderColor = bound ? scheme.primary : scheme.outlineVariant;
    final Color baseFg =
        bound ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    final Color fg = glyph.accent ?? baseFg;

    final Widget knob = Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: faceColor,
        shape: BoxShape.circle,
        border: Border.all(
          color: borderColor,
          width: bound ? 1.5 : 1,
        ),
      ),
      child: Text(
        glyph.symbol,
        maxLines: 1,
        overflow: TextOverflow.clip,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelMedium?.copyWith(
          color: fg,
          fontWeight: bound ? FontWeight.w700 : FontWeight.w600,
        ),
      ),
    );

    if (onTap == null) return knob;

    return Material(
      type: MaterialType.transparency,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: knob,
      ),
    );
  }
}
