import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 选择类控件（开关 / 滑块 / 复选 / 单选 / 列表行变体 / 分段按钮）的「设计系统
// 分派」包装：构造参数与 Material 原控件逐个同名同型（含同名命名构造器），调用
// 点只改类名。MD3 设计系统下原样构造原控件并转发全部参数（像素、焦点、语义
// 一字不差）；「玻璃」设计系统下渲染 liquid_glass_widgets 组件：
//
// - Switch → [GlassSwitch]；Slider → [GlassSlider]（库不处理方向键，这里补上，
//   键位与 Material Slider 同：←/→ 恒调值，传统导航模式下 ↑/↓ 也调值）；
// - Checkbox / Radio → [GlassButton.custom] 小圆角 / 圆形 + 勾 / 点自绘（库里
//   没有对应组件），支持 tristate 与 RadioGroup；
// - RangeSlider → 自绘轨道 + 两个 [GlassContainer] 玻璃拇指（库里没有）；
// - *ListTile → [GlassListTile] 排版 + 整行一个焦点停靠点（与 Material 同：行内
//   控件 ExcludeFocus，Enter / 手柄 A 经 ActivateIntent 切换）；
// - SegmentedButton → 单选且能用 [GlassSegmentedControl] 表达时用它，否则（多选、
//   允许空选、竖排、段数越界、label 不是纯文本）退回一排玻璃按钮。
//
// 主色一律取 `Theme.of(context).colorScheme`（库默认是 iOS 蓝）。

const Set<WidgetState> _kNoStates = <WidgetState>{};
const Set<WidgetState> _kSelectedStates = <WidgetState>{WidgetState.selected};

/// 禁用态玻璃控件：不可聚焦、不吃指针、按 Material 禁用不透明度变淡。
Widget _glassDisabled(Widget child) {
  return ExcludeFocus(
    child: IgnorePointer(child: Opacity(opacity: 0.38, child: child)),
  );
}

/// 转发 `onFocusChange`：观察子树焦点变化，自身不占焦点停靠点。
Widget _glassFocusObserver(ValueChanged<bool>? onFocusChange, Widget child) {
  if (onFocusChange == null) return child;
  return Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: onFocusChange,
    child: child,
  );
}

/// Material 复选 / 单选的点击目标边长：padded 48、shrinkWrap 40，再按视觉密度
/// 修正（与 Material 布局尺寸一致，切换设计系统不跳行高）。
double _toggleTapTarget(
  BuildContext context,
  MaterialTapTargetSize? tapTargetSize,
  VisualDensity? visualDensity,
) {
  final ThemeData theme = Theme.of(context);
  final MaterialTapTargetSize size =
      tapTargetSize ?? theme.materialTapTargetSize;
  final double base = size == MaterialTapTargetSize.padded
      ? kMinInteractiveDimension
      : 40;
  final VisualDensity density = visualDensity ?? theme.visualDensity;
  return base + density.baseSizeAdjustment.dx;
}

/// 滑块方向键：返回 +1（增大）/ -1（减小）/ 0（不处理）。键位与 Material
/// Slider 一致：←/→ 恒调值（RTL 反向），传统导航模式下 ↑/↓ 也调值；方向导航
/// 模式（电视 / 手柄）把 ↑/↓ 留给移焦。
int _sliderKeyDirection(BuildContext context, KeyEvent event) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return 0;
  final bool traditional =
      (MediaQuery.maybeNavigationModeOf(context) ??
          NavigationMode.traditional) ==
      NavigationMode.traditional;
  final bool rtl = Directionality.of(context) == TextDirection.rtl;
  final LogicalKeyboardKey key = event.logicalKey;
  if (key == LogicalKeyboardKey.arrowRight) return rtl ? -1 : 1;
  if (key == LogicalKeyboardKey.arrowLeft) return rtl ? 1 : -1;
  if (traditional && key == LogicalKeyboardKey.arrowUp) return 1;
  if (traditional && key == LogicalKeyboardKey.arrowDown) return -1;
  return 0;
}

/// 键盘单步：有 divisions 走一格，否则按平台取量程的 10%（Apple）/ 5%。
double _sliderKeyStep(
  BuildContext context,
  double min,
  double max,
  int? divisions,
) {
  final double range = max - min;
  if (divisions != null && divisions > 0) return range / divisions;
  final double unit = switch (Theme.of(context).platform) {
    TargetPlatform.iOS || TargetPlatform.macOS => 0.1,
    _ => 0.05,
  };
  return range * unit;
}

/// 复选框 / 单选钮的玻璃指示器。[onTap] 为 null 时是列表行里的纯展示控件
/// （不可聚焦、不吃指针、不出语义——由整行承担）。
Widget _glassCheckIndicator(
  BuildContext context, {
  required bool? value,
  required bool enabled,
  required VoidCallback? onTap,
  required bool round,
  FocusNode? focusNode,
  bool autofocus = false,
  Color? activeColor,
  WidgetStateProperty<Color?>? fillColor,
  Color? checkColor,
  bool isError = false,
  String? semanticLabel,
  double scale = 1.0,
  MaterialTapTargetSize? materialTapTargetSize,
  VisualDensity? visualDensity,
}) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  final bool selected = value != false;
  final Set<WidgetState> states = <WidgetState>{
    if (selected) WidgetState.selected,
    if (!enabled) WidgetState.disabled,
    if (isError) WidgetState.error,
  };
  final Color tint = isError
      ? cs.error
      : (fillColor?.resolve(states) ?? activeColor ?? cs.primary);
  final Color mark = checkColor ?? (isError ? cs.onError : cs.onPrimary);
  final double size = (round ? 20 : 18) * scale;
  final ShapeBorder outline = round
      ? const CircleBorder()
      : RoundedRectangleBorder(borderRadius: BorderRadius.circular(5 * scale));

  final Widget glyph;
  if (!selected) {
    glyph = DecoratedBox(
      decoration: ShapeDecoration(
        shape: outline is CircleBorder
            ? CircleBorder(
                side: BorderSide(
                  color: isError ? cs.error : cs.onSurfaceVariant,
                  width: 1.5,
                ),
              )
            : RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5 * scale),
                side: BorderSide(
                  color: isError ? cs.error : cs.onSurfaceVariant,
                  width: 1.5,
                ),
              ),
      ),
      child: SizedBox.square(dimension: size),
    );
  } else if (round) {
    glyph = Container(
      width: size * 0.4,
      height: size * 0.4,
      decoration: BoxDecoration(color: mark, shape: BoxShape.circle),
    );
  } else {
    glyph = Icon(
      value == null ? Icons.remove_rounded : Icons.check_rounded,
      size: size * 0.85,
      color: mark,
    );
  }

  final bool interactive = onTap != null;
  Widget box = GlassButton.custom(
    onTap: onTap ?? () {},
    enabled: enabled,
    style: selected ? GlassButtonStyle.prominent : GlassButtonStyle.filled,
    settings: selected ? fushiGlassSettings(context, tint: tint) : null,
    quality: fushiGlassQuality(context),
    shape: round
        ? const LiquidOval()
        : LiquidRoundedSuperellipse(borderRadius: 5 * scale),
    width: size,
    height: size,
    stretch: 0.2,
    focusNode: interactive ? focusNode : null,
    autofocus: interactive && autofocus,
    canRequestFocus: interactive,
    excludeFromSemantics: !interactive,
    label: semanticLabel ?? '',
    child: Center(child: glyph),
  );
  if (!interactive) {
    return ExcludeFocus(child: IgnorePointer(child: box));
  }
  box = Semantics(
    checked: value ?? false,
    mixed: value == null ? true : null,
    inMutuallyExclusiveGroup: round ? true : null,
    child: box,
  );
  final double target = _toggleTapTarget(
    context,
    materialTapTargetSize,
    visualDensity,
  );
  return SizedBox.square(
    dimension: target,
    child: Center(child: box),
  );
}

// ---------------------------------------------------------------------------
// Switch
// ---------------------------------------------------------------------------

