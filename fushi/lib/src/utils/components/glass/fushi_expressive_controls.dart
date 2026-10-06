import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// Material 3 Expressive（2025-05）交互控件共享层的第二批：按钮尺寸档 / 形状、
// toggle 按钮、split button、FAB 三尺寸 + FAB menu，以及开关 thumb 图标、
// chip 强调色的公共几何与配色。规格全部取自 Compose Material3 的 token 文件
// （`ButtonXSmallTokens` … `ButtonXLargeTokens`、`SplitButtonSmallTokens`、
// `FabMenuBaselineTokens`，2026-10 androidx-main），CornerSmall/Medium/Large/
// ExtraLarge = 8 / 12 / 16 / 28。
//
// 形变 / 挤压动效沿用 fushi_expressive.dart 的弹簧（fast / default spatial），
// 墨水屏与系统「减少动画」下一律静止（[fushiExpressiveMotionEnabled]）。Apple
// 设计系统下这些组件映射到同一 API 的 iOS 原生形态（玻璃胶囊 / 系统菜单），
// 不出现 Expressive 形变。

// ---------------------------------------------------------------------------
// 按钮尺寸档 / 形状
// ---------------------------------------------------------------------------

/// M3 Expressive 按钮尺寸档：XS 32 / S 40（默认）/ M 56 / L 96 / XL 136。
enum FushiButtonSize { xs, s, m, l, xl }

/// M3 Expressive 按钮形状：圆（全胶囊，默认）/ 方（按尺寸的圆角矩形）。
enum FushiButtonShape { round, square }

/// 一个尺寸档的几何（Compose `Button*Tokens`）。
@immutable
class FushiButtonMetrics {
  const FushiButtonMetrics._({
    required this.height,
    required this.horizontalPadding,
    required this.iconSize,
    required this.iconGap,
    required this.squareRadius,
    required this.pressedRadius,
    required this.outlineWidth,
  });

  /// 容器高度。
  final double height;

  /// 左右留白（leading / trailing space）。
  final double horizontalPadding;

  /// 图标尺寸。
  final double iconSize;

  /// 图标与文字的间距。
  final double iconGap;

  /// 方形按钮（及圆形 toggle 选中态）的圆角。
  final double squareRadius;

  /// 按下时收缩到的圆角。
  final double pressedRadius;

  /// 描边按钮的描边宽度。
  final double outlineWidth;

  static const FushiButtonMetrics _xs = FushiButtonMetrics._(
    height: 32,
    horizontalPadding: 12,
    iconSize: 20,
    iconGap: 8,
    squareRadius: 12,
    pressedRadius: 8,
    outlineWidth: 1,
  );
  static const FushiButtonMetrics _s = FushiButtonMetrics._(
    height: 40,
    horizontalPadding: 16,
    iconSize: 20,
    iconGap: 8,
    squareRadius: 12,
    pressedRadius: 8,
    outlineWidth: 1,
  );
  static const FushiButtonMetrics _m = FushiButtonMetrics._(
    height: 56,
    horizontalPadding: 24,
    iconSize: 24,
    iconGap: 8,
    squareRadius: 16,
    pressedRadius: 12,
    outlineWidth: 1,
  );
  static const FushiButtonMetrics _l = FushiButtonMetrics._(
    height: 96,
    horizontalPadding: 48,
    iconSize: 32,
    iconGap: 12,
    squareRadius: 28,
    pressedRadius: 16,
    outlineWidth: 2,
  );
  static const FushiButtonMetrics _xl = FushiButtonMetrics._(
    height: 136,
    horizontalPadding: 64,
    iconSize: 40,
    iconGap: 16,
    squareRadius: 28,
    pressedRadius: 16,
    outlineWidth: 3,
  );

  /// 某尺寸档的几何。
  static FushiButtonMetrics of(FushiButtonSize size) => switch (size) {
    FushiButtonSize.xs => _xs,
    FushiButtonSize.s => _s,
    FushiButtonSize.m => _m,
    FushiButtonSize.l => _l,
    FushiButtonSize.xl => _xl,
  };

  /// 该档的标签字阶：XS / S labelLarge、M titleMedium、L headlineSmall、
  /// XL headlineLarge（Expressive 的 emphasized 字重 600）。
  static TextStyle? labelStyleOf(FushiButtonSize size, TextTheme tt) {
    final TextStyle? base = switch (size) {
      FushiButtonSize.xs || FushiButtonSize.s => tt.labelLarge,
      FushiButtonSize.m => tt.titleMedium,
      FushiButtonSize.l => tt.headlineSmall,
      FushiButtonSize.xl => tt.headlineLarge,
    };
    return base?.copyWith(fontWeight: FontWeight.w600);
  }
}

/// 尺寸档对应的 ButtonStyle 片段（高度 / 留白 / 图标 / 字阶 / 描边宽），合并在
/// 调用方 style **之下**（调用方显式给的字段优先）。不含 shape：形状由
/// [FushiPressMorph] 逐帧给出（见 [fushiButtonMorphSpec]）。
ButtonStyle fushiButtonSizeStyle(
  BuildContext context,
  FushiButtonSize size, {
  bool outlined = false,
}) {
  final FushiButtonMetrics m = FushiButtonMetrics.of(size);
  final ThemeData theme = Theme.of(context);
  final TextStyle? label = FushiButtonMetrics.labelStyleOf(
    size,
    theme.textTheme,
  );
  return ButtonStyle(
    minimumSize: WidgetStatePropertyAll<Size>(Size(m.height, m.height)),
    maximumSize: WidgetStatePropertyAll<Size>(Size(double.infinity, m.height)),
    padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
      EdgeInsets.symmetric(horizontal: m.horizontalPadding),
    ),
    iconSize: WidgetStatePropertyAll<double>(m.iconSize),
    textStyle: label == null ? null : WidgetStatePropertyAll<TextStyle>(label),
    // 尺寸档自己定高，不再让密度 / 48dp 点击区补白二次改高度（XS 例外：
    // 32 高的按钮仍按 M3 规则补到 48 的点击区，见调用方 tapTargetSize）。
    visualDensity: VisualDensity.standard,
    side: outlined
        ? WidgetStateProperty.resolveWith<BorderSide?>((
            Set<WidgetState> states,
          ) {
            final ColorScheme cs = theme.colorScheme;
            return BorderSide(
              width: m.outlineWidth,
              color: states.contains(WidgetState.disabled)
                  ? cs.onSurface.withValues(alpha: 0.12)
                  : cs.outlineVariant,
            );
          })
        : null,
  );
}

