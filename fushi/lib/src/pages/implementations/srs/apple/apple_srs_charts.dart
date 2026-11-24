/// Apple（Cupertino，iOS 27 / macOS 27）复习首页的图形件：Swift Charts 式柱图、
/// Activity 式单环、日历热力图、圆体数字与系统色板（2026-11-24 用户拍板方案 A，
/// 效果图 `build/srs_cupertino_design/index.html` 拍板点 4 / 5 / 7 / 8 / 9 / 10）。
///
/// 只被复习首页的 Apple 布局（`srs/apple/*.part.dart`）使用；M3E 不经过这里。
/// 本文件只画内容层图形（柱、环、方格、数字），不是系统控件，没有 M3E 分支；
/// 颜色一律取 Apple 系统色（[AppleSrsSystemColors] / `appleColorsOf`）。
///
/// 动效：环从 0 转到当前值、柱从底部长出，时长取 [fushiMotionDuration]（减弱动效
/// 与墨水屏时为 0，直接画终值）。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';

/// UIKit 系统色（动态色的 light / dark 两档，HIG「Color」）。复习首页的三色计数
/// （新 blue / 学习中 red / 待复习 green）、RWKV 三档（red / orange / green）与
/// 牌组图标色板都取这里——强调色可能是单色（默认主题黑 / 白），不能拿来当
/// 「新词蓝」。
@immutable
class AppleSrsSystemColors {
  const AppleSrsSystemColors._({
    required this.blue,
    required this.red,
    required this.green,
    required this.orange,
    required this.yellow,
    required this.cyan,
    required this.indigo,
    required this.purple,
    required this.pink,
    required this.gray,
  });

  factory AppleSrsSystemColors.of(BuildContext context) =>
      Theme.of(context).colorScheme.brightness == Brightness.dark
      ? _dark
      : _light;

  static const AppleSrsSystemColors _light = AppleSrsSystemColors._(
    blue: Color(0xFF007AFF),
    red: Color(0xFFFF3B30),
    green: Color(0xFF34C759),
    orange: Color(0xFFFF9500),
    yellow: Color(0xFFFFCC00),
    cyan: Color(0xFF32ADE6),
    indigo: Color(0xFF5856D6),
    purple: Color(0xFFAF52DE),
    pink: Color(0xFFFF2D55),
    gray: Color(0xFF8E8E93),
  );

  static const AppleSrsSystemColors _dark = AppleSrsSystemColors._(
    blue: Color(0xFF0A84FF),
    red: Color(0xFFFF453A),
    green: Color(0xFF30D158),
    orange: Color(0xFFFF9F0A),
    yellow: Color(0xFFFFD60A),
    cyan: Color(0xFF64D2FF),
    indigo: Color(0xFF5E5CE6),
    purple: Color(0xFFBF5AF2),
    pink: Color(0xFFFF375F),
    gray: Color(0xFF8E8E93),
  );

  final Color blue;
  final Color red;
  final Color green;
  final Color orange;
  final Color yellow;
  final Color cyan;
  final Color indigo;
  final Color purple;
  final Color pink;
  final Color gray;

  /// Reminders 列表图标的 8 色板（顺序固定：映射靠下标，改顺序会让所有牌组换色）。
  List<Color> get deckPalette => <Color>[
    red,
    orange,
    yellow,
    green,
    cyan,
    blue,
    indigo,
    purple,
  ];
}

/// 牌组图标色（拍板点 8）：按牌组 id 稳定映射到系统色板 8 选 1（FNV-1a，跨平台
/// 跨运行一致；改名不换色，因为 id 不变）。卡片与行背景不用它。
Color appleSrsDeckColor(BuildContext context, String deckId) {
  final List<Color> palette = AppleSrsSystemColors.of(context).deckPalette;
  return palette[appleSrsDeckColorIndex(deckId, palette.length)];
}

