import 'package:flutter/material.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/visual/gamepad_button_assets.dart';
import 'package:fushi/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

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

  /// 胶囊（肩键/扳机）footprint：宽 = [diameter] × 此倍数（布局与测试共用真相）。
  static const double pillWidthFactor = 1.6;

  /// 胶囊 footprint：高 = [diameter] × 此倍数。
  static const double pillHeightFactor = 0.75;

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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
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
      width: isPill ? diameter * pillWidthFactor : diameter,
      height: isPill ? diameter * pillHeightFactor : diameter,
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
    FushiDesignTokens tokens,
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
      width: isPill ? diameter * pillWidthFactor : diameter,
      height: isPill ? diameter * pillHeightFactor : diameter,
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

/// 十字键单臂的数据（按钮身份 + 绑定态 + 点击路由），由 [GamepadDpadCluster] 渲染。
@immutable
class GamepadDpadArm {
  const GamepadDpadArm({
    required this.button,
    required this.bound,
    this.onTap,
  });

  /// 方向臂的逻辑按钮（DpadUp/Down/Left/Right，序列化恒定）。
  final GamepadButton button;

  /// 是否已绑（已绑高亮）。
  final bool bound;

  /// 点击回调；null 表示不可点。
  final VoidCallback? onTap;
}

/// 一体式十字键簇（TODO-942 v3）：真实手柄的十字键是**一个整体十字**，不是四颗
/// 散装圆钮（用户截图里「十字键裂成散块」的修复）。
///
/// 底座画一个完整十字（两条圆角横竖条取并集）+ 中枢圆点；四个方向臂各自仍是
/// 独立的点击/高亮目标——`Key('gamepad_btn_DpadX')`、绑定高亮、已绑/未绑点击
/// 路由语义与其他按钮完全一致，只是视觉上聚合成一个十字。着色纪律同机身外壳：
/// 从 onSurface/surface 对比对儿推导，任何主题下可见。
class GamepadDpadCluster extends StatelessWidget {
  const GamepadDpadCluster({
    super.key,
    required this.size,
    required this.up,
    required this.down,
    required this.left,
    required this.right,
  });

  /// 簇边长（正方形）。
  final double size;

  final GamepadDpadArm up;
  final GamepadDpadArm down;
  final GamepadDpadArm left;
  final GamepadDpadArm right;

  /// 十字臂厚度占比（相对簇边长）。
  static const double armThicknessFactor = 0.34;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double thickness = size * armThicknessFactor;
    final double armLength = (size - thickness) / 2;
    final Color crossFill = Color.alphaBlend(
        scheme.onSurface.withValues(alpha: 0.14), scheme.surface);
    final Color crossLine = scheme.onSurface.withValues(alpha: 0.45);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: CustomPaint(
              painter: _DpadCrossPainter(
                fill: crossFill,
                line: crossLine,
                thicknessFactor: armThicknessFactor,
              ),
            ),
          ),
          _buildArm(
            scheme,
            up,
            Rect.fromLTWH(armLength, 0, thickness, armLength),
            Icons.arrow_drop_up,
          ),
          _buildArm(
            scheme,
            down,
            Rect.fromLTWH(armLength, size - armLength, thickness, armLength),
            Icons.arrow_drop_down,
          ),
          _buildArm(
            scheme,
            left,
            Rect.fromLTWH(0, armLength, armLength, thickness),
            Icons.arrow_left,
          ),
          _buildArm(
            scheme,
            right,
            Rect.fromLTWH(size - armLength, armLength, armLength, thickness),
            Icons.arrow_right,
          ),
        ],
      ),
    );
  }

  Widget _buildArm(
    ColorScheme scheme,
    GamepadDpadArm arm,
    Rect rect,
    IconData icon,
  ) {
    // 圆角随臂厚缩放（几何推导，非 MD3 尺寸决策）。
    final Radius radius = Radius.circular(size * armThicknessFactor * 0.24);
    final RoundedRectangleBorder shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(radius),
      side: arm.bound
          ? BorderSide(color: scheme.primary, width: 1.5)
          : BorderSide.none,
    );
    final Widget content = Container(
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: arm.bound ? scheme.primaryContainer : const Color(0x00000000),
        shape: shape,
      ),
      child: Icon(
        icon,
        size: rect.shortestSide * 0.9,
        color: arm.bound ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
      ),
    );
    return Positioned(
      key: Key('gamepad_btn_${arm.button.label}'),
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: arm.onTap == null
          ? content
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: arm.onTap,
                customBorder: shape,
                child: content,
              ),
            ),
    );
  }
}

/// 十字键底座：两条圆角横竖条取并集成整体十字 + 中枢圆点。
class _DpadCrossPainter extends CustomPainter {
  const _DpadCrossPainter({
    required this.fill,
    required this.line,
    required this.thicknessFactor,
  });

  final Color fill;
  final Color line;
  final double thicknessFactor;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = size.shortestSide * thicknessFactor;
    final Radius r = Radius.circular(t * 0.28);
    final Rect vertical =
        Rect.fromLTWH((size.width - t) / 2, 0, t, size.height);
    final Rect horizontal =
        Rect.fromLTWH(0, (size.height - t) / 2, size.width, t);
    final Path cross = Path.combine(
      PathOperation.union,
      Path()..addRRect(RRect.fromRectAndRadius(vertical, r)),
      Path()..addRRect(RRect.fromRectAndRadius(horizontal, r)),
    );

    canvas.drawPath(cross, Paint()..color = fill);

    final double strokeWidth =
        (size.shortestSide * 0.02).clamp(1.0, 2.0).toDouble();
    final Paint linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = line;
    canvas.drawPath(cross, linePaint);

    // 中枢圆点（真实十字键的中心枢轴）。
    canvas.drawCircle(
      size.center(Offset.zero),
      t * 0.22,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = line.withValues(alpha: 0.30),
    );
  }

  @override
  bool shouldRepaint(_DpadCrossPainter old) =>
      old.fill != fill ||
      old.line != line ||
      old.thicknessFactor != thicknessFactor;
}
