/// 倾诉的绘制：每句按 [buildTiltLayout] 拆成 1–4 行，逐行（逐字错峰）显现；斜体行字上下
/// 交错、整行从下方放大浮上来；正在唱的字按脉动放大。每句的字形 TextPainter 只排一次，
/// 每帧只读缓存按时间算透明度 / 位移 / 缩放。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tilt/tilt_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tilt/tilt_tuning.dart';

/// 排好的一行（段）：字号、行高、每个字的画笔与步进。
class TiltRenderSegment {
  TiltRenderSegment({
    required this.plan,
    required this.fontSize,
    required this.lineHeight,
    required this.staggerPx,
    required this.painters,
    required this.advances,
  }) : width = advances.fold<double>(0, (double a, double b) => a + b);

  final TiltSegmentPlan plan;
  final double fontSize;

  /// 行盒高度（px）。
  final double lineHeight;

  /// 斜体字上下错开的幅度（px；正体为 0）。
  final double staggerPx;

  /// 与 [TiltSegmentPlan.chars] 一一对应；空白为 null。
  final List<TextPainter?> painters;
  final List<double> advances;
  final double width;

  bool get isTilt => plan.segment.isTilt;

  void dispose() {
    for (final TextPainter? p in painters) {
      p?.dispose();
    }
  }
}

/// 排好的一句。
class TiltLinePlan {
  TiltLinePlan({required this.layout, required this.segments});

  final TiltLayout layout;
  final List<TiltRenderSegment> segments;

  /// 各段的时间（与 [segments] 同序）。
  late final List<TiltSegmentPlan> segmentPlans = <TiltSegmentPlan>[
    for (final TiltRenderSegment s in segments) s.plan,
  ];

  void dispose() {
    for (final TiltRenderSegment s in segments) {
      s.dispose();
    }
  }
}

/// 场景：持有排版缓存，按时间画一帧。
class TiltScene {
  LyricVisualizerContext? _ctx;
  TextStyle _base = const TextStyle();
  TiltTuning _tuning = const TiltTuning();
  TiltColors? _colors;
  double _width = -1;
  double _fontScale = 1;
  LyricVisualizerTheme? _theme;

  final Map<int, TiltLinePlan> _plans = <int, TiltLinePlan>{};
  final Map<String, double> _measureCache = <String, double>{};

  /// 换输入：排版相关的东西变了就清缓存。
  void update(LyricVisualizerContext c, TextStyle base) {
    final TiltTuning tuning = TiltTuning.of(c.tuning);
    final TiltColors colors = resolveTiltColors(tuning.colorScheme, c.palette);
    final bool stale =
        _ctx == null ||
        !identical(_ctx!.runtime, c.runtime) ||
        tuning != _tuning ||
        colors.normal != _colors?.normal ||
        colors.tilt != _colors?.tilt ||
        c.fontScale != _fontScale ||
        c.theme != _theme ||
        base != _base;
    _ctx = c;
    _tuning = tuning;
    _colors = colors;
    _fontScale = c.fontScale;
    _theme = c.theme;
    _base = base;
    if (stale) _clear();
  }

  void _clear() {
    for (final TiltLinePlan p in _plans.values) {
      p.dispose();
    }
    _plans.clear();
    _measureCache.clear();
  }

  void dispose() => _clear();

  /// 字重照 folia `resolveThemeFontWeight(theme, 400 / 300)`：主题给了字重就两种行都用主题的，
  /// 字体族也取主题的（[LyricVisualizerContext.applyThemeFont]）。
  TextStyle _style(double px, bool tilt, {Color? color, double? spacing}) =>
      _applyTheme(
        _base.copyWith(
          fontSize: px,
          fontWeight: tilt ? FontWeight.w300 : FontWeight.w400,
          fontStyle: tilt ? FontStyle.italic : FontStyle.normal,
          letterSpacing: spacing ?? 0,
          height: 1,
          color: color,
          decoration: TextDecoration.none,
          shadows: const <Shadow>[],
        ),
      );

  TextStyle _applyTheme(TextStyle style) =>
      _ctx?.applyThemeFont(style) ?? style;

  double _measure(String text, double px, bool tilt) {
    final String key = '${tilt ? 1 : 0}|${px.toStringAsFixed(2)}|$text';
    final double? hit = _measureCache[key];
    if (hit != null) return hit;
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: _style(px, tilt)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final double w = tp.width;
    tp.dispose();
    _measureCache[key] = w;
    return w;
  }

