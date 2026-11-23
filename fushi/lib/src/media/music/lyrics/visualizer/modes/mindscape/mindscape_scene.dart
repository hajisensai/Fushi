/// 心象（folia cadenza）的逐帧绘制：folia 每帧把落点写进 DOM 叠层（正文 + 逐字 text-shadow
/// 发光），这里换成一个 CustomPainter：每个词一个缓存的 TextPainter（白字），颜色 / 透明度 /
/// 模糊用 saveLayer 的颜色滤镜与图像滤镜叠上去，发光用带阴影的透明字。
///
/// 动画状态（位置 / 角度 / 缩放 / 透明度 / 模糊 / 混色 / 发光）按帧间隔指数逼近目标，与 folia
/// `VisualizerCadenza.tsx` 的 draw 循环同一套系数。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/mindscape/mindscape_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/mindscape/mindscape_timing.dart';

/// 样式参数键（落库，冻结）。
abstract final class MindscapeTuningKeys {
  static const String fontScale = 'fontScale';
  static const String widthRatio = 'widthRatio';
  static const String motionAmount = 'motionAmount';
  static const String glowIntensity = 'glowIntensity';
}

/// 一帧用到的配置（来自 [LyricVisualizerContext] + 布局约束）。
@immutable
class MindscapeConfig {
  const MindscapeConfig({
    required this.runtime,
    required this.palette,
    required this.baseStyle,
    required this.motion,
    required this.fontScale,
    required this.widthRatio,
    required this.motionAmount,
    required this.glowIntensity,
    required this.intensity,
    this.fontWeight = FontWeight.w700,
    this.theme,
    this.audioPower,
  });

  factory MindscapeConfig.of(LyricVisualizerContext c, TextStyle baseStyle) {
    final LyricVisualizerTuning t = c.tuning;
    return MindscapeConfig(
      runtime: c.runtime,
      palette: c.palette,
      baseStyle: c.theme?.fontFamily == null
          ? baseStyle
          : baseStyle.copyWith(fontFamily: c.theme!.fontFamily),
      motion: c.motion,
      fontScale: t.number(MindscapeTuningKeys.fontScale, 1.12) * c.fontScale,
      widthRatio: t.number(MindscapeTuningKeys.widthRatio, 0.72),
      motionAmount: t.number(MindscapeTuningKeys.motionAmount, 1),
      glowIntensity: t.number(MindscapeTuningKeys.glowIntensity, 1),
      intensity: c.intensity,
      fontWeight: c.theme?.fontWeight ?? FontWeight.w700,
      theme: c.theme,
      audioPower: (int displayMs) => c.audioFrameAt(displayMs).power,
    );
  }

  final LyricVisualizerRuntime runtime;
  final LyricVisualizerPalette palette;
  final TextStyle baseStyle;
  final bool motion;
  final double fontScale;
  final double widthRatio;
  final double motionAmount;
  final double glowIntensity;

  /// 共享动画强度（`context.intensity`：主题指定或全局偏好）。
  final LyricVisualizerIntensity intensity;

  /// 主题字重（folia `resolveThemeFontWeight(theme, 700)`）。
  final FontWeight fontWeight;

  /// 歌词动画主题：按词着色（folia `resolveWordColor(word, wordColors, accentColor)`）。
  final LyricVisualizerTheme? theme;

  /// 音频响度（folia `audioPower / 255`；没有音频分析时框架回落歌词起字包络）。null = 0。
  final double Function(int displayMs)? audioPower;

  /// 词的高亮色。
  Color activeColorFor(String word) =>
      theme?.resolveWordColor(word, palette.accent) ?? palette.accent;
}

/// 一个落点的平滑动画状态（folia `AnimatedPlacementState`）。
class MindscapeAnimatedState {
  MindscapeAnimatedState({
    required this.x,
    required this.y,
    required this.rotation,
    required this.scale,
    required this.bodyAlpha,
    required this.blur,
    required this.activeMix,
    required this.glowAlpha,
  });

  double x;
  double y;

  /// 度。
  double rotation;
  double scale;
  double bodyAlpha;
  double blur;
  double activeMix;
  double glowAlpha;
}

/// 一个落点的缓存文字：正文（白字，按需上色）与发光（透明字 + 阴影；拉丁词逐字一份）。
class _WordPaint {
  _WordPaint(this.body, this.baselineY);

  final TextPainter body;

