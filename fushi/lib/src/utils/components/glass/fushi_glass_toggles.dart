import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 选择类控件（开关 / 滑块 / 复选 / 单选 / 列表行变体 / 分段按钮）的「设计系统
// 分派」包装：构造参数与 Material 原控件逐个同名同型（含同名命名构造器），调用
// 点只改类名。MD3 设计系统下原样构造原控件并转发全部参数（像素、焦点、语义
// 一字不差）；「玻璃」设计系统下按 iOS 26 的控件形态渲染：
//
// - Switch → [FushiAppleSwitch]（自绘经典 iOS 开关：iOS 51×31 / macOS 38×22
//   全胶囊轨，开 = 强调色轨 + onAccent 圆钮、关 = systemFill 灰轨 + 白钮，弹簧
//   过渡）；Slider → [FushiAppleSlider]（自绘 4px 细轨 + 白色正圆钮，键位与
//   Material Slider 同：←/→ 恒调值，传统导航模式下 ↑/↓ 也调值）；
// - Checkbox → iOS 圆形勾选（强调色实心圆 + 白勾 / 灰色空心圈），Radio → 圆形
//   单选钮，支持 tristate 与 RadioGroup；都是内容层实色控件，不是玻璃；
// - RangeSlider → 与 [FushiAppleSlider] 同轨道 / 圆钮的区间版；
// - *ListTile → iOS 设置行（行高 44 起）+ 整行一个焦点停靠点（与 Material 同：
//   行内控件 ExcludeFocus，Enter / 手柄 A 经 ActivateIntent 切换）；单选行是
//   行尾强调色对勾；
// - SegmentedButton → iOS 分段（灰轨 + 白色滑块），单选能用
//   [FushiAppleSegmentedControl] 表达时用它，否则退回同形态的实色分段行。
//
// 颜色一律取 Apple 系统色（`appleColorsOf`）。

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

/// 复选框 / 单选钮的 Apple 指示器（**不是玻璃**，内容层控件），按平台档分两套：
///
/// 触屏（iOS）：
/// - 复选（[round] 为 false）= iOS 圆形勾选（22）：选中是强调色实心圆 +
///   onAccent `CupertinoIcons.checkmark`，未选中是 1.5px 的灰色空心圈
///   （tertiaryLabel），三态的「部分选中」画 onAccent 短横；
/// - 单选（[round] 为 true）= 同尺寸圆钮：选中强调色实心圆 + onAccent 圆点。
///   iOS 单选列表行不用它，走行尾对勾（见 [FushiRadioListTile]）。
///
/// 桌面（macOS）：见 [_macosCheckGlyph]——16 的圆角方框复选 / 圆形单选。
///
/// 前景一律是强调色的 onAccent（单色主题深色下强调色是白，勾就是黑）。
///
/// [onTap] 为 null 时是列表行里的纯展示控件（不可聚焦、不吃指针、不出语义——
/// 由整行承担）。
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
  final FushiAppleColors apple = appleColorsOf(context);
  final bool selected = value != false;
  final Set<WidgetState> states = <WidgetState>{
    if (selected) WidgetState.selected,
    if (!enabled) WidgetState.disabled,
    if (isError) WidgetState.error,
  };
  final Color tint = isError
      ? apple.destructive
      : (fillColor?.resolve(states) ?? activeColor ?? apple.accent);
  final Color mark = checkColor ?? appleOnAccent(tint);
  final bool desktop = _appleDesktopMetrics(context);
  final double size = (desktop ? 16 : 22) * scale;

  final Widget glyph = desktop
      ? _macosCheckGlyph(
          context,
          value: value,
          round: round,
          size: size,
          tint: tint,
          mark: mark,
          isError: isError,
        )
      : AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? tint : Colors.transparent,
            border: selected
                ? null
                : Border.all(
                    color: isError ? apple.destructive : apple.tertiaryLabel,
                    width: 1.5,
                  ),
          ),
          child: !selected
              ? null
              : Center(
                  child: round
                      ? Container(
                          width: size * 0.36,
                          height: size * 0.36,
                          decoration: BoxDecoration(
                            color: mark,
                            shape: BoxShape.circle,
                          ),
                        )
                      : value == null
                      ? Container(
                          width: size * 0.46,
                          height: 2.2 * scale,
                          decoration: BoxDecoration(
                            color: mark,
                            borderRadius: BorderRadius.circular(1.1 * scale),
                          ),
                        )
                      : FushiIcon(
                          CupertinoIcons.checkmark,
                          size: size * 0.62,
                          color: mark,
                        ),
                ),
        );

  if (onTap == null) {
    return ExcludeFocus(child: IgnorePointer(child: glyph));
  }
  final Widget box = Semantics(
    checked: value ?? false,
    mixed: value == null ? true : null,
    inMutuallyExclusiveGroup: round ? true : null,
    enabled: enabled,
    label: semanticLabel,
    child: _AppleToggleHit(
      enabled: enabled,
      onTap: onTap,
      focusNode: focusNode,
      autofocus: autofocus,
      ringRadius: size / 2 + 3,
      // macOS 方形复选框的焦点环跟着圆角矩形走；其余是圆形环。
      ringCornerRadius: desktop && !round ? 4 * scale + 3 : null,
      child: glyph,
    ),
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

/// macOS 的复选框 / 单选钮（16）：
/// - 复选 = 圆角 4 的方框；单选 = 正圆；
/// - 未选中：白底（深色 #3A3A3C）+ 0.5px separator 细边，浅色下带一丝落影
///   （macOS 控件凸起感）；
/// - 选中：强调色实底；复选画 onAccent 对勾 / 部分选中短横，单选画 6px
///   onAccent 圆点。
Widget _macosCheckGlyph(
  BuildContext context, {
  required bool? value,
  required bool round,
  required double size,
  required Color tint,
  required Color mark,
  required bool isError,
}) {
  final FushiAppleColors apple = appleColorsOf(context);
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  final bool selected = value != false;
  final double scale = size / 16;
  final BorderRadius? radius = round ? null : BorderRadius.circular(4 * scale);
  final Widget? inner = !selected
      ? null
      : round
      ? Container(
          width: 6 * scale,
          height: 6 * scale,
          decoration: BoxDecoration(color: mark, shape: BoxShape.circle),
        )
      : value == null
      ? Container(
          width: 8 * scale,
          height: 2 * scale,
          decoration: BoxDecoration(
            color: mark,
            borderRadius: BorderRadius.circular(1 * scale),
          ),
        )
      : FushiIcon(CupertinoIcons.checkmark, size: 12 * scale, color: mark);
  return AnimatedContainer(
    duration: const Duration(milliseconds: 120),
    curve: Curves.easeOut,
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: round ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: radius,
      color: selected
          ? tint
          : (dark ? const Color(0xFF3A3A3C) : const Color(0xFFFFFFFF)),
      border: selected
          ? null
          : Border.all(
              color: isError ? apple.destructive : apple.separator,
              width: isError ? 1 : 0.5,
            ),
      boxShadow: selected || dark
          ? null
          : const <BoxShadow>[
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 1,
                offset: Offset(0, 0.5),
              ),
            ],
    ),
    child: inner == null ? null : Center(child: inner),
  );
}

/// 复选 / 单选的可交互外壳：自带焦点节点（Tab 可达），[ActivateIntent]
/// （Enter / 手柄 A）与点击都触发 [onTap]，按下变淡，键盘焦点时外描一圈强调色
/// 焦点环（半径 [ringRadius]；给了 [ringCornerRadius] 时是该圆角的方环）。
class _AppleToggleHit extends StatefulWidget {
  const _AppleToggleHit({
    required this.enabled,
    required this.onTap,
    required this.focusNode,
    required this.autofocus,
    required this.ringRadius,
    required this.child,
    this.ringCornerRadius,
  });

  final bool enabled;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final bool autofocus;
  final double ringRadius;
  final double? ringCornerRadius;
  final Widget child;

  @override
  State<_AppleToggleHit> createState() => _AppleToggleHitState();
}

