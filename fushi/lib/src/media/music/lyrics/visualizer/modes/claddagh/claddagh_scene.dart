/// 回环的每帧场景（移植 folia `VisualizerCladdagh.tsx` 的环切换弹簧 / 渲染行窗口 与
/// `CladdaghRingLine.tsx` 的逐字上色）：给定歌词显示时间与画布尺寸，算出中轴线和每个要画
/// 的字（位置、转角、缩放、颜色、发光、模糊）。字的排版宽度按行缓存，只在尺寸 / 参数变化时重测。
library;

import 'dart:math' as math;

import 'package:flutter/physics.dart' show SpringDescription, SpringSimulation;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/claddagh/claddagh_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/claddagh/claddagh_timeline.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/claddagh/claddagh_tuning.dart';

/// 环在行之间的切换：每换一行整环转半圈（folia framer-motion spring：stiffness 55、
/// damping 14、mass 0.9）。跳行（>1）或减弱动态时直接到位。时钟用歌词显示时间，
/// 同一时刻永远得到同一角度。
class CladdaghRingSpring {
  static const SpringDescription _spring = SpringDescription(
    mass: 0.9,
    stiffness: 55,
    damping: 14,
  );

  int? _center;
  double _target = 0;
  SpringSimulation? _sim;
  double _simStartMs = 0;

  /// [center] 行在 [timeMs] 时环的整体转角（弧度）。
  double valueAt(int center, double timeMs, {required bool animate}) {
    final double target = center * math.pi;
    final int? prev = _center;
    if (prev == null || !animate || (center - prev).abs() > 1) {
      _center = center;
      _target = target;
      _sim = null;
      return target;
    }
    if (center != prev) {
      double from = _target;
      double velocity = 0;
      final SpringSimulation? running = _sim;
      if (running != null) {
        final double dt = math.max(0, (timeMs - _simStartMs) / 1000);
        from = running.x(dt);
        velocity = running.dx(dt);
      }
      _sim = SpringSimulation(_spring, from, target, velocity);
      _simStartMs = timeMs;
      _center = center;
      _target = target;
    }
    final SpringSimulation? sim = _sim;
    if (sim == null) return _target;
    final double dt = (timeMs - _simStartMs) / 1000;
    if (dt < 0 || sim.isDone(dt)) {
      _sim = null;
      return _target;
    }
    return sim.x(dt);
  }
}

/// folia 用 framer-motion `useSpring` 平滑频段（低频 stiffness 150 / damping 25，人声 120 / 24，
/// 质量 1）。这里按歌词显示时间逐帧推进同一个弹簧：半隐式欧拉，每步不超过 1/240 秒；时间倒退或
/// 一跳超过 0.5 秒（拖进度、首帧）时直接落到目标值。
class CladdaghSpringFollower {
  CladdaghSpringFollower({required this.stiffness, required this.damping});

  final double stiffness;
  final double damping;

  double _x = 0;
  double _v = 0;
  int? _lastMs;

  double get value => _x;

  /// 推进到 [timeMs]，目标 [target]，返回平滑后的值。
  double advance(double target, int timeMs) {
    final int? last = _lastMs;
    _lastMs = timeMs;
    if (last == null || timeMs < last || timeMs - last > 500) {
      _x = target;
      _v = 0;
      return _x;
    }
    double remaining = (timeMs - last) / 1000;
    while (remaining > 1e-9) {
      final double h = math.min(remaining, 1 / 240);
      final double a = -stiffness * (_x - target) - damping * _v;
      _v += a * h;
      _x += _v * h;
      remaining -= h;
    }
    return _x;
  }
}

/// folia 副歌时中轴线光晕的强度：每帧（60fps）向目标走 0.05，约 330ms 走完。这里按显示时间换算
/// 成每秒 3.0；时间倒退或跳太远时直接到位。
class CladdaghGlowRamp {
  double _value = 0;
  int? _lastMs;

  double advance(bool on, int timeMs, {required bool animate}) {
    final double target = on ? 1 : 0;
    final int? last = _lastMs;
    _lastMs = timeMs;
    if (!animate || last == null || timeMs < last || timeMs - last > 500) {
      _value = target;
      return _value;
    }
    final double step = (timeMs - last) / 1000 * 3.0;
    final double diff = target - _value;
    _value = diff.abs() <= step ? target : _value + diff.sign * step;
    return _value;
  }
}

