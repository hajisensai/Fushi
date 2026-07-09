import 'package:flutter/material.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_button_assets.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

/// 手柄按钮外形（TODO-942 P1）：面键/摇杆/系统键是圆钮，肩键/扳机是横向胶囊。
enum GamepadPadShape { circle, pill }

/// 单个手柄按钮图（TODO-942：改贴 Kenney「Input Prompts」CC0 现成素材，替代手绘
/// 圆钮 + 文字符号，用户决策「不要手绘，抄现成的正经手柄图标」）。
///
/// 渲染分两层：
/// - **有素材**（绝大多数按钮）：贴 [GamepadButtonAssets.assetFor] 返回的品牌图标
///   （Xbox 彩色 ABXY / PlayStation ✕○□△ / Switch 黑底 ABXY 等），已绑（[bound]）时
///   在图标下垫 primaryContainer 高亮底 + primary 描边，未绑透明。
/// - **无素材**（如 PlayStation 无 PS/Guide 键图标）：回退到旧的绘制符号占位
///   （[GamepadGlyphs.glyphFor] / [overrideSymbol]），永不缺图。
///
/// 品牌只决定素材/符号/配色，绝不进入任何 binding 序列化（[GamepadButton.label]
/// 恒定）。`Key('gamepad_btn_<label>')` 由上层布局视图注入，供 widget 行为测试定位；
/// 高亮与否完全由上层 `ReverseBindingIndex` 决定后传入。
class GamepadButtonWidget extends StatelessWidget {
  const GamepadButtonWidget({
    super.key,
    required this.button,
    required this.brand,
    required this.bound,
    this.onTap,
    this.diameter = 40,
    this.shape = GamepadPadShape.circle,
    this.overrideSymbol,
  });

  /// 本图代表的手柄按钮（用于上层判定高亮 / 路由点击；本 widget 不直接读绑定）。
  final GamepadButton button;

  /// 显示品牌（Xbox/PlayStation/Switch）——只换素材/符号/配色，不改序列化。
  final GamepadBrand brand;

  /// 是否已绑（已绑高亮）。
  final bool bound;

  /// 点击回调；null 表示不可点。
  final VoidCallback? onTap;

  /// 圆形按钮直径（胶囊形以此为高度基准）。
  final double diameter;

  /// 外形：圆钮（默认）或胶囊（肩键/扳机）——决定高亮底/描边形状。
  final GamepadPadShape shape;

  /// 无素材回退时的显示符号覆盖（方向键箭头等）；null 走 [GamepadGlyphs.glyphFor]。
  final String? overrideSymbol;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final String? assetPath = GamepadButtonAssets.assetFor(button, brand);

    final bool isPill = shape == GamepadPadShape.pill;
    final ShapeBorder inkShape =
        isPill ? const StadiumBorder() : const CircleBorder();

    final Widget knob = assetPath != null
        ? _buildAssetKnob(assetPath, scheme, isPill)
        : _buildGlyphKnob(theme, scheme, tokens, isPill);

    if (onTap == null) return knob;

    return Material(
      type: MaterialType.transparency,
      shape: inkShape,
      child: InkWell(
        onTap: onTap,
        customBorder: inkShape,
        child: knob,
      ),
    );
  }

  /// 贴现成素材图（TODO-942 主路径）。已绑：图标下垫 primaryContainer 高亮底 +
  /// primary 描边；未绑：透明底，只显图标。高亮底形状随 [isPill]（圆钮/胶囊）。
  Widget _buildAssetKnob(String assetPath, ColorScheme scheme, bool isPill) {
    final BorderSide side =
        bound ? BorderSide(color: scheme.primary, width: 1.5) : BorderSide.none;
    final ShapeBorder shapeBorder =
        isPill ? StadiumBorder(side: side) : CircleBorder(side: side);
    // 已绑填 primaryContainer，未绑透明——高亮/普通两态占位一致（footprint 不跳）。
    final Color background =
        bound ? scheme.primaryContainer : const Color(0x00000000);
    return Container(
      width: isPill ? diameter * 1.5 : diameter,
      height: diameter,
      alignment: Alignment.center,
      padding: EdgeInsets.all(diameter * 0.12),
      decoration: ShapeDecoration(color: background, shape: shapeBorder),
      child: Image.asset(
        assetPath,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      ),
    );
  }

  /// 无素材回退：旧的绘制符号占位（保留品牌符号/配色，永不缺图）。
  Widget _buildGlyphKnob(
    ThemeData theme,
    ColorScheme scheme,
    HibikiDesignTokens tokens,
    bool isPill,
  ) {
    final GamepadButtonGlyph glyph = GamepadGlyphs.glyphFor(button, brand);
    final String symbol = overrideSymbol ?? glyph.symbol;

    final Color faceColor =
        bound ? scheme.primaryContainer : tokens.surfaces.card;
    final Color borderColor = bound ? scheme.primary : scheme.outlineVariant;
    final Color baseFg =
        bound ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    final Color fg = glyph.accent ?? baseFg;

    final BorderSide side = BorderSide(
      color: borderColor,
      width: bound ? 1.5 : 1,
    );

    return Container(
      width: isPill ? diameter * 1.8 : diameter,
      height: isPill ? diameter * 0.72 : diameter,
      alignment: Alignment.center,
      decoration: isPill
          ? ShapeDecoration(
              color: faceColor,
              shape: StadiumBorder(side: side),
            )
          : BoxDecoration(
              color: faceColor,
              shape: BoxShape.circle,
              border: Border.fromBorderSide(side),
            ),
      child: Text(
        symbol,
        maxLines: 1,
        overflow: TextOverflow.clip,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelMedium?.copyWith(
          color: fg,
          fontWeight: bound ? FontWeight.w700 : FontWeight.w600,
        ),
      ),
    );
  }
}
