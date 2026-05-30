import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

Widget adaptiveAlertDialog({
  required BuildContext context,
  Widget? title,
  Widget? content,
  List<Widget>? actions,
  EdgeInsetsGeometry? contentPadding,
  EdgeInsetsGeometry? titlePadding,
  EdgeInsetsGeometry? actionsPadding,
  EdgeInsetsGeometry? buttonPadding,
  EdgeInsets? insetPadding,
}) {
  if (isCupertinoPlatform(context)) {
    // CupertinoAlertDialog 不提供 Material 祖先；content 里若含 Material 组件
    // (如 HibikiTextField) 会抛 "No Material widget found"。包一层透明 Material
    // 只提供祖先、不改外观，使所有 Cupertino 对话框的 Material 内容可用。
    return CupertinoAlertDialog(
      title: title,
      content: content == null
          ? null
          : Material(type: MaterialType.transparency, child: content),
      actions: actions ?? const [],
    );
  }
  final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
  return ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 560),
    child: AlertDialog(
      title: title,
      content: content,
      actions: actions,
      shape: RoundedRectangleBorder(borderRadius: tokens.radii.dialogRadius),
      backgroundColor: tokens.surfaces.overlay,
      surfaceTintColor: Colors.transparent,
      contentPadding: contentPadding,
      titlePadding: titlePadding,
      actionsPadding:
          actionsPadding ?? const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 20),
      buttonPadding: buttonPadding,
      insetPadding: insetPadding,
    ),
  );
}

Widget adaptiveDialogAction({
  required BuildContext context,
  required VoidCallback? onPressed,
  required Widget child,
  bool isDestructiveAction = false,
  bool isDefaultAction = false,
}) {
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
  return Slider(
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
