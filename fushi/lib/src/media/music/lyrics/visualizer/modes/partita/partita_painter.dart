/// 云阶的逐帧绘制：整句容器（进出场 + 漂浮）→ 每行 chunk（错位滑入 + 引导线）→ 每个词
/// （waiting / active / passed 三态的位移、放大、旋转、变色、模糊）+ 逐字发光层。
///
/// 所有动画都是「距状态切换多久」的解析函数（见 `partita_timing.dart`），不持有任何动画控制器。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_line_cache.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_timing.dart';

/// 一个元素此刻的姿态（不透明度、缩放、位移、旋转角度）。
@immutable
class PartitaAnimState {
  const PartitaAnimState({
    required this.opacity,
    required this.scale,
    required this.x,
    required this.y,
    required this.rotate,
  });

  final double opacity;
  final double scale;
  final double x;
  final double y;
  final double rotate;

  static double _l(double a, double b, double t) => a + (b - a) * t;

  /// 位置 / 缩放 / 角度按 [t]，不透明度按 [to]。
  PartitaAnimState lerpTo(PartitaAnimState b, double t, double to) =>
      PartitaAnimState(
        opacity: _l(opacity, b.opacity, to),
        scale: _l(scale, b.scale, t),
        x: _l(x, b.x, t),
        y: _l(y, b.y, t),
        rotate: _l(rotate, b.rotate, t),
      );
}

/// 词的姿态（folia `buildGlowWordLayoutVariants`）。
PartitaAnimState partitaWordStateAt(
  PartitaPose p,
  PartitaStateTimes times,
  int timeMs, {
  required LyricVisualizerIntensity intensity,
}) {
  final PartitaAnimState waiting = PartitaAnimState(
    opacity: 0,
    scale: 0.5,
    x: p.x + math.sin(p.y) * 100,
    y: p.y + math.cos(p.x) * 50,
    rotate: p.rotate + 20,
  );
  final PartitaAnimState active = PartitaAnimState(
    opacity: 1,
    scale: p.scale * partitaActiveScale,
    x: p.x,
    y: p.y,
    rotate: p.rotate,
  );
  PartitaAnimState activeAt(double sec) =>
      waiting.lerpTo(active, partitaSpring(sec), partitaTween(sec, 0.1));
  switch (times.phaseAt(timeMs)) {
    case PartitaPhase.waiting:
      return waiting;
    case PartitaPhase.active:
      return activeAt(times.sinceActive(timeMs));
    case PartitaPhase.passed:
      final PartitaAnimState from = activeAt(
        (times.passedAtMs - times.activeAtMs) / 1000,
      );
      final double sec = times.sincePassed(timeMs);
      final double e = partitaTween(sec, 0.5);
      final double r = partitaTween(sec, 5, Curves.linear);
      final double passedOpacity = intensity == LyricVisualizerIntensity.chaotic
          ? 0.9
          : 0.82;
      return PartitaAnimState(
        opacity: from.opacity + (passedOpacity - from.opacity) * e,
        scale: from.scale + (p.scale - from.scale) * e,
        x: from.x + (p.x - from.x) * e,
        y: from.y + (p.y - from.y) * e,
        rotate: from.rotate + (p.rotate + p.passedRotate - from.rotate) * r,
      );
  }
}

/// chunk 的姿态（folia `PartitaChunk` 的 animate）。
PartitaAnimState partitaRowStateAt(
  PartitaPose cfg,
  bool guideLeft,
  PartitaStateTimes times,
  int timeMs,
) {
  final PartitaAnimState waiting = PartitaAnimState(
    opacity: 0,
    scale: 0.85,
    x: cfg.x + (guideLeft ? -40 : 40),
    y: cfg.y,
    rotate: cfg.rotate,
  );
  final PartitaAnimState target = PartitaAnimState(
    opacity: 1,
    scale: 1,
    x: cfg.x,
    y: cfg.y,
    rotate: cfg.rotate,
  );
  PartitaAnimState activeAt(double sec) =>
      waiting.lerpTo(target, partitaSpring(sec), partitaTween(sec, 0.1));
  switch (times.phaseAt(timeMs)) {
    case PartitaPhase.waiting:
      return waiting;
    case PartitaPhase.active:
      return activeAt(times.sinceActive(timeMs));
    case PartitaPhase.passed:
      final PartitaAnimState from = activeAt(
        (times.passedAtMs - times.activeAtMs) / 1000,
      );
      final double e = partitaTween(
        times.sincePassed(timeMs),
        0.4,
        partitaEaseOut,
      );
      return from.lerpTo(target, e, e);
  }
}

