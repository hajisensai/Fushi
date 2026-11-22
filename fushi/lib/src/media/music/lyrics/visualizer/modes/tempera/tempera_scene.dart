/// 凝彩的场景装配与逐帧绘制（folia `temperaSceneBuilder.ts` / `temperaShotFrame.ts` /
/// `temperaSceneFrame.ts` / `temperaTextView.ts` / `temperaDepth.ts` / `temperaOverlay.ts` /
/// `temperaCreditsLayer.ts` / `temperaImageLayer.ts` 与 runtime 的逐帧编排）。
///
/// 段落 → 场景（每个分镜一组色块 + 一组排好的字），只缓存当前段落前后各一个。
/// 文字反色在 CPU 侧模拟 folia 的 difference 滤镜：字先画进一个图层，再按其下色块的亮度
/// 用 srcATop 把每块区域里的字染成 ink / paper 中对比更大的那个。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_compositions.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_geometry.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_motion.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_palette.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_random.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_shapes.dart';

/// 解析好的参数（folia `TemperaTuning` 里本移植用得到的部分）。
class TemperaSettings {
  const TemperaSettings({
    this.cameraIntensity = 1,
    this.glyphMotion = 1,
    this.wholeLine = false,
    this.settleStretch = 0.5,
    this.colorMode = TemperaColorMode.duo,
    this.showBlocks = true,
    this.showDecor = true,
    this.cornerMarks = true,
    this.textInversion = true,
    this.transitions = true,
    this.coverLayer = false,
    this.layerFrequency = 0.6,
    this.layerFront = false,
    this.layerScale = 0.7,
    this.layerOpacity = 1,
    this.depth = false,
    this.depthOfField = 1,
    this.depthPan = 1,
    this.glyphDepth = 1,
    this.postProcess = true,
    this.grain = 0.2,
    this.contrast = 0,
    this.vignette = 0.85,
  });

  final double cameraIntensity;
  final double glyphMotion;
  final bool wholeLine;
  final double settleStretch;
  final TemperaColorMode colorMode;
  final bool showBlocks;
  final bool showDecor;
  final bool cornerMarks;
  final bool textInversion;
  final bool transitions;
  final bool coverLayer;
  final double layerFrequency;
  final bool layerFront;
  final double layerScale;
  final double layerOpacity;
  final bool depth;
  final double depthOfField;
  final double depthPan;
  final double glyphDepth;
  final bool postProcess;
  final double grain;
  final double contrast;
  final double vignette;

  /// 改了要重建场景的参数（其余逐帧读）。
  Object get sceneKey => (
    colorMode,
    settleStretch,
    showBlocks,
    showDecor,
    coverLayer,
    layerFrequency,
    layerFront,
    layerScale,
    layerOpacity,
  );
}

// ---------------------------------------------------------------------------
// 文字：量宽与 TextPainter 缓存
// ---------------------------------------------------------------------------

/// 凝彩用的字体样式（folia 取主题字体、字重 600）。
TextStyle temperaTextStyle(double fontSize, Color color) => TextStyle(
  fontSize: fontSize,
  fontWeight: FontWeight.w600,
  color: color,
  height: 1,
);

/// 量宽缓存 + 逐字 TextPainter 缓存（透明度量化到 1/32，避免每帧新建）。
class TemperaTextCache {
  final Map<String, double> _widths = <String, double>{};
  final Map<String, TextPainter> _painters = <String, TextPainter>{};

  static const int _widthLimit = 20000;
  static const int _painterLimit = 1600;

  /// 一段文字在 [fontSize] 下的宽度。
  double measure(String text, double fontSize) {
    final String key = '$fontSize|$text';
    final double? cached = _widths[key];
    if (cached != null) return cached;
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: temperaTextStyle(fontSize, const Color(0xFF000000)),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final double width = tp.width;
    tp.dispose();
    if (_widths.length >= _widthLimit) _widths.remove(_widths.keys.first);
    _widths[key] = width;
    return width;
  }

  TextPainter _painter(String text, double fontSize, Color color) {
    final String key = '$text|$fontSize|${color.toARGB32()}';
    final TextPainter? hit = _painters[key];
    if (hit != null) return hit;
    if (_painters.length >= _painterLimit) {
      for (final TextPainter tp in _painters.values) {
        tp.dispose();
      }
      _painters.clear();
    }
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: temperaTextStyle(fontSize, color)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    _painters[key] = tp;
    return tp;
  }

  /// 以原点为中心画一个字 / 一段字。
  void paintCentered(
    Canvas canvas,
    String text,
    double fontSize,
    Color color,
    double alpha,
  ) {
    final int q = (alpha.clamp(0.0, 1.0) * 32).round();
    if (q <= 0) return;
    final double size = (fontSize * 2).roundToDouble() / 2;
    final TextPainter tp = _painter(
      text,
      size,
      color.withValues(alpha: color.a * q / 32),
    );
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
  }

  void dispose() {
    for (final TextPainter tp in _painters.values) {
      tp.dispose();
    }
    _painters.clear();
    _widths.clear();
  }
}

// ---------------------------------------------------------------------------
// 场景数据
// ---------------------------------------------------------------------------

const double _shadowOffsetX = 0.06;
const double _shadowOffsetY = 0.08;
const double _shadowAlpha = 0.34;
const double _depthFarSize = 0.4;
const double _farGlyphAlpha = 0.5;
const double _minGlyphShade = 0.2;
const double _glyphLeadNear = 0.5;
const double _glyphLagFar = 0.4;
const double _glyphParallaxCap = 0.07;
const List<(double, double)> _panDirections = <(double, double)>[
  (0, -1),
  (0, 1),
  (-1, 0),
  (1, 0),
];
const double _riseEnter = 0.2;
const double _riseEnterSeconds = 0.9;
const double _riseDrift = 0.18;
const double _backParallax = 0.55;
const double _frontParallax = 1.6;
const double _backBlur = 1.6;
const double _frontBlur = 6;

