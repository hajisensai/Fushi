/// 雾笺的窗外（folia `nebbiaSceneGlsl.ts` / `nebbiaAquaGlsl.ts` / `nebbiaJellies.ts` / `nebbiaSnowFall.ts`
/// / `nebbiaPalette.ts` 的 Canvas 版）：公交车侧窗外的雨夜街景（远近两层楼群、主题色霓虹散景、路灯招牌、
/// 湿路面倒影、车灯、聚光灯光柱里的雨），或水族箱「梦海流萤」（水、光束、沙底焦散、礁石水草和荧光粒子、
/// 水母、气泡）。坐标单位和 folia 一样按屏高（q = 像素 / H），HZ = 0.6 是楼底，ROAD = 0.7 是路面。
/// 这里只画清晰的一版；雾后面的模糊版由 nebbia_painter.dart 把同一张 Picture 套高斯模糊再画一遍。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_layout.dart'
    show nebbiaClamp;
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_tuning.dart';

const double _hz = 0.6;
const double _road = 0.7;
const double _wind = 0.6;
const Color _sodium = Color.fromARGB(255, 255, 173, 82);

/// folia 着色器的格子伪随机数（Dave Hoskins hash11）。
double nebbiaH1(double n) {
  double x = n * 0.1031;
  x -= x.floorToDouble();
  x *= x + 33.33;
  x *= x + x;
  return x - x.floorToDouble();
}

/// 连续种子 → 0..1 的伪随机数（sin 哈希）。nebbiaH1 是给整数格子编号用的，种子是 i × 小数倍时
/// 相邻的值会排成一行，雪、冷凝水珠、水母这些按序号散开的用这个。
double nebbiaRand(double n) {
  final double x = math.sin(n * 12.9898 + 78.233) * 43758.5453;
  return x - x.floorToDouble();
}

/// 窗外配色：天色两档（主题背景压成夜色），三个灯光色（强调色打头，是聚光灯和霓虹的颜色）。
@immutable
class NebbiaColors {
  const NebbiaColors(
    this.sky0,
    this.sky1,
    this.la,
    this.lb,
    this.lc,
    this.dark,
  );

  factory NebbiaColors.from(LyricVisualizerPalette p) {
    Color asLight(Color c) {
      final HSLColor h = HSLColor.fromColor(c);
      return h
          .withSaturation(math.max(0.55, h.saturation))
          .withLightness(nebbiaClamp(h.lightness, 0.6, 0.78))
          .toColor();
    }

    Color asSky(Color c, double l) {
      final HSLColor h = HSLColor.fromColor(c);
      return h
          .withSaturation(math.min(0.55, h.saturation))
          .withLightness(l)
          .toColor();
    }

    bool vivid(Color c) {
      final HSLColor h = HSLColor.fromColor(c);
      return h.saturation > 0.3 && h.lightness > 0.25 && h.lightness < 0.9;
    }

    final Color accent = p.accent;
    final HSLColor ah = HSLColor.fromColor(accent);
    final List<Color> vs = <Color>[
      p.secondary,
      p.primary,
    ].where(vivid).toList();
    final Color lb = vs.isNotEmpty
        ? vs[0]
        : ah.withHue((ah.hue + 198) % 360).toColor();
    final Color lc = vs.length > 1
        ? vs[1]
        : ah.withHue((ah.hue + 324) % 360).toColor();
    return NebbiaColors(
      asSky(p.background, 0.05),
      asSky(Color.lerp(p.background, accent, 0.3)!, 0.14),
      asLight(accent),
      asLight(lb),
      asLight(lc),
      p.brightness == Brightness.dark,
    );
  }

  final Color sky0;
  final Color sky1;
  final Color la;
  final Color lb;
  final Color lc;

  /// 主题是夜间（共用背景时雾是深色的）。
  final bool dark;

  Color pick(double h) => h < 0.34 ? la : (h < 0.67 ? lb : lc);

  @override
  bool operator ==(Object other) =>
      other is NebbiaColors &&
      other.sky0 == sky0 &&
      other.sky1 == sky1 &&
      other.la == la &&
      other.lb == lb &&
      other.lc == lc &&
      other.dark == dark;

  @override
  int get hashCode => Object.hash(sky0, sky1, la, lb, lc, dark);
}

/// 两盏聚光灯的这一帧：光斑中心、半径（像素）、强度。
@immutable
class NebbiaSpotFrame {
  const NebbiaSpotFrame(this.target, this.radius, this.intensity);
  final Offset target;
  final double radius;
  final double intensity;
}

/// 画一个光点：高斯模糊的圆（或横向拖影的椭圆），加色混合。
void nebbiaGlow(
  Canvas canvas,
  Offset c,
  double r,
  Color color,
  double k, {
  double streak = 0,
  double stretchY = 1,
}) {
  if (k <= 0.004 || r <= 0.2) return;
  final Paint p = Paint()
    ..blendMode = BlendMode.plus
    ..color = color.withValues(alpha: nebbiaClamp(k * 0.85))
    ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.7);
  canvas.drawOval(
    Rect.fromCenter(
      center: c,
      width: 2 * (r + streak),
      height: 2 * r * stretchY,
    ),
    p,
  );
  if (k > 1.2) {
    // 亮核：比光晕小、偏白。
    canvas.drawOval(
      Rect.fromCenter(center: c, width: r + 2 * streak, height: r * stretchY),
      Paint()
        ..blendMode = BlendMode.plus
        ..color = Color.lerp(
          color,
          const Color(0xFFFFFFFF),
          0.5,
        )!.withValues(alpha: nebbiaClamp((k - 1.2) * 0.5))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.35),
    );
  }
}