/// 词的正文颜色进度（0 = 底色，1 = 高亮色；folia `glowWordBodyVariants` 的 color）。
double partitaBodyTintAt(
  PartitaStateTimes times,
  int durationMs,
  LyricVisualizerWordReveal reveal,
  int timeMs,
) {
  double activeAt(double sec) =>
      (sec / math.max(durationMs / 1000, 0.001)).clamp(0.0, 1.0);
  switch (times.phaseAt(timeMs)) {
    case PartitaPhase.waiting:
      return 0;
    case PartitaPhase.active:
      return activeAt(times.sinceActive(timeMs));
    case PartitaPhase.passed:
      final double from = activeAt(
        (times.passedAtMs - times.activeAtMs) / 1000,
      );
      final double dur = switch (reveal) {
        LyricVisualizerWordReveal.instant => 0.12,
        LyricVisualizerWordReveal.fast => 0.24,
        LyricVisualizerWordReveal.normal => 0.8,
      };
      return from * (1 - partitaTween(times.sincePassed(timeMs), dur));
  }
}

/// 正文模糊（CSS blur px；waiting 10 → active 清晰）。
double partitaBodyBlurAt(
  PartitaStateTimes times,
  LyricVisualizerWordReveal reveal,
  int timeMs,
) {
  final double inDur = switch (reveal) {
    LyricVisualizerWordReveal.instant => 0.08,
    LyricVisualizerWordReveal.fast => 0.12,
    LyricVisualizerWordReveal.normal => 0.2,
  };
  double activeAt(double sec) => 10 * (1 - partitaTween(sec, inDur));
  switch (times.phaseAt(timeMs)) {
    case PartitaPhase.waiting:
      return 10;
    case PartitaPhase.active:
      return activeAt(times.sinceActive(timeMs));
    case PartitaPhase.passed:
      final double from = activeAt(
        (times.passedAtMs - times.activeAtMs) / 1000,
      );
      final double dur = switch (reveal) {
        LyricVisualizerWordReveal.instant => 0.12,
        LyricVisualizerWordReveal.fast => 0.2,
        LyricVisualizerWordReveal.normal => 0.5,
      };
      return from * (1 - partitaTween(times.sincePassed(timeMs), dur));
  }
}

/// 发光层一个字的强度 0–1（folia `wordGlowVariants`）。
double partitaGlowAt({
  required PartitaStateTimes times,
  required LyricVisualizerWordReveal reveal,
  required int durationMs,
  required int wordStartMs,
  required int glyphStartMs,
  required int glyphEndMs,
  required bool perGlyph,
  required int timeMs,
}) {
  final double dur = durationMs / 1000;
  double activeAt(double sec) {
    switch (reveal) {
      case LyricVisualizerWordReveal.instant:
        return partitaKeyframes(
          sec,
          math.min(dur, 0.12),
          const <double>[0, 1, 0],
          const <double>[0, 0.35, 1],
          partitaEaseOut,
        );
      case LyricVisualizerWordReveal.fast:
        return partitaKeyframes(
          sec,
          dur.clamp(0.12, 0.2),
          const <double>[0, 1, 0],
          const <double>[0, 0.4, 1],
        );
      case LyricVisualizerWordReveal.normal:
        if (perGlyph) {
          final double delay = math.max(0, glyphStartMs - wordStartMs) / 1000;
          final double cd = math.max(glyphEndMs - glyphStartMs, 1) / 1000;
          if (sec < delay) return 0;
          return partitaKeyframes(
            sec - delay,
            cd * 6,
            const <double>[0, 1, 0],
            const <double>[0, 0.3, 1],
          );
        }
        return partitaKeyframes(
          sec,
          dur,
          const <double>[0, 1, 1],
          const <double>[0, 0.9, 1],
        );
    }
  }

  switch (times.phaseAt(timeMs)) {
    case PartitaPhase.waiting:
      return 0;
    case PartitaPhase.active:
      return activeAt(times.sinceActive(timeMs));
    case PartitaPhase.passed:
      final double from = activeAt(
        (times.passedAtMs - times.activeAtMs) / 1000,
      );
      final double fade = switch (reveal) {
        LyricVisualizerWordReveal.instant => 0.12,
        LyricVisualizerWordReveal.fast => 0.22,
        LyricVisualizerWordReveal.normal => 0.9,
      };
      return from *
          (1 - partitaTween(times.sincePassed(timeMs), fade, partitaEaseOut));
  }
}

