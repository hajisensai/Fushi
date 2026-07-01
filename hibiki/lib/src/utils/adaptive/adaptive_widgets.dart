import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart'
    show MacosSwitch, MacosSlider, PushButton, ControlSize;
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/components/hibiki_motion_tokens.dart';

Widget adaptiveDialogAction({
  required BuildContext context,
  required VoidCallback? onPressed,
  required Widget child,
  bool isDestructiveAction = false,
  bool isDefaultAction = false,
}) {
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
  // SDK 假定两者同空间。HibikiAppUiScale 把树放大 s 倍、却把 MediaQuery.size 缩成 view/s，
  // 两空间差 s²，钳制甩飞气泡。这里把 Slider 看到的 screenSize 还原回 GLOBAL/view 空间
  // (= size * scale)，与 localToGlobal 同空间，钳制即正确归零。scale==1.0 为 no-op。
  // 只改 size（保留 textScaler 等），且 Slider 布局宽度来自父约束、不依赖 MediaQuery.size，
  // 故仅影响值指示器钳制这一条买路。
  final double uiScale = HibikiAppUiScale.of(context);
  if (uiScale == HibikiAppUiScale.defaultScale) return slider;
  final MediaQueryData mq = MediaQuery.of(context);
  return MediaQuery(
    data: mq.copyWith(size: mq.size * uiScale),
    child: slider,
  );
}

Widget adaptiveIndicator({
  required BuildContext context,
  Color? color,
  double? strokeWidth,
}) {
  if (isCupertinoPlatform(context)) {
    return CupertinoActivityIndicator(
      color: color,
      radius: strokeWidth != null ? strokeWidth * 2.5 : 10.0,
    );
  }
  return CircularProgressIndicator(
    color: color,
    strokeWidth: strokeWidth ?? 4.0,
  );
}

Future<T?> adaptiveModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool showDragHandle = true,
}) {
  if (isCupertinoPlatform(context)) {
    return showCupertinoModalPopup<T>(
      context: context,
      builder: builder,
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    showDragHandle: showDragHandle,
    sheetAnimationStyle: hibikiMd3SheetAnimationStyle,
    builder: builder,
  );
}

Widget adaptiveSegmentedButton<T extends Object>({
  required BuildContext context,
  required List<ButtonSegment<T>> segments,
  required Set<T> selected,
  required ValueChanged<Set<T>> onSelectionChanged,
  ButtonStyle? style,
}) {
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

Route<T> adaptivePageRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
  BuildContext? context,
}) {
  final bool cupertino =
      context != null ? isCupertinoPlatform(context) : isCupertinoDefault;
  if (cupertino) {
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
