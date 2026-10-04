import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart'
    show MacosSwitch, MacosSlider, PushButton, ControlSize;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiFilledButton, FushiTextButton;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show
        GlassProgressIndicator,
        GlassSegment,
        GlassContainer,
        GlassSegmentedControl,
        GlassSlider,
        GlassSwitch,
        LiquidVerticalRoundedSuperellipse;

Widget adaptiveDialogAction({
  required BuildContext context,
  required VoidCallback? onPressed,
  required Widget child,
  bool isDestructiveAction = false,
  bool isDefaultAction = false,
}) {
  // 「玻璃」设计系统：玻璃按钮族（fushi_glass_buttons 的分派包装在玻璃下渲染
  // GlassButton，自带焦点环 + Enter → ActivateIntent）。配色口径与 MD3 分支一致：
  // 默认动作 = 主色玻璃、破坏性 = errorContainer 着色、其余 = 透明玻璃。
  if (isGlassDesign(context)) {
    if (isDestructiveAction) {
      final ColorScheme cs = Theme.of(context).colorScheme;
      return FushiFilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: cs.errorContainer,
          foregroundColor: cs.onErrorContainer,
        ),
        child: child,
      );
    }
    if (isDefaultAction) {
      return FushiFilledButton(onPressed: onPressed, child: child);
    }
    return FushiTextButton(onPressed: onPressed, child: child);
  }
  // macOS-native: PushButton is the standard dialog button. Default action =
  // filled primary; destructive = error-tinted; everything else = secondary
  // (the grey Cancel-style button). Checked before isCupertinoPlatform (macOS
  // auto answers true there as the legacy fallback).
  if (isMacosPlatform(context)) {
    if (isDestructiveAction) {
      return PushButton(
        controlSize: ControlSize.large,
        color: Theme.of(context).colorScheme.error,
        onPressed: onPressed,
        child: child,
      );
    }
    return PushButton(
      controlSize: ControlSize.large,
      secondary: !isDefaultAction,
      onPressed: onPressed,
      child: child,
    );
  }
  if (isCupertinoPlatform(context)) {
    return CupertinoDialogAction(
      onPressed: onPressed,
      isDestructiveAction: isDestructiveAction,
      isDefaultAction: isDefaultAction,
      child: child,
    );
  }
  if (isDestructiveAction) {
    final cs = Theme.of(context).colorScheme;
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: cs.errorContainer,
        foregroundColor: cs.onErrorContainer,
      ),
      child: child,
    );
  }
  if (isDefaultAction) {
    return FilledButton(
      onPressed: onPressed,
      child: child,
    );
  }
  return TextButton(
    onPressed: onPressed,
    child: child,
  );
}

Widget adaptiveSwitch({
  required BuildContext context,
  required bool value,
  required ValueChanged<bool>? onChanged,
  Color? activeColor,
}) {
  if (isGlassDesign(context)) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    // GlassSwitch 的 onChanged 不可空：禁用态用 IgnorePointer + 半透明表达，
    // 与 MD3 Switch(onChanged: null) 同语义（不可点、不可聚焦）。
    final Widget glassSwitch = GlassSwitch(
      value: value,
      onChanged: onChanged ?? (_) {},
      activeColor: activeColor ?? cs.primary,
      inactiveColor: cs.outlineVariant,
      quality: fushiGlassQuality(context),
    );
    if (onChanged != null) return glassSwitch;
    return IgnorePointer(
      child: ExcludeFocus(child: Opacity(opacity: 0.38, child: glassSwitch)),
    );
  }
  // macOS-native: MacosSwitch is a clean drop-in (nullable onChanged handles the
  // disabled state, activeColor maps 1:1). Checked BEFORE isCupertinoPlatform
  // because under `auto` macOS still answers true there as the legacy fallback.
  if (isMacosPlatform(context)) {
    // Let MacosSwitch use the system accent for its active track — that's the
    // native macOS look, more correct than forcing the app's activeColor (which
    // is a Material/Cupertino Color, not macos_ui's MacosColor anyway).
    return MacosSwitch(
      value: value,
      onChanged: onChanged,
    );
  }
  if (isCupertinoPlatform(context)) {
    return CupertinoSwitch(
      value: value,
      onChanged: onChanged,
      activeTrackColor: activeColor ?? CupertinoTheme.of(context).primaryColor,
    );
  }
  return Switch(
    value: value,
    onChanged: onChanged,
    activeColor: activeColor,
  );
}

