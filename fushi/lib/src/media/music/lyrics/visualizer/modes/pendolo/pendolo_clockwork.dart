/// 时计的线框机芯（folia `pendoloClockworkDraw2d.ts` + `pendoloClockworkScene.ts` 配色）。
///
/// 一律按「相对轮心、未镜像」的表盘平面坐标画；每个部件先进自己那一层的投影
/// （镜像 / 倾斜 / 轮心视角 + 分层视差高度），所以倾斜时近高远低地错开，和 folia 的
/// WebGL 路径一致。齿形、游丝等路径按轮盘半径缓存，每帧只做旋转。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_geometry.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_tuning.dart';

/// 一帧机芯的输入。
class PendoloClockworkFrame {
  const PendoloClockworkFrame({
    required this.hubX,
    required this.hubY,
    required this.anchors,
    required this.escapementAngle,
    required this.phase,
    required this.bassOscillation,
    required this.secondGearAngle,
    required this.primary,
    required this.accent,
    required this.background,
    required this.decor,
    required this.showCenterGradient,
    required this.cover,
    required this.mirrored,
    required this.dial,
    required this.parallaxScalePx,
  });

  final double hubX;
  final double hubY;
  final PendoloClockworkAnchors anchors;
  final double escapementAngle;
  final double phase;
  final double bassOscillation;
  final double secondGearAngle;
  final Color primary;
  final Color accent;
  final Color background;
  final PendoloGearDecor decor;
  final bool showCenterGradient;

  /// 表盘封面（开着「表盘显示专辑封面」且已解码时）。
  final ui.Image? cover;
  final bool mirrored;

  /// 表盘平面投影（已含镜像）。
  final PendoloDialProjection dial;

  /// 分层高度（半径比例）× 它 = px；不倾斜时 0。
  final double parallaxScalePx;

  double get baseRadius => anchors.baseRadius;
}

Color _a(Color c, double alpha) => c.withValues(alpha: alpha.clamp(0.0, 1.0));

/// 主题色配出的线色（folia `buildPendoloClockworkPalette`）。
class _Palette {
  _Palette(Color primary, Color accent, PendoloGearDecor decor)
    : m = decor == PendoloGearDecor.full ? 1.0 : 0.6,
      _p = primary,
      _ac = accent;

  final double m;
  final Color _p;
  final Color _ac;

  Color get primary10 => _a(_p, 0.10 * m);
  Color get primary15 => _a(_p, 0.15 * m);
  Color get accent35 => _a(_ac, 0.35 * m);
  Color get gearPrimary => _a(_p, 0.42 * m);
  Color get gearPrimarySubtle => _a(_p, 0.32 * m);
  Color get gearAccent => _a(_ac, 0.58 * m);
  Color get gearAccentStrong => _a(_ac, 0.72 * m);
  Color get planetGear => _a(_p, 0.24 * m);
  Color get jewelFill => _a(_ac, 0.28 * m);
  Color get jewelStroke => _a(_ac, 0.65 * m);
  Color get mainGearFill => _a(_ac, 0.08 * m);
  Color get balanceGearFill => _a(_ac, 0.10 * m);
  Color get secondGearFill => _a(_ac, 0.06 * m);
  Color get bevelRing => _a(_p, 0.18 * m);
  Color get rivet => _a(_p, 0.25 * m);
  Color get guillocheAlt => _a(_p, 0.07 * m);
  Color get genevaAlt => _a(_p, 0.06 * m);
  Color get idlerStroke => _a(_p, 0.28 * m);
  Color get idlerInner => _a(_p, 0.18 * m);
  Color get hairspring => _a(_ac, 0.30 * m);
  Color get balanceIcon => _a(_ac, 0.62);
}