/// [Switch] 的设计系统分派版（含 `.adaptive`）。
class FushiSwitch extends StatelessWidget {
  const FushiSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.activeThumbColor,
    this.activeTrackColor,
    this.inactiveThumbColor,
    this.inactiveTrackColor,
    this.activeThumbImage,
    this.onActiveThumbImageError,
    this.inactiveThumbImage,
    this.onInactiveThumbImageError,
    this.thumbColor,
    this.trackColor,
    this.trackOutlineColor,
    this.trackOutlineWidth,
    this.thumbIcon,
    this.materialTapTargetSize,
    this.dragStartBehavior = DragStartBehavior.start,
    this.mouseCursor,
    this.focusColor,
    this.hoverColor,
    this.overlayColor,
    this.splashRadius,
    this.focusNode,
    this.onFocusChange,
    this.autofocus = false,
    this.padding,
  }) : applyCupertinoTheme = null,
       _adaptive = false;

  const FushiSwitch.adaptive({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.activeThumbColor,
    this.activeTrackColor,
    this.inactiveThumbColor,
    this.inactiveTrackColor,
    this.activeThumbImage,
    this.onActiveThumbImageError,
    this.inactiveThumbImage,
    this.onInactiveThumbImageError,
    this.materialTapTargetSize,
    this.thumbColor,
    this.trackColor,
    this.trackOutlineColor,
    this.trackOutlineWidth,
    this.thumbIcon,
    this.dragStartBehavior = DragStartBehavior.start,
    this.mouseCursor,
    this.focusColor,
    this.hoverColor,
    this.overlayColor,
    this.splashRadius,
    this.focusNode,
    this.onFocusChange,
    this.autofocus = false,
    this.padding,
    this.applyCupertinoTheme,
  }) : _adaptive = true;

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;
  final Color? activeThumbColor;
  final Color? activeTrackColor;
  final Color? inactiveThumbColor;
  final Color? inactiveTrackColor;
  final ImageProvider? activeThumbImage;
  final ImageErrorListener? onActiveThumbImageError;
  final ImageProvider? inactiveThumbImage;
  final ImageErrorListener? onInactiveThumbImageError;
  final WidgetStateProperty<Color?>? thumbColor;
  final WidgetStateProperty<Color?>? trackColor;
  final WidgetStateProperty<Color?>? trackOutlineColor;
  final WidgetStateProperty<double?>? trackOutlineWidth;
  final WidgetStateProperty<Icon?>? thumbIcon;
  final MaterialTapTargetSize? materialTapTargetSize;
  final DragStartBehavior dragStartBehavior;
  final MouseCursor? mouseCursor;
  final Color? focusColor;
  final Color? hoverColor;
  final WidgetStateProperty<Color?>? overlayColor;
  final double? splashRadius;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final EdgeInsetsGeometry? padding;
  final bool? applyCupertinoTheme;
  final bool _adaptive;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildGlass(context);
    if (_adaptive) {
      return Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeColor: activeColor,
        activeThumbColor: activeThumbColor,
        activeTrackColor: activeTrackColor,
        inactiveThumbColor: inactiveThumbColor,
        inactiveTrackColor: inactiveTrackColor,
        activeThumbImage: activeThumbImage,
        onActiveThumbImageError: onActiveThumbImageError,
        inactiveThumbImage: inactiveThumbImage,
        onInactiveThumbImageError: onInactiveThumbImageError,
        materialTapTargetSize: materialTapTargetSize,
        thumbColor: thumbColor,
        trackColor: trackColor,
        trackOutlineColor: trackOutlineColor,
        trackOutlineWidth: trackOutlineWidth,
        thumbIcon: thumbIcon,
        dragStartBehavior: dragStartBehavior,
        mouseCursor: mouseCursor,
        focusColor: focusColor,
        hoverColor: hoverColor,
        overlayColor: overlayColor,
        splashRadius: splashRadius,
        focusNode: focusNode,
        onFocusChange: onFocusChange,
        autofocus: autofocus,
        padding: padding,
        applyCupertinoTheme: applyCupertinoTheme,
      );
    }
    return Switch(
      value: value,
      onChanged: onChanged,
      activeColor: activeColor,
      activeThumbColor: activeThumbColor,
      activeTrackColor: activeTrackColor,
      inactiveThumbColor: inactiveThumbColor,
      inactiveTrackColor: inactiveTrackColor,
      activeThumbImage: activeThumbImage,
      onActiveThumbImageError: onActiveThumbImageError,
      inactiveThumbImage: inactiveThumbImage,
      onInactiveThumbImageError: onInactiveThumbImageError,
      thumbColor: thumbColor,
      trackColor: trackColor,
      trackOutlineColor: trackOutlineColor,
      trackOutlineWidth: trackOutlineWidth,
      thumbIcon: thumbIcon,
      materialTapTargetSize: materialTapTargetSize,
      dragStartBehavior: dragStartBehavior,
      mouseCursor: mouseCursor,
      focusColor: focusColor,
      hoverColor: hoverColor,
      overlayColor: overlayColor,
      splashRadius: splashRadius,
      focusNode: focusNode,
      onFocusChange: onFocusChange,
      autofocus: autofocus,
      padding: padding,
    );
  }

  Widget _buildGlass(BuildContext context) {
    final bool enabled = onChanged != null;
    final double vertical =
        (materialTapTargetSize ?? Theme.of(context).materialTapTargetSize) ==
            MaterialTapTargetSize.shrinkWrap
        ? 4
        : 11;
    Widget control = _glassSwitchVisual(
      context,
      value: value,
      onChanged: onChanged,
      focusNode: focusNode,
      autofocus: autofocus,
      activeThumbColor: activeThumbColor,
      activeTrackColor: activeTrackColor,
      inactiveThumbColor: inactiveThumbColor,
      inactiveTrackColor: inactiveTrackColor,
      thumbColor: thumbColor,
      trackColor: trackColor,
    );
    control = Padding(
      padding:
          padding ?? EdgeInsets.symmetric(horizontal: 2, vertical: vertical),
      child: control,
    );
    // 紧约束（如被父级撑宽）下居中，而不是让 GlassSwitch 的手势区与画面错位。
    control = Center(widthFactor: 1, heightFactor: 1, child: control);
    if (!enabled) return _glassDisabled(control);
    return _glassFocusObserver(onFocusChange, control);
  }
}

/// [GlassSwitch] 配色：轨道取 primary / surfaceContainerHighest（可被 Material
/// 颜色参数覆盖），拇指默认白。[onChanged] 为 null 时给空回调（调用方负责禁用态）。
Widget _glassSwitchVisual(
  BuildContext context, {
  required bool value,
  required ValueChanged<bool>? onChanged,
  FocusNode? focusNode,
  bool autofocus = false,
  Color? activeThumbColor,
  Color? activeTrackColor,
  Color? inactiveThumbColor,
  Color? inactiveTrackColor,
  WidgetStateProperty<Color?>? thumbColor,
  WidgetStateProperty<Color?>? trackColor,
}) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  final Color active =
      activeTrackColor ?? trackColor?.resolve(_kSelectedStates) ?? cs.primary;
  final Color inactive =
      inactiveTrackColor ??
      trackColor?.resolve(_kNoStates) ??
      cs.surfaceContainerHighest;
  final Color thumb =
      thumbColor?.resolve(value ? _kSelectedStates : _kNoStates) ??
      (value ? activeThumbColor : inactiveThumbColor) ??
      Colors.white;
  return GlassSwitch(
    value: value,
    onChanged: onChanged ?? (bool _) {},
    activeColor: active,
    inactiveColor: inactive,
    thumbColor: thumb,
    quality: fushiGlassQuality(context),
    focusNode: focusNode,
    autofocus: autofocus,
  );
}

// ---------------------------------------------------------------------------
// Slider
// ---------------------------------------------------------------------------

/// [Slider] 的设计系统分派版（含 `.adaptive`）。
class FushiSlider extends StatelessWidget {
  const FushiSlider({
    super.key,
    required this.value,
    this.secondaryTrackValue,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.label,
    this.activeColor,
    this.inactiveColor,
    this.secondaryActiveColor,
    this.thumbColor,
    this.overlayColor,
    this.mouseCursor,
    this.semanticFormatterCallback,
    this.focusNode,
    this.autofocus = false,
    this.allowedInteraction,
    this.padding,
    this.showValueIndicator,
    this.year2023,
  }) : _adaptive = false;

  const FushiSlider.adaptive({
    super.key,
    required this.value,
    this.secondaryTrackValue,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.label,
    this.mouseCursor,
    this.activeColor,
    this.inactiveColor,
    this.secondaryActiveColor,
    this.thumbColor,
    this.overlayColor,
    this.semanticFormatterCallback,
    this.focusNode,
    this.autofocus = false,
    this.allowedInteraction,
    this.showValueIndicator,
    this.year2023,
  }) : padding = null,
       _adaptive = true;

  final double value;
  final double? secondaryTrackValue;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final Color? activeColor;
  final Color? inactiveColor;
  final Color? secondaryActiveColor;
  final Color? thumbColor;
  final WidgetStateProperty<Color?>? overlayColor;
  final MouseCursor? mouseCursor;
  final SemanticFormatterCallback? semanticFormatterCallback;
  final FocusNode? focusNode;
  final bool autofocus;
  final SliderInteraction? allowedInteraction;
  final EdgeInsetsGeometry? padding;
  final ShowValueIndicator? showValueIndicator;
  final bool? year2023;
  final bool _adaptive;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildGlass(context);
    if (_adaptive) {
      return Slider.adaptive(
        value: value,
        secondaryTrackValue: secondaryTrackValue,
        onChanged: onChanged,
        onChangeStart: onChangeStart,
        onChangeEnd: onChangeEnd,
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        mouseCursor: mouseCursor,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        secondaryActiveColor: secondaryActiveColor,
        thumbColor: thumbColor,
        overlayColor: overlayColor,
        semanticFormatterCallback: semanticFormatterCallback,
        focusNode: focusNode,
        autofocus: autofocus,
        allowedInteraction: allowedInteraction,
        showValueIndicator: showValueIndicator,
        year2023: year2023,
      );
    }
    return Slider(
      value: value,
      secondaryTrackValue: secondaryTrackValue,
      onChanged: onChanged,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      activeColor: activeColor,
      inactiveColor: inactiveColor,
      secondaryActiveColor: secondaryActiveColor,
      thumbColor: thumbColor,
      overlayColor: overlayColor,
      mouseCursor: mouseCursor,
      semanticFormatterCallback: semanticFormatterCallback,
      focusNode: focusNode,
      autofocus: autofocus,
      allowedInteraction: allowedInteraction,
      padding: padding,
      showValueIndicator: showValueIndicator,
      year2023: year2023,
    );
  }

  Widget _buildGlass(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ValueChanged<double>? changed = onChanged;
    final bool enabled = changed != null;
    Widget slider = GlassSlider(
      value: value.clamp(min, max).toDouble(),
      onChanged: changed,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      activeColor: activeColor ?? cs.primary,
      inactiveColor: inactiveColor ?? cs.surfaceContainerHighest,
      thumbColor: thumbColor ?? Colors.white,
      glowColor: cs.primary,
      quality: fushiGlassQuality(context),
      focusNode: focusNode,
      autofocus: autofocus,
    );
    if (enabled) {
      final Widget glassSlider = slider;
      // GlassSlider 只认拖动；Material Slider 点轨道即跳值，这里补上点击。
      // 几何与 GlassSlider 一致：轨道两端各留一个拇指半径（默认 15）。
      slider = LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          const double thumbRadius = 15;
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: (TapUpDetails details) {
              final double track = constraints.maxWidth - thumbRadius * 2;
              if (!track.isFinite || track <= 0) return;
              double t = ((details.localPosition.dx - thumbRadius) / track)
                  .clamp(0.0, 1.0)
                  .toDouble();
              if (Directionality.of(context) == TextDirection.rtl) t = 1 - t;
              double next = min + t * (max - min);
              final int? div = divisions;
              if (div != null && div > 0) {
                final double stepSize = (max - min) / div;
                next = (((next - min) / stepSize).round() * stepSize + min)
                    .clamp(min, max)
                    .toDouble();
              }
              onChangeStart?.call(value);
              changed(next);
              onChangeEnd?.call(next);
            },
            child: glassSlider,
          );
        },
      );
    }
    if (padding != null) slider = Padding(padding: padding!, child: slider);
    if (!enabled) return Opacity(opacity: 0.38, child: slider);
    // GlassSlider 只注册了语义增减，不处理方向键：在祖先上补 Material 同款键位。
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (FocusNode node, KeyEvent event) {
        final int dir = _sliderKeyDirection(context, event);
        if (dir == 0) return KeyEventResult.ignored;
        final double step = _sliderKeyStep(context, min, max, divisions);
        final double current = value.clamp(min, max).toDouble();
        final double next = (current + dir * step).clamp(min, max).toDouble();
        onChangeStart?.call(current);
        changed(next);
        onChangeEnd?.call(next);
        return KeyEventResult.handled;
      },
      child: slider,
    );
  }
}

// ---------------------------------------------------------------------------
// RangeSlider
// ---------------------------------------------------------------------------

/// [RangeSlider] 的设计系统分派版。玻璃下是自绘轨道 + 两个玻璃拇指（库里
/// 没有区间滑块）；两个拇指各是一个焦点停靠点，方向键与 [FushiSlider] 同键位。
class FushiRangeSlider extends StatelessWidget {
  // Material 的 RangeSlider 构造器本身不是 const（断言读 values 字段）。
  // ignore: prefer_const_constructors_in_immutables
  FushiRangeSlider({
    super.key,
    required this.values,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.labels,
    this.activeColor,
    this.inactiveColor,
    this.overlayColor,
    this.mouseCursor,
    this.semanticFormatterCallback,
    this.padding,
    this.year2023,
  });