/// 中轴线这一帧的样子。
class CladdaghAxis {
  const CladdaghAxis({
    required this.color,
    required this.scaleX,
    required this.scaleY,
    required this.angleDeg,
    required this.length,
    this.glowSize = 0,
    this.glowColor = const Color(0x00000000),
  });

  final Color color;
  final double scaleX;
  final double scaleY;
  final double angleDeg;
  final double length;

  /// 副歌光晕（CSS drop-shadow 的模糊半径 px；0 = 不画）。
  final double glowSize;
  final Color glowColor;
}

/// 一个要画的字。
class CladdaghDraw {
  const CladdaghDraw({
    required this.text,
    required this.fontPx,
    required this.translation,
    required this.offset,
    required this.rotationDeg,
    required this.scale,
    required this.color,
    required this.glowRadius,
    required this.glowColor,
    required this.blur,
    this.chorus = false,
    this.coreColor = const Color(0x00000000),
  });

  final String text;
  final double fontPx;
  final bool translation;

  /// 副歌三层发光（内核 0.35r 用 [coreColor]，外两层 r / 1.6r 用 [glowColor]）。
  final bool chorus;
  final Color coreColor;

  /// 相对环心。
  final Offset offset;
  final double rotationDeg;
  final double scale;

  /// 已乘整体透明度。
  final Color color;
  final double glowRadius;
  final Color glowColor;
  final double blur;
}

/// 一帧。
class CladdaghFrame {
  const CladdaghFrame({
    required this.center,
    required this.axis,
    required this.glyphs,
    required this.centerLineIndex,
    required this.lineOffset,
  });

  final Offset center;
  final CladdaghAxis? axis;
  final List<CladdaghDraw> glyphs;
  final int centerLineIndex;
  final double lineOffset;
}

/// 测量用的排版样式（字号外的部分来自宿主的默认字体）。
TextStyle claddaghGlyphStyle(
  TextStyle base,
  double fontPx,
  FontWeight weight,
) => base.copyWith(
  fontSize: fontPx,
  fontWeight: weight,
  letterSpacing: fontPx * kCladdaghLetterSpacingEm,
  height: 1.2,
);

