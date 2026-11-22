/// 隐喻的画法（folia `createMetaphorRuntime.ts` 的 render + `metaphorShaders.ts`，换成 Canvas 合成）。
/// 两步，和 folia 一样：
/// 1. 墨场：字形（图集实例化）、融球 / 圆环（轮廓精灵实例化）、线稿（缓存的矢量图）都用加法混合
///    画进一张离屏图——R 是墨、G 是网点的浓淡、B 是强调色的墨。字和融球挨近了相加就连成一片。
/// 2. 显影：离屏图贴在一张随流场推歪的网格上（每秒 8 格地跳），再用色彩矩阵层「切阈值」：
///    R（加上阈值噪点、漫墨）过阈值就是墨；B 过阈值是强调色；网点浓淡和一格半调的距离场相加后
///    过阈值就是大小不一的圆点。最后压上杂点、四角的裁切标记和砂纸颗粒。全部是 GPU 合成，没有逐像素 Dart。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_camera.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_figures.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_glyphs.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_palette.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_shapes.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_textures.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_tuning.dart';

/// 装饰跟着一张位移场抖多远（世界单位，「流体」是 1 时）。
const double _wobble = 0.05;

/// 网点格子的基础大小（逻辑像素）。
const double _dotSize = 7;

/// 墨场离屏图的长边上限（逻辑像素）：再大只是更费，阈值切出来的边已经够干净。
const double _fieldMaxSide = 960;

/// 切阈值的斜率：越大边越硬。
const double _inkSlope = 14;
const double _dotSlope = 10;

/// 线两边那圈网点有多宽（世界单位）。
const double _fringe = 0.11;
const double _deg = math.pi / 180;

final double _tanHalfFov = math.tan(metaphorFov * math.pi / 360);

/// 某一帧要画的全部量（纯计算，可单测）。
class MetaphorFrameState {
  const MetaphorFrameState({
    required this.cueIndex,
    required this.cue,
    required this.shot,
    required this.pose,
    required this.fluidTime,
    required this.time,
    required this.reveal,
    required this.melt,
    required this.flood,
    required this.pop,
    required this.invert,
    required this.screenAngle,
    required this.seed,
    required this.flow,
    required this.audio,
    required this.still,
  });

  final int cueIndex;
  final MetaphorCue cue;
  final MetaphorShot shot;
  final MetaphorPose pose;

  /// 融球 / 流场的时间（静态模式停在 cue 开头）。
  final double fluidTime;

  /// 播放时间（秒，不小于 0）。
  final double time;
  final double reveal;
  final double melt;
  final double flood;
  final double pop;
  final bool invert;
  final double screenAngle;
  final double seed;

  /// 显影时流场推歪的幅度。
  final double flow;
  final double audio;
  final bool still;
}

/// 解出一帧：哪个 cue、哪个镜头、机位、转场和字的进度。
MetaphorFrameState resolveMetaphorFrame(
  MetaphorScene scene,
  double timeSeconds,
  double aspect,
) {
  final LyricVisualizerContext c = scene.context;
  final MetaphorSettings s = scene.settings;
  final bool still = !c.motion;
  final double safe = timeSeconds.isFinite ? math.max(0, timeSeconds) : 0;
  final int cueIndex = findMetaphorCue(scene.program, safe);
  final MetaphorCue cue = scene.program.cues[cueIndex];
  final MetaphorSet set = scene.ensureSet(cueIndex);
  // 下一个快到了就先备好，免得在切过去那一帧才排版、拼图集
  if (cueIndex + 1 < scene.program.cues.length &&
      scene.program.cues[cueIndex + 1].start - safe < 2.5) {
    scene.ensureSet(cueIndex + 1);
    scene.ensureSet(cueIndex);
  }
  final double cueTime = resolveMetaphorCueTime(cue, safe);
  final MetaphorShot shot = findMetaphorShot(cue, cueTime);
  final MetaphorPose pose = still
      ? resolveMetaphorStillPose(set.layout, aspect)
      : scene.tracker.resolve(
          MetaphorPoseInput(
            shot: shot,
            layout: set.layout,
            time: cueTime,
            aspect: aspect,
            motion: s.cameraMotion,
          ),
        );
  // 没有实时频谱：音量用逐字起音的包络代替
  final double audio = still
      ? 0
      : 0.6 * scene.runtime.pulseAt((safe * 1000).round(), decayMs: 600);
  return MetaphorFrameState(
    cueIndex: cueIndex,
    cue: cue,
    shot: shot,
    pose: pose,
    fluidTime: still ? cue.start : safe,
    time: safe,
    reveal: resolveMetaphorReveal(cue, safe),
    melt: resolveMetaphorMelt(cue, safe),
    flood: still ? 0 : resolveMetaphorFlood(scene.program, cueIndex, safe),
    pop: still ? 0 : 1,
    invert: !still && shot.invert,
    screenAngle: still ? 30 * _deg : shot.screenAngle,
    seed: still ? 0.37 : shot.seed,
    flow: still ? s.flow * 0.5 : s.flow * (1 + audio * 0.6),
    audio: audio,
    still: still,
  );
}