/// 字深度：字号越接近本分镜最大字越「近」（folia `buildTemperaTextViews`）。
List<double> temperaGlyphDepths(List<double> fontSizes) {
  final double biggest = fontSizes.fold(0, math.max);
  return <double>[
    for (final double s in fontSizes)
      biggest > 0
          ? ((s / biggest - _depthFarSize) / (1 - _depthFarSize)).clamp(
              0.0,
              1.0,
            )
          : 1,
  ];
}

class _GlyphView {
  _GlyphView(this.p, this.depth) : motion = p.motion;

  final TemperaGlyphPlacement p;
  final TemperaGlyphMotionInput motion;
  final double depth;
}

/// 封面图层在一个分镜里的落位（folia `resolveTemperaImagePlacement`，pool 只有封面）。
class _CoverPlacement {
  const _CoverPlacement(
    this.x,
    this.y,
    this.scale,
    this.rotation,
    this.opacity,
    this.flip,
    this.creepScale,
    this.front,
  );

  final double x;
  final double y;
  final double scale;
  final double rotation;
  final double opacity;
  final bool flip;
  final double creepScale;
  final bool front;
}

_CoverPlacement? _resolveCover(TemperaSettings s, int seed) {
  if (!s.coverLayer) return null;
  if (temperaHash01(seed, 6, 277) >= s.layerFrequency.clamp(0.0, 1.0)) {
    return null;
  }
  // 对齐：横向自由（0.12–0.88），纵向靠下（0.68–0.86）。
  return _CoverPlacement(
    0.12 + 0.76 * temperaHash01(seed, 1, 251),
    0.68 + 0.18 * temperaHash01(seed, 2, 257),
    s.layerScale * (0.9 + temperaHash01(seed, 3, 263) * 0.2),
    (temperaHash01(seed, 4, 269) - 0.5) * 0.08,
    s.layerOpacity,
    temperaHash01(seed, 5, 271) > 0.5,
    0.6 + temperaHash01(seed, 8, 283) * 0.8,
    s.layerFront,
  );
}

class _ShotView {
  _ShotView({
    required this.shot,
    required this.blocks,
    required this.glyphs,
    required this.baseFontSize,
    required this.revealDoneTime,
    required this.idHash,
    required this.cover,
    required this.textLeft,
    required this.textRight,
  });

  final TemperaShot shot;
  final TemperaBlocks blocks;
  final List<_GlyphView> glyphs;
  final double baseFontSize;
  final double revealDoneTime;
  final int idHash;
  final _CoverPlacement? cover;
  final double textLeft;
  final double textRight;
  final Map<int, ui.Shader> _tintShaders = <int, ui.Shader>{};

  /// gradient 模式文字 ramp（横跨本分镜所有字），亮度换成 [tone] 的；[tone] 为 null 时用 ramp 原色。
  ui.Shader tint(List<Color> ramp, Color? tone) {
    final int key = tone?.toARGB32() ?? 0;
    return _tintShaders.putIfAbsent(key, () {
      final List<Color> colors = <Color>[
        for (final Color c in ramp)
          tone == null ? c : temperaWithLuminanceOf(c, tone),
      ];
      return ui.Gradient.linear(
        Offset(textLeft, 0),
        Offset(math.max(textRight, textLeft + 1), 0),
        colors,
        <double>[
          for (int i = 0; i < colors.length; i++) i / (colors.length - 1),
        ],
      );
    });
  }
}

class _SceneView {
  _SceneView(this.paragraph, this.shots, this.seed, this.screentone);

  final TemperaParagraph paragraph;
  final List<_ShotView> shots;
  final int seed;
  final TemperaNode? screentone;
}

class _CreditsItem {
  _CreditsItem(
    this.node, {
    this.baseX = 0,
    this.baseY = 0,
    this.enterDX = 0,
    this.enterDY = 0,
    this.delay = 0,
    this.driftX = 0,
    this.driftY = 0,
    this.grow = 0,
  });

  final TemperaNode node;
  final double baseX;
  final double baseY;
  final double enterDX;
  final double enterDY;
  final double delay;
  final double driftX;
  final double driftY;
  final double grow;
}

/// 一帧的输入。
class TemperaSceneConfig {
  const TemperaSceneConfig({
    required this.program,
    required this.programSeed,
    required this.palette,
    required this.settings,
    required this.motion,
    required this.fontScale,
    required this.cornerColor,
    this.cover,
    this.title,
    this.artist,
    this.album,
  });

  final TemperaProgram program;
  final String programSeed;
  final TemperaPalette palette;
  final TemperaSettings settings;
  final bool motion;
  final double fontScale;
  final Color cornerColor;
  final ui.Image? cover;
  final String? title;
  final String? artist;
  final String? album;
}

/// 凝彩的场景缓存 + 逐帧绘制。
class TemperaEngine {
  TemperaEngine(this._config);

  TemperaSceneConfig _config;
  final TemperaTextCache _text = TemperaTextCache();
  final Map<int, _SceneView> _scenes = <int, _SceneView>{};
  Size _size = Size.zero;
  _Credits? _credits;
  bool _creditsBuilt = false;

  TemperaSceneConfig get config => _config;

  /// 换输入；影响场景的变化会清缓存。
  set config(TemperaSceneConfig next) {
    final TemperaSceneConfig prev = _config;
    _config = next;
    if (!identical(prev.program, next.program) ||
        !identical(prev.palette, next.palette) ||
        prev.settings.sceneKey != next.settings.sceneKey ||
        prev.motion != next.motion ||
        prev.fontScale != next.fontScale ||
        !identical(prev.cover, next.cover) ||
        prev.title != next.title ||
        prev.artist != next.artist ||
        prev.album != next.album) {
      _invalidate();
    }
  }

  void _invalidate() {
    _scenes.clear();
    _credits?.dispose();
    _credits = null;
    _creditsBuilt = false;
  }

  void dispose() {
    _invalidate();
    _text.dispose();
  }

  bool get _static => !_config.motion;

  /// 测试 / 诊断：当前缓存的段落下标。
  Iterable<int> get cachedParagraphs => _scenes.keys;

  // -------------------------------------------------------------------------
  // 构建
  // -------------------------------------------------------------------------