  /// 正文基线相对锚点的纵坐标（已含 folia 的 CSS 行盒与墨迹顶对齐，见 [MindscapeScene._buildPaint]）。
  final double baselineY;
  TextPainter? glow;
  List<TextPainter>? glyphGlows;
  List<double>? glyphOffsets;

  void dispose() {
    body.dispose();
    glow?.dispose();
    for (final TextPainter p in glyphGlows ?? const <TextPainter>[]) {
      p.dispose();
    }
  }
}

/// CSS text-shadow 40px 模糊半径（σ = 20）→ Flutter Shadow.blurRadius（σ = r·0.57735 + 0.5 ≈ 20.1）。
const double _glowBlurRadius = 34;
const List<MindscapeWordStatus> _drawOrder = <MindscapeWordStatus>[
  MindscapeWordStatus.waiting,
  MindscapeWordStatus.passed,
  MindscapeWordStatus.active,
];

/// 跨帧的场景：准备态缓存、文字缓存、动画状态。由样式的 State 持有并释放。
class MindscapeScene {
  final Map<int, MindscapePrepared?> _prepared = <int, MindscapePrepared?>{};
  final Map<int, MindscapeSourceLine> _sources = <int, MindscapeSourceLine>{};
  final Map<String, MindscapeAnimatedState> _states =
      <String, MindscapeAnimatedState>{};
  final Map<String, _WordPaint> _paints = <String, _WordPaint>{};
  final TextPainter _measurer = TextPainter(textDirection: TextDirection.ltr);
  Object? _cacheKey;
  LyricVisualizerRuntime? _sourcesFor;
  double? _lastElapsed;
  int? _drawnLine;

  /// 当前画着的行（测试用）。
  int? get drawnLine => _drawnLine;

  /// 当前行的落点（测试用）。
  List<MindscapePlacement> get currentPlacements => _drawnLine == null
      ? const <MindscapePlacement>[]
      : _prepared[_drawnLine]?.placements ?? const <MindscapePlacement>[];

  /// 落点的动画状态（测试用）。
  @visibleForTesting
  MindscapeAnimatedState? debugStateOf(String id) => _states[id];

  void dispose() {
    _clearPaints();
    _measurer.dispose();
  }

  void _clearPaints() {
    for (final _WordPaint p in _paints.values) {
      p.dispose();
    }
    _paints.clear();
  }

  TextStyle _style(MindscapeConfig c, double fontPx) => c.baseStyle.copyWith(
    fontSize: fontPx,
    fontWeight: c.fontWeight,
    color: const Color(0xFFFFFFFF),
    height: 1,
    shadows: const <Shadow>[],
    decoration: TextDecoration.none,
    letterSpacing: 0,
  );

  double _measure(MindscapeConfig c, String text, double fontPx) {
    _measurer.text = TextSpan(text: text, style: _style(c, fontPx));
    _measurer.layout();
    return _measurer
        .getOffsetForCaret(TextPosition(offset: text.length), Rect.zero)
        .dx;
  }

  MindscapeSourceLine _sourceOf(MindscapeConfig c, int index) {
    if (!identical(_sourcesFor, c.runtime)) {
      _sourcesFor = c.runtime;
      _sources.clear();
    }
    return _sources[index] ??= mindscapeSourceOf(c.runtime.lines[index]);
  }

  MindscapePrepared? _prepare(MindscapeConfig c, Size size, int index) {
    if (_prepared.containsKey(index)) return _prepared[index];
    final MindscapePrepared? p = mindscapePrepare(
      _sourceOf(c, index),
      viewportWidth: size.width,
      viewportHeight: size.height,
      fontScale: c.fontScale,
      widthRatio: c.widthRatio,
      intensity: c.intensity,
      measure: (String text, double fontPx) => _measure(c, text, fontPx),
    );
    _prepared[index] = p;
    return p;
  }

  /// 正在唱的行；刚唱完、还在离场窗口（renderEndTime）里的也算（folia 用 renderEndTime 判行尾）。
  int _activeLine(MindscapeConfig c, int timeMs, double time) {
    final LyricVisualizerRuntime rt = c.runtime;
    final int active = rt.activeLineAt(timeMs);
    if (active >= 0) return active;
    final int last = rt.lastStartedLineAt(timeMs);
    if (last < 0) return -1;
    return time <= _sourceOf(c, last).timing.lineRenderEndTime ? last : -1;
  }