int _argb(double r, double g, double b) {
  final int ri = (r.clamp(0.0, 1.0) * 255).round();
  final int gi = (g.clamp(0.0, 1.0) * 255).round();
  final int bi = (b.clamp(0.0, 1.0) * 255).round();
  return (0xFF000000 | (ri << 16) | (gi << 8) | bi).toSigned(32);
}

Color _rgb(double r, double g, double b) => Color.from(
  alpha: 1,
  red: r.clamp(0.0, 1.0),
  green: g.clamp(0.0, 1.0),
  blue: b.clamp(0.0, 1.0),
);

/// 一批精灵（drawRawAtlas 的三段数据）。
class _Batch {
  final List<double> xforms = <double>[];
  final List<double> rects = <double>[];
  final List<int> colors = <int>[];

  bool get isEmpty => colors.isEmpty;

  void add(RSTransform t, Rect src, int color) {
    xforms
      ..add(t.scos)
      ..add(t.ssin)
      ..add(t.tx)
      ..add(t.ty);
    rects
      ..add(src.left)
      ..add(src.top)
      ..add(src.right)
      ..add(src.bottom);
    colors.add(color);
  }

  void draw(Canvas canvas, ui.Image image, Paint paint) {
    if (isEmpty) return;
    canvas.drawRawAtlas(
      image,
      Float32List.fromList(xforms),
      Float32List.fromList(rects),
      Int32List.fromList(colors),
      BlendMode.modulate,
      null,
      paint,
    );
  }
}

/// 墨场与显影的画家（一个样式实例一个，持有逐帧的缓存）。
class MetaphorRenderer {
  MetaphorRenderer(this.scene);

  final MetaphorScene scene;
  final MetaphorInstances _instances = MetaphorInstances();
  ui.Image? _field;
  String? _warpKey;
  ui.Vertices? _warp;

  void dispose() {
    _field?.dispose();
    _field = null;
    _warp?.dispose();
    _warp = null;
  }

  void paint(Canvas canvas, Size size, int timeMs) {
    if (size.width < 1 || size.height < 1) return;
    final double aspect = size.width / size.height;
    scene.ensureAspect(aspect);
    final MetaphorFrameState f = resolveMetaphorFrame(
      scene,
      timeMs / 1000,
      aspect,
    );
    final MetaphorSet set = scene.ensureSet(f.cueIndex);
    final MetaphorSettings s = scene.settings;
    final MetaphorPalette palette = resolveMetaphorPalette(
      scene.context.palette,
      flip: s.flip,
    );
    final MetaphorTextures tex = scene.textures;

    final double q = math.min(1, _fieldMaxSide / size.longestSide);
    final int fw = math.max(1, (size.width * q).ceil());
    final int fh = math.max(1, (size.height * q).ceil());
    final ui.Image field = _renderField(set, f, size, q, fw, fh, tex);
    _field?.dispose();
    _field = field;
    _develop(canvas, size, f, s, palette, tex, field, q);
  }

  // ---------------------------------------------------------------------------
  // 墨场
  // ---------------------------------------------------------------------------