/// [FushiPressMorph] 的形变参数：(按下圆角, 是否常驻方形, 方形圆角)。
///
/// - 圆形：静止全胶囊，按下弹到 [FushiButtonMetrics.pressedRadius]；
/// - 方形：常驻 [FushiButtonMetrics.squareRadius]，按下再收到 pressedRadius；
/// - toggle（[selected] 非 null）：圆形按钮选中变方，方形按钮选中变圆
///   （Compose `ToggleButtonDefaults.shapes` 的 checkedShape）。
({double pressedRadius, bool squared, double squareRadius})
fushiButtonMorphSpec(
  FushiButtonSize size,
  FushiButtonShape shape, {
  bool? selected,
}) {
  final FushiButtonMetrics m = FushiButtonMetrics.of(size);
  final bool square = shape == FushiButtonShape.square;
  final bool squared = selected == null
      ? square
      : (square ? !selected : selected);
  return (
    pressedRadius: m.pressedRadius,
    squared: squared,
    squareRadius: m.squareRadius,
  );
}

/// 不做动效（墨水屏 / 减少动画）时 [FushiPressMorph] 原样透传 style：方形与
/// toggle 选中态仍要静态圆角矩形。调用方 style 显式给了 shape 的不动。
ButtonStyle? fushiStaticSquareShape(
  ButtonStyle? style, {
  required bool squared,
  required double radius,
}) {
  if (!squared || style?.shape != null) return style;
  return (style ?? const ButtonStyle()).copyWith(
    shape: WidgetStatePropertyAll<OutlinedBorder>(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    ),
  );
}

// ---------------------------------------------------------------------------
// Toggle 按钮
// ---------------------------------------------------------------------------

/// [FushiToggleButton] 的配色变体（Compose `ToggleButtonDefaults`）。
enum FushiToggleButtonVariant { filled, tonal, outlined, elevated }

/// M3 Expressive toggle 按钮：选中态由按钮本身表达——颜色切换 + **形状变形**
/// （圆形按钮选中弹成方圆角，方形选中弹成胶囊，default spatial 弹簧），按下
/// 再收圆角（fast spatial）。
///
/// 配色：filled 未选 surfaceContainer + onSurfaceVariant、选中 primary +
/// onPrimary；tonal 未选 secondaryContainer、选中 secondary + onSecondary；
/// outlined 未选透明 + outlineVariant 描边、选中 inverseSurface；elevated 未选
/// surfaceContainerLow + primary 字、选中 primary + onPrimary。
///
/// 读屏：`toggled` 语义；键盘 / 手柄：Enter 切换（App 把裸空格中和了）。
/// Apple 设计系统：选中 = 强调色玻璃胶囊（FushiFilledButton），未选 = 中性
/// 玻璃胶囊（FushiFilledButton.tonal），不变形。
class FushiToggleButton extends StatefulWidget {
  const FushiToggleButton({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.label,
    this.icon,
    this.selectedIcon,
    this.variant = FushiToggleButtonVariant.filled,
    this.size = FushiButtonSize.s,
    this.shape = FushiButtonShape.round,
    this.focusNode,
    this.autofocus = false,
    this.tooltip,
  });

  final bool selected;
  final ValueChanged<bool>? onChanged;
  final Widget label;
  final Widget? icon;

  /// 选中时替换 [icon]（如 bookmark_border → bookmark）；null 沿用 [icon]。
  final Widget? selectedIcon;
  final FushiToggleButtonVariant variant;
  final FushiButtonSize size;
  final FushiButtonShape shape;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? tooltip;

  @override
  State<FushiToggleButton> createState() => _FushiToggleButtonState();
}

class _FushiToggleButtonState extends State<FushiToggleButton> {
  final WidgetStatesController _states = WidgetStatesController();

  @override
  void dispose() {
    _states.dispose();
    super.dispose();
  }

  (Color?, Color) _colors(ColorScheme cs, Set<WidgetState> states) {
    final bool on = states.contains(WidgetState.selected);
    if (states.contains(WidgetState.disabled)) {
      final Color fg = cs.onSurface.withValues(alpha: 0.38);
      return widget.variant == FushiToggleButtonVariant.outlined && !on
          ? (null, fg)
          : (cs.onSurface.withValues(alpha: 0.12), fg);
    }
    return switch (widget.variant) {
      FushiToggleButtonVariant.filled =>
        on
            ? (cs.primary, cs.onPrimary)
            : (cs.surfaceContainer, cs.onSurfaceVariant),
      FushiToggleButtonVariant.tonal =>
        on
            ? (cs.secondary, cs.onSecondary)
            : (cs.secondaryContainer, cs.onSecondaryContainer),
      FushiToggleButtonVariant.outlined =>
        on
            ? (cs.inverseSurface, cs.onInverseSurface)
            : (null, cs.onSurfaceVariant),
      FushiToggleButtonVariant.elevated =>
        on ? (cs.primary, cs.onPrimary) : (cs.surfaceContainerLow, cs.primary),
    };
  }