  final RangeValues values;
  final ValueChanged<RangeValues>? onChanged;
  final ValueChanged<RangeValues>? onChangeStart;
  final ValueChanged<RangeValues>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final RangeLabels? labels;
  final Color? activeColor;
  final Color? inactiveColor;
  final WidgetStateProperty<Color?>? overlayColor;
  final WidgetStateProperty<MouseCursor?>? mouseCursor;
  final SemanticFormatterCallback? semanticFormatterCallback;
  final EdgeInsetsGeometry? padding;
  final bool? year2023;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      Widget slider = _GlassRangeSlider(
        values: values,
        onChanged: onChanged,
        onChangeStart: onChangeStart,
        onChangeEnd: onChangeEnd,
        min: min,
        max: max,
        divisions: divisions,
        labels: labels,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        semanticFormatterCallback: semanticFormatterCallback,
      );
      if (padding != null) slider = Padding(padding: padding!, child: slider);
      return onChanged == null ? _glassDisabled(slider) : slider;
    }
    return RangeSlider(
      values: values,
      onChanged: onChanged,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
      min: min,
      max: max,
      divisions: divisions,
      labels: labels,
      activeColor: activeColor,
      inactiveColor: inactiveColor,
      overlayColor: overlayColor,
      mouseCursor: mouseCursor,
      semanticFormatterCallback: semanticFormatterCallback,
      padding: padding,
      year2023: year2023,
    );
  }
}

class _GlassRangeSlider extends StatefulWidget {
  const _GlassRangeSlider({
    required this.values,
    required this.onChanged,
    required this.onChangeStart,
    required this.onChangeEnd,
    required this.min,
    required this.max,
    required this.divisions,
    required this.labels,
    required this.activeColor,
    required this.inactiveColor,
    required this.semanticFormatterCallback,
  });

  final RangeValues values;
  final ValueChanged<RangeValues>? onChanged;
  final ValueChanged<RangeValues>? onChangeStart;
  final ValueChanged<RangeValues>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final RangeLabels? labels;
  final Color? activeColor;
  final Color? inactiveColor;
  final SemanticFormatterCallback? semanticFormatterCallback;

  @override
  State<_GlassRangeSlider> createState() => _GlassRangeSliderState();
}

class _GlassRangeSliderState extends State<_GlassRangeSlider> {
  static const double _thumbSize = 24;
  static const double _height = 48;
  static const double _trackHeight = 4;

  final FocusNode _startNode = FocusNode(debugLabel: 'FushiRangeSlider.start');
  final FocusNode _endNode = FocusNode(debugLabel: 'FushiRangeSlider.end');
  bool _startFocused = false;
  bool _endFocused = false;
  int? _dragThumb;
  double _width = 0;
  late RangeValues _latest = widget.values;

  @override
  void didUpdateWidget(_GlassRangeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    _latest = widget.values;
  }

  @override
  void dispose() {
    _startNode.dispose();
    _endNode.dispose();
    super.dispose();
  }

  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  double get _range => widget.max - widget.min;

  double _fraction(double v) {
    if (_range <= 0) return 0;
    final double t = ((v - widget.min) / _range).clamp(0.0, 1.0).toDouble();
    return _rtl ? 1 - t : t;
  }

  double _discretize(double v) {
    final double clamped = v.clamp(widget.min, widget.max).toDouble();
    final int? divisions = widget.divisions;
    if (divisions == null || divisions <= 0 || _range <= 0) return clamped;
    final double steps = ((clamped - widget.min) / _range * divisions)
        .roundToDouble();
    return widget.min + steps / divisions * _range;
  }

  double _valueAt(double dx) {
    final double usable = _width - _thumbSize;
    if (usable <= 0) return widget.min;
    double t = ((dx - _thumbSize / 2) / usable).clamp(0.0, 1.0).toDouble();
    if (_rtl) t = 1 - t;
    return _discretize(widget.min + t * _range);
  }

  int _nearestThumb(double dx) {
    final double usable = _width - _thumbSize;
    final double startX = _thumbSize / 2 + _fraction(_latest.start) * usable;
    final double endX = _thumbSize / 2 + _fraction(_latest.end) * usable;
    final double ds = (dx - startX).abs();
    final double de = (dx - endX).abs();
    if (ds == de) {
      // 两拇指重叠：往哪边拖就动哪个。
      final bool towardsEnd = _rtl ? dx < startX : dx > startX;
      return towardsEnd ? 1 : 0;
    }
    return ds < de ? 0 : 1;
  }

  void _emit(int thumb, double v) {
    final RangeValues current = _latest;
    final RangeValues next = thumb == 0
        ? RangeValues(v > current.end ? current.end : v, current.end)
        : RangeValues(current.start, v < current.start ? current.start : v);
    if (next == current) return;
    _latest = next;
    widget.onChanged?.call(next);
  }

  void _beginInteraction(int thumb) {
    _dragThumb = thumb;
    widget.onChangeStart?.call(_latest);
  }

  void _endInteraction() {
    _dragThumb = null;
    widget.onChangeEnd?.call(_latest);
  }

  KeyEventResult _onKey(int thumb, KeyEvent event) {
    final int dir = _sliderKeyDirection(context, event);
    if (dir == 0) return KeyEventResult.ignored;
    final double step = _sliderKeyStep(
      context,
      widget.min,
      widget.max,
      widget.divisions,
    );
    final double current = thumb == 0 ? _latest.start : _latest.end;
    _beginInteraction(thumb);
    _emit(thumb, _discretize(current + dir * step));
    _endInteraction();
    return KeyEventResult.handled;
  }

  String _semanticValue(double v) {
    final SemanticFormatterCallback? format = widget.semanticFormatterCallback;
    if (format != null) return format(v);
    if (_range <= 0) return '0%';
    return '${((v - widget.min) / _range * 100).round()}%';
  }

  Widget _thumb(int thumb, double left) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool focused = thumb == 0 ? _startFocused : _endFocused;
    final double v = thumb == 0 ? _latest.start : _latest.end;
    final String? label = thumb == 0
        ? widget.labels?.start
        : widget.labels?.end;
    final double step = _sliderKeyStep(
      context,
      widget.min,
      widget.max,
      widget.divisions,
    );
    return Positioned(
      left: left,
      top: (_height - _thumbSize) / 2,
      width: _thumbSize,
      height: _thumbSize,
      child: Focus(
        focusNode: thumb == 0 ? _startNode : _endNode,
        onFocusChange: (bool f) => setState(() {
          if (thumb == 0) {
            _startFocused = f;
          } else {
            _endFocused = f;
          }
        }),
        onKeyEvent: (FocusNode node, KeyEvent event) => _onKey(thumb, event),
        child: Semantics(
          slider: true,
          label: label,
          value: _semanticValue(v),
          increasedValue: _semanticValue(_discretize(v + step)),
          decreasedValue: _semanticValue(_discretize(v - step)),
          onIncrease: () => _emit(thumb, _discretize(v + step)),
          onDecrease: () => _emit(thumb, _discretize(v - step)),
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              GlassContainer(
                width: _thumbSize,
                height: _thumbSize,
                shape: const LiquidOval(),
                quality: fushiGlassQuality(context),
                settings: fushiGlassSettings(context, tint: Colors.white),
              ),
              if (focused)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: cs.primary, width: 2),
                      ),
                    ),
                  ),
                ),
              if (label != null && (focused || _dragThumb == thumb))
                Positioned(
                  bottom: _thumbSize + 4,
                  left: -40,
                  right: -40,
                  child: Center(
                    child: Text(
                      label,
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: cs.onSurface),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: _height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          _width = constraints.maxWidth.isFinite ? constraints.maxWidth : 144;
          final double usable = _width - _thumbSize;
          final double a = _fraction(_latest.start) * usable;
          final double b = _fraction(_latest.end) * usable;
          final double lo = a < b ? a : b;
          final double hi = a < b ? b : a;
          const double trackTop = (_height - _trackHeight) / 2;
          return SizedBox(
            width: _width,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (TapDownDetails d) {
                final int thumb = _nearestThumb(d.localPosition.dx);
                _beginInteraction(thumb);
                _emit(thumb, _valueAt(d.localPosition.dx));
              },
              onTapUp: (TapUpDetails d) => _endInteraction(),
              onTapCancel: () {
                if (_dragThumb != null) _endInteraction();
              },
              onHorizontalDragStart: (DragStartDetails d) {
                if (_dragThumb == null) {
                  _beginInteraction(_nearestThumb(d.localPosition.dx));
                }
                setState(() {});
              },
              onHorizontalDragUpdate: (DragUpdateDetails d) {
                final int? thumb = _dragThumb;
                if (thumb != null) _emit(thumb, _valueAt(d.localPosition.dx));
              },
              onHorizontalDragEnd: (DragEndDetails d) {
                _endInteraction();
                setState(() {});
              },
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned(
                    left: _thumbSize / 2,
                    right: _thumbSize / 2,
                    top: trackTop,
                    height: _trackHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color:
                            widget.inactiveColor ?? cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(_trackHeight / 2),
                      ),
                    ),
                  ),
                  Positioned(
                    left: _thumbSize / 2 + lo,
                    width: hi - lo,
                    top: trackTop,
                    height: _trackHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: widget.activeColor ?? cs.primary,
                        borderRadius: BorderRadius.circular(_trackHeight / 2),
                      ),
                    ),
                  ),
                  _thumb(0, a),
                  _thumb(1, b),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Checkbox
// ---------------------------------------------------------------------------

/// [Checkbox] 的设计系统分派版（含 `.adaptive`）。
class FushiCheckbox extends StatelessWidget {
  const FushiCheckbox({
    super.key,
    required this.value,
    this.tristate = false,
    required this.onChanged,
    this.mouseCursor,
    this.activeColor,
    this.fillColor,
    this.checkColor,
    this.focusColor,
    this.hoverColor,
    this.overlayColor,
    this.splashRadius,
    this.materialTapTargetSize,
    this.visualDensity,
    this.focusNode,
    this.autofocus = false,
    this.shape,
    this.side,
    this.isError = false,
    this.semanticLabel,
  }) : _adaptive = false;

  const FushiCheckbox.adaptive({
    super.key,
    required this.value,
    this.tristate = false,
    required this.onChanged,
    this.mouseCursor,
    this.activeColor,
    this.fillColor,
    this.checkColor,
    this.focusColor,
    this.hoverColor,
    this.overlayColor,
    this.splashRadius,
    this.materialTapTargetSize,
    this.visualDensity,
    this.focusNode,
    this.autofocus = false,
    this.shape,
    this.side,
    this.isError = false,
    this.semanticLabel,
  }) : _adaptive = true;

