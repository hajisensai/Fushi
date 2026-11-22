/// 雾笺每帧的合成（folia `createNebbiaRuntime.ts` + `nebbiaMask.ts` + `nebbiaInk.ts` + 主着色器的 Canvas 版）：
///
/// 1. 清晰的窗外（nebbia_window.dart 录成一张 Picture）；
/// 2. 雾：同一张窗外套高斯模糊、压暗、加一层更散的光晕和乳白，叠上哈气的白气、聚光灯照在雾上的一圈、
///    玻璃上的凝结水珠 / 冷凝水珠 / 雪；再用 `dstOut` 把手指写过、抹过、雨点砸开、水珠淌过的地方擦掉，
///    透出底下清晰的窗外。选了共用背景时雾是一层半透明的雾，擦开处透出宿主的背景；
/// 3. 擦痕边的小水珠、收笔水珠、往下淌的水珠、雨点的水珠画在最上面。
///
/// 场景（每句的位置、字形、书写节奏）在 [NebbiaController] 里按歌、尺寸、参数缓存。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_chars.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_glass.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_glyphs.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_tuning.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_window.dart';

const Color _haze = Color.fromARGB(255, 179, 189, 199);

/// 一首歌、一块屏、一份参数下的全部缓存：场景、大雨点、凝结水珠、窗外、字形绘制器，以及窗外时钟。
class NebbiaController {
  NebbiaController();

  final NebbiaWindow window = NebbiaWindow();
  NebbiaBumps? _bumps;
  int _bumpSeed = -1;

  String _key = '';
  List<NebbiaLaidLine> laid = const <NebbiaLaidLine>[];
  List<NebbiaSourceLine> source = const <NebbiaSourceLine>[];
  List<NebbiaHit> bigHits = const <NebbiaHit>[];
  NebbiaFieldDrops? field;
  Size _fieldSize = Size.zero;

  final Map<String, TextPainter> _text = <String, TextPainter>{};
  double _textSize = -1;

  /// 窗外时钟：只在播放时走（暂停时窗外停住），减弱动态效果时恒为 0。
  double sceneTime = 0;
  double _lastElapsed = 0;

  /// 推窗外时钟。
  void advance(double elapsed, bool playing) {
    double dt = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    if (dt < 0 || dt > 0.25) dt = 0;
    if (playing) sceneTime += dt;
  }

  NebbiaBumps bumps(int seed) {
    if (_bumps == null || _bumpSeed != seed) {
      _bumps = NebbiaBumps(seed);
      _bumpSeed = seed;
    }
    return _bumps!;
  }

  /// 按需重排整首。
  void ensure(
    LyricVisualizerContext c,
    NebbiaSettings s,
    Size size,
    TextStyle font,
  ) {
    final NebbiaGlyphCache glyphs = NebbiaGlyphCache.instance;
    final String key = <Object>[
      identityHashCode(c.runtime),
      size.width.round(),
      size.height.round(),
      c.fontScale,
      s.layoutKey,
      c.title ?? '',
      c.artist ?? '',
      c.seed,
      glyphs.version,
    ].join('|');
    if (size != _fieldSize) {
      field = NebbiaFieldDrops(size.width, size.height);
      _fieldSize = size;
    }
    if (key == _key) return;
    _key = key;
    List<NebbiaSourceLine> src = buildNebbiaLines(
      c.runtime.lines,
      c.seed,
      s.doodle,
    );
    if (s.credits) src = appendNebbiaCredits(src, c.title, c.artist);
    source = src;
    glyphs.request(<String>{
      for (final NebbiaSourceLine l in src)
        for (final NebbiaChar ch in l.chars) ch.ch,
    }, font);
    laid = buildNebbiaScene(
      src,
      glyphs.get,
      s,
      width: size.width,
      height: size.height,
      fontScale: c.fontScale,
      seed: c.seed,
    );
    bigHits = nebbiaBigHits(
      laid,
      <List<List<int>>>[for (final NebbiaSourceLine l in src) l.words],
      size.width,
      size.height,
      c.seed,
    );
  }