/// 窗外的画家。楼群每栋录成一张 Picture 缓存（窗格多，逐帧画太费），尺寸 / 配色变了清掉。
class NebbiaWindow {
  final Map<int, ui.Picture> _buildings = <int, ui.Picture>{};
  double _cacheH = -1;
  NebbiaColors? _cacheColors;

  void dispose() {
    for (final ui.Picture p in _buildings.values) {
      p.dispose();
    }
    _buildings.clear();
  }

  /// 画整扇窗外。[time] 是窗外时钟（秒），[shake] 是车身颠簸的位移。
  void paint(
    Canvas canvas,
    Size size,
    double time,
    NebbiaSettings s,
    NebbiaColors colors,
    NebbiaSpotFrame spot, {
    required bool snowing,
  }) {
    if (_cacheH != size.height || _cacheColors != colors) {
      dispose();
      _cacheH = size.height;
      _cacheColors = colors;
    }
    if (s.behind == NebbiaBehind.aquarium) {
      _aquarium(canvas, size, time, s, colors, spot);
    } else {
      _night(canvas, size, time, s, colors, spot, snowing: snowing);
    }
  }

  // ---------------------------------------------------------------------------
  // 雨夜街景
  // ---------------------------------------------------------------------------

  void _night(
    Canvas canvas,
    Size size,
    double time,
    NebbiaSettings s,
    NebbiaColors colors,
    NebbiaSpotFrame spot, {
    required bool snowing,
  }) {
    final double h = size.height;
    final double w = size.width;
    final double t = time * s.busSpeed;
    final Rect full = Offset.zero & size;
    canvas.drawRect(
      full,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, h * _hz), <Color>[
          colors.sky0,
          colors.sky1,
        ]),
    );
    // 天边一层主题色和钠灯的辉光。
    canvas.drawRect(
      Rect.fromLTWH(0, h * (_hz - 0.3), w, h * 0.5),
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.linear(
          Offset(0, h * (_hz - 0.3)),
          Offset(0, h * (_hz + 0.2)),
          <Color>[
            const Color(0x00000000),
            Color.lerp(colors.la, _sodium, 0.4)!.withValues(alpha: 0.16),
            const Color(0x00000000),
          ],
          <double>[0, 0.6, 1],
        ),
    );
    if (s.sceneryOn('buildings')) {
      _buildingLayer(canvas, size, t, 0, colors);
      _buildingLayer(canvas, size, t, 1, colors);
    }
    final bool lights = s.sceneryOn('lights');
    if (lights) {
      _neon(canvas, size, t, s.neon, colors, reflect: false);
      canvas.drawRect(
        Rect.fromLTWH(0, h * (_hz - 0.35), w, h * 0.5),
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.linear(
            Offset(0, h * (_hz - 0.35)),
            Offset(0, h * (_hz + 0.15)),
            <Color>[
              const Color(0x00000000),
              colors.la.withValues(alpha: nebbiaClamp(0.12 * s.neon)),
              const Color(0x00000000),
            ],
            <double>[0, 0.75, 1],
          ),
      );
      _lampsSigns(canvas, size, t, s.busSpeed, colors, reflect: false);
    }
    final bool road = s.sceneryOn('road');
    if (road) {
      canvas.drawRect(
        Rect.fromLTRB(0, h * _road, w, h),
        Paint()
          ..color = Color.lerp(
            colors.sky0,
            const Color(0xFF000000),
            0.5,
          )!.withValues(alpha: 0.85),
      );
      if (lights) {
        canvas
          ..save()
          ..clipRect(Rect.fromLTRB(0, h * _road, w, h));
        _lampsSigns(canvas, size, t, s.busSpeed, colors, reflect: true);
        _neon(canvas, size, t, s.neon, colors, reflect: true);
        canvas.restore();
      }
    }
    if (s.sceneryOn('cars')) _cars(canvas, size, t, s.busSpeed, road);
    if (snowing) {
      _snowFall(canvas, size, time, s.busSpeed, aquarium: false);
    }
    // 聚光灯光柱，和光柱里被照亮的雨丝。
    final Offset src1 = Offset(s.spotX * w, h * 0.595);
    final Offset src2 = Offset((1 - s.spotX) * w, h * 0.595);
    _spotBeams(canvas, size, src1, src2, spot, colors);
    if (s.rain != NebbiaRain.off && !snowing && spot.intensity > 0.01) {
      _rainInBeams(canvas, size, time, s, src1, src2, spot, colors);
    }
  }

  void _buildingLayer(
    Canvas canvas,
    Size size,
    double t,
    int layer,
    NebbiaColors colors,
  ) {
    final double h = size.height;
    final double near = layer.toDouble();
    final double speed = near == 0 ? 0.02 : 0.035;
    final double shift = t * speed + layer * 7.7;
    final double cw = near == 0 ? 0.065 : 0.12;
    final double xw = size.width / h;
    final int c0 = (shift / cw).floor() - 1;
    final int c1 = ((xw + shift) / cw).floor() + 1;
    for (int c = c0; c <= c1; c++) {
      final double n = c + layer * 100.0;
      final double bw = cw * (0.72 + 0.26 * nebbiaH1(n));
      final double left = c * cw + (cw - bw) * nebbiaH1(n + 1);
      final int key = c * 2 + layer;
      final ui.Picture pic = _buildings[key] ??= _recordBuilding(
        n,
        bw,
        near,
        h,
        colors,
      );
      canvas
        ..save()
        ..translate((left - shift) * h, 0)
        ..drawPicture(pic)
        ..restore();
    }
    if (_buildings.length > 400) dispose();
  }

  /// 一栋楼：立面（下亮上暗、左侧边光）、收分顶层、天线、窗格（暖白 / 冷白 / 主题色，有的整层全黑）。
  ui.Picture _recordBuilding(
    double n,
    double bw,
    double near,
    double h,
    NebbiaColors colors,
  ) {
    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas c = Canvas(rec);
    final double hgt =
        (near == 0 ? 0.07 : 0.11) +
        (near == 0 ? 0.16 : 0.27) * math.pow(nebbiaH1(n + 2), 1.5);
    final double base = _hz + near * 0.015;
    final double top = base - hgt;
    final bool tier = nebbiaH1(n + 3) < 0.5;
    final double tw = bw * (0.5 + 0.25 * nebbiaH1(n + 4));
    final double tl = (bw - tw) * 0.5;
    final double th = hgt * (0.12 + 0.15 * nebbiaH1(n + 5));
    final double roof = tier ? top - th : top;
    final Color skyMix = Color.lerp(colors.sky0, colors.sky1, 0.7)!;
    Color fade(Color col) => Color.lerp(col, skyMix, near == 0 ? 0.45 : 0.12)!;
    final Color fac = fade(
      Color.lerp(
        colors.sky0,
        const Color(0xFF04050A),
        0.55,
      )!.withValues(alpha: 1),
    );
    final double k = 0.7 + 0.6 * nebbiaH1(n + 8);
    final Color facade = Color.fromARGB(
      255,
      (fac.r * 255 * k).clamp(0, 255).round(),
      (fac.g * 255 * k).clamp(0, 255).round(),
      (fac.b * 255 * k).clamp(0, 255).round(),
    );
    final Paint body = Paint()..color = facade;
    c.drawRect(Rect.fromLTRB(0, top * h, bw * h, base * h), body);
    if (tier) {
      c.drawRect(
        Rect.fromLTRB(tl * h, (top - th) * h, (tl + tw) * h, top * h),
        body,
      );
    }
    if (nebbiaH1(n + 6) < 0.3) {
      c.drawRect(
        Rect.fromLTRB(
          bw * 0.5 * h - 0.6,
          (roof - 0.04 - 0.03 * nebbiaH1(n + 7)) * h,
          bw * 0.5 * h + 0.6,
          roof * h,
        ),
        body,
      );
    }
    // 越往下越被街面的灯照亮。
    c.drawRect(
      Rect.fromLTRB(0, roof * h, bw * h, base * h),
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.linear(
          Offset(0, roof * h),
          Offset(0, base * h),
          <Color>[
            const Color(0x00000000),
            fade(Color.lerp(_sodium, colors.la, 0.5)!).withValues(alpha: 0.1),
          ],
        ),
    );
    // 左侧一道细边光。
    c.drawRect(
      Rect.fromLTRB(0, top * h, 0.003 * h, base * h),
      Paint()
        ..blendMode = BlendMode.plus
        ..color = Color.lerp(
          colors.sky1,
          colors.lb,
          0.3,
        )!.withValues(alpha: 0.12),
    );
    final double fh = (near == 0 ? 0.0075 : 0.012) * h;
    final double wc = (near == 0 ? 0.0055 : 0.0085) * h;
    final double dens = 0.15 + 0.5 * nebbiaH1(n + 9);
    final double x0 = wc * 0.6;
    final double x1 = bw * h - wc * 0.6;
    final double y0 = roof * h + fh * 0.8;
    final double y1 = base * h - fh;
    final math.Random rnd = math.Random((n * 977).round());
    for (int row = 0; y0 + row * fh < y1; row++) {
      final double wy = y0 + row * fh;
      if (rnd.nextDouble() < 0.18) continue;
      for (int col = 0; x0 + col * wc < x1; col++) {
        final double wx = x0 + col * wc;
        // 收分顶层以外的上半段不开窗。
        if (wy < top * h && (wx < tl * h || wx > (tl + tw) * h)) continue;
        if (rnd.nextDouble() > dens) continue;
        final double hc = rnd.nextDouble();
        final Color wcol = hc < 0.5
            ? const Color(0xFFFFC780)
            : (hc < 0.8
                  ? const Color(0xFFC7E0FF)
                  : colors.pick(rnd.nextDouble()));
        final double lum =
            (0.55 + 0.6 * rnd.nextDouble()) * (near == 0 ? 0.7 : 1);
        c.drawRect(
          Rect.fromLTWH(wx + wc * 0.18, wy + fh * 0.2, wc * 0.64, fh * 0.6),
          Paint()..color = fade(wcol).withValues(alpha: nebbiaClamp(lum)),
        );
      }
    }
    return rec.endRecording();
  }

  /// 主题色霓虹：楼群之间密密的彩色小散景，偶尔一大团带一圈很大的光晕。[reflect] 时压扁倒在湿路面上。
  void _neon(
    Canvas canvas,
    Size size,
    double t,
    double neon,
    NebbiaColors colors, {
    required bool reflect,
  }) {
    if (neon <= 0) return;
    final double h = size.height;
    final double xw = size.width / h;
    double yOf(double y) => reflect ? _road + (_hz - y) / 0.22 : y;
    for (int row = 0; row < 2; row++) {
      final double shift = t * (0.06 + row * 0.03) + row * 7.3;
      final double cw = 0.045 - row * 0.012;
      final int c0 = (shift / cw).floor() - 1;
      final int c1 = ((xw + shift) / cw).floor() + 1;
      for (int c = c0; c <= c1; c++) {
        final double n = c + row * 300.0;
        if (nebbiaH1(n + 11) > 0.85) continue;
        final double cx = (c + 0.15 + 0.7 * nebbiaH1(n)) * cw - shift;
        final double cy = _hz - 0.02 - 0.2 * math.pow(nebbiaH1(n + 3), 1.6);
        final double r = 0.004 + 0.008 * math.pow(nebbiaH1(n + 6), 3);
        final double k =
            (1 + 1.8 * nebbiaH1(n + 13)) * neon * (reflect ? 0.45 : 1);
        nebbiaGlow(
          canvas,
          Offset(cx * h, yOf(cy) * h),
          (r + 0.003) * h,
          colors.pick(nebbiaH1(n + 9)),
          k * 0.8,
          stretchY: reflect ? 4.5 : 1,
        );
      }
    }
    final double shift = t * 0.1;
    const double bw = 0.75;
    final int c0 = (shift / bw).floor() - 1;
    final int c1 = ((xw + shift) / bw).floor() + 1;
    for (int c = c0; c <= c1; c++) {
      final double n = c + 500.0;
      final double cx = (c + 0.2 + 0.6 * nebbiaH1(n)) * bw - shift;
      final double cy = _hz - 0.08 - 0.12 * nebbiaH1(n + 2);
      final Color lc = colors.pick(nebbiaH1(n + 4));
      final double k = neon * (reflect ? 0.45 : 1);
      final double sy = reflect ? 4.5 : 1;
      nebbiaGlow(
        canvas,
        Offset(cx * h, yOf(cy) * h),
        0.017 * h,
        lc,
        2.0 * k,
        stretchY: sy,
      );
      nebbiaGlow(
        canvas,
        Offset(cx * h, yOf(cy) * h),
        0.13 * h,
        lc,
        0.4 * k,
        stretchY: reflect ? 1.5 : 1,
      );
    }
  }

  /// 路灯（中景，灯头 + 雨里的大光晕）和招牌、店面（近，移动快，带横向拖影）。
  void _lampsSigns(
    Canvas canvas,
    Size size,
    double t,
    double bus,
    NebbiaColors colors, {
    required bool reflect,
  }) {
    final double h = size.height;
    final double xw = size.width / h;
    double yOf(double y) => reflect ? _road + (_road - y) / 0.55 : y;
    final double k = reflect ? 0.35 : 1;
    final double sy = reflect ? 2.2 : 1;
    {
      final double shift = t * 0.42;
      const double cw = 0.34;
      final double streak = 0.012 * bus * h;
      final int c0 = (shift / cw).floor() - 1;
      final int c1 = ((xw + shift) / cw).floor() + 1;
      for (int c = c0; c <= c1; c++) {
        final double n = c.toDouble();
        if (nebbiaH1(n + 33) < 0.75) {
          final double cx = (n + 0.2 + 0.6 * nebbiaH1(n)) * cw - shift;
          final double cy = 0.46 + 0.1 * nebbiaH1(n + 17);
          nebbiaGlow(
            canvas,
            Offset(cx * h, yOf(cy) * h),
            (0.008 + 0.01 * nebbiaH1(n + 5)) * h,
            colors.pick(nebbiaH1(n + 2)),
            1.6 * k,
            streak: streak,
            stretchY: sy,
          );
        }
        if (nebbiaH1(n + 41) < 0.6) {
          final double cx = (n + 0.5) * cw - shift;
          nebbiaGlow(
            canvas,
            Offset(cx * h, yOf(0.645) * h),
            (0.019 + 0.01 * nebbiaH1(n + 3)) * h,
            Color.lerp(_sodium, colors.pick(nebbiaH1(n + 8)), 0.3)!,
            0.9 * k,
            streak: streak,
            stretchY: sy,
          );
        }
      }
    }
    final double shift = t * 0.22;
    const double lw = 0.55;
    final int c0 = (shift / lw).floor() - 1;
    final int c1 = ((xw + shift) / lw).floor() + 1;
    for (int c = c0; c <= c1; c++) {
      final double cx = (c + 0.5) * lw - shift;
      final Offset p = Offset(cx * h, yOf(0.36) * h);
      nebbiaGlow(
        canvas,
        p,
        0.009 * h,
        _sodium,
        2.6 * k,
        streak: 0.004 * bus * h,
        stretchY: sy,
      );
      nebbiaGlow(canvas, p, 0.07 * h, _sodium, 0.3 * k, stretchY: sy);
    }
  }

  /// 车灯：同向车道尾灯（红），对向车道前灯（白），快速掠过拖出长影；路面上有倒影。
  void _cars(Canvas canvas, Size size, double t, double bus, bool road) {
    final double h = size.height;
    final double xw = size.width / h;
    for (int lane = 0; lane < 2; lane++) {
      final double sp = lane == 0 ? 0.55 : -1.1;
      final double ly = lane == 0 ? 0.76 : 0.83;
      const double ww = 0.9;
      final Color lc = lane == 0
          ? const Color(0xFFFF2E1F)
          : const Color(0xFFFFF2D9);
      final double shift = t * sp;
      final int c0 = (shift / ww).floor() - 1;
      final int c1 = ((xw + shift) / ww).floor() + 1;
      for (int c = c0; c <= c1; c++) {
        final double n = c + lane * 50.0;
        if (nebbiaH1(n) > 0.6) continue;
        final double cx = (c + 0.2 + 0.6 * nebbiaH1(n + 4)) * ww - shift;
        final double st = sp.abs() * 0.03 * bus * h;
        nebbiaGlow(
          canvas,
          Offset((cx - 0.035) * h, ly * h),
          0.005 * h,
          lc,
          2.2,
          streak: st,
        );
        nebbiaGlow(
          canvas,
          Offset((cx + 0.035) * h, ly * h),
          0.005 * h,
          lc,
          2.2,
          streak: st,
        );
        if (road) {
          nebbiaGlow(
            canvas,
            Offset(cx * h, (ly + 0.01) * h),
            0.02 * h,
            lc,
            0.3,
            streak: st,
            stretchY: 0.35,
          );
        }
      }
    }
  }

  /// 聚光灯光柱：从楼底的光源射向玻璃上的光斑，越近越宽越亮；光源本身是一颗很亮的灯。
  void _spotBeams(
    Canvas canvas,
    Size size,
    Offset a,
    Offset b,
    NebbiaSpotFrame spot,
    NebbiaColors colors,
  ) {
    if (spot.intensity <= 0.01) return;
    for (final Offset src in <Offset>[a, b]) {
      final Path beam = nebbiaBeamPath(src, spot.target, spot.radius);
      canvas.drawPath(
        beam,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.linear(src, spot.target, <Color>[
            colors.la.withValues(alpha: 0),
            colors.la.withValues(alpha: nebbiaClamp(0.55 * spot.intensity)),
          ])
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            spot.radius * 0.25 + 2,
          ),
      );
      nebbiaGlow(
        canvas,
        src,
        size.height * 0.006,
        Color.lerp(colors.la, const Color(0xFFFFFFFF), 0.5)!,
        2.5 * spot.intensity,
      );
    }
  }

  /// 窗外的雨：相对车身往下落 + 往后（车越快越斜）；只在聚光灯光柱里画（被照亮的那些）。
  void _rainInBeams(
    Canvas canvas,
    Size size,
    double time,
    NebbiaSettings s,
    Offset src1,
    Offset src2,
    NebbiaSpotFrame spot,
    NebbiaColors colors,
  ) {
    final double h = size.height;
    final Path clip = nebbiaBeamPath(src1, spot.target, spot.radius)
      ..addPath(nebbiaBeamPath(src2, spot.target, spot.radius), Offset.zero);
    final Rect bounds = clip.getBounds();
    // 雨的方向（屏高单位）：往下 1，往后 -WIND × 车速。
    final double dxPerDy = s.rain == NebbiaRain.slant ? -_wind * s.busSpeed : 0;
    final double len = math.sqrt(1 + dxPerDy * dxPerDy);
    final Offset dir = Offset(dxPerDy / len, 1 / len);
    final Offset perp = Offset(-dir.dy, dir.dx);
    final Path rain = Path();
    const double spacing = 0.007;
    // 投到垂直于雨的轴上，覆盖光柱的范围。
    final List<Offset> corners = <Offset>[
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomLeft,
      bounds.bottomRight,
    ];
    double pmin = double.infinity;
    double pmax = -double.infinity;
    double amin = double.infinity;
    double amax = -double.infinity;
    for (final Offset c in corners) {
      final double pp = (c.dx * perp.dx + c.dy * perp.dy) / h;
      final double aa = (c.dx * dir.dx + c.dy * dir.dy) / h;
      pmin = math.min(pmin, pp);
      pmax = math.max(pmax, pp);
      amin = math.min(amin, aa);
      amax = math.max(amax, aa);
    }
    for (
      int col = (pmin / spacing).floor();
      col <= (pmax / spacing).ceil();
      col++
    ) {
      final double hr = nebbiaH1(col.toDouble());
      if (hr < 0.3) continue;
      final double freq = 1.5 + hr;
      final double phase =
          time * (2.5 + hr * 2) * (1 + 0.4 * s.busSpeed) - hr * 10;
      // seg = fract(a × freq − phase)，亮在 0.1..0.3 那一段。
      final double first = ((amin * freq - phase).floorToDouble());
      for (double k = first; (k + phase) / freq <= amax; k++) {
        final double a0 = (k + 0.1 + phase) / freq;
        final double a1 = (k + 0.3 + phase) / freq;
        final double pp = (col + 0.5) * spacing;
        final Offset p0 = (perp * pp + dir * a0) * h;
        final Offset p1 = (perp * pp + dir * a1) * h;
        rain
          ..moveTo(p0.dx, p0.dy)
          ..lineTo(p1.dx, p1.dy);
      }
    }
    canvas
      ..save()
      ..clipPath(clip);
    canvas.drawPath(
      rain,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.8, h * 0.0012)
        ..blendMode = BlendMode.plus
        ..color = Color.lerp(
          colors.la,
          const Color(0xFFFFFFFF),
          0.5,
        )!.withValues(alpha: nebbiaClamp(0.6 * spot.intensity)),
    );
    canvas.restore();
  }

  /// 窗外在下雪：远、中两层往下落，跟着车速往后斜、轻轻晃。
  void _snowFall(
    Canvas canvas,
    Size size,
    double time,
    double bus, {
    required bool aquarium,
  }) {
    final double h = size.height;
    final double w = size.width;
    for (int layer = 0; layer < 2; layer++) {
      final int count = (w * h / (layer == 0 ? 2600 : 6000)).round();
      final double speed = layer == 0 ? 0.05 : 0.11;
      final double r = (layer == 0 ? 0.0016 : 0.0032) * h;
      final Paint p = Paint()
        ..color = Color.fromARGB(layer == 0 ? 110 : 170, 235, 240, 250)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.6);
      final List<Offset> pts = <Offset>[];
      for (int i = 0; i < count; i++) {
        final double hx = nebbiaRand(i * 7.13 + layer * 91);
        final double hy = nebbiaRand(i * 3.71 + layer * 53);
        final double fall = time * speed * (0.8 + 0.4 * nebbiaRand(i + 9.0));
        final double y = (hy + fall) % 1.0;
        final double drift = aquarium ? 0 : -_wind * bus * fall * 0.6;
        double x = (hx + drift * h / w + 0.01 * math.sin(time * 0.8 + i)) % 1.0;
        if (x < 0) x += 1;
        pts.add(Offset(x * w, y * h * 1.02 - 0.01 * h));
      }
      canvas.drawPoints(
        ui.PointMode.points,
        pts,
        p
          ..strokeWidth = r * 2
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 水族箱「梦海流萤」
  // ---------------------------------------------------------------------------

  void _aquarium(
    Canvas canvas,
    Size size,
    double time,
    NebbiaSettings s,
    NebbiaColors colors,
    NebbiaSpotFrame spot,
  ) {
    final double h = size.height;
    final double w = size.width;
    final Color deep = Color.lerp(colors.sky0, const Color(0xFF02101A), 0.4)!;
    final Color shallow = Color.lerp(
      Color.lerp(colors.sky1, const Color(0xFF0E4A63), 0.55)!,
      colors.la,
      0.12,
    )!;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, h), <Color>[
          shallow,
          deep,
        ]),
    );
    // 水面照下来的光束：几道斜的、慢慢摆。
    for (int i = 0; i < 6; i++) {
      final double x =
          (nebbiaH1(i + 3.0) * 1.2 - 0.1) * w +
          math.sin(time * 0.15 + i * 1.7) * 0.04 * w;
      final double bw = (0.04 + 0.06 * nebbiaH1(i + 9.0)) * w;
      final Path p = Path()
        ..moveTo(x - bw * 0.3, -10)
        ..lineTo(x + bw * 0.3, -10)
        ..lineTo(x + bw + 0.15 * w, h * 0.85)
        ..lineTo(x - bw + 0.15 * w, h * 0.85)
        ..close();
      canvas.drawPath(
        p,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader =
              ui.Gradient.linear(Offset(x, 0), Offset(x, h * 0.85), <Color>[
                const Color(
                  0xFFBFE8FF,
                ).withValues(alpha: 0.09 + 0.05 * math.sin(time * 0.4 + i)),
                const Color(0x00000000),
              ])
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, bw * 0.3),
      );
    }
    final double sandY = h * 0.86;
    if (s.sceneryOn('road')) {
      final Color sand = Color.lerp(deep, const Color(0xFF8C7A5A), 0.35)!;
      canvas.drawRect(
        Rect.fromLTRB(0, sandY, w, h),
        Paint()
          ..shader = ui.Gradient.linear(Offset(0, sandY), Offset(0, h), <Color>[
            sand,
            Color.lerp(sand, deep, 0.5)!,
          ]),
      );
      // 焦散：沙上几道晃动的亮纹。
      final Path caustic = Path();
      for (int k = 0; k < 7; k++) {
        final double y0 = sandY + (k + 0.5) / 7 * (h - sandY);
        caustic.moveTo(0, y0);
        for (double x = 0; x <= w; x += 18) {
          caustic.lineTo(
            x,
            y0 +
                math.sin(x * 0.03 + time * 0.9 + k * 1.3) * 3 +
                math.sin(x * 0.011 - time * 0.6 + k) * 4,
          );
        }
      }
      canvas.drawPath(
        caustic,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..blendMode = BlendMode.plus
          ..color = const Color(0xFFCFF2FF).withValues(alpha: 0.12),
      );
    }
    final bool lights = s.sceneryOn('lights');
    if (s.sceneryOn('buildings')) {
      // 礁石：底下一排暗色的团块，慢慢往后退。
      final double shift = time * s.busSpeed * 0.01 * h;
      final Paint rock = Paint()
        ..color = Color.lerp(deep, const Color(0xFF000000), 0.35)!;
      const double cell = 0.22;
      final int c0 = (shift / (cell * h)).floor() - 1;
      final int c1 = ((w + shift) / (cell * h)).floor() + 1;
      for (int c = c0; c <= c1; c++) {
        final double cx = (c + 0.5) * cell * h - shift;
        final double rw = (0.08 + 0.1 * nebbiaH1(c + 70.0)) * h;
        final double rh = (0.05 + 0.08 * nebbiaH1(c + 71.0)) * h;
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(cx, sandY + rh * 0.3),
            width: rw * 2,
            height: rh * 2,
          ),
          rock,
        );
        // 水草：从礁石上长出来，根不动、梢晃。
        final int weeds = 2 + (nebbiaH1(c + 72.0) * 3).floor();
        for (int k = 0; k < weeds; k++) {
          final double bx = cx + (nebbiaH1(c * 3.1 + k) - 0.5) * rw * 1.4;
          final double len = (0.12 + 0.18 * nebbiaH1(c * 5.3 + k)) * h;
          final Path weed = Path()..moveTo(bx, sandY);
          Offset tip = Offset(bx, sandY);
          for (int j = 1; j <= 8; j++) {
            final double f = j / 8;
            final double sway =
                math.sin(time * 0.9 + c * 1.3 + k * 2.1 - f * 1.5) *
                0.05 *
                h *
                f *
                f;
            tip = Offset(bx + sway, sandY - len * f);
            weed.lineTo(tip.dx, tip.dy);
          }
          canvas.drawPath(
            weed,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeWidth = (0.006 + 0.004 * nebbiaH1(c + k * 1.0)) * h
              ..color = Color.lerp(const Color(0xFF0D3B2E), colors.lb, 0.15)!,
          );
          if (lights) {
            // 水草上一串串荧光粒子。
            for (int g = 0; g < 4; g++) {
              final double f = 0.55 + g * 0.13;
              final double sway =
                  math.sin(time * 0.9 + c * 1.3 + k * 2.1 - f * 1.5) *
                  0.05 *
                  h *
                  f *
                  f;
              final double pulse =
                  0.6 + 0.4 * math.sin(time * 1.7 + g + k * 3.0 + c);
              nebbiaGlow(
                canvas,
                Offset(bx + sway + 4, sandY - len * f),
                0.006 * h,
                colors.pick(nebbiaH1(c * 7.0 + k + g)),
                1.4 * pulse * s.neon,
              );
            }
          }
        }
      }
    }
    _jellies(canvas, size, time, s, colors);
    _bubbles(canvas, size, time, s, sandY);
    _spotBeams(
      canvas,
      size,
      Offset(s.spotX * w, -0.04 * h),
      Offset((1 - s.spotX) * w, -0.04 * h),
      spot,
      colors,
    );
  }

  static const List<Color> _vivid = <Color>[
    Color.fromARGB(255, 255, 89, 184),
    Color.fromARGB(255, 89, 204, 255),
    Color.fromARGB(255, 184, 128, 255),
    Color.fromARGB(255, 255, 184, 89),
  ];

  /// 水母：每只自己的节奏一收一缩，缩的时候往上窜一点，慢慢浮上去，浮出上沿就从底下再来。
  /// 位置按时钟直接算（不积分），拖进度、重建都一样。
  void _jellies(
    Canvas canvas,
    Size size,
    double time,
    NebbiaSettings s,
    NebbiaColors colors,
  ) {
    final double h = size.height;
    final double aspect = size.width / h;
    const double top = -0.35;
    const double bottom = 1.35;
    final List<Color> theme = <Color>[colors.la, colors.lb, colors.lc];
    for (int i = 0; i < s.jellies; i++) {
      final double xf = nebbiaRand(i * 3.1 + 1);
      final double depth = nebbiaRand(i * 5.7 + 1.3);
      final double rate = 1.6 + 0.9 * nebbiaRand(i * 2.3 + 2);
      final double phase0 = nebbiaRand(i * 7.3 + 3) * math.pi * 2;
      final double rise = 0.012 + 0.012 * nebbiaRand(i * 9.1 + 4);
      final double hue = nebbiaRand(i * 11.0 + 5);
      final double ph = phase0 + time * rate;
      final double swim = math.max(math.sin(ph), 0);
      // 平均上浮速度 ≈ rise × (1 + 0.9 × 0.318)。
      final double travel =
          time * rise * 1.29 + 0.18 * (1 - math.cos(ph)) * rise / rate;
      const double span = bottom - top;
      final double y = bottom - ((nebbiaRand(i * 13.7) * span + travel) % span);
      final double x =
          (xf + 0.02 * math.sin(time * 0.15 + hue * 10)) * (aspect + 0.2) - 0.1;
      final double r = (0.03 + 0.055 * depth) * s.jellySize * h;
      final double squeeze = math.pow(swim, 3).toDouble();
      final Color col = Color.lerp(
        Color.lerp(
          _vivid[(hue * 4).floor() % 4],
          theme[((hue * 3.7 % 1) * 3).floor() % 3],
          0.35,
        )!,
        const Color(0xFF000000),
        1 - (0.45 + 0.55 * depth),
      )!;
      final Offset c = Offset(x * h, y * h);
      final double bw = r * (1 - 0.18 * squeeze);
      final double bh = r * (0.8 + 0.15 * squeeze);
      // 拖尾：几条随波的细线。
      final Path tails = Path();
      for (int k = 0; k < 5; k++) {
        final double bx = c.dx + (k - 2) / 2.5 * bw * 0.8;
        tails.moveTo(bx, c.dy);
        for (int j = 1; j <= 10; j++) {
          final double f = j / 10;
          tails.lineTo(
            bx + math.sin(time * 2 + f * 5 + k + i) * r * 0.15 * f,
            c.dy + f * r * 2.4,
          );
        }
      }
      canvas.drawPath(
        tails,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.8, r * 0.04)
          ..blendMode = BlendMode.plus
          ..color = col.withValues(alpha: 0.35)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.05),
      );
      final Rect bell = Rect.fromCenter(
        center: c,
        width: bw * 2,
        height: bh * 2,
      );
      canvas
        ..save()
        ..clipRect(
          Rect.fromLTRB(
            bell.left - 2,
            bell.top - 2,
            bell.right + 2,
            c.dy + bh * 0.15,
          ),
        );
      canvas.drawOval(
        bell,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.radial(
            c.translate(0, -bh * 0.2),
            bw,
            <Color>[
              col.withValues(alpha: 0.75),
              col.withValues(alpha: 0.2),
              col.withValues(alpha: 0.05),
            ],
            <double>[0, 0.7, 1],
          ),
      );
      canvas.restore();
      nebbiaGlow(canvas, c, r * 1.3, col, 0.25);
    }
  }

  /// 细泡（窗外的雨这一项）从几处泉眼冒上来；大泡（车灯这一项）偶尔一颗。
  void _bubbles(
    Canvas canvas,
    Size size,
    double time,
    NebbiaSettings s,
    double sandY,
  ) {
    if (s.bubbles <= 0) return;
    final double h = size.height;
    final double w = size.width;
    final Paint rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x99DFF6FF);
    if (s.rain != NebbiaRain.off) {
      final int vents = (2 + 5 * s.bubbles).round();
      for (int v = 0; v < vents; v++) {
        final double vx = nebbiaRand(v * 4.7 + 20) * w;
        const int per = 14;
        for (int k = 0; k < per; k++) {
          final double life = 4 + 2 * nebbiaRand(v * 13.0 + k);
          final double age =
              (time + k / per * life + nebbiaRand(v + 0.5) * 9) % life;
          final double f = age / life;
          final double y = sandY - f * (sandY + 0.05 * h);
          final double x = vx + math.sin(age * 3 + k) * 0.01 * h * (0.4 + f);
          final double r =
              (0.002 + 0.002 * nebbiaRand(v * 2.0 + k)) * h * (1 + f * 0.6);
          canvas.drawCircle(Offset(x, y), r, rim);
        }
      }
    }
    if (s.sceneryOn('cars')) {
      final int n = (1 + 4 * s.bubbles).round();
      for (int i = 0; i < n; i++) {
        const double life = 7;
        final double age = (time + i * 2.9) % life;
        final double cycle = ((time + i * 2.9) / life).floorToDouble();
        final double x = nebbiaRand(cycle * 3.3 + i) * w;
        final double y = sandY - age / life * (sandY + 0.1 * h);
        final double r = (0.012 + 0.012 * nebbiaRand(cycle + i * 1.7)) * h;
        final Offset c = Offset(x + math.sin(age * 2 + i) * r * 0.6, y);
        canvas
          ..drawOval(
            Rect.fromCenter(center: c, width: r * 2.1, height: r * 1.9),
            rim,
          )
          ..drawCircle(
            c.translate(-r * 0.35, -r * 0.4),
            r * 0.22,
            Paint()..color = const Color(0x88FFFFFF),
          );
      }
    }
  }
}

/// 光柱的形状：光源处很窄，到光斑处宽成光斑半径，末端是圆头。
Path nebbiaBeamPath(Offset src, Offset target, double radius) {
  final Offset d = target - src;
  final double l = d.distance;
  if (l < 1) return Path();
  final Offset u = d / l;
  final Offset n = Offset(-u.dy, u.dx);
  const double w0 = 3;
  final double w1 = radius * 0.9;
  return Path()
    ..moveTo(src.dx + n.dx * w0, src.dy + n.dy * w0)
    ..lineTo(target.dx + n.dx * w1, target.dy + n.dy * w1)
    ..arcToPoint(
      Offset(target.dx - n.dx * w1, target.dy - n.dy * w1),
      radius: Radius.circular(w1),
      clockwise: n.dx * u.dy - n.dy * u.dx > 0,
    )
    ..lineTo(src.dx - n.dx * w0, src.dy - n.dy * w0)
    ..close();
}