  final bool? value;
  final bool tristate;
  final ValueChanged<bool?>? onChanged;
  final MouseCursor? mouseCursor;
  final Color? activeColor;
  final WidgetStateProperty<Color?>? fillColor;
  final Color? checkColor;
  final Color? focusColor;
  final Color? hoverColor;
  final WidgetStateProperty<Color?>? overlayColor;
  final double? splashRadius;
  final MaterialTapTargetSize? materialTapTargetSize;
  final VisualDensity? visualDensity;
  final FocusNode? focusNode;
  final bool autofocus;
  final OutlinedBorder? shape;
  final BorderSide? side;
  final bool isError;
  final String? semanticLabel;
  final bool _adaptive;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      final ValueChanged<bool?>? changed = onChanged;
      return _glassCheckIndicator(
        context,
        value: value,
        enabled: changed != null,
        onTap: () {
          if (changed == null) return;
          changed(_nextCheckboxValue(value, tristate));
        },
        round: false,
        focusNode: focusNode,
        autofocus: autofocus,
        activeColor: activeColor,
        fillColor: fillColor,
        checkColor: checkColor,
        isError: isError,
        semanticLabel: semanticLabel,
        materialTapTargetSize: materialTapTargetSize,
        visualDensity: visualDensity,
      );
    }
    if (_adaptive) {
      return Checkbox.adaptive(
        value: value,
        tristate: tristate,
        onChanged: onChanged,
        mouseCursor: mouseCursor,
        activeColor: activeColor,
        fillColor: fillColor,
        checkColor: checkColor,
        focusColor: focusColor,
        hoverColor: hoverColor,
        overlayColor: overlayColor,
        splashRadius: splashRadius,
        materialTapTargetSize: materialTapTargetSize,
        visualDensity: visualDensity,
        focusNode: focusNode,
        autofocus: autofocus,
        shape: shape,
        side: side,
        isError: isError,
        semanticLabel: semanticLabel,
      );
    }
    return Checkbox(
      value: value,
      tristate: tristate,
      onChanged: onChanged,
      mouseCursor: mouseCursor,
      activeColor: activeColor,
      fillColor: fillColor,
      checkColor: checkColor,
      focusColor: focusColor,
      hoverColor: hoverColor,
      overlayColor: overlayColor,
      splashRadius: splashRadius,
      materialTapTargetSize: materialTapTargetSize,
      visualDensity: visualDensity,
      focusNode: focusNode,
      autofocus: autofocus,
      shape: shape,
      side: side,
      isError: isError,
      semanticLabel: semanticLabel,
    );
  }
}

/// Material 复选框的切换序：false → true → (tristate ? null : false)，null → false。
bool? _nextCheckboxValue(bool? value, bool tristate) {
  switch (value) {
    case false:
      return true;
    case true:
      return tristate ? null : false;
    case null:
      return false;
  }
}

// ---------------------------------------------------------------------------
// Radio
// ---------------------------------------------------------------------------

/// [Radio] 的设计系统分派版（含 `.adaptive`）。支持新 [RadioGroup] API 与
/// 已弃用的 `groupValue` / `onChanged`；玻璃下作为 [RadioClient] 登记到组里，
/// RadioGroup 的方向键选择、空格切换与「Tab 只停已选项」照常生效。
class FushiRadio<T> extends StatefulWidget {
  const FushiRadio({
    super.key,
    required this.value,
    this.groupValue,
    this.onChanged,
    this.mouseCursor,
    this.toggleable = false,
    this.activeColor,
    this.fillColor,
    this.focusColor,
    this.hoverColor,
    this.overlayColor,
    this.splashRadius,
    this.materialTapTargetSize,
    this.visualDensity,
    this.focusNode,
    this.autofocus = false,
    this.enabled,
    this.groupRegistry,
    this.backgroundColor,
    this.side,
    this.innerRadius,
  }) : useCupertinoCheckmarkStyle = false,
       _adaptive = false;

  const FushiRadio.adaptive({
    super.key,
    required this.value,
    this.groupValue,
    this.onChanged,
    this.mouseCursor,
    this.toggleable = false,
    this.activeColor,
    this.fillColor,
    this.focusColor,
    this.hoverColor,
    this.overlayColor,
    this.splashRadius,
    this.materialTapTargetSize,
    this.visualDensity,
    this.focusNode,
    this.autofocus = false,
    this.useCupertinoCheckmarkStyle = false,
    this.enabled,
    this.groupRegistry,
    this.backgroundColor,
    this.side,
    this.innerRadius,
  }) : _adaptive = true;

  final T value;
  final T? groupValue;
  final ValueChanged<T?>? onChanged;
  final MouseCursor? mouseCursor;
  final bool toggleable;
  final Color? activeColor;
  final WidgetStateProperty<Color?>? fillColor;
  final Color? focusColor;
  final Color? hoverColor;
  final WidgetStateProperty<Color?>? overlayColor;
  final double? splashRadius;
  final MaterialTapTargetSize? materialTapTargetSize;
  final VisualDensity? visualDensity;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool useCupertinoCheckmarkStyle;
  final bool? enabled;
  final RadioGroupRegistry<T>? groupRegistry;
  final WidgetStateProperty<Color?>? backgroundColor;
  final BorderSide? side;
  final WidgetStateProperty<double?>? innerRadius;
  final bool _adaptive;

  @override
  State<FushiRadio<T>> createState() => _FushiRadioState<T>();
}

class _FushiRadioState<T> extends State<FushiRadio<T>> with RadioClient<T> {
  FocusNode? _internalFocusNode;

  @override
  FocusNode get focusNode =>
      widget.focusNode ?? (_internalFocusNode ??= FocusNode());

  @override
  T get radioValue => widget.value;

  @override
  bool get tristate => widget.toggleable;

  // 在 didChangeDependencies 里缓存：RadioGroup 会在按键处理（build 之外）里
  // 读 [enabled]，那里不能再做继承查找。
  RadioGroupRegistry<T>? _inheritedGroup;

  RadioGroupRegistry<T>? get _groupRegistry =>
      widget.groupRegistry ?? _inheritedGroup;

  @override
  bool get enabled =>
      widget.enabled ?? (widget.onChanged != null || _groupRegistry != null);

  // 只在玻璃下登记：MD3 下由内部 Radio 自己登记，重复登记会让 RadioGroup 的
  // 「组内只有一个选中项」调试断言误报。
  void _syncRegistry() {
    registry = isGlassDesign(context) ? _groupRegistry : null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _inheritedGroup = RadioGroup.maybeOf<T>(context);
    _syncRegistry();
  }

  @override
  void didUpdateWidget(FushiRadio<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRegistry();
  }

  @override
  void dispose() {
    registry = null;
    _internalFocusNode?.dispose();
    super.dispose();
  }

  void _handleTap() {
    final RadioGroupRegistry<T>? group = _groupRegistry;
    final T? groupValue = group != null ? group.groupValue : widget.groupValue;
    final ValueChanged<T?>? change = group != null
        ? group.onChanged
        : widget.onChanged;
    if (change == null) return;
    final bool checked = widget.value == groupValue;
    if (checked) {
      if (widget.toggleable) change(null);
      return;
    }
    change(widget.value);
  }

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      final RadioGroupRegistry<T>? group = _groupRegistry;
      final T? groupValue = group != null
          ? group.groupValue
          : widget.groupValue;
      return _glassCheckIndicator(
        context,
        value: widget.value == groupValue,
        enabled: enabled,
        onTap: _handleTap,
        round: true,
        focusNode: focusNode,
        autofocus: widget.autofocus,
        activeColor: widget.activeColor,
        fillColor: widget.fillColor,
        materialTapTargetSize: widget.materialTapTargetSize,
        visualDensity: widget.visualDensity,
      );
    }
    if (widget._adaptive) {
      return Radio<T>.adaptive(
        value: widget.value,
        groupValue: widget.groupValue,
        onChanged: widget.onChanged,
        mouseCursor: widget.mouseCursor,
        toggleable: widget.toggleable,
        activeColor: widget.activeColor,
        fillColor: widget.fillColor,
        focusColor: widget.focusColor,
        hoverColor: widget.hoverColor,
        overlayColor: widget.overlayColor,
        splashRadius: widget.splashRadius,
        materialTapTargetSize: widget.materialTapTargetSize,
        visualDensity: widget.visualDensity,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        useCupertinoCheckmarkStyle: widget.useCupertinoCheckmarkStyle,
        enabled: widget.enabled,
        groupRegistry: widget.groupRegistry,
        backgroundColor: widget.backgroundColor,
        side: widget.side,
        innerRadius: widget.innerRadius,
      );
    }
    return Radio<T>(
      value: widget.value,
      groupValue: widget.groupValue,
      onChanged: widget.onChanged,
      mouseCursor: widget.mouseCursor,
      toggleable: widget.toggleable,
      activeColor: widget.activeColor,
      fillColor: widget.fillColor,
      focusColor: widget.focusColor,
      hoverColor: widget.hoverColor,
      overlayColor: widget.overlayColor,
      splashRadius: widget.splashRadius,
      materialTapTargetSize: widget.materialTapTargetSize,
      visualDensity: widget.visualDensity,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      groupRegistry: widget.groupRegistry,
      backgroundColor: widget.backgroundColor,
      side: widget.side,
      innerRadius: widget.innerRadius,
    );
  }
}

// ---------------------------------------------------------------------------
// 列表行变体共用的玻璃行
// ---------------------------------------------------------------------------

/// 玻璃下的「选择类列表行」：[GlassListTile] 排版，整行是一个焦点停靠点
/// （Enter / 手柄 A → ActivateIntent → [onTap]），行内 [control] 只做展示。
class _GlassToggleTile extends StatefulWidget {
  const _GlassToggleTile({
    required this.focusNode,
    required this.autofocus,
    required this.enabled,
    required this.onTap,
    required this.onFocusChange,
    required this.title,
    required this.subtitle,
    required this.secondary,
    required this.control,
    required this.controlLeading,
    required this.selected,
    required this.tileColor,
    required this.selectedTileColor,
    required this.hoverColor,
    required this.contentPadding,
    required this.dense,
    required this.isThreeLine,
    required this.shape,
    required this.mouseCursor,
    required this.enableFeedback,
    required this.horizontalTitleGap,
    required this.minTileHeight,
    this.checked,
    this.mixed = false,
    this.toggled,
    this.inMutuallyExclusiveGroup = false,
  });

  final FocusNode? focusNode;
  final bool autofocus;
  final bool enabled;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onFocusChange;
  final Widget? title;
  final Widget? subtitle;
  final Widget? secondary;
  final Widget control;
  final bool controlLeading;
  final bool selected;
  final Color? tileColor;
  final Color? selectedTileColor;
  final Color? hoverColor;
  final EdgeInsetsGeometry? contentPadding;
  final bool? dense;
  final bool? isThreeLine;
  final ShapeBorder? shape;
  final MouseCursor? mouseCursor;
  final bool? enableFeedback;
  final double? horizontalTitleGap;
  final double? minTileHeight;
  final bool? checked;
  final bool mixed;
  final bool? toggled;
  final bool inMutuallyExclusiveGroup;

  @override
  State<_GlassToggleTile> createState() => _GlassToggleTileState();
}

class _GlassToggleTileState extends State<_GlassToggleTile> {
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;