  /// 字的 TextPainter（扫笔字形用）：按字号缓存，换尺寸清掉。
  TextPainter textFor(
    String ch,
    double fontSize,
    TextStyle font,
    double? stroke,
  ) {
    final double fs = (fontSize * 2).roundToDouble() / 2;
    if (_text.length > 600) clearText();
    final String key = '$ch|$fs|${stroke?.toStringAsFixed(1)}';
    return _text[key] ??= TextPainter(
      text: TextSpan(
        text: ch,
        style: font.copyWith(
          fontSize: fs,
          height: 1,
          fontWeight: FontWeight.w600,
          color: stroke == null ? const Color(0xFFFFFFFF) : null,
          foreground: stroke == null
              ? null
              : (Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = stroke
                  ..strokeJoin = StrokeJoin.round
                  ..color = const Color(0xFFFFFFFF)),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  void clearText() {
    for (final TextPainter p in _text.values) {
      p.dispose();
    }
    _text.clear();
  }

  void dispose() {
    clearText();
    window.dispose();
  }

  /// 文字缓存按字号失效。
  void checkTextSize(double h) {
    if (h != _textSize) {
      clearText();
      _textSize = h;
    }
  }
}

/// 聚光灯这一帧：目标沿字连续移动（写第 i 个字时从它滑向第 i+1 个），再按过去 0.3 秒的目标
/// 指数加权平均当作弹簧的跟随（不积分，拖进度也对）。
({Offset target, double radius, double intensity}) nebbiaSpotAt(
  List<NebbiaLaidLine> laid,
  double t, {
  required bool smooth,
}) {
  ({Offset p, double r})? goal(double at) {
    final ({NebbiaLaidChar c, NebbiaLaidChar? next})? cur = nebbiaWritingChar(
      laid,
      at,
    );
    if (cur == null) return null;
    final NebbiaLaidChar c = cur.c;
    final NebbiaLaidChar? n = cur.next;
    if (n == null) return (p: Offset(c.x, c.y), r: c.s);
    final double u = nebbiaSmooth(
      nebbiaClamp(
        (at - nebbiaStartOf(c)) /
            math.max(0.05, nebbiaStartOf(n) - nebbiaStartOf(c)),
      ),
    );
    return (
      p: Offset(c.x + (n.x - c.x) * u, c.y + (n.y - c.y) * u),
      r: c.s + (n.s - c.s) * u,
    );
  }

  if (!smooth) {
    final ({Offset p, double r})? g = goal(t);
    return g == null
        ? (target: Offset.zero, radius: 0, intensity: 0)
        : (target: g.p, radius: g.r, intensity: 1);
  }
  double wsum = 0;
  double isum = 0;
  double iw = 0;
  Offset p = Offset.zero;
  double r = 0;
  for (int k = 0; k < 12; k++) {
    final double at = t - k * 0.05;
    final ({Offset p, double r})? g = goal(at);
    final double w = math.exp(-k * 0.05 / 0.1);
    final double wi = math.exp(-k * 0.05 / 0.25);
    iw += wi;
    if (g == null) continue;
    isum += wi;
    wsum += w;
    p += g.p * w;
    r += g.r * w;
  }
  if (wsum <= 0) return (target: Offset.zero, radius: 0, intensity: 0);
  return (target: p / wsum, radius: r / wsum, intensity: isum / iw);
}

class NebbiaPainter extends CustomPainter {
  NebbiaPainter({
    required this.c,
    required this.s,
    required this.ticks,
    required this.controller,
    required this.font,
  }) : super(repaint: ticks);

  final LyricVisualizerContext c;
  final NebbiaSettings s;
  final LyricVisualizerTicks ticks;
  final NebbiaController controller;
  final TextStyle font;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final LyricVisualizerTick tick = ticks.value;
    final bool motion = c.motion;
    final double t = tick.timeMs / 1000;
    controller
      ..advance(tick.elapsed, c.playing)
      ..checkTextSize(size.height)
      ..ensure(c, s, size, font);
    final double scene = controller.sceneTime;
    final List<NebbiaLaidLine> laid = controller.laid;
    final NebbiaColors colors = NebbiaColors.from(c.palette);
    final bool seeThrough = s.behind == NebbiaBehind.backdrop;
    final bool aquarium = s.behind == NebbiaBehind.aquarium;
    final double h = size.height;

    // 聚光灯。
    final ({Offset target, double radius, double intensity}) sp = nebbiaSpotAt(
      laid,
      t,
      smooth: motion,
    );
    final double spotI = s.sceneryOn('spot') ? sp.intensity * s.spot : 0;
    final NebbiaSpotFrame spot = NebbiaSpotFrame(
      sp.target,
      math.max(0.02 * h, sp.radius * 0.75),
      spotI,
    );

    // 颠簸（不画水族箱时）。
    final NebbiaBumps bumps = controller.bumps(c.seed);
    final double bumpK = motion && !aquarium ? s.bump : 0;
    final Offset shake = bumps.shakeAt(scene, bumpK);
    final Offset glassShift = shake * 0.35;

    final Rect full = Offset.zero & size;
    ui.Picture? scenePic;
    if (!seeThrough) {
      final ui.PictureRecorder rec = ui.PictureRecorder();
      final Canvas sc = Canvas(rec, full);
      controller.window.paint(
        sc,
        size,
        scene,
        s,
        colors,
        spot,
        snowing: s.glass == NebbiaGlass.snow,
      );
      scenePic = rec.endRecording();
      canvas
        ..drawRect(full, Paint()..color = colors.sky0)
        ..save()
        ..translate(shake.dx, shake.dy)
        ..drawPicture(scenePic)
        ..restore();
    }

    // ---- 雾层 ----
    final double mist = s.mist;
    canvas.saveLayer(full, Paint());
    final Color fogTint;
    if (!seeThrough) {
      fogTint = Color.lerp(colors.sky1, _haze, 0.2 + 0.3 * mist)!;
      canvas
        ..saveLayer(
          full,
          Paint()
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: 0.018 * h,
              sigmaY: 0.018 * h,
              tileMode: TileMode.clamp,
            ),
        )
        ..translate(shake.dx, shake.dy)
        ..drawPicture(scenePic!)
        ..restore()
        ..drawRect(
          full,
          Paint()..color = Color.fromRGBO(0, 0, 0, nebbiaClamp(0.45 * mist)),
        )
        ..saveLayer(
          full,
          Paint()
            ..blendMode = BlendMode.plus
            ..color = Color.fromRGBO(0, 0, 0, nebbiaClamp(0.8 * mist))
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: 0.05 * h,
              sigmaY: 0.05 * h,
              tileMode: TileMode.clamp,
            ),
        )
        ..translate(shake.dx, shake.dy)
        ..drawPicture(scenePic)
        ..restore();
      // 乳白：下半部分略浓。
      canvas.drawRect(
        full,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.linear(Offset.zero, Offset(0, h), <Color>[
            _haze.withValues(alpha: 0.17 * mist),
            _haze.withValues(alpha: 0.23 * mist),
          ]),
      );
    } else {
      fogTint = colors.dark ? const Color(0xFF1A1F26) : const Color(0xFFEBEFF4);
      canvas.drawRect(
        full,
        Paint()
          ..color = fogTint.withValues(
            alpha: nebbiaClamp(0.62 * mist * (colors.dark ? 1.3 : 1), 0, 0.92),
          ),
      );
    }
    // 雾的浓淡起伏：几团很大的软斑慢慢飘。
    for (int i = 0; i < 5; i++) {
      final double x =
          (nebbiaRand(i + 1.5) + scene * 0.004 * (i.isEven ? 1 : -1)) % 1.2 -
          0.1;
      final double y = nebbiaRand(i + 7.5);
      canvas.drawCircle(
        Offset(x * size.width, y * h),
        h * (0.25 + 0.2 * nebbiaRand(i + 3.3)),
        Paint()
          ..color = fogTint.withValues(alpha: 0.06 * mist)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, h * 0.12),
      );
    }
    _breath(canvas, laid, t, fogTint);
    if (spotI > 0.01) {
      canvas.drawCircle(
        spot.target,
        spot.radius * 2.2,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.radial(spot.target, spot.radius * 2.2, <Color>[
            colors.la.withValues(
              alpha: nebbiaClamp(spotI * (0.18 + 0.4 * mist)),
            ),
            colors.la.withValues(alpha: 0),
          ]),
      );
    }

    final Color dropBody = Color.lerp(
      fogTint,
      const Color(0xFF000000),
      seeThrough && !colors.dark ? 0.2 : 0.4,
    )!.withValues(alpha: 0.8);
    final NebbiaDropLook look = NebbiaDropLook(
      body: dropBody,
      glow: Color.lerp(colors.la, _haze, 0.5)!.withValues(alpha: 0.35),
      glint: 1,
    );
    // 玻璃上的水（在雾里：擦开的地方没有）。
    canvas
      ..save()
      ..translate(glassShift.dx, glassShift.dy);
    final List<_Trail> trails = <_Trail>[];
    final List<NebbiaFlakeState> flakes = s.glass == NebbiaGlass.snow
        ? nebbiaFlakesAt(scene, size, s)
        : const <NebbiaFlakeState>[];
    switch (s.glass) {
      case NebbiaGlass.rain:
        _fieldDrops(canvas, bumps, scene, bumpK, look, trails);
      case NebbiaGlass.dew:
        nebbiaPaintDew(canvas, size, scene, s, fogTint);
      case NebbiaGlass.snow:
        for (final NebbiaFlakeState f in flakes) {
          nebbiaPaintFlake(canvas, f, colors.la);
        }
    }
    canvas.restore();

    // 擦痕：dstOut 把雾擦掉。
    final List<_Drop> drops = <_Drop>[];
    final _Ink ink = _Ink(canvas, s, controller, font, motion, drops);
    for (int i = 0; i < laid.length; i++) {
      final NebbiaLaidLine line = laid[i];
      if (t >= line.t - 0.5) _drawLine(ink, line, i, t);
    }
    // 雨点打窗（雨窗才有）。
    if (motion && s.glass == NebbiaGlass.rain) {
      _hits(ink, t, size);
    }
    // 掉落水珠的水痕。
    final Paint trailPaint = Paint()
      ..blendMode = BlendMode.dstOut
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final _Trail tr in trails) {
      canvas.drawLine(
        tr.a + glassShift,
        tr.b + glassShift,
        trailPaint
          ..strokeWidth = tr.w
          ..color = Color.fromRGBO(0, 0, 0, nebbiaClamp(tr.v * 0.95)),
      );
    }
    canvas.restore();