  ButtonStyle _style(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool outlined = widget.variant == FushiToggleButtonVariant.outlined;
    final ButtonStyle size = fushiButtonSizeStyle(
      context,
      widget.size,
      outlined: false,
    );
    final FushiButtonMetrics m = FushiButtonMetrics.of(widget.size);
    return size.copyWith(
      backgroundColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> s) => _colors(cs, s).$1,
      ),
      foregroundColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> s) => _colors(cs, s).$2,
      ),
      iconColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> s) => _colors(cs, s).$2,
      ),
      overlayColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> s,
      ) {
        final Color fg = _colors(cs, s).$2;
        if (s.contains(WidgetState.pressed)) return fg.withValues(alpha: 0.1);
        if (s.contains(WidgetState.hovered)) return fg.withValues(alpha: 0.08);
        if (s.contains(WidgetState.focused)) return fg.withValues(alpha: 0.1);
        return null;
      }),
      side: outlined
          ? WidgetStateProperty.resolveWith<BorderSide?>((Set<WidgetState> s) {
              if (s.contains(WidgetState.selected)) return BorderSide.none;
              return BorderSide(
                width: m.outlineWidth,
                color: s.contains(WidgetState.disabled)
                    ? cs.onSurface.withValues(alpha: 0.12)
                    : cs.outlineVariant,
              );
            })
          : null,
      elevation: WidgetStateProperty.resolveWith<double>(
        (Set<WidgetState> s) =>
            widget.variant == FushiToggleButtonVariant.elevated &&
                !s.contains(WidgetState.selected) &&
                !s.contains(WidgetState.disabled)
            ? 1
            : 0,
      ),
      shadowColor: WidgetStatePropertyAll<Color>(cs.shadow),
      surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      // 颜色由 WidgetState.selected 切换，交给 Material 的隐式补间；形状另由
      // 弹簧逐帧给出（FushiPressMorph 会把 animationDuration 置零，颜色此时
      // 瞬变——形变本身已足够醒目）。
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onChanged != null;
    final Widget? icon = widget.selected
        ? (widget.selectedIcon ?? widget.icon)
        : widget.icon;
    VoidCallback? onPressed;
    if (enabled) onPressed = () => widget.onChanged!(!widget.selected);
    Widget result;
    if (isGlassDesign(context)) {
      result = widget.selected
          ? (icon == null
                ? FushiFilledButton(
                    onPressed: onPressed,
                    focusNode: widget.focusNode,
                    autofocus: widget.autofocus,
                    child: widget.label,
                  )
                : FushiFilledButton.icon(
                    onPressed: onPressed,
                    focusNode: widget.focusNode,
                    autofocus: widget.autofocus,
                    icon: icon,
                    label: widget.label,
                  ))
          : (icon == null
                ? FushiFilledButton.tonal(
                    onPressed: onPressed,
                    focusNode: widget.focusNode,
                    autofocus: widget.autofocus,
                    child: widget.label,
                  )
                : FushiFilledButton.tonalIcon(
                    onPressed: onPressed,
                    focusNode: widget.focusNode,
                    autofocus: widget.autofocus,
                    icon: icon,
                    label: widget.label,
                  ));
    } else {
      _states.update(WidgetState.selected, widget.selected);
      final ({double pressedRadius, bool squared, double squareRadius}) spec =
          fushiButtonMorphSpec(
            widget.size,
            widget.shape,
            selected: widget.selected,
          );
      result = FushiPressMorph(
        enabled: enabled,
        style: isEinkTheme(context) ? null : _style(context),
        statesController: _states,
        pressedRadius: spec.pressedRadius,
        selected: spec.squared,
        selectedRadius: spec.squareRadius,
        builder:
            (
              BuildContext context,
              ButtonStyle? style,
              WidgetStatesController? controller,
            ) {
              final ButtonStyle? effective = fushiStaticSquareShape(
                style,
                squared: spec.squared && !fushiExpressiveMotionEnabled(context),
                radius: spec.squareRadius,
              );
              return icon == null
                  ? FilledButton(
                      onPressed: onPressed,
                      style: effective,
                      statesController: controller,
                      focusNode: widget.focusNode,
                      autofocus: widget.autofocus,
                      child: widget.label,
                    )
                  : FilledButton.icon(
                      onPressed: onPressed,
                      style: effective,
                      statesController: controller,
                      focusNode: widget.focusNode,
                      autofocus: widget.autofocus,
                      icon: icon,
                      label: widget.label,
                    );
            },
      );
    }
    result = Semantics(toggled: widget.selected, child: result);
    final String? tip = widget.tooltip;
    if (tip != null && tip.isNotEmpty) {
      result = FushiTooltip(message: tip, child: result);
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// Split button
// ---------------------------------------------------------------------------

/// [FushiSplitButton] 的配色变体。
enum FushiSplitButtonVariant { filled, tonal, outlined, elevated }

/// 内侧相邻角圆角（Compose `SplitButton*Tokens.InnerCornerCornerSize`：XS/S/M
/// 4，L 8，XL 12）与按下 / 悬停时放大到的内角（XS/S 12、M 12、L 16、XL 20）。
(double inner, double innerPressed) _splitInnerRadii(FushiButtonSize size) =>
    switch (size) {
      FushiButtonSize.xs || FushiButtonSize.s => (4, 12),
      FushiButtonSize.m => (4, 12),
      FushiButtonSize.l => (8, 16),
      FushiButtonSize.xl => (12, 20),
    };

/// M3 Expressive split button：主操作按钮 + 2dp 缝 + 下拉箭头按钮。
///
/// - 外侧两端全圆角，内侧相邻角小圆角，按下 / 悬停的那一半内角弹大
///   （fast spatial 弹簧）；
/// - 菜单打开时尾按钮弹成正圆（内角 → 50%），箭头转 180°（default spatial）；
/// - 菜单是 [MenuAnchor]（Apple 设计系统下同一个锚点，主题已换成系统菜单
///   外观），键盘 Enter / 方向键与手柄 A 都能开合与遍历，Esc 关闭。
class FushiSplitButton extends StatefulWidget {
  const FushiSplitButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.menuChildren,
    this.icon,
    this.variant = FushiSplitButtonVariant.filled,
    this.size = FushiButtonSize.s,
    this.menuTooltip,
    this.focusNode,
    this.autofocus = false,
  });

  final Widget label;
  final Widget? icon;
  final VoidCallback? onPressed;

  /// 下拉菜单项（[MenuItemButton] 等）；空表时尾按钮禁用。
  final List<Widget> menuChildren;
  final FushiSplitButtonVariant variant;
  final FushiButtonSize size;

  /// 尾按钮的提示 / 读屏标签（如「更多选项」）。
  final String? menuTooltip;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<FushiSplitButton> createState() => _FushiSplitButtonState();
}