  late final Map<Type, Action<Intent>> _actions = <Type, Action<Intent>>{
    ActivateIntent: CallbackAction<ActivateIntent>(
      onInvoke: (ActivateIntent intent) {
        _activate();
        return null;
      },
    ),
  };

  void _activate() {
    if (!widget.enabled) return;
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final TextTheme tt = theme.textTheme;
    final bool enabled = widget.enabled;
    final bool dense = widget.dense ?? false;
    final Color disabledFg = cs.onSurface.withValues(alpha: 0.38);
    final Color titleColor = !enabled
        ? disabledFg
        : (widget.selected ? cs.primary : cs.onSurface);
    final Color subtitleColor = enabled ? cs.onSurfaceVariant : disabledFg;

    final Widget? leading = widget.controlLeading
        ? widget.control
        : widget.secondary;
    final Widget? trailing = widget.controlLeading
        ? widget.secondary
        : widget.control;

    Widget body = GlassListTile(
      title: widget.title ?? const SizedBox.shrink(),
      subtitle: widget.subtitle,
      trailing: trailing,
      contentPadding: EdgeInsets.zero,
      titleStyle:
          (dense ? tt.bodyMedium : tt.bodyLarge)?.copyWith(color: titleColor) ??
          TextStyle(color: titleColor),
      subtitleStyle: (tt.bodyMedium ?? const TextStyle()).copyWith(
        color: subtitleColor,
      ),
    );
    if (leading != null) {
      body = Row(
        children: <Widget>[
          IconTheme.merge(
            data: IconThemeData(color: subtitleColor),
            child: leading,
          ),
          SizedBox(width: widget.horizontalTitleGap ?? 16),
          Expanded(child: body),
        ],
      );
    }
    final double minHeight =
        widget.minTileHeight ??
        (dense
            ? 48
            : widget.subtitle == null
            ? 56
            : ((widget.isThreeLine ?? false) ? 88 : 72));
    body = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding:
            widget.contentPadding ??
            EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 4 : 8),
        child: Align(alignment: AlignmentDirectional.centerStart, child: body),
      ),
    );

    final Color base =
        (widget.selected ? widget.selectedTileColor : widget.tileColor) ??
        Colors.transparent;
    final bool highlight = enabled && (_pressed || _hovered || _focused);
    final Color overlay =
        widget.hoverColor ?? cs.onSurface.withValues(alpha: 0.08);
    final Color fill = highlight ? Color.alphaBlend(overlay, base) : base;
    final BorderSide ring = _focused
        ? BorderSide(color: cs.primary, width: 2)
        : BorderSide.none;
    final ShapeBorder shape = switch (widget.shape) {
      final OutlinedBorder outlined => outlined.copyWith(side: ring),
      final ShapeBorder other when !_focused => other,
      _ => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: ring,
      ),
    };

    final Widget decorated = AnimatedContainer(
      duration: _pressed ? Duration.zero : const Duration(milliseconds: 150),
      curve: Curves.easeOutCubic,
      decoration: ShapeDecoration(color: fill, shape: shape),
      child: body,
    );

    return MergeSemantics(
      child: Semantics(
        enabled: enabled,
        checked: widget.checked,
        mixed: widget.mixed ? true : null,
        toggled: widget.toggled,
        inMutuallyExclusiveGroup: widget.inMutuallyExclusiveGroup ? true : null,
        selected: widget.selected ? true : null,
        onTap: enabled && widget.onTap != null ? _activate : null,
        child: FocusableActionDetector(
          enabled: enabled,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          actions: _actions,
          mouseCursor: enabled
              ? (widget.mouseCursor ?? SystemMouseCursors.click)
              : SystemMouseCursors.basic,
          onFocusChange: widget.onFocusChange,
          onShowFocusHighlight: (bool v) => setState(() => _focused = v),
          onShowHoverHighlight: (bool v) => setState(() => _hovered = v),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
            onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
            onTapCancel: enabled
                ? () => setState(() => _pressed = false)
                : null,
            onTap: enabled && widget.onTap != null
                ? () {
                    if (widget.enableFeedback ?? true) {
                      Feedback.forTap(context);
                    }
                    _activate();
                  }
                : null,
            child: decorated,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CheckboxListTile
// ---------------------------------------------------------------------------

/// [CheckboxListTile] 的设计系统分派版（含 `.adaptive`）。
class FushiCheckboxListTile extends StatelessWidget {
  const FushiCheckboxListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.mouseCursor,
    this.activeColor,
    this.fillColor,
    this.checkColor,
    this.hoverColor,
    this.overlayColor,
    this.splashRadius,
    this.materialTapTargetSize,
    this.visualDensity,
    this.focusNode,
    this.statesController,
    this.autofocus = false,
    this.shape,
    this.side,
    this.isError = false,
    this.enabled,
    this.tileColor,
    this.title,
    this.subtitle,
    this.isThreeLine,
    this.dense,
    this.secondary,
    this.selected = false,
    this.controlAffinity,
    this.contentPadding,
    this.tristate = false,
    this.checkboxShape,
    this.selectedTileColor,
    this.onFocusChange,
    this.enableFeedback,
    this.horizontalTitleGap,
    this.minVerticalPadding,
    this.minLeadingWidth,
    this.minTileHeight,
    this.checkboxSemanticLabel,
    this.checkboxScaleFactor = 1.0,
    this.titleAlignment,
    this.internalAddSemanticForOnTap = false,
  }) : _adaptive = false;

  const FushiCheckboxListTile.adaptive({
    super.key,
    required this.value,
    required this.onChanged,
    this.mouseCursor,
    this.activeColor,
    this.fillColor,
    this.checkColor,
    this.hoverColor,
    this.overlayColor,
    this.splashRadius,
    this.materialTapTargetSize,
    this.visualDensity,
    this.focusNode,
    this.statesController,
    this.autofocus = false,
    this.shape,
    this.side,
    this.isError = false,
    this.enabled,
    this.tileColor,
    this.title,
    this.subtitle,
    this.isThreeLine,
    this.dense,
    this.secondary,
    this.selected = false,
    this.controlAffinity,
    this.contentPadding,
    this.tristate = false,
    this.checkboxShape,
    this.selectedTileColor,
    this.onFocusChange,
    this.enableFeedback,
    this.horizontalTitleGap,
    this.minVerticalPadding,
    this.minLeadingWidth,
    this.minTileHeight,
    this.checkboxSemanticLabel,
    this.checkboxScaleFactor = 1.0,
    this.titleAlignment,
    this.internalAddSemanticForOnTap = false,
  }) : _adaptive = true;

  final bool? value;
  final ValueChanged<bool?>? onChanged;
  final MouseCursor? mouseCursor;
  final Color? activeColor;
  final WidgetStateProperty<Color?>? fillColor;
  final Color? checkColor;
  final Color? hoverColor;
  final WidgetStateProperty<Color?>? overlayColor;
  final double? splashRadius;
  final MaterialTapTargetSize? materialTapTargetSize;
  final VisualDensity? visualDensity;
  final FocusNode? focusNode;
  final WidgetStatesController? statesController;
  final bool autofocus;
  final ShapeBorder? shape;
  final BorderSide? side;
  final bool isError;
  final bool? enabled;
  final Color? tileColor;
  final Widget? title;
  final Widget? subtitle;
  final bool? isThreeLine;
  final bool? dense;
  final Widget? secondary;
  final bool selected;
  final ListTileControlAffinity? controlAffinity;
  final EdgeInsetsGeometry? contentPadding;
  final bool tristate;
  final OutlinedBorder? checkboxShape;
  final Color? selectedTileColor;
  final ValueChanged<bool>? onFocusChange;
  final bool? enableFeedback;
  final double? horizontalTitleGap;
  final double? minVerticalPadding;
  final double? minLeadingWidth;
  final double? minTileHeight;
  final String? checkboxSemanticLabel;
  final double checkboxScaleFactor;
  final ListTileTitleAlignment? titleAlignment;
  final bool internalAddSemanticForOnTap;
  final bool _adaptive;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildGlass(context);
    if (_adaptive) {
      return CheckboxListTile.adaptive(
        value: value,
        onChanged: onChanged,
        mouseCursor: mouseCursor,
        activeColor: activeColor,
        fillColor: fillColor,
        checkColor: checkColor,
        hoverColor: hoverColor,
        overlayColor: overlayColor,
        splashRadius: splashRadius,
        materialTapTargetSize: materialTapTargetSize,
        visualDensity: visualDensity,
        focusNode: focusNode,
        statesController: statesController,
        autofocus: autofocus,
        shape: shape,
        side: side,
        isError: isError,
        enabled: enabled,
        tileColor: tileColor,
        title: title,
        subtitle: subtitle,
        isThreeLine: isThreeLine,
        dense: dense,
        secondary: secondary,
        selected: selected,
        controlAffinity: controlAffinity,
        contentPadding: contentPadding,
        tristate: tristate,
        checkboxShape: checkboxShape,
        selectedTileColor: selectedTileColor,
        onFocusChange: onFocusChange,
        enableFeedback: enableFeedback,
        horizontalTitleGap: horizontalTitleGap,
        minVerticalPadding: minVerticalPadding,
        minLeadingWidth: minLeadingWidth,
        minTileHeight: minTileHeight,
        checkboxSemanticLabel: checkboxSemanticLabel,
        checkboxScaleFactor: checkboxScaleFactor,
        titleAlignment: titleAlignment,
        internalAddSemanticForOnTap: internalAddSemanticForOnTap,
      );
    }
    return CheckboxListTile(
      value: value,
      onChanged: onChanged,
      mouseCursor: mouseCursor,
      activeColor: activeColor,
      fillColor: fillColor,
      checkColor: checkColor,
      hoverColor: hoverColor,
      overlayColor: overlayColor,
      splashRadius: splashRadius,
      materialTapTargetSize: materialTapTargetSize,
      visualDensity: visualDensity,
      focusNode: focusNode,
      statesController: statesController,
      autofocus: autofocus,
      shape: shape,
      side: side,
      isError: isError,
      enabled: enabled,
      tileColor: tileColor,
      title: title,
      subtitle: subtitle,
      isThreeLine: isThreeLine,
      dense: dense,
      secondary: secondary,
      selected: selected,
      controlAffinity: controlAffinity,
      contentPadding: contentPadding,
      tristate: tristate,
      checkboxShape: checkboxShape,
      selectedTileColor: selectedTileColor,
      onFocusChange: onFocusChange,
      enableFeedback: enableFeedback,
      horizontalTitleGap: horizontalTitleGap,
      minVerticalPadding: minVerticalPadding,
      minLeadingWidth: minLeadingWidth,
      minTileHeight: minTileHeight,
      checkboxSemanticLabel: checkboxSemanticLabel,
      checkboxScaleFactor: checkboxScaleFactor,
      titleAlignment: titleAlignment,
      internalAddSemanticForOnTap: internalAddSemanticForOnTap,
    );
  }

  Widget _buildGlass(BuildContext context) {
    final ValueChanged<bool?>? changed = onChanged;
    final bool isEnabled = (enabled ?? true) && changed != null;
    final ListTileControlAffinity affinity =
        controlAffinity ??
        ListTileTheme.of(context).controlAffinity ??
        ListTileControlAffinity.platform;
    return _GlassToggleTile(
      focusNode: focusNode,
      autofocus: autofocus,
      enabled: isEnabled,
      onTap: changed == null
          ? null
          : () => changed(_nextCheckboxValue(value, tristate)),
      onFocusChange: onFocusChange,
      title: title,
      subtitle: subtitle,
      secondary: secondary,
      control: _glassCheckIndicator(
        context,
        value: value,
        enabled: isEnabled,
        onTap: null,
        round: false,
        activeColor: activeColor,
        fillColor: fillColor,
        checkColor: checkColor,
        isError: isError,
        scale: checkboxScaleFactor,
      ),
      controlLeading: affinity == ListTileControlAffinity.leading,
      selected: selected,
      tileColor: tileColor,
      selectedTileColor: selectedTileColor,
      hoverColor: hoverColor,
      contentPadding: contentPadding,
      dense: dense,
      isThreeLine: isThreeLine,
      shape: shape,
      mouseCursor: mouseCursor,
      enableFeedback: enableFeedback,
      horizontalTitleGap: horizontalTitleGap,
      minTileHeight: minTileHeight,
      checked: value ?? false,
      mixed: value == null,
    );
  }
}

