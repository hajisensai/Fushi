/// 町景的天空与天气（folia `engine/sky.ts`、`fx/weather.ts`、`fx/post.ts` 的氛围部分）：竖向渐变
/// 天空（夜 / 黄昏 / 白天三套之间插值，阴天往灰里拉）、晴夜的星星、云、闪电；雨丝与水花、
/// 雪花在底座上方的世界空间里落（落到屋顶为止）；雾天按高低加一层灰、贴地薄雾、暗角。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_director.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_render.dart';

/// 天空此刻的上下两色。
(Color, Color) resolveMachiSkyColors(MachiFrame f) {
  final double d = f.env.daylight;
  Color tri(Color night, Color dusk, Color day) => d < machiDaylightDusk
      ? machiMix(night, dusk, d / machiDaylightDusk)
      : machiMix(dusk, day, (d - machiDaylightDusk) / (1 - machiDaylightDusk));
  Color top = tri(f.palette.skyTop, f.palette.skyTopDusk, f.palette.skyTopDay);
  Color bottom = tri(
    f.palette.skyBottom,
    f.palette.skyBottomDusk,
    f.palette.skyBottomDay,
  );
  final double gray = f.look.overcast * 0.6;
  Color grayOf(Color c) {
    final double l = 0.3 * c.r + 0.59 * c.g + 0.11 * c.b;
    return Color.from(alpha: 1, red: l * 0.95, green: l * 0.97, blue: l);
  }

  top = machiMix(top, grayOf(top), gray);
  bottom = machiMix(bottom, grayOf(bottom), gray);
  if (f.lightning > 0) {
    top = machiMix(top, machiHex(0xd8dcff), f.lightning * 0.7);
    bottom = machiMix(bottom, machiHex(0xeef0ff), f.lightning * 0.6);
  }
  return (top, bottom);
}

void paintMachiSky(Canvas canvas, Size size, MachiFrame f) {
  final Rect all = Offset.zero & size;
  final (Color top, Color bottom) = resolveMachiSkyColors(f);
  canvas.drawRect(
    all,
    Paint()
      ..shader = ui.Gradient.linear(all.topCenter, all.bottomCenter, <Color>[
        top,
        bottom,
      ]),
  );
  // 星星（晴夜）。
  final double stars = f.look.stars;
  if (stars > 0.02) {
    final Paint p = Paint()..strokeCap = StrokeCap.round;
    for (int i = 0; i < 140; i++) {
      final double x = machiHash01(f.seed, i, 0x5a) * size.width;
      final double y = machiHash01(f.seed, i, 0x5b) * size.height * 0.7;
      final double tw = f.motion
          ? 0.6 + 0.4 * math.sin(f.ambient * (1 + i % 5) + i)
          : 1;
      p
        ..color = Color.fromRGBO(
          255,
          255,
          255,
          machiClamp(
            stars * tw * (0.3 + 0.7 * machiHash01(f.seed, i, 0x5c)),
            0,
            1,
          ),
        )
        ..strokeWidth = 1 + machiHash01(f.seed, i, 0x5d) * 1.4;
      canvas.drawPoints(ui.PointMode.points, <Offset>[Offset(x, y)], p);
    }
  }
  // 云：几团模糊的椭圆，缓慢地飘；云量随天气。
  final double clouds = f.look.clouds;
  final Color cloudColor = machiMix(bottom, top, 0.3);
  final Color lit = machiMix(
    cloudColor,
    machiHex(0xffffff),
    0.18 + 0.25 * f.env.daylight,
  );
  final int n = (3 + clouds * 6).round();
  for (int i = 0; i < n; i++) {
    final double w = size.width * (0.25 + 0.3 * machiHash01(f.seed, i, 0x61));
    final double drift = f.ambient * (4 + 6 * machiHash01(f.seed, i, 0x62));
    final double x =
        ((machiHash01(f.seed, i, 0x63) * (size.width + w) + drift) %
            (size.width + w)) -
        w / 2;
    final double y = size.height * (0.05 + 0.35 * machiHash01(f.seed, i, 0x64));
    canvas.drawOval(
      Rect.fromCenter(center: Offset(x, y), width: w, height: w * 0.22),
      Paint()
        ..color = lit.withValues(alpha: machiClamp(0.12 + 0.25 * clouds, 0, 1))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.08),
    );
  }
}