  /// 第 [index] 句的排法（按视口宽缓存）。
  TiltLinePlan planFor(int index, double viewportWidth) {
    if (viewportWidth != _width) {
      _clear();
      _width = viewportWidth;
    }
    final TiltLinePlan? hit = _plans[index];
    if (hit != null) return hit;
    final LyricVisualizerContext c = _ctx!;
    final LyricVisualizerLine line = c.runtime.lines[index];
    final TiltLayout layout = buildTiltLayout(
      fullText: tiltLineFullText(line),
      lineSeed: line.startMs / 1000,
      tuning: _tuning,
      viewportWidth: viewportWidth,
      fontScale: c.fontScale,
      measure: _measure,
      wordSpans: tiltLineWordSpans(line),
    );
    final List<TiltSegmentPlan> segPlans = buildTiltSegmentPlans(layout, line);
    final double k = c.fontScale * layout.scaleMultiplier;
    final TiltColors colors = _colors!;
    final List<TiltRenderSegment> segments = <TiltRenderSegment>[];
    for (final TiltSegmentPlan sp in segPlans) {
      final bool tilt = sp.segment.isTilt;
      final double boost = !tilt && sp.segment.isShortLastLine
          ? kTiltShortLastBoost
          : 1;
      final double px = tiltRenderFontPx(viewportWidth, k * boost);
      final double spacing =
          px * (tilt ? kTiltTiltLetterSpacingEm : kTiltNormalLetterSpacingEm);
      final TextStyle style = _style(
        px,
        tilt,
        color: tilt ? colors.tilt : colors.normal,
        spacing: spacing,
      );
      final double spaceMin =
          px * (tilt ? kTiltTiltSpaceEm : kTiltNormalSpaceEm);
      final List<TextPainter?> painters = <TextPainter?>[];
      final List<double> advances = <double>[];
      for (final TiltChar ch in sp.chars) {
        final TextPainter tp = TextPainter(
          text: TextSpan(text: ch.isSpace ? ' ' : ch.text, style: style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        if (ch.isSpace) {
          advances.add(math.max(tp.width, spaceMin));
          tp.dispose();
          painters.add(null);
        } else {
          advances.add(tp.width);
          painters.add(tp);
        }
      }
      segments.add(
        TiltRenderSegment(
          plan: sp,
          fontSize: px,
          lineHeight: px * (tilt ? kTiltTiltLineHeight : kTiltNormalLineHeight),
          staggerPx: tilt ? tiltStaggerOffsetPx(viewportWidth, k) : 0,
          painters: painters,
          advances: advances,
        ),
      );
    }
    final TiltLinePlan plan = TiltLinePlan(layout: layout, segments: segments);
    _plans[index] = plan;
    return plan;
  }

  void _evictExcept(Set<int> keep) {
    if (_plans.length <= 4) return;
    final List<int> drop = _plans.keys
        .where((int k) => !keep.contains(k))
        .toList();
    for (final int k in drop) {
      _plans.remove(k)?.dispose();
    }
  }

  /// 画一帧。当前句 = folia `currentLineIndex`（起点已到、还没过句尾离场的最后一句，
  /// [LyricVisualizerRuntime.displayedLineAt]）；一句不再是当前句时（下一句开始或过了句尾离场，
  /// [LyricVisualizerRuntime.visualEndMsOf]）整组在 0.45s 里淡出（AnimatePresence popLayout，
  /// 与新句叠在同一处）。
  void paint(Canvas canvas, Size size, int timeMs) {
    final LyricVisualizerContext? c = _ctx;
    if (c == null || size.isEmpty) return;
    final LyricVisualizerRuntime rt = c.runtime;
    final int last = rt.lastStartedLineAt(timeMs);
    if (last < 0) return;
    final int cur = rt.displayedLineAt(timeMs);
    final bool motion = c.motion;
    _evictExcept(<int>{last - 1, last, last + 1});

    if (motion) {
      for (final int j in <int>[last - 1, last]) {
        if (j < 0 || j == cur) continue;
        final int since = timeMs - rt.visualEndMsOf(j);
        if (since < 0 || since >= kTiltGroupExitMs) continue;
        final double fade =
            1 - Curves.easeInOut.transform(since / kTiltGroupExitMs);
        _paintGroup(canvas, size, j, timeMs, fade, motion);
      }
    }
    if (cur < 0) return;
    final double enter = motion
        ? Curves.easeOut.transform(
            ((timeMs - rt.lines[cur].startMs) / kTiltGroupEnterMs).clamp(
              0.0,
              1.0,
            ),
          )
        : 1;
    _paintGroup(canvas, size, cur, timeMs, enter, motion);
  }

  void _paintGroup(
    Canvas canvas,
    Size size,
    int index,
    int timeMs,
    double groupAlpha,
    bool motion,
  ) {
    if (groupAlpha <= 0.004) return;
    final LyricVisualizerLine line = _ctx!.runtime.lines[index];
    final TiltLinePlan plan = planFor(index, size.width);
    if (plan.segments.isEmpty) return;
    // 自然离场（过了句尾离场时下一句还没开始）时各段跟着隐去；被下一句顶掉时段停在原样、
    // 只随整组淡出（folia 退场中的元素保留最后一次的 props）。
    final List<LyricVisualizerLine> lines = _ctx!.runtime.lines;
    final int nextStart = index + 1 < lines.length
        ? lines[index + 1].startMs
        : 1 << 52;
    final int hideAt = line.renderEndMs <= nextStart
        ? line.renderEndMs
        : 1 << 52;

    // folia：70vh 高的居中区域、p-8 内边距、行间 gap-y-3 / sm:gap-y-4。
    final double gap = size.width < 640 ? 12 : 16;
    double total = 0;
    for (final TiltRenderSegment s in plan.segments) {
      total += s.lineHeight;
    }
    total += gap * (plan.segments.length - 1);
    final double areaH = math.max(1, size.height * 0.7 - 64);
    final double areaW = math.max(
      1,
      math.min(size.width * 0.85, size.width - 64),
    );
    // 兜底：整组太高就整体缩小，免得出框（folia 依赖 CSS 溢出被裁）。
    final double fit = math.min(1, areaH / total);

    final double cx = size.width / 2;
    final double cy = size.height / 2;
    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(fit);
    double y = -total / 2;
    for (int si = 0; si < plan.segments.length; si++) {
      final TiltRenderSegment seg = plan.segments[si];
      final double boxCenter = y + seg.lineHeight / 2;
      y += seg.lineHeight + gap;
      _paintSegment(
        canvas,
        plan,
        si,
        seg,
        line,
        hideAt,
        boxCenter,
        areaW / fit,
        timeMs,
        groupAlpha,
        motion,
      );
    }
    canvas.restore();
  }

  void _paintSegment(
    Canvas canvas,
    TiltLinePlan plan,
    int si,
    TiltRenderSegment seg,
    LyricVisualizerLine line,
    int hideAt,
    double boxCenter,
    double maxWidth,
    int timeMs,
    double groupAlpha,
    bool motion,
  ) {
    final int revealAt = tiltSegmentRevealAt(
      plan.segmentPlans,
      si,
      line.startMs,
    );
    final bool tilt = seg.isTilt;
    final double v = motion
        ? tiltTransition(
            timeMs: timeMs,
            revealAtMs: revealAt,
            hideAtMs: hideAt,
            durationMs: tilt ? kTiltTiltSegmentMs : kTiltNormalSegmentMs,
          )
        : (timeMs >= revealAt && timeMs <= hideAt && revealAt < hideAt ? 1 : 0);
    final double segAlpha = groupAlpha * v;
    if (segAlpha <= 0.004) return;

    // 容器：正体从下方 20px 浮上；斜体从下方 24px、0.92 倍放大到原位。
    final double rise = (1 - v) * (tilt ? 24 : 20);
    final double grow = tilt ? 0.92 + 0.08 * v : 1;
    // 兜底：单行比可用宽度还宽时压到能放下（folia 的缩放有下限，窄屏会溢出）。
    final double squeeze = seg.width > maxWidth ? maxWidth / seg.width : 1;

    canvas.save();
    canvas.translate(0, boxCenter + rise);
    canvas.scale(grow * squeeze);
    double x = -seg.width / 2;
    final List<TiltChar> chars = seg.plan.chars;
    final int stagger = tilt
        ? kTiltTiltCharStaggerMs
        : kTiltNormalCharStaggerMs;
    for (int ci = 0; ci < chars.length; ci++) {
      final TiltChar ch = chars[ci];
      final double adv = seg.advances[ci];
      final TextPainter? tp = seg.painters[ci];
      if (tp == null || ch.isSpace) {
        x += adv;
        continue;
      }
      final double cv = motion
          ? tiltTransition(
              timeMs: timeMs,
              revealAtMs: revealAt,
              hideAtMs: hideAt,
              durationMs: kTiltCharMs,
              delayMs: ch.visualIndex * stagger,
            )
          : (v > 0 ? 1 : 0);
      final double alpha = segAlpha * cv;
      if (alpha > 0.004) {
        // 斜体：偶数字往上、奇数字往下，显现时从两倍幅度收回一倍。
        final double dir = ch.visualIndex.isEven ? -1 : 1;
        final double dy = tilt ? dir * seg.staggerPx * (2 - cv) : 0;
        final double scale = motion
            ? tiltCharPulseScale(
                tiltCharPulse(timeMs, ch.startMs, ch.endMs),
                tilt,
              )
            : 1;
        _paintChar(canvas, tp, x + adv / 2, dy, scale, alpha);
      }
      x += adv;
    }
    canvas.restore();
  }

  void _paintChar(
    Canvas canvas,
    TextPainter tp,
    double cx,
    double cy,
    double scale,
    double alpha,
  ) {
    canvas.save();
    canvas.translate(cx, cy);
    if (scale != 1) canvas.scale(scale);
    final Offset origin = Offset(-tp.width / 2, -tp.height / 2);
    if (alpha < 0.999) {
      final Rect bounds = (origin & tp.size).inflate(tp.height * 0.3);
      canvas.saveLayer(
        bounds,
        Paint()..color = ui.Color.fromRGBO(0, 0, 0, alpha.clamp(0.0, 1.0)),
      );
      tp.paint(canvas, origin);
      canvas.restore();
    } else {
      tp.paint(canvas, origin);
    }
    canvas.restore();
  }
}