  ui.Image _renderField(
    MetaphorSet set,
    MetaphorFrameState f,
    Size size,
    double q,
    int fw,
    int fh,
    MetaphorTextures tex,
  ) {
    final MetaphorSettings s = scene.settings;
    final MetaphorPose pose = f.pose;
    final double ppw = size.height / (2 * pose.distance * _tanHalfFov);
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas c = Canvas(recorder);
    c.drawRect(
      Rect.fromLTWH(0, 0, fw.toDouble(), fh.toDouble()),
      Paint()..color = const Color(0xFF000000),
    );
    final Paint plus = Paint()
      ..blendMode = BlendMode.plus
      ..filterQuality = FilterQuality.low;

    // 世界坐标：y 朝上，机位只有平移、远近、滚转
    c
      ..save()
      ..scale(q)
      ..translate(size.width / 2, size.height / 2)
      ..scale(ppw, -ppw)
      ..rotate(-pose.roll)
      ..translate(-pose.x, -pose.y);

    final double since = f.still ? double.infinity : f.time - f.cue.start;
    final double shakeTime = (f.fluidTime * 8).floorToDouble() / 8;
    final ui.Picture lineArt = _lineArt(set, since, shakeTime, s.flow);
    c.drawPicture(lineArt);

    _instances.clear();
    writeMetaphorShapes(
      set.shapes,
      f.fluidTime,
      f.audio,
      s.flow,
      _instances,
      since: since,
      includeLines: false,
    );
    if (!f.still) {
      writeMetaphorPairs(set.layout.glyphs, f.time, _instances);
      writeMetaphorCollisions(
        set.collisions,
        resolveMetaphorCueTime(f.cue, f.time),
        _instances,
      );
    }
    final _Batch blobCore = _Batch();
    final _Batch blobHalo = _Batch();
    final _Batch ringCore = _Batch();
    final _Batch ringHalo = _Batch();
    const Rect blobSrc = Rect.fromLTWH(
      0,
      0,
      metaphorSpriteRadius * 2,
      metaphorSpriteRadius * 2,
    );
    const Rect ringSrc = Rect.fromLTWH(
      0,
      0,
      metaphorRingSpriteRadius * 2,
      metaphorRingSpriteRadius * 2,
    );
    final int haloGray = _argb(0, 0.35, 0);
    for (int i = 0; i < _instances.count; i++) {
      final int shape = _instances.shapeAt(i);
      final double x = _instances.valueAt(i, 0);
      final double y = _instances.valueAt(i, 1);
      final double sx = _instances.valueAt(i, 2);
      final double ink = _instances.valueAt(i, 5);
      final double tone = _instances.valueAt(i, 6);
      final double accent = _instances.valueAt(i, 7);
      if (sx <= 0) continue;
      if (shape == metaphorShapeBlob) {
        final RSTransform t = RSTransform.fromComponents(
          rotation: 0,
          scale: sx / metaphorSpriteRadius,
          anchorX: metaphorSpriteRadius,
          anchorY: metaphorSpriteRadius,
          translateX: x,
          translateY: y,
        );
        blobCore.add(t, blobSrc, _argb(ink, 0, accent));
        blobHalo.add(
          t,
          blobSrc,
          _argb(0, tone * 0.6 + 0.55 * (ink + accent), 0),
        );
      } else if (shape == metaphorShapeRing) {
        final RSTransform t = RSTransform.fromComponents(
          rotation: 0,
          scale: sx / metaphorRingSpriteRadius,
          anchorX: metaphorRingSpriteRadius,
          anchorY: metaphorRingSpriteRadius,
          translateX: x,
          translateY: y,
        );
        ringCore.add(t, ringSrc, _argb(ink, tone, accent));
        ringHalo.add(t, ringSrc, haloGray);
      }
    }
    blobHalo.draw(c, tex.blobHalo, plus);
    blobCore.draw(c, tex.blobCore, plus);
    ringHalo.draw(c, tex.ringHalo, plus);
    ringCore.draw(c, tex.ringCore, plus);
    c.restore();

    // 字形：屏幕坐标里摆（字不能跟着世界的 y 翻过来）
    final MetaphorAtlas? atlas = set.atlas;
    if (atlas != null) {
      final _Batch tight = _Batch();
      final _Batch wide = _Batch();
      final double cos = math.cos(pose.roll);
      final double sin = math.sin(pose.roll);
      final double keep = 1 - f.melt;
      final double wobble = _wobble * s.flow;
      for (final MetaphorGlyphEntry g in set.entries) {
        final int? slot = atlas.slots[g.key];
        if (slot == null) continue;
        final double dt = f.time - g.t0;
        final bool on = dt >= 0;
        final double age = math.max(0, dt);
        double scale = on ? 1 + f.pop * 0.18 * math.exp(-age * 2.2) : 0.94;
        scale *= 1 + f.melt * 0.25;
        // 化开：各自朝自己的方向散出去（不是往下淌）
        final double away = g.seed * math.pi * 2;
        final double push =
            f.melt * f.melt * (0.4 + ((g.seed * 7.31) % 1) * 0.9) * g.size;
        double wx = g.x + math.cos(away) * push;
        double wy = g.y + math.sin(away) * push;
        int tightColor;
        int wideColor;
        if (g.note) {
          // 注记：细的墨字，和线稿同一支笔一起抖；字周围一圈淡的网点
          final (double shx, double shy) = metaphorShake(wx, wy, shakeTime);
          wx += shx * wobble * 0.6;
          wy += shy * wobble * 0.6;
          final double onF = on ? 1 : 0;
          tightColor = _argb(onF * keep * keep * 1.12, 0, 0);
          wideColor = _argb(0, 0.55 * onF * keep, 0);
        } else {
          final double onF = on ? 1 : 0;
          final double setV = onF * (1 - math.exp(-age * 4.5));
          final double bulge = onF * math.exp(-age * 1.5);
          final double inkT = setV * keep * keep;
          final double inkW =
              (bulge * 1.25 + 0.3 * setV + 0.9 * f.melt * setV) * keep;
          final double toneT = (1 - setV) * 0.85 * f.reveal * keep;
          final double toneW = (0.3 + 0.45 * setV) * f.reveal * keep;
          final double acc = g.accent ? 1 : 0;
          tightColor = _argb(inkT * (1 - acc), toneT, inkT * acc);
          wideColor = _argb(inkW * (1 - acc), toneW, inkW * acc);
        }
        final double dx = wx - pose.x;
        final double dy = wy - pose.y;
        final double ax = dx * cos + dy * sin;
        final double ay = -dx * sin + dy * cos;
        final double px = (size.width / 2 + ax * ppw) * q;
        final double py = (size.height / 2 - ay * ppw) * q;
        final double spriteScale = g.size * ppw * scale * q / metaphorGlyphEm;
        if (spriteScale * metaphorGlyphCell < 0.5) continue;
        final RSTransform t = RSTransform.fromComponents(
          rotation: -(g.rot - pose.roll),
          scale: spriteScale,
          anchorX: metaphorGlyphCell / 2,
          anchorY: metaphorGlyphCell / 2,
          translateX: px,
          translateY: py,
        );
        tight.add(t, atlas.tightRect(slot), tightColor);
        wide.add(t, atlas.wideRect(slot), wideColor);
      }
      wide.draw(c, atlas.image, plus);
      tight.draw(c, atlas.image, plus);
    }

    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = picture.toImageSync(fw, fh);
    picture.dispose();
    return image;
  }