    // ---- 最上面的水珠 ----
    canvas
      ..save()
      ..translate(glassShift.dx, glassShift.dy);
    for (final _Drop d in drops) {
      look.draw(canvas, d.c, d.r, d.a, sx: d.sx, sy: d.sy);
    }
    for (final NebbiaFlakeState f in flakes) {
      if (f.water > 0.5) {
        look.draw(canvas, f.center.translate(0, f.radius * 0.3), f.water, 0.9);
      }
    }
    canvas.restore();
    scenePic?.dispose();
  }

  /// 哈气的白气：一句外框上的几团，从中线鼓开，到点再慢慢散。
  void _breath(
    Canvas canvas,
    List<NebbiaLaidLine> laid,
    double t,
    Color fogTint,
  ) {
    for (int i = 0; i < laid.length; i++) {
      final NebbiaLaidLine line = laid[i];
      if (line.breathAt < double.infinity) {
        _puff(
          canvas,
          line,
          i,
          t,
          line.breathAt,
          line.breathUntil,
          line.breathDur,
          fogTint,
        );
      }
      if (line.appearBreathAt < double.infinity) {
        _puff(
          canvas,
          line,
          i,
          t,
          line.appearBreathAt,
          line.appearBreathUntil,
          NebbiaFixed.breathSpread,
          fogTint,
        );
      }
    }
  }

  void _puff(
    Canvas canvas,
    NebbiaLaidLine line,
    int idx,
    double t,
    double t0,
    double until,
    double spread,
    Color fogTint,
  ) {
    if (t < t0) return;
    final double fade =
        1 -
        nebbiaSmooth(
          nebbiaClamp(
            (t - math.max(until, t0 + spread)) / NebbiaFixed.breathFade,
          ),
        );
    if (fade <= 0.002) return;
    final NebbiaBreathShape? b = line.breath(idx);
    if (b == null) return;
    final double u = nebbiaClamp((t - t0) / spread);
    final double g0 = nebbiaSmooth(nebbiaClamp(u * 1.4));
    final double e = 1 - math.pow(1 - u, 3).toDouble();
    final double kx = 0.7 + 0.3 * e;
    final double ky = 0.08 + 0.92 * e;
    final Color white = Color.lerp(fogTint, const Color(0xFFFFFFFF), 0.55)!;
    final double a = nebbiaClamp(NebbiaFixed.breathThick * fade * g0);
    for (final NebbiaLobe lb in b.lobes) {
      final Offset c = Offset(
        b.cx + (lb.x - b.cx) * kx,
        b.cy + (lb.y - b.cy) * ky,
      );
      final double rx = lb.rx * kx;
      final double ry = math.max(lb.ry * ky, 4);
      canvas
        ..save()
        ..translate(c.dx, c.dy)
        ..scale(rx, ry)
        ..drawCircle(
          Offset.zero,
          1,
          Paint()
            ..shader = ui.Gradient.radial(
              Offset.zero,
              1,
              <Color>[
                white.withValues(alpha: a * 0.8),
                white.withValues(alpha: a * 0.55),
                white.withValues(alpha: 0),
              ],
              <double>[0, 0.45 * fade + 0.2, 1],
            ),
        )
        ..restore();
    }
  }

  void _fieldDrops(
    Canvas canvas,
    NebbiaBumps bumps,
    double now,
    double bumpK,
    NebbiaDropLook look,
    List<_Trail> trails,
  ) {
    final NebbiaFieldDrops? field = controller.field;
    if (field == null) return;
    final double window = 3.4 + s.hold + s.refog + 3;
    for (final NebbiaFieldDrop d in field.drops) {
      double x = d.x;
      double y = d.y;
      double stretch = 0;
      double alpha = 1;
      final NebbiaFall? f = bumpK > 0
          ? field.fallOf(d, bumps, now, window, bumpK)
          : null;
      if (f != null && now >= f.t0) {
        final double u = nebbiaClamp((now - f.t0) / f.dur);
        y = d.y + f.len * nebbiaFallEase(u);
        x =
            d.x +
            math.sin(y * 0.07 + f.seed) * 1.4 +
            math.sin(y * 0.021 + f.seed * 2) * 2.2;
        stretch = 0.4 * (1 - math.cos(u * 6 * math.pi)) * (u < 1 ? 1 : 0);
        final double end = f.t0 + f.dur;
        final double v = now < end
            ? 1
            : 1 - nebbiaSmooth(nebbiaClamp((now - end - s.hold) / s.refog));
        if (v > 0.002) {
          trails.add(
            _Trail(Offset(d.x, d.y - d.h * 0.05), Offset(x, y), d.w * 0.18, v),
          );
        }
        // 淌完的水珠停在落点，回雾后在原处重新凝出来。
        if (v <= 0.002) {
          x = d.x;
          y = d.y;
          alpha = nebbiaSmooth(nebbiaClamp((now - end - s.hold - s.refog) / 3));
        }
      }
      final double wb = bumps.wobbleAt(now, bumpK, d.phase);
      look.draw(
        canvas,
        Offset(x, y),
        d.w / 8,
        alpha,
        sx: 1 + wb,
        sy: (1 - wb + stretch) * d.h / d.w,
      );
    }
  }

  /// 一句：慢慢起雾，或手指抹除（另画拖痕，拖过的地方字边水珠被带走）。
  void _drawLine(_Ink ink, NebbiaLaidLine line, int idx, double t) {
    final double refog = s.refog;
    const double beadHold = NebbiaFixed.beadHold;
    final double yf = nebbiaYieldFactor(line, t);
    final double ym = nebbiaYieldMask(line, t);
    final bool fingers =
        line.mode == NebbiaFade.fingers &&
        line.breathAt == double.infinity &&
        ink.motion;
    if (!fingers) {
      final double v =
          (1 - nebbiaSmooth(nebbiaClamp((t - line.fogAt) / refog))) * ym;
      final double vb =
          (1 -
              nebbiaSmooth(
                nebbiaClamp((t - line.fogAt - beadHold) / (refog * 3)),
              )) *
          yf;
      if (vb > 0.002 || v > 0.002) {
        for (final NebbiaLaidChar c in line.chars) {
          ink.drawChar(c, t, v, vb, null);
        }
      }
      return;
    }
    final NebbiaWipe? w = line.wipe(idx);
    if (w == null) return;
    final double early = line.yieldAt - w.dur - 0.9;
    final double t0 = line.fogAt > early && early >= line.end
        ? early
        : line.fogAt;
    final double ue = nebbiaClamp((t - t0) / w.dur);
    final double back =
        1 - nebbiaSmooth(nebbiaClamp((t - t0 - w.dur - 0.5) / refog));
    final double vw = back * ym;
    final double vs = back * yf;
    final double vbw =
        (1 -
            nebbiaSmooth(
              nebbiaClamp((t - t0 - w.dur - 0.5 - beadHold) / (refog * 3)),
            )) *
        yf;
    if (vbw <= 0.002 && vw <= 0.002) return;
    final double Function(Offset q)? alive = ue <= 0
        ? null
        : (Offset q) => nebbiaIsSwept(w, ue, q) ? 0.0 : 1.0;
    for (final NebbiaLaidChar c in line.chars) {
      ink.drawChar(c, t, ue <= 0 ? ym : vw, ue <= 0 ? yf : vbw, alive);
    }
    if (ue <= 0) return;
    if (vs > 0.002) {
      final Paint p = Paint()
        ..blendMode = BlendMode.dstOut
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = Color.fromRGBO(0, 0, 0, nebbiaClamp(vs));
      for (final NebbiaWipeStreak st in w.streaks) {
        final double lp = nebbiaStreakProgress(st, ue);
        if (lp <= 0) continue;
        final int n = st.pts.length - 1;
        final double f = lp * n;
        final int i = f.floor();
        final Path path = Path()..moveTo(st.pts.first.dx, st.pts.first.dy);
        for (int k = 1; k <= math.min(i, n); k++) {
          path.lineTo(st.pts[k].dx, st.pts[k].dy);
        }
        if (i < n) {
          final Offset a = st.pts[i];
          final Offset b = st.pts[i + 1];
          final Offset q = a + (b - a) * (f - i);
          path.lineTo(q.dx, q.dy);
        }
        ink.canvas.drawPath(path, p..strokeWidth = st.w);
      }
    }
    if (ue >= 1 && vbw > 0.002) {
      for (final ({Offset p, double r}) b in w.beads) {
        ink.drops.add(_Drop(b.p, b.r * (0.55 + 0.45 * vbw), vbw));
      }
    }
  }

  void _hits(_Ink ink, double t, Size size) {
    final double life = nebbiaHitLife(s.refog);
    final double fogT = s.refog * 0.3;
    final double sizeK = s.rainBig;
    final Paint clear = Paint()..blendMode = BlendMode.dstOut;
    void one(NebbiaHit hit, double k) {
      final double r = hit.r * k;
      final double age = t - hit.t;
      final double v = 1 - nebbiaSmooth(nebbiaClamp((age - 0.4) / fogT));
      final double bv =
          1 -
          nebbiaSmooth(
            nebbiaClamp((age - 0.4 - NebbiaFixed.beadHold * 0.5) / s.refog),
          );
      if (hit.big && v > 0.002) {
        ink.canvas.drawCircle(
          Offset(hit.x, hit.y),
          r * 0.95,
          clear
            ..color = Color.fromRGBO(0, 0, 0, nebbiaClamp(v))
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.2),
        );
      }
      if (bv > 0.01) {
        final double sq = math.exp(-age / 0.05);
        ink.drops.add(
          _Drop(
            Offset(hit.x, hit.y + r * 0.1),
            r * 0.9 * (0.6 + 0.4 * bv),
            bv,
            sx: 1 + 0.5 * sq,
            sy: 1 - 0.35 * sq,
          ),
        );
        for (final (double dx0, double dy0, double sr) in hit.sat) {
          final double out = nebbiaClamp(age / 0.08);
          ink.drops.add(
            _Drop(
              Offset(hit.x + dx0 * k * out, hit.y + dy0 * k * out),
              sr * (0.55 + 0.45 * bv),
              bv * out,
            ),
          );
        }
      }
    }

    if (sizeK > 0) {
      for (final NebbiaHit hit in controller.bigHits) {
        if (hit.t > t) break;
        if (hit.t < t - life || hit.r * sizeK < 1) continue;
        one(hit, sizeK);
      }
    }
    final LyricVisualizerRuntime rt = c.runtime;
    for (final NebbiaHit hit in nebbiaSmallHits(
      t,
      life,
      s.rainHit,
      (double at) => rt.pulseAt((at * 1000).round(), decayMs: 400),
      size.width,
      size.height,
      c.seed,
    )) {
      one(hit, 1);
    }
  }

  @override
  bool shouldRepaint(covariant NebbiaPainter old) =>
      old.c != c ||
      old.s != s ||
      old.controller != controller ||
      old.font != font;
}