  _SceneView _scene(int index) =>
      _scenes.putIfAbsent(index, () => _buildScene(index));

  _SceneView _buildScene(int index) {
    final TemperaSceneConfig c = _config;
    final TemperaSettings s = c.settings;
    final double w = _size.width, h = _size.height;
    final TemperaParagraph paragraph = c.program.paragraphs[index];
    final int sceneSeed = temperaHashSeed('${c.programSeed}:${paragraph.id}');
    final TemperaNode? screentone = s.showBlocks
        ? drawSquareMarks(
            temperaDotGrid(w, h, math.max(26, math.sqrt((w * h) / 6000)), 1.6),
            c.palette.tone4,
            0.05,
          )
        : null;
    final List<_ShotView> shots = <_ShotView>[];
    for (int i = 0; i < paragraph.shots.length; i++) {
      final TemperaShot shot = paragraph.shots[i];
      final List<List<TemperaSegment>> lines = <List<TemperaSegment>>[];
      for (final TemperaShotSlice slice in shot.slices) {
        TemperaCompiledLine? line;
        for (final TemperaCompiledLine l in paragraph.lines) {
          if (l.sourceIndex == slice.lineIndex) {
            line = l;
            break;
          }
        }
        if (line == null) continue;
        final int start = slice.segmentStart.clamp(0, line.segments.length);
        final int end = slice.segmentEnd.clamp(start, line.segments.length);
        final List<TemperaSegment> segs = line.segments
            .sublist(start, end)
            .where(temperaIsLayoutSegment)
            .toList();
        if (segs.isNotEmpty) lines.add(segs);
      }
      int maxGraphemes = 3;
      for (final List<TemperaSegment> segs in lines) {
        maxGraphemes = math.max(
          maxGraphemes,
          segs.fold(0, (int n, TemperaSegment seg) => n + seg.graphemes.length),
        );
      }
      final double baseFontSize =
          math.max(
            34,
            math.min(150, (w / math.max(5, maxGraphemes * 1.05)) * 1.5),
          ) *
          c.fontScale;
      final int shotSeed = sceneSeed + i * 97;
      final List<TemperaBlockItem> items;
      if (s.showBlocks) {
        final TemperaComposer composer = TemperaComposer(
          kind: shot.kind,
          palette: c.palette,
          decor: shot.decor,
          width: w,
          height: h,
          seed: shotSeed,
          showDecor: s.showDecor,
          flowAngle: shot.flowAngle,
        );
        drawTemperaComposition(composer);
        items = composer.items;
      } else {
        items = <TemperaBlockItem>[];
      }
      final List<TemperaGlyphPlacement> placements = resolveTemperaLayout(
        lines: lines,
        shotKind: shot.kind,
        width: w,
        height: h,
        baseFontSize: baseFontSize,
        seed: shotSeed,
        measure: _text.measure,
        settleStretch: s.settleStretch,
      );
      final List<double> depths = temperaGlyphDepths(<double>[
        for (final TemperaGlyphPlacement p in placements) p.fontSize,
      ]);
      double left = double.infinity,
          right = double.negativeInfinity,
          reveal = shot.startTime;
      for (final TemperaGlyphPlacement p in placements) {
        left = math.min(left, p.x - p.fontSize / 2);
        right = math.max(right, p.x + p.fontSize / 2);
      }
      if (placements.isNotEmpty) {
        reveal = placements.fold(
          double.negativeInfinity,
          (double m, TemperaGlyphPlacement p) => math.max(m, p.settleTime),
        );
      }
      shots.add(
        _ShotView(
          shot: shot,
          blocks: TemperaBlocks(items, w, h, shot.flowAngle),
          glyphs: <_GlyphView>[
            for (int g = 0; g < placements.length; g++)
              _GlyphView(placements[g], depths[g]),
          ],
          baseFontSize: baseFontSize,
          revealDoneTime: reveal,
          idHash: temperaHashSeed(shot.id),
          cover: c.cover == null ? null : _resolveCover(s, shotSeed),
          textLeft: left.isFinite ? left : 0,
          textRight: right.isFinite ? right : w,
        ),
      );
    }
    return _SceneView(paragraph, shots, sceneSeed, screentone);
  }

  _Credits? _creditsPoster() {
    if (_creditsBuilt) return _credits;
    _creditsBuilt = true;
    final TemperaSceneConfig c = _config;
    final bool has = <String?>[
      c.title,
      c.artist,
      c.album,
    ].any((String? v) => (v ?? '').trim().isNotEmpty);
    if (!has) return null;
    return _credits = _Credits.build(c, _size, _text);
  }

  // -------------------------------------------------------------------------
  // 逐帧
  // -------------------------------------------------------------------------

  /// 画 [time]（秒）这一帧。[elapsed] 是墙钟秒（颗粒噪点换帧用）。
  void paint(Canvas canvas, Size size, double time, double elapsed) {
    if (size.width <= 1 || size.height <= 1) return;
    if (size != _size) {
      _size = size;
      _invalidate();
    }
    final TemperaSceneConfig c = _config;
    final List<TemperaParagraph> paragraphs = c.program.paragraphs;
    final double w = size.width, h = size.height;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (paragraphs.isNotEmpty) {
      final int index = temperaParagraphIndexAt(c.program, time);
      final bool transitionsOn = c.settings.transitions && !_static;
      final TemperaTransition? outgoing = paragraphs[index].transitionOut;
      final bool preRoll =
          transitionsOn &&
          outgoing != null &&
          outgoing.kind != 'block-wipe' &&
          time >= outgoing.startTime;
      _scenes.removeWhere((int k, _SceneView _) => (k - index).abs() > 1);
      final TemperaCreditsFrame credits = temperaCreditsFrame(
        time,
        paragraphs.last.endTime,
      );
      final _Credits? poster = _creditsPoster();
      (double, double, Color)? wipe;
      for (final int i in <int>[
        index,
        if (preRoll && index + 1 < paragraphs.length) index + 1,
      ]) {
        final _SceneView scene = _scene(i);
        final TemperaTransitionFrame tf = temperaSceneTransition(
          c.program,
          i,
          time,
          i != index,
          outgoing,
          transitionsOn,
        );
        final double lyricAlpha = i == paragraphs.length - 1 && poster != null
            ? credits.lyricAlpha
            : 1;
        final double alpha = tf.alpha * lyricAlpha;
        if (alpha > 0.002) _paintScene(canvas, scene, tf, alpha, time, elapsed);
        if (tf.wipe > 0.001 && tf.wipe < 1.999) {
          wipe = (tf.wipe, tf.wipeAngle, c.palette.tone3);
        }
      }
      if (wipe != null) _paintWipe(canvas, wipe.$1, wipe.$2, wipe.$3);
      if (poster != null && credits.active) {
        poster.paint(
          canvas,
          credits,
          _static ? 99 : time - paragraphs.last.endTime,
          c,
          size,
        );
      }
    }
    if (c.settings.cornerMarks) _paintCornerMarks(canvas, w, h, c.cornerColor);
    canvas.restore();
  }

