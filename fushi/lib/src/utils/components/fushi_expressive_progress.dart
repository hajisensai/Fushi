import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';

// Material 3 Expressive（2025-05）的进度与加载指示，自绘实现。
//
// Flutter 3.44 内核只带了 Expressive 的配色变体，没有 Expressive 组件（波浪
// 进度条 / LoadingIndicator），所以这里按 M3 Expressive 规格自绘，只给 MD3
// 设计系统用（Apple 设计系统走 iOS / macOS 形态，见 glass/fushi_glass_feedback）：
//
// - [FushiWavyLinearProgress]：线性进度。确定态已填段是正弦波（振幅 3、波长
//   40、线宽 4、圆头），波形缓慢向前流动，进度接近 0 / 1 时振幅收平；轨道是
//   直线，与已填段之间留缝，尾端一个停止点。不定态是两段波浪沿轨道滑动。
// - [FushiWavyCircularProgress]：圆形进度。波浪绕环一周（振幅 1.6、波长约
//   15），确定态带缝 + 直线底环；不定态是一段长度呼吸、整体旋转的波浪弧。
// - [FushiExpressiveLoadingIndicator]：不定态「加载」——主色形状在圆角多边形
//   之间连续变形并旋转（软圆 → 7 瓣饼干 → 五边形 → 胶囊 → 9 瓣饼干 → 太阳），
//   可选 primaryContainer 圆底（contained）。变形 = 两个形状按同一组 N 个角度
//   采样极径后逐点插值，节拍用带回弹的弹簧感曲线。
//
// 每个控件只有一个 AnimationController，画在 RepaintBoundary 里；系统「减少
// 动态效果」（MediaQuery.disableAnimations）时退回直线 / 静止、不跑动画。
// 墨水屏不用这里（调用方退回 Material 原控件的墨水屏处理）。

/// 是否允许动画（系统「减少动态效果」时为 false）。
bool _motionAllowed(BuildContext context) =>
    !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