class _AppleToggleHitState extends State<_AppleToggleHit> {
  bool _pressed = false;
  bool _focusHighlight = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    Widget body = AnimatedOpacity(
      duration: _pressed ? Duration.zero : const Duration(milliseconds: 160),
      opacity: !widget.enabled ? 0.38 : (_pressed ? 0.6 : 1),
      child: widget.child,
    );
    if (_focusHighlight) {
      body = Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: <Widget>[
          body,
          IgnorePointer(
            child: Container(
              width: widget.ringRadius * 2,
              height: widget.ringRadius * 2,
              decoration: BoxDecoration(
                shape: widget.ringCornerRadius == null
                    ? BoxShape.circle
                    : BoxShape.rectangle,
                borderRadius: widget.ringCornerRadius == null
                    ? null
                    : BorderRadius.circular(widget.ringCornerRadius!),
                border: Border.all(color: apple.accent, width: 2),
              ),
            ),
          ),
        ],
      );
    }
    return FocusableActionDetector(
      enabled: widget.enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: widget.enabled
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            widget.onTap();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (bool value) {
        setState(() => _focusHighlight = value);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
        onTapUp: widget.enabled ? (_) => _setPressed(false) : null,
        onTapCancel: widget.enabled ? () => _setPressed(false) : null,
        onTap: widget.enabled ? widget.onTap : null,
        child: body,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Switch
// ---------------------------------------------------------------------------

/// MD3（M3 Expressive）开关默认带 thumb 图标：开 = 对勾、关 = 叉（关态圆钮
/// 由 16 撑到 24，按下 28，M3 位移曲线 easeOutBack 带回弹）。调用方显式给了
/// thumbIcon 的照用；墨水屏交回主题（只在开态画勾，保持以前的观感）。
WidgetStateProperty<Icon?>? _md3SwitchThumbIcon(BuildContext context) {
  if (isEinkTheme(context)) return null;
  return fushiExpressiveSwitchThumbIcon(Theme.of(context).colorScheme);
}

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
        thumbIcon: thumbIcon ?? _md3SwitchThumbIcon(context),
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
      thumbIcon: thumbIcon ?? _md3SwitchThumbIcon(context),
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
    final Size size = _appleSwitchSize(context);
    // 上下补到 Material 开关的布局高度（padded 48 / shrinkWrap 40），切换设计
    // 系统不跳行高；开关本体在其中垂直居中。
    final double target =
        (materialTapTargetSize ?? Theme.of(context).materialTapTargetSize) ==
            MaterialTapTargetSize.shrinkWrap
        ? 40
        : kMinInteractiveDimension;
    final double vertical = math.max(0, (target - size.height) / 2);
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
    // 紧约束（如被父级撑宽）下居中，而不是让手势区与画面错位。
    control = Center(widthFactor: 1, heightFactor: 1, child: control);
    if (!enabled) return _glassDisabled(control);
    return _glassFocusObserver(onFocusChange, control);
  }
}

/// 把 Material 的颜色参数折算成 [FushiAppleSwitch] 的参数（null = 走 Apple
/// 默认配色）。[onChanged] 为 null 时是纯展示（调用方负责禁用态）。
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
  return FushiAppleSwitch(
    value: value,
    onChanged: onChanged,
    focusNode: focusNode,
    autofocus: autofocus,
    activeTrackColor: activeTrackColor ?? trackColor?.resolve(_kSelectedStates),
    inactiveTrackColor: inactiveTrackColor ?? trackColor?.resolve(_kNoStates),
    activeThumbColor: thumbColor?.resolve(_kSelectedStates) ?? activeThumbColor,
    inactiveThumbColor: thumbColor?.resolve(_kNoStates) ?? inactiveThumbColor,
  );
}

/// Apple 控件的尺寸档：桌面（macOS / Windows / Linux）用 macOS 的紧凑尺寸，
/// 触屏平台用 iOS 尺寸。按 Theme 的 platform 判（与键盘步长同一判据，测试可
/// 覆写）。
bool _appleDesktopMetrics(BuildContext context) {
  return switch (Theme.of(context).platform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => false,
  };
}

/// 开关轨道尺寸：iOS 51×31、macOS 38×22（全胶囊）。
Size _appleSwitchSize(BuildContext context) =>
    _appleDesktopMetrics(context) ? const Size(38, 22) : const Size(51, 31);

/// 开关 / 滑块圆钮按下时是否换成液态玻璃透镜：**恒 false**——圆钮一律是实色
/// 胶囊 / 正圆，按下时朝行进方向拉长（经典 iOS 按压反馈）。
///
/// 透镜（premium [GlassContainer]）在 Impeller 上会带出一圈高光描边、在深色
/// 底上发白成团，Skia 上又根本不走（液态被降成磨砂档），同一个控件两端两种
/// 样子；分段控件的同类透镜已经因为「不透明白胶囊盖住文字」被用户点名
/// （2026-10-05 Windows + Mac 截图）。稳定观感优先，透镜整体关掉；判据留成
/// 函数，日后有不出白圈的透镜参数再在这里按材质放开。
bool _appleLensAllowed(BuildContext context) => false;

/// 透镜放大 / 回弹的时长（减少动态效果时瞬变）。
Duration _appleLensDuration(BuildContext context) =>
    (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
    ? Duration.zero
    : const Duration(milliseconds: 260);

/// 透镜的弹簧感节拍：略冲过头再落定（GlassSwitch / GlassSlider 同感）。
const Curve _kAppleLensCurve = Cubic(0.3, 1.35, 0.55, 1);

/// 透镜玻璃参数：近乎无色的厚透镜，不模糊、只折射放大（照库里 GlassSwitch /
/// GlassSlider 圆钮的透镜调参），光照沿用 [fushiGlassSettings] 的 iOS 26
/// 实测档（深色关 fresnel / 环境光）。
LiquidGlassSettings _appleLensSettings(BuildContext context) {
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  final LiquidGlassSettings base = fushiGlassSettings(context);
  return LiquidGlassSettings(
    glassColor: dark
        ? const Color(0x14FFFFFF)
        : const Color.from(alpha: 0.12, red: 0.88, green: 0.88, blue: 0.90),
    blur: 0,
    thickness: dark ? 10 : 14,
    refractiveIndex: dark ? 1.12 : 1.22,
    lightIntensity: base.lightIntensity,
    ambientStrength: base.ambientStrength,
    fresnelStrength: base.fresnelStrength,
    chromaticAberration: base.chromaticAberration,
    saturation: base.saturation,
    shadowElevation: 0,
  );
}

/// iOS 26 圆钮：[lens] = 0 是实色胶囊 / 正圆（[color] + 投影）；向 1 过渡时
/// 实色淡出、液态玻璃透镜（[GlassContainer]，premium 档、自带图层）浮现，
/// 透出并放大下方轨道。尺寸由父级给（放大由调用方算）。
class _AppleLensThumb extends StatelessWidget {
  const _AppleLensThumb({
    required this.color,
    required this.shadow,
    required this.lens,
  });

  final Color color;
  final List<BoxShadow> shadow;
  final double lens;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double w = constraints.maxWidth;
        final double h = constraints.maxHeight;
        final bool round = (w - h).abs() < 0.5;
        // 实色体：Opacity 而不是改颜色 alpha——Impeller 下整层移出合成树，
        // 透镜的折射才透得出来（库里 GlassSwitch 同法）。
        final Widget solid = Opacity(
          opacity: (1 - lens * 1.2).clamp(0.0, 1.0),
          child: Container(
            width: w,
            height: h,
            decoration: round
                ? BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    boxShadow: shadow,
                  )
                : BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(h / 2),
                    boxShadow: shadow,
                  ),
          ),
        );
        if (lens < 0.02) return solid;
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              child: GlassContainer(
                useOwnLayer: true,
                quality: GlassQuality.premium,
                shape: LiquidRoundedRectangle(borderRadius: h / 2),
                settings: _appleLensSettings(context),
                child: const SizedBox.expand(),
              ),
            ),
            solid,
          ],
        );
      },
    );
  }
}

/// 开关 / 滑块圆钮的柔和投影：iOS 是大而淡的落影，macOS 尺寸小、落影收紧。
List<BoxShadow> _appleKnobShadow(bool desktop) {
  return desktop
      ? const <BoxShadow>[
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 2.5,
            offset: Offset(0, 1),
          ),
          BoxShadow(color: Color(0x14000000), blurRadius: 0.5),
        ]
      : const <BoxShadow>[
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 1,
            offset: Offset(0, 1),
          ),
        ];
}

/// Apple 设计系统下 [FushiSwitch] 与开关列表行的开关（**不是玻璃**，内容层
/// 控件）。
///
/// 自绘而不用库的 [GlassSwitch]：库的 iOS 26 开关圆钮是比例写死的横向胶囊，
/// 而这里的规格是经典 iOS 开关——全胶囊轨（触屏 51×31 / 桌面 38×22）+ 正圆钮
/// （轨高 − 4）带柔和投影，开关时弹簧过渡（略有回弹）。
///
/// 配色（用户拍板）：开 = 强调色轨道 + 强调色前景色（onAccent）圆钮——深色
/// 强调色上是白钮；默认单色主题深色下强调色是白，圆钮就成黑，不会白钮压白轨
/// 看不出开关状态。关 = systemFill 灰轨 + 白钮。Material 颜色参数显式给了就用
/// 显式值（开态圆钮默认仍按实际轨道色取前景色）。
///
/// 交互：点击 / 横拖圆钮 / 焦点 + Enter（[ActivateIntent]；App 把裸空格中和
/// 了）切换；按下时圆钮朝行进方向拉长（iOS 的按压反馈）；键盘焦点时外描一圈
/// 强调色焦点环。[onChanged] 为 null 时是纯展示：不可聚焦、不吃手势。
class FushiAppleSwitch extends StatefulWidget {
  const FushiAppleSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.focusNode,
    this.autofocus = false,
    this.activeTrackColor,
    this.inactiveTrackColor,
    this.activeThumbColor,
    this.inactiveThumbColor,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final FocusNode? focusNode;
  final bool autofocus;
  final Color? activeTrackColor;
  final Color? inactiveTrackColor;
  final Color? activeThumbColor;
  final Color? inactiveThumbColor;