class _Drop {
  _Drop(this.c, this.r, this.a, {this.sx = 1, this.sy = 1});
  final Offset c;
  final double r;
  final double a;
  final double sx;
  final double sy;
}

class _Trail {
  _Trail(this.a, this.b, this.w, this.v);
  final Offset a;
  final Offset b;
  final double w;
  final double v;
}

/// 在雾层上写字（dstOut 擦掉雾），水珠攒进 [drops]。
class _Ink {
  _Ink(
    this.canvas,
    this.s,
    this.controller,
    this.font,
    this.motion,
    this.drops,
  );
  final Canvas canvas;
  final NebbiaSettings s;
  final NebbiaController controller;
  final TextStyle font;
  final bool motion;
  final List<_Drop> drops;

  /// 某一笔在 [0, len] 上画到 l 的部分（屏幕坐标）。
  Path _partial(NebbiaLaidChar c, NebbiaStroke st, double l, Path into) {
    final Offset p0 = c.toScreen(st.pts.first.dx, st.pts.first.dy);
    into.moveTo(p0.dx, p0.dy);
    for (int i = 1; i < st.pts.length; i++) {
      if (st.cum[i] >= l) {
        final double k =
            (l - st.cum[i - 1]) / math.max(1e-6, st.cum[i] - st.cum[i - 1]);
        final Offset a = st.pts[i - 1];
        final Offset b = st.pts[i];
        final Offset q = c.toScreen(
          a.dx + (b.dx - a.dx) * k,
          a.dy + (b.dy - a.dy) * k,
        );
        into.lineTo(q.dx, q.dy);
        return into;
      }
      final Offset q = c.toScreen(st.pts[i].dx, st.pts[i].dy);
      into.lineTo(q.dx, q.dy);
    }
    return into;
  }