class _FushiSplitButtonState extends State<FushiSplitButton>
    with TickerProviderStateMixin {
  final MenuController _menu = MenuController();
  final WidgetStatesController _leadStates = WidgetStatesController();
  final WidgetStatesController _trailStates = WidgetStatesController();
  late final FushiSpring _leadPress = FushiSpring(vsync: this);
  late final FushiSpring _trailPress = FushiSpring(vsync: this);
  late final FushiSpring _open = FushiSpring(
    vsync: this,
    spring: fushiExpressiveDefaultSpatial,
  );
  bool _menuOpen = false;

  /// 元素已停用（移出树 / 换父途中）。两个 statesController 归本 State 所有，
  /// 子树卸载时 InkWell 补发的 tap cancel / 失焦仍会回调过来，停用元素上不能
  /// 再查 Theme 等祖先（BUG-3058）。
  bool _deactivated = false;

  @override
  void deactivate() {
    _deactivated = true;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _deactivated = false;
    // 停用期间漏掉的开合回调在这里对齐（重新激活后紧接着就是 build）。
    final bool open = _menu.isOpen;
    if (_menuOpen != open) {
      _menuOpen = open;
      _open.animateTo(open ? 1 : 0, animate: false);
    }
  }

  @override
  void initState() {
    super.initState();
    _leadPress;
    _trailPress;
    _open;
    _leadStates.addListener(() => _onStates(_leadStates, _leadPress));
    _trailStates.addListener(() => _onStates(_trailStates, _trailPress));
  }

  void _onStates(WidgetStatesController c, FushiSpring spring) {
    if (!mounted || _deactivated) return;
    final bool active =
        c.value.contains(WidgetState.pressed) ||
        c.value.contains(WidgetState.hovered) ||
        c.value.contains(WidgetState.focused);
    spring.animateTo(
      active ? 1 : 0,
      animate: fushiExpressiveMotionEnabled(context),
    );
  }

  void _setOpen(bool open) {
    if (!mounted || _deactivated || _menuOpen == open) return;
    setState(() => _menuOpen = open);
    _open.animateTo(
      open ? 1 : 0,
      animate: fushiExpressiveMotionEnabled(context),
    );
  }

  void _toggleMenu() {
    if (_menu.isOpen) {
      _menu.close();
    } else {
      _menu.open();
    }
  }

  @override
  void dispose() {
    _leadStates.dispose();
    _trailStates.dispose();
    _leadPress.dispose();
    _trailPress.dispose();
    _open.dispose();
    super.dispose();
  }

  (Color?, Color) _colors(ColorScheme cs, Set<WidgetState> states) {
    if (states.contains(WidgetState.disabled)) {
      final Color fg = cs.onSurface.withValues(alpha: 0.38);
      return widget.variant == FushiSplitButtonVariant.outlined
          ? (null, fg)
          : (cs.onSurface.withValues(alpha: 0.12), fg);
    }
    return switch (widget.variant) {
      FushiSplitButtonVariant.filled => (cs.primary, cs.onPrimary),
      FushiSplitButtonVariant.tonal => (
        cs.secondaryContainer,
        cs.onSecondaryContainer,
      ),
      FushiSplitButtonVariant.outlined => (null, cs.onSurfaceVariant),
      FushiSplitButtonVariant.elevated => (cs.surfaceContainerLow, cs.primary),
    };
  }

  ButtonStyle _style(BuildContext context, {required EdgeInsets padding}) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiButtonMetrics m = FushiButtonMetrics.of(widget.size);
    return fushiButtonSizeStyle(context, widget.size).copyWith(
      padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(padding),
      minimumSize: WidgetStatePropertyAll<Size>(Size(m.height, m.height)),
      backgroundColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> s) => _colors(cs, s).$1,
      ),
      foregroundColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> s) => _colors(cs, s).$2,
      ),
      iconColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> s) => _colors(cs, s).$2,
      ),
      side: widget.variant == FushiSplitButtonVariant.outlined
          ? WidgetStateProperty.resolveWith<BorderSide?>(
              (Set<WidgetState> s) => BorderSide(
                width: m.outlineWidth,
                color: s.contains(WidgetState.disabled)
                    ? cs.onSurface.withValues(alpha: 0.12)
                    : cs.outlineVariant,
              ),
            )
          : null,
      elevation: WidgetStatePropertyAll<double>(
        widget.variant == FushiSplitButtonVariant.elevated ? 1 : 0,
      ),
      shadowColor: WidgetStatePropertyAll<Color>(cs.shadow),
      surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      animationDuration: Duration.zero,
    );
  }

  Widget _chevron(BuildContext context, double iconSize) {
    return AnimatedBuilder(
      animation: _open.animation,
      builder: (BuildContext context, Widget? child) => Transform.rotate(
        angle: math.pi * _open.value.clamp(0.0, 1.0),
        child: child,
      ),
      child: Icon(FushiIcons.expandMore, size: iconSize + 2),
    );
  }

  Widget _buildGlass(BuildContext context) {
    final bool hasMenu = widget.menuChildren.isNotEmpty;
    final Widget lead = widget.icon == null
        ? FushiFilledButton(
            onPressed: widget.onPressed,
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            child: widget.label,
          )
        : FushiFilledButton.icon(
            onPressed: widget.onPressed,
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            icon: widget.icon,
            label: widget.label,
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: <Widget>[
        lead,
        MenuAnchor(
          controller: _menu,
          onOpen: () => _setOpen(true),
          onClose: () => _setOpen(false),
          menuChildren: widget.menuChildren,
          builder: (BuildContext context, MenuController c, Widget? _) =>
              FushiIconButtonControl.filled(
                onPressed: hasMenu ? _toggleMenu : null,
                tooltip: widget.menuTooltip,
                icon: _chevron(context, 20),
              ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildGlass(context);
    final FushiButtonMetrics m = FushiButtonMetrics.of(widget.size);
    final (double inner, double innerActive) = _splitInnerRadii(widget.size);
    final bool hasMenu = widget.menuChildren.isNotEmpty;
    final bool eink = isEinkTheme(context);
    final ButtonStyle leadBase = _style(
      context,
      padding: EdgeInsetsDirectional.only(
        start: m.horizontalPadding,
        end: math.max(12, m.horizontalPadding * 0.75),
      ).resolve(Directionality.of(context)),
    );
    final double trailPad = math.max(12, m.height * 0.3);
    final ButtonStyle trailBase = _style(
      context,
      padding: EdgeInsets.symmetric(horizontal: trailPad),
    );

    OutlinedBorder innerShape({
      required bool leading,
      required double active,
      double open = 0,
    }) {
      // 内侧角：静止 inner，激活（按下 / 悬停 / 焦点）放大到 innerActive，
      // 菜单打开时尾按钮内侧到全圆（pill 插值，见 FushiMorphBorder）。
      final double r = lerpDouble(inner, innerActive, active.clamp(0.0, 1.0))!;
      return FushiMorphBorder(
        radius: r,
        startPill: leading ? 1 : open.clamp(0.0, 1.0),
        endPill: leading ? 0 : 1,
        side: BorderSide.none,
      );
    }

    final Widget lead = AnimatedBuilder(
      animation: _leadPress.animation,
      builder: (BuildContext context, Widget? _) {
        final ButtonStyle style = leadBase.copyWith(
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            innerShape(leading: true, active: _leadPress.value),
          ),
        );
        return widget.icon == null
            ? FilledButton(
                onPressed: widget.onPressed,
                style: eink ? null : style,
                statesController: _leadStates,
                focusNode: widget.focusNode,
                autofocus: widget.autofocus,
                child: widget.label,
              )
            : FilledButton.icon(
                onPressed: widget.onPressed,
                style: eink ? null : style,
                statesController: _leadStates,
                focusNode: widget.focusNode,
                autofocus: widget.autofocus,
                icon: widget.icon,
                label: widget.label,
              );
      },
    );

    final Widget trail = MenuAnchor(
      controller: _menu,
      onOpen: () => _setOpen(true),
      onClose: () => _setOpen(false),
      menuChildren: widget.menuChildren,
      builder: (BuildContext context, MenuController c, Widget? _) {
        Widget button = AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[
            _trailPress.animation,
            _open.animation,
          ]),
          builder: (BuildContext context, Widget? _) {
            final ButtonStyle style = trailBase.copyWith(
              shape: WidgetStatePropertyAll<OutlinedBorder>(
                innerShape(
                  leading: false,
                  active: _trailPress.value,
                  open: _open.value,
                ),
              ),
            );
            return FilledButton(
              onPressed: hasMenu ? _toggleMenu : null,
              style: eink ? null : style,
              statesController: _trailStates,
              child: _chevron(context, m.iconSize),
            );
          },
        );
        button = Semantics(
          expanded: _menuOpen,
          label: widget.menuTooltip,
          child: button,
        );
        final String? tip = widget.menuTooltip;
        if (tip != null && tip.isNotEmpty) {
          button = FushiTooltip(message: tip, child: button);
        }
        return button;
      },
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: <Widget>[lead, trail],
    );
  }
}