  /// 线稿（细线、圆弧、波浪线）：按冒出来的笔数和手抖的格缓存成一张世界坐标的矢量图。
  ui.Picture _lineArt(
    MetaphorSet set,
    double since,
    double shakeTime,
    double flow,
  ) {
    int visible = 0;
    for (final MetaphorShape sh in set.shapes) {
      if (sh.isLine && sh.born <= since) visible++;
    }
    final String key = '$visible|$shakeTime|$flow';
    final ui.Picture? cached = set.lineArt;
    if (cached != null && set.lineArtKey == key) return cached;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas c = Canvas(recorder);
    final double wobble = _wobble * flow;
    for (final MetaphorShape sh in set.shapes) {
      if (!sh.isLine || sh.born > since) continue;
      _drawLineShape(c, sh, shakeTime, wobble);
    }
    final ui.Picture picture = recorder.endRecording();
    set.replaceLineArt(key, picture);
    return picture;
  }

  void _drawLineShape(
    Canvas c,
    MetaphorShape sh,
    double shakeTime,
    double wobble,
  ) {
    final double inked = math.min(1, sh.ink + sh.accent);
    final Paint core = Paint()
      ..blendMode = BlendMode.plus
      ..color = _rgb(sh.ink, sh.tone, sh.accent);
    final double cos = math.cos(sh.rot);
    final double sin = math.sin(sh.rot);
    Offset world(double lx, double ly) {
      final double wx = sh.x + lx * cos - ly * sin;
      final double wy = sh.y + lx * sin + ly * cos;
      if (wobble == 0) return Offset(wx, wy);
      final (double dx, double dy) = metaphorShake(wx, wy, shakeTime);
      return Offset(wx + dx * wobble, wy + dy * wobble);
    }

    Path polyline(List<Offset> pts) {
      final Path p = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (int i = 1; i < pts.length; i++) {
        p.lineTo(pts[i].dx, pts[i].dy);
      }
      return p;
    }

    void stroke(Path path, double halfWidth, double haloAmount) {
      if (haloAmount > 0) {
        c.drawPath(
          path,
          Paint()
            ..blendMode = BlendMode.plus
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 * (halfWidth + _fringe * 0.5)
            ..color = _rgb(0, haloAmount, 0),
        );
      }
      c.drawPath(
        path,
        core
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 * halfWidth * 1.1,
      );
    }

    final double halo = math.max(inked * 0.55, sh.tone * 0.4);
    if (sh.shape == metaphorShapeBar) {
      final double reach = sh.sy;
      if (reach > 0.06) {
        // 色带：一块长方形，不抖
        final Path band = Path()
          ..addPolygon(<Offset>[
            world(-sh.sx, -reach),
            world(sh.sx, -reach),
            world(sh.sx, reach),
            world(-sh.sx, reach),
          ], true);
        c.drawPath(band, core..style = PaintingStyle.fill);
        return;
      }
      // 虚线：fract(u·n + 0.25) ≤ 0.55 的那几段
      final List<(double, double)> runs = <(double, double)>[];
      if (sh.param > 0.5) {
        final double n = sh.param;
        for (int k = 0; k <= n.ceil() + 1; k++) {
          final double a = math.max(0, (k - 0.25) / n);
          final double b = math.min(1, (k + 0.3) / n);
          if (b > a) runs.add((a, b));
        }
      } else {
        runs.add((0, 1));
      }
      for (final (double a, double b) in runs) {
        final double len = (b - a) * sh.sx * 2;
        final int steps = math.max(1, (len / 0.08).ceil());
        final List<Offset> pts = <Offset>[
          for (int i = 0; i <= steps; i++)
            world(-sh.sx + (a + (b - a) * i / steps) * sh.sx * 2, 0),
        ];
        stroke(polyline(pts), reach, halo);
      }
    } else if (sh.shape == metaphorShapeArc) {
      final double radius = metaphorArcAt * sh.sx;
      final double half = sh.param * math.pi;
      final int steps = math.max(
        12,
        (radius * half * 2 / 0.06).ceil().clamp(12, 400),
      );
      final List<Offset> pts = <Offset>[
        for (int i = 0; i <= steps; i++)
          world(
            math.cos(-half + 2 * half * i / steps) * radius,
            math.sin(-half + 2 * half * i / steps) * radius,
          ),
      ];
      final Path path = polyline(pts);
      if (sh.param >= 1) path.close();
      stroke(path, metaphorStroke * sh.sy, halo);
    } else if (sh.shape == metaphorShapeWave) {
      final double amp = sh.sy * metaphorWaveAmp;
      final int steps = math.max(16, (sh.param * 12).ceil());
      final List<Offset> pts = <Offset>[
        for (int i = 0; i <= steps; i++)
          world(
            -sh.sx + 2 * sh.sx * i / steps,
            amp * math.sin(math.pi / 2 * sh.param * (2 * i / steps)),
          ),
      ];
      stroke(polyline(pts), metaphorStroke, halo);
    }
  }