  void _paintScene(
    Canvas canvas,
    _SceneView scene,
    TemperaTransitionFrame tf,
    double alpha,
    double time,
    double elapsed,
  ) {
    final TemperaSceneConfig c = _config;
    final TemperaSettings s = c.settings;
    final double w = _size.width, h = _size.height;
    final bool post = s.postProcess && !_static;
    final Rect full = Offset.zero & _size;
    canvas.save();
    canvas.translate(w / 2 + tf.x * w, h / 2 + tf.y * h);
    if (tf.scale != 1) canvas.scale(tf.scale);
    canvas.translate(-w / 2, -h / 2);
    final bool layer = alpha < 0.999 || tf.blur > 0.01 || post;
    if (layer) {
      final Paint lp = Paint()
        ..color = Color.fromRGBO(0, 0, 0, alpha.clamp(0.0, 1.0));
      if (tf.blur > 0.01) {
        lp.imageFilter = ui.ImageFilter.blur(
          sigmaX: tf.blur * 0.5,
          sigmaY: tf.blur * 0.5,
        );
      }
      if (post && s.contrast > 0) {
        final double k = 1 + s.contrast * 0.5;
        final double o = 128 * (1 - k);
        lp.colorFilter = ColorFilter.matrix(<double>[
          k, 0, 0, 0, o, //
          0, k, 0, 0, o,
          0, 0, k, 0, o,
          0, 0, 0, 1, 0,
        ]);
      }
      canvas.saveLayer(full, lp);
    }
    if (s.showBlocks) {
      canvas.drawRect(
        full,
        Paint()..color = c.palette.paper.withValues(alpha: 0.35),
      );
      final TemperaNode? tone = scene.screentone;
      if (tone != null) {
        for (final TemperaOp op in tone.ops) {
          op.draw(canvas, 1);
        }
      }
    }
    final int active = temperaActiveShotIndex(scene.paragraph.shots, time);
    for (int i = 0; i < scene.shots.length; i++) {
      final _ShotView view = scene.shots[i];
      final bool show =
          i == active ||
          (!_static && i < active && _shotExit(view.shot, time) < 1);
      if (show) _paintShot(canvas, view, time);
    }
    if (post) _paintPost(canvas, scene.seed, elapsed);
    if (layer) canvas.restore();
    canvas.restore();
  }

  double _handoff(TemperaShot shot) =>
      temperaShotPaced(shot.endTime - shot.startTime, 0.3, 0.4, 1.1);

  double _shotExit(TemperaShot shot, double time) =>
      temperaClamp01((time - shot.endTime) / _handoff(shot));