  @override
  State<FushiAppleSwitch> createState() => _FushiAppleSwitchState();
}

class _FushiAppleSwitchState extends State<FushiAppleSwitch>
    with SingleTickerProviderStateMixin {
  static const double _inset = 2;

  /// iOS 开关的弹簧：阻尼比 < 1 留一点回弹，约 0.3 秒落定。
  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 520,
    ratio: 0.72,
  );

  // 无界：弹簧回弹会略越过 0 / 1，有界控制器会把回弹削平。
  late final AnimationController _position = AnimationController.unbounded(
    vsync: this,
    value: widget.value ? 1 : 0,
  );
  bool _pressed = false;
  bool _dragging = false;
  bool _focusHighlight = false;

  @override
  void didUpdateWidget(FushiAppleSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_dragging) {
      _animateTo(widget.value);
    }
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  void _animateTo(bool on) {
    final double target = on ? 1 : 0;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _position.value = target;
      return;
    }
    _position.animateWith(
      SpringSimulation(_spring, _position.value, target, _position.velocity),
    );
  }

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  void _toggle() {
    widget.onChanged?.call(!widget.value);
  }

  /// 拖动 / 甩动结束：提交 [next]；父级不接受新值（不重建）时弹回真实值。
  /// 弹簧动画本身在出帧，所以帧后回调一定会跑到。
  void _settle(bool next) {
    if (next != widget.value) widget.onChanged?.call(next);
    _animateTo(next);
    SchedulerBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && !_dragging && widget.value != next) {
        _animateTo(widget.value);
      }
    });
  }

  void _onDragStart(DragStartDetails details) {
    _dragging = true;
    _position.stop();
    _setPressed(true);
  }

  void _onDragUpdate(DragUpdateDetails details, double travel, bool rtl) {
    if (travel <= 0) return;
    final double dx = rtl ? -details.delta.dx : details.delta.dx;
    _position.value = (_position.value + dx / travel).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details, bool rtl) {
    _dragging = false;
    _setPressed(false);
    double velocity = details.primaryVelocity ?? 0;
    if (rtl) velocity = -velocity;
    final bool next = velocity.abs() > 300
        ? velocity > 0
        : _position.value >= 0.5;
    _settle(next);
  }

  void _onDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    _setPressed(false);
    _animateTo(widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool desktop = _appleDesktopMetrics(context);
    final Size size = _appleSwitchSize(context);
    final double thumb = size.height - _inset * 2;
    final double travel = size.width - _inset * 2 - thumb;
    // 按下 / 拖动：液态玻璃档下圆钮横向放大成玻璃透镜（≈1.4×、略高出轨道），
    // 透出并放大下方轨道；降低透明度 / 减少动态效果时退回实色圆钮朝行进方向
    // 拉长（经典 iOS 按压反馈）。
    final bool lensAllowed = _appleLensAllowed(context);
    final double stretch = lensAllowed
        ? thumb * 0.4
        : thumb * (desktop ? 0.2 : 0.26);
    final double lift = lensAllowed ? thumb * 0.14 : 0;
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    final bool enabled = widget.onChanged != null;
    final Color activeTrack = widget.activeTrackColor ?? apple.accent;
    final Color inactiveTrack = widget.inactiveTrackColor ?? apple.fill;
    final Color onThumb = widget.activeThumbColor ?? appleOnAccent(activeTrack);
    final Color offThumb = widget.inactiveThumbColor ?? Colors.white;
    final List<BoxShadow> shadow = _appleKnobShadow(desktop);

    final Widget visual = TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _pressed ? 1 : 0),
      duration: _appleLensDuration(context),
      // 弹簧感：放大与回弹都略冲过头再落定。
      curve: _kAppleLensCurve,
      builder: (BuildContext context, double lens, Widget? _) {
        final double grow = stretch * lens;
        final double rise = lift * lens;
        return AnimatedBuilder(
          animation: _position,
          builder: (BuildContext context, Widget? _) {
            final double p = _position.value;
            final double t = p.clamp(0.0, 1.0);
            // 拉长朝行进方向：关态向右伸、开态向左伸，外沿始终贴着轨道内边。
            // 透镜态以圆钮中心为锚横向长开（会略越出轨道，iOS 26 同）。
            double left = lensAllowed
                ? _inset + travel * p + thumb / 2 - (thumb + grow) / 2
                : _inset + travel * p - grow * t;
            if (rtl) left = size.width - left - (thumb + grow);
            return SizedBox(
              width: size.width,
              height: size.height,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color.lerp(inactiveTrack, activeTrack, t),
                        borderRadius: BorderRadius.circular(size.height / 2),
                      ),
                    ),
                  ),
                  Positioned(
                    left: left,
                    top: _inset - rise,
                    width: thumb + grow,
                    height: thumb + rise * 2,
                    child: _AppleLensThumb(
                      color: Color.lerp(offThumb, onThumb, t)!,
                      shadow: shadow,
                      lens: lensAllowed ? lens : 0,
                    ),
                  ),
                  if (_focusHighlight)
                    Positioned(
                      left: -3,
                      top: -3,
                      right: -3,
                      bottom: -3,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              size.height / 2 + 3,
                            ),
                            border: Border.all(color: apple.accent, width: 2),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );

    return Semantics(
      container: true,
      toggled: widget.value,
      enabled: enabled,
      onTap: enabled ? _toggle : null,
      child: FocusableActionDetector(
        enabled: enabled,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent intent) {
              _toggle();
              return null;
            },
          ),
        },
        onShowFocusHighlight: (bool value) {
          setState(() => _focusHighlight = value);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTapDown: enabled ? (_) => _setPressed(true) : null,
          onTapUp: enabled ? (_) => _setPressed(false) : null,
          onTapCancel: enabled
              ? () {
                  if (!_dragging) _setPressed(false);
                }
              : null,
          onTap: enabled ? _toggle : null,
          onHorizontalDragStart: enabled ? _onDragStart : null,
          onHorizontalDragUpdate: enabled
              ? (DragUpdateDetails d) => _onDragUpdate(d, travel, rtl)
              : null,
          onHorizontalDragEnd: enabled
              ? (DragEndDetails d) => _onDragEnd(d, rtl)
              : null,
          onHorizontalDragCancel: enabled ? _onDragCancel : null,
          child: visual,
        ),
      ),
    );
  }
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
    this.ticks = const <double>[],
    this.size,
    this.axis = Axis.horizontal,
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
    this.ticks = const <double>[],
    this.size,
    this.axis = Axis.horizontal,
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

  /// 轨道上的竖线刻度（量程内的分数 0~1，例如全书进度条的章首）。只有 Apple
  /// 设计系统读——MD3 的刻度由调用方经 [SliderTheme] 的 trackShape 画。
  final List<double> ticks;

  /// M3 Expressive 滑块尺寸档（轨道 16 / 24 / 40 / 56 / 96，竖条把手随之加高，
  /// 只影响 MD3）。null = 主题默认（XS，16 粗轨道）。
  final FushiSliderSize? size;

  /// [Axis.vertical] = 竖直滑块（M3 Expressive vertical slider）：底端为
  /// [min]、顶端为 [max]，方向键上 / 右增大、下 / 左减小（Material 滑块本身
  /// 对上下键就是增减）。竖直时不弹数值气泡（气泡会随旋转横躺）。
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final Widget slider = isGlassDesign(context)
        ? _buildGlass(context)
        : _buildMd3(context);
    if (axis == Axis.horizontal) return slider;
    // 竖直：整体逆时针转 90°，布局尺寸随之互换（RotatedBox 参与布局）。
    return RotatedBox(quarterTurns: 3, child: slider);
  }

  Widget _buildMd3(BuildContext context) {
    final FushiSliderSize? sliderSize = size;
    final ShowValueIndicator? valueIndicator = axis == Axis.vertical
        ? ShowValueIndicator.never
        : showValueIndicator;
    Widget slider = _buildMd3Slider(valueIndicator);
    if (sliderSize != null && !isEinkTheme(context)) {
      slider = SliderTheme(
        data: fushiSliderSizeTheme(SliderTheme.of(context), sliderSize),
        child: slider,
      );
    }
    // 竖直：Material Slider 在有界高度下会吃满父级给的最大高度，旋转后就成了
    // 横向吃满父级宽度的一大块（命中区与布局都按整宽算）。按 Slider 自己的固有
    // 高度（轨道 / 把手 / 光晕里最高的那个）定厚度，旋转后才是一根竖条
    // （BUG-3047）。Apple 分支自带定高，不需要。
    if (axis == Axis.vertical) slider = IntrinsicHeight(child: slider);
    return slider;
  }

  Widget _buildMd3Slider(ShowValueIndicator? showValueIndicator) {
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
    Widget slider = FushiAppleSlider(
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
      semanticFormatterCallback: semanticFormatterCallback,
      focusNode: focusNode,
      autofocus: autofocus,
      ticks: ticks,
    );
    if (padding != null) slider = Padding(padding: padding!, child: slider);
    return onChanged == null ? _glassDisabled(slider) : slider;
  }
}

