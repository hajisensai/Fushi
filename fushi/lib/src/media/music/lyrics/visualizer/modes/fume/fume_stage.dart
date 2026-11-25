/// 浮名的舞台（folia `useFumeCanvasStage.ts` + `fumeBlockFrame.ts` + `fumeCanvasText.ts`）：
/// 每帧先画世界背景，再把镜头下看得到的每一块画出来——等待 / 唱过的块用缓存的整行段落，
/// 正在打印的块逐字算颜色、辉光与「打印方块」。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_article_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_background.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_camera.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_timeline.dart';

/// 一次构建内不变的场景（歌词 / 尺寸 / 配色 / 参数变了才换）。
@immutable
class FumeScene {
  const FumeScene({
    required this.runtime,
    required this.lines,
    required this.article,
    required this.viewport,
    required this.background,
    required this.overview,
    required this.overviewStartTime,
    required this.passedFadeDuration,
    required this.text,
    required this.secondary,
    required this.accent,
    required this.cameraSpeed,
    required this.tracking,
    required this.glowIntensity,
    required this.backgroundObjectOpacity,
    required this.showPrintStamp,
    required this.textHoldRatio,
    required this.motion,
    this.font = FumeFont.standard,
    this.theme,
    this.intensity = LyricVisualizerIntensity.normal,
    this.audioAt,
  });

  final LyricVisualizerRuntime runtime;
  final List<FumeLine> lines;
  final FumeArticle? article;
  final Size viewport;
  final FumeBackgroundScene background;
  final FumeViewTarget? overview;
  final double overviewStartTime;
  final double passedFadeDuration;

  /// folia theme.primaryColor（正文字色）。
  final Color text;
  final Color secondary;

  /// folia theme.accentColor（正在唱的字与辉光）。
  final Color accent;
  final double cameraSpeed;
  final FumeTrackingMode tracking;
  final double glowIntensity;
  final double backgroundObjectOpacity;
  final bool showPrintStamp;
  final double textHoldRatio;
  final bool motion;

  /// 主题字重 / 字体。
  final FumeFont font;

  /// 歌词动画主题（按词着色 `wordColors`）；null = 没有。
  final LyricVisualizerTheme? theme;

  /// 主题强度（folia `theme.animationIntensity`）：辉光底数与镜头漂浮幅度。
  final LyricVisualizerIntensity intensity;

  /// 一帧音频（歌词显示时间毫秒 → 帧；`LyricVisualizerContext.audioFrameAt`）；null = 静音。
  final LyricVisualizerAudioFrame Function(int displayMs)? audioAt;

  /// 正在唱的字色（folia `getActiveColor`：按词查主题 wordColors，CJK 互相包含即命中，没命中用
  /// accent）。
  Color activeColorFor(String word) =>
      theme?.resolveWordColor(
        word,
        accent,
        cjkMatch: LyricVisualizerCjkMatch.bidirectional,
      ) ??
      accent;

  double? nextLineStart(int lineIndex) =>
      lineIndex + 1 < lines.length ? lines[lineIndex + 1].start : null;
}

/// folia `resolveFumeGlowBases`：(当前句辉光, 唱过残光) 按主题强度取底数（calm 0.72 / 0.35、
/// normal 0.92 / 0.62、chaotic 1.15 / 0.95），再乘「辉光强度」参数。
(double, double) fumeGlowBases(
  LyricVisualizerIntensity intensity,
  double glowIntensity,
) => (
  intensity.pick(0.72, 0.92, 1.15) * glowIntensity,
  intensity.pick(0.35, 0.62, 0.95) * glowIntensity,
);