// ---------------------------------------------------------------------------
// RadioListTile
// ---------------------------------------------------------------------------

/// [RadioListTile] 的设计系统分派版（含 `.adaptive`）。
class FushiRadioListTile<T> extends StatefulWidget {
  const FushiRadioListTile({
    super.key,
    required this.value,
    this.groupValue,
    this.onChanged,
    this.mouseCursor,
    this.toggleable = false,
    this.activeColor,
    this.fillColor,
    this.hoverColor,
    this.overlayColor,
    this.splashRadius,
    this.materialTapTargetSize,
    this.title,
    this.subtitle,
    this.isThreeLine,
    this.dense,
    this.secondary,
    this.selected = false,
    this.controlAffinity,
    this.autofocus = false,
    this.contentPadding,
    this.shape,
    this.tileColor,
    this.selectedTileColor,
    this.visualDensity,
    this.focusNode,
    this.statesController,
    this.onFocusChange,
    this.enableFeedback,
    this.horizontalTitleGap,
    this.minVerticalPadding,
    this.minLeadingWidth,
    this.minTileHeight,
    this.radioScaleFactor = 1.0,
    this.titleAlignment,
    this.enabled,
    this.internalAddSemanticForOnTap = false,
    this.radioBackgroundColor,
    this.radioSide,
    this.radioInnerRadius,
  }) : useCupertinoCheckmarkStyle = false,
       _adaptive = false;

  const FushiRadioListTile.adaptive({
    super.key,
    required this.value,
    this.groupValue,
    this.onChanged,
    this.mouseCursor,
    this.toggleable = false,
    this.activeColor,
    this.fillColor,
    this.hoverColor,
    this.overlayColor,
    this.splashRadius,
    this.materialTapTargetSize,
    this.title,
    this.subtitle,
    this.isThreeLine,
    this.dense,
    this.secondary,
    this.selected = false,
    this.controlAffinity,
    this.autofocus = false,
    this.contentPadding,
    this.shape,
    this.tileColor,
    this.selectedTileColor,
    this.visualDensity,
    this.focusNode,
    this.statesController,
    this.onFocusChange,
    this.enableFeedback,
    this.horizontalTitleGap,
    this.minVerticalPadding,
    this.minLeadingWidth,
    this.minTileHeight,
    this.radioScaleFactor = 1.0,
    this.enabled,
    this.useCupertinoCheckmarkStyle = false,
    this.titleAlignment,
    this.internalAddSemanticForOnTap = false,
    this.radioBackgroundColor,
    this.radioSide,
    this.radioInnerRadius,
  }) : _adaptive = true;

  final T value;
  final T? groupValue;
  final ValueChanged<T?>? onChanged;
  final MouseCursor? mouseCursor;
  final bool toggleable;
  final Color? activeColor;
  final WidgetStateProperty<Color?>? fillColor;
  final Color? hoverColor;
  final WidgetStateProperty<Color?>? overlayColor;
  final double? splashRadius;
  final MaterialTapTargetSize? materialTapTargetSize;
  final Widget? title;
  final Widget? subtitle;
  final bool? isThreeLine;
  final bool? dense;
  final Widget? secondary;
  final bool selected;
  final ListTileControlAffinity? controlAffinity;
  final bool autofocus;
  final EdgeInsetsGeometry? contentPadding;
  final ShapeBorder? shape;
  final Color? tileColor;
  final Color? selectedTileColor;
  final VisualDensity? visualDensity;
  final FocusNode? focusNode;
  final WidgetStatesController? statesController;
  final ValueChanged<bool>? onFocusChange;
  final bool? enableFeedback;
  final double? horizontalTitleGap;
  final double? minVerticalPadding;
  final double? minLeadingWidth;
  final double? minTileHeight;
  final double radioScaleFactor;
  final ListTileTitleAlignment? titleAlignment;
  final bool? enabled;
  final bool useCupertinoCheckmarkStyle;
  final bool internalAddSemanticForOnTap;
  final WidgetStateProperty<Color?>? radioBackgroundColor;
  final BorderSide? radioSide;
  final WidgetStateProperty<double?>? radioInnerRadius;
  final bool _adaptive;

  @override
  State<FushiRadioListTile<T>> createState() => _FushiRadioListTileState<T>();
}

class _FushiRadioListTileState<T> extends State<FushiRadioListTile<T>>
    with RadioClient<T> {
  FocusNode? _internalFocusNode;

  @override
  FocusNode get focusNode =>
      widget.focusNode ?? (_internalFocusNode ??= FocusNode());

  @override
  T get radioValue => widget.value;

  @override
  bool get tristate => widget.toggleable;

  // 缓存理由同 _FushiRadioState._inheritedGroup。
  RadioGroupRegistry<T>? _group;

  @override
  bool get enabled =>
      widget.enabled ?? (widget.onChanged != null || _group != null);

  T? get _groupValue => _group?.groupValue ?? widget.groupValue;

  bool get _checked => widget.value == _groupValue;

  // 只在玻璃下登记（MD3 下由 RadioListTile 自己登记，见 _FushiRadioState）。
  void _syncRegistry() {
    registry = isGlassDesign(context) ? _group : null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _group = RadioGroup.maybeOf<T>(context);
    _syncRegistry();
  }

  @override
  void didUpdateWidget(FushiRadioListTile<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRegistry();
  }

  @override
  void dispose() {
    registry = null;
    _internalFocusNode?.dispose();
    super.dispose();
  }

  // 与 RadioListTile._handleListTileTap 同语义：已选且不可取消则不动；
  // 组与 onChanged 都在时两边都通知。
  void _handleTap() {
    if (!widget.toggleable && _checked) return;
    final T? next = _checked ? null : widget.value;
    _group?.onChanged(next);
    widget.onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildGlass(context);
    if (widget._adaptive) {
      return RadioListTile<T>.adaptive(
        value: widget.value,
        groupValue: widget.groupValue,
        onChanged: widget.onChanged,
        mouseCursor: widget.mouseCursor,
        toggleable: widget.toggleable,
        activeColor: widget.activeColor,
        fillColor: widget.fillColor,
        hoverColor: widget.hoverColor,
        overlayColor: widget.overlayColor,
        splashRadius: widget.splashRadius,
        materialTapTargetSize: widget.materialTapTargetSize,
        title: widget.title,
        subtitle: widget.subtitle,
        isThreeLine: widget.isThreeLine,
        dense: widget.dense,
        secondary: widget.secondary,
        selected: widget.selected,
        controlAffinity: widget.controlAffinity,
        autofocus: widget.autofocus,
        contentPadding: widget.contentPadding,
        shape: widget.shape,
        tileColor: widget.tileColor,
        selectedTileColor: widget.selectedTileColor,
        visualDensity: widget.visualDensity,
        focusNode: widget.focusNode,
        statesController: widget.statesController,
        onFocusChange: widget.onFocusChange,
        enableFeedback: widget.enableFeedback,
        horizontalTitleGap: widget.horizontalTitleGap,
        minVerticalPadding: widget.minVerticalPadding,
        minLeadingWidth: widget.minLeadingWidth,
        minTileHeight: widget.minTileHeight,
        radioScaleFactor: widget.radioScaleFactor,
        enabled: widget.enabled,
        useCupertinoCheckmarkStyle: widget.useCupertinoCheckmarkStyle,
        titleAlignment: widget.titleAlignment,
        internalAddSemanticForOnTap: widget.internalAddSemanticForOnTap,
        radioBackgroundColor: widget.radioBackgroundColor,
        radioSide: widget.radioSide,
        radioInnerRadius: widget.radioInnerRadius,
      );
    }
    return RadioListTile<T>(
      value: widget.value,
      groupValue: widget.groupValue,
      onChanged: widget.onChanged,
      mouseCursor: widget.mouseCursor,
      toggleable: widget.toggleable,
      activeColor: widget.activeColor,
      fillColor: widget.fillColor,
      hoverColor: widget.hoverColor,
      overlayColor: widget.overlayColor,
      splashRadius: widget.splashRadius,
      materialTapTargetSize: widget.materialTapTargetSize,
      title: widget.title,
      subtitle: widget.subtitle,
      isThreeLine: widget.isThreeLine,
      dense: widget.dense,
      secondary: widget.secondary,
      selected: widget.selected,
      controlAffinity: widget.controlAffinity,
      autofocus: widget.autofocus,
      contentPadding: widget.contentPadding,
      shape: widget.shape,
      tileColor: widget.tileColor,
      selectedTileColor: widget.selectedTileColor,
      visualDensity: widget.visualDensity,
      focusNode: widget.focusNode,
      statesController: widget.statesController,
      onFocusChange: widget.onFocusChange,
      enableFeedback: widget.enableFeedback,
      horizontalTitleGap: widget.horizontalTitleGap,
      minVerticalPadding: widget.minVerticalPadding,
      minLeadingWidth: widget.minLeadingWidth,
      minTileHeight: widget.minTileHeight,
      radioScaleFactor: widget.radioScaleFactor,
      titleAlignment: widget.titleAlignment,
      enabled: widget.enabled,
      internalAddSemanticForOnTap: widget.internalAddSemanticForOnTap,
      radioBackgroundColor: widget.radioBackgroundColor,
      radioSide: widget.radioSide,
      radioInnerRadius: widget.radioInnerRadius,
    );
  }

  Widget _buildGlass(BuildContext context) {
    final bool isEnabled = enabled;
    final bool checked = _checked;
    final ListTileControlAffinity affinity =
        widget.controlAffinity ??
        ListTileTheme.of(context).controlAffinity ??
        ListTileControlAffinity.platform;
    return _GlassToggleTile(
      focusNode: focusNode,
      autofocus: widget.autofocus,
      enabled: isEnabled,
      onTap: _handleTap,
      onFocusChange: widget.onFocusChange,
      title: widget.title,
      subtitle: widget.subtitle,
      secondary: widget.secondary,
      control: _glassCheckIndicator(
        context,
        value: checked,
        enabled: isEnabled,
        onTap: null,
        round: true,
        activeColor: widget.activeColor,
        fillColor: widget.fillColor,
        scale: widget.radioScaleFactor,
      ),
      // RadioListTile 的 platform 默认把单选钮放在行首。
      controlLeading: affinity != ListTileControlAffinity.trailing,
      selected: widget.selected,
      tileColor: widget.tileColor,
      selectedTileColor: widget.selectedTileColor,
      hoverColor: widget.hoverColor,
      contentPadding: widget.contentPadding,
      dense: widget.dense,
      isThreeLine: widget.isThreeLine,
      shape: widget.shape,
      mouseCursor: widget.mouseCursor,
      enableFeedback: widget.enableFeedback,
      horizontalTitleGap: widget.horizontalTitleGap,
      minTileHeight: widget.minTileHeight,
      checked: checked,
      inMutuallyExclusiveGroup: true,
    );
  }
}