/// 副歌涟漪扩到的倍数：folia `1.5 + Math.random() * 2`，按词起点与字形位置确定性取。
double partitaRippleScale(int wordStartMs, int firstGlyph) {
  final double x =
      math.sin(wordStartMs * 0.00713 + firstGlyph * 12.9898 + 97) * 43758.5453;
  return 1.5 + (x - x.floorToDouble()) * 2;
}

/// 副歌涟漪此刻的缩放与不透明度；null = 不画（还没 active / 已淡完）。
({double scale, double opacity})? partitaRippleAt({
  required PartitaStateTimes times,
  required int timeMs,
  required double maxScale,
}) {
  ({double scale, double opacity}) at(int ms) {
    final double p = partitaTween(
      math.max(0, ms - times.activeAtMs) / 1000,
      0.5,
      partitaEaseOut,
    );
    return (scale: 0.2 + (maxScale - 0.2) * p, opacity: 0.8 * (1 - p));
  }

  switch (times.phaseAt(timeMs)) {
    case PartitaPhase.waiting:
      return null;
    case PartitaPhase.active:
      return at(timeMs);
    case PartitaPhase.passed:
      final ({double scale, double opacity}) from = at(times.passedAtMs);
      final double p = partitaTween(
        times.sincePassed(timeMs),
        0.5,
        partitaEaseOut,
      );
      if (p >= 1 || from.opacity <= 0) return null;
      return (scale: from.scale, opacity: from.opacity * (1 - p));
  }
}

/// 整句容器此刻的不透明度 / 缩放 / 模糊（folia `getGlowWordLineContainerMotion`）。
({double opacity, double scale, double blur}) partitaLineContainerAt({
  required LyricVisualizerRenderHints profile,
  required int lineStartMs,
  required int leaveAtMs,
  required int timeMs,
}) {
  ({double opacity, double scale, double blur}) enter(double sec) {
    switch (profile.lineTransition) {
      case LyricVisualizerLineTransition.normal:
        return (
          opacity: partitaTween(sec, 0.3),
          scale: 0.9 + 0.1 * partitaSpring(sec, stiffness: 500, damping: 25),
          blur: 10 * (1 - partitaTween(sec, 0.3)),
        );
      case LyricVisualizerLineTransition.fast:
        final double e = partitaTween(sec, 0.16, partitaEaseOut);
        return (
          opacity: 0.35 + 0.65 * e,
          scale: 0.96 + 0.04 * e,
          blur: 4 * (1 - e),
        );
      case LyricVisualizerLineTransition.none:
        return (opacity: 1, scale: 1, blur: 0);
    }
  }

  if (timeMs < leaveAtMs) return enter((timeMs - lineStartMs) / 1000);
  final ({double opacity, double scale, double blur}) from = enter(
    (leaveAtMs - lineStartMs) / 1000,
  );
  final (double s, double b, Curve c) = switch (profile.lineTransition) {
    LyricVisualizerLineTransition.normal => (1.1, 20.0, partitaEaseInOut),
    LyricVisualizerLineTransition.fast => (1.04, 10.0, partitaEaseInOut),
    LyricVisualizerLineTransition.none => (1.02, 6.0, partitaEaseOut),
  };
  final double e = partitaTween(
    (timeMs - leaveAtMs) / 1000,
    partitaLineExitMs(profile.lineTransition) / 1000,
    c,
  );
  return (
    opacity: from.opacity * (1 - e),
    scale: from.scale + (s - from.scale) * e,
    blur: from.blur + (b - from.blur) * e,
  );
}