/// 音频帧 → 背景火花的频段电平（folia `readFumeAudioLevels`，0–255 量级，下限 10）：bass ← 低频、
/// lowMid ← 中低频（150–400 Hz）、mid ← 中高频（400–1200 Hz，folia `audioBands.mid`）、vocal ← 人声、
/// treble ← 高频。旧分析结果没有分段时两段都回落到合并的中频。
/// 没有音频分析时帧是歌词起字包络的代用品，各段衰减快慢不同。
FumeBackgroundLevels fumeBackgroundLevelsOf(LyricVisualizerAudioFrame f) {
  double lv(double v) => 10 + 190 * v.clamp(0.0, 1.0);
  return <FumeAudioBand, double>{
    FumeAudioBand.bass: lv(f.low),
    FumeAudioBand.lowMid: lv(f.lowMid),
    FumeAudioBand.mid: lv(f.upperMid),
    FumeAudioBand.vocal: lv(f.vocal),
    FumeAudioBand.treble: lv(f.high),
  };
}

/// 一块此刻的时序与样式（folia `resolveFumeBlockTiming`）。
class FumeBlockTiming {
  FumeBlockTiming(FumeBlock block, double t, double? nextStart, double hold)
    : waitingOpacity = block.hero ? 0.06 : 0.035,
      activeOpacity = block.hero ? 0.985 : 0.92,
      holdStyle = hold >= 1 ? FumeHoldStyle.standard : FumeHoldStyle.dimmed,
      transitionStyle = fumePassedTextStyle(
        block.variant,
        FumeHoldStyle.standard,
      ),
      lineEndTime = block.line.renderEnd,
      passCutoff = fumeLinePassCutoffTime(block.line, nextStart),
      revealCompleted = t >= block.line.end,
      lineDuration = math.max(block.line.renderEnd - block.line.start, 0.18) {
    passCutoffReached = t >= passCutoff;
    passedStyle = fumePassedTextStyle(block.variant, holdStyle);
    colorTrailDuration = fumeClamp(
      lineDuration * (block.hero ? 0.42 : 0.52),
      0.45,
      1.45,
    );
    staticState = t < block.line.start
        ? FumeStaticState.waiting
        : t >= lineEndTime + colorTrailDuration
        ? FumeStaticState.passed
        : null;
  }

  final double waitingOpacity;
  final double activeOpacity;
  final FumeHoldStyle holdStyle;
  final FumePassedStyle transitionStyle;
  final double lineEndTime;
  final double passCutoff;
  final bool revealCompleted;
  final double lineDuration;
  late final bool passCutoffReached;
  late final FumePassedStyle passedStyle;
  late final double colorTrailDuration;

  /// 不在打印、也不在颜色拖尾里：用缓存的整行画。
  late final FumeStaticState? staticState;
}

enum FumeStaticState { waiting, passed }

/// 一种统一样式（整行同色同辉光）。
@immutable
class FumeUniformStyle {
  const FumeUniformStyle(this.fill, this.blur, this.shadow);

  final Color fill;

  /// Canvas 2D 语义的 shadowBlur（像素）。
  final double blur;
  final Color shadow;

  String get key =>
      '${fill.toARGB32()}|${blur.toStringAsFixed(1)}|${shadow.toARGB32()}';
}

/// 唱过 / 等待块此刻的样式（folia `resolveFumeStaticLayers`；两层交叉淡化在字形完全重合时
/// 等价于一层插值样式，这里按 1/32 量化后合成一层）。
FumeUniformStyle fumeStaticStyle({
  required FumeBlock block,
  required FumeBlockTiming timing,
  required double t,
  required Color text,
  required double passedGlowBase,
  required double passedFadeDuration,
  required double overviewRestore,
}) {
  if (timing.staticState == FumeStaticState.waiting) {
    return FumeUniformStyle(
      text.withValues(alpha: timing.waitingOpacity),
      0,
      const Color(0x00000000),
    );
  }
  FumeUniformStyle styleOf(FumePassedStyle s) => FumeUniformStyle(
    text.withValues(alpha: s.opacity),
    (2 + block.fontPx * 0.1) * 0.65 * passedGlowBase * s.glowMultiplier,
    text.withValues(alpha: s.shadowAlphaBase),
  );
  if (timing.holdStyle == FumeHoldStyle.standard) {
    return styleOf(timing.passedStyle);
  }
  final double passedAt = timing.lineEndTime + timing.colorTrailDuration;
  final double dim =
      (fumePassedDimAmount(t, passedAt, passedFadeDuration) *
              (1 - overviewRestore) *
              32)
          .round() /
      32;
  final FumeUniformStyle a = styleOf(timing.transitionStyle);
  final FumeUniformStyle b = styleOf(timing.passedStyle);
  if (dim <= 0) return a;
  if (dim >= 1) return b;
  return FumeUniformStyle(
    Color.lerp(a.fill, b.fill, dim)!,
    fumeMix(a.blur, b.blur, dim),
    Color.lerp(a.shadow, b.shadow, dim)!,
  );
}