// ---------------------------------------------------------------------------
// FAB 三尺寸 + FAB menu
// ---------------------------------------------------------------------------

/// M3 Expressive FAB 尺寸：FAB 56（圆角 16）/ Medium 80（20）/ Large 96（28）。
/// （Small FAB 已在 Expressive 中废弃。）
enum FushiFabSize { regular, medium, large }

/// M3 Expressive FAB 配色：三种 container 色 + 三种饱和 accent 色。
enum FushiFabColor {
  primaryContainer,
  secondaryContainer,
  tertiaryContainer,
  primary,
  secondary,
  tertiary,
}

/// FAB 几何：(边长, 圆角, 图标尺寸, 按下圆角)。
({double extent, double radius, double iconSize, double pressedRadius})
fushiFabMetrics(FushiFabSize size) => switch (size) {
  FushiFabSize.regular => (
    extent: 56,
    radius: 16,
    iconSize: 24,
    pressedRadius: 12,
  ),
  FushiFabSize.medium => (
    extent: 80,
    radius: 20,
    iconSize: 28,
    pressedRadius: 16,
  ),
  FushiFabSize.large => (
    extent: 96,
    radius: 28,
    iconSize: 36,
    pressedRadius: 20,
  ),
};

/// FAB 配色（container, onContainer）。
(Color, Color) fushiFabColors(ColorScheme cs, FushiFabColor color) =>
    switch (color) {
      FushiFabColor.primaryContainer => (
        cs.primaryContainer,
        cs.onPrimaryContainer,
      ),
      FushiFabColor.secondaryContainer => (
        cs.secondaryContainer,
        cs.onSecondaryContainer,
      ),
      FushiFabColor.tertiaryContainer => (
        cs.tertiaryContainer,
        cs.onTertiaryContainer,
      ),
      FushiFabColor.primary => (cs.primary, cs.onPrimary),
      FushiFabColor.secondary => (cs.secondary, cs.onSecondary),
      FushiFabColor.tertiary => (cs.tertiary, cs.onTertiary),
    };

