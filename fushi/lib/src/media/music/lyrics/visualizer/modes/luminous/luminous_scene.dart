/// 流光的场景缓存与绘制：每句一份排版（TextPainter 按 行 + 字号 + 宽度 缓存），每帧只按时间
/// 求姿态 / 颜色 / 光晕再画。颜色和光晕强度量化成有限档，每档的 TextPainter 懒建后复用，
/// 不在每帧重排文字。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/luminous/luminous_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/luminous/luminous_timing.dart';

/// 某一帧里要画的一句：入场中 / 常驻，或离场中。
@immutable
class LuminousVisibleLine {
  const LuminousVisibleLine({
    required this.index,
    required this.fx,
    required this.exiting,
  });

  /// 在 `runtime.lines` 里的下标。
  final int index;
  final LuminousLineFx fx;
  final bool exiting;
}

/// 这一句何时下场（秒）：渲染尾巴与下一句起点取早的（folia 的 activeLine 换行即离场）。
double luminousLineExitAt(List<LyricVisualizerLine> lines, int i) {
  final LuminousRenderProfile p = LuminousRenderProfile.ofLine(lines[i]);
  double exit = p.lineRenderEnd;
  if (i + 1 < lines.length) exit = math.min(exit, lines[i + 1].startMs / 1000);
  return exit;
}

/// [t] 时刻（秒）要画的句子，离场的在前（先画、被新句盖住）。
/// [motion] 为 false 时只画当前句，不做入场 / 离场。
List<LuminousVisibleLine> luminousVisibleLines(
  LyricVisualizerRuntime runtime,
  double t, {
  required bool motion,
}) {
  final List<LyricVisualizerLine> lines = runtime.lines;
  final int last = runtime.lastStartedLineAt((t * 1000).floor());
  if (last < 0) return const <LuminousVisibleLine>[];
  final List<LuminousVisibleLine> out = <LuminousVisibleLine>[];
  for (int i = math.max(0, last - 1); i <= last; i++) {
    final LyricVisualizerLine line = lines[i];
    final double start = line.startMs / 1000;
    final double exitAt = luminousLineExitAt(lines, i);
    final LuminousRenderProfile p = LuminousRenderProfile.ofLine(line);
    if (t < exitAt) {
      out.add(
        LuminousVisibleLine(
          index: i,
          fx: motion
              ? luminousLineEnterFx(p.lineTransition, t - start)
              : LuminousLineFx.steady,
          exiting: false,
        ),
      );
    } else if (motion &&
        t < exitAt + luminousLineExitDuration(p.lineTransition)) {
      out.add(
        LuminousVisibleLine(
          index: i,
          fx: luminousLineExitFx(p.lineTransition, t - exitAt),
          exiting: true,
        ),
      );
    }
  }
  return out;
}

/// 场景配置：任何一项变了，全部排版缓存作废。
@immutable
class LuminousSceneConfig {
  const LuminousSceneConfig({
    required this.size,
    required this.fontScale,
    required this.params,
    required this.baseColor,
    required this.activeColor,
    required this.fontFamily,
    required this.fontFamilyFallback,
  });

  final Size size;
  final double fontScale;
  final LuminousLayoutParams params;
  final Color baseColor;
  final Color activeColor;
  final String? fontFamily;
  final List<String>? fontFamilyFallback;

  @override
  bool operator ==(Object other) =>
      other is LuminousSceneConfig &&
      other.size == size &&
      other.fontScale == fontScale &&
      other.params == params &&
      other.baseColor == baseColor &&
      other.activeColor == activeColor &&
      other.fontFamily == fontFamily &&
      listEquals(other.fontFamilyFallback, fontFamilyFallback);

  @override
  int get hashCode =>
      Object.hash(size, fontScale, params, baseColor, activeColor, fontFamily);
}

/// CSS text-shadow 模糊半径 → Flutter [Shadow.blurRadius]（CSS σ = r/2；Flutter σ = 0.577·b + 0.5）。
double luminousCssShadowToBlurRadius(double cssRadius) =>
    math.max(0, (cssRadius / 2 - 0.5) / 0.57735);