/// [appleSrsDeckColor] 的下标（纯函数，测试钉映射稳定）。
@visibleForTesting
int appleSrsDeckColorIndex(String deckId, int paletteSize) {
  int hash = 0x811C9DC5;
  for (final int unit in deckId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash % paletteSize;
}

/// Apple 平台的 SF Rounded 系统字族（macOS `SFNSRounded.ttf` 的家族名；iOS 同族名
/// 找不到时按 [_kAppleRoundedFallback] 退）。只在主题平台是 iOS / macOS 时用；不随包。
const String _kAppleRoundedFamily = '.SF NS Rounded';
const List<String> _kAppleRoundedFallback = <String>[
  '.SF UI Rounded',
  '.AppleSystemUIFontRounded',
];

/// 圆体数字（拍板点 10）：iOS / macOS 用系统 SF Rounded；Windows / Android 等
/// 没有 SF Rounded、也不许随包分发 SF 字体，退回 [base] 自己的字族 + 等宽数字。
/// 两边都加 tabular figures，数字变化时不跳宽。
TextStyle appleSrsRounded(BuildContext context, TextStyle base) {
  final TargetPlatform platform = Theme.of(context).platform;
  final bool applePlatform =
      platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
  const List<FontFeature> tabular = <FontFeature>[FontFeature.tabularFigures()];
  if (!applePlatform) return base.copyWith(fontFeatures: tabular);
  final String? own = base.fontFamily;
  return base.copyWith(
    fontFamily: _kAppleRoundedFamily,
    fontFamilyFallback: <String>[
      ..._kAppleRoundedFallback,
      ?own,
      ...?base.fontFamilyFallback,
    ],
    fontFeatures: tabular,
  );
}

/// 「今日」单环（拍板点 9，Activity 式）：[value]（0–1）一圈 [color] 圆头弧，
/// 底下同色 18% 轨道；入场从 0 转到当前值，值变化时从旧值转到新值。
class AppleSrsRing extends StatelessWidget {
  const AppleSrsRing({
    super.key,
    required this.value,
    required this.color,
    this.size = 88,
    this.stroke = 12,
    this.child,
  });

  final double value;
  final Color color;
  final double size;
  final double stroke;

  /// 环心内容（百分比）。
  final Widget? child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: value.clamp(0.0, 1.0)),
    duration: fushiMotionDuration(context, FushiMotion.long),
    curve: FushiMotion.enter,
    builder: (BuildContext context, double v, Widget? inner) => CustomPaint(
      painter: _AppleRingPainter(progress: v, color: color, stroke: stroke),
      child: SizedBox.square(
        dimension: size,
        child: Center(child: inner),
      ),
    ),
    child: child,
  );
}

class _AppleRingPainter extends CustomPainter {
  const _AppleRingPainter({
    required this.progress,
    required this.color,
    required this.stroke,
  });

  final double progress;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = (Offset.zero & size).deflate(stroke / 2);
    final Paint track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color.withValues(alpha: 0.18);
    canvas.drawArc(rect, 0, math.pi * 2, false, track);
    if (progress <= 0) return;
    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * progress, false, arc);
  }

  @override
  bool shouldRepaint(_AppleRingPainter old) =>
      old.progress != progress || old.color != color || old.stroke != stroke;
}

/// 柱图的一根柱。
@immutable
class AppleSrsBar {
  const AppleSrsBar({
    required this.value,
    required this.title,
    this.label,
    this.color,
  });

  final int value;

  /// 点按 / 悬停时注记里的说明（「11/24 · 12 次复习」）。
  final String title;

  /// 横轴刻度；null = 这根不标。
  final String? label;

  /// 单柱颜色；null = 图表的 [AppleSrsBarChart.color]。
  final Color? color;
}

/// Swift Charts 式柱图（拍板点 4）：顶端圆角的 BarMark、y 轴刻度在右侧、横向细网格；
/// 可选一条水平虚线 RuleMark（[average]，如「日均 27」）或一条竖直虚线 RuleMark
/// （[ruleAt]，0–1 的横向位置，如目标保留率「目标 90%」，注记在线顶）。入场柱从
/// 底部长出；点按 / 悬停一根柱在图顶弹出注记（Swift Charts 的 selection
/// annotation），再点同一根收起。
class AppleSrsBarChart extends StatefulWidget {
  const AppleSrsBarChart({
    super.key,
    required this.bars,
    required this.color,
    this.height = 96,
    this.average,
    this.averageLabel,
    this.ruleAt,
    this.ruleLabel,
    this.highlightLast = false,
    this.barWidthFactor = 0.56,
    this.edgeLabels = false,
    this.semanticLabel,
  });

  final List<AppleSrsBar> bars;
  final Color color;
  final double height;

  /// 水平虚线的 y 值与注记。
  final double? average;
  final String? averageLabel;