/// M3 Expressive 悬浮按钮：三尺寸、六配色、可带文字（扩展 FAB）。
///
/// 本体仍是 [FloatingActionButton]（语义 / 焦点 / heroTag / Scaffold 定位全
/// 照旧），外包 [FushiGlassFab]（玻璃材质下补底）；MD3 下按压时圆角朝
/// pressedRadius 收缩（fast spatial 弹簧）。Apple 设计系统下走主题的中性玻璃
/// 胶囊 + 强调色图标（尺寸仍按档）。
class FushiFab extends StatefulWidget {
  const FushiFab({
    super.key,
    required this.icon,
    required this.onPressed,
    this.label,
    this.size = FushiFabSize.regular,
    this.color = FushiFabColor.primaryContainer,
    this.tooltip,
    this.heroTag = const _FushiFabDefaultHeroTag(),
    this.focusNode,
    this.autofocus = false,
  });

  final Widget icon;
  final VoidCallback? onPressed;

  /// 非 null = 扩展 FAB（图标 + 文字）。
  final Widget? label;
  final FushiFabSize size;
  final FushiFabColor color;
  final String? tooltip;
  final Object? heroTag;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<FushiFab> createState() => _FushiFabState();
}

class _FushiFabDefaultHeroTag {
  const _FushiFabDefaultHeroTag();
  @override
  String toString() => '<FushiFab default hero tag>';
}

class _FushiFabState extends State<FushiFab> with TickerProviderStateMixin {
  late final FushiSpring _press = FushiSpring(vsync: this);

  @override
  void initState() {
    super.initState();
    _press;
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (!mounted) return;
    _press.animateTo(
      pressed && widget.onPressed != null ? 1 : 0,
      animate: fushiExpressiveMotionEnabled(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool apple = isGlassDesign(context);
    final bool eink = isEinkTheme(context);
    final ({
      double extent,
      double radius,
      double iconSize,
      double pressedRadius,
    })
    m = fushiFabMetrics(widget.size);
    final FloatingActionButtonThemeData base = theme.floatingActionButtonTheme;
    final bool themedTransparent = base.backgroundColor == Colors.transparent;
    final (Color bg, Color fg) = apple || eink
        ? (
            base.backgroundColor ?? cs.primaryContainer,
            base.foregroundColor ?? cs.onPrimaryContainer,
          )
        : fushiFabColors(cs, widget.color);
    final BoxConstraints box = BoxConstraints.tightFor(
      width: m.extent,
      height: m.extent,
    );
    final FloatingActionButtonThemeData sized = base.copyWith(
      sizeConstraints: box,
      largeSizeConstraints: box,
      smallSizeConstraints: box,
      extendedSizeConstraints: BoxConstraints(
        minHeight: m.extent,
        maxHeight: m.extent,
        minWidth: m.extent + 24,
      ),
      iconSize: m.iconSize,
      extendedIconLabelSpacing: widget.size == FushiFabSize.regular ? 12 : 16,
      extendedPadding: EdgeInsets.symmetric(
        horizontal: widget.size == FushiFabSize.regular ? 16 : 26,
      ),
      extendedTextStyle: switch (widget.size) {
        FushiFabSize.regular => theme.textTheme.titleMedium,
        FushiFabSize.medium => theme.textTheme.titleLarge,
        FushiFabSize.large => theme.textTheme.headlineSmall,
      }?.copyWith(fontWeight: FontWeight.w600),
      backgroundColor: themedTransparent ? Colors.transparent : bg,
      foregroundColor: fg,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
    );

    Widget fab = AnimatedBuilder(
      animation: _press.animation,
      builder: (BuildContext context, Widget? _) {
        final double radius = apple
            ? m.extent / 2
            : lerpDouble(m.radius, m.pressedRadius, _press.value)!;
        final ShapeBorder shape = RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
        );
        final Widget? label = widget.label;
        return label == null
            ? FloatingActionButton(
                onPressed: widget.onPressed,
                tooltip: widget.tooltip,
                heroTag: widget.heroTag,
                focusNode: widget.focusNode,
                autofocus: widget.autofocus,
                shape: shape,
                child: widget.icon,
              )
            : FloatingActionButton.extended(
                onPressed: widget.onPressed,
                tooltip: widget.tooltip,
                heroTag: widget.heroTag,
                focusNode: widget.focusNode,
                autofocus: widget.autofocus,
                shape: shape,
                icon: widget.icon,
                label: label,
              );
      },
    );
    fab = FloatingActionButtonTheme(data: sized, child: fab);
    if (!apple) {
      fab = Listener(
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: fab,
      );
    }
    if (themedTransparent) {
      fab = _FushiGlassFabBase(
        color: apple ? null : bg,
        radius: apple ? m.extent / 2 : m.radius,
        child: fab,
      );
    }
    return fab;
  }
}

/// 玻璃材质下给 FAB 补底（与 [FushiGlassFab] 同一判据，但按 FAB 尺寸给圆角
/// 与配色）。
class _FushiGlassFabBase extends StatelessWidget {
  const _FushiGlassFabBase({
    required this.color,
    required this.radius,
    required this.child,
  });

  final Color? color;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (color == null) return FushiGlassFab(child: child);
    return FushiGlassSurface(
      baseColor: color,
      borderRadius: BorderRadius.circular(radius),
      child: child,
    );
  }
}