/// 用 [TextPainter] 量出每个字素前缀的宽度（插入点位置）。
double Function(int count) claddaghTextMeasurer(
  List<String> graphemes,
  TextStyle style,
) {
  final TextPainter painter = TextPainter(
    text: TextSpan(text: graphemes.join(), style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final List<double> widths = <double>[0];
  int cu = 0;
  for (final String g in graphemes) {
    cu += g.length;
    widths.add(
      painter.getOffsetForCaret(TextPosition(offset: cu), Rect.zero).dx,
    );
  }
  // 字距算在每个字的步进里，插入点即「前缀宽度 + 每字字距」，与 CSS 前缀测量一致。
  painter.dispose();
  return (int count) => widths[count];
}

/// 场景：持有环弹簧与按行的排版缓存。
class CladdaghScene {
  CladdaghScene(
    this._ctx,
    this._baseStyle, {
    FontWeight lyricWeight = FontWeight.w700,
    FontWeight translationWeight = FontWeight.w600,
  }) : _lyricWeight = lyricWeight,
       _translationWeight = translationWeight;

  LyricVisualizerContext _ctx;
  TextStyle _baseStyle;
  FontWeight _lyricWeight;
  FontWeight _translationWeight;
  final CladdaghRingSpring _spring = CladdaghRingSpring();

  /// folia `useSpring(audioBands.bass, {stiffness: 150, damping: 25})`。
  final CladdaghSpringFollower _bass = CladdaghSpringFollower(
    stiffness: 150,
    damping: 25,
  );

  /// folia `useSpring(audioBands.vocal, {stiffness: 120, damping: 24})`。
  final CladdaghSpringFollower _vocal = CladdaghSpringFollower(
    stiffness: 120,
    damping: 24,
  );
  final CladdaghGlowRamp _axisGlow = CladdaghGlowRamp();

  String _layoutKey = '';
  final Map<int, List<CladdaghGlyph>> _lineCache = <int, List<CladdaghGlyph>>{};
  final Map<int, List<CladdaghGlyph>> _translationCache =
      <int, List<CladdaghGlyph>>{};

  /// 每行每个字的按词着色（folia `charColor`，主题 wordColors 命中的字；null = 用高亮色）。
  final Map<int, List<Color?>> _colorCache = <int, List<Color?>>{};

  /// 换输入（参数 / 配色 / 时间轴 / 主题变化）。排版缓存按 key 自动失效。
  void update(
    LyricVisualizerContext ctx,
    TextStyle baseStyle, {
    FontWeight lyricWeight = FontWeight.w700,
    FontWeight translationWeight = FontWeight.w600,
  }) {
    if (!identical(ctx.runtime, _ctx.runtime) ||
        baseStyle != _baseStyle ||
        lyricWeight != _lyricWeight ||
        translationWeight != _translationWeight ||
        ctx.theme != _ctx.theme) {
      _layoutKey = '';
    }
    _ctx = ctx;
    _baseStyle = baseStyle;
    _lyricWeight = lyricWeight;
    _translationWeight = translationWeight;
  }

  /// 歌词基准字号：folia 72px × 字号倍数；窄屏按宽度缩（不到 1100 宽时，最小一半）。
  static double fontPxFor(Size size, double fontScale) =>
      kCladdaghBaseFontPx *
      fontScale *
      claddaghClamp(size.width / 1100, 0.5, 1);

  static double baseRadiusFor(Size size, double radiusScale) =>
      (size.width > 0 ? math.min(size.width * 0.44, 560.0) : 360.0) *
      radiusScale;

  void _ensureLayoutKey(String key) {
    if (key == _layoutKey) return;
    _layoutKey = key;
    _lineCache.clear();
    _translationCache.clear();
    _colorCache.clear();
  }

  /// 行内每个字（按 [spacing] 的字素顺序）该用的按词着色：folia 按 UTF-16 游标把字素映射回整行
  /// 文本，与 `buildWordColorRanges` 的范围重叠就取那个颜色。
  List<Color?> _lineColors(int index, List<CladdaghGlyph> spacing) =>
      _colorCache.putIfAbsent(index, () {
        final LyricVisualizerTheme? theme = _ctx.theme;
        if (theme == null || !theme.hasWordColors) {
          return List<Color?>.filled(spacing.length, null);
        }
        final List<LyricVisualizerWordColorRange> ranges = theme.colorRangesFor(
          _ctx.runtime.lines[index].text,
        );
        final List<Color?> out = <Color?>[];
        int cursor = 0;
        for (final CladdaghGlyph g in spacing) {
          final int end = cursor + g.char.length;
          out.add(LyricVisualizerTheme.colorForSpan(ranges, cursor, end));
          cursor = end;
        }
        return out;
      });

  List<CladdaghTiming> _timingsOf(LyricVisualizerLine line) {
    if (line.glyphs.isNotEmpty) {
      return <CladdaghTiming>[
        for (final LyricVisualizerGlyph g in line.glyphs)
          CladdaghTiming(
            char: g.text,
            startMs: g.startMs.toDouble(),
            endMs: g.endMs.toDouble(),
          ),
      ];
    }
    final List<String> chars = line.text.characters.toList();
    final double step = chars.isEmpty ? 0 : line.durationMs / chars.length;
    return <CladdaghTiming>[
      for (int i = 0; i < chars.length; i++)
        CladdaghTiming(
          char: chars[i],
          startMs: line.startMs + step * i,
          endMs: line.startMs + step * (i + 1),
        ),
    ];
  }

  List<CladdaghGlyph> _lineGlyphs(
    int index,
    double fontPx,
    double radius,
    CladdaghTuning tuning,
  ) => _lineCache.putIfAbsent(index, () {
    final LyricVisualizerLine line = _ctx.runtime.lines[index];
    final List<CladdaghTiming> timeline = adjustCladdaghTimeline(
      _timingsOf(line),
      line.startMs.toDouble(),
      line.endMs.toDouble(),
    );
    if (timeline.isEmpty) return const <CladdaghGlyph>[];
    final List<String> chars = <String>[
      for (final CladdaghTiming t in timeline) t.char,
    ];
    final List<double> offsets = claddaghPrefixOffsets(
      chars,
      fontPx,
      tuning.letterSpacingOffset,
      claddaghTextMeasurer(
        chars,
        claddaghGlyphStyle(_baseStyle, fontPx, _lyricWeight),
      ),
    );
    final List<CladdaghArc> arcs = claddaghArcs(
      offsets,
      fontPx,
      radius,
      tuning.focusSpacingScale,
    );
    return <CladdaghGlyph>[
      for (int i = 0; i < timeline.length; i++)
        CladdaghGlyph(
          char: timeline[i].char,
          startMs: timeline[i].startMs,
          endMs: timeline[i].endMs,
          nominalAngle: arcs[i].nominalAngle,
          scaleFactor: arcs[i].scaleFactor,
        ),
    ];
  });

  List<CladdaghGlyph> _translationGlyphs(
    int index,
    double fontPx,
    double radius,
    CladdaghTuning tuning,
  ) => _translationCache.putIfAbsent(index, () {
    final String text = (_ctx.runtime.lines[index].translation ?? '').trim();
    if (text.isEmpty) return const <CladdaghGlyph>[];
    final List<String> chars = text.characters.toList();
    final List<double> offsets = claddaghPrefixOffsets(
      chars,
      fontPx,
      tuning.translationLetterSpacingOffset,
      claddaghTextMeasurer(
        chars,
        claddaghGlyphStyle(_baseStyle, fontPx, _translationWeight),
      ),
    );
    final List<CladdaghArc> arcs = claddaghArcs(offsets, fontPx, radius, 1);
    return <CladdaghGlyph>[
      for (int i = 0; i < chars.length; i++)
        CladdaghGlyph(
          char: chars[i],
          startMs: 0,
          endMs: 0,
          nominalAngle: arcs[i].nominalAngle,
          scaleFactor: arcs[i].scaleFactor,
        ),
    ];
  });

  /// folia `line.renderHints?.renderEndTime`：行的句尾离场窗口（共享 render hints）。
  double _renderEnd(int index) =>
      _ctx.runtime.lines[index].renderEndMs.toDouble();

  /// 算一帧。
  CladdaghFrame compute(int timeMs, Size size) {
    final LyricVisualizerContext c = _ctx;
    final CladdaghTuning tuning = CladdaghTuning.from(c.tuning);
    final List<LyricVisualizerLine> lines = c.runtime.lines;
    final double t = timeMs.toDouble();
    final bool motion = c.motion;
    final LyricVisualizerPalette palette = c.palette;

    final double fontPx = fontPxFor(size, c.fontScale);
    final double baseRx = baseRadiusFor(size, tuning.radiusScale);
    final double translationFontPx =
        fontPx * kCladdaghTranslationFontRatio * tuning.translationScale;
    _ensureLayoutKey(
      '${fontPx.toStringAsFixed(2)}|${baseRx.toStringAsFixed(2)}|'
      '${tuning.focusSpacingScale}|${tuning.letterSpacingOffset}|'
      '${tuning.translationLetterSpacingOffset}|'
      '${translationFontPx.toStringAsFixed(2)}',
    );

    final Offset center = Offset(
      size.width / 2 + tuning.positionX / 100 * size.width,
      size.height / 2 + tuning.positionY / 100 * size.height,
    );

    final int centerIndex = c.runtime.lastStartedLineAt(timeMs);
    final double lineOffset = _spring.valueAt(centerIndex, t, animate: motion);
    // 音频：分析就绪时是真低频 / 人声，否则框架用歌词起字包络合成一帧；两路都过 folia 的弹簧。
    final LyricVisualizerAudioFrame audio = c.audioFrameAt(timeMs);
    final double smoothedBass = _bass.advance(audio.low, timeMs);
    final double smoothedVocal = _vocal.advance(audio.vocal, timeMs);
    final bool live = motion && c.playing;
    final double power = live ? smoothedBass.clamp(0.0, 1.0) : 0;
    final double vocalPower = live ? smoothedVocal.clamp(0.0, 1.0) : 0;
    final int activeIndex = c.runtime.activeLineAt(timeMs);
    final bool activeChorus = activeIndex >= 0 && lines[activeIndex].isChorus;
    final double axisGlow = _axisGlow.advance(
      activeChorus,
      timeMs,
      animate: motion,
    );

    // 中轴线：颜色随 max(低频, 人声) 在主色与强调色之间脉动，长度随低频平方伸缩；副歌加光晕。
    CladdaghAxis? axis;
    if (tuning.showAxisLine) {
      final Color from = palette.text;
      Color to = palette.accent;
      if (to == from) to = palette.secondary;
      if (to == from) to = const Color(0xFFFFFFFF);
      final double colorPower = math.max(power, vocalPower);
      final double ratio = math.min(
        1.0,
        math.max(0.0, colorPower - 0.02) / 0.58,
      );
      final Color mixed = Color.lerp(
        from.withValues(alpha: 1),
        to.withValues(alpha: 1),
        ratio,
      )!.withValues(alpha: 0.2 + 0.75 * ratio);
      final double sq = power * power;
      axis = CladdaghAxis(
        color: mixed,
        scaleX: 1 + sq * 1.5,
        scaleY: 1 + sq * 0.5,
        angleDeg: tuning.centerNormalTiltDeg,
        length: 300 * claddaghClamp(size.width / 1100, 0.5, 1),
        glowSize: axisGlow > 0.001 ? (4 + power * 12) * axisGlow : 0,
        glowColor: mixed.withValues(alpha: axisGlow),
      );
    }

    final List<CladdaghDraw> draws = <CladdaghDraw>[];
    if (lines.isEmpty || baseRx <= 0) {
      return CladdaghFrame(
        center: center,
        axis: axis,
        glyphs: draws,
        centerLineIndex: centerIndex,
        lineOffset: lineOffset,
      );
    }

    // 低频让环半径鼓起（folia 按主题强度：calm ×0.08 ≤1.08、normal ×0.25 ≤1.25、
    // chaotic ×0.95 ≤1.95）。
    final double rx =
        baseRx *
        math.min(
          1 + power * c.intensity.pick(0.08, 0.25, 0.95),
          c.intensity.pick(1.08, 1.25, 1.95),
        );
    final CladdaghRing ring = CladdaghRing(
      rx: rx,
      ellipseTiltDeg: tuning.ellipseTiltDeg,
      lineOffset: lineOffset,
    );

    final int renderBase = centerIndex;
    final List<int> indices = <int>[
      for (int i = renderBase - 1; i <= renderBase + 2; i++)
        if (i >= 0 && i < lines.length) i,
    ];
    if (indices.isEmpty) {
      indices.add(centerIndex.clamp(0, lines.length - 1));
    }

    final List<CladdaghGlyph> activeSpacing = renderBase >= 0
        ? _lineGlyphs(renderBase, fontPx, baseRx, tuning)
        : const <CladdaghGlyph>[];
    final double? activeRenderEnd = renderBase >= 0
        ? _renderEnd(renderBase)
        : null;
    final double activeWordOffset = motion
        ? claddaghLineWordOffset(activeSpacing, t, activeRenderEnd)
        : 0;
    final double activeProgress = motion
        ? claddaghLinePlaybackProgress(activeSpacing, t, activeRenderEnd)
        : 0;
    final double backOrbitFollow =
        math.pi *
        kCladdaghBackOrbitFollowRatio *
        (1 - math.pow(1 - activeProgress, 1.35));
    final double currentLen = centerIndex >= 0
        ? claddaghVisualLength(lines[centerIndex].text)
        : 0;

    final Color primary = palette.text.withValues(alpha: 1);
    final Color highlight = palette.accent.withValues(alpha: 1);

    for (final int idx in indices) {
      final LyricVisualizerLine line = lines[idx];
      final List<CladdaghGlyph> spacing = _lineGlyphs(
        idx,
        fontPx,
        baseRx,
        tuning,
      );
      if (spacing.isEmpty) continue;
      final bool upcoming = idx > centerIndex;
      final double diff = (lineOffset - idx * math.pi).abs() / math.pi;
      final ({double fade, double scale}) mitigation = claddaghLengthMitigation(
        isUpcoming: upcoming,
        currentLen: currentLen,
        targetLen: claddaghVisualLength(line.text),
        lineDiffFromCenter: diff,
      );
      final double ownRenderEnd = _renderEnd(idx);
      double wordOffset = motion
          ? claddaghLineWordOffset(spacing, t, ownRenderEnd)
          : 0;
      // 过去的行保持自己唱完时的角度；当前及之后的行跟着当前行转，
      // 切换途中按与焦点的距离连续淡出这份跟随。
      if (idx >= centerIndex) {
        final double follow = upcoming ? 1 : claddaghClamp(diff, 0, 1);
        wordOffset +=
            (activeWordOffset * kCladdaghBackFollowRatio + backOrbitFollow) *
            follow;
      }
      final CladdaghLineState state = CladdaghLineState(
        lineIndex: idx,
        centerLineIndex: centerIndex,
        lineDiffFromCenter: diff,
        wordOffset: wordOffset,
        lengthFade: mitigation.fade,
        lengthScale: mitigation.scale,
        upcomingEntry: upcoming
            ? claddaghClamp(
                (t - (line.startMs - kCladdaghNextLineEntryLeadMs)) /
                    kCladdaghNextLineEntryLeadMs,
                0,
                1,
              )
            : 0,
      );

      final bool chorus = line.isChorus;
      final List<Color?> charColors = _lineColors(idx, spacing);
      // 副歌：奇偶字沿短轴上下错开，幅度随低频脉动（folia `staggerAmount`）。
      final double stagger = chorus ? fontPx * (0.06 + power * 0.12) : 0;
      for (int gi = 0; gi < spacing.length; gi++) {
        final CladdaghGlyph g = spacing[gi];
        if (g.char.trim().isEmpty) continue;
        final CladdaghPose pose = ring.pose(
          line: state,
          nominalAngle: g.nominalAngle,
          rawYOffset: chorus ? (gi.isEven ? stagger : -stagger) : 0,
        );
        if (pose.opacity < 0.002) continue;
        final ({double mix, double alpha, double flashPop}) flash =
            claddaghFlash(claddaghCharProgress(g, t));
        final Color color = Color.lerp(
          primary,
          (charColors[gi] ?? highlight).withValues(alpha: 1),
          flash.mix,
        )!.withValues(alpha: flash.alpha);
        final double baseGlow = chorus
            ? (36 + power * 24) * math.pow(pose.focus, 1.5).toDouble()
            : 24 * math.pow(pose.focus, 2.0).toDouble();
        final double glow = baseGlow * (1 + (motion ? flash.flashPop : 0));
        final double shadowFade = claddaghClamp((glow - 0.5) / 2, 0, 1);
        final bool hasGlow = glow > 0.5 && shadowFade > 0.01;
        draws.add(
          CladdaghDraw(
            text: g.char,
            fontPx: fontPx,
            translation: false,
            offset: Offset(pose.x, pose.y),
            rotationDeg: pose.rotationDeg,
            scale:
                pose.scale *
                (1 + tuning.focusScaleRatio * pose.focus) *
                mitigation.scale *
                g.scaleFactor,
            color: color.withValues(alpha: flash.alpha * pose.opacity),
            glowRadius: hasGlow ? glow : 0,
            glowColor: color.withValues(
              alpha: hasGlow ? flash.alpha * shadowFade * pose.opacity : 0,
            ),
            blur: pose.blur < 0.2 ? 0 : pose.blur,
            chorus: chorus && hasGlow,
            coreColor: chorus && hasGlow
                ? Color.lerp(
                    color.withValues(alpha: 1),
                    primary,
                    0.65,
                  )!.withValues(alpha: shadowFade * pose.opacity)
                : const Color(0x00000000),
          ),
        );
      }

      // 译文：同一圈、同样的转角，沿短轴外推到歌词下方；按整行唱进度逐字填色。
      if (!tuning.showTranslation) continue;
      final List<CladdaghGlyph> tr = _translationGlyphs(
        idx,
        translationFontPx,
        baseRx,
        tuning,
      );
      if (tr.isEmpty) continue;
      final double gapPx =
          fontPx * 0.62 * (1 + tuning.focusScaleRatio * 0.5) +
          translationFontPx * 0.8;
      final double sungGlyphs =
          claddaghLinePlaybackProgress(spacing, t, ownRenderEnd) * tr.length;
      for (int i = 0; i < tr.length; i++) {
        final CladdaghGlyph g = tr[i];
        if (g.char.trim().isEmpty) continue;
        final CladdaghPose pose = ring.pose(
          line: state,
          nominalAngle: g.nominalAngle,
          extraMinor: gapPx,
        );
        final double opacity = pose.opacity * 0.9;
        if (opacity < 0.002) continue;
        final double sung = claddaghClamp(sungGlyphs - i, 0, 1);
        final Color color = sung > 0
            ? Color.lerp(
                primary,
                highlight,
                sung,
              )!.withValues(alpha: 0.55 + 0.3 * sung)
            : primary.withValues(alpha: 0.55);
        draws.add(
          CladdaghDraw(
            text: g.char,
            fontPx: translationFontPx,
            translation: true,
            offset: Offset(pose.x, pose.y),
            rotationDeg: pose.rotationDeg,
            scale:
                pose.scale *
                (1 + tuning.focusScaleRatio * 0.35 * pose.focus) *
                mitigation.scale *
                g.scaleFactor,
            color: color.withValues(alpha: color.a * opacity),
            glowRadius: 0,
            glowColor: const Color(0x00000000),
            blur: pose.blur < 0.2 ? 0 : pose.blur,
          ),
        );
      }
    }

    return CladdaghFrame(
      center: center,
      axis: axis,
      glyphs: draws,
      centerLineIndex: centerIndex,
      lineOffset: lineOffset,
    );
  }
}