/// 雨丝、水花、雪花（世界空间，底座上方）。
void paintMachiPrecipitation(
  Canvas canvas,
  MachiCamera camera,
  MachiFrame f,
  MachiSceneModel scene,
) {
  final double rain = machiClamp(
    f.env.rain * (0.8 + 0.2 * f.chorus + 0.15 * f.audio) * f.intensity,
    0,
    1.3,
  );
  final double snow = f.env.snow * (0.75 + 0.25 * f.intensity);
  const double topY = 9.5;
  if (rain > 0.02) {
    final int count = (420 * rain).round();
    final Path streaks = Path();
    const double speed = 11;
    const double wind = 0.08;
    for (int i = 0; i < count; i++) {
      final double x = machiHash01(f.seed, i, 0x81) * 12 - 6;
      final double z = machiHash01(f.seed, i, 0x82) * 12 - 6;
      final double ground = scene.groundAt(x, z);
      final double span = topY - ground;
      final double y =
          topY -
          ((f.ambient * speed + machiHash01(f.seed, i, 0x83) * span) % span);
      final Offset a = camera.project(MachiV3(x, y, z));
      final Offset b = camera.project(MachiV3(x - wind, y + 0.42, z));
      streaks
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy);
    }
    final Color c = machiMix(
      machiHex(0xb8c8e0),
      machiHex(0xffffff),
      f.env.daylight * 0.3,
    );
    canvas.drawPath(
      streaks,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.7, camera.scale * 0.012)
        ..color = c.withValues(
          alpha: machiClamp(0.32 + 0.2 * f.lightning, 0, 1),
        ),
    );
    // 水花：地上 / 屋顶上一圈圈小环。
    final int splashes = (110 * rain).round();
    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.6, camera.scale * 0.01);
    final double squash = math.sin(camera.elevation);
    for (int i = 0; i < splashes; i++) {
      final double x = machiHash01(f.seed, i, 0x84) * 11.6 - 5.8;
      final double z = machiHash01(f.seed, i, 0x85) * 11.6 - 5.8;
      final double age = (f.ambient + machiHash01(f.seed, i, 0x86) * 0.6) % 0.6;
      if (age > 0.2) continue;
      final double r = (0.04 + age * 0.6) * camera.scale;
      final Offset o = camera.project(
        MachiV3(x, scene.groundAt(x, z) + 0.02, z),
      );
      ring.color = c.withValues(alpha: 0.5 * (1 - age / 0.2));
      canvas.drawOval(
        Rect.fromCenter(center: o, width: r * 2, height: r * 2 * squash),
        ring,
      );
    }
  }
  if (snow > 0.02) {
    final int count = (300 * snow).round();
    final Float32List pts = Float32List(count * 2);
    for (int i = 0; i < count; i++) {
      final double x0 = machiHash01(f.seed, i, 0x87) * 12 - 6;
      final double z0 = machiHash01(f.seed, i, 0x88) * 12 - 6;
      final double ground = scene.groundAt(x0, z0);
      final double span = topY - ground;
      final double y =
          topY -
          ((f.ambient * 0.8 + machiHash01(f.seed, i, 0x89) * span) % span);
      final double sway = 0.25 * math.sin(f.ambient * 0.9 + i);
      final Offset o = camera.project(MachiV3(x0 + sway, y, z0 + sway * 0.5));
      pts[i * 2] = o.dx;
      pts[i * 2 + 1] = o.dy;
    }
    canvas.drawRawPoints(
      ui.PointMode.points,
      pts,
      Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = math.max(1.6, camera.scale * 0.07)
        ..color = const Color(0xE6F4F7FF),
    );
  }
}

/// 雾、贴地薄雾、闪电、暗角（画在场景之上）。
void paintMachiAtmosphere(Canvas canvas, Size size, MachiFrame f) {
  final Rect all = Offset.zero & size;
  final (Color top, Color bottom) = resolveMachiSkyColors(f);
  final double haze = f.look.haze;
  if (haze > 0.01) {
    canvas.drawRect(
      all,
      Paint()
        ..shader = ui.Gradient.linear(all.topCenter, all.bottomCenter, <Color>[
          bottom.withValues(alpha: machiClamp(haze * 0.95, 0, 0.9)),
          bottom.withValues(alpha: machiClamp(haze * 0.45, 0, 0.9)),
        ]),
    );
  }
  final double mist = f.look.mist;
  if (mist > 0.01) {
    final Rect low = Rect.fromLTWH(
      0,
      size.height * 0.45,
      size.width,
      size.height * 0.55,
    );
    canvas.drawRect(
      low,
      Paint()
        ..shader = ui.Gradient.linear(low.topCenter, low.bottomCenter, <Color>[
          machiMix(bottom, top, 0.2).withValues(alpha: 0),
          machiMix(
            bottom,
            top,
            0.2,
          ).withValues(alpha: machiClamp(mist * 0.45, 0, 0.6)),
        ]),
    );
  }
  if (f.lightning > 0.01) {
    canvas.drawRect(
      all,
      Paint()
        ..blendMode = BlendMode.plus
        ..color = Color.fromRGBO(
          200,
          210,
          255,
          machiClamp(f.lightning * 0.3, 0, 1),
        ),
    );
  }
  canvas.drawRect(
    all,
    Paint()
      ..shader = ui.Gradient.radial(
        all.center,
        all.longestSide * 0.72,
        <Color>[
          const Color(0x00000000),
          const Color(0x00000000),
          Color.fromRGBO(0, 0, 0, 0.32 - 0.12 * f.env.daylight),
        ],
        const <double>[0, 0.62, 1],
      ),
  );
}