/// 歌词区的缓慢漂浮（folia `lyricContainerFloat`）：y 与缩放按关键帧循环。
({double y, double scale}) partitaFloatAt(
  double elapsedSec,
  LyricVisualizerIntensity intensity,
) {
  final (double distance, double duration) = switch (intensity) {
    LyricVisualizerIntensity.calm => (10.0, 8.5),
    LyricVisualizerIntensity.normal => (14.0, 7.0),
    LyricVisualizerIntensity.chaotic => (18.0, 5.8),
  };
  final double t = elapsedSec % duration;
  const List<double> times = <double>[0, 0.25, 0.5, 0.75, 1];
  return (
    y: partitaKeyframes(t, duration, <double>[
      0,
      -distance,
      0,
      distance * 0.45,
      0,
    ], times),
    scale: partitaKeyframes(t, duration, const <double>[
      1,
      1.01,
      1,
      0.995,
      1,
    ], times),
  );
}

/// 云阶的画师。
class PartitaPainter extends CustomPainter {
  PartitaPainter({
    required this.ticks,
    required this.visualizer,
    required this.cache,
    required this.textStyle,
  }) : settings = PartitaSettings.fromTuning(
         visualizer.tuning,
         motion: visualizer.motion,
         intensity: visualizer.intensity,
       ),
       super(repaint: ticks);

  final LyricVisualizerTicks ticks;
  final LyricVisualizerContext visualizer;
  final PartitaLineCache cache;
  final TextStyle textStyle;
  final PartitaSettings settings;

  bool get _motion => visualizer.motion;

  PartitaLinePaint _layout(LyricVisualizerLine line, Size size) =>
      cache.lineFor(
        line: line,
        area: size,
        fontScale: visualizer.fontScale,
        settings: settings,
        style: textStyle,
        seed: visualizer.seed,
      );

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final LyricVisualizerRuntime rt = visualizer.runtime;
    if (rt.lines.isEmpty) return;
    final LyricVisualizerTick tick = ticks.value;
    final int t = tick.timeMs;

    // 下一句提前排版（folia 预热窗 0.18–1.2 s）。
    final LyricVisualizerLine? upcoming = rt.upcomingLineAt(t);
    if (upcoming != null &&
        rt.shouldPreheat(upcoming, t, minLeadMs: 180, maxLeadMs: 1200)) {
      _layout(upcoming, size);
    }