/// Canvas 2D 的 shadowBlur（≈ 2σ）→ Flutter `Shadow.blurRadius`（σ = r·0.577 + 0.5）。
double fumeShadowRadius(double canvasBlur) =>
    canvasBlur <= 1 ? 0 : math.max(0, (canvasBlur / 2 - 0.5) / 0.57735);

List<Shadow>? _shadows(double canvasBlur, Color color) {
  final double r = fumeShadowRadius(canvasBlur);
  if (r <= 0 || color.a <= 0.002) return null;
  return <Shadow>[Shadow(color: color, blurRadius: r)];
}

TextStyle _style(
  FumeBlock b,
  FumeFont font,
  Color fill,
  double blur,
  Color shadow,
) => fumeTextStyle(
  b.variant,
  b.fontPx,
  font,
).copyWith(color: fill, shadows: _shadows(blur, shadow));

class _CachedPainter {
  _CachedPainter(this.painter, this.frame);

  final TextPainter painter;
  int frame;
}

/// 舞台：每个挂载的样式一份，持有镜头状态与段落缓存。
class FumeStage {
  final FumeCameraState cameraState = FumeCameraState();
  final FumeBackgroundPainter _background = FumeBackgroundPainter();
  FumeFont _font = FumeFont.standard;
  final Map<String, _CachedPainter> _painters = <String, _CachedPainter>{};
  FumeArticle? _article;
  LyricVisualizerTick? _steppedTick;
  double? _lastElapsed;
  double _printedScale = 0.985;
  FumeCameraStepResult _step = const FumeCameraStepResult(false, 0);
  int _frame = 0;

  /// 场景换了：文章变了就清段落缓存、重新放镜头。
  void attach(FumeScene scene) {
    _font = scene.font;
    if (!identical(scene.article, _article)) {
      _article = scene.article;
      _clearPainters();
      cameraState.syncToArticle(scene.article);
      _printedScale = 0.985;
    } else {
      cameraState.syncToArticle(scene.article);
    }
  }

  void _clearPainters() {
    for (final _CachedPainter p in _painters.values) {
      p.painter.dispose();
    }
    _painters.clear();
  }

  void dispose() {
    _clearPainters();
    _background.clear();
  }