Widget adaptiveSlider({
  required BuildContext context,
  required double value,
  required ValueChanged<double>? onChanged,
  double min = 0.0,
  double max = 1.0,
  int? divisions,
  String? label,
  Color? thumbColor,
  ValueChanged<double>? onChangeStart,
  ValueChanged<double>? onChangeEnd,
}) {
  if (isGlassDesign(context)) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return GlassSlider(
      value: value.clamp(min, max).toDouble(),
      onChanged: onChanged,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
      min: min,
      max: max,
      divisions: divisions,
      label: label,
      activeColor: cs.primary,
      inactiveColor: cs.outlineVariant,
      thumbColor: thumbColor ?? Colors.white,
      quality: fushiGlassQuality(context),
    );
  }
  // macOS-native: MacosSlider has no onChangeEnd/onChangeStart/divisions, so a
  // thin wrapper re-creates the commit-on-drag-end contract the settings sliders
  // rely on (e.g. app UI scale). Only when interactive — a null onChanged means
  // disabled, which MacosSlider can't express (its onChanged is non-nullable),
  // so we fall through to the Cupertino disabled slider for that case.
  if (isMacosPlatform(context) && onChanged != null) {
    return _MacosSliderWithDragCallbacks(
      value: value.clamp(min, max).toDouble(),
      min: min,
      max: max,
      divisions: divisions,
      color: Theme.of(context).colorScheme.primary,
      onChanged: onChanged,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
    );
  }
  if (isCupertinoPlatform(context)) {
    return CupertinoSlider(
      value: value,
      onChanged: onChanged,
      min: min,
      max: max,
      divisions: divisions,
      thumbColor: thumbColor ?? CupertinoColors.white,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
    );
  }
  final Widget slider = Slider(
    value: value,
    onChanged: onChanged,
    min: min,
    max: max,
    divisions: divisions,
    label: label,
    thumbColor: thumbColor,
    onChangeStart: onChangeStart,
    onChangeEnd: onChangeEnd,
  );
  // 值指示器水平钳制根因修复（见 slider_value_indicator_scale_test.dart）：
  // Material Slider 的 getHorizontalShift 用 parentBox.localToGlobal(center)（GLOBAL/
  // view 坐标，含 Transform.scale 的 ×s）与 sizeWithOverflow(= MediaQuery.sizeOf) 比较，
  // SDK 假定两者同空间。FushiAppUiScale 把树放大 s 倍、却把 MediaQuery.size 缩成 view/s，
  // 两空间差 s²，钳制甩飞气泡。这里把 Slider 看到的 screenSize 还原回 GLOBAL/view 空间
  // (= size * scale)，与 localToGlobal 同空间，钳制即正确归零。scale==1.0 为 no-op。
  // 只改 size（保留 textScaler 等），且 Slider 布局宽度来自父约束、不依赖 MediaQuery.size，
  // 故仅影响值指示器钳制这一条买路。
  final double uiScale = FushiAppUiScale.of(context);
  if (uiScale == FushiAppUiScale.defaultScale) return slider;
  final MediaQueryData mq = MediaQuery.of(context);
  return MediaQuery(
    data: mq.copyWith(size: mq.size * uiScale),
    child: slider,
  );
}