// ---------------------------------------------------------------------------
// SwitchListTile
// ---------------------------------------------------------------------------

/// [SwitchListTile] 的设计系统分派版（含 `.adaptive`）。
class FushiSwitchListTile extends StatelessWidget {
  const FushiSwitchListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.activeThumbColor,
    this.activeTrackColor,
    this.inactiveThumbColor,
    this.inactiveTrackColor,
    this.activeThumbImage,
    this.onActiveThumbImageError,
    this.inactiveThumbImage,
    this.onInactiveThumbImageError,
    this.thumbColor,
    this.trackColor,
    this.trackOutlineColor,
    this.thumbIcon,
    this.materialTapTargetSize,
    this.dragStartBehavior = DragStartBehavior.start,
    this.mouseCursor,
    this.overlayColor,
    this.splashRadius,
    this.focusNode,
    this.statesController,
    this.onFocusChange,
    this.autofocus = false,
    this.tileColor,
    this.title,
    this.subtitle,
    this.isThreeLine,
    this.dense,
    this.contentPadding,
    this.secondary,
    this.selected = false,
    this.controlAffinity,
    this.shape,
    this.selectedTileColor,
    this.visualDensity,
    this.enableFeedback,
    this.horizontalTitleGap,
    this.minVerticalPadding,
    this.minLeadingWidth,
    this.minTileHeight,
    this.hoverColor,
    this.internalAddSemanticForOnTap = false,
  }) : applyCupertinoTheme = null,
       _adaptive = false;

  const FushiSwitchListTile.adaptive({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.activeThumbColor,
    this.activeTrackColor,
    this.inactiveThumbColor,
    this.inactiveTrackColor,
    this.activeThumbImage,
    this.onActiveThumbImageError,
    this.inactiveThumbImage,
    this.onInactiveThumbImageError,
    this.thumbColor,
    this.trackColor,
    this.trackOutlineColor,
    this.thumbIcon,
    this.materialTapTargetSize,
    this.dragStartBehavior = DragStartBehavior.start,
    this.mouseCursor,
    this.overlayColor,
    this.splashRadius,
    this.focusNode,
    this.statesController,
    this.onFocusChange,
    this.autofocus = false,
    this.applyCupertinoTheme,
    this.tileColor,
    this.title,
    this.subtitle,
    this.isThreeLine,
    this.dense,
    this.contentPadding,
    this.secondary,
    this.selected = false,
    this.controlAffinity,
    this.shape,
    this.selectedTileColor,
    this.visualDensity,
    this.enableFeedback,
    this.horizontalTitleGap,
    this.minVerticalPadding,
    this.minLeadingWidth,
    this.minTileHeight,
    this.hoverColor,
    this.internalAddSemanticForOnTap = false,
  }) : _adaptive = true;

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;
  final Color? activeThumbColor;
  final Color? activeTrackColor;
  final Color? inactiveThumbColor;
  final Color? inactiveTrackColor;
  final ImageProvider? activeThumbImage;
  final ImageErrorListener? onActiveThumbImageError;
  final ImageProvider? inactiveThumbImage;
  final ImageErrorListener? onInactiveThumbImageError;
  final WidgetStateProperty<Color?>? thumbColor;
  final WidgetStateProperty<Color?>? trackColor;
  final WidgetStateProperty<Color?>? trackOutlineColor;
  final WidgetStateProperty<Icon?>? thumbIcon;
  final MaterialTapTargetSize? materialTapTargetSize;
  final DragStartBehavior dragStartBehavior;
  final MouseCursor? mouseCursor;
  final WidgetStateProperty<Color?>? overlayColor;
  final double? splashRadius;
  final FocusNode? focusNode;
  final WidgetStatesController? statesController;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final bool? applyCupertinoTheme;
  final Color? tileColor;
  final Widget? title;
  final Widget? subtitle;
  final bool? isThreeLine;
  final bool? dense;
  final EdgeInsetsGeometry? contentPadding;
  final Widget? secondary;
  final bool selected;
  final ListTileControlAffinity? controlAffinity;
  final ShapeBorder? shape;
  final Color? selectedTileColor;
  final VisualDensity? visualDensity;
  final bool? enableFeedback;
  final double? horizontalTitleGap;
  final double? minVerticalPadding;
  final double? minLeadingWidth;
  final double? minTileHeight;
  final Color? hoverColor;
  final bool internalAddSemanticForOnTap;
  final bool _adaptive;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildGlass(context);
    if (_adaptive) {
      return SwitchListTile.adaptive(
        value: value,
        onChanged: onChanged,
        activeColor: activeColor,
        activeThumbColor: activeThumbColor,
        activeTrackColor: activeTrackColor,
        inactiveThumbColor: inactiveThumbColor,
        inactiveTrackColor: inactiveTrackColor,
        activeThumbImage: activeThumbImage,
        onActiveThumbImageError: onActiveThumbImageError,
        inactiveThumbImage: inactiveThumbImage,
        onInactiveThumbImageError: onInactiveThumbImageError,
        thumbColor: thumbColor,
        trackColor: trackColor,
        trackOutlineColor: trackOutlineColor,
        thumbIcon: thumbIcon,
        materialTapTargetSize: materialTapTargetSize,
        dragStartBehavior: dragStartBehavior,
        mouseCursor: mouseCursor,
        overlayColor: overlayColor,
        splashRadius: splashRadius,
        focusNode: focusNode,
        statesController: statesController,
        onFocusChange: onFocusChange,
        autofocus: autofocus,
        applyCupertinoTheme: applyCupertinoTheme,
        tileColor: tileColor,
        title: title,
        subtitle: subtitle,
        isThreeLine: isThreeLine,
        dense: dense,
        contentPadding: contentPadding,
        secondary: secondary,
        selected: selected,
        controlAffinity: controlAffinity,
        shape: shape,
        selectedTileColor: selectedTileColor,
        visualDensity: visualDensity,
        enableFeedback: enableFeedback,
        horizontalTitleGap: horizontalTitleGap,
        minVerticalPadding: minVerticalPadding,
        minLeadingWidth: minLeadingWidth,
        minTileHeight: minTileHeight,
        hoverColor: hoverColor,
        internalAddSemanticForOnTap: internalAddSemanticForOnTap,
      );
    }
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeColor: activeColor,
      activeThumbColor: activeThumbColor,
      activeTrackColor: activeTrackColor,
      inactiveThumbColor: inactiveThumbColor,
      inactiveTrackColor: inactiveTrackColor,
      activeThumbImage: activeThumbImage,
      onActiveThumbImageError: onActiveThumbImageError,
      inactiveThumbImage: inactiveThumbImage,
      onInactiveThumbImageError: onInactiveThumbImageError,
      thumbColor: thumbColor,
      trackColor: trackColor,
      trackOutlineColor: trackOutlineColor,
      thumbIcon: thumbIcon,
      materialTapTargetSize: materialTapTargetSize,
      dragStartBehavior: dragStartBehavior,
      mouseCursor: mouseCursor,
      overlayColor: overlayColor,
      splashRadius: splashRadius,
      focusNode: focusNode,
      statesController: statesController,
      onFocusChange: onFocusChange,
      autofocus: autofocus,
      tileColor: tileColor,
      title: title,
      subtitle: subtitle,
      isThreeLine: isThreeLine,
      dense: dense,
      contentPadding: contentPadding,
      secondary: secondary,
      selected: selected,
      controlAffinity: controlAffinity,
      shape: shape,
      selectedTileColor: selectedTileColor,
      visualDensity: visualDensity,
      enableFeedback: enableFeedback,
      horizontalTitleGap: horizontalTitleGap,
      minVerticalPadding: minVerticalPadding,
      minLeadingWidth: minLeadingWidth,
      minTileHeight: minTileHeight,
      hoverColor: hoverColor,
      internalAddSemanticForOnTap: internalAddSemanticForOnTap,
    );
  }

  Widget _buildGlass(BuildContext context) {
    final ValueChanged<bool>? changed = onChanged;
    final bool isEnabled = changed != null;
    final ListTileControlAffinity affinity =
        controlAffinity ??
        ListTileTheme.of(context).controlAffinity ??
        ListTileControlAffinity.platform;
    Widget control = ExcludeFocus(
      child: IgnorePointer(
        child: _glassSwitchVisual(
          context,
          value: value,
          onChanged: null,
          activeThumbColor: activeThumbColor,
          activeTrackColor: activeTrackColor,
          inactiveThumbColor: inactiveThumbColor,
          inactiveTrackColor: inactiveTrackColor,
          thumbColor: thumbColor,
          trackColor: trackColor,
        ),
      ),
    );
    if (!isEnabled) control = Opacity(opacity: 0.38, child: control);
    return _GlassToggleTile(
      focusNode: focusNode,
      autofocus: autofocus,
      enabled: isEnabled,
      onTap: changed == null ? null : () => changed(!value),
      onFocusChange: onFocusChange,
      title: title,
      subtitle: subtitle,
      secondary: secondary,
      control: control,
      controlLeading: affinity == ListTileControlAffinity.leading,
      selected: selected,
      tileColor: tileColor,
      selectedTileColor: selectedTileColor,
      hoverColor: hoverColor,
      contentPadding: contentPadding,
      dense: dense,
      isThreeLine: isThreeLine,
      shape: shape,
      mouseCursor: mouseCursor,
      enableFeedback: enableFeedback,
      horizontalTitleGap: horizontalTitleGap,
      minTileHeight: minTileHeight,
      toggled: value,
    );
  }
}

// ---------------------------------------------------------------------------
// SegmentedButton
// ---------------------------------------------------------------------------