/// [FushiFabMenu] 的一项。
@immutable
class FushiFabMenuItem {
  const FushiFabMenuItem({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
}

/// M3 Expressive FAB menu：FAB 点开后变形为 56 圆形关闭钮（图标旋转交叉淡入），
/// 上方从下往上错峰弹出 2–6 个胶囊菜单项（56 高、全圆角、24 左右留白、项间
/// 4、与关闭钮间 8，`FabMenuBaselineTokens`）。
///
/// - 展开 / 收起走 default spatial 弹簧，菜单项按序错峰（缩放 + 位移 + 淡入）；
///   墨水屏 / 减少动画下瞬变；
/// - 键盘 / 手柄：Enter 开合，展开时焦点落到最近的菜单项，Esc / 手柄 B 收起并
///   把焦点还给 FAB；点菜单项先收起再执行；
/// - Apple 设计系统：同一结构，菜单项是玻璃胶囊按钮，不做形变。
///
/// 放在 `Scaffold.floatingActionButton` 即可：整体向上生长，底边锚定。
class FushiFabMenu extends StatefulWidget {
  const FushiFabMenu({
    super.key,
    required this.icon,
    required this.items,
    this.closeIcon = const Icon(FushiIcons.close),
    this.color = FushiFabColor.primaryContainer,
    this.size = FushiFabSize.regular,
    this.tooltip,
    this.closeTooltip,
    this.onOpenChanged,
  });

  final Widget icon;
  final Widget closeIcon;
  final List<FushiFabMenuItem> items;
  final FushiFabColor color;
  final FushiFabSize size;
  final String? tooltip;
  final String? closeTooltip;
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<FushiFabMenu> createState() => FushiFabMenuState();
}

/// [FushiFabMenu] 的状态（公开以便外部 `GlobalKey` 调 [open] / [close]）。
class FushiFabMenuState extends State<FushiFabMenu>
    with TickerProviderStateMixin {
  late final FushiSpring _openSpring = FushiSpring(
    vsync: this,
    spring: fushiExpressiveDefaultSpatial,
  );
  final FocusNode _fabFocus = FocusNode(debugLabel: 'FushiFabMenu.fab');
  final List<FocusNode> _itemFocus = <FocusNode>[];
  bool _open = false;

  bool get isOpen => _open;

  @override
  void initState() {
    super.initState();
    _openSpring;
  }

  @override
  void dispose() {
    _openSpring.dispose();
    _fabFocus.dispose();
    for (final FocusNode n in _itemFocus) {
      n.dispose();
    }
    super.dispose();
  }

  void _syncFocusNodes() {
    while (_itemFocus.length < widget.items.length) {
      _itemFocus.add(FocusNode(debugLabel: 'FushiFabMenu.item'));
    }
    while (_itemFocus.length > widget.items.length) {
      _itemFocus.removeLast().dispose();
    }
  }

  void open() => _setOpen(true);

  void close() => _setOpen(false);

  void _setOpen(bool value) {
    if (_open == value) return;
    setState(() => _open = value);
    _openSpring.animateTo(
      value ? 1 : 0,
      animate: fushiExpressiveMotionEnabled(context),
    );
    widget.onOpenChanged?.call(value);
    if (value) {
      // 焦点进最近（最下方）的菜单项：键盘 / 手柄打开后可以直接上下遍历。
      if (_fabFocus.hasFocus && _itemFocus.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _open) _itemFocus.last.requestFocus();
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      }
    } else if (_itemFocus.any((FocusNode n) => n.hasFocus)) {
      _fabFocus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncFocusNodes();
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool apple = isGlassDesign(context);
    final int n = widget.items.length;
    final (Color container, Color onContainer) = fushiFabColors(
      cs,
      widget.color,
    );

    Widget item(int i) {
      final FushiFabMenuItem it = widget.items[i];
      void activate() {
        _setOpen(false);
        it.onPressed?.call();
      }

      final Widget button = apple
          ? FushiFilledButton.tonalIcon(
              onPressed: it.onPressed == null ? null : activate,
              focusNode: _itemFocus[i],
              icon: it.icon,
              label: Text(it.label),
            )
          : FilledButton.icon(
              onPressed: it.onPressed == null ? null : activate,
              focusNode: _itemFocus[i],
              style: FilledButton.styleFrom(
                backgroundColor: container,
                foregroundColor: onContainer,
                iconColor: onContainer,
                minimumSize: const Size(56, 56),
                maximumSize: const Size(double.infinity, 56),
                padding: const EdgeInsets.symmetric(horizontal: 24),
                iconSize: 24,
                textStyle: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                shape: const StadiumBorder(),
                elevation: 3,
                shadowColor: cs.shadow,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: it.icon,
              label: Text(it.label),
            );
      // 错峰：离 FAB 最近（最下方）的先出；收起时反序。
      final int order = n - 1 - i;
      return AnimatedBuilder(
        animation: _openSpring.animation,
        builder: (BuildContext context, Widget? child) {
          final double raw = _openSpring.value;
          final double start = order * 0.12;
          final double t = ((raw - start) / (1 - start).clamp(0.2, 1.0)).clamp(
            0.0,
            1.2,
          );
          final double visible = t.clamp(0.0, 1.0);
          // 收起时完全摘掉；展开途中（含弹簧首帧 visible 仍为 0）必须留在树里：
          // 键盘 / 手柄展开后焦点在后帧回调里移进最近的菜单项，菜单项此刻不在
          // 树里，requestFocus 落在未挂载的节点上，焦点就留在 FAB（BUG-3059）。
          if (visible <= 0.001 && !_open) return const SizedBox.shrink();
          return Opacity(
            opacity: visible,
            child: Transform.translate(
              offset: Offset(0, (1 - visible) * 16),
              child: Transform.scale(
                scale: 0.8 + 0.2 * t,
                alignment: AlignmentDirectional.centerEnd.resolve(
                  Directionality.of(context),
                ),
                child: child,
              ),
            ),
          );
        },
        child: ExcludeFocus(excluding: !_open, child: button),
      );
    }

    final ({
      double extent,
      double radius,
      double iconSize,
      double pressedRadius,
    })
    m = fushiFabMetrics(widget.size);
    final Widget toggle = AnimatedBuilder(
      animation: _openSpring.animation,
      builder: (BuildContext context, Widget? _) {
        final double t = _openSpring.value.clamp(0.0, 1.0);
        // 展开：FAB（方圆角、container 色）→ 56 正圆关闭钮（primary 色）。
        final double extent = lerpDouble(m.extent, 56, t)!;
        final double radius = lerpDouble(m.radius, 28, t)!;
        final Color bg = apple
            ? (Color.lerp(container, cs.primary, t) ?? cs.primary)
            : Color.lerp(container, cs.primary, t)!;
        final Color fg = Color.lerp(onContainer, cs.onPrimary, t)!;
        return Semantics(
          button: true,
          expanded: _open,
          child: SizedBox(
            width: extent,
            height: extent,
            child: FloatingActionButton(
              heroTag: null,
              focusNode: _fabFocus,
              tooltip: _open ? widget.closeTooltip : widget.tooltip,
              onPressed: () => _setOpen(!_open),
              backgroundColor: bg,
              foregroundColor: fg,
              elevation: _open ? 3 : 0,
              highlightElevation: _open ? 3 : 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radius),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  if (t < 1)
                    Opacity(
                      opacity: 1 - t,
                      child: Transform.rotate(
                        angle: t * math.pi / 2,
                        child: IconTheme.merge(
                          data: IconThemeData(size: m.iconSize),
                          child: widget.icon,
                        ),
                      ),
                    ),
                  if (t > 0)
                    Opacity(
                      opacity: t,
                      child: Transform.rotate(
                        angle: (t - 1) * math.pi / 2,
                        child: IconTheme.merge(
                          data: const IconThemeData(size: 20),
                          child: widget.closeIcon,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        if (_open) const SingleActivator(LogicalKeyboardKey.escape): close,
        if (_open) const SingleActivator(LogicalKeyboardKey.gameButtonB): close,
      },
      child: FocusTraversalGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            for (int i = 0; i < n; i++) ...<Widget>[
              item(i),
              SizedBox(height: i == n - 1 ? 8 : 4),
            ],
            SizedBox(
              width: m.extent,
              height: m.extent,
              child: Align(alignment: Alignment.bottomRight, child: toggle),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 开关 thumb 图标 / chip 强调色
// ---------------------------------------------------------------------------

/// M3 Expressive 开关的 thumb 图标：开 = 对勾（primary 色，压在 onPrimary
/// 圆钮上）、关 = 叉（surfaceContainerHighest 色，压在 outline 圆钮上）。
/// 关态有图标时 M3 把圆钮从 16 撑到 24，开关读起来更「实」。
WidgetStateProperty<Icon?> fushiExpressiveSwitchThumbIcon(ColorScheme cs) {
  return WidgetStateProperty.resolveWith<Icon?>((Set<WidgetState> states) {
    final bool disabled = states.contains(WidgetState.disabled);
    if (states.contains(WidgetState.selected)) {
      return Icon(
        FushiIcons.check,
        size: 16,
        color: disabled ? cs.onSurface.withValues(alpha: 0.38) : cs.primary,
      );
    }
    return Icon(
      FushiIcons.close,
      size: 16,
      color: disabled
          ? cs.surfaceContainerHighest.withValues(alpha: 0.38)
          : cs.surfaceContainerHighest,
    );
  });
}

/// 强调色 chip 的三色（选中底, 选中前景, 未选底）：标签 / 合集等彩色 chip 用。
///
/// M3 Expressive 的饱和色块：选中直接铺 [accent]、前景按亮度取黑 / 白；未选
/// 是 [accent] 14% 叠在 surfaceContainerHigh 上的淡色块（仍看得出是哪种颜色）。
({Color selected, Color onSelected, Color unselected}) fushiAccentChipColors(
  Color accent,
  ColorScheme cs,
) {
  final Color onSelected =
      ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
      ? Colors.white
      : Colors.black;
  return (
    selected: accent,
    onSelected: onSelected,
    unselected: Color.alphaBlend(
      accent.withValues(alpha: 0.14),
      cs.surfaceContainerHigh,
    ),
  );
}

// ---------------------------------------------------------------------------
// 滑块尺寸档
// ---------------------------------------------------------------------------

/// M3 Expressive 滑块尺寸档：XS 16 / S 24 / M 40 / L 56 / XL 96（轨道粗细）。
enum FushiSliderSize { xs, s, m, l, xl }

/// 滑块尺寸档几何：(轨道粗细, 竖条把手高度)。把手宽恒 4（按下 2，Flutter
/// 2024 版滑块自带）。
({double track, double handle}) fushiSliderMetrics(FushiSliderSize size) =>
    switch (size) {
      FushiSliderSize.xs => (track: 16, handle: 44),
      FushiSliderSize.s => (track: 24, handle: 44),
      FushiSliderSize.m => (track: 40, handle: 52),
      FushiSliderSize.l => (track: 56, handle: 68),
      FushiSliderSize.xl => (track: 96, handle: 108),
    };

/// 在 [base]（通常是 `SliderTheme.of(context)`）上叠一个尺寸档：轨道粗细与
/// 竖条把手高度（按下时把手变细由 Flutter 2024 版滑块处理）。
SliderThemeData fushiSliderSizeTheme(
  SliderThemeData base,
  FushiSliderSize size,
) {
  final ({double track, double handle}) m = fushiSliderMetrics(size);
  return base.copyWith(
    trackHeight: m.track,
    thumbSize: WidgetStateProperty.resolveWith<Size?>(
      (Set<WidgetState> states) => Size(
        states.contains(WidgetState.pressed) ||
                states.contains(WidgetState.dragged)
            ? 2
            : 4,
        m.handle,
      ),
    ),
  );
}

/// MD3 强调色 chip 的局部 [ChipThemeData]：在当前主题上换选中底 / 未选底 /
/// 文字 / 对勾色（形状、字阶、内边距照旧）。
ChipThemeData fushiAccentChipTheme(BuildContext context, Color accent) {
  final ThemeData theme = Theme.of(context);
  final ColorScheme cs = theme.colorScheme;
  final ChipThemeData base = ChipTheme.of(context);
  final ({Color selected, Color onSelected, Color unselected}) c =
      fushiAccentChipColors(accent, cs);
  final TextStyle label =
      base.labelStyle ?? theme.textTheme.labelLarge ?? const TextStyle();
  return base.copyWith(
    selectedColor: c.selected,
    backgroundColor: c.unselected,
    checkmarkColor: c.onSelected,
    labelStyle: label.copyWith(
      color: WidgetStateColor.resolveWith(
        (Set<WidgetState> states) =>
            states.contains(WidgetState.selected) ? c.onSelected : cs.onSurface,
      ),
    ),
  );
}