  void _paintShot(Canvas canvas, _ShotView view, double time) {
    final TemperaSceneConfig c = _config;
    final TemperaSettings s = c.settings;
    final TemperaPalette pal = c.palette;
    final double w = _size.width, h = _size.height;
    final TemperaShot shot = view.shot;
    final bool still = _static;
    final double duration = math.max(shot.endTime - shot.startTime, 0.001);
    final double rawProgress = (time - shot.startTime) / duration;
    final double camera = still ? 0 : s.cameraIntensity;
    final double motion = still ? 0 : s.glyphMotion;
    final TemperaCameraFrame frame = temperaCameraFrame(shot, rawProgress);
    final double breathWeight = temperaBreathWeight(time, view.revealDoneTime);
    if (breathWeight > 0) {
      final double phase = (view.idHash % 1024) / 1024 * math.pi * 2;
      final TemperaCameraFrame breath = temperaCameraBreath(time, phase);
      frame
        ..x += breath.x * breathWeight
        ..y += breath.y * breathWeight
        ..scale += breath.scale * breathWeight
        ..rotation += breath.rotation * breathWeight;
    }
    final double handoff = _handoff(shot);
    final double span = math.max(w, h);
    final double enter = still
        ? 1
        : temperaEaseEnter(
            temperaClamp01((time - shot.startTime) / (handoff * 0.8)),
          );
    final double exit = still ? 0 : temperaEaseInOut(_shotExit(shot, time));
    final double travel = exit * span * 0.55 - (1 - enter) * span * 0.32;
    final double depthMix = s.depth && !still ? 1 : 0;
    final (double panX, double panY) =
        _panDirections[(view.idHash >>> 5) % _panDirections.length];
    final double panEnter =
        1 -
        temperaEaseEnter(
          temperaClamp01((time - shot.startTime) / _riseEnterSeconds),
        );
    final double pan =
        (panEnter * _riseEnter +
            (0.5 - temperaClamp01(rawProgress)) * _riseDrift) *
        h *
        camera *
        depthMix *
        s.depthPan;
    final double camX =
        frame.x * w * camera + math.cos(shot.flowAngle) * travel - panX * pan;
    final double camY =
        frame.y * h * camera + math.sin(shot.flowAngle) * travel - panY * pan;
    final double parallax = depthMix * s.depthOfField;
    final double backX = camX * parallax * (_backParallax - 1),
        backY = camY * parallax * (_backParallax - 1);
    final double frontX = camX * parallax * (_frontParallax - 1),
        frontY = camY * parallax * (_frontParallax - 1);
    final double shotAlpha = 1 - exit;
    final double scale = (1 + (frame.scale - 1) * camera) * (1 - exit * 0.08);
    final double rotation = frame.rotation * camera;
    final double blurScale = w / 1280 * depthMix * s.depthOfField;
    view.blocks.update(
      time,
      shot.startTime,
      shot.endTime,
      shot.lyricEndTime,
      still: still,
    );

    canvas.save();
    canvas.translate(w / 2 + camX, h / 2 + camY);
    if (rotation != 0) canvas.rotate(rotation);
    if (scale != 1) canvas.scale(scale);
    canvas.translate(-w / 2, -h / 2);
    final Rect big = Rect.fromLTWH(-w, -h, w * 3, h * 3);
    if (shotAlpha < 0.999) {
      canvas.saveLayer(
        big,
        Paint()..color = Color.fromRGBO(0, 0, 0, shotAlpha.clamp(0.0, 1.0)),
      );
    }
    // 色块
    for (final TemperaBlockItem item in view.blocks.items) {
      item.draw(canvas, 1);
    }
    // 背后的封面图层 + 水印（远景）
    final _CoverPlacement? cover = view.cover;
    if (cover != null && !cover.front) {
      _paintCover(
        canvas,
        view,
        cover,
        time,
        backX,
        backY,
        _backBlur * blurScale,
      );
    }
    final TemperaDecorWatermark? wm = shot.decor.watermark;
    if (s.showDecor && wm != null && wm.text.trim().isNotEmpty) {
      _blurred(canvas, big, _backBlur * blurScale, () {
        canvas.save();
        canvas.translate(wm.x * w + backX, wm.y * h + backY);
        canvas.rotate(wm.rotation);
        _text.paintCentered(
          canvas,
          wm.text,
          math.max(48, view.baseFontSize * wm.scale),
          pal.tone4,
          0.16,
        );
        canvas.restore();
      });
    }
    // 字的逐帧姿态
    final double cap = math.min(w, h) * _glyphParallaxCap;
    final double glyphDepth = depthMix * s.glyphDepth;
    final List<(_GlyphView, TemperaGlyphMotionFrame, double, double, double)>
    frames = <(_GlyphView, TemperaGlyphMotionFrame, double, double, double)>[];
    for (final _GlyphView g in view.glyphs) {
      final TemperaGlyphMotionFrame f = still
          ? _stillFrame(g, time)
          : temperaGlyphMotion(g.motion, time, motion);
      if (!f.visible) continue;
      final double lead =
          (g.depth * (_glyphLeadNear + _glyphLagFar) - _glyphLagFar) *
          glyphDepth;
      final double dx = (camX * lead).clamp(-cap, cap);
      final double dy = (camY * lead).clamp(-cap, cap);
      final double shade = math.max(
        _minGlyphShade,
        1 - (1 - _farGlyphAlpha) * (1 - g.depth) * glyphDepth,
      );
      frames.add((g, f, dx, dy, shade));
    }
    // 文字层（含影子、碎字），反色 / 渐变在这一层上做
    final bool recolor = s.textInversion || pal.textGradient != null;
    if (recolor) canvas.saveLayer(big, Paint());
    if (s.showDecor) {
      for (final (
            _GlyphView g,
            TemperaGlyphMotionFrame f,
            double dx,
            double dy,
            double shade,
          )
          in frames) {
        _paintGlyph(
          canvas,
          g.p,
          f,
          g.p.x + f.x + dx + g.p.fontSize * _shadowOffsetX,
          g.p.y + f.y + dy + g.p.fontSize * _shadowOffsetY,
          pal.ink,
          f.alpha * shade * _shadowAlpha,
        );
      }
    }
    for (final (
          _GlyphView g,
          TemperaGlyphMotionFrame f,
          double dx,
          double dy,
          double shade,
        )
        in frames) {
      _paintGlyph(
        canvas,
        g.p,
        f,
        g.p.x + f.x + dx,
        g.p.y + f.y + dy,
        pal.ink,
        f.alpha * shade,
      );
    }
    if (s.showDecor) {
      for (final TemperaDecorFragment fr in shot.decor.fragments) {
        canvas.save();
        canvas.translate(fr.x * w, fr.y * h);
        canvas.rotate(fr.rotation);
        _text.paintCentered(
          canvas,
          fr.char,
          math.max(12, view.baseFontSize * fr.scale),
          pal.ink,
          0.42,
        );
        canvas.restore();
      }
    }
    if (recolor) {
      _recolorText(canvas, view, big);
      canvas.restore();
    }
    // 残影层（近景）
    if (s.showDecor && !still) {
      for (final (
            _GlyphView g,
            TemperaGlyphMotionFrame f,
            double dx,
            double dy,
            double shade,
          )
          in frames) {
        if (f.echoAlpha <= 0.004) continue;
        for (int e = 0; e < 2; e++) {
          final double depth = 1 + e * 0.85;
          _paintGlyph(
            canvas,
            g.p,
            f,
            g.p.x + dx + f.echoX * depth + frontX,
            g.p.y + dy + f.echoY * depth + frontY,
            pal.tone4,
            f.echoAlpha * shade / (e + 1.4),
          );
        }
      }
    }
    if (cover != null && cover.front) {
      _paintCover(
        canvas,
        view,
        cover,
        time,
        frontX,
        frontY,
        _frontBlur * blurScale,
      );
    }
    if (shotAlpha < 0.999) canvas.restore();
    canvas.restore();
  }

  TemperaGlyphMotionFrame _stillFrame(_GlyphView g, double time) =>
      TemperaGlyphMotionFrame(
        visible: time >= g.p.startTime,
        alpha: 1,
        x: 0,
        y: 0,
        rotation: g.p.rotation,
        scaleX: 1,
        scaleY: 1,
        echoX: 0,
        echoY: 0,
        echoAlpha: 0,
      );