/// Apple 滑块几何：轨道粗细、圆钮直径、控件高度。iOS 4 / 28 / 44（44 是 iOS
/// 最小点击高度）；macOS 4 / 20 / 36。
typedef _AppleSliderMetrics = ({double track, double thumb, double height});

_AppleSliderMetrics _appleSliderMetrics(BuildContext context) {
  return _appleDesktopMetrics(context)
      ? (track: 4, thumb: 20, height: 36)
      : (track: 4, thumb: 28, height: 44);
}

/// 滑块轨道（单值与区间共用）：整条未填段 + 已填段 + 可选的次级段 + 离散刻度。
/// 所有分数都是**视觉坐标**（0 = 左端，已按 RTL 翻转），轨道两端各内缩
/// [inset]（圆钮半径），与圆钮中心的行程一致。
class _AppleSliderTrackPainter extends CustomPainter {
  const _AppleSliderTrackPainter({
    required this.inset,
    required this.trackHeight,
    required this.activeStart,
    required this.activeEnd,
    required this.secondaryStart,
    required this.secondaryEnd,
    required this.divisions,
    required this.inactiveColor,
    required this.activeColor,
    required this.secondaryColor,
    required this.activeTickColor,
    required this.inactiveTickColor,
    this.marks = const <double>[],
    this.markColor = const Color(0x00000000),
  });

  /// 额外的竖线刻度（视觉坐标 0~1，例如有声书全书进度条上的章首），画在
  /// 轨道上方、上下各伸出 3px。
  final List<double> marks;
  final Color markColor;

  final double inset;
  final double trackHeight;
  final double activeStart;
  final double activeEnd;
  final double? secondaryStart;
  final double? secondaryEnd;
  final int? divisions;
  final Color inactiveColor;
  final Color activeColor;
  final Color secondaryColor;
  final Color activeTickColor;
  final Color inactiveTickColor;

  @override
  void paint(Canvas canvas, Size size) {
    final double usable = size.width - inset * 2;
    if (usable <= 0) return;
    final double cy = size.height / 2;
    final Radius radius = Radius.circular(trackHeight / 2);
    RRect segment(double a, double b) => RRect.fromRectAndRadius(
      Rect.fromLTRB(
        inset + usable * a,
        cy - trackHeight / 2,
        inset + usable * b,
        cy + trackHeight / 2,
      ),
      radius,
    );
    canvas.drawRRect(segment(0, 1), Paint()..color = inactiveColor);
    final double? s0 = secondaryStart;
    final double? s1 = secondaryEnd;
    if (s0 != null && s1 != null && s1 > s0) {
      canvas.drawRRect(segment(s0, s1), Paint()..color = secondaryColor);
    }
    if (activeEnd > activeStart) {
      canvas.drawRRect(
        segment(activeStart, activeEnd),
        Paint()..color = activeColor,
      );
    }
    // 离散刻度极淡：轨道中线上的 2px 小点，格距不足 8px 时不画（一串点比没
    // 有更乱）。
    final int? div = divisions;
    if (div != null && div > 0 && usable / div >= 8) {
      final Paint active = Paint()..color = activeTickColor;
      final Paint inactive = Paint()..color = inactiveTickColor;
      for (int i = 0; i <= div; i++) {
        final double f = i / div;
        final bool inActive = f >= activeStart - 1e-9 && f <= activeEnd + 1e-9;
        canvas.drawCircle(
          Offset(inset + usable * f, cy),
          trackHeight / 4,
          inActive ? active : inactive,
        );
      }
    }
    if (marks.isNotEmpty) {
      final Paint mark = Paint()
        ..color = markColor
        ..strokeWidth = 1.5;
      final double half = trackHeight / 2 + 3;
      for (final double f in marks) {
        final double x = inset + usable * f.clamp(0.0, 1.0);
        canvas.drawLine(Offset(x, cy - half), Offset(x, cy + half), mark);
      }
    }
  }

  @override
  bool shouldRepaint(_AppleSliderTrackPainter oldDelegate) {
    return oldDelegate.inset != inset ||
        oldDelegate.trackHeight != trackHeight ||
        oldDelegate.activeStart != activeStart ||
        oldDelegate.activeEnd != activeEnd ||
        oldDelegate.secondaryStart != secondaryStart ||
        oldDelegate.secondaryEnd != secondaryEnd ||
        oldDelegate.divisions != divisions ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.secondaryColor != secondaryColor ||
        oldDelegate.activeTickColor != activeTickColor ||
        oldDelegate.inactiveTickColor != inactiveTickColor ||
        oldDelegate.markColor != markColor ||
        !listEquals(oldDelegate.marks, marks);
  }
}