  // ---------------------------------------------------------------------------
  // 显影
  // ---------------------------------------------------------------------------

  void _develop(
    Canvas canvas,
    Size size,
    MetaphorFrameState f,
    MetaphorSettings s,
    MetaphorPalette palette,
    MetaphorTextures tex,
    ui.Image field,
    double q,
  ) {
    final Rect full = Offset.zero & size;
    final Color paper = f.invert ? palette.ink : palette.paper;
    final Color ink = f.invert ? palette.paper : palette.ink;
    final double grain = s.grain;
    final ui.Vertices warp = _warpMesh(size, f, q);
    final Paint fieldPaint = Paint()
      ..filterQuality = FilterQuality.low
      ..shader = ImageShader(
        field,
        TileMode.clamp,
        TileMode.clamp,
        _translate(0, 0),
        filterQuality: FilterQuality.low,
      );
    final double seedShift = (f.seed * 997) % 240;
    final Paint roughPaint = Paint()
      ..blendMode = BlendMode.plus
      ..color = Color.from(
        alpha: (0.24 * grain).clamp(0.0, 1.0),
        red: 1,
        green: 1,
        blue: 1,
      )
      ..shader = ImageShader(
        tex.rough,
        TileMode.repeated,
        TileMode.repeated,
        _translate(seedShift, seedShift * 0.37),
      );
    final double threshold = 0.5 + 0.12 * grain;

    canvas.drawRect(full, Paint()..color = paper);

    // 半调：网点浓淡 + 一格的距离场，过阈值就是圆点
    canvas.saveLayer(
      full,
      Paint()
        ..colorFilter = ColorFilter.matrix(
          _constantRgb(
            palette.tone,
            0.82 * _dotSlope,
            -0.82 * _dotSlope * 0.5075,
          ),
        ),
    );
    canvas.saveLayer(
      full,
      Paint()
        ..colorFilter = const ColorFilter.matrix(<double>[
          0, 0, 0, 0, 255, //
          0, 0, 0, 0, 255, //
          0, 0, 0, 0, 255, //
          0.25, 0.45, 0.25, 0, 0,
        ]),
    );
    canvas.drawVertices(warp, BlendMode.srcOver, fieldPaint);
    canvas.restore();
    // 四角的暗角也进网点
    canvas
      ..save()
      ..scale(size.width, size.height)
      ..drawRect(
        const Rect.fromLTWH(0, 0, 1, 1),
        Paint()
          ..blendMode = BlendMode.plus
          ..shader =
              ui.Gradient.radial(const Offset(0.5, 0.5), 1 / 1.3, <Color>[
                for (final double st in _vignetteStops)
                  Color.from(
                    alpha: 0.15 * _smoothstep(0.42, 1, st),
                    red: 1,
                    green: 1,
                    blue: 1,
                  ),
              ], _vignetteStops),
      )
      ..restore();
    final double dot = _dotSize * s.halftone;
    final double k = dot / metaphorDotCell;
    final double ca = math.cos(f.screenAngle);
    final double sa = math.sin(f.screenAngle);
    canvas.drawRect(
      full,
      Paint()
        ..blendMode = BlendMode.plus
        ..color = const Color(0x80FFFFFF)
        ..filterQuality = FilterQuality.low
        ..shader = ImageShader(
          tex.dotCell,
          TileMode.repeated,
          TileMode.repeated,
          Float64List.fromList(<double>[
            k * ca, k * sa, 0, 0, //
            -k * sa, k * ca, 0, 0, //
            0, 0, 1, 0, //
            0, 0, 0, 1,
          ]),
          filterQuality: FilterQuality.low,
        ),
    );
    canvas.restore();

    // 强调色的墨（B 通道）
    _thresholdLayer(
      canvas,
      full,
      warp,
      fieldPaint,
      roughPaint,
      palette.accent,
      channel: 2,
      offset: -threshold,
    );

    // 杂点：墨色的撒在纸上（落在墨里的被墨盖住），纸色的在墨上面（落在纸上的看不出）
    final double beat = (f.fluidTime * 6).floorToDouble();
    final double speckAmount = 0.55 * math.min(grain, 1.5);
    final double jitterX = metaphorHash(beat * 7.13, 0.5) * 220;
    final double jitterY = metaphorHash(beat * 3.7, 1.5) * 220;
    if (speckAmount > 0) {
      _specks(canvas, full, tex, ink, speckAmount, jitterX, jitterY);
    }

    // 墨（R 通道 + 漫墨），最后画：强调色融球漂到字上时字压在它上面
    _thresholdLayer(
      canvas,
      full,
      warp,
      fieldPaint,
      roughPaint,
      ink,
      channel: 0,
      offset: f.flood - threshold,
    );
    if (speckAmount > 0) {
      _specks(canvas, full, tex, paper, speckAmount, jitterY, jitterX);
    }

    // 画面四角的裁切标记：钉在屏幕上，不跟着镜头走
    final Paint mark = Paint()
      ..color = ink.withValues(alpha: 0.85)
      ..strokeWidth = 1.5;
    for (final double sx in const <double>[0, 1]) {
      for (final double sy in const <double>[0, 1]) {
        final double x = sx == 0 ? 18 : size.width - 18;
        final double y = sy == 0 ? 18 : size.height - 18;
        final double dx = sx == 0 ? 1 : -1;
        final double dy = sy == 0 ? 1 : -1;
        canvas
          ..drawLine(Offset(x, y), Offset(x, y + dy * 16), mark)
          ..drawLine(Offset(x, y), Offset(x + dx * 16, y), mark);
      }
    }

    // 砂纸颗粒：每秒 6 格地换（平移一张颗粒图）
    if (grain > 0) {
      canvas.drawRect(
        full,
        Paint()
          ..blendMode = BlendMode.overlay
          ..color = Color.from(
            alpha: (grain / 2).clamp(0.0, 1.0),
            red: 1,
            green: 1,
            blue: 1,
          )
          ..shader = ImageShader(
            tex.grain,
            TileMode.repeated,
            TileMode.repeated,
            _translate(jitterX * 1.13, jitterY * 0.87),
          ),
      );
    }
  }