  TextPainter _uniformPainter(FumeBlock b, int lineIndex, FumeUniformStyle s) {
    final String key = '${b.id}|$lineIndex|${s.key}';
    final _CachedPainter? hit = _painters[key];
    if (hit != null) {
      hit.frame = _frame;
      return hit.painter;
    }
    final TextPainter p = TextPainter(
      text: TextSpan(
        text: b.renderLines[lineIndex].text,
        style: _style(b, _font, s.fill, s.blur, s.shadow),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    _painters[key] = _CachedPainter(p, _frame);
    return p;
  }

  void _sweep() {
    if (_frame % 60 != 0 && _painters.length < 800) return;
    final List<String> stale = <String>[
      for (final MapEntry<String, _CachedPainter> e in _painters.entries)
        if (_frame - e.value.frame > 240) e.key,
    ];
    for (final String k in stale) {
      _painters.remove(k)!.painter.dispose();
    }
  }

  /// 画一帧。
  void paint(
    Canvas canvas,
    Size size,
    FumeScene scene,
    LyricVisualizerTick tick,
  ) {
    _frame++;
    final double t = tick.timeMs / 1000;
    final double wall = tick.elapsed;
    final bool fresh = !identical(tick, _steppedTick);
    double dt = 1 / 60;
    if (fresh) {
      final double? last = _lastElapsed;
      dt = last == null ? 1 / 60 : fumeClamp(wall - last, 1 / 240, 0.05);
      _lastElapsed = wall;
    }
    canvas
      ..save()
      ..clipRect(Offset.zero & size);
    final Offset center = size.center(Offset.zero);
    final FumeArticle? article = scene.article;
    final FumeBackgroundLevels levels = _levels(scene, tick.timeMs);

    if (article == null) {
      if (scene.motion) {
        canvas
          ..save()
          ..translate(center.dx, center.dy)
          ..translate(
            -scene.background.size.width * 0.5,
            -scene.background.size.height * 0.5,
          );
        _background.paint(
          canvas,
          scene: scene.background,
          secondary: scene.secondary,
          accent: scene.accent,
          time: t + wall * 0.18,
          levels: levels,
          objectOpacity: scene.backgroundObjectOpacity * 2,
        );
        canvas.restore();
      }
      canvas.restore();
      return;
    }

    if (fresh) {
      _steppedTick = tick;
      // 第一块开始打印前整张略缩（0.985），开唱后 0.45 秒舒展到 1。
      final double target = t >= article.firstRenderableStart ? 1 : 0.985;
      _printedScale = scene.motion
          ? _printedScale + (target - _printedScale) * (1 - math.exp(-dt * 6.5))
          : target;
      _step = fumeStepCamera(
        cameraState,
        article: article,
        time: t,
        wallSeconds: wall,
        dt: dt,
        lineIndex: scene.runtime.displayedLineAt(tick.timeMs),
        viewport: size,
        overview: scene.overview,
        overviewStartTime: scene.overviewStartTime,
        cameraSpeed: scene.cameraSpeed,
        tracking: scene.tracking,
        motion: scene.motion,
        intensity: scene.intensity,
      );
    }
    final FumeCamera cam = cameraState.camera;
    canvas
      ..translate(center.dx, center.dy)
      ..scale(_printedScale)
      ..translate(-center.dx, -center.dy);

    if (scene.motion) {
      final ({
        double centerX,
        double centerY,
        double cameraX,
        double cameraY,
        double scale,
      })
      view = fumeBackgroundView(scene.background.size, cam, size);
      canvas
        ..save()
        ..translate(center.dx, center.dy)
        ..scale(view.scale)
        ..translate(-view.cameraX, -view.cameraY);
      _background.paint(
        canvas,
        scene: scene.background,
        secondary: scene.secondary,
        accent: scene.accent,
        time: t,
        levels: levels,
        objectOpacity: scene.backgroundObjectOpacity * 2,
        parallaxCamera: Offset(view.cameraX, view.cameraY),
        parallaxOrigin: Offset(view.centerX, view.centerY),
        parallaxStrength: 0.72,
      );
      canvas.restore();
    }

    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..scale(cam.scale)
      ..translate(-cam.x, -cam.y);
    final (double activeGlowBoost, double passedGlowBase) = fumeGlowBases(
      scene.intensity,
      scene.glowIntensity,
    );
    for (final FumeBlock b in article.blocks) {
      if (!_onScreen(b, cam, size)) continue;
      final FumeBlockTiming timing = FumeBlockTiming(
        b,
        t,
        scene.nextLineStart(b.lineIndex),
        scene.textHoldRatio,
      );
      if (timing.staticState != null) {
        final FumeUniformStyle s = fumeStaticStyle(
          block: b,
          timing: timing,
          t: t,
          text: scene.text,
          passedGlowBase: passedGlowBase,
          passedFadeDuration: scene.passedFadeDuration,
          overviewRestore: _step.overviewTextRestoreProgress,
        );
        for (int li = 0; li < b.renderLines.length; li++) {
          _uniformPainter(b, li, s).paint(canvas, _lineOrigin(b, li));
        }
        continue;
      }
      _paintLive(
        canvas,
        b,
        timing,
        t,
        scene,
        activeGlowBoost,
        passedGlowBase,
        1 / math.max(cam.scale, 0.05),
      );
    }
    canvas
      ..restore()
      ..restore();
    _sweep();
  }

  FumeBackgroundLevels _levels(FumeScene scene, int timeMs) {
    final LyricVisualizerAudioFrame Function(int)? at = scene.audioAt;
    if (!scene.motion || at == null) return const <FumeAudioBand, double>{};
    return fumeBackgroundLevelsOf(at(timeMs));
  }

  static bool _onScreen(FumeBlock b, FumeCamera cam, Size viewport) {
    const double overscan = 180;
    final double s = cam.scale;
    final double left = viewport.width * 0.5 + (b.x - cam.x) * s;
    final double top = viewport.height * 0.5 + (b.y - cam.y) * s;
    final double right = left + b.width * s;
    final double bottom = top + b.height * s;
    return !(right < -overscan ||
        left > viewport.width + overscan ||
        bottom < -overscan ||
        top > viewport.height + overscan);
  }

  static Offset _lineOrigin(FumeBlock b, int li) {
    final FumeRenderLine l = b.renderLines[li];
    return Offset(
      b.x + l.left,
      b.y + l.top + b.baselineOffset - b.paintHeight * 0.5,
    );
  }

  /// 正在打印 / 颜色拖尾中的块（folia `drawFumeLiveBlock`）。[screenPx] = 1 屏幕像素合多少世界单位
  /// （Canvas 2D 的阴影半径不随变换缩放，这里折回世界坐标）。
  void _paintLive(
    Canvas canvas,
    FumeBlock b,
    FumeBlockTiming tm,
    double t,
    FumeScene scene,
    double activeGlowBoost,
    double passedGlowBase,
    double screenPx,
  ) {
    final FumeLine line = b.line;
    final int printed = fumePrintedGraphemeCount(line, t);
    final int total = b.graphemeCount;
    final Color text = scene.text;
    final bool lineActive = t >= line.start && t <= tm.passCutoff;

    if (lineActive && scene.glowIntensity > 0) {
      final double progress = fumeVisualProgressWithCutoff(
        line.start,
        tm.lineDuration,
        t,
        tm.passCutoff,
      );
      final double env = fumeDelayedGlowEnvelope(progress);
      final double alpha =
          ((b.hero ? 0.16 : 0.12) + env * (b.hero ? 0.26 : 0.2)) *
          scene.glowIntensity;
      final double blur =
          ((b.hero ? 12 : 8) + env * (b.fontPx * (b.hero ? 0.7 : 0.52))) *
          scene.glowIntensity;
      // 量化到 1/48 透明度、0.5 世界单位模糊：段落缓存才命中得上。
      final double qa = (fumeClamp(alpha, 0, 1) * 48).round() / 48;
      final double qb = (blur * screenPx * 2).roundToDouble() / 2;
      final FumeUniformStyle glow = FumeUniformStyle(
        scene.accent.withValues(alpha: qa),
        qb,
        scene.accent.withValues(alpha: fumeClamp(qa * 1.35, 0, 1)),
      );
      for (int li = 0; li < b.renderLines.length; li++) {
        _uniformPainter(b, li, glow).paint(canvas, _lineOrigin(b, li));
      }
    }

    for (int li = 0; li < b.renderLines.length; li++) {
      final FumeRenderLine rl = b.renderLines[li];
      final Offset origin = _lineOrigin(b, li);
      final double baseX = b.x + rl.left;
      final double baseY = b.y + rl.top + b.baselineOffset;
      final List<InlineSpan> spans = <InlineSpan>[];
      final StringBuffer run = StringBuffer();
      String runKey = '';
      TextStyle? runStyle;
      void flush() {
        if (run.isEmpty || runStyle == null) return;
        spans.add(TextSpan(text: run.toString(), style: runStyle));
        run.clear();
      }

      for (int o = rl.start; o < rl.end; o++) {
        final int local = o - rl.start;
        final String g = rl.graphemes[local];
        final int ri = o < b.rangeIndexByOffset.length
            ? b.rangeIndexByOffset[o]
            : -1;
        final FumeWordRange? range = ri >= 0 ? line.ranges[ri] : null;
        final bool isPrinted = tm.revealCompleted || o < printed;
        final bool frontier =
            printed > 0 &&
            o == printed &&
            printed < total &&
            !tm.revealCompleted &&
            !tm.passCutoffReached;
        double alpha = isPrinted
            ? tm.activeOpacity
            : frontier
            ? 0.82
            : tm.waitingOpacity;
        Color fill = text.withValues(alpha: alpha);
        double blur = 0;
        Color shadow = const Color(0x00000000);

        if (range != null) {
          final double wordDuration = math.max(
            range.wordEnd - range.wordStart,
            0.08,
          );
          final double wordProgress = fumeClamp(
            (t - range.wordStart) / wordDuration,
            0,
            1,
          );
          final int glyphCount = math.max(range.end - range.start, 1);
          final int gi = o - range.start;
          final FumeGlyphTiming? gt = range.timings.isEmpty
              ? null
              : range.timings[math.min(gi, range.timings.length - 1)];
          final double gStart =
              gt?.start ?? range.wordStart + (gi / glyphCount) * wordDuration;
          final double gEnd =
              gt?.end ??
              range.wordStart + ((gi + 1) / glyphCount) * wordDuration;
          final double gDur = math.max(gEnd - gStart, 0.001);
          final double gp = gt != null
              ? fumeClamp((t - gStart) / gDur + 0.16, 0, 1)
              : fumeClamp(wordProgress * glyphCount - gi + 0.16, 0, 1);
          final double eased = fumeEaseOutCubic(gp);
          final Color active = scene.activeColorFor(range.text);
          final double trailStart = gStart + gDur * 0.18;
          final double trail = math
              .pow(
                fumeVisualProgressWithCutoff(
                  trailStart,
                  tm.colorTrailDuration,
                  t,
                  tm.passCutoff,
                ),
                1.35,
              )
              .toDouble();
          void trailStyle() {
            final FumePassedStyle ps = tm.transitionStyle;
            alpha = fumeMix(tm.activeOpacity, ps.opacity, trail);
            fill = Color.lerp(
              active,
              text,
              0.18 + trail * 0.82,
            )!.withValues(alpha: alpha);
            blur =
                (2 + b.fontPx * 0.1) *
                (1 - trail * 0.35) *
                passedGlowBase *
                ps.glowMultiplier;
            shadow = Color.lerp(active, text, 0.55 + trail * 0.45)!.withValues(
              alpha: fumeClamp(
                ps.shadowAlphaBase + (1 - trail) * ps.shadowAlphaTrail,
                0,
                1,
              ),
            );
          }

          if (tm.passCutoffReached) {
            trailStyle();
          } else if (t < range.wordStart) {
            alpha = tm.waitingOpacity;
            fill = text.withValues(alpha: alpha);
          } else if (t <= trailStart) {
            alpha = fumeMix(tm.waitingOpacity, tm.activeOpacity, eased);
            fill = Color.lerp(
              text,
              active,
              0.22 + eased * 0.78,
            )!.withValues(alpha: alpha);
            blur = (4 + b.fontPx * 0.22) * eased * activeGlowBoost;
            shadow = active.withValues(alpha: 0.4 + eased * 0.44);
          } else {
            trailStyle();
          }

          if (scene.showPrintStamp && scene.motion && g.trim().isNotEmpty) {
            _paintStamp(
              canvas,
              b: b,
              tm: tm,
              t: t,
              rl: rl,
              local: local,
              grapheme: g,
              trailStart: trailStart,
              wordDuration: wordDuration,
              glyphCount: glyphCount,
              baseX: baseX,
              baseY: baseY,
              active: active,
              activeGlowBoost: activeGlowBoost,
              screenPx: screenPx,
            );
          }
        }

        if (alpha <= 0.002) fill = fill.withValues(alpha: 0);
        // 屏幕像素的整数半径（folia 同样取整，避免每帧都是新的模糊半径）。
        final double worldBlur = blur.roundToDouble() * screenPx;
        final String key =
            '${fill.toARGB32()}|${worldBlur.toStringAsFixed(2)}|${shadow.toARGB32()}';
        if (key != runKey) {
          flush();
          runKey = key;
          runStyle = _style(b, scene.font, fill, worldBlur, shadow);
        }
        run.write(g);
      }
      flush();
      if (spans.isEmpty) continue;
      final TextPainter p = TextPainter(
        text: TextSpan(children: spans),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      )..layout();
      p
        ..paint(canvas, origin)
        ..dispose();
    }
  }

  /// 字被「打」上纸前，从上方落下一个发光方块，落定后淡出（folia print stamp）。
  void _paintStamp(
    Canvas canvas, {
    required FumeBlock b,
    required FumeBlockTiming tm,
    required double t,
    required FumeRenderLine rl,
    required int local,
    required String grapheme,
    required double trailStart,
    required double wordDuration,
    required int glyphCount,
    required double baseX,
    required double baseY,
    required Color active,
    required double activeGlowBoost,
    required double screenPx,
  }) {
    final double window = math.max(wordDuration / glyphCount, 0.04);
    final double lead = fumeClamp(
      math.min(window * 0.86, tm.lineDuration * 0.16),
      0.055,
      b.hero ? 0.2 : 0.16,
    );
    final double release = lead * 0.42;
    final double wStart = trailStart - lead;
    final double wEnd = trailStart + release;
    final double stamp = fumeVisualProgressWithCutoff(
      wStart,
      wEnd - wStart,
      t,
      tm.passCutoff,
    );
    if (stamp <= 0 || stamp >= 1) return;
    final double trailPhase = fumeVisualProgressWithCutoff(
      trailStart,
      math.max(wEnd - trailStart, 0.001),
      t,
      tm.passCutoff,
    );
    final bool dropping = trailPhase <= 0;
    final double drop = dropping
        ? fumeEaseOutCubic(
            fumeVisualProgressWithCutoff(
              wStart,
              math.max(trailStart - wStart, 0.001),
              t,
              tm.passCutoff,
            ),
          )
        : 1;
    final double fade = dropping ? 0 : fumeEaseInOutCubic(trailPhase);
    final double pulse = dropping
        ? fumeMix(0.18, 1, math.pow(drop, 0.78).toDouble())
        : math.pow(1 - fade, 1.2).toDouble();
    final double advance = rl.advanceAt(local);
    final double visualWidth = math.max(
      advance * 0.88,
      fumeIsCjk(grapheme) ? b.fontPx * 0.56 : b.fontPx * 0.38,
    );
    final double cx = baseX + rl.offsetAt(local) + advance * 0.5;
    final double dropDistance = b.lineHeight * (b.hero ? 0.24 : 0.2);
    final double alpha = pulse * (b.hero ? 0.82 : 0.72);
    final double w = visualWidth + b.fontPx * (b.hero ? 0.18 : 0.12);
    final double h = b.fontPx * (b.hero ? 0.72 : 0.62);
    final double cy = baseY - b.fontPx * 0.38 - fumeMix(dropDistance, 0, drop);
    final double blur = (8 + b.fontPx * 0.24) * pulse * activeGlowBoost;
    if (w <= 0) return;
    final Rect rect = Rect.fromLTWH(cx - w * 0.5, cy - h * 0.5, w, h);
    final double sigma = blur * screenPx * 0.5;
    if (sigma > 0.1) {
      canvas.drawRect(
        rect,
        Paint()
          ..color = active.withValues(alpha: fumeClamp(0.56 * pulse, 0, 1))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
      );
    }
    canvas.drawRect(
      rect,
      Paint()..color = active.withValues(alpha: fumeClamp(alpha, 0, 1)),
    );
  }
}

/// 舞台画家：只读 [FumeStage]，随 [ticks] 重画。
class FumePainter extends CustomPainter {
  FumePainter({required this.stage, required this.scene, required this.ticks})
    : super(repaint: ticks);

  final FumeStage stage;
  final FumeScene scene;
  final LyricVisualizerTicks ticks;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    stage.paint(canvas, size, scene, ticks.value);
  }

  @override
  bool shouldRepaint(covariant FumePainter old) =>
      !identical(old.scene, scene) || !identical(old.stage, stage);
}