/// CSS `blur(px)` 的 σ 就是 px。
const int _colorSteps = 24;
const int _alphaSteps = 40;
const int _glowSteps = 20;

class _GlyphGlow {
  _GlyphGlow({
    required this.text,
    required this.offset,
    required this.start,
    required this.end,
    required this.index,
  });

  final String text;

  /// 相对词框左上角。
  final Offset offset;
  final double start;
  final double end;
  final int index;
  final Map<int, TextPainter> painters = <int, TextPainter>{};
}

class _WordRender {
  _WordRender({
    required this.word,
    required this.config,
    required this.schedule,
    required this.center,
    required this.size,
    required this.glows,
  });

  final LuminousDisplayWord word;
  final LuminousWordConfig config;
  final LuminousWordSchedule schedule;

  /// 词框中心，相对行容器中心。
  final Offset center;
  final Size size;
  final List<_GlyphGlow> glows;
  final Map<int, TextPainter> bodies = <int, TextPainter>{};

  void dispose() {
    for (final TextPainter p in bodies.values) {
      p.dispose();
    }
    bodies.clear();
    for (final _GlyphGlow g in glows) {
      for (final TextPainter p in g.painters.values) {
        p.dispose();
      }
      g.painters.clear();
    }
  }
}

class _LineRender {
  _LineRender({
    required this.profile,
    required this.words,
    required this.fontSize,
    required this.rtl,
    required this.blockSize,
  });

  final LuminousRenderProfile profile;
  final List<_WordRender> words;
  final double fontSize;
  final bool rtl;
  final Size blockSize;

  void dispose() {
    for (final _WordRender w in words) {
      w.dispose();
    }
  }
}

/// 一句的全部排版结果（纯数据，供测试检查）。
@immutable
class LuminousLineLayout {
  const LuminousLineLayout({
    required this.fontSize,
    required this.words,
    required this.plan,
    required this.flow,
    required this.widths,
  });

  final double fontSize;
  final List<LuminousDisplayWord> words;
  final LuminousLinePlan plan;
  final LuminousFlow flow;
  final List<double> widths;
}

/// 排一句：量词宽 → 姿态与边距 → flex-wrap；防重叠放不下或单词比容器宽时按比例缩小重排。
LuminousLineLayout luminousLayoutLine({
  required LyricVisualizerLine line,
  required Size area,
  required double fontScale,
  required LuminousLayoutParams params,
  required double Function(String text, double fontSize) measure,
}) {
  final List<LuminousDisplayWord> words = luminousDisplayWords(
    line,
    adaptive: !params.legacy,
  );
  final bool interlude = luminousIsInterlude(line.text);
  final bool rtl = luminousIsRtl(line.text);
  final double containerWidth = math.max(
    1,
    math.min(area.width - luminousAreaPadding * 2, luminousMaxLineWidth),
  );
  final double availableHeight = math.max(
    1,
    area.height * 0.7 - luminousAreaPadding * 2,
  );
  double fit = 1;
  late LuminousLineLayout result;
  for (int pass = 0; pass < 4; pass++) {
    final double fontSize = luminousFontSize(area.width, fontScale * fit);
    final List<double> widths = <double>[
      for (final LuminousDisplayWord w in words) measure(w.text, fontSize),
    ];
    final LuminousLinePlan plan = luminousPlanLine(
      seed: line.startMs / 1000,
      wordWidths: widths,
      fontSize: fontSize,
      params: params,
      interlude: interlude,
      rtl: rtl,
    );
    final LuminousFlow flow = luminousFlow(
      widths: widths,
      margins: plan.margins,
      containerWidth: containerWidth,
      rowHeight: fontSize * luminousLineHeight,
      justify: plan.justify,
      rtl: rtl,
      rowGap: plan.rowGap,
      reachTop: plan.reachTop,
      reachBottom: plan.reachBottom,
    );
    result = LuminousLineLayout(
      fontSize: fontSize,
      words: words,
      plan: plan,
      flow: flow,
      widths: widths,
    );
    double next = fit;
    if (params.effectiveAvoidOverlap) {
      final double f = luminousOverlapFit(availableHeight, flow.height);
      if (f < 1) next = math.max(0.5, fit * f);
    }
    // 单个词（不换行）比容器还宽时也缩到放得下，长单词不出屏。
    final double widest = widths.fold<double>(0, math.max);
    if (widest > containerWidth) {
      next = math.min(
        next,
        math.max(0.3, fit * containerWidth / widest * 0.98),
      );
    }
    if (next >= fit - 0.005) break;
    fit = next;
  }
  return result;
}