  void _thresholdLayer(
    Canvas canvas,
    Rect full,
    ui.Vertices warp,
    Paint fieldPaint,
    Paint roughPaint,
    Color color, {
    required int channel,
    required double offset,
  }) {
    final List<double> m = <double>[
      0, 0, 0, 0, color.r * 255, //
      0, 0, 0, 0, color.g * 255, //
      0, 0, 0, 0, color.b * 255, //
      0, 0, 0, 0, _inkSlope * offset * 255,
    ];
    m[15 + channel] = _inkSlope;
    canvas.saveLayer(full, Paint()..colorFilter = ColorFilter.matrix(m));
    canvas
      ..drawVertices(warp, BlendMode.srcOver, fieldPaint)
      ..drawRect(full, roughPaint)
      ..restore();
  }

  void _specks(
    Canvas canvas,
    Rect full,
    MetaphorTextures tex,
    Color color,
    double amount,
    double jx,
    double jy,
  ) {
    canvas.drawRect(
      full,
      Paint()
        ..color = Color.from(
          alpha: amount.clamp(0.0, 1.0),
          red: 1,
          green: 1,
          blue: 1,
        )
        ..colorFilter = ColorFilter.mode(color, BlendMode.srcIn)
        ..shader = ImageShader(
          tex.speck,
          TileMode.repeated,
          TileMode.repeated,
          _translate(jx, jy),
        ),
    );
  }