  /// 竖直虚线的横向位置（0 = 第一根柱左缘，1 = 最后一根右缘）与线顶注记。
  final double? ruleAt;
  final String? ruleLabel;

  /// 只有最后一根（今天）实色，其余 55%。
  final bool highlightLast;

  /// 柱宽占格宽的比例。
  final double barWidthFactor;

  /// 刻度文字靠格左缘（直方图的区间起点），默认居中。
  final bool edgeLabels;

  /// 整张图的读屏摘要。
  final String? semanticLabel;

  @override
  State<AppleSrsBarChart> createState() => _AppleSrsBarChartState();
}

class _AppleSrsBarChartState extends State<AppleSrsBarChart> {
  int? _selected;

  /// y 轴右侧刻度区宽。
  static const double _axisWidth = 28;

  /// 底部刻度行高。
  static const double _tickHeight = 18;

  int? _indexAt(Offset local, double width) {
    final int n = widget.bars.length;
    if (n == 0) return null;
    final double plot = width - _axisWidth;
    if (local.dx < 0 || local.dx > plot) return null;
    return (local.dx / plot * n).floor().clamp(0, n - 1);
  }

  void _select(int? index, {bool toggle = false}) {
    final int? next = toggle && index == _selected ? null : index;
    if (next == _selected) return;
    setState(() => _selected = next);
  }