  /// 画一个字到时刻 t：从 wt 起用 wd 秒一笔一笔写完；clarity 管擦痕，beadV 管水珠；
  /// alive(q) 为 0 的地方水珠已经被手指抹走。慢慢显现的字一次画全，不带水珠。
  void drawChar(
    NebbiaLaidChar c,
    double t,
    double clarityIn,
    double beadIn,
    double Function(Offset q)? alive,
  ) {
    final NebbiaGlyph? g = c.glyph;
    final bool fadeIn = c.appearDur > 0 || !motion;
    if (g == null || t < (c.appearDur > 0 || !motion ? c.t : c.wt)) return;
    double clarity = clarityIn;
    double beadV = beadIn;
    if (c.appearDur > 0 && motion) {
      final double a = nebbiaSmooth(nebbiaClamp((t - c.t) / c.appearDur));
      clarity *= a;
      beadV *= a;
    }
    final double wd = c.wd;
    final double gap = math.min(0.06 / s.writeSpeed, wd * 0.08);
    final double inkTime = wd - gap * (g.strokes.length - 1);
    double local = t - (fadeIn ? c.t : c.wt);
    final double thin = nebbiaClamp(math.sqrt(9 / g.strokes.length), 0.55, 1);
    final double width = math.max(s.strokeWidth * thin, 1.2 / c.s);
    final Path inkPath = Path();
    final List<(NebbiaStroke, NebbiaDrip, double)> drips =
        <(NebbiaStroke, NebbiaDrip, double)>[];
    for (int si = 0; si < g.strokes.length; si++) {
      final NebbiaStroke st = g.strokes[si];
      final double dur = fadeIn ? 0 : inkTime * st.len / g.total;
      if (local <= 0) break;
      final double p = dur > 0 ? nebbiaClamp(local / dur) : 1;
      final double drawn = (p * 0.4 + nebbiaSmooth(p) * 0.6) * st.len;
      if (clarity > 0.002) _partial(c, st, drawn, inkPath);
      if (!fadeIn && beadV > 0.002) {
        for (final NebbiaBead b in c.beads[si]) {
          if (b.s > drawn) break;
          final double off = width / 2 + (b.r * 0.7 + b.j * 1.5) / c.s;
          final Offset q = c.toScreen(b.x + b.nx * off, b.y + b.ny * off);
          final double bv = alive != null ? beadV * alive(q) : beadV;
          if (bv <= 0.002) continue;
          drops.add(
            _Drop(
              q,
              b.r * (0.55 + 0.45 * bv),
              bv,
              sx: 1 + b.j * 0.25,
              sy: 1 + (1 - b.j) * 0.3,
            ),
          );
        }
        // 收笔水珠：笔尖推着走的水越堆越多；字太小不留。
        if (drawn > 0 && c.s >= NebbiaFixed.endBeadMin) {
          final ({double h, double j}) e = c.ends[si];
          final Offset u = nebbiaPointAt(st, drawn).p;
          final Offset v = nebbiaPointAt(st, math.max(0, drawn - 2 / c.s)).p;
          Offset d = u - v;
          final double dl = d.distance == 0 ? 1 : d.distance;
          d = d / dl;
          final double r =
              c.s *
              (0.031 + 0.018 * e.h) *
              NebbiaFixed.endBead *
              (0.5 + 0.5 * nebbiaSmooth(p));
          final Offset q = c.toScreen(
            u.dx + d.dx * r * 0.35 / c.s,
            u.dy + (d.dy * r * 0.35 + r * 0.15) / c.s,
          );
          final double ev = alive != null ? beadV * alive(q) : beadV;
          if (ev > 0.002) {
            drops.add(
              _Drop(q, r * (0.6 + 0.4 * ev), ev, sy: 1.12 + e.j * 0.12),
            );
          }
        }
        final NebbiaDrip? d = c.drips.length > si ? c.drips[si] : null;
        if (d != null && p >= 1 && local - dur > d.delay) {
          drips.add((st, d, local - dur - d.delay));
        }
      }
      local -= dur + (fadeIn ? 0 : gap);
    }
    if (clarity > 0.002) {
      if (g.sweep) {
        _sweepText(c, inkPath, clarity);
      } else {
        canvas.drawPath(
          inkPath,
          Paint()
            ..blendMode = BlendMode.dstOut
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = width * c.s
            ..color = Color.fromRGBO(0, 0, 0, nebbiaClamp(clarity))
            ..maskFilter = MaskFilter.blur(
              BlurStyle.normal,
              math.max(0.6, width * c.s * 0.1 * NebbiaFixed.edge),
            ),
        );
      }
    }
    for (final (NebbiaStroke st, NebbiaDrip d, double age) in drips) {
      _drip(c, st, d, age, width, clarity, beadV, alive);
    }
  }