  /// 画一帧。
  void paint(
    Canvas canvas,
    Size size,
    MindscapeConfig c,
    int timeMs,
    double elapsed,
  ) {
    if (size.isEmpty) return;
    final Object key = Object.hash(
      size.width.floor(),
      size.height.floor(),
      c.fontScale,
      c.widthRatio,
      c.intensity,
      c.baseStyle.fontFamily,
      c.fontWeight,
      c.theme,
      c.runtime,
    );
    if (key != _cacheKey) {
      _cacheKey = key;
      _prepared.clear();
      _states.clear();
      _clearPaints();
    }
    final double dt = _lastElapsed == null
        ? 1 / 60
        : mindscapeClamp(elapsed - _lastElapsed!, 1 / 240, 0.05);
    _lastElapsed = elapsed;
    final double time = timeMs / 1000;
    final int lineIndex = _activeLine(c, timeMs, time);
    // 预热下一句（folia `prepareActiveAndUpcoming`）。
    final int upcoming = c.runtime.lastStartedLineAt(timeMs) + 1;
    if (upcoming < c.runtime.lines.length) _prepare(c, size, upcoming);
    final MindscapePrepared? prepared = lineIndex < 0
        ? null
        : _prepare(c, size, lineIndex);
    if (lineIndex != (_drawnLine ?? -1)) {
      _drawnLine = lineIndex < 0 ? null : lineIndex;
      // folia 换行时只删新行里没有的落点状态（id 不含行号）：相邻两句同位置的同一个词
      // 接着上一句的状态动；间奏里没有当前行，状态全清。
      final Set<String> keep = <String>{
        for (final MindscapePlacement p
            in prepared?.placements ?? const <MindscapePlacement>[])
          p.id,
      };
      _states.removeWhere(
        (String k, MindscapeAnimatedState _) => !keep.contains(k),
      );
      _clearPaints();
      // 只留当前与下一句的准备态，免得长歌越攒越多。
      _prepared.removeWhere(
        (int k, MindscapePrepared? _) => k != lineIndex && k != upcoming,
      );
    }
    if (prepared == null || prepared.placements.isEmpty) return;
    _paintLine(canvas, size, c, prepared, time, dt);
  }