/// [SegmentedButton] 的设计系统分派版。
///
/// 玻璃下：单选、不允许空选、横排、2–6 段且每段 label 为 null 或纯文本 [Text]
/// 时用 [GlassSegmentedControl]（滑动玻璃指示器，每段自带焦点 + Enter 激活）；
/// 其余情形（多选、允许空选、竖排、段数越界、富文本 label）用一排玻璃按钮，
/// 选中段以 secondaryContainer 着色、按 [showSelectedIcon] 显示勾。
class FushiSegmentedButton<T> extends StatefulWidget {
  const FushiSegmentedButton({
    super.key,
    required this.segments,
    required this.selected,
    this.onSelectionChanged,
    this.multiSelectionEnabled = false,
    this.emptySelectionAllowed = false,
    this.expandedInsets,
    this.style,
    this.showSelectedIcon = true,
    this.selectedIcon,
    this.direction = Axis.horizontal,
  });

  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final void Function(Set<T>)? onSelectionChanged;
  final bool multiSelectionEnabled;
  final bool emptySelectionAllowed;
  final EdgeInsets? expandedInsets;
  final ButtonStyle? style;
  final bool showSelectedIcon;
  final Widget? selectedIcon;
  final Axis direction;

  /// 转发 [SegmentedButton.styleFrom]（调用点改类名后仍能编译）。
  static ButtonStyle styleFrom({
    Color? foregroundColor,
    Color? backgroundColor,
    Color? selectedForegroundColor,
    Color? selectedBackgroundColor,
    Color? disabledForegroundColor,
    Color? disabledBackgroundColor,
    Color? shadowColor,
    Color? surfaceTintColor,
    Color? iconColor,
    double? iconSize,
    Color? disabledIconColor,
    Color? overlayColor,
    double? elevation,
    TextStyle? textStyle,
    EdgeInsetsGeometry? padding,
    Size? minimumSize,
    Size? fixedSize,
    Size? maximumSize,
    BorderSide? side,
    OutlinedBorder? shape,
    MouseCursor? enabledMouseCursor,
    MouseCursor? disabledMouseCursor,
    VisualDensity? visualDensity,
    MaterialTapTargetSize? tapTargetSize,
    Duration? animationDuration,
    bool? enableFeedback,
    AlignmentGeometry? alignment,
    InteractiveInkFeatureFactory? splashFactory,
  }) {
    return SegmentedButton.styleFrom(
      foregroundColor: foregroundColor,
      backgroundColor: backgroundColor,
      selectedForegroundColor: selectedForegroundColor,
      selectedBackgroundColor: selectedBackgroundColor,
      disabledForegroundColor: disabledForegroundColor,
      disabledBackgroundColor: disabledBackgroundColor,
      shadowColor: shadowColor,
      surfaceTintColor: surfaceTintColor,
      iconColor: iconColor,
      iconSize: iconSize,
      disabledIconColor: disabledIconColor,
      overlayColor: overlayColor,
      elevation: elevation,
      textStyle: textStyle,
      padding: padding,
      minimumSize: minimumSize,
      fixedSize: fixedSize,
      maximumSize: maximumSize,
      side: side,
      shape: shape,
      enabledMouseCursor: enabledMouseCursor,
      disabledMouseCursor: disabledMouseCursor,
      visualDensity: visualDensity,
      tapTargetSize: tapTargetSize,
      animationDuration: animationDuration,
      enableFeedback: enableFeedback,
      alignment: alignment,
      splashFactory: splashFactory,
    );
  }

  @override
  State<FushiSegmentedButton<T>> createState() =>
      _FushiSegmentedButtonState<T>();
}

class _FushiSegmentedButtonState<T> extends State<FushiSegmentedButton<T>> {
  // GlassSegmentedControl 在 tapDown 与 tap 上各回调一次（两次之间父级还没
  // 重建），这里吞掉同一次点击的第二次通知。
  Set<T>? _pendingSelection;

  @override
  void didUpdateWidget(FushiSegmentedButton<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pendingSelection = null;
  }

  bool get _enabled => widget.onSelectionChanged != null;

  /// 与 [SegmentedButtonState] 的按下逻辑同语义。
  void _handlePressed(T segmentValue) {
    final void Function(Set<T>)? notify = widget.onSelectionChanged;
    if (notify == null) return;
    final Set<T> current = _pendingSelection ?? widget.selected;
    final bool onlySelectedSegment =
        current.length == 1 && current.contains(segmentValue);
    final bool validChange =
        widget.emptySelectionAllowed || !onlySelectedSegment;
    if (!validChange) return;
    final bool toggle =
        widget.multiSelectionEnabled ||
        (widget.emptySelectionAllowed && onlySelectedSegment);
    final Set<T> pressed = <T>{segmentValue};
    final Set<T> updated = toggle
        ? (current.contains(segmentValue)
              ? current.difference(pressed)
              : current.union(pressed))
        : pressed;
    if (setEquals(updated, current)) return;
    _pendingSelection = updated;
    notify(updated);
  }

  /// 能否用 [GlassSegmentedControl] 表达（否则退回玻璃按钮行）。
  bool get _fitsSegmentedControl {
    if (widget.multiSelectionEnabled || widget.emptySelectionAllowed) {
      return false;
    }
    if (widget.direction != Axis.horizontal) return false;
    if (widget.segments.length < 2 || widget.segments.length > 6) return false;
    if (widget.selected.length != 1) return false;
    if (!widget.segments.any(
      (ButtonSegment<T> s) => widget.selected.contains(s.value),
    )) {
      return false;
    }
    for (final ButtonSegment<T> s in widget.segments) {
      final Widget? label = s.label;
      if (label != null && (label is! Text || label.data == null)) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return SegmentedButton<T>(
        segments: widget.segments,
        selected: widget.selected,
        onSelectionChanged: widget.onSelectionChanged,
        multiSelectionEnabled: widget.multiSelectionEnabled,
        emptySelectionAllowed: widget.emptySelectionAllowed,
        expandedInsets: widget.expandedInsets,
        style: widget.style,
        showSelectedIcon: widget.showSelectedIcon,
        selectedIcon: widget.selectedIcon,
        direction: widget.direction,
      );
    }
    final Widget glass = _fitsSegmentedControl
        ? _buildSegmentedControl(context)
        : _buildButtonRow(context);
    return _enabled ? glass : _glassDisabled(glass);
  }

  Widget _buildSegmentedControl(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final TextStyle base = theme.textTheme.labelLarge ?? const TextStyle();
    final TextStyle selectedStyle = base.copyWith(
      color: cs.onSecondaryContainer,
      fontWeight: FontWeight.w600,
    );
    final TextStyle unselectedStyle = base.copyWith(color: cs.onSurface);
    final List<ButtonSegment<T>> segments = widget.segments;
    final int selectedIndex = segments.indexWhere(
      (ButtonSegment<T> s) => widget.selected.contains(s.value),
    );
    bool stacked = false;
    double widest = 0;
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextDirection textDirection = Directionality.of(context);
    final List<GlassSegment> glassSegments = <GlassSegment>[];
    for (final ButtonSegment<T> s in segments) {
      final String? text = (s.label as Text?)?.data;
      double w = 0;
      if (text != null) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: text, style: selectedStyle),
          textDirection: textDirection,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        w = painter.width;
        painter.dispose();
      }
      if (s.icon != null) {
        if (text != null) stacked = true;
        w = w < 24 ? 24 : w;
      }
      if (w > widest) widest = w;
      glassSegments.add(
        GlassSegment(
          icon: s.icon,
          label: text,
          tooltip: s.tooltip,
          enabled: s.enabled,
        ),
      );
    }
    // 与 Material 一样按内容取宽（等宽段）；有 expandedInsets 时撑满。
    final double intrinsic = segments.length * (widest + 32) + 4;
    final Widget control = GlassSegmentedControl(
      segments: glassSegments,
      selectedIndex: selectedIndex,
      onSegmentSelected: (int index) => _handlePressed(segments[index].value),
      height: stacked ? 54 : 40,
      selectedTextStyle: selectedStyle,
      unselectedTextStyle: unselectedStyle,
      backgroundColor: fushiGlassFill(context),
      indicatorColor: cs.secondaryContainer,
      glowColor: cs.primary,
      quality: fushiGlassQuality(context),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool bounded = constraints.maxWidth.isFinite;
        if (widget.expandedInsets != null && bounded) {
          return Padding(padding: widget.expandedInsets!, child: control);
        }
        final double width = bounded && intrinsic > constraints.maxWidth
            ? constraints.maxWidth
            : intrinsic;
        return SizedBox(width: width, child: control);
      },
    );
  }

  Widget _buildButtonRow(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool expanded = widget.expandedInsets != null;
    final List<Widget> children = <Widget>[
      for (final ButtonSegment<T> s in widget.segments)
        _segmentButton(context, cs, theme, s),
    ];
    Widget row = Flex(
      direction: widget.direction,
      mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
      spacing: 6,
      children: expanded
          ? <Widget>[for (final Widget c in children) Expanded(child: c)]
          : children,
    );
    if (expanded) row = Padding(padding: widget.expandedInsets!, child: row);
    return row;
  }

  Widget _segmentButton(
    BuildContext context,
    ColorScheme cs,
    ThemeData theme,
    ButtonSegment<T> s,
  ) {
    final bool selected = widget.selected.contains(s.value);
    final bool enabled = _enabled && s.enabled;
    final Color fg = !enabled
        ? cs.onSurface.withValues(alpha: 0.38)
        : (selected ? cs.onSecondaryContainer : cs.onSurface);
    final Widget? icon = selected && widget.showSelectedIcon
        ? (widget.selectedIcon ?? const Icon(Icons.check))
        : (s.label != null ? s.icon : null);
    final Widget label = s.label ?? s.icon ?? const SizedBox.shrink();
    final Widget content = IconTheme.merge(
      data: IconThemeData(color: fg, size: 18),
      child: DefaultTextStyle.merge(
        style: (theme.textTheme.labelLarge ?? const TextStyle()).copyWith(
          color: fg,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[icon, const SizedBox(width: 6)],
              Flexible(child: label),
            ],
          ),
        ),
      ),
    );
    final String? text = s.label is Text ? (s.label as Text).data : null;
    Widget button = GlassButton.custom(
      onTap: () => _handlePressed(s.value),
      enabled: enabled,
      style: selected ? GlassButtonStyle.filled : GlassButtonStyle.transparent,
      settings: selected
          ? fushiGlassSettings(context, tint: cs.secondaryContainer)
          : null,
      quality: fushiGlassQuality(context),
      shape: const LiquidRoundedSuperellipse(borderRadius: 20),
      label: text ?? s.tooltip ?? '',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 40),
        child: Center(widthFactor: 1, heightFactor: 1, child: content),
      ),
    );
    button = Semantics(selected: selected, child: button);
    if (s.tooltip != null) {
      button = Tooltip(message: s.tooltip, child: button);
    }
    return button;
  }
}