/// 滑块圆钮：静止是正圆（默认白）+ 柔和投影；拖动时（[active]）液态玻璃档下
/// 放大约 1.3× 成玻璃透镜、透出并放大下方轨道，松手弹回实色——iOS 26 滑块；
/// 降低透明度 / 减少动态效果时只是实色圆钮微微放大。键盘焦点时外描一圈强调色
/// 焦点环。深色下仍是白钮——它压在细轨上、四周是页面底色，与白色已填段只在
/// 中心 4px 处相接，不存在撞色。
Widget _appleSliderKnob({
  required double size,
  required Color color,
  required bool desktop,
  required bool focused,
  required bool active,
  required Color ringColor,
}) {
  return Builder(
    builder: (BuildContext context) {
      final bool lensAllowed = _appleLensAllowed(context);
      return TweenAnimationBuilder<double>(
        tween: Tween<double>(end: active ? 1 : 0),
        duration: _appleLensDuration(context),
        curve: _kAppleLensCurve,
        builder: (BuildContext context, double lens, Widget? _) {
          final double d = size * (1 + (lensAllowed ? 0.3 : 0.08) * lens);
          final double offset = (size - d) / 2;
          return Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              SizedBox.square(dimension: size),
              Positioned(
                left: offset,
                top: offset,
                width: d,
                height: d,
                child: _AppleLensThumb(
                  color: color,
                  shadow: _appleKnobShadow(desktop),
                  lens: lensAllowed ? lens : 0,
                ),
              ),
              if (focused)
                Positioned(
                  left: -3,
                  top: -3,
                  right: -3,
                  bottom: -3,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: ringColor, width: 2),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    },
  );
}

/// 滑块数值气泡（[Slider.label] / [RangeSlider.labels]）：拖动或键盘聚焦时浮在
/// 圆钮上方的小圆角气泡。
Widget _appleSliderLabel(BuildContext context, String label) {
  final FushiAppleColors apple = appleColorsOf(context);
  return DecoratedBox(
    decoration: BoxDecoration(
      color: apple.tertiaryGroupedBackground,
      borderRadius: BorderRadius.circular(8),
      boxShadow: const <BoxShadow>[
        BoxShadow(
          color: Color(0x24000000),
          blurRadius: 6,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        label,
        maxLines: 1,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: apple.label,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    ),
  );
}

/// 离散化：有 divisions 时吸附到最近一格。
double _appleDiscretize(double v, double min, double max, int? divisions) {
  final double range = max - min;
  final double clamped = range > 0 ? v.clamp(min, max).toDouble() : min;
  if (divisions == null || divisions <= 0 || range <= 0) return clamped;
  final double steps = ((clamped - min) / range * divisions).roundToDouble();
  return min + steps / divisions * range;
}

/// 语义数值：有格式化回调用它，否则按 Material 的百分比口径。
String _appleSemanticValue(
  double v,
  double min,
  double max,
  SemanticFormatterCallback? format,
) {
  if (format != null) return format(v);
  final double range = max - min;
  if (range <= 0) return '0%';
  return '${((v - min) / range * 100).round()}%';
}

/// Apple 设计系统下的 [FushiSlider]（**不是玻璃**，内容层控件）。
///
/// 自绘而不用库的 [GlassSlider]：库的 iOS 26 圆钮是横向胶囊、拖动变玻璃，
/// 这里的规格是 iOS 滑块——4px 细轨（已填段强调色、未填段 systemFill）+ 白色
/// 正圆钮带柔和投影（触屏 28 / 桌面 20），离散刻度是极淡的小点。
///
/// 交互与 Material Slider 对齐：点轨道跳值、横拖跟手（各自成对发
/// onChangeStart / onChangeEnd）；自带焦点停靠点，←/→（传统导航模式下 ↑/↓
/// 也）按一格 / 量程 10%（Apple）调值；语义 increase / decrease 同步长。
class FushiAppleSlider extends StatefulWidget {
  const FushiAppleSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.secondaryTrackValue,
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
    this.semanticFormatterCallback,
    this.focusNode,
    this.autofocus = false,
    this.ticks = const <double>[],
  });

  /// 轨道上的竖线刻度（量程内分数 0~1，见 [FushiSlider.ticks]）。
  final List<double> ticks;

  final double value;
  final ValueChanged<double>? onChanged;
  final double? secondaryTrackValue;
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
  final SemanticFormatterCallback? semanticFormatterCallback;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<FushiAppleSlider> createState() => _FushiAppleSliderState();
}

class _FushiAppleSliderState extends State<FushiAppleSlider> {
  FocusNode? _ownNode;
  bool _focused = false;
  bool _dragging = false;
  double _width = 0;
  double _thumbSize = 28;
  late double _latest = _clamped(widget.value);

  FocusNode get _node =>
      widget.focusNode ?? (_ownNode ??= FocusNode(debugLabel: 'FushiSlider'));

  @override
  void didUpdateWidget(FushiAppleSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    _latest = _clamped(widget.value);
  }

  @override
  void dispose() {
    _ownNode?.dispose();
    super.dispose();
  }

  bool get _enabled => widget.onChanged != null;

  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  double get _range => widget.max - widget.min;

  double _clamped(double v) =>
      _range > 0 ? v.clamp(widget.min, widget.max).toDouble() : widget.min;

  /// 值在轨道上的逻辑分数（0 = min，未按 RTL 翻转）。
  double _fraction(double v) {
    if (_range <= 0) return 0;
    return ((v - widget.min) / _range).clamp(0.0, 1.0).toDouble();
  }

  double _discretize(double v) =>
      _appleDiscretize(v, widget.min, widget.max, widget.divisions);

  double _valueAt(double dx) {
    final double usable = _width - _thumbSize;
    if (usable <= 0) return widget.min;
    double t = ((dx - _thumbSize / 2) / usable).clamp(0.0, 1.0).toDouble();
    if (_rtl) t = 1 - t;
    return _discretize(widget.min + t * _range);
  }

  void _emit(double v) {
    if (v == _latest) return;
    _latest = v;
    widget.onChanged?.call(v);
  }

  double get _step =>
      _sliderKeyStep(context, widget.min, widget.max, widget.divisions);

  /// 键盘 / 语义单步调值：与 Material 同，每步独立成对发 start / end。
  void _adjust(int dir) {
    if (!_enabled) return;
    final double current = _latest;
    final double next = _clamped(_discretize(current + dir * _step));
    widget.onChangeStart?.call(current);
    _emit(next);
    widget.onChangeEnd?.call(next);
  }

  void _onTapUp(TapUpDetails details) {
    widget.onChangeStart?.call(_latest);
    _emit(_valueAt(details.localPosition.dx));
    widget.onChangeEnd?.call(_latest);
  }

  void _onDragStart(DragStartDetails details) {
    setState(() => _dragging = true);
    widget.onChangeStart?.call(_latest);
    _emit(_valueAt(details.localPosition.dx));
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _emit(_valueAt(details.localPosition.dx));
  }

  void _onDragEnd() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onChangeEnd?.call(_latest);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool desktop = _appleDesktopMetrics(context);
    final _AppleSliderMetrics m = _appleSliderMetrics(context);
    _thumbSize = m.thumb;
    final Color active = widget.activeColor ?? apple.accent;
    final double? secondaryValue = widget.secondaryTrackValue;
    final String? label = widget.label;

    final Widget body = SizedBox(
      height: m.height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          _width = constraints.maxWidth.isFinite ? constraints.maxWidth : 144;
          final double usable = math.max(0, _width - m.thumb);
          final double f = _fraction(_latest);
          final double visual = _rtl ? 1 - f : f;
          double? s0;
          double? s1;
          if (secondaryValue != null) {
            final double sf = _fraction(secondaryValue);
            if (sf > f) {
              s0 = _rtl ? 1 - sf : f;
              s1 = _rtl ? 1 - f : sf;
            }
          }
          final double left = visual * usable;
          return SizedBox(
            width: _width,
            child: MouseRegion(
              cursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTapUp: _enabled ? _onTapUp : null,
                onHorizontalDragStart: _enabled ? _onDragStart : null,
                onHorizontalDragUpdate: _enabled ? _onDragUpdate : null,
                onHorizontalDragEnd: _enabled
                    ? (DragEndDetails _) => _onDragEnd()
                    : null,
                onHorizontalDragCancel: _enabled ? _onDragEnd : null,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _AppleSliderTrackPainter(
                          inset: m.thumb / 2,
                          trackHeight: m.track,
                          activeStart: _rtl ? visual : 0,
                          activeEnd: _rtl ? 1 : visual,
                          secondaryStart: s0,
                          secondaryEnd: s1,
                          divisions: widget.divisions,
                          inactiveColor: widget.inactiveColor ?? apple.fill,
                          activeColor: active,
                          secondaryColor:
                              widget.secondaryActiveColor ??
                              apple.tertiaryLabel,
                          activeTickColor: appleOnAccent(
                            active,
                          ).withValues(alpha: 0.4),
                          inactiveTickColor: apple.label.withValues(
                            alpha: 0.16,
                          ),
                          marks: <double>[
                            for (final double f in widget.ticks)
                              _rtl ? 1 - f : f,
                          ],
                          markColor: apple.secondaryLabel,
                        ),
                      ),
                    ),
                    Positioned(
                      left: left,
                      top: (m.height - m.thumb) / 2,
                      width: m.thumb,
                      height: m.thumb,
                      child: _appleSliderKnob(
                        size: m.thumb,
                        color: widget.thumbColor ?? Colors.white,
                        desktop: desktop,
                        focused: _focused,
                        active: _dragging,
                        ringColor: apple.accent,
                      ),
                    ),
                    if (label != null && (_focused || _dragging))
                      Positioned(
                        left: left + m.thumb / 2 - 80,
                        width: 160,
                        bottom: (m.height + m.thumb) / 2 + 4,
                        child: IgnorePointer(
                          child: Center(
                            child: _appleSliderLabel(context, label),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    final double step = _step;
    return Semantics(
      container: true,
      slider: true,
      enabled: _enabled,
      value: _appleSemanticValue(
        _latest,
        widget.min,
        widget.max,
        widget.semanticFormatterCallback,
      ),
      increasedValue: _appleSemanticValue(
        _clamped(_discretize(_latest + step)),
        widget.min,
        widget.max,
        widget.semanticFormatterCallback,
      ),
      decreasedValue: _appleSemanticValue(
        _clamped(_discretize(_latest - step)),
        widget.min,
        widget.max,
        widget.semanticFormatterCallback,
      ),
      onIncrease: _enabled ? () => _adjust(1) : null,
      onDecrease: _enabled ? () => _adjust(-1) : null,
      child: Focus(
        focusNode: _node,
        autofocus: widget.autofocus,
        canRequestFocus: _enabled,
        onFocusChange: (bool focused) => setState(() => _focused = focused),
        onKeyEvent: (FocusNode node, KeyEvent event) {
          final int dir = _sliderKeyDirection(context, event);
          if (dir == 0) return KeyEventResult.ignored;
          _adjust(dir);
          return KeyEventResult.handled;
        },
        child: body,
      ),
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
  // 几何随平台档变（iOS 28 / 44、macOS 20 / 36），每次 build 从
  // [_appleSliderMetrics] 刷新；手势换算读的是同一份。
  double _thumbSize = 28;
  double _height = 44;
  double _trackHeight = 4;

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

  double _discretize(double v) =>
      _appleDiscretize(v, widget.min, widget.max, widget.divisions);

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
    if (mounted) setState(() => _dragThumb = thumb);
    widget.onChangeStart?.call(_latest);
  }

  void _endInteraction() {
    // setState：松手后圆钮要从玻璃透镜弹回实色，不能等下一次外部重建。
    if (mounted) setState(() => _dragThumb = null);
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

  String _semanticValue(double v) => _appleSemanticValue(
    v,
    widget.min,
    widget.max,
    widget.semanticFormatterCallback,
  );

  Widget _thumb(int thumb, double left) {
    final FushiAppleColors apple = appleColorsOf(context);
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
              _appleSliderKnob(
                size: _thumbSize,
                color: Colors.white,
                desktop: _appleDesktopMetrics(context),
                focused: focused,
                active: _dragThumb == thumb,
                ringColor: apple.accent,
              ),
              if (label != null && (focused || _dragThumb == thumb))
                Positioned(
                  bottom: _thumbSize + 4,
                  left: -66,
                  right: -66,
                  child: IgnorePointer(
                    child: Center(child: _appleSliderLabel(context, label)),
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
    final FushiAppleColors apple = appleColorsOf(context);
    final _AppleSliderMetrics m = _appleSliderMetrics(context);
    _thumbSize = m.thumb;
    _height = m.height;
    _trackHeight = m.track;
    final Color active = widget.activeColor ?? apple.accent;
    return SizedBox(
      height: _height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          _width = constraints.maxWidth.isFinite ? constraints.maxWidth : 144;
          final double usable = math.max(0, _width - _thumbSize);
          final double fa = _fraction(_latest.start);
          final double fb = _fraction(_latest.end);
          final double a = fa * usable;
          final double b = fb * usable;
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
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _AppleSliderTrackPainter(
                        inset: _thumbSize / 2,
                        trackHeight: _trackHeight,
                        activeStart: math.min(fa, fb),
                        activeEnd: math.max(fa, fb),
                        secondaryStart: null,
                        secondaryEnd: null,
                        divisions: widget.divisions,
                        inactiveColor: widget.inactiveColor ?? apple.fill,
                        activeColor: active,
                        secondaryColor: apple.tertiaryLabel,
                        activeTickColor: appleOnAccent(
                          active,
                        ).withValues(alpha: 0.4),
                        inactiveTickColor: apple.label.withValues(alpha: 0.16),
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

/// iOS 单选列表行的行尾标记：选中 = 强调色 `CupertinoIcons.checkmark`，未选中
/// 留出同宽空位（行内文字不随选中跳动）。纯展示，焦点与语义由整行承担。
Widget _glassRadioCheckmark(
  BuildContext context, {
  required bool checked,
  required bool enabled,
  Color? color,
  double scale = 1.0,
}) {
  final FushiAppleColors apple = appleColorsOf(context);
  final double size = 20 * scale;
  return ExcludeFocus(
    child: IgnorePointer(
      child: SizedBox.square(
        dimension: size + 4,
        child: checked
            ? FushiIcon(
                CupertinoIcons.checkmark,
                size: size,
                color: enabled ? (color ?? apple.accent) : apple.tertiaryLabel,
              )
            : null,
      ),
    ),
  );
}

/// 玻璃下的「选择类列表行」：iOS 设置行（行高 44 起、label 色标题、
/// secondaryLabel 副标题，实色内容层，不是玻璃），[GlassListTile] 排版，整行是
/// 一个焦点停靠点（Enter / 手柄 A → ActivateIntent → [onTap]），行内 [control]
/// 只做展示。
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
    final FushiAppleColors apple = appleColorsOf(context);
    final TextTheme tt = theme.textTheme;
    final bool enabled = widget.enabled;
    final bool dense = widget.dense ?? false;
    // iOS 行的选中态不染标题（选中由行尾对勾 / 开关表达），禁用整行变灰。
    final Color titleColor = enabled ? apple.label : apple.tertiaryLabel;
    final Color subtitleColor = enabled
        ? apple.secondaryLabel
        : apple.tertiaryLabel;

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
        fontSize: 13,
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
          SizedBox(width: widget.horizontalTitleGap ?? 12),
          Expanded(child: body),
        ],
      );
    }
    // iOS 行高：单行 44，带副标题 58，三行 76。
    final double minHeight =
        widget.minTileHeight ??
        (dense || widget.subtitle == null
            ? 44
            : ((widget.isThreeLine ?? false) ? 76 : 58));
    body = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding:
            widget.contentPadding ??
            const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Align(alignment: AlignmentDirectional.centerStart, child: body),
      ),
    );

    final Color base =
        (widget.selected ? widget.selectedTileColor : widget.tileColor) ??
        Colors.transparent;
    final bool highlight = enabled && (_pressed || _hovered || _focused);
    // 按下 / 悬停 / 焦点是 iOS 行高亮的中性灰（systemFill），不是 MD3 的
    // onSurface 叠层。
    final Color overlay = widget.hoverColor ?? apple.tertiaryFill;
    final Color fill = highlight ? Color.alphaBlend(overlay, base) : base;
    final BorderSide ring = _focused
        ? BorderSide(color: apple.accent, width: 2)
        : BorderSide.none;
    final ShapeBorder shape = switch (widget.shape) {
      final OutlinedBorder outlined => outlined.copyWith(side: ring),
      final ShapeBorder other when !_focused => other,
      _ => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
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
      // macOS 复选框在文字前（调用方显式要求行尾时才放行尾）；iOS 按调用方
      // 显式要求，默认行尾。
      controlLeading: _appleDesktopMetrics(context)
          ? affinity != ListTileControlAffinity.trailing
          : affinity == ListTileControlAffinity.leading,
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
    final bool desktop = _appleDesktopMetrics(context);
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
      control: desktop
          ? _glassCheckIndicator(
              context,
              value: checked,
              enabled: isEnabled,
              onTap: null,
              round: true,
              fillColor: widget.fillColor,
              activeColor: widget.activeColor,
              scale: widget.radioScaleFactor,
            )
          : _glassRadioCheckmark(
              context,
              checked: checked,
              enabled: isEnabled,
              color:
                  widget.fillColor?.resolve(
                    checked ? _kSelectedStates : _kNoStates,
                  ) ??
                  widget.activeColor,
              scale: widget.radioScaleFactor,
            ),
      // macOS 单选组的圆钮在行首（调用方显式要求行尾时才放行尾）；iOS 单选
      // 列表行首不放控件，选中行行尾一个强调色对勾。
      controlLeading: desktop && affinity != ListTileControlAffinity.trailing,
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
        thumbIcon: thumbIcon ?? _md3SwitchThumbIcon(context),
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
      thumbIcon: thumbIcon ?? _md3SwitchThumbIcon(context),
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
    // 行内开关纯展示：焦点、手势、语义（toggled）都由整行承担，开关自己的
    // 语义节点排除掉，免得与行的 MergeSemantics 合出矛盾的 enabled 标志。
    Widget control = ExcludeFocus(
      child: IgnorePointer(
        child: ExcludeSemantics(
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
/// 玻璃下是 iOS / macOS 26 分段控件（无色透明玻璃轨 + 更亮的透明滑块，高
/// iOS 36 / macOS 30）：单选、不允许
/// 空选、横排、2–6 段且每段 label 为 null 或纯文本 [Text] 时用
/// [FushiAppleSegmentedControl]（滑块自绘在文字之下、可横拖，每段自带焦点 +
/// Enter 激活）；
/// 其余情形（多选、允许空选、竖排、段数越界、富文本 label）用同形态的实色
/// 分段行，按 [showSelectedIcon] 显示 SF 对勾。
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
  // 父级异步重建（例如先写偏好再 setState）之前同一次点击可能再通知一次
  // （分段的 tap 与拖动结束都会选），这里吞掉重复通知。
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

  /// 能否用 [FushiAppleSegmentedControl] 表达（否则退回玻璃按钮行）。
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
      // MD3 = M3 Expressive 连接式按钮组；墨水屏保留 Material 原件（主题里
      // 那套反色填充是为墨水屏选中段可辨认专门调过的，见 theme_notifier）。
      if (!isEinkTheme(context)) {
        return FushiConnectedButtonGroup<T>(
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
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    // iOS 26 分段控件 15 号 / macOS 26 13 号，选中段 semibold。
    final TextStyle base = (theme.textTheme.labelLarge ?? const TextStyle())
        .copyWith(fontSize: compact ? 13 : 15, letterSpacing: -0.1);
    // Niratan / macOS 26 参考（用户 2026-10-04）：选中段是更亮一点的无色透明
    // 玻璃 pill（不着强调色），字 label 色 semibold；未选段 secondaryLabel。
    final TextStyle selectedStyle = base.copyWith(
      color: apple.label,
      fontWeight: FontWeight.w600,
    );
    final TextStyle unselectedStyle = base.copyWith(
      color: apple.secondaryLabel,
      fontWeight: FontWeight.w500,
    );
    final List<ButtonSegment<T>> segments = widget.segments;
    final int selectedIndex = segments.indexWhere(
      (ButtonSegment<T> s) => widget.selected.contains(s.value),
    );
    bool stacked = false;
    double widest = 0;
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextDirection textDirection = Directionality.of(context);
    final List<FushiAppleSegmentData> appleSegments = <FushiAppleSegmentData>[];
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
        w = w < 20 ? 20 : w;
      }
      if (w > widest) widest = w;
      appleSegments.add(
        FushiAppleSegmentData(
          icon: s.icon,
          label: text,
          tooltip: s.tooltip,
          enabled: s.enabled,
        ),
      );
    }
    // 与 Material 一样按内容取宽（等宽段）；有 expandedInsets 时撑满。
    final double intrinsic = segments.length * (widest + 28) + 6;
    // iOS / macOS 26 分段控件：轨道是一枚无色透明玻璃胶囊（[_appleGlassTrack]，
    // 降低透明度时退回 systemFill 实色），选中滑块由 [FushiAppleSegmentedControl]
    // 自绘在文字**之下**（深色白 20% + 0.5 px 低透明内高光、浅色白 + 柔和投影）。
    // 高度：iOS 36、macOS 30（系统 regular 分段 28–32）；图标 + 文字叠排 50。
    final double height = stacked ? 50 : (compact ? 30 : 36);
    final bool solid = glassMaterialOf(context) == FushiGlassMaterial.off;
    final Widget control = FushiAppleSegmentedControl(
      segments: appleSegments,
      selectedIndex: selectedIndex,
      onSelected: _enabled
          ? (int index) => _handlePressed(segments[index].value)
          : null,
      height: height,
      iconSize: compact ? 15 : 17,
      selectedStyle: selectedStyle,
      unselectedStyle: unselectedStyle,
      solid: solid,
    );
    final Widget track = solid
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: apple.fill,
              borderRadius: BorderRadius.circular(height / 2),
            ),
            child: control,
          )
        : _appleGlassTrack(context, radius: height / 2, child: control);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool bounded = constraints.maxWidth.isFinite;
        if (widget.expandedInsets != null && bounded) {
          return Padding(padding: widget.expandedInsets!, child: track);
        }
        final double width = bounded && intrinsic > constraints.maxWidth
            ? constraints.maxWidth
            : intrinsic;
        return SizedBox(width: width, child: track);
      },
    );
  }

  /// 退回形态（多选 / 允许空选 / 竖排 / 富文本段）：与主形态同一套液态玻璃
  /// 语言——无色透明玻璃胶囊轨，选中段是更亮的透明 pill + label 字（降低透明度
  /// 下轨道 systemFill、选中段实色高一阶底）。
  Widget _buildButtonRow(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool expanded = widget.expandedInsets != null;
    final List<Widget> children = <Widget>[
      for (final ButtonSegment<T> s in widget.segments)
        _segmentButton(context, s),
    ];
    Widget row = Flex(
      direction: widget.direction,
      mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
      spacing: 2,
      children: expanded
          ? <Widget>[for (final Widget c in children) Expanded(child: c)]
          : children,
    );
    final double trackRadius = widget.direction == Axis.horizontal ? 999 : 12;
    row = Padding(padding: const EdgeInsets.all(3), child: row);
    row = glassMaterialOf(context) == FushiGlassMaterial.off
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: apple.fill,
              borderRadius: BorderRadius.circular(trackRadius),
            ),
            child: row,
          )
        : _appleGlassTrack(context, radius: trackRadius, child: row);
    if (expanded) row = Padding(padding: widget.expandedInsets!, child: row);
    return row;
  }

  Widget _segmentButton(BuildContext context, ButtonSegment<T> s) {
    final ThemeData theme = Theme.of(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final bool selected = widget.selected.contains(s.value);
    final bool enabled = _enabled && s.enabled;
    final Color fg = !enabled
        ? apple.tertiaryLabel
        : (selected ? apple.label : apple.secondaryLabel);
    final Widget? icon = selected && widget.showSelectedIcon
        ? (widget.selectedIcon ?? const FushiIcon(CupertinoIcons.checkmark))
        : (s.label != null ? s.icon : null);
    final Widget label = s.label ?? s.icon ?? const SizedBox.shrink();
    final Widget content = IconTheme.merge(
      data: IconThemeData(color: fg, size: 15),
      child: DefaultTextStyle.merge(
        style: (theme.textTheme.labelLarge ?? const TextStyle()).copyWith(
          fontSize: fushiAppleCompact(context) ? 13 : 15,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: fg,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[icon, const SizedBox(width: 4)],
              Flexible(child: label),
            ],
          ),
        ),
      ),
    );
    final String? text = s.label is Text ? (s.label as Text).data : null;
    Widget button = _AppleSegment(
      selected: selected,
      enabled: enabled,
      onTap: () => _handlePressed(s.value),
      thumbColor: glassMaterialOf(context) == FushiGlassMaterial.off
          ? apple.tertiaryGroupedBackground
          : _appleClearLensColor(context),
      semanticLabel: text ?? s.tooltip,
      child: content,
    );
    if (s.tooltip != null) {
      button = Tooltip(message: s.tooltip, child: button);
    }
    return button;
  }
}

/// [FushiAppleSegmentedControl] 的一段：文字 / 图标（可同时给，图标在上）。
class FushiAppleSegmentData {
  const FushiAppleSegmentData({
    this.label,
    this.icon,
    this.tooltip,
    this.enabled = true,
  });

  final String? label;
  final Widget? icon;
  final String? tooltip;
  final bool enabled;
}

/// Apple 设计系统的等宽分段控件（iOS / macOS 26 `UISegmentedControl` 形态）：
/// 选中滑块自绘、**永远在文字之下**，文字层在上。
///
/// 不再用库的 `GlassSegmentedControl`（用户 2026-10-05 Windows + Mac 截图）：
/// 它的选中滑块在按下 / 切换时换成 `GlassEffect` 透镜——Skia 上走 2D 指示器
/// 着色器（premium 参数 = 8 px 实色描边）、Impeller 上 premium 档第二遍透镜
/// 画在文字**之上**，两端都成了一颗盖住选中文字的不透明白胶囊，旁边还拖着
/// 一块折射出来的暗色色块；鼠标点按只要抖 1 px 就被它的拖动识别器吞掉、点击
/// 静默无效。观感稳定优先于「透镜」效果，所以滑块只是一枚普通的形状：
/// - 深色：白 20% + 0.5 px 低透明度内高光（不发白、不成圈）；
/// - 浅色：白色 + iOS 的柔和投影；
/// - 降低透明度（[solid]）：深色 tertiaryGroupedBackground、浅色白。
///
/// 交互：点一段选中；在控件上横拖时滑块跟手，松开吸附到最近一段；每段一个
/// 焦点停靠点（Enter / 手柄 A → [ActivateIntent]），键盘焦点画强调色环；
/// [onSelected] 为 null 时纯展示。切换时滑块弹簧滑动（减少动态效果 / 墨水屏
/// 下瞬移）。
class FushiAppleSegmentedControl extends StatefulWidget {
  const FushiAppleSegmentedControl({
    super.key,
    required this.segments,
    required this.selectedIndex,
    required this.onSelected,
    required this.height,
    required this.selectedStyle,
    required this.unselectedStyle,
    this.iconSize = 17,
    this.solid = false,
  });

  final List<FushiAppleSegmentData> segments;
  final int selectedIndex;
  final ValueChanged<int>? onSelected;
  final double height;
  final TextStyle selectedStyle;
  final TextStyle unselectedStyle;
  final double iconSize;

  /// 系统「降低透明度」：滑块用实色。
  final bool solid;

  @override
  State<FushiAppleSegmentedControl> createState() =>
      _FushiAppleSegmentedControlState();
}

class _FushiAppleSegmentedControlState
    extends State<FushiAppleSegmentedControl> {
  /// 轨道内边距：滑块与轨道外沿之间留 3 px（iOS 同）。
  static const double _inset = 3;

  /// 拖动中滑块中心（控件局部坐标）；null = 不在拖动。
  double? _dragCenter;
  int? _pressedIndex;
  int? _focusedIndex;

  bool get _enabled => widget.onSelected != null;

  void _select(int index) {
    if (!_enabled || index < 0 || index >= widget.segments.length) return;
    if (!widget.segments[index].enabled) return;
    if (index != widget.selectedIndex) widget.onSelected!(index);
  }

  Widget _segmentContent(FushiAppleSegmentData data, TextStyle style) {
    final Widget? text = data.label == null || data.label!.isEmpty
        ? null
        : Text(
            data.label!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          );
    final Widget? icon = data.icon == null
        ? null
        : IconTheme.merge(
            data: IconThemeData(
              color: style.color,
              size: text == null ? widget.iconSize + 3 : widget.iconSize,
            ),
            child: data.icon!,
          );
    final Widget body = icon != null && text != null
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[icon, const SizedBox(height: 2), text],
          )
        : (icon ?? text ?? const SizedBox.shrink());
    return AnimatedDefaultTextStyle(
      duration: einkSafeDuration(context, const Duration(milliseconds: 180)),
      style: style,
      child: body,
    );
  }

  BoxDecoration _thumbDecoration(BuildContext context, double radius) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool dark =
        Theme.of(context).colorScheme.brightness == Brightness.dark;
    if (dark) {
      return BoxDecoration(
        color: widget.solid
            ? apple.tertiaryGroupedBackground
            : Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(radius),
        // 0.5 px 低透明度内高光：只是让滑块边缘略有质感，不成「白圈」。
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 0.5,
        ),
      );
    }
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: Colors.black.withValues(alpha: 0.04),
        width: 0.5,
      ),
      boxShadow: const <BoxShadow>[
        BoxShadow(
          color: Color(0x1F000000),
          blurRadius: 8,
          offset: Offset(0, 3),
        ),
        BoxShadow(
          color: Color(0x0A000000),
          blurRadius: 1,
          offset: Offset(0, 3),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final int count = widget.segments.length;
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    final bool reduceMotion =
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
        isEinkTheme(context);
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = constraints.maxWidth;
          final double segmentWidth = math.max(
            0,
            (width - _inset * 2) / math.max(1, count),
          );
          final double thumbHeight = math.max(0, widget.height - _inset * 2);
          final double radius = thumbHeight / 2;
          // 逻辑段号 ↔ 视觉位置（RTL 镜像）。
          int visualOf(int index) => rtl ? count - 1 - index : index;
          int logicalIndexAt(double x) {
            final int visual = segmentWidth <= 0
                ? 0
                : ((x - _inset) / segmentWidth).floor().clamp(0, count - 1);
            return rtl ? count - 1 - visual : visual;
          }

          final int selected = widget.selectedIndex;
          final double thumbLeft = _dragCenter != null
              ? (_dragCenter! - segmentWidth / 2).clamp(
                  _inset,
                  math.max(_inset, width - _inset - segmentWidth),
                )
              : _inset + segmentWidth * visualOf(selected.clamp(0, count - 1));
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: _enabled
                ? (DragStartDetails d) =>
                      setState(() => _dragCenter = d.localPosition.dx)
                : null,
            onHorizontalDragUpdate: _enabled
                ? (DragUpdateDetails d) =>
                      setState(() => _dragCenter = d.localPosition.dx)
                : null,
            onHorizontalDragEnd: _enabled
                ? (DragEndDetails _) {
                    final double? center = _dragCenter;
                    setState(() {
                      _dragCenter = null;
                      _pressedIndex = null;
                    });
                    if (center != null) _select(logicalIndexAt(center));
                  }
                : null,
            onHorizontalDragCancel: _enabled
                ? () => setState(() => _dragCenter = null)
                : null,
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                // 选中滑块：在文字层之下。
                if (selected >= 0 && count > 0)
                  AnimatedPositioned(
                    duration: _dragCenter != null || reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 320),
                    // 略冲过头再落定的弹簧感（iOS 分段滑块）。
                    curve: const Cubic(0.3, 1.18, 0.55, 1),
                    left: thumbLeft,
                    top: _inset,
                    width: segmentWidth,
                    height: thumbHeight,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: _thumbDecoration(context, radius),
                      ),
                    ),
                  ),
                Positioned(
                  left: _inset,
                  right: _inset,
                  top: 0,
                  bottom: 0,
                  child: Row(
                    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                    children: <Widget>[
                      for (int i = 0; i < count; i++)
                        Expanded(
                          child: _buildCell(
                            context,
                            i,
                            apple,
                            selected: i == selected,
                            radius: radius,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCell(
    BuildContext context,
    int index,
    FushiAppleColors apple, {
    required bool selected,
    required double radius,
  }) {
    final FushiAppleSegmentData data = widget.segments[index];
    final bool enabled = _enabled && data.enabled;
    final TextStyle style = selected
        ? widget.selectedStyle
        : widget.unselectedStyle;
    final bool pressed = _pressedIndex == index && !selected;
    Widget content = AnimatedOpacity(
      duration: pressed
          ? Duration.zero
          : einkSafeDuration(context, const Duration(milliseconds: 160)),
      opacity: !data.enabled ? 0.38 : (pressed ? 0.5 : 1),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Center(child: _segmentContent(data, style)),
      ),
    );
    if (_focusedIndex == index) {
      content = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius + 3),
          border: Border.all(color: apple.accent, width: 2),
        ),
        child: content,
      );
    }
    Widget cell = Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: data.label ?? data.tooltip,
      // 内层 GestureDetector 排除了语义，读屏的 tap 由这里直接接到选段。
      onTap: enabled ? () => _select(index) : null,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent intent) {
              _select(index);
              return null;
            },
          ),
        },
        onShowFocusHighlight: (bool value) {
          setState(() => _focusedIndex = value ? index : null);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTapDown: enabled
              ? (_) => setState(() => _pressedIndex = index)
              : null,
          onTapUp: enabled ? (_) => setState(() => _pressedIndex = null) : null,
          onTapCancel: enabled
              ? () => setState(() => _pressedIndex = null)
              : null,
          onTap: enabled ? () => _select(index) : null,
          child: content,
        ),
      ),
    );
    if (data.tooltip != null && data.tooltip != data.label) {
      cell = Tooltip(message: data.tooltip, child: cell);
    }
    return cell;
  }
}

