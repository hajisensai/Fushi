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

/// 代替 folia 平滑后的低频能量：歌词起字包络（`pulseAt`）加一段 70ms 的起音，峰值约 0.56。
double claddaghLyricPower(LyricVisualizerRuntime runtime, int timeMs) {
  const double decayMs = 320;
  final double p = runtime.pulseAt(timeMs, decayMs: decayMs.round());
  if (p <= 0) return 0;
  final double dt = -decayMs * math.log(p);
  return p * (1 - math.exp(-dt / 70));
}

/// 中轴线这一帧的样子。
class CladdaghAxis {
  const CladdaghAxis({
    required this.color,
    required this.scaleX,
    required this.scaleY,
    required this.angleDeg,
    required this.length,
  });

  final Color color;
  final double scaleX;
  final double scaleY;
  final double angleDeg;
  final double length;
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
  });

  final String text;
  final double fontPx;
  final bool translation;

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
  CladdaghScene(this._ctx, this._baseStyle);

  LyricVisualizerContext _ctx;
  TextStyle _baseStyle;
  final CladdaghRingSpring _spring = CladdaghRingSpring();

  String _layoutKey = '';
  final Map<int, List<CladdaghGlyph>> _lineCache = <int, List<CladdaghGlyph>>{};
  final Map<int, List<CladdaghGlyph>> _translationCache =
      <int, List<CladdaghGlyph>>{};

  /// 换输入（参数 / 配色 / 时间轴变化）。排版缓存按 key 自动失效。
  void update(LyricVisualizerContext ctx, TextStyle baseStyle) {
    if (!identical(ctx.runtime, _ctx.runtime) || baseStyle != _baseStyle) {
      _layoutKey = '';
    }
    _ctx = ctx;
    _baseStyle = baseStyle;
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
  }

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
        claddaghGlyphStyle(_baseStyle, fontPx, FontWeight.w700),
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
        claddaghGlyphStyle(_baseStyle, fontPx, FontWeight.w600),
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

  /// 行结束后环继续慢慢转到下一行开唱前（留出下一行入场的时间），末行再多转 10 秒。
  double _renderEnd(int index) {
    final List<LyricVisualizerLine> lines = _ctx.runtime.lines;
    final LyricVisualizerLine line = lines[index];
    final double end = line.endMs.toDouble();
    final double next = index + 1 < lines.length
        ? lines[index + 1].startMs - kCladdaghNextLineEntryLeadMs
        : end + 10000;
    return math.max(end, next);
  }

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
    final double power = motion && c.playing
        ? claddaghLyricPower(c.runtime, timeMs)
        : 0;

    // 中轴线：颜色在主色与强调色之间随能量脉动，长度随低频平方伸缩。
    CladdaghAxis? axis;
    if (tuning.showAxisLine) {
      final Color from = palette.text;
      Color to = palette.accent;
      if (to == from) to = palette.secondary;
      if (to == from) to = const Color(0xFFFFFFFF);
      final double ratio = math.min(1.0, math.max(0.0, power - 0.02) / 0.58);
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

    // 节拍让环半径轻轻鼓起（folia normal 强度：×0.25，上限 1.25）。
    final double rx = baseRx * math.min(1 + power * 0.25, 1.25);
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

      for (final CladdaghGlyph g in spacing) {
        if (g.char.trim().isEmpty) continue;
        final CladdaghPose pose = ring.pose(
          line: state,
          nominalAngle: g.nominalAngle,
        );
        if (pose.opacity < 0.002) continue;
        final ({double mix, double alpha, double flashPop}) flash =
            claddaghFlash(claddaghCharProgress(g, t));
        final Color color = Color.lerp(
          primary,
          highlight,
          flash.mix,
        )!.withValues(alpha: flash.alpha);
        final double glow =
            24 *
            math.pow(pose.focus, 2.0) *
            (1 + (motion ? flash.flashPop : 0));
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