  void _paintGlyph(
    Canvas canvas,
    TemperaGlyphPlacement p,
    TemperaGlyphMotionFrame f,
    double x,
    double y,
    Color color,
    double alpha,
  ) {
    if (alpha <= 0.01) return;
    canvas.save();
    canvas.translate(x, y);
    if (f.rotation != 0) canvas.rotate(f.rotation);
    if (f.scaleX != 1 || f.scaleY != 1) canvas.scale(f.scaleX, f.scaleY);
    _text.paintCentered(canvas, p.char, p.fontSize, color, alpha);
    canvas.restore();
  }

  void _blurred(
    Canvas canvas,
    Rect bounds,
    double sigma,
    void Function() draw,
  ) {
    if (sigma <= 0.05) {
      draw();
      return;
    }
    canvas.saveLayer(
      bounds,
      Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
    );
    draw();
    canvas.restore();
  }

  void _paintCover(
    Canvas canvas,
    _ShotView view,
    _CoverPlacement cover,
    double time,
    double offsetX,
    double offsetY,
    double blur,
  ) {
    final ui.Image? image = _config.cover;
    if (image == null || image.height <= 0) return;
    final double w = _size.width, h = _size.height;
    final TemperaShot shot = view.shot;
    final double duration = math.max(shot.endTime - shot.startTime, 0.2);
    final double pace = math.max(shot.lyricEndTime - shot.startTime, 0.2);
    final double carry = math.max(w, h) * 0.09;
    final double creep = _static
        ? 0
        : temperaEaseInOut(temperaClamp01((time - shot.startTime) / duration)) *
              carry *
              0.35 *
              cover.creepScale;
    final double enter = _static
        ? (time >= shot.startTime ? 1 : 0)
        : temperaEaseEnter((time - shot.startTime - pace * 0.1) / (pace * 0.5));
    final double alpha = cover.opacity * enter;
    if (alpha <= 0.001) return;
    final double uniform = h * cover.scale / image.height;
    final Rect bounds = Rect.fromLTWH(-w, -h, w * 3, h * 3);
    _blurred(canvas, bounds, blur, () {
      canvas.save();
      canvas.translate(
        cover.x * w + math.cos(shot.flowAngle) * creep + offsetX,
        cover.y * h + math.sin(shot.flowAngle) * creep + offsetY,
      );
      canvas.rotate(cover.rotation);
      canvas.scale(uniform * (cover.flip ? -1 : 1), uniform);
      canvas.drawImage(
        image,
        Offset(-image.width / 2, -image.height / 2),
        Paint()
          ..filterQuality = FilterQuality.medium
          ..color = Color.fromRGBO(0, 0, 0, alpha.clamp(0.0, 1.0)),
      );
      canvas.restore();
    });
  }

  /// folia difference 滤镜的 CPU 版：底下没画东西的地方视作 paper，有色块的地方按色块的
  /// 亮度在 ink / paper 中选对比更大的那个；gradient 模式再把选中的亮度套到 ramp 色相上。
  void _recolorText(Canvas canvas, _ShotView view, Rect big) {
    final TemperaSettings s = _config.settings;
    final TemperaPalette pal = _config.palette;
    final List<Color>? ramp = pal.textGradient;
    Paint paintFor(Color tone, double? stroke) {
      final Paint p = Paint()
        ..blendMode = BlendMode.srcATop
        ..style = stroke == null ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = stroke ?? 0;
      if (ramp != null && ramp.length >= 2) {
        p.shader = view.tint(ramp, s.textInversion ? tone : null);
      } else {
        p.color = tone;
      }
      return p;
    }

    if (!s.textInversion) {
      canvas.drawRect(big, paintFor(pal.ink, null));
      return;
    }
    Color toneOver(Color backdrop) =>
        temperaPrefersPaper(backdrop, pal.ink, pal.paper) ? pal.paper : pal.ink;
    canvas.drawRect(big, paintFor(toneOver(pal.paper), null));
    for (final TemperaBlockItem item in view.blocks.items) {
      item.draw(
        canvas,
        1,
        paintOp: (TemperaOp op, double a) {
          final double eff = a * op.alpha;
          if (eff < 0.34) return;
          final Color backdrop = temperaMix(
            pal.paper,
            op.color,
            math.min(1, eff),
          );
          canvas.drawPath(
            op.path,
            paintFor(toneOver(backdrop), op.strokeWidth),
          );
        },
      );
    }
  }

  /// 后处理：暗角 + 胶片颗粒，只作用在已画内容上（srcATop）。
  void _paintPost(Canvas canvas, int seed, double elapsed) {
    final TemperaSettings s = _config.settings;
    final double w = _size.width, h = _size.height;
    if (s.vignette > 0) {
      final double radius = math.sqrt(w * w + h * h) / 2;
      canvas.drawRect(
        Offset.zero & _size,
        Paint()
          ..blendMode = BlendMode.srcATop
          ..shader = ui.Gradient.radial(
            Offset(w / 2, h / 2),
            radius,
            <Color>[
              const Color(0x00000000),
              Color.fromRGBO(0, 0, 0, (s.vignette * 0.4).clamp(0.0, 0.9)),
            ],
            const <double>[0.45, 1],
          ),
      );
    }
    if (s.grain > 0) {
      final double strength = s.grain * 0.35;
      final int count = math.min(6000, (w * h / 1000).round()) * 2;
      int state = temperaMixSeed(seed, (elapsed * 24).floor()) | 1;
      double next() {
        state = (state * 1103515245 + 12345) & 0x7fffffff;
        return state / 0x7fffffff;
      }

      final Float32List dark = Float32List(count);
      final Float32List light = Float32List(count);
      for (int i = 0; i < count; i += 2) {
        dark[i] = next() * w;
        dark[i + 1] = next() * h;
        light[i] = next() * w;
        light[i + 1] = next() * h;
      }
      final Paint p = Paint()
        ..blendMode = BlendMode.srcATop
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.square;
      canvas.drawRawPoints(
        ui.PointMode.points,
        dark,
        p..color = Color.fromRGBO(0, 0, 0, strength * 0.7),
      );
      canvas.drawRawPoints(
        ui.PointMode.points,
        light,
        p..color = Color.fromRGBO(255, 255, 255, strength * 0.5),
      );
    }
  }