    final int li = rt.lastStartedLineAt(t);
    if (li < 0) return;
    final ({double y, double scale}) float = _motion
        ? partitaFloatAt(tick.elapsed, settings.intensity)
        : (y: 0.0, scale: 1.0);
    // 先画正在离场的上一句，再画当前句（folia AnimatePresence popLayout）。
    for (final int i in <int>[li - 1, li]) {
      if (i < 0) continue;
      _paintLine(canvas, size, i, t, float);
    }
  }

  void _paintLine(
    Canvas canvas,
    Size size,
    int index,
    int t,
    ({double y, double scale}) float,
  ) {
    final List<LyricVisualizerLine> lines = visualizer.runtime.lines;
    final LyricVisualizerLine line = lines[index];
    if (t < line.startMs) return;
    final LyricVisualizerRenderHints profile = line.renderHints;
    // 共享的视觉结束：句尾离场窗口与下一句起点取早的。
    final int leaveAt = visualizer.runtime.visualEndMsOf(index);
    if (!_motion && t >= leaveAt) return;
    final int exitMs = partitaLineExitMs(profile.lineTransition);
    if (_motion && t >= leaveAt + exitMs) return;

    final PartitaLinePaint lp = _layout(line, size);
    final ({double opacity, double scale, double blur}) box = _motion
        ? partitaLineContainerAt(
            profile: profile,
            lineStartMs: line.startMs,
            leaveAtMs: leaveAt,
            timeMs: t,
          )
        : (opacity: 1.0, scale: 1.0, blur: 0.0);
    if (box.opacity <= 0.004) return;

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2 + float.y);
    canvas.scale(box.scale * float.scale * lp.fitScale);
    canvas.translate(-lp.blockSize.width / 2, -lp.blockSize.height / 2);
    final bool blurred = box.blur > 0.3;
    if (blurred) {
      canvas.saveLayer(
        null,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: box.blur,
            sigmaY: box.blur,
            tileMode: TileMode.decal,
          ),
      );
    }
    for (final PartitaRowPaint row in lp.rows) {
      _paintRow(canvas, lp, row, t, box.opacity, line.isChorus);
    }
    if (blurred) canvas.restore();
    canvas.restore();
  }

  void _paintRow(
    Canvas canvas,
    PartitaLinePaint lp,
    PartitaRowPaint row,
    int t,
    double lineOpacity,
    bool chorus,
  ) {
    final PartitaRowPlan plan = row.plan;
    final PartitaPhase phase = row.times.phaseAt(t);
    final PartitaAnimState s = _motion
        ? partitaRowStateAt(plan.config, plan.guideLeft, row.times, t)
        : PartitaAnimState(
            opacity: 1,
            scale: 1,
            x: plan.config.x,
            y: plan.config.y,
            rotate: plan.config.rotate,
          );
    final double rowOpacity = s.opacity * lineOpacity;
    if (rowOpacity <= 0.004) return;
    final Rect b = row.box;

    canvas.save();
    canvas.translate(b.center.dx + s.x, b.center.dy + s.y);
    if (s.rotate != 0) canvas.rotate(s.rotate * math.pi / 180);
    canvas.scale(s.scale);
    canvas.translate(-b.width / 2, -b.height / 2);

    if (settings.showGuideLines) {
      _paintGuides(canvas, row, b.size, phase, t, rowOpacity);
    }
    for (final PartitaWordPaint w in row.words) {
      _paintWord(canvas, lp, w, t, rowOpacity, chorus);
    }
    canvas.restore();
  }

  void _paintGuides(
    Canvas canvas,
    PartitaRowPaint row,
    Size box,
    PartitaPhase phase,
    int t,
    double opacity,
  ) {
    final LyricVisualizerPalette pal = visualizer.palette;
    // 引导线的高亮色：整个 chunk 文本按主题着色（folia `getActiveColor(chunk 文本)`）。
    final Color active = _activeColor(
      row.plan.displayWords.map((LyricVisualizerWord w) => w.text).join(' '),
    );
    final double grow = switch (phase) {
      PartitaPhase.waiting => 0,
      _ =>
        _motion
            ? partitaTween(row.times.sinceActive(t), 0.4, partitaEaseOut)
            : 1,
    };
    if (grow <= 0) return;
    final Color color = switch (phase) {
      PartitaPhase.active => active,
      PartitaPhase.passed => pal.text.withValues(alpha: 0.22),
      PartitaPhase.waiting => pal.text.withValues(alpha: 0.14),
    };
    final double a = color.a * grow * opacity;
    final double w = box.width;
    final double h = box.height;
    final Rect vertical;
    final Rect horizontal;
    final double len = (w + 36) * grow;
    if (row.plan.guideLeft) {
      vertical = Rect.fromLTRB(-8, h + 16 - 32 * grow, -7, h + 16);
      horizontal = Rect.fromLTWH(-16, h + 7, len, 1);
    } else {
      vertical = Rect.fromLTRB(w + 7, h + 16 - 32 * grow, w + 8, h + 16);
      horizontal = Rect.fromLTWH(w + 16 - len, h + 7, len, 1);
    }
    if (phase == PartitaPhase.active && _motion) {
      final Paint glow = Paint()
        ..color = active.withValues(alpha: 0.27 * grow * opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
      canvas.drawRect(vertical.inflate(1), glow);
      canvas.drawRect(horizontal.inflate(1), glow);
    }
    final Paint p = Paint()..color = color.withValues(alpha: a);
    canvas.drawRect(vertical, p);
    canvas.drawRect(horizontal, p);
  }

  void _paintWord(
    Canvas canvas,
    PartitaLinePaint lp,
    PartitaWordPaint w,
    int t,
    double rowOpacity,
    bool chorus,
  ) {
    final LyricVisualizerPalette pal = visualizer.palette;
    final Color accent = _activeColor(w.word.text);
    final LyricVisualizerWordReveal reveal = lp.profile.wordReveal;
    final Rect b = w.box;

    if (!_motion) {
      // 静态帧：词都在原位、不放大不转；未唱 / 正在唱 / 已唱只换颜色。
      final PartitaPhase phase = w.times.phaseAt(t);
      final Color c = switch (phase) {
        PartitaPhase.waiting => pal.dimText,
        PartitaPhase.active => accent,
        PartitaPhase.passed => pal.text.withValues(alpha: pal.text.a * 0.82),
      };
      final TextPainter tp = w.body.body(c.withValues(alpha: c.a * rowOpacity));
      tp.paint(canvas, b.topLeft);
      return;
    }

    final PartitaAnimState s = partitaWordStateAt(
      w.pose,
      w.times,
      t,
      intensity: settings.intensity,
    );
    final double opacity = s.opacity * rowOpacity;
    if (opacity <= 0.004) return;

    canvas.save();
    canvas.translate(b.center.dx + s.x, b.center.dy + s.y);
    if (s.rotate != 0) canvas.rotate(s.rotate * math.pi / 180);
    canvas.scale(s.scale);
    if (chorus) _paintRipple(canvas, w, t, opacity, accent);
    canvas.translate(-b.width / 2, -b.height / 2);

    // 发光层（在正文下面）。
    final (double inner, double outer) radii = switch (reveal) {
      LyricVisualizerWordReveal.instant => (14.0, 24.0),
      LyricVisualizerWordReveal.fast => (18.0, 32.0),
      LyricVisualizerWordReveal.normal => (20.0, 40.0),
    };
    final bool perGlyph = w.glyphs.length > 1;
    for (final PartitaGlowGlyph g in w.glyphs) {
      final double glow = partitaGlowAt(
        times: w.times,
        reveal: reveal,
        durationMs: w.durationMs,
        wordStartMs: w.word.startMs,
        glyphStartMs: g.startMs,
        glyphEndMs: g.endMs,
        perGlyph: perGlyph,
        timeMs: t,
      );
      final double a = glow * opacity;
      if (a <= 0.02) continue;
      g.text.glow(accent, a, radii.$1, radii.$2).paint(canvas, Offset(g.dx, 0));
    }

    // 正文：颜色在底色与高亮色间过渡，进 active 时去模糊。
    final double tint = partitaBodyTintAt(w.times, w.durationMs, reveal, t);
    final Color base = Color.lerp(pal.text, accent, tint)!;
    final Color color = base.withValues(alpha: base.a * opacity);
    final double blur = partitaBodyBlurAt(w.times, reveal, t);
    final bool blurred = blur > 0.3;
    if (blurred) {
      canvas.saveLayer(
        null,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: blur,
            sigmaY: blur,
            tileMode: TileMode.decal,
          ),
      );
    }
    w.body.body(color).paint(canvas, Offset.zero);
    if (blurred) canvas.restore();
    canvas.restore();
  }

  /// 词的高亮色：主题按词着色命中就用它，否则 `palette.accent`（folia `getActiveColor`）。
  Color _activeColor(String text) {
    final Color accent = visualizer.palette.accent;
    return visualizer.theme?.resolveWordColor(text, accent) ?? accent;
  }

  /// 副歌涟漪（folia `GlowWord` 的 Chorus Ripple；副歌判据来自共享歌曲结构）：词在唱时从词心
  /// 起一圈 1px 细环（直径 = 词框高 ×1.5、模糊 1px），0.5 秒 easeOut 从 0.2 倍扩到
  /// 1.5–3.5 倍、不透明度 0.8→0；离开 active 后没放完的 0.5 秒淡出。调用时画布原点在词心。
  void _paintRipple(
    Canvas canvas,
    PartitaWordPaint w,
    int t,
    double opacity,
    Color color,
  ) {
    final ({double scale, double opacity})? r = partitaRippleAt(
      times: w.times,
      timeMs: t,
      maxScale: partitaRippleScale(w.word.startMs, w.word.firstGlyph),
    );
    if (r == null) return;
    final double a = (r.opacity * opacity).clamp(0.0, 1.0);
    if (a <= 0.004) return;
    canvas.save();
    canvas.scale(r.scale);
    canvas.drawCircle(
      Offset.zero,
      w.box.height * 0.75,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: color.a * a)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant PartitaPainter old) =>
      old.visualizer != visualizer ||
      old.textStyle != textStyle ||
      old.ticks != ticks ||
      old.cache != cache;
}