/// [value] 非空时画**确定**进度（0..1）；为空时是原本的不确定动画。两个平台分支都
/// 认这个值，避免「Material 显进度、Cupertino 一直转」的静默分歧。
///
/// eink 下不确定态改成一枚静止的沙漏：转圈是永不停歇的动画，墨水屏上等于那一小块
/// 持续局部刷新（闪烁 + 残影）；确定进度照常画环（一次一格、不连续重绘）。
Widget adaptiveIndicator({
  required BuildContext context,
  Color? color,
  double? strokeWidth,
  double? value,
}) {
  if (value == null && isEinkTheme(context)) {
    // 这是全局 helper：不少调用点把它包在 14~20 px 的 tight SizedBox 里（Anki
    // 配置行、字幕重匹配、阅读器快捷设置……），父约束会把 36 压到 16 而 24 px 的
    // 字形不缩，裁成残缺一角。FittedBox.scaleDown 让沙漏随容器缩、无约束时不放大。
    return SizedBox(
      width: 36,
      height: 36,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Icon(
          Icons.hourglass_top,
          color: color ?? Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
  if (isGlassDesign(context)) {
    // 与 CircularProgressIndicator 同一个 36 的默认外框：调用点常把它塞进
    // 14~20 的 tight SizedBox，紧约束下照样跟着缩。
    return GlassProgressIndicator.circular(
      value: value?.clamp(0.0, 1.0),
      size: 36,
      strokeWidth: strokeWidth ?? 4.0,
      color: color ?? Theme.of(context).colorScheme.primary,
      quality: fushiGlassQuality(context),
    );
  }
  if (isCupertinoPlatform(context)) {
    final double radius = strokeWidth != null ? strokeWidth * 2.5 : 10.0;
    if (value != null) {
      return CupertinoActivityIndicator.partiallyRevealed(
        color: color,
        radius: radius,
        progress: value.clamp(0.0, 1.0),
      );
    }
    return CupertinoActivityIndicator(color: color, radius: radius);
  }
  return CircularProgressIndicator(
    color: color,
    strokeWidth: strokeWidth ?? 4.0,
    value: value,
  );
}

Future<T?> adaptiveModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool showDragHandle = true,
  bool useSafeArea = false,
}) {
  if (isCupertinoPlatform(context)) {
    return showCupertinoModalPopup<T>(
      context: context,
      builder: builder,
    );
  }
  if (isGlassDesign(context)) {
    // 「玻璃」设计系统：弹层表面是只有上圆角的玻璃（GlassSheet 的形状与拖动条
    // 观感）。不直接用 GlassSheet：它把内容放进非弹性槽 / 自带滚动视图，内容
    // 拿到的是无界高度，而这里的调用点（FushiModalSheetFrame 等）靠 Flexible
    // 在弹层高度内收缩，放进去会抛无界约束。BottomSheet 只剩路由 / 拖拽关闭
    // 职责，自身透明无阴影。
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      elevation: 0,
      sheetAnimationStyle: fushiMd3SheetAnimationStyle,
      builder: (BuildContext sheetContext) => _LiquidSheetBody(
        showDragHandle: showDragHandle,
        child: builder(sheetContext),
      ),
    );
  }
  if (glassMaterialOf(context) != FushiGlassMaterial.off) {
    // 毛玻璃：BottomSheet 自己的底色让位，表面交给 FushiGlassSurface。拖动条
    // 由 BottomSheet 画在 child 之外，底色透明后会悬在未模糊的内容上，所以这里
    // 关掉它、在玻璃里按 M3 同一几何（48 高交互区 + 32x4 横条）自己画。
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      elevation: 0,
      sheetAnimationStyle: fushiMd3SheetAnimationStyle,
      builder: (BuildContext sheetContext) => _GlassSheetBody(
        showDragHandle: showDragHandle,
        child: builder(sheetContext),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    showDragHandle: showDragHandle,
    sheetAnimationStyle: fushiMd3SheetAnimationStyle,
    builder: builder,
  );
}

/// 玻璃设计系统的底部弹层表面：上圆角超椭圆 [GlassContainer] + 与 M3 同几何的
/// 拖动条（48 高交互区 + 36x5 胶囊）。内容外包一层透明 Material，弹层里的 MD3
/// 子组件（InkWell 等）仍有画墨水的祖先。
class _LiquidSheetBody extends StatelessWidget {
  const _LiquidSheetBody({required this.showDragHandle, required this.child});

  final bool showDragHandle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double radius = FushiBorderRadius.sheet.topLeft.x;
    final Widget content = Material(
      type: MaterialType.transparency,
      child: child,
    );
    return GlassContainer(
      shape: LiquidVerticalRoundedSuperellipse(
        topRadius: radius,
        bottomRadius: 0,
      ),
      quality: fushiGlassQuality(context, prominent: true),
      settings: fushiGlassSettings(
        context,
        tint: FushiDesignTokens.of(context).surfaces.group,
      ),
      clipBehavior: Clip.antiAlias,
      child: showDragHandle
          ? Stack(
              alignment: Alignment.topCenter,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: kMinInteractiveDimension),
                  child: content,
                ),
                SizedBox(
                  height: kMinInteractiveDimension,
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 5,
                      decoration: BoxDecoration(
                        color: colors.onSurfaceVariant.withValues(alpha: 0.45),
                        borderRadius:
                            const BorderRadius.all(Radius.circular(2.5)),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : content,
    );
  }
}

class _GlassSheetBody extends StatelessWidget {
  const _GlassSheetBody({required this.showDragHandle, required this.child});

  final bool showDragHandle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return FushiGlassSurface(
      borderRadius: FushiBorderRadius.sheet,
      // M3 底部弹层的色阶（BottomSheet 默认底色 surfaceContainerLow）。
      baseColor: FushiDesignTokens.of(context).surfaces.group,
      child: showDragHandle
          ? Stack(
              alignment: Alignment.topCenter,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: kMinInteractiveDimension),
                  child: child,
                ),
                SizedBox(
                  height: kMinInteractiveDimension,
                  child: Center(
                    child: Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.onSurfaceVariant.withValues(alpha: 0.4),
                        borderRadius:
                            const BorderRadius.all(Radius.circular(2)),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : child,
    );
  }
}

Widget adaptiveSegmentedButton<T extends Object>({
  required BuildContext context,
  required List<ButtonSegment<T>> segments,
  required Set<T> selected,
  required ValueChanged<Set<T>> onSelectionChanged,
  ButtonStyle? style,
}) {
  if (isGlassDesign(context)) {
    return _GlassSegmentedButton<T>(
      segments: segments,
      selected: selected,
      onSelectionChanged: onSelectionChanged,
    );
  }
  if (isCupertinoPlatform(context)) {
    final T groupValue = selected.first;
    return CupertinoSlidingSegmentedControl<T>(
      groupValue: groupValue,
      onValueChanged: (v) {
        if (v != null) onSelectionChanged({v});
      },
      children: {
        for (final seg in segments)
          seg.value: seg.label ?? seg.icon ?? Text('$seg'),
      },
    );
  }
  return SegmentedButton<T>(
    showSelectedIcon: false,
    segments: segments,
    selected: selected,
    onSelectionChanged: onSelectionChanged,
    style: style,
  );
}

/// 「玻璃」设计系统的分段控件：[GlassSegmentedControl]（滑动玻璃指示器）。
///
/// [ButtonSegment] 的文字段取 Text.data、图标段取 icon、tooltip / enabled 原样
/// 带过去。GlassSegmentedControl 按段均分可用宽：在无界宽（横向滚动的分段条
/// 宿主）里先按与 settings_shared 同口径的估宽给出自然宽，避免无界约束。
class _GlassSegmentedButton<T extends Object> extends StatelessWidget {
  const _GlassSegmentedButton({
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
  });

  final List<ButtonSegment<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>> onSelectionChanged;

  static String? _labelOf(ButtonSegment<Object> segment) {
    final Widget? label = segment.label;
    if (label is Text) return label.data ?? label.textSpan?.toPlainText();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextStyle base = FushiDesignTokens.of(context).type.controlLabel;
    final int found = selected.isEmpty
        ? -1
        : segments
            .indexWhere((ButtonSegment<T> s) => s.value == selected.first);
    final int selectedIndex = found < 0 ? 0 : found;
    final List<GlassSegment> glassSegments = <GlassSegment>[
      for (final ButtonSegment<T> s in segments)
        GlassSegment(
          label: _labelOf(s),
          icon: _labelOf(s) == null ? s.icon : null,
          tooltip: s.tooltip,
          enabled: s.enabled,
        ),
    ];
    final double textScale = MediaQuery.textScalerOf(context).scale(1);
    double naturalWidth = 4;
    for (final ButtonSegment<T> s in segments) {
      final String? label = _labelOf(s);
      naturalWidth += label == null
          ? 48
          : 32 + _estimateTextWidth(label, (base.fontSize ?? 14) * textScale);
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Widget control = GlassSegmentedControl(
          segments: glassSegments,
          selectedIndex: selectedIndex,
          onSegmentSelected: (int index) {
            if (index < 0 || index >= segments.length) return;
            if (!segments[index].enabled) return;
            onSelectionChanged(<T>{segments[index].value});
          },
          selectedTextStyle: base.copyWith(
            color: cs.onSurface,
            fontWeight: FontWeight.w600,
          ),
          unselectedTextStyle: base.copyWith(color: cs.onSurfaceVariant),
          selectedIconColor: cs.onSurface,
          unselectedIconColor: cs.onSurfaceVariant,
          iconSize: 18,
          indicatorColor: cs.secondaryContainer.withValues(alpha: 0.6),
          quality: fushiGlassQuality(context),
        );
        if (constraints.maxWidth.isFinite) return control;
        return SizedBox(width: naturalWidth, child: control);
      },
    );
  }

  /// CJK / 全角按 1em，其余按 0.62em（与 settings_shared 的分段估宽同口径）。
  static double _estimateTextWidth(String text, double fontSize) {
    double width = 0;
    for (final int rune in text.runes) {
      width += rune >= 0x1100 ? fontSize : fontSize * 0.62;
    }
    return width;
  }
}