/// 场景：持有排版缓存，按帧画。宿主 State 持有一份，卸载时 [dispose]。
class LuminousScene {
  LuminousSceneConfig? _config;
  final Map<int, _LineRender> _lines = <int, _LineRender>{};
  TextPainter? _measurer;

  int get cachedLineCount => _lines.length;

  void dispose() {
    _clear();
    _measurer?.dispose();
    _measurer = null;
  }

  /// 换歌时清空（行下标换了含义）。
  void reset() {
    _clear();
    _config = null;
  }

  void _clear() {
    for (final _LineRender l in _lines.values) {
      l.dispose();
    }
    _lines.clear();
  }

  TextStyle _style(double fontSize) => TextStyle(
    fontFamily: _config!.fontFamily,
    fontFamilyFallback: _config!.fontFamilyFallback,
    fontSize: fontSize,
    fontWeight: FontWeight.w700,
    height: luminousLineHeight,
    leadingDistribution: TextLeadingDistribution.even,
  );

  TextPainter _layout(String text, TextStyle style, TextDirection dir) =>
      TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: dir,
        maxLines: 1,
      )..layout();

  double _measure(String text, double fontSize) {
    final TextPainter m = _measurer ??= TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: 1,
    );
    m.text = TextSpan(text: text, style: _style(fontSize));
    m.layout();
    return m.width;
  }

  _LineRender _lineFor(LyricVisualizerRuntime runtime, int index) {
    final _LineRender? hit = _lines[index];
    if (hit != null) return hit;
    final LuminousSceneConfig cfg = _config!;
    final LyricVisualizerLine line = runtime.lines[index];
    final LuminousLineLayout layout = luminousLayoutLine(
      line: line,
      area: cfg.size,
      fontScale: cfg.fontScale,
      params: cfg.params,
      measure: _measure,
    );
    final bool rtl = luminousIsRtl(line.text);
    final TextDirection dir = rtl ? TextDirection.rtl : TextDirection.ltr;
    final LuminousRenderProfile profile = LuminousRenderProfile.ofLine(line);
    final TextStyle style = _style(layout.fontSize);
    final double mount = line.startMs / 1000;
    final List<_WordRender> words = <_WordRender>[];
    for (int i = 0; i < layout.words.length; i++) {
      final LuminousDisplayWord w = layout.words[i];
      final LuminousSlot slot = layout.flow.slots[i];
      // 字形在词里的位置：按 UTF-16 偏移取选区框。
      final TextPainter probe = _layout(w.text, style, dir);
      final List<_GlyphGlow> glows = <_GlyphGlow>[];
      int offset = 0;
      int voiced = 0;
      for (final LyricVisualizerGlyph g in w.glyphs) {
        final int len = g.text.length;
        if (!g.isSpace) {
          final List<TextBox> boxes = probe.getBoxesForSelection(
            TextSelection(baseOffset: offset, extentOffset: offset + len),
          );
          final double left = boxes.isEmpty
              ? 0
              : boxes.map((TextBox b) => b.left).reduce(math.min);
          glows.add(
            _GlyphGlow(
              text: g.text,
              offset: Offset(left, 0),
              start: g.startMs / 1000,
              end: g.endMs / 1000,
              index: voiced,
            ),
          );
          voiced++;
        }
        offset += len;
      }
      final Size size = Size(probe.width, probe.height);
      probe.dispose();
      words.add(
        _WordRender(
          word: w,
          config: layout.plan.configs[i],
          schedule: LuminousWordSchedule.of(
            profile: profile,
            wordStart: w.startMs / 1000,
            wordEnd: w.endMs / 1000,
            mountAt: mount,
          ),
          center: Offset(
            slot.centerX - layout.flow.width / 2,
            slot.centerY - layout.flow.height / 2,
          ),
          size: size,
          glows: glows,
        ),
      );
    }
    final _LineRender render = _LineRender(
      profile: profile,
      words: words,
      fontSize: layout.fontSize,
      rtl: rtl,
      blockSize: Size(layout.flow.width, layout.flow.height),
    );
    _lines[index] = render;
    return render;
  }

  TextPainter _body(
    _WordRender w,
    _LineRender line,
    int colorStep,
    int alphaStep,
  ) {
    final int key = colorStep * (_alphaSteps + 1) + alphaStep;
    return w.bodies.putIfAbsent(key, () {
      final LuminousSceneConfig cfg = _config!;
      final Color c = Color.lerp(
        cfg.baseColor,
        cfg.activeColor,
        colorStep / _colorSteps,
      )!;
      return _layout(
        w.word.text,
        _style(
          line.fontSize,
        ).copyWith(color: c.withValues(alpha: c.a * alphaStep / _alphaSteps)),
        line.rtl ? TextDirection.rtl : TextDirection.ltr,
      );
    });
  }

  TextPainter _glow(_GlyphGlow g, int step, _LineRender line) {
    return g.painters.putIfAbsent(step, () {
      final Color c = _config!.activeColor;
      final double a = step / _glowSteps;
      final (double inner, double outer) = luminousGlowRadii(
        line.profile.wordReveal,
      );
      final Color sc = c.withValues(alpha: c.a * a);
      return _layout(
        g.text,
        _style(line.fontSize).copyWith(
          color: const Color(0x00000000),
          shadows: <Shadow>[
            Shadow(color: sc, blurRadius: luminousCssShadowToBlurRadius(inner)),
            Shadow(color: sc, blurRadius: luminousCssShadowToBlurRadius(outer)),
          ],
        ),
        TextDirection.ltr,
      );
    });
  }

  /// 画一帧。
  void paint(
    Canvas canvas,
    LuminousSceneConfig config,
    LyricVisualizerRuntime runtime, {
    required double t,
    required double elapsed,
    required bool motion,
    required double breathingMultiplier,
  }) {
    if (_config != config) {
      _clear();
      _config = config;
    }
    final List<LuminousVisibleLine> visible = luminousVisibleLines(
      runtime,
      t,
      motion: motion,
    );
    // 不再可见的句子释放缓存。
    final Set<int> keep = <int>{
      for (final LuminousVisibleLine v in visible) v.index,
    };
    final List<int> drop = _lines.keys
        .where((int k) => !keep.contains(k))
        .toList();
    for (final int k in drop) {
      _lines.remove(k)!.dispose();
    }
    if (visible.isEmpty) return;

    final Size size = config.size;
    final LuminousBreath breath = motion
        ? luminousBreathAt(
            elapsed,
            breathingMultiplier,
            config.params.intensity,
          )
        : LuminousBreath.none;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2 + breath.dy);
    if (breath.scale != 1) canvas.scale(breath.scale);
    for (final LuminousVisibleLine v in visible) {
      _paintLine(canvas, _lineFor(runtime, v.index), v.fx, t, motion);
    }
    canvas.restore();
  }

  void _paintLine(
    Canvas canvas,
    _LineRender line,
    LuminousLineFx fx,
    double t,
    bool motion,
  ) {
    if (fx.opacity <= 0.004) return;
    canvas.save();
    final bool layered = !fx.isSteady;
    if (layered) {
      canvas.scale(fx.scale);
      final Paint p = Paint()
        ..color = Color.fromRGBO(0, 0, 0, fx.opacity.clamp(0.0, 1.0));
      if (fx.blur > 0.05) {
        p.imageFilter = ui.ImageFilter.blur(
          sigmaX: fx.blur,
          sigmaY: fx.blur,
          tileMode: TileMode.decal,
        );
      }
      canvas.saveLayer(null, p);
    }
    for (final _WordRender w in line.words) {
      if (motion) {
        _paintWord(canvas, line, w, t);
      } else {
        _paintStaticWord(canvas, line, w, t);
      }
    }
    if (layered) canvas.restore();
    canvas.restore();
  }

  /// 减弱动态效果：词停在布局姿态，不旋转漂移、不发光；唱过 / 在唱 / 未唱只靠颜色和透明度区分。
  void _paintStaticWord(
    Canvas canvas,
    _LineRender line,
    _WordRender w,
    double t,
  ) {
    final LuminousWordState s = w.schedule.stateAt(t);
    final double alpha = switch (s) {
      LuminousWordState.waiting => 0.45,
      LuminousWordState.active => 1.0,
      LuminousWordState.passed => 0.82,
    };
    final int colorStep = s == LuminousWordState.active ? _colorSteps : 0;
    canvas.save();
    canvas.translate(w.center.dx + w.config.x, w.center.dy + w.config.y);
    canvas.scale(w.config.scale);
    canvas.rotate(w.config.rotate * math.pi / 180);
    _body(
      w,
      line,
      colorStep,
      (alpha * _alphaSteps).round(),
    ).paint(canvas, Offset(-w.size.width / 2, -w.size.height / 2));
    canvas.restore();
  }

  void _paintWord(Canvas canvas, _LineRender line, _WordRender w, double t) {
    final LuminousLayoutParams params = _config!.params;
    final LuminousWordPose pose = luminousWordPoseAt(
      t: t,
      schedule: w.schedule,
      config: w.config,
      rotation: params.rotation,
      intensity: params.intensity,
    );
    if (pose.opacity <= 0.004) return;
    final LuminousWordReveal reveal = line.profile.wordReveal;
    final LuminousBodyState body = luminousBodyAt(
      t: t,
      schedule: w.schedule,
      reveal: reveal,
    );
    final int count = w.glows.length;
    final List<int> glowSteps = <int>[
      for (final _GlyphGlow g in w.glows)
        (luminousGlowAt(
                  t: t,
                  schedule: w.schedule,
                  reveal: reveal,
                  glyphCount: count,
                  charStart: g.start,
                  charEnd: g.end,
                  glyphIndex: g.index,
                ).clamp(0.0, 1.0) *
                _glowSteps)
            .round(),
    ];
    final bool glowing = glowSteps.any((int s) => s > 0);
    final bool blurred = body.blur > 0.3;
    final int colorStep = (body.highlight.clamp(0.0, 1.0) * _colorSteps)
        .round();
    final Offset topLeft = Offset(-w.size.width / 2, -w.size.height / 2);

    canvas.save();
    canvas.translate(w.center.dx + pose.x, w.center.dy + pose.y);
    canvas.scale(pose.scale);
    canvas.rotate(pose.rotate * math.pi / 180);
    if (!glowing && !blurred) {
      // 常见情况：不开图层，透明度烘进字色。
      _body(
        w,
        line,
        colorStep,
        (pose.opacity.clamp(0.0, 1.0) * _alphaSteps).round(),
      ).paint(canvas, topLeft);
      canvas.restore();
      return;
    }
    // 光晕层与正文层共用词容器的透明度（CSS 里 opacity 作用于整组）。
    final bool group = pose.opacity < 0.995;
    if (group) {
      canvas.saveLayer(
        null,
        Paint()..color = Color.fromRGBO(0, 0, 0, pose.opacity.clamp(0.0, 1.0)),
      );
    }
    if (glowing) {
      for (int i = 0; i < w.glows.length; i++) {
        if (glowSteps[i] <= 0) continue;
        final _GlyphGlow g = w.glows[i];
        _glow(g, glowSteps[i], line).paint(canvas, topLeft + g.offset);
      }
    }
    final TextPainter bodyPainter = _body(w, line, colorStep, _alphaSteps);
    if (blurred) {
      canvas.saveLayer(
        null,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: body.blur,
            sigmaY: body.blur,
            tileMode: TileMode.decal,
          ),
      );
      bodyPainter.paint(canvas, topLeft);
      canvas.restore();
    } else {
      bodyPainter.paint(canvas, topLeft);
    }
    if (group) canvas.restore();
    canvas.restore();
  }
}
