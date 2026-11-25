import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:intl/intl.dart' show NumberFormat;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/reader/reader_status_bar_layout.dart';
import 'package:fushi/src/reader/reader_status_footer.dart'
    show kReaderStatusFooterFontSize, readerProgressLabel;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 页眉行高（页脚沿用读数胶囊的 [kReaderStatusFooterHeight]，两条栏视觉上一样高）。
/// 视觉高度 == 喂给 WebView 的顶部预留高度（chrome 铁律，见
/// reader_chrome_floating.dart 文件头）。
const double kReaderStatusHeaderHeight = 24;

/// 页脚右槽文字与读数胶囊之间的间距。
const double kReaderStatusBarTrailingGap = 10;

/// 状态栏文字的透明度：与读数胶囊的 `muted`（0.55）同一档的「常驻但不抢正文」。
const double kReaderStatusBarTextAlpha = 0.6;

/// 一次绘制要用到的全部读数原料。全部可空：拿不到的读数整项不画（不画占位符）。
@immutable
class ReaderStatusBarData {
  const ReaderStatusBarData({
    required this.now,
    required this.continuous,
    this.batteryLevel,
    this.chapterTitle,
    this.bookTitle,
    this.chapterPage,
    this.chapterPageTotal,
    this.chapterChars,
    this.chapterCharsTotal,
    this.bookChars,
    this.bookCharsTotal,
  });

  final DateTime now;

  /// 连续滚动模式没有「页」：页码项改画本章进度（设计图 ④）。
  final bool continuous;

  /// 0–100；平台拿不到（桌面无电池、插件未注册）时 null。
  final int? batteryLevel;
  final String? chapterTitle;
  final String? bookTitle;

  /// 分页模式本章第几页 / 共几页（1 起），由分页引擎 `pageInfo()` 回报。
  final int? chapterPage;
  final int? chapterPageTotal;
  final int? chapterChars;
  final int? chapterCharsTotal;
  final int? bookChars;
  final int? bookCharsTotal;
}

String _charsPair(int? current, int? total, String locale) {
  final NumberFormat format = NumberFormat.decimalPattern(locale);
  return '${format.format(current)} / ${format.format(total)}';
}

/// 某项此刻要画的文字；拿不到数据时 null（整项不画）。纯函数，测试直接调。
/// 默认时钟写法：24 小时制 `HH:mm`。阅读器里改用 `MaterialLocalizations` 按界面语言与
/// 系统 12 / 24 小时制格式化（[readerStatusBarSlotText] 的 `formatClock`）；`intl` 的
/// `DateFormat` 需要先 `initializeDateFormatting`，阅读器里不为一个时钟去等它。
String readerStatusBarDefaultClock(DateTime now) =>
    '${now.hour.toString().padLeft(2, '0')}:'
    '${now.minute.toString().padLeft(2, '0')}';

String? readerStatusBarItemText(
  ReaderStatusBarItem item,
  ReaderStatusBarData data, {
  String locale = 'en',
  String Function(DateTime now) formatClock = readerStatusBarDefaultClock,
}) {
  String? chapterPercent() {
    final String? label = readerProgressLabel(
      current: data.chapterChars,
      total: data.chapterCharsTotal,
    );
    return label == null ? null : t.reader_status_bar_chapter_percent(p: label);
  }

  switch (item) {
    case ReaderStatusBarItem.clock:
      return formatClock(data.now);
    case ReaderStatusBarItem.battery:
      final int? level = data.batteryLevel;
      return level == null ? null : '$level%';
    case ReaderStatusBarItem.chapterTitle:
      final String? title = data.chapterTitle?.trim();
      return title == null || title.isEmpty ? null : title;
    case ReaderStatusBarItem.bookTitle:
      final String? title = data.bookTitle?.trim();
      return title == null || title.isEmpty ? null : title;
    case ReaderStatusBarItem.chapterPage:
      if (data.continuous) return chapterPercent();
      final int? page = data.chapterPage;
      final int? total = data.chapterPageTotal;
      if (page == null || total == null || total <= 0) return null;
      return '$page / $total';
    case ReaderStatusBarItem.chapterProgress:
      return chapterPercent();
    case ReaderStatusBarItem.chapterChars:
      final int? current = data.chapterChars;
      final int? total = data.chapterCharsTotal;
      if (current == null || total == null || total <= 0) return null;
      return _charsPair(current, total, locale);
    case ReaderStatusBarItem.bookProgress:
      return readerProgressLabel(
        current: data.bookChars,
        total: data.bookCharsTotal,
      );
    case ReaderStatusBarItem.bookChars:
      final int? current = data.bookChars;
      final int? total = data.bookCharsTotal;
      if (current == null || total == null || total <= 0) return null;
      return _charsPair(current, total, locale);
  }
}

/// 一个槽位整串文字（槽内多项用两个 em 空白隔开）；空槽 null。
String? readerStatusBarSlotText(
  ReaderStatusBarLayout layout,
  ReaderStatusBarSlot slot,
  ReaderStatusBarData data, {
  String locale = 'en',
  String Function(DateTime now) formatClock = readerStatusBarDefaultClock,
}) {
  final List<String> parts = <String>[
    for (final ReaderStatusBarItem item in layout.itemsIn(slot))
      ?readerStatusBarItemText(
        item,
        data,
        locale: locale,
        formatClock: formatClock,
      ),
  ];
  return parts.isEmpty ? null : parts.join(' ');
}