  void _paintWipe(Canvas canvas, double travel, double angle, Color color) {
    final double w = _size.width, h = _size.height;
    final double span = math.sqrt(w * w + h * h);
    final double notch = span * 0.08;
    final double length = span + notch * 2;
    final double start = -span / 2 - notch;
    final double end = start + length;
    final double half = span / 2;
    final Path path = Path()
      ..moveTo(start, -half)
      ..lineTo(end, -half)
      ..lineTo(end + notch, 0)
      ..lineTo(end, half)
      ..lineTo(start, half)
      ..lineTo(start + notch, 0)
      ..close();
    final double offset = (travel - 1) * length;
    canvas.save();
    canvas.translate(
      w / 2 + math.cos(angle) * offset,
      h / 2 + math.sin(angle) * offset,
    );
    canvas.rotate(angle);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 1));
    canvas.restore();
  }

  void _paintCornerMarks(Canvas canvas, double w, double h, Color color) {
    final double px = math.max(28, w * 0.045), py = math.max(28, h * 0.045);
    final Path path = Path()
      ..moveTo(px, py + 14)
      ..lineTo(px, py)
      ..lineTo(px + 14, py)
      ..moveTo(w - px - 14, h - py)
      ..lineTo(w - px, h - py)
      ..lineTo(w - px, h - py - 14);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color.withValues(alpha: 0.5),
    );
  }
}

// ---------------------------------------------------------------------------
// 片尾海报（folia `buildTemperaCreditsPoster`）
// ---------------------------------------------------------------------------

class _Credits {
  _Credits(
    this.items,
    this.ground,
    this.title,
    this.subtitle,
    this.titleGap,
    this.diagonal,
  );

  final List<_CreditsItem> items;
  final TemperaNode ground;
  final TextPainter title;
  final TextPainter? subtitle;
  final double titleGap;
  final double diagonal;
  ui.Shader? _tint;
  Color? _tintTone;

