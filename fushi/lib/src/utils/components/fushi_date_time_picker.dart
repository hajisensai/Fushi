import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isGlassDesign;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveDialogAction, adaptiveModalSheet;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiModalSheetFrame;
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_sheet_header.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics, fushiAppleUsesMacMetrics;
import 'package:material_ui/material_ui.dart';

/// 日期 / 时间选择的设计系统分派入口（页面层不写裸 `showDatePicker` /
/// `showTimePicker`，守卫 `m3e_raw_component_ratchet_guard_test.dart`）。
///
/// - MD3（M3E）：原样调 SDK 的 [showDatePicker] / [showTimePicker]，参数一一透传，
///   外观与行为与直接调用一字不差。
/// - Apple（Cupertino，判据 [isGlassDesign]）：cupertino_ui 的
///   [CupertinoDatePicker] 滚轮放进 Apple sheet——iOS 档（窄屏）是底部 sheet，
///   顶部导航栏左「取消」右「完成」（[FushiAppleSheetHeader]）；macOS 档（宽屏，
///   [fushiAppleUsesMacMetrics]）是窗口正中的浮动 sheet，标题在上、「取消 /
///   完成」按钮靠右在下（macOS sheet 惯例）。点遮罩 / Esc / 取消返回 null。
Future<DateTime?> showFushiDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  String? helpText,
}) {
  if (!isGlassDesign(context)) {
    return showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: helpText,
    );
  }
  final DateTime min = DateUtils.dateOnly(firstDate);
  final DateTime max = DateTime(
    lastDate.year,
    lastDate.month,
    lastDate.day,
    23,
    59,
    59,
  );
  DateTime initial = DateUtils.dateOnly(initialDate);
  if (initial.isBefore(min)) initial = min;
  if (initial.isAfter(max)) initial = DateUtils.dateOnly(max);
  return adaptiveModalSheet<DateTime>(
    context: context,
    showDragHandle: false,
    builder: (BuildContext sheetContext) => _FushiApplePickerSheet(
      title: helpText,
      mode: CupertinoDatePickerMode.date,
      initial: initial,
      minimum: min,
      maximum: max,
      onDone: (DateTime value) =>
          Navigator.of(sheetContext).pop(DateUtils.dateOnly(value)),
    ),
  );
}

/// 时间选择（见 [showFushiDatePicker] 的分派说明）。Apple 下 12 / 24 小时制跟随
/// [MediaQuery.alwaysUse24HourFormatOf]（与 SDK 时间选择器同一来源）。
Future<TimeOfDay?> showFushiTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
  String? helpText,
}) {
  if (!isGlassDesign(context)) {
    return showTimePicker(
      context: context,
      initialTime: initialTime,
      helpText: helpText,
    );
  }
  final DateTime anchor = DateTime(2000, 1, 1);
  return adaptiveModalSheet<TimeOfDay>(
    context: context,
    showDragHandle: false,
    builder: (BuildContext sheetContext) => _FushiApplePickerSheet(
      title: helpText,
      mode: CupertinoDatePickerMode.time,
      initial: DateTime(
        anchor.year,
        anchor.month,
        anchor.day,
        initialTime.hour,
        initialTime.minute,
      ),
      onDone: (DateTime value) =>
          Navigator.of(sheetContext).pop(TimeOfDay.fromDateTime(value)),
    ),
  );
}

/// Apple 日期 / 时间 sheet 的内容：滚轮 + 「取消 / 完成」。滚轮的值只在本地
/// 暂存，按「完成」才经 [onDone] 交出去（iOS 惯例：滚动不即时生效）。
class _FushiApplePickerSheet extends StatefulWidget {
  const _FushiApplePickerSheet({
    required this.mode,
    required this.initial,
    required this.onDone,
    this.title,
    this.minimum,
    this.maximum,
  });

  final CupertinoDatePickerMode mode;
  final DateTime initial;
  final DateTime? minimum;
  final DateTime? maximum;
  final String? title;
  final ValueChanged<DateTime> onDone;

  @override
  State<_FushiApplePickerSheet> createState() => _FushiApplePickerSheetState();
}

class _FushiApplePickerSheetState extends State<_FushiApplePickerSheet> {
  late DateTime _value = widget.initial;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool mac = fushiAppleUsesMacMetrics(context);
    final double scale = FushiAppleMetrics.of(context).scale;
    final Brightness brightness = Theme.of(context).colorScheme.brightness;
    final Widget picker = CupertinoTheme(
      data: CupertinoThemeData(
        brightness: brightness,
        primaryColor: apple.accent,
        textTheme: CupertinoTextThemeData(
          dateTimePickerTextStyle: TextStyle(
            fontSize: (mac ? 15 : 21) * scale,
            letterSpacing: 0,
            color: apple.label,
          ),
        ),
      ),
      child: SizedBox(
        key: const ValueKey<String>('fushi-apple-date-picker'),
        height: (mac ? 168 : 216) * scale,
        child: CupertinoDatePicker(
          mode: widget.mode,
          initialDateTime: widget.initial,
          minimumDate: widget.minimum,
          maximumDate: widget.maximum,
          use24hFormat: MediaQuery.alwaysUse24HourFormatOf(context),
          itemExtent: (mac ? 24 : 32) * scale,
          onDateTimeChanged: (DateTime value) => _value = value,
        ),
      ),
    );
    final Widget cancel = adaptiveDialogAction(
      context: context,
      onPressed: () => Navigator.of(context).pop(),
      child: Text(t.dialog_cancel),
    );
    final Widget done = adaptiveDialogAction(
      context: context,
      isDefaultAction: true,
      onPressed: () => widget.onDone(_value),
      child: Text(t.dialog_done),
    );
    if (mac) {
      return FushiModalSheetFrame(
        title: widget.title,
        body: picker,
        footer: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8 * scale,
          children: <Widget>[cancel, done],
        ),
      );
    }
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiAppleSheetHeader(
            title: widget.title,
            leading: cancel,
            trailing: done,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: picker,
          ),
        ],
      ),
    );
  }
}