/// 设备电量（battery_plus）。只在有状态栏放了「电量」时由 [ReaderStatusBarClock]
/// 拉起；一分钟读一次（电量变化很慢，不订阅高频事件），桌面无电池 / 平台不支持
/// 时保持 null——电量项不画。
class ReaderBatteryMonitor {
  ReaderBatteryMonitor._();

  static final ReaderBatteryMonitor instance = ReaderBatteryMonitor._();

  final ValueNotifier<int?> level = ValueNotifier<int?>(null);
  final Battery _battery = Battery();
  bool _unsupported = false;

  Future<void> refresh() async {
    if (_unsupported) return;
    try {
      final int value = await _battery.batteryLevel;
      // Windows / macOS 台式机无电池时插件回 -1 或 0 以外的哨兵值：当作拿不到。
      level.value = value >= 0 && value <= 100 ? value : null;
    } on MissingPluginException {
      _unsupported = true;
    } catch (e, stack) {
      // 无电池的桌面机插件会抛 PlatformException：电量项不画，不重试刷日志。
      _unsupported = true;
      ErrorLogService.instance.log('ReaderBatteryMonitor.refresh', e, stack);
    }
  }
}

/// 状态栏的分钟时钟：放了「时间」/「电量」时每到整分钟重建一次子树（电量顺带
/// 一分钟读一次）；都没放时不起 Timer。
class ReaderStatusBarClock extends StatefulWidget {
  const ReaderStatusBarClock({
    super.key,
    required this.tickClock,
    required this.watchBattery,
    required this.builder,
  });

  final bool tickClock;
  final bool watchBattery;
  final Widget Function(BuildContext context, DateTime now, int? battery)
  builder;

  @override
  State<ReaderStatusBarClock> createState() => _ReaderStatusBarClockState();
}

class _ReaderStatusBarClockState extends State<ReaderStatusBarClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
    ReaderBatteryMonitor.instance.level.addListener(_onBattery);
  }

  @override
  void didUpdateWidget(ReaderStatusBarClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tickClock != widget.tickClock ||
        oldWidget.watchBattery != widget.watchBattery) {
      _sync();
    }
  }

  void _onBattery() {
    if (mounted && widget.watchBattery) setState(() {});
  }

  void _sync() {
    _timer?.cancel();
    _timer = null;
    if (widget.watchBattery) {
      unawaited(ReaderBatteryMonitor.instance.refresh());
    }
    if (!widget.tickClock && !widget.watchBattery) return;
    _scheduleNextMinute();
  }

  void _scheduleNextMinute() {
    final DateTime now = DateTime.now();
    final Duration untilNext = Duration(
      seconds: 60 - now.second,
      milliseconds: -now.millisecond,
    );
    _timer = Timer(untilNext, () {
      if (!mounted) return;
      if (widget.watchBattery) {
        unawaited(ReaderBatteryMonitor.instance.refresh());
      }
      setState(() {});
      _scheduleNextMinute();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    ReaderBatteryMonitor.instance.level.removeListener(_onBattery);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    DateTime.now(),
    widget.watchBattery ? ReaderBatteryMonitor.instance.level.value : null,
  );
}

/// 状态栏文字样式：字号与读数胶囊同源（12），等宽数字，跟随主题正文色。
TextStyle readerStatusBarTextStyle(Color textColor) => TextStyle(
  fontSize: kReaderStatusFooterFontSize,
  color: textColor.withValues(alpha: kReaderStatusBarTextAlpha),
  height: 1.0,
  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
);

/// 页眉 / 页脚的一个槽位：单行、超长省略，左槽靠左、中槽居中、右槽靠右。
class ReaderStatusBarSlotLabel extends StatelessWidget {
  const ReaderStatusBarSlotLabel({
    super.key,
    required this.text,
    required this.textAlign,
    required this.style,
  });

  final String? text;
  final TextAlign textAlign;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final String? value = text;
    if (value == null) return const SizedBox.shrink();
    return Text(
      value,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
      style: style,
    );
  }
}

/// 一条状态栏（页眉，或不含读数胶囊的页脚三格）：左 / 中 / 右三等分。
///
/// [trailing] 给页脚用：读数胶囊贴在右槽文字的右边（同一行，不另起一条）。
class ReaderStatusBarRow extends StatelessWidget {
  const ReaderStatusBarRow({
    super.key,
    required this.start,
    required this.center,
    required this.end,
    required this.style,
    this.trailing,
  });

  final String? start;
  final String? center;
  final String? end;
  final TextStyle style;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final Widget? tail = trailing;
    return Row(
      children: <Widget>[
        Expanded(
          child: ReaderStatusBarSlotLabel(
            key: const ValueKey<String>('fushi_status_bar_start'),
            text: start,
            textAlign: TextAlign.start,
            style: style,
          ),
        ),
        Expanded(
          child: ReaderStatusBarSlotLabel(
            key: const ValueKey<String>('fushi_status_bar_center'),
            text: center,
            textAlign: TextAlign.center,
            style: style,
          ),
        ),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              Flexible(
                child: ReaderStatusBarSlotLabel(
                  key: const ValueKey<String>('fushi_status_bar_end'),
                  text: end,
                  textAlign: TextAlign.end,
                  style: style,
                ),
              ),
              if (end != null && tail != null)
                const SizedBox(width: kReaderStatusBarTrailingGap),
              ?tail,
            ],
          ),
        ),
      ],
    );
  }
}