  /// 扫笔字形：在雾上擦出真正的字（粗一点，像手指写的），只显出扫笔已经走过的部分。
  void _sweepText(NebbiaLaidChar c, Path sweep, double clarity) {
    final double fs = c.s * 0.78;
    final TextPainter fill = controller.textFor(c.ch, fs, font, null);
    final TextPainter edge = controller.textFor(
      c.ch,
      fs,
      font,
      s.strokeWidth * c.s * 0.45,
    );
    final double base = fill.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    final Rect bounds = Rect.fromCircle(center: Offset(c.x, c.y), radius: c.s);
    final bool wide = nebbiaIsWideGlyph(c.ch);
    // 外层按清晰度 dstOut 到雾上；里面先画扫笔走过的范围，再用 srcIn 合上真正的字，只剩两者的交集。
    canvas
      ..saveLayer(
        bounds,
        Paint()
          ..color = Color.fromRGBO(0, 0, 0, nebbiaClamp(clarity))
          ..blendMode = BlendMode.dstOut,
      )
      ..drawPath(
        sweep,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = c.s * (wide ? 0.36 : 1.1)
          ..color = const Color(0xFFFFFFFF),
      )
      ..saveLayer(bounds, Paint()..blendMode = BlendMode.srcIn)
      ..translate(c.x, c.y)
      ..rotate(c.rot)
      ..translate(-c.s / 2, -c.s / 2);
    final Offset at = Offset(c.s / 2 - fill.width / 2, c.s * 0.8 - base);
    fill.paint(canvas, at);
    edge.paint(canvas, at);
    canvas
      ..restore()
      ..restore();
  }