  /// 流场推歪的贴图网格：一层大的慢慢推，一层小的抖，每秒 8 格地跳（按格缓存）。
  ui.Vertices _warpMesh(Size size, MetaphorFrameState f, double q) {
    final double tq = (f.fluidTime * 8).floorToDouble() / 8;
    final String key =
        '${size.width}x${size.height}|$tq|${f.flow.toStringAsFixed(3)}|$q';
    final ui.Vertices? cached = _warp;
    if (cached != null && _warpKey == key) return cached;
    final double w = size.width;
    final double h = size.height;
    final double aspect = w / h;
    final double cell = math.max(w, h) / 48;
    final int cols = math.max(2, (w / cell).ceil());
    final int rows = math.max(2, (h / cell).ceil());
    final Float32List pos = Float32List((cols + 1) * (rows + 1) * 2);
    final Float32List uv = Float32List((cols + 1) * (rows + 1) * 2);
    int at = 0;
    for (int r = 0; r <= rows; r++) {
      for (int col = 0; col <= cols; col++) {
        final double x = w * col / cols;
        final double y = h * r / rows;
        final double u = x / w;
        final double v = 1 - y / h;
        final double px = u * aspect;
        final double py = v;
        double wx =
            (metaphorValueNoise(px * 3.2, py * 3.2 + tq * 0.16) - 0.5) * 0.024 +
            (metaphorValueNoise(px * 9.0 + tq * 0.3, py * 9.0 + 3.0) - 0.5) *
                0.007;
        double wy =
            (metaphorValueNoise(px * 3.2 + 17.3, py * 3.2 - tq * 0.13) - 0.5) *
                0.024 +
            (metaphorValueNoise(px * 9.0 + 31.7, py * 9.0 - tq * 0.27) - 0.5) *
                0.007;
        wx *= f.flow / aspect;
        wy *= f.flow;
        pos[at] = x;
        pos[at + 1] = y;
        uv[at] = (x + wx * w) * q;
        uv[at + 1] = (y - wy * h) * q;
        at += 2;
      }
    }
    final Uint16List indices = Uint16List(cols * rows * 6);
    int k = 0;
    for (int r = 0; r < rows; r++) {
      for (int col = 0; col < cols; col++) {
        final int a = r * (cols + 1) + col;
        final int b = a + 1;
        final int c = a + cols + 1;
        final int d = c + 1;
        indices[k++] = a;
        indices[k++] = b;
        indices[k++] = c;
        indices[k++] = b;
        indices[k++] = d;
        indices[k++] = c;
      }
    }
    final ui.Vertices mesh = ui.Vertices.raw(
      VertexMode.triangles,
      pos,
      textureCoordinates: uv,
      indices: indices,
    );
    _warp?.dispose();
    _warp = mesh;
    _warpKey = key;
    return mesh;
  }
}