  static _Credits build(
    TemperaSceneConfig c,
    Size size,
    TemperaTextCache text,
  ) {
    final TemperaPalette pal = c.palette;
    final double w = size.width, h = size.height;
    final int seed = temperaHashSeed('${c.title ?? ''}|${c.artist ?? ''}');
    final double diagonal = math.sqrt(w * w + h * h);
    final double bleed = diagonal * 0.25;
    final double hw = w / 2, hh = h / 2;
    final double flip = temperaHash01(seed, 1, 229) > 0.5 ? 1 : -1;
    final TemperaGradientFill? gradient = pal.gradient == null
        ? null
        : TemperaGradientFill(
            pal.gradient!,
            temperaHash01(seed, 3, 197) * math.pi * 2,
          );
    final List<_CreditsItem> items = <_CreditsItem>[];
    final TemperaNode ground = drawPolygonFill(
      rectPolygon(-hw - bleed, -hh - bleed, w + bleed * 2, h + bleed * 2),
      pal.tone1,
      1,
      gradient,
    );
    final List<Color> tones = <Color>[pal.tone2, pal.tone3, pal.tone4];
    final double baseAngle = temperaHash01(seed, 4, 241) * math.pi * 2;
    final int hatchIndex = (temperaHash01(seed, 5, 251) * 3).floor() % 3;
    for (int i = 0; i < 3; i++) {
      final double angle =
          baseAngle +
          (i * math.pi * 2) / 3 +
          (temperaHash01(seed, i, 257) - 0.5) * 0.7;
      final double distance =
          diagonal * (0.58 + temperaHash01(seed, i, 263) * 0.14);
      final double radius =
          distance + diagonal * (0.06 + temperaHash01(seed, i, 269) * 0.1);
      final List<double> polygon = circlePolygon(0, 0, radius, 72);
      final double cx = math.cos(angle) * distance,
          cy = math.sin(angle) * distance;
      final double delay = 0.08 + i * 0.16;
      _CreditsItem place(TemperaNode node, double d) => _CreditsItem(
        node,
        baseX: cx,
        baseY: cy,
        enterDX: math.cos(angle) * diagonal * 0.16,
        enterDY: math.sin(angle) * diagonal * 0.16,
        driftX: -math.cos(angle) * diagonal * 0.024,
        driftY: -math.sin(angle) * diagonal * 0.024,
        delay: d,
      );
      items.add(place(drawPolygonFill(polygon, tones[i], 1, gradient), delay));
      if (i == hatchIndex) {
        items.add(
          place(
            drawHatchFill(
              polygon,
              temperaHatchSpec(seed, 271),
              pal.paper,
              0.28,
            ),
            delay + 0.06,
          ),
        );
      }
      items.add(
        place(drawPolygonOutline(polygon, pal.ink, 2.4, 0.8), delay + 0.04),
      );
    }
    final List<TemperaLine> lines = <TemperaLine>[
      for (final TemperaLine l in temperaCrossingLines(seed, 31, w, h, 2))
        TemperaLine(l.x1 - hw, l.y1 - hh, l.x2 - hw, l.y2 - hh),
    ];
    items.add(
      _CreditsItem(
        drawLines(lines, pal.tone4, 1.3, 0.6),
        delay: 0.5,
        enterDX: w * 0.2,
      ),
    );
    if (c.settings.showDecor) {
      final double cornerX = hw * 0.66 * flip, cornerY = hh * 0.62;
      items.add(
        _CreditsItem(
          drawCrossMarks(
            temperaCrossRow(
              seed,
              71,
              cornerX - w * 0.1,
              cornerY,
              5,
              w * 0.05,
              8,
            ),
            pal.tone4,
            2,
            0.8,
          ),
          delay: 0.62,
          enterDX: -w * 0.06,
        ),
      );
      final List<double> box = rectPolygon(
        -cornerX - 19,
        -cornerY - 19,
        38,
        38,
      );
      items
        ..add(
          _CreditsItem(
            drawHatchFill(box, temperaHatchSpec(seed, 67), pal.tone4, 0.7),
            delay: 0.68,
            grow: 0.06,
          ),
        )
        ..add(
          _CreditsItem(
            drawPolygonOutline(box, pal.tone4, 1.2, 0.6),
            delay: 0.72,
          ),
        );
    }
    final double wrap = math.min(w * 0.72, diagonal * 0.52);
    final String subtitleText = <String?>[c.artist, c.album]
        .where((String? v) => (v ?? '').trim().isNotEmpty)
        .map((String? v) => v!.trim())
        .join(' - ');
    final double titleSize = math.max(26, math.min(w, h) * 0.085 * c.fontScale);
    final String titleText = (c.title ?? '').trim().isEmpty
        ? '♪'
        : c.title!.trim();
    final TextPainter title = TextPainter(
      text: TextSpan(
        text: titleText,
        style: temperaTextStyle(titleSize, pal.ink),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 3,
      ellipsis: '…',
    )..layout(maxWidth: wrap);
    TextPainter? subtitle;
    if (subtitleText.isNotEmpty) {
      subtitle = TextPainter(
        text: TextSpan(
          text: subtitleText,
          style: temperaTextStyle(
            math.max(14, titleSize * 0.34),
            pal.ink.withValues(alpha: 0.75),
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: wrap);
    }
    return _Credits(items, ground, title, subtitle, titleSize, diagonal);
  }

  void dispose() {
    title.dispose();
    subtitle?.dispose();
  }

  void _drawItem(
    Canvas canvas,
    _CreditsItem item,
    double elapsed,
    double creep,
    void Function(TemperaOp op, double alpha)? paintOp,
  ) {
    final double enter = temperaEaseEnter((elapsed - item.delay) / 1.1);
    if (enter <= 0.001) return;
    canvas.save();
    canvas.translate(
      item.baseX + item.enterDX * (1 - enter) + item.driftX * creep,
      item.baseY + item.enterDY * (1 - enter) + item.driftY * creep,
    );
    if (item.grow != 0) canvas.scale(1 + item.grow * creep);
    for (final TemperaOp op in item.node.ops) {
      if (paintOp != null) {
        paintOp(op, enter);
      } else {
        op.draw(canvas, enter);
      }
    }
    canvas.restore();
  }

  void paint(
    Canvas canvas,
    TemperaCreditsFrame frame,
    double elapsed,
    TemperaSceneConfig c,
    Size screen,
  ) {
    if (frame.posterAlpha <= 0.002) return;
    final TemperaPalette pal = c.palette;
    final double creep = 1 - math.exp(-math.max(0, elapsed) / 7);
    final Rect big = Rect.fromLTWH(
      -diagonal,
      -diagonal,
      diagonal * 2,
      diagonal * 2,
    );
    canvas.save();
    // 海报以画面中心为原点。
    canvas.translate(
      screen.width / 2,
      screen.height / 2 + frame.posterOffsetY * screen.height,
    );
    canvas.scale(frame.posterScale);
    canvas.saveLayer(
      big,
      Paint()
        ..color = Color.fromRGBO(0, 0, 0, frame.posterAlpha.clamp(0.0, 1.0)),
    );
    for (final TemperaOp op in ground.ops) {
      op.draw(canvas, 1);
    }
    for (final _CreditsItem item in items) {
      _drawItem(canvas, item, elapsed, creep, null);
    }
    // 标题：同一套反色
    final double titleEnter = temperaEaseEnter((elapsed - 0.78) / 1.1);
    if (titleEnter > 0.001) {
      canvas.saveLayer(
        big,
        Paint()..color = Color.fromRGBO(0, 0, 0, titleEnter),
      );
      final double dy = diagonal * 0.03 * (1 - titleEnter);
      final TextPainter? sub = subtitle;
      final double titleY = sub == null ? 0 : -titleGap * 0.35;
      title.paint(
        canvas,
        Offset(-title.width / 2, titleY - title.height / 2 + dy),
      );
      if (sub != null) {
        final double subY = titleY + title.height / 2 + titleGap * 0.22;
        sub.paint(canvas, Offset(-sub.width / 2, subY + dy));
      }
      _recolor(canvas, pal, c.settings, big, elapsed, creep);
      canvas.restore();
    }
    canvas.restore();
    canvas.restore();
  }

  void _recolor(
    Canvas canvas,
    TemperaPalette pal,
    TemperaSettings s,
    Rect big,
    double elapsed,
    double creep,
  ) {
    final List<Color>? ramp = pal.textGradient;
    if (!s.textInversion && ramp == null) return;
    Paint paintFor(Color tone, double? stroke) {
      final Paint p = Paint()
        ..blendMode = BlendMode.srcATop
        ..style = stroke == null ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = stroke ?? 0;
      if (ramp != null && ramp.length >= 2) {
        final Color? matched = s.textInversion ? tone : null;
        if (_tint == null || _tintTone != matched) {
          _tintTone = matched;
          final double half = title.width / 2;
          _tint = ui.Gradient.linear(
            Offset(-half, 0),
            Offset(math.max(half, -half + 1), 0),
            <Color>[
              for (final Color c in ramp)
                matched == null ? c : temperaWithLuminanceOf(c, matched),
            ],
            <double>[
              for (int i = 0; i < ramp.length; i++) i / (ramp.length - 1),
            ],
          );
        }
        p.shader = _tint;
      } else {
        p.color = tone;
      }
      return p;
    }

    if (!s.textInversion) {
      canvas.drawRect(big, paintFor(pal.ink, null));
      return;
    }
    Color toneOver(Color backdrop) =>
        temperaPrefersPaper(backdrop, pal.ink, pal.paper) ? pal.paper : pal.ink;
    canvas.drawRect(big, paintFor(toneOver(pal.tone1), null));
    for (final _CreditsItem item in items) {
      _drawItem(canvas, item, elapsed, creep, (TemperaOp op, double a) {
        final double eff = a * op.alpha;
        if (eff < 0.34) return;
        canvas.drawPath(
          op.path,
          paintFor(
            toneOver(temperaMix(pal.tone1, op.color, math.min(1, eff))),
            op.strokeWidth,
          ),
        );
      });
    }
  }
}