  /// 一颗往下淌的水珠：从笔画最低处出发，走走停停，越走越小，留下一道擦开的水痕。
  void _drip(
    NebbiaLaidChar c,
    NebbiaStroke st,
    NebbiaDrip d,
    double age,
    double width,
    double clarity,
    double beadV,
    double Function(Offset q)? alive,
  ) {
    double bx = 0;
    double by = -1e9;
    for (final Offset q in st.pts) {
      final Offset p = c.toScreen(q.dx, q.dy);
      if (p.dy > by) {
        bx = p.dx;
        by = p.dy;
      }
    }
    by += width * c.s * 0.35;
    final double u = nebbiaClamp(age / d.dur);
    final double dist = d.len * nebbiaFallEase(u);
    final double r = d.r * (1 - 0.35 * u);
    double wob(double y) =>
        math.sin(y * 0.07 + d.seed) * 1.6 +
        math.sin(y * 0.023 + d.seed * 2) * 2.5;
    if (dist > 1 && clarity > 0.002) {
      final Path trail = Path()..moveTo(bx + wob(0), by);
      for (double y = 4; y < dist; y += 4) {
        trail.lineTo(bx + wob(y), by + y);
      }
      trail.lineTo(bx + wob(dist), by + dist);
      canvas.drawPath(
        trail,
        Paint()
          ..blendMode = BlendMode.dstOut
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = r * 1.5 * 0.85
          ..color = Color.fromRGBO(0, 0, 0, nebbiaClamp(clarity * 0.95)),
      );
    }
    if (beadV <= 0.002) return;
    final double speed = 1 - math.cos(u * 6 * math.pi);
    for (
      double y = 14 + (d.seed % 7) * 2;
      y < dist - r * 2;
      y += 18 + ((y * 7 + d.seed * 13) % 11)
    ) {
      final Offset q = Offset(bx + wob(y), by + y);
      final double v = alive != null ? beadV * alive(q) : beadV;
      if (v > 0.002) {
        drops.add(_Drop(q, r * (0.3 + 0.2 * (((y + d.seed) * 0.37) % 1)), v));
      }
    }
    final Offset e = Offset(bx + wob(dist), by + dist + r * 0.3);
    final double ev = alive != null ? beadV * alive(e) : beadV;
    if (ev > 0.002) {
      drops.add(_Drop(e, r, ev, sy: 1 + 0.35 * speed * (u < 1 ? 1 : 0)));
    }
  }
}