/// 梯形齿的闭合齿轮外形（folia `drawGearTeeth`），原点为齿轮中心。
Path pendoloGearTeethPath(double radius, int teeth, double toothDepth) {
  final double inner = radius - toothDepth;
  final double per = math.pi * 2 / teeth;
  final Path path = Path();
  for (int i = 0; i < teeth; i++) {
    final double base = i * per;
    final double a0 = base - per * 0.22;
    final double a1 = base - per * 0.12;
    final double a2 = base + per * 0.12;
    final double a3 = base + per * 0.22;
    final Offset p0 = Offset(inner * math.cos(a0), inner * math.sin(a0));
    if (i == 0) {
      path.moveTo(p0.dx, p0.dy);
    } else {
      path.lineTo(p0.dx, p0.dy);
    }
    path
      ..lineTo(radius * math.cos(a1), radius * math.sin(a1))
      ..lineTo(radius * math.cos(a2), radius * math.sin(a2))
      ..lineTo(inner * math.cos(a3), inner * math.sin(a3));
  }
  return path..close();
}

/// 游丝螺线（folia `drawHairspring`）。
Path pendoloHairspringPath(double startR, double endR, double coils) {
  final double total = coils * math.pi * 2;
  final int steps = (coils * 60).round();
  final Path path = Path();
  for (int i = 0; i <= steps; i++) {
    final double t = i / steps;
    final double angle = t * total;
    final double r = startR + (endR - startR) * math.pow(t, 0.9);
    final double x = r * math.cos(angle);
    final double y = r * math.sin(angle);
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  return path;
}

/// 摆轮上的主题图标（folia 用 lucide 的五角星）：描边五角星。
Path pendoloStarPath(double size) {
  final double outer = size / 2;
  final double inner = outer * 0.42;
  final Path path = Path();
  for (int i = 0; i < 10; i++) {
    final double r = i.isEven ? outer : inner;
    final double a = -math.pi / 2 + i * math.pi / 5;
    final double x = r * math.cos(a);
    final double y = r * math.sin(a);
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  return path..close();
}

/// 按轮盘半径缓存的路径。
class PendoloClockworkPaths {
  double _radius = -1;
  final Map<String, Path> _paths = <String, Path>{};

  Path _get(String key, Path Function() build) =>
      _paths.putIfAbsent(key, build);

  void _sync(double radius) {
    if (radius == _radius) return;
    _radius = radius;
    _paths.clear();
  }

  Path gear(String key, double r, int teeth, double depth) =>
      _get(key, () => pendoloGearTeethPath(r, teeth, depth));

  Path hairspring(double startR, double endR) =>
      _get('hairspring', () => pendoloHairspringPath(startR, endR, 3.5));

  Path star(double size) => _get('star', () => pendoloStarPath(size));
}

/// 画一帧机芯。
void paintPendoloClockwork(
  Canvas canvas,
  PendoloClockworkFrame f,
  PendoloClockworkPaths paths,
) {
  final PendoloClockworkAnchors an = f.anchors;
  final double r = f.baseRadius;
  paths._sync(r);
  final double esc = f.escapementAngle;
  final Paint stroke = Paint()
    ..style = PaintingStyle.stroke
    ..isAntiAlias = true;
  final Paint fill = Paint()..style = PaintingStyle.fill;

  void layer(double height, void Function() draw) {
    final PendoloDialProjection p = buildPendoloLayerProjection(
      f.dial,
      height * f.parallaxScalePx,
    );
    canvas.save();
    canvas.transform(
      Float64List.fromList(p.canvasMatrix(f.hubX, f.hubY).storage),
    );
    // 轮心视角下相机背后的半边不画（投影在那里翻转）。
    final ({double minX, double maxX, double minY, double maxY})? front = p
        .frontHalfPlane(0.08, r * 6);
    if (front != null) {
      canvas.clipRect(
        Rect.fromLTRB(front.minX, front.minY, front.maxX, front.maxY),
      );
    }
    draw();
    canvas.restore();
  }

  void circle(double cx, double cy, double radius, Color color, double width) {
    stroke
      ..color = color
      ..strokeWidth = width;
    canvas.drawCircle(Offset(cx, cy), radius, stroke);
  }

  void gear(
    String key,
    double cx,
    double cy,
    double radius,
    int teeth,
    double depth,
    double rotation,
    Color color,
    double width, [
    Color? fillColor,
  ]) {
    final Path path = paths.gear(key, radius, teeth, depth);
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(rotation);
    if (fillColor != null) {
      fill.color = fillColor;
      canvas.drawPath(path, fill);
    }
    stroke
      ..color = color
      ..strokeWidth = width;
    canvas.drawPath(path, stroke);
    canvas.restore();
  }

  void spoked(
    double cx,
    double cy,
    double hubR,
    double rimR,
    int spokes,
    double rotation,
    Color color,
    double width,
  ) {
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(rotation);
    stroke
      ..color = color
      ..strokeWidth = width;
    canvas.drawCircle(Offset.zero, hubR, stroke);
    canvas.drawCircle(Offset.zero, rimR, stroke);
    final double step = math.pi * 2 / spokes;
    for (int i = 0; i < spokes; i++) {
      final double a = i * step;
      canvas.drawLine(
        Offset(hubR * math.cos(a), hubR * math.sin(a)),
        Offset(rimR * math.cos(a), rimR * math.sin(a)),
        stroke,
      );
    }
    final double midR = (hubR + rimR) * 0.5;
    final double holeR = (rimR - hubR) * 0.22;
    for (int i = 0; i < spokes; i++) {
      final double a = i * step + step * 0.5;
      canvas.drawCircle(
        Offset(midR * math.cos(a), midR * math.sin(a)),
        holeR,
        stroke,
      );
    }
    canvas.restore();
  }

  void jewel(
    double cx,
    double cy,
    double outerR,
    double innerR,
    _Palette pal,
    double outerW,
    double innerW,
  ) {
    circle(cx, cy, outerR, pal.jewelStroke, outerW);
    circle(cx, cy, innerR, pal.jewelFill, innerW);
  }

  // 0. 表盘：中央深色渐变、封面。
  layer(PendoloLayerHeight.dialFace, () {
    if (f.showCenterGradient) {
      final double gr = an.gradientR;
      canvas.drawCircle(
        Offset.zero,
        gr,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset.zero,
            gr,
            <Color>[
              _a(f.background, 0.72),
              _a(f.background, 0.52),
              _a(f.background, 0.20),
              _a(f.background, 0),
            ],
            const <double>[0, 0.35, 0.7, 1],
          ),
      );
    }
    final ui.Image? cover = f.cover;
    if (cover != null) {
      final double cr = an.coverRadius;
      canvas.save();
      canvas.clipPath(
        Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: cr)),
      );
      // 镜像时整块表盘被翻过，封面再翻回来，图里的字不是反的。
      if (f.mirrored) canvas.scale(-1, 1);
      final double iw = cover.width.toDouble();
      final double ih = cover.height.toDouble();
      final double side = math.min(iw, ih);
      canvas.drawImageRect(
        cover,
        Rect.fromLTWH((iw - side) / 2, (ih - side) / 2, side, side),
        Rect.fromCircle(center: Offset.zero, radius: cr),
        Paint()
          ..filterQuality = FilterQuality.medium
          ..color = Color.fromRGBO(
            0,
            0,
            0,
            0.42 * (f.decor == PendoloGearDecor.full ? 1.0 : 0.6),
          ),
      );
      canvas.restore();
    }
    if (f.decor == PendoloGearDecor.none) return;
    final _Palette pal = _Palette(f.primary, f.accent, f.decor);
    for (final double ring in <double>[0.3, 0.6, 0.85, 1.15, 1.4]) {
      circle(0, 0, r * ring, pal.primary15, 1);
    }
  });

  if (f.decor == PendoloGearDecor.none) return;
  final _Palette pal = _Palette(f.primary, f.accent, f.decor);

  // 1. 外圈 60 个刻度（每 6°），随轮盘慢转。
  layer(PendoloLayerHeight.ticks, () {
    final double outer = r * 1.15;
    for (int i = 0; i < 60; i++) {
      final double a = i * math.pi * 2 / 60 + esc * 0.2;
      final bool major = i % 5 == 0;
      final double len = major ? 12 : 6;
      stroke
        ..color = major ? pal.accent35 : pal.primary15
        ..strokeWidth = major ? 1.5 : 1;
      canvas.drawLine(
        Offset(outer * math.cos(a), outer * math.sin(a)),
        Offset((outer + len) * math.cos(a), (outer + len) * math.sin(a)),
        stroke,
      );
    }
  });

  // 2. 擒纵主轮：外齿、辐条、倒角双环、放射雕纹、铆钉。
  layer(PendoloLayerHeight.escapement, () {
    gear(
      'main',
      0,
      0,
      r + 8,
      36,
      10,
      esc,
      pal.gearAccent,
      2.2,
      pal.mainGearFill,
    );
    spoked(0, 0, r * 0.2, r * 0.85, 6, esc, pal.gearPrimary, 1.8);
    circle(0, 0, r * 0.88, pal.bevelRing, 0.8);
    circle(0, 0, r * 0.92, pal.bevelRing, 0.8);
    canvas.save();
    canvas.rotate(esc);
    final double gIn = r * 0.62;
    final double gOut = r * 0.83;
    stroke.strokeWidth = 0.7;
    for (int i = 0; i < 48; i++) {
      final double a = i * math.pi * 2 / 48;
      final double inner = i.isEven ? gIn : gIn + (gOut - gIn) * 0.3;
      stroke.color = i.isEven ? pal.primary10 : pal.guillocheAlt;
      canvas.drawLine(
        Offset(inner * math.cos(a), inner * math.sin(a)),
        Offset(gOut * math.cos(a), gOut * math.sin(a)),
        stroke,
      );
    }
    canvas.restore();
    final double rivetR = r * 0.96;
    for (int i = 0; i < 12; i++) {
      final double a = i * math.pi * 2 / 12 + esc;
      circle(rivetR * math.cos(a), rivetR * math.sin(a), 2.2, pal.rivet, 0.8);
    }
  });

  // 惰轮（传动齿轮与秒齿轮之间）。
  layer(PendoloLayerHeight.idler, () {
    gear(
      'idler',
      an.idlerX,
      an.idlerY,
      an.idlerR,
      10,
      3.5,
      esc * 2.2,
      pal.idlerStroke,
      1.3,
    );
    circle(an.idlerX, an.idlerY, an.idlerR * 0.45, pal.idlerInner, 0.8);
    jewel(an.idlerX, an.idlerY, 2.2, 1.2, pal, 0.7, 0.5);
  });

  // 3. 中心太阳轮与宝石轴承。
  layer(PendoloLayerHeight.mainSun, () {
    gear('sun', 0, 0, r * 0.22, 12, 6, -esc * 2.5, pal.gearAccentStrong, 2.1);
    jewel(0, 0, 4.5, 2.5, pal, 1.2, 0.8);
  });

  // 秒齿轮：每秒走一齿（播放中）。
  layer(PendoloLayerHeight.second, () {
    final double s = f.secondGearAngle;
    gear(
      'second',
      an.secondX,
      an.secondY,
      an.secondR,
      15,
      5,
      s,
      pal.gearAccent,
      1.8,
      pal.secondGearFill,
    );
    spoked(
      an.secondX,
      an.secondY,
      an.secondR * 0.28,
      an.secondR * 0.76,
      4,
      -s,
      pal.gearPrimarySubtle,
      1.3,
    );
    jewel(an.secondX, an.secondY, 2.8, 1.5, pal, 0.8, 0.6);
  });

  // 6. 焦点轴（刻度针）与箭头，指着焦点句。
  layer(PendoloLayerHeight.axis, () {
    stroke
      ..color = pal.gearAccentStrong
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(r * 0.8, 0),
      Offset(an.focalAxisEndRadius, 0),
      stroke,
    );
    final double ax = an.focalAxisEndRadius;
    fill.color = pal.gearAccentStrong;
    canvas.drawPath(
      Path()
        ..moveTo(ax, -4)
        ..lineTo(ax + 8, 0)
        ..lineTo(ax, 4)
        ..close(),
      fill,
    );
  });

  // 4. 三颗行星轮绕轴公转。
  layer(PendoloLayerHeight.planet, () {
    final double orbitBase = esc * 0.4;
    for (int i = 0; i < 3; i++) {
      final double a = orbitBase + i * math.pi * 2 / 3;
      final double px = an.orbitR * math.cos(a);
      final double py = an.orbitR * math.sin(a);
      gear(
        'planet',
        px,
        py,
        an.planetR,
        14,
        5,
        -esc * 3 + i * 0.5,
        pal.planetGear,
        1.7,
      );
      jewel(px, py, 3.5, 1.8, pal, 1, 0.7);
    }
  });

  // 传动齿轮：跟着主轮反转，面上有日内瓦波纹。
  layer(PendoloLayerHeight.trans, () {
    final double ta = -esc * 1.4;
    gear(
      'trans',
      an.transX,
      an.transY,
      an.transR,
      24,
      7,
      ta,
      pal.gearPrimary,
      1.8,
    );
    spoked(
      an.transX,
      an.transY,
      an.transR * 0.25,
      an.transR * 0.85,
      5,
      ta,
      pal.gearPrimarySubtle,
      1.5,
    );
    canvas.save();
    canvas.translate(an.transX, an.transY);
    canvas.rotate(ta);
    canvas.clipPath(
      Path()..addOval(
        Rect.fromCircle(center: Offset.zero, radius: an.transR * 0.8),
      ),
    );
    final double span = an.transR * 1.6;
    final double step = span / 10;
    stroke.strokeWidth = 0.7;
    for (int i = 1; i <= 9; i++) {
      final double y = -span * 0.5 + i * step;
      stroke.color = i.isEven ? pal.primary10 : pal.genevaAlt;
      canvas.drawLine(Offset(-an.transR, y), Offset(an.transR, y), stroke);
    }
    canvas.restore();
    jewel(an.transX, an.transY, 3.5, 1.8, pal, 1, 0.7);
  });

  // 5. 左上摆轮：齿轮、图标座、游丝、宝石、主题图标。
  layer(PendoloLayerHeight.balance, () {
    final double ba = f.phase * 0.1;
    gear(
      'balance',
      an.balanceX,
      an.balanceY,
      an.balanceR,
      20,
      7,
      ba,
      pal.gearAccentStrong,
      2.1,
      pal.balanceGearFill,
    );
    circle(
      an.balanceX,
      an.balanceY,
      an.balanceR * 0.52,
      pal.gearPrimarySubtle,
      1.8,
    );
    canvas.save();
    canvas.translate(an.balanceX, an.balanceY);
    canvas.rotate(f.bassOscillation * 0.6 + ba * 0.3);
    stroke
      ..color = pal.hairspring
      ..strokeWidth = 0.8;
    canvas.drawPath(
      paths.hairspring(an.balanceR * 0.56, an.balanceR * 0.88),
      stroke,
    );
    canvas.restore();
    jewel(an.balanceX, an.balanceY, 3.5, 1.8, pal, 1, 0.7);
    // 主题图标不随摆轮转；镜像时翻回来（五角星左右对称，翻不翻都一样，只为位置）。
    final double iconSize = math.max(14, r * 0.13).toDouble();
    canvas.save();
    canvas.translate(an.balanceX, an.balanceY);
    stroke
      ..color = pal.balanceIcon
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(paths.star(iconSize), stroke);
    canvas.restore();
  });
}