Route<T> adaptivePageRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
}) {
  if (isCupertinoPlatform(context)) {
    return CupertinoPageRoute<T>(
      builder: builder,
      settings: settings,
      fullscreenDialog: fullscreenDialog,
    );
  }
  return MaterialPageRoute<T>(
    builder: builder,
    settings: settings,
    fullscreenDialog: fullscreenDialog,
  );
}

/// Wraps [MacosSlider] (which only exposes a continuous [onChanged]) to restore
/// the [Slider]/[CupertinoSlider] drag-boundary callbacks the settings sliders
/// depend on. The raw [Listener] sees the pointer down/up regardless of the
/// slider's internal pan recognizer, so commit-on-drag-end keeps working without
/// re-introducing the scaled-tree slider regression. Maps Material `divisions`
/// to MacosSlider's `discrete`/`splits`.
class _MacosSliderWithDragCallbacks extends StatefulWidget {
  const _MacosSliderWithDragCallbacks({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.color,
    required this.onChanged,
    required this.onChangeStart,
    required this.onChangeEnd,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final Color color;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<_MacosSliderWithDragCallbacks> createState() =>
      _MacosSliderWithDragCallbacksState();
}

class _MacosSliderWithDragCallbacksState
    extends State<_MacosSliderWithDragCallbacks> {
  late double _latest = widget.value;

  @override
  void didUpdateWidget(_MacosSliderWithDragCallbacks oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Track externally-driven value changes between drags so a pointer-up that
    // fires without an intervening onChanged still commits the current value.
    if (oldWidget.value != widget.value) _latest = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final int? divisions = widget.divisions;
    return Listener(
      onPointerDown: (_) => widget.onChangeStart?.call(_latest),
      onPointerUp: (_) => widget.onChangeEnd?.call(_latest),
      onPointerCancel: (_) => widget.onChangeEnd?.call(_latest),
      child: MacosSlider(
        value: _latest.clamp(widget.min, widget.max).toDouble(),
        min: widget.min,
        max: widget.max,
        discrete: divisions != null,
        splits: (divisions != null && divisions >= 2) ? divisions : 15,
        color: widget.color,
        onChanged: (double next) {
          _latest = next;
          widget.onChanged(next);
        },
      ),
    );
  }
}