  @override
  void didUpdateWidget(AppleSrsBarChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    final int? s = _selected;
    if (s != null && s >= widget.bars.length) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final TextStyle tick =
        (Theme.of(context).textTheme.labelSmall ?? const TextStyle()).copyWith(
          height: 1.1,
          letterSpacing: 0,
          color: apple.secondaryLabel,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );
    final TextStyle annotation = tick.copyWith(
      fontWeight: FontWeight.w600,
      color: apple.label,
    );
    final int? selected = _selected;
    final bool topRoom = widget.ruleAt != null && widget.ruleLabel != null;
    return Semantics(
      container: true,
      label: widget.semanticLabel,
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final double width = box.maxWidth;
            final Widget chart = TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: fushiMotionDuration(context, FushiMotion.medium),
              curve: FushiMotion.enter,
              builder: (BuildContext context, double grow, Widget? _) =>
                  CustomPaint(
                    size: Size(width, widget.height),
                    painter: _AppleBarPainter(
                      bars: widget.bars,
                      color: widget.color,
                      grow: grow,
                      selected: selected,
                      highlightLast: widget.highlightLast,
                      barWidthFactor: widget.barWidthFactor,
                      edgeLabels: widget.edgeLabels,
                      average: widget.average,
                      averageLabel: widget.averageLabel,
                      ruleAt: widget.ruleAt,
                      ruleLabel: widget.ruleLabel,
                      topRoom: topRoom ? 16 : 6,
                      grid: apple.separator,
                      ruleColor: apple.label,
                      avgColor: apple.secondaryLabel,
                      tickStyle: tick,
                      annotationStyle: annotation,
                      textDirection: Directionality.of(context),
                      axisWidth: _axisWidth,
                      tickHeight: _tickHeight,
                    ),
                  ),
            );
            final Widget? callout = selected == null
                ? null
                : _callout(context, selected, width, annotation);
            return MouseRegion(
              onHover: (PointerHoverEvent e) =>
                  _select(_indexAt(e.localPosition, width)),
              onExit: (_) => _select(null),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (TapDownDetails d) =>
                    _select(_indexAt(d.localPosition, width), toggle: true),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[chart, ?callout],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _callout(
    BuildContext context,
    int index,
    double width,
    TextStyle style,
  ) {
    final FushiAppleColors apple = appleColorsOf(context);
    final int n = widget.bars.length;
    final double plot = width - _axisWidth;
    final double center = plot / n * (index + 0.5);
    // 注记贴在柱的正上方，左右夹在图内。
    final double x = width <= 0 ? 0 : (center / width).clamp(0.0, 1.0);
    final AppleSrsBar bar = widget.bars[index];
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: Alignment(x * 2 - 1, -1),
          child: FractionalTranslation(
            translation: const Offset(0, -1.05),
            child: DecoratedBox(
              key: const ValueKey<String>('apple-srs-chart-callout'),
              decoration: ShapeDecoration(
                color: apple.tertiaryGroupedBackground,
                shape: const StadiumBorder(),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text(
                  bar.title,
                  maxLines: 1,
                  style: style,
                  semanticsLabel: bar.title,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「好看的」刻度步长：max / 3 取 1 / 2 / 5 × 10^k。
int _niceStep(int max) {
  if (max <= 3) return 1;
  final double raw = max / 3;
  final double m = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final double f = raw / m;
  final double step = (f <= 1 ? 1 : (f <= 2 ? 2 : (f <= 5 ? 5 : 10))) * m;
  return math.max(1, step.round());
}

class _AppleBarPainter extends CustomPainter {
  _AppleBarPainter({
    required this.bars,
    required this.color,
    required this.grow,
    required this.selected,
    required this.highlightLast,
    required this.barWidthFactor,
    required this.edgeLabels,
    required this.average,
    required this.averageLabel,
    required this.ruleAt,
    required this.ruleLabel,
    required this.topRoom,
    required this.grid,
    required this.ruleColor,
    required this.avgColor,
    required this.tickStyle,
    required this.annotationStyle,
    required this.textDirection,
    required this.axisWidth,
    required this.tickHeight,
  });

  final List<AppleSrsBar> bars;
  final Color color;
  final double grow;
  final int? selected;
  final bool highlightLast;
  final double barWidthFactor;
  final bool edgeLabels;
  final double? average;
  final String? averageLabel;
  final double? ruleAt;
  final String? ruleLabel;
  final double topRoom;
  final Color grid;
  final Color ruleColor;
  final Color avgColor;
  final TextStyle tickStyle;
  final TextStyle annotationStyle;
  final TextDirection textDirection;
  final double axisWidth;
  final double tickHeight;

  void _text(
    Canvas canvas,
    String text,
    TextStyle style,
    Offset at, {
    double alignX = 0,
  }) {
    final TextPainter p = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      maxLines: 1,
    )..layout();
    p.paint(canvas, at - Offset(p.width * alignX, 0));
    p.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final int n = bars.length;
    final double plotW = size.width - axisWidth;
    final double plotH = size.height - tickHeight - topRoom;
    if (n == 0 || plotW <= 0 || plotH <= 0) return;
    int top = 0;
    for (final AppleSrsBar b in bars) {
      top = math.max(top, b.value);
    }
    final double avg = average ?? 0;
    top = math.max(top, avg.ceil());
    final int step = _niceStep(math.max(1, top));
    final int axisMax = math.max(step, (top / step).ceil() * step);
    double yOf(double v) => topRoom + plotH - plotH * v / axisMax;

    // 横向网格 + 右侧刻度。
    final Paint gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 0.5;
    for (int v = 0; v <= axisMax; v += step) {
      final double y = yOf(v.toDouble());
      canvas.drawLine(Offset(0, y), Offset(plotW, y), gridPaint);
      _text(canvas, '$v', tickStyle, Offset(plotW + 6, y - 6));
    }

    final double slot = plotW / n;
    final double barW = slot * barWidthFactor;
    final Radius radius = Radius.circular(math.min(4, barW / 2));
    for (int i = 0; i < n; i++) {
      final AppleSrsBar b = bars[i];
      final double cx = slot * (i + 0.5);
      final double h = plotH * b.value / axisMax * grow;
      if (h > 0) {
        final Color base = b.color ?? color;
        final bool dim =
            (highlightLast && i != n - 1) ||
            (selected != null && selected != i);
        final Paint p = Paint()
          ..color = dim ? base.withValues(alpha: base.a * 0.55) : base;
        final Rect r = Rect.fromLTWH(
          cx - barW / 2,
          topRoom + plotH - h,
          barW,
          h,
        );
        canvas.drawRRect(
          RRect.fromRectAndCorners(r, topLeft: radius, topRight: radius),
          p,
        );
      }
      final String? label = b.label;
      if (label != null) {
        _text(
          canvas,
          label,
          tickStyle,
          Offset(edgeLabels ? slot * i : cx, size.height - tickHeight + 4),
          alignX: edgeLabels ? 0 : 0.5,
        );
      }
    }

    final Paint dashed = Paint()..strokeWidth = 1.2;
    final double? avgValue = average;
    if (avgValue != null && avgValue > 0) {
      final double y = yOf(avgValue);
      dashed.color = avgColor;
      _dash(canvas, Offset(0, y), Offset(plotW, y), dashed);
      final String? text = averageLabel;
      if (text != null) {
        _text(
          canvas,
          text,
          annotationStyle.copyWith(color: avgColor),
          Offset(2, y - 14),
        );
      }
    }
    final double? at = ruleAt;
    if (at != null) {
      final double x = plotW * at.clamp(0.0, 1.0);
      dashed.color = ruleColor.withValues(alpha: 0.7);
      _dash(canvas, Offset(x, topRoom - 4), Offset(x, topRoom + plotH), dashed);
      final String? text = ruleLabel;
      if (text != null) {
        _text(
          canvas,
          text,
          annotationStyle,
          Offset(x - 4, 0),
          alignX: x > plotW / 2 ? 1 : 0,
        );
      }
    }
  }

  void _dash(Canvas canvas, Offset a, Offset b, Paint paint) {
    const double on = 4, off = 3;
    final double length = (b - a).distance;
    if (length <= 0) return;
    final Offset dir = (b - a) / length;
    double d = 0;
    while (d < length) {
      final double e = math.min(d + on, length);
      canvas.drawLine(a + dir * d, a + dir * e, paint);
      d = e + off;
    }
  }

  @override
  bool shouldRepaint(_AppleBarPainter old) =>
      old.grow != grow ||
      old.selected != selected ||
      old.bars != bars ||
      old.color != color ||
      old.average != average ||
      old.ruleAt != ruleAt ||
      old.grid != grid ||
      old.tickStyle != tickStyle;
}

/// 学习日历热力图（拍板点 5）：近 [weeks] 周（手机 16、宽屏 26），每列一周
/// （周日在上），圆角小方格；0 次 = systemFill 灰，有复习按当期最大值分四档
/// systemGreen 透明度；今天描一圈强调色；月份写在列顶（caption2）。点按 /
/// 悬停一格在图下写「日期 · N 次」（[countLabel]），右下是「少 ■■■■■ 多」图例。
class AppleSrsHeatmap extends StatefulWidget {
  const AppleSrsHeatmap({
    super.key,
    required this.countsByDay,
    required this.today,
    required this.weeks,
    required this.dateOf,
    required this.dayLabel,
    required this.monthLabel,
    required this.countLabel,
    required this.lessLabel,
    required this.moreLabel,
    this.maxCell = 14,
  });

  /// 日序号 → 当天复习次数。
  final Map<int, int> countsByDay;
  final int today;
  final int weeks;

  /// 日序号 → 日期（取星期几与月份）。
  final DateTime Function(int day) dateOf;
  final String Function(int day) dayLabel;
  final String Function(int day) monthLabel;
  final String Function(int count) countLabel;
  final String lessLabel;
  final String moreLabel;

  /// 方格边长上限（宽度富余时不再放大）。
  final double maxCell;

  @override
  State<AppleSrsHeatmap> createState() => _AppleSrsHeatmapState();
}

/// 四档绿色的不透明度（叠在 systemFill 上）。
const List<double> _kHeatLevels = <double>[0.30, 0.55, 0.78, 1.0];

class _AppleSrsHeatmapState extends State<AppleSrsHeatmap> {
  int? _selectedDay;

  /// 今天在本周列里的行（周日 = 0）。
  int get _todayRow => widget.dateOf(widget.today).weekday % 7;

  /// 第一列第一格（周日）的日序号。
  int get _firstDay => widget.today - _todayRow - (widget.weeks - 1) * 7;

  int _levelOf(int count, int max) {
    if (count <= 0 || max <= 0) return 0;
    return (count * 4 / max).ceil().clamp(1, 4);
  }

  int? _dayAt(Offset local, double cell, double gap) {
    final int col = (local.dx / (cell + gap)).floor();
    final int row = (local.dy / (cell + gap)).floor();
    if (col < 0 || col >= widget.weeks || row < 0 || row > 6) return null;
    final int day = _firstDay + col * 7 + row;
    return day > widget.today ? null : day;
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final AppleSrsSystemColors system = AppleSrsSystemColors.of(context);
    final TextStyle caption =
        (Theme.of(context).textTheme.labelSmall ?? const TextStyle()).copyWith(
          letterSpacing: 0,
          height: 1.2,
          color: apple.secondaryLabel,
        );
    final Color fill = Color.alphaBlend(
      apple.fill,
      apple.secondaryGroupedBackground,
    );
    Color shade(int level) => level == 0
        ? fill
        : Color.lerp(fill, system.green, _kHeatLevels[level - 1])!;
    int max = 0;
    for (int d = _firstDay; d <= widget.today; d++) {
      max = math.max(max, widget.countsByDay[d] ?? 0);
    }
    final int? sel = _selectedDay;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final int weeks = widget.weeks;
        final double gap = box.maxWidth / weeks > 16 ? 4 : 3;
        final double cell = math.min(
          widget.maxCell,
          (box.maxWidth - gap * (weeks - 1)) / weeks,
        );
        final double gridW = cell * weeks + gap * (weeks - 1);
        final double gridH = cell * 7 + gap * 6;
        final List<Widget> months = <Widget>[];
        for (int w = 1; w < weeks - 1; w++) {
          final int day = _firstDay + w * 7;
          if (widget.dateOf(day).month != widget.dateOf(day - 7).month) {
            months.add(
              Positioned(
                left: w * (cell + gap),
                top: 0,
                child: Text(widget.monthLabel(day), style: caption),
              ),
            );
          }
        }
        final Widget grid = MouseRegion(
          onHover: (PointerHoverEvent e) {
            final int? d = _dayAt(e.localPosition, cell, gap);
            if (d != _selectedDay) setState(() => _selectedDay = d);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (TapDownDetails details) {
              final int? d = _dayAt(details.localPosition, cell, gap);
              setState(() => _selectedDay = d == _selectedDay ? null : d);
            },
            child: CustomPaint(
              size: Size(gridW, gridH),
              painter: _AppleHeatPainter(
                firstDay: _firstDay,
                today: widget.today,
                weeks: weeks,
                cell: cell,
                gap: gap,
                levelOf: (int day) =>
                    _levelOf(widget.countsByDay[day] ?? 0, max),
                shade: shade,
                todayRing: apple.accent,
                selectedDay: sel,
                selectedRing: apple.label,
              ),
            ),
          ),
        );
        final String? callout = sel == null
            ? null
            : '${widget.dayLabel(sel)} · '
                  '${widget.countLabel(widget.countsByDay[sel] ?? 0)}';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: gridW,
              height: 16,
              child: Stack(clipBehavior: Clip.none, children: months),
            ),
            grid,
            const SizedBox(height: 8),
            SizedBox(
              width: gridW,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: callout == null
                        ? const SizedBox.shrink()
                        : Text(
                            callout,
                            key: const ValueKey<String>(
                              'apple-srs-heatmap-callout',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: caption.copyWith(
                              color: apple.label,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                  ExcludeSemantics(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 3,
                      children: <Widget>[
                        Text(widget.lessLabel, style: caption),
                        for (int level = 0; level <= 4; level++)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: shade(level),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: const SizedBox.square(dimension: 9),
                          ),
                        Text(widget.moreLabel, style: caption),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AppleHeatPainter extends CustomPainter {
  _AppleHeatPainter({
    required this.firstDay,
    required this.today,
    required this.weeks,
    required this.cell,
    required this.gap,
    required this.levelOf,
    required this.shade,
    required this.todayRing,
    required this.selectedDay,
    required this.selectedRing,
  });

  final int firstDay;
  final int today;
  final int weeks;
  final double cell;
  final double gap;
  final int Function(int day) levelOf;
  final Color Function(int level) shade;
  final Color todayRing;
  final int? selectedDay;
  final Color selectedRing;

  @override
  void paint(Canvas canvas, Size size) {
    final Radius r = Radius.circular(cell > 10 ? 3 : 2.5);
    final Paint p = Paint();
    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (int w = 0; w < weeks; w++) {
      for (int row = 0; row < 7; row++) {
        final int day = firstDay + w * 7 + row;
        if (day > today) continue;
        final Rect rect = Rect.fromLTWH(
          w * (cell + gap),
          row * (cell + gap),
          cell,
          cell,
        );
        p.color = shade(levelOf(day));
        canvas.drawRRect(RRect.fromRectAndRadius(rect, r), p);
        if (day == today || day == selectedDay) {
          ring.color = day == selectedDay ? selectedRing : todayRing;
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              rect.inflate(1.5),
              r + const Radius.circular(1),
            ),
            ring,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_AppleHeatPainter old) =>
      old.firstDay != firstDay ||
      old.today != today ||
      old.cell != cell ||
      old.selectedDay != selectedDay ||
      old.todayRing != todayRing ||
      old.levelOf != levelOf;
}