/// 分段控件选中段静止时的透明 pill 色：比轨道亮一点的无色白（深色 20% /
/// 浅色 70%），不着强调色。深色 16% 压在 #1C1C1E 卡片 + 透明玻璃轨上与轨道
/// 只差一阶，选中段读不出来（用户 2026-10-05 Windows 深色截图）。
Color _appleClearLensColor(BuildContext context) {
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  return Colors.white.withValues(alpha: dark ? 0.2 : 0.7);
}

/// 分段控件的液态玻璃轨：在控件**背后**垫一枚透明玻璃胶囊（兄弟层，而不是把
/// 控件包进 GlassContainer——库明确警告那样会让滑块透镜失去折射、果冻溢出被
/// 裁），控件自己的轨道底色给透明。[radius] 给 999 即全胶囊。
Widget _appleGlassTrack(
  BuildContext context, {
  required double radius,
  required Widget child,
}) {
  return Stack(
    clipBehavior: Clip.none,
    children: <Widget>[
      Positioned.fill(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double r = math.min(
              radius,
              constraints.biggest.shortestSide / 2,
            );
            return GlassContainer(
              useOwnLayer: true,
              quality: fushiGlassQuality(context, prominent: true),
              // 无色透明玻璃轨：只有高光边与轻微折射，没有灰底。
              settings: fushiClearGlassSettings(context),
              shape: LiquidRoundedSuperellipse(borderRadius: r),
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
      child,
    ],
  );
}

/// 分段退回形态的单段：选中段是带细阴影的滑块胶囊，未选中段透明；整段一个
/// 焦点停靠点（Enter / 手柄 A → ActivateIntent），键盘焦点画强调色焦点环。
class _AppleSegment extends StatefulWidget {
  const _AppleSegment({
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.thumbColor,
    required this.semanticLabel,
    required this.child,
  });

  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final Color thumbColor;
  final String? semanticLabel;
  final Widget child;

  @override
  State<_AppleSegment> createState() => _AppleSegmentState();
}

class _AppleSegmentState extends State<_AppleSegment> {
  bool _pressed = false;
  bool _focusHighlight = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final Widget body = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      constraints: BoxConstraints(
        minWidth: 44,
        minHeight: fushiAppleCompact(context) ? 24 : 30,
      ),
      decoration: BoxDecoration(
        color: widget.selected ? widget.thumbColor : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        // 选中的透明 pill 带一圈细高光边（玻璃 rim），键盘焦点时换强调色环。
        border: _focusHighlight
            ? Border.all(color: apple.accent, width: 2)
            : (widget.selected
                  ? Border.all(
                      color: Colors.white.withValues(alpha: 0.28),
                      width: 0.6,
                    )
                  : null),
        boxShadow: widget.selected
            ? const <BoxShadow>[
                BoxShadow(
                  color: Color(0x1F000000),
                  blurRadius: 8,
                  offset: Offset(0, 3),
                ),
              ]
            : const <BoxShadow>[],
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: AnimatedOpacity(
          duration: _pressed
              ? Duration.zero
              : const Duration(milliseconds: 160),
          opacity: _pressed ? 0.5 : 1,
          child: widget.child,
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      // 内层 GestureDetector 排除了语义，读屏的 tap 由这里直接接到 onTap。
      onTap: widget.enabled ? widget.onTap : null,
      child: FocusableActionDetector(
        enabled: widget.enabled,
        mouseCursor: widget.enabled
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent intent) {
              widget.onTap();
              return null;
            },
          ),
        },
        onShowFocusHighlight: (bool value) {
          setState(() => _focusHighlight = value);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
          onTapUp: widget.enabled ? (_) => _setPressed(false) : null,
          onTapCancel: widget.enabled ? () => _setPressed(false) : null,
          onTap: widget.enabled ? widget.onTap : null,
          child: body,
        ),
      ),
    );
  }
}