/// 按需启停的单个 repeat 控制器：只在需要动画时跑，避免常驻 ticker。
mixin _RepeatingTicker<T extends StatefulWidget>
    on State<T>, SingleTickerProviderStateMixin<T> {
  AnimationController? _ticker;

  Duration get tickerPeriod;

  bool wantsAnimation(BuildContext context);

  AnimationController? get ticker => _ticker;

  void syncTicker() {
    if (wantsAnimation(context)) {
      final AnimationController c = _ticker ??= AnimationController(
        vsync: this,
        duration: tickerPeriod,
      );
      if (!c.isAnimating) c.repeat();
    } else {
      _ticker?.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncTicker();
  }

  @override
  void didUpdateWidget(T oldWidget) {
    super.didUpdateWidget(oldWidget);
    syncTicker();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }
}

/// 进度接近两端时振幅收平的系数（M3 Expressive：起步与收尾是直线）。
double _amplitudeEase(double value) {
  final double head = (value / 0.1).clamp(0.0, 1.0);
  final double tail = ((1 - value) / 0.05).clamp(0.0, 1.0);
  return Curves.easeInOut.transform(math.min(head, tail));
}

// ---------------------------------------------------------------------------
// 线性
// ---------------------------------------------------------------------------

/// M3 Expressive 波浪线性进度条，撑满父级宽度（与 Material 线性进度条一致）。
///
/// 布局高度 = 线宽 + 2 × 振幅（默认 4 + 6 = 10）；父级高度不够时振幅自动压小
/// 以适配（极端情况下退成直线），不撑破调用点原有的布局。
class FushiWavyLinearProgress extends StatefulWidget {
  const FushiWavyLinearProgress({
    super.key,
    this.value,
    required this.color,
    required this.trackColor,
    this.strokeWidth = 4,
    this.trackGap = 4,
    this.stopIndicatorColor,
    this.stopIndicatorRadius,
    this.semanticsLabel,
    this.semanticsValue,
    this.waving = true,
  });

  final double? value;
  final Color color;
  final Color trackColor;
  final double strokeWidth;
  final double trackGap;

  /// false = 已填段收平成直线、停止流动（确定态；如有声书暂停时）。振幅以
  /// 300ms 过渡收放，恢复时重新起波。不定态忽略。
  final bool waving;

  /// 尾端停止点颜色；null = 与已填段同色，透明 = 不画。
  final Color? stopIndicatorColor;
  final double? stopIndicatorRadius;
  final String? semanticsLabel;
  final String? semanticsValue;

  static const double amplitude = 3;
  static const double wavelength = 40;

  @override
  State<FushiWavyLinearProgress> createState() =>
      _FushiWavyLinearProgressState();
}

class _FushiWavyLinearProgressState extends State<FushiWavyLinearProgress>
    with
        SingleTickerProviderStateMixin<FushiWavyLinearProgress>,
        _RepeatingTicker<FushiWavyLinearProgress> {
  // 不定态一轮 1.8 秒（与 Material 线性不定态同节拍）；确定态复用同一个控制器
  // 推波形相位（一轮流过一个波长）。
  @override
  Duration get tickerPeriod => const Duration(milliseconds: 1800);

  // 确定态在两端振幅收平成直线（[_amplitudeEase] 为 0），相位流动看不见，
  // 不跑控制器——否则「已看完」贴底满条这类静止装饰会永远每帧重绘。
  @override
  bool wantsAnimation(BuildContext context) {
    if (!_motionAllowed(context)) return false;
    final double? value = widget.value;
    if (value != null && !widget.waving) return false;
    return value == null || _amplitudeEase(value.clamp(0.0, 1.0)) > 0;
  }

  @override
  Widget build(BuildContext context) {
    final double? value = widget.value;
    final bool motion = _motionAllowed(context);
    final double stroke = widget.strokeWidth;
    final double amp = motion ? FushiWavyLinearProgress.amplitude : 0;
    return Semantics(
      label: widget.semanticsLabel,
      value:
          widget.semanticsValue ??
          (value == null ? null : '${(value.clamp(0.0, 1.0) * 100).round()}%'),
      // 不用 LayoutBuilder（它不支持固有尺寸查询，放进 IntrinsicHeight 等会抛）：
      // 高度在 [线宽, 线宽 + 2 × 振幅] 之间由父约束决定，画家按实际高度收振幅。
      child: RepaintBoundary(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: double.infinity,
            minHeight: stroke,
            maxHeight: stroke + amp * 2,
          ),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(
              end: value != null && !widget.waving ? 0 : amp,
            ),
            duration: motion
                ? const Duration(milliseconds: 300)
                : Duration.zero,
            curve: Curves.easeOut,
            builder: (BuildContext context, double liveAmp, Widget? _) {
              return TweenAnimationBuilder<double>(
                tween: Tween<double>(end: (value ?? 0).clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                builder:
                    (BuildContext context, double animatedValue, Widget? _) {
                      return CustomPaint(
                        size: Size(double.infinity, stroke + amp * 2),
                        painter: _WavyLinearPainter(
                          progress: ticker,
                          value: value == null ? null : animatedValue,
                          color: widget.color,
                          trackColor: widget.trackColor,
                          stopColor: widget.stopIndicatorColor ?? widget.color,
                          stopRadius: widget.stopIndicatorRadius ?? stroke / 2,
                          strokeWidth: stroke,
                          gap: widget.trackGap,
                          amplitude: liveAmp,
                          rtl: Directionality.of(context) == TextDirection.rtl,
                        ),
                      );
                    },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _WavyLinearPainter extends CustomPainter {
  _WavyLinearPainter({
    required this.progress,
    required this.value,
    required this.color,
    required this.trackColor,
    required this.stopColor,
    required this.stopRadius,
    required this.strokeWidth,
    required this.gap,
    required this.amplitude,
    required this.rtl,
  }) : super(repaint: progress);

  final Animation<double>? progress;
  final double? value;
  final Color color;
  final Color trackColor;
  final Color stopColor;
  final double stopRadius;
  final double strokeWidth;
  final double gap;
  final double amplitude;
  final bool rtl;

  // Material 线性不定态的两段线头 / 线尾节拍（1800ms 一轮）。
  static const Curve _line1Head = Interval(
    0,
    750 / 1800,
    curve: Cubic(0.2, 0, 0.8, 1),
  );
  static const Curve _line1Tail = Interval(
    333 / 1800,
    (333 + 750) / 1800,
    curve: Cubic(0.4, 0, 1, 1),
  );
  static const Curve _line2Head = Interval(
    1000 / 1800,
    (1000 + 567) / 1800,
    curve: Cubic(0, 0, 0.65, 1),
  );
  static const Curve _line2Tail = Interval(
    1267 / 1800,
    (1267 + 533) / 1800,
    curve: Cubic(0.10, 0, 0.45, 1),
  );

  Paint _stroke(Color c) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidth
    ..strokeCap = StrokeCap.round
    ..color = c;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = progress?.value ?? 0;
    final double cy = size.height / 2;
    final double half = strokeWidth / 2;
    // 父级给的高度不够完整振幅时按实际高度收小（极端情况退成直线）。
    final double amplitude = math.min(
      this.amplitude,
      math.max(0, (size.height - strokeWidth) / 2),
    );
    // 圆头会伸出端点半个线宽：可画区间两端各内缩半个线宽。
    final double left = half;
    final double right = size.width - half;
    final double usable = right - left;
    if (usable <= 0) return;
    // 波形相位：一轮控制器流过一个波长（向进度方向流动）。
    final double phase = t * 2 * math.pi;

    double xOf(double f) => rtl ? right - usable * f : left + usable * f;

    void wave(double f0, double f1, double amp) {
      if (f1 - f0 <= 0) return;
      final double a = xOf(f0);
      final double b = xOf(f1);
      final double lo = math.min(a, b);
      final double hi = math.max(a, b);
      final Path path = Path();
      final double dir = rtl ? -1 : 1;
      double yAt(double x) =>
          cy +
          amp *
              math.sin(
                2 * math.pi * (x * dir) / FushiWavyLinearProgress.wavelength -
                    phase,
              );
      path.moveTo(lo, yAt(lo));
      for (double x = lo + 1; x < hi; x += 1) {
        path.lineTo(x, yAt(x));
      }
      path.lineTo(hi, yAt(hi));
      canvas.drawPath(path, _stroke(color));
    }

    void line(double f0, double f1, Color c) {
      if (f1 - f0 <= 0) return;
      canvas.drawLine(Offset(xOf(f0), cy), Offset(xOf(f1), cy), _stroke(c));
    }

    // 缝（含两侧圆头）换算成分数。
    final double gapF = (gap + strokeWidth) / usable;
    final double? v = value;
    if (v != null) {
      final double amp = amplitude * _amplitudeEase(v);
      if (v > 0) wave(0, v, amp);
      final double trackStart = v <= 0 ? 0 : v + gapF;
      if (trackStart < 1) line(trackStart, 1, trackColor);
      // 停止点：轨道尾端一个已填色小圆点（进度到头后被已填段盖住）。
      if (stopColor.a > 0 && v < 1) {
        canvas.drawCircle(
          Offset(xOf(1), cy),
          math.min(stopRadius, half),
          Paint()..color = stopColor,
        );
      }
      return;
    }

    // 不定态：两段波浪沿轨道滑动，空处是带缝的直线轨道。
    final List<(double, double)> segments = <(double, double)>[
      (_line1Tail.transform(t), _line1Head.transform(t)),
      (_line2Tail.transform(t), _line2Head.transform(t)),
    ];
    double cursor = 0;
    for (final (double s, double e) in segments) {
      if (e - s <= 0.001) continue;
      line(cursor, s - gapF, trackColor);
      wave(s, e, amplitude);
      cursor = e + gapF;
    }
    line(cursor, 1, trackColor);
  }

  @override
  bool shouldRepaint(_WavyLinearPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.stopColor != stopColor ||
      oldDelegate.stopRadius != stopRadius ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.gap != gap ||
      oldDelegate.amplitude != amplitude ||
      oldDelegate.rtl != rtl ||
      oldDelegate.progress != progress;
}

// ---------------------------------------------------------------------------
// 圆形
// ---------------------------------------------------------------------------

/// M3 Expressive 波浪圆形进度。默认外框 40、内边距 4（与 Flutter M3 2024 版
/// CircularProgressIndicator 的布局尺寸一致，替换后不跳布局）；父级紧约束更小
/// 时跟着缩，线宽与振幅等比收小。
class FushiWavyCircularProgress extends StatefulWidget {
  const FushiWavyCircularProgress({
    super.key,
    this.value,
    required this.color,
    required this.trackColor,
    this.strokeWidth = 4,
    this.trackGap = 4,
    this.size = 40,
    this.padding = const EdgeInsets.all(4),
    this.semanticsLabel,
    this.semanticsValue,
  });

  final double? value;
  final Color color;
  final Color trackColor;
  final double strokeWidth;
  final double trackGap;
  final double size;
  final EdgeInsetsGeometry padding;
  final String? semanticsLabel;
  final String? semanticsValue;

  @override
  State<FushiWavyCircularProgress> createState() =>
      _FushiWavyCircularProgressState();
}

class _FushiWavyCircularProgressState extends State<FushiWavyCircularProgress>
    with
        SingleTickerProviderStateMixin<FushiWavyCircularProgress>,
        _RepeatingTicker<FushiWavyCircularProgress> {
  // 不定态：一轮 8 秒里 6 次「伸长—收缩」呼吸（每次 1.333 秒，与 Material
  // 圆形不定态同节拍）；确定态同一个控制器推波形相位。
  @override
  Duration get tickerPeriod => const Duration(milliseconds: 8000);

  @override
  bool wantsAnimation(BuildContext context) => _motionAllowed(context);

  @override
  Widget build(BuildContext context) {
    final double? value = widget.value;
    final bool motion = _motionAllowed(context);
    return Semantics(
      label: widget.semanticsLabel,
      value:
          widget.semanticsValue ??
          (value == null ? null : '${(value.clamp(0.0, 1.0) * 100).round()}%'),
      child: SizedBox.square(
        dimension: widget.size,
        child: Padding(
          padding: widget.padding,
          child: RepaintBoundary(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: (value ?? 0).clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              builder: (BuildContext context, double animatedValue, Widget? _) {
                return CustomPaint(
                  painter: _WavyCircularPainter(
                    progress: ticker,
                    value: value == null ? null : animatedValue,
                    color: widget.color,
                    trackColor: widget.trackColor,
                    strokeWidth: widget.strokeWidth,
                    gap: widget.trackGap,
                    wavy: motion,
                    clockwise: Directionality.of(context) != TextDirection.rtl,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _WavyCircularPainter extends CustomPainter {
  _WavyCircularPainter({
    required this.progress,
    required this.value,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
    required this.gap,
    required this.wavy,
    required this.clockwise,
  }) : super(repaint: progress);

  final Animation<double>? progress;
  final double? value;
  final Color color;
  final Color trackColor;
  final double strokeWidth;
  final double gap;
  final bool wavy;
  final bool clockwise;

  @override
  void paint(Canvas canvas, Size size) {
    final double side = math.min(size.width, size.height);
    if (side <= 0) return;
    // 小尺寸（调用点塞进 14~20 的格子）时线宽 / 振幅按 32 的基准等比缩。
    final double k = (side / 32).clamp(0.0, 1.0);
    final double stroke = math.max(1.5, strokeWidth * k);
    final double amp = wavy ? 1.6 * k : 0;
    final Offset c = size.center(Offset.zero);
    final double radius = side / 2 - stroke / 2 - amp;
    if (radius <= 0) return;
    // 波长约 15：按周长取整数个波，首尾接得上。
    final int waves = math.max(3, (2 * math.pi * radius / 15).round());
    final double t = progress?.value ?? 0;
    final double phase = t * 2 * math.pi * 6;
    final double dir = clockwise ? 1 : -1;
    final Paint stroked = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    void waveArc(double start, double sweep, double a) {
      if (sweep <= 0) return;
      final Path path = Path();
      final int steps = math.max(8, (sweep * radius).ceil());
      for (int i = 0; i <= steps; i++) {
        final double theta = start + sweep * i / steps;
        final double r = radius + a * math.sin(waves * theta - phase);
        final double angle = -math.pi / 2 + dir * theta;
        final Offset p = c + Offset(math.cos(angle), math.sin(angle)) * r;
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, stroked..color = color);
    }

    // 缝（含两侧圆头）换算成弧度。
    final double gapAngle = (gap + stroke) / radius;
    final double? v = value;
    if (v != null) {
      final double sweep = 2 * math.pi * v;
      waveArc(0, sweep, amp * _amplitudeEase(v));
      final double trackStart = v <= 0 ? 0 : sweep + gapAngle;
      final double trackEnd = v <= 0 ? 2 * math.pi : 2 * math.pi - gapAngle;
      if (trackEnd > trackStart) {
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: radius),
          -math.pi / 2 + dir * trackStart,
          dir * (trackEnd - trackStart),
          false,
          stroked..color = trackColor,
        );
      }
      return;
    }

    // 不定态：每 1/6 轮一次「线头先跑、线尾追上」，弧长在 ~10° 与 ~270°
    // 之间呼吸；每次呼吸后起点累进 270°，再叠一个整体慢转。
    final double cycles = t * 6;
    final int index = cycles.floor();
    final double p = cycles - index;
    final double head = Curves.fastOutSlowIn.transform((p * 2).clamp(0.0, 1.0));
    final double tail = Curves.fastOutSlowIn.transform(
      (p * 2 - 1).clamp(0.0, 1.0),
    );
    const double maxSweep = math.pi * 1.5;
    const double minSweep = math.pi / 18;
    final double base = index * maxSweep + t * 2 * math.pi * 2;
    final double start = base + tail * maxSweep;
    final double sweep = minSweep + (head - tail) * (maxSweep - minSweep);
    waveArc(start, sweep, amp);
  }

  @override
  bool shouldRepaint(_WavyCircularPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.gap != gap ||
      oldDelegate.wavy != wavy ||
      oldDelegate.clockwise != clockwise ||
      oldDelegate.progress != progress;
}

// ---------------------------------------------------------------------------
// LoadingIndicator
// ---------------------------------------------------------------------------

/// 变形形状：极径函数 r(θ)（未归一化，绘制前按最大极径归一）。
typedef _PolarShape = double Function(double theta);

/// 圆角正 [n] 边形：正多边形的极径与圆按 [roundness] 混合（越大越圆）。
_PolarShape _roundedPolygon(int n, double roundness) {
  final double sector = 2 * math.pi / n;
  return (double theta) {
    final double local = (theta % sector) - sector / 2;
    final double polygon = math.cos(sector / 2) / math.cos(local);
    return lerpDouble(polygon, 1, roundness)!;
  };
}

/// [n] 瓣「饼干」：圆上叠 [depth] 深的余弦起伏。
_PolarShape _cookie(int n, double depth) =>
    (double theta) => 1 + depth * math.cos(n * theta);

/// 胶囊（横向体育场形，长宽比约 1 : 0.62）。
double _pill(double theta) {
  const double a = 1.0;
  const double b = 0.62;
  // 超椭圆近似体育场形：|x/a|^4 + |y/b|^4 = 1。
  final double c = math.cos(theta).abs();
  final double s = math.sin(theta).abs();
  return 1 / math.pow(math.pow(c / a, 4) + math.pow(s / b, 4), 0.25);
}

/// M3 Expressive 默认 LoadingIndicator 的形状序列。
final List<_PolarShape> _kLoadingShapes = <_PolarShape>[
  (double _) => 1, // 软圆
  _cookie(7, 0.09), // 7 瓣饼干
  _roundedPolygon(5, 0.32), // 圆角五边形
  _pill, // 胶囊
  _cookie(9, 0.07), // 9 瓣饼干
  _cookie(12, 0.06), // 太阳（细密起伏）
];

/// 采样点数：两个形状按同一组角度采样后逐点插值。
const int _kShapeSamples = 144;

List<double> _sampleShape(_PolarShape shape) {
  final List<double> radii = List<double>.generate(
    _kShapeSamples,
    (int i) => shape(2 * math.pi * i / _kShapeSamples),
  );
  final double maxR = radii.reduce(math.max);
  return <double>[for (final double r in radii) r / maxR];
}

final List<List<double>> _kSampledShapes = <List<double>>[
  for (final _PolarShape s in _kLoadingShapes) _sampleShape(s),
];

/// 弹簧感节拍：快速冲过目标再回落（阻尼回弹）。
const Curve _kMorphCurve = Cubic(0.34, 1.45, 0.64, 1);

/// M3 Expressive LoadingIndicator（不定态「加载」，区别于进度环）：主色形状
/// 在圆角多边形之间连续变形并旋转。[contained] 为 true 时铺 primaryContainer
/// 圆底、形状用 onPrimaryContainer。默认外框 48，形状占 38/48。
///
/// 系统「减少动态效果」时停在静止的 7 瓣饼干形，不动画。
class FushiExpressiveLoadingIndicator extends StatefulWidget {
  const FushiExpressiveLoadingIndicator({
    super.key,
    this.size = 48,
    this.contained = false,
    this.color,
    this.containerColor,
    this.semanticsLabel,
  });

  final double size;
  final bool contained;
  final Color? color;
  final Color? containerColor;
  final String? semanticsLabel;

  @override
  State<FushiExpressiveLoadingIndicator> createState() =>
      _FushiExpressiveLoadingIndicatorState();
}

class _FushiExpressiveLoadingIndicatorState
    extends State<FushiExpressiveLoadingIndicator>
    with
        SingleTickerProviderStateMixin<FushiExpressiveLoadingIndicator>,
        _RepeatingTicker<FushiExpressiveLoadingIndicator> {
  /// 每次变形 650ms，一轮走完全部形状。
  static const int _morphMs = 650;

  @override
  Duration get tickerPeriod =>
      Duration(milliseconds: _morphMs * _kSampledShapes.length);

  @override
  bool wantsAnimation(BuildContext context) => _motionAllowed(context);

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color color =
        widget.color ?? (widget.contained ? cs.onPrimaryContainer : cs.primary);
    Widget body = RepaintBoundary(
      child: CustomPaint(
        painter: _MorphPainter(
          progress: ticker,
          animate: _motionAllowed(context),
          color: color,
          containerColor: widget.contained
              ? (widget.containerColor ?? cs.primaryContainer)
              : null,
        ),
      ),
    );
    body = SizedBox.square(dimension: widget.size, child: body);
    return Semantics(label: widget.semanticsLabel, child: body);
  }
}

class _MorphPainter extends CustomPainter {
  _MorphPainter({
    required this.progress,
    required this.animate,
    required this.color,
    required this.containerColor,
  }) : super(repaint: progress);

  final Animation<double>? progress;
  final bool animate;
  final Color color;
  final Color? containerColor;

  @override
  void paint(Canvas canvas, Size size) {
    final double side = math.min(size.width, size.height);
    if (side <= 0) return;
    final Offset c = size.center(Offset.zero);
    final Color? container = containerColor;
    if (container != null) {
      canvas.drawCircle(c, side / 2, Paint()..color = container);
    }
    // 形状占 38/48；contained 时再收一点，给圆底留边。
    final double radius = side / 2 * (container != null ? 0.66 : 0.79);
    final int n = _kSampledShapes.length;
    final double t = animate ? (progress?.value ?? 0) : 0;
    final double steps = t * n;
    final int index = steps.floor() % n;
    final double local = steps - steps.floor();
    // 每段前 70% 时间变形、后 30% 停留，变形用弹簧感曲线（可略越过目标）。
    final double morph = animate
        ? _kMorphCurve.transform((local / 0.7).clamp(0.0, 1.0))
        : 0;
    final List<double> from = _kSampledShapes[animate ? index : 1];
    final List<double> to = _kSampledShapes[(index + 1) % n];
    // 整体匀速慢转 + 每次变形额外转 90°（同样带弹簧感），一轮转回原位。
    final double rotation = animate
        ? 2 * math.pi * t + (index + morph) * (math.pi / 2)
        : 0;
    final Path path = Path();
    for (int i = 0; i < _kShapeSamples; i++) {
      final double r = lerpDouble(from[i], to[i], morph)! * radius;
      final double angle = 2 * math.pi * i / _kShapeSamples + rotation;
      final Offset p = c + Offset(math.cos(angle), math.sin(angle)) * r;
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_MorphPainter oldDelegate) =>
      oldDelegate.animate != animate ||
      oldDelegate.color != color ||
      oldDelegate.containerColor != containerColor ||
      oldDelegate.progress != progress;
}