  void _paintLine(
    Canvas canvas,
    Size size,
    MindscapeConfig c,
    MindscapePrepared prepared,
    double time,
    double dt,
  ) {
    final bool motion = c.motion;
    final MindscapeSourceLine source = prepared.source;
    final MindscapeLineTiming timing = source.timing;
    final MindscapeLineEnvelope envelope = motion
        ? mindscapeLineEnvelope(time, timing)
        : MindscapeLineEnvelope.identity;
    if (envelope.opacity <= 0.001) return;
    final LyricVisualizerWordReveal reveal = timing.wordReveal;
    final bool instant = reveal == LyricVisualizerWordReveal.instant;
    final bool chaotic = c.intensity == LyricVisualizerIntensity.chaotic;
    // folia 的 audioPower / 255：共享音频帧（没有分析时框架回落歌词起字包络）。
    final double energy = motion && c.audioPower != null
        ? c.audioPower!((time * 1000).round()).clamp(0.0, 1.0)
        : 0;
    final double motionEnergy = energy * c.motionAmount;
    final double verticalLift = motion
        ? math.sin(time * 2.3) * (3 + motionEnergy * 8)
        : 0;
    final double width = size.width;
    final double focusY = size.height * 0.42 + verticalLift;
    final Color baseColor = c.palette.text;

    canvas.save();
    // 整行绕 (50%, 42%) 缩放（folia lineLayer 的 transform-origin）。CSS 的 filter / opacity
    // 在元素自身坐标里做、再整体 transform，所以先缩放再开图层：模糊半径跟着缩放。
    final double ox = width / 2;
    final double oy = size.height * 0.42;
    canvas.translate(ox, oy);
    canvas.scale(envelope.scale);
    canvas.translate(-ox, -oy);
    final bool lineLayer = envelope.opacity < 0.999 || envelope.blur > 0.05;
    if (lineLayer) {
      canvas.saveLayer(
        null,
        Paint()
          ..color = Color.fromRGBO(0, 0, 0, envelope.opacity)
          ..imageFilter = envelope.blur > 0.05
              ? ui.ImageFilter.blur(
                  sigmaX: envelope.blur,
                  sigmaY: envelope.blur,
                  tileMode: TileMode.decal,
                )
              : null,
      );
    }
    final Map<MindscapeWordStatus, List<int>> buckets =
        <MindscapeWordStatus, List<int>>{
          for (final MindscapeWordStatus s in _drawOrder) s: <int>[],
        };
    final List<MindscapePlacement> placements = prepared.placements;
    for (int i = 0; i < placements.length; i++) {
      buckets[mindscapeWordStatus(time, timing, placements[i].word.time)]!.add(
        i,
      );
    }

    final double tAmount = 1 - math.exp(-11 * dt);
    final double vAmount = 1 - math.exp(-14 * dt);
    final double gAmount = 1 - math.exp(-16 * dt);
    // 副歌涟漪画在 folia 的文字 canvas 上，那块 canvas 叠在所有词的 DOM 之上：攒到最后画。
    final List<(Offset, double, Color)> ripples = <(Offset, double, Color)>[];
    int drawIndex = -1;
    for (final MindscapeWordStatus status in _drawOrder) {
      for (final int pi in buckets[status]!) {
        drawIndex++;
        final MindscapePlacement p = placements[pi];
        final MindscapeWordTime wt = p.word.time;
        // 落点的高亮色（folia `placement.color`：按词着色）。
        final Color accent = c.activeColorFor(p.word.text);
        final double progress = mindscapeWordProgress(time, reveal, wt);
        final double passedAlpha = instant ? 0 : (chaotic ? 0.9 : 0.82);
        final double pulse =
            motion && status == MindscapeWordStatus.active && !instant
            ? 1 +
                  math.sin(
                        time * mindscapeActivePulseFrequency + wt.startTime * 5,
                      ) *
                      0.04 *
                      c.motionAmount
            : 1;
        final double driftProgress = instant || !motion
            ? 0
            : mindscapePassedDrift(time, wt);
        double targetScale;
        double targetRotation;
        double targetAlpha;
        double targetBlur;
        if (motion) {
          targetScale = switch (status) {
            MindscapeWordStatus.waiting =>
              instant ? p.scale : math.max(p.scale * 0.5, 0.5),
            MindscapeWordStatus.active =>
              instant ? p.scale : p.scale * 1.3 * pulse,
            MindscapeWordStatus.passed => p.scale,
          };
          targetRotation = switch (status) {
            MindscapeWordStatus.waiting => instant ? 0 : 20,
            MindscapeWordStatus.passed =>
              instant ? 0 : p.passedRotate * driftProgress,
            MindscapeWordStatus.active => 0,
          };
          targetAlpha = switch (status) {
            MindscapeWordStatus.waiting => 0,
            MindscapeWordStatus.active => 1,
            MindscapeWordStatus.passed => passedAlpha,
          };
          targetBlur = status == MindscapeWordStatus.waiting && !instant
              ? 10
              : 0;
        } else {
          // 减弱动态效果：整句静止铺开，未唱的淡、唱过的略淡，不转不缩不糊。
          targetScale = p.scale;
          targetRotation = 0;
          targetAlpha = switch (status) {
            MindscapeWordStatus.waiting => 0.35,
            MindscapeWordStatus.active => 1,
            MindscapeWordStatus.passed => 0.82,
          };
          targetBlur = 0;
        }
        final double floatX = motion
            ? math.sin(time * 1.2 + drawIndex * 0.6) * motionEnergy * 4
            : 0;
        final double floatY = motion
            ? math.cos(time * 1.5 + drawIndex * 0.4) * motionEnergy * 2.5
            : 0;
        final bool passed = status == MindscapeWordStatus.passed;
        final double targetX =
            width / 2 +
            p.x +
            floatX +
            (passed ? p.passedDriftX * driftProgress : 0);
        final double targetY =
            focusY +
            p.y +
            floatY +
            (passed ? p.passedDriftY * driftProgress : 0);
        final double targetMix = mindscapeBodyMix(time, timing, wt);
        final double targetGlow = motion
            ? mindscapeGlowEnvelope(time, timing, wt)
            : 0;

        final String id = p.id;
        MindscapeAnimatedState? s = _states[id];
        if (!motion) {
          s = MindscapeAnimatedState(
            x: targetX,
            y: targetY,
            rotation: targetRotation,
            scale: targetScale,
            bodyAlpha: targetAlpha,
            blur: targetBlur,
            activeMix: targetMix,
            glowAlpha: targetGlow,
          );
        } else {
          if (s == null) {
            final bool asActive = instant && time >= wt.startTime;
            s = MindscapeAnimatedState(
              x: width / 2 + p.x,
              y: focusY + p.y,
              rotation: asActive ? targetRotation : targetRotation + 16,
              scale: asActive ? targetScale : math.max(p.scale * 0.5, 0.5),
              bodyAlpha: asActive ? targetAlpha : 0,
              blur: asActive ? targetBlur : 10,
              activeMix: asActive ? targetMix : 0,
              glowAlpha: asActive ? targetGlow : 0,
            );
          }
          s
            ..x = mindscapeMix(s.x, targetX, tAmount)
            ..y = mindscapeMix(s.y, targetY, tAmount)
            ..rotation = mindscapeMix(s.rotation, targetRotation, tAmount)
            ..scale = mindscapeMix(s.scale, targetScale, tAmount)
            ..bodyAlpha = mindscapeMix(s.bodyAlpha, targetAlpha, vAmount)
            ..blur = mindscapeMix(s.blur, targetBlur, vAmount)
            ..activeMix = mindscapeMix(s.activeMix, targetMix, vAmount)
            ..glowAlpha = mindscapeMix(s.glowAlpha, targetGlow, gAmount);
        }
        _states[id] = s;
        if (s.bodyAlpha < 0.015 && s.glowAlpha < 0.015) continue;

        final double visualWidth = p.width * s.scale;
        final double visualHeight = p.height * s.scale;
        final double anchorX = s.x + p.width / 2;
        final double anchorY = s.y - p.height * 0.42;

        // 副歌：正在唱的词外扩一圈渐隐涟漪。
        if (motion &&
            status == MindscapeWordStatus.active &&
            !p.isInterlude &&
            source.isChorus) {
          final double highlightHeight = visualHeight * 1.08;
          final double radius =
              math.max(visualWidth, highlightHeight) * (0.55 + progress * 0.45);
          final double a = 0.45 * (1 - progress) * s.bodyAlpha;
          if (a > 0.005) {
            ripples.add((
              Offset(anchorX, s.y - visualHeight * 0.42),
              radius,
              accent.withValues(alpha: a.clamp(0.0, 1.0)),
            ));
          }
        }

        final _WordPaint wp = _paints[id] ??= _buildPaint(c, prepared, p);
        canvas.save();
        canvas.translate(anchorX, anchorY);
        canvas.rotate(s.rotation * math.pi / 180);
        canvas.scale(s.scale);
        final Offset textOrigin = Offset(-p.width / 2, wp.baselineY);

        // 发光在正文后面（folia glow span z-index 0）。
        if (s.glowAlpha > 0.001 && c.glowIntensity > 0) {
          final bool split =
              reveal == LyricVisualizerWordReveal.normal &&
              !mindscapeContainsCjk(p.text) &&
              p.text.characters.length > 1;
          final double glowAlpha =
              s.glowAlpha.clamp(0.0, 1.0) * c.glowIntensity;
          if (split) {
            _ensureGlyphGlows(c, prepared, p, wp, accent);
            for (int g = 0; g < wp.glyphGlows!.length; g++) {
              final double intensity =
                  mindscapeCharGlow(
                    time,
                    wt,
                    p.fragmentStartInWord + g,
                    math.max(p.wordGraphemeCount, wp.glyphGlows!.length),
                    p.word.glyphTimes,
                  ) *
                  glowAlpha;
              _paintGlow(
                canvas,
                wp.glyphGlows![g],
                textOrigin + Offset(wp.glyphOffsets![g], 0),
                intensity,
              );
            }
          } else {
            wp.glow ??= _glowPainter(c, prepared.fontPx, p.text, accent);
            final double intensity =
                mindscapeGlowEnvelope(time, timing, wt) * glowAlpha;
            _paintGlow(canvas, wp.glow!, textOrigin, intensity);
          }
        }

        if (s.bodyAlpha >= 0.015) {
          final Color color = Color.lerp(
            baseColor,
            accent,
            s.activeMix.clamp(0.0, 1.0),
          )!;
          final double alpha = (s.bodyAlpha * color.a).clamp(0.0, 1.0);
          final double pad = s.blur * 3 + 2;
          final Rect bounds = Rect.fromLTWH(
            textOrigin.dx - pad,
            textOrigin.dy - pad,
            wp.body.width + pad * 2,
            wp.body.height + pad * 2,
          );
          canvas.saveLayer(
            bounds,
            Paint()
              ..colorFilter = ColorFilter.mode(
                color.withValues(alpha: alpha),
                BlendMode.srcIn,
              )
              ..imageFilter = s.blur > 0.05
                  ? ui.ImageFilter.blur(
                      sigmaX: s.blur,
                      sigmaY: s.blur,
                      tileMode: TileMode.decal,
                    )
                  : null,
          );
          wp.body.paint(canvas, textOrigin);
          canvas.restore();
        }
        canvas.restore();
      }
    }

    for (final (Offset center, double radius, Color color) in ripples) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = color,
      );
    }

    if (lineLayer) canvas.restore();
    canvas.restore();
  }

  _WordPaint _buildPaint(
    MindscapeConfig c,
    MindscapePrepared prepared,
    MindscapePlacement p,
  ) {
    final double fontPx = prepared.fontPx;
    final TextStyle style = _style(c, fontPx);
    final TextPainter body = TextPainter(
      text: TextSpan(text: p.text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    // folia 把词放进 line-height:1 的 DOM 盒里，再把盒顶上移「墨迹顶」(actualBoundingBoxAscent)，
    // 让墨迹顶落在锚点下 height·0.42 处：基线 = 0.42·height − 墨迹顶 + CSS 行盒里的基线
    // （半行距 (1em − 字体 ascent − descent)/2 + ascent）。字体 ascent / descent 取不带 height 的
    // 自然行度量；Flutter 的 height:1 按比例分配行距，基线位置与 CSS 不同，所以不能直接用 body 的。
    _measurer
      ..text = TextSpan(text: p.text, style: style.copyWith(height: null))
      ..layout();
    final List<ui.LineMetrics> metrics = _measurer.computeLineMetrics();
    final double cssBaseline = metrics.isEmpty
        ? fontPx * 0.8
        : (fontPx + metrics.first.ascent - metrics.first.descent) / 2;
    final double ink = mindscapeInkAscentEm(p.text) * fontPx;
    final double bodyBaseline = body.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    return _WordPaint(body, p.height * 0.42 - ink + cssBaseline - bodyBaseline);
  }

  TextPainter _glowPainter(
    MindscapeConfig c,
    double fontPx,
    String text,
    Color color,
  ) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: _style(c, fontPx).copyWith(
          color: const Color(0x00000000),
          shadows: <Shadow>[Shadow(color: color, blurRadius: _glowBlurRadius)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  void _ensureGlyphGlows(
    MindscapeConfig c,
    MindscapePrepared prepared,
    MindscapePlacement p,
    _WordPaint wp,
    Color color,
  ) {
    if (wp.glyphGlows != null) return;
    final List<String> glyphs = p.text.characters.toList();
    final List<TextPainter> painters = <TextPainter>[];
    final List<double> offsets = <double>[];
    int utf16 = 0;
    for (final String g in glyphs) {
      offsets.add(
        wp.body.getOffsetForCaret(TextPosition(offset: utf16), Rect.zero).dx,
      );
      painters.add(_glowPainter(c, prepared.fontPx, g, color));
      utf16 += g.length;
    }
    wp
      ..glyphGlows = painters
      ..glyphOffsets = offsets;
  }

  /// folia `buildDomTextShadow` 的三层同半径 40px 阴影逐层画（各自透明度，逐像素 over 叠加）。
  /// 不能先合成一个总透明度再画一层：模糊边缘覆盖率 m 处三层叠出的是 1 − Π(1 − aᵢ·m)，
  /// 比 (1 − Π(1 − aᵢ))·m 亮得多、晕得更开，合成一层的辉光明显偏弱偏窄。
  void _paintGlow(
    Canvas canvas,
    TextPainter glow,
    Offset at,
    double intensity,
  ) {
    final (double a1, double a2, double a3) = mindscapeGlowAlphas(intensity);
    if (a1 <= 0.01) return;
    const double pad = _glowBlurRadius * 2;
    final Rect bounds = Rect.fromLTWH(
      at.dx - pad,
      at.dy - pad,
      glow.width + pad * 2,
      glow.height + pad * 2,
    );
    for (final double a in <double>[a1, a2, a3]) {
      if (a <= 0.004) continue;
      canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, a));
      glow.paint(canvas, at);
      canvas.restore();
    }
  }
}