const List<double> _vignetteStops = <double>[
  0,
  0.42,
  0.5,
  0.6,
  0.7,
  0.8,
  0.9,
  1,
];

double _smoothstep(double e0, double e1, double x) {
  final double t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

Float64List _translate(double x, double y) => Float64List.fromList(<double>[
  1, 0, 0, 0, //
  0, 1, 0, 0, //
  0, 0, 1, 0, //
  x, y, 0, 1,
]);

/// 色彩矩阵：RGB 换成常量 [color]，α = slope·α + offset。
List<double> _constantRgb(Color color, double slope, double offset) => <double>[
  0, 0, 0, 0, color.r * 255, //
  0, 0, 0, 0, color.g * 255, //
  0, 0, 0, 0, color.b * 255, //
  0, 0, 0, slope, offset * 255,
];

/// CustomPainter：每帧（时间变了）重画。
class MetaphorPainter extends CustomPainter {
  MetaphorPainter({
    required this.renderer,
    required this.ticks,
    required this.context,
  }) : super(repaint: ticks);

  final MetaphorRenderer renderer;

  /// 只用来判断输入变了没有（配色、参数、歌）。
  final LyricVisualizerContext context;
  final ValueListenable<LyricVisualizerTick> ticks;

  @override
  void paint(Canvas canvas, Size size) {
    renderer.paint(canvas, size, ticks.value.timeMs);
  }

  @override
  bool shouldRepaint(MetaphorPainter oldDelegate) =>
      !identical(oldDelegate.renderer, renderer) ||
      !identical(oldDelegate.ticks, ticks) ||
      !identical(oldDelegate.context, context);
}
