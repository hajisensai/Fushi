/// 三个场景共用的道具（folia `engine/geometry/plinth.ts`、`actors/traffic.ts`、`actors/nobori.ts`
/// 以及各场景里的路灯、贩卖机、自行车、电线杆……）：都由盒子、面板和几笔线组成。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_director.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_palette.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_render.dart';

/// 底座半宽（12m 见方）与厚度。
const double machiBaseHalf = 6;
const double machiBaseDepth = 0.6;

MachiSolid machiBox(
  double x0,
  double y0,
  double z0,
  double x1,
  double y1,
  double z1,
  Color color, {
  Color? top,
  Map<MachiSide, MachiDecal> decals = const <MachiSide, MachiDecal>{},
  Set<MachiSide> emissive = const <MachiSide>{},
  Map<MachiSide, Color> sideColors = const <MachiSide, Color>{},
  bool outline = true,
  bool snowable = true,
}) => MachiSolid.box(
  MachiV3(math.min(x0, x1), math.min(y0, y1), math.min(z0, z1)),
  MachiV3(math.max(x0, x1), math.max(y0, y1), math.max(z0, z1)),
  color,
  top: top,
  decals: decals,
  emissiveSides: emissive,
  sideColors: sideColors,
  outline: outline,
  snowable: snowable,
);

/// 底座：12m 见方、0.6m 厚，侧面三道地层色。
List<MachiItem> machiPlinth() {
  void strata(Canvas c, Size s, MachiFrame f) {
    final double h = s.height;
    c.drawRect(
      Rect.fromLTWH(0, 0, s.width, h * 0.12),
      Paint()
        ..color = f.lighting.shade(
          MachiPalette.plinthTrim,
          const MachiV3(0, 0, 1),
        ),
    );
    c.drawRect(
      Rect.fromLTWH(0, h * 0.62, s.width, h * 0.38),
      Paint()
        ..color = f.lighting.shade(
          MachiPalette.plinthLow,
          const MachiV3(0, 0, 1),
        ),
    );
  }

  return <MachiItem>[
    machiBox(
      -machiBaseHalf,
      -machiBaseDepth,
      -machiBaseHalf,
      machiBaseHalf,
      0,
      machiBaseHalf,
      MachiPalette.plinthMid,
      top: MachiPalette.plinthTop,
      decals: <MachiSide, MachiDecal>{
        MachiSide.front: strata,
        MachiSide.right: strata,
        MachiSide.left: strata,
        MachiSide.back: strata,
      },
    ),
  ];
}

/// 地面上的一块矩形（xz）。
MachiGround machiGroundRect(
  double x0,
  double z0,
  double x1,
  double z1,
  double y,
  Color color, {
  MachiDecal? decal,
  bool wet = true,
}) => MachiGround(
  MachiFaceFrame(
    MachiV3(x0, y, z0),
    const MachiV3(1, 0, 0),
    const MachiV3(0, 0, 1),
    x1 - x0,
    z1 - z0,
  ),
  color,
  decal: decal,
  wet: wet,
);

/// 一根方杆（细的柱子用盒子代替圆柱，微缩里看不出来）。
MachiSolid machiPost(
  double x,
  double z,
  double y0,
  double y1,
  double w,
  Color c,
) => machiBox(
  x - w / 2,
  y0,
  z - w / 2,
  x + w / 2,
  y1,
  z + w / 2,
  c,
  snowable: false,
);

/// 路灯：杆、臂、灯头；返回物件与灯。
(List<MachiItem>, MachiLamp) machiStreetLamp({
  required double x,
  required double z,
  required double height,
  required double armX,
  required double armZ,
}) {
  final MachiV3 head = MachiV3(x + armX, height - 0.12, z + armZ);
  final List<MachiItem> items = <MachiItem>[
    machiPost(x, z, 0, height, 0.14, MachiPalette.pole),
    MachiCustom(MachiV3(x + armX / 2, height, z + armZ / 2), (MachiRenderer r) {
      r.line(
        MachiV3(x, height - 0.05, z),
        head + const MachiV3(0, 0.08, 0),
        r.frame.lighting.shade(MachiPalette.pole, MachiV3.up),
        0.08,
      );
    }),
    machiBox(
      head.x - 0.22,
      head.y - 0.05,
      head.z - 0.12,
      head.x + 0.22,
      head.y + 0.08,
      head.z + 0.12,
      MachiPalette.darkMetal,
    ),
  ];
  return (
    items,
    MachiLamp(
      position: head + const MachiV3(0, -0.1, 0),
      color: MachiPalette.streetLight,
      radius: 0.9,
      pool: 2.3,
      poolAt: MachiV3(head.x, 0.03, head.z),
      streetLamp: true,
    ),
  );
}

/// 贩卖机：盒身，正面一块发光的面板（几排饮料）。[facing] 是正面朝向。
MachiSolid machiVending({
  required double x0,
  required double z0,
  required double x1,
  required double z1,
  required double height,
  required MachiSide facing,
  required MachiPalette palette,
  int seed = 0,
}) {
  void face(Canvas c, Size s, MachiFrame f) {
    final double w = s.width;
    final double h = s.height;
    c.drawRect(
      Offset.zero & s,
      Paint()..color = f.lighting.shade(palette.vendingBody, MachiV3.up),
    );
    final Rect panel = Rect.fromLTWH(w * 0.08, h * 0.08, w * 0.84, h * 0.52);
    c.drawRect(
      panel,
      Paint()..color = f.emissive(MachiPalette.vendingLight, 0.95),
    );
    final Paint p = Paint();
    for (int row = 0; row < 3; row++) {
      for (int col = 0; col < 6; col++) {
        p.color = f.emissive(
          palette.products[(col + row * 3 + seed) % palette.products.length],
          0.95,
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              panel.left + panel.width * (0.04 + col * 0.16),
              panel.top + panel.height * (0.08 + row * 0.32),
              panel.width * 0.1,
              panel.height * 0.2,
            ),
            Radius.circular(panel.width * 0.03),
          ),
          p,
        );
      }
    }
    c.drawRect(
      Rect.fromLTWH(w * 0.08, h * 0.64, w * 0.84, h * 0.06),
      Paint()..color = f.emissive(palette.vendingAccent),
    );
    c.drawRect(
      Rect.fromLTWH(w * 0.2, h * 0.8, w * 0.6, h * 0.1),
      Paint()..color = const Color(0xFF15181F),
    );
  }

  return machiBox(
    x0,
    0.02,
    z0,
    x1,
    height,
    z1,
    palette.vendingBody,
    decals: <MachiSide, MachiDecal>{facing: face},
  );
}

/// 车：车身、车厢（玻璃）、轮子；[alongX] 为 true 时车身沿 x，[forward] 是车头方向（±1）。
/// 出租车多一个顶灯；[clip] 时车身截到底座里（从底座边上“开出来”）。
MachiGroup machiCar({
  required double x,
  required double z,
  required bool alongX,
  required double forward,
  required Color body,
  double length = 3.2,
  double width = 1.42,
  double height = 1.38,
  bool taxi = false,
  bool kei = false,
  bool clip = false,
  MachiDecal? roofSign,
  bool hazard = false,
}) {
  final double hl = length / 2;
  final double hw = width / 2;
  double a0 = -hl;
  double a1 = hl;
  final double centerA = alongX ? x : z;
  if (clip) {
    a0 = math.max(a0, -machiBaseHalf - centerA);
    a1 = math.min(a1, machiBaseHalf - centerA);
  }
  final List<MachiItem> parts = <MachiItem>[];
  if (a1 - a0 <= 0.05) return MachiGroup(parts, MachiV3(x, 0.5, z));
  MachiSolid? part(
    double s0,
    double s1,
    double y0,
    double y1,
    double inset,
    Color c, {
    Map<MachiSide, MachiDecal> decals = const <MachiSide, MachiDecal>{},
    Set<MachiSide> emissive = const <MachiSide>{},
  }) {
    final double u0 = math.max(s0, a0);
    final double u1 = math.min(s1, a1);
    if (u1 - u0 < 0.02) return null;
    if (alongX) {
      return machiBox(
        x + u0,
        y0,
        z - hw + inset,
        x + u1,
        y1,
        z + hw - inset,
        c,
        decals: decals,
        emissive: emissive,
      );
    }
    return machiBox(
      x - hw + inset,
      y0,
      z + u0,
      x + hw - inset,
      y1,
      z + u1,
      c,
      decals: decals,
      emissive: emissive,
    );
  }

  void windows(Canvas c, Size s, MachiFrame f) {
    final Paint glass = Paint()
      ..color = f.lighting.shade(
        machiMix(MachiPalette.glass, machiHex(0x1d2430), 0.55),
        const MachiV3(0, 0.4, 1),
      );
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          s.width * 0.06,
          s.height * 0.12,
          s.width * 0.88,
          s.height * 0.7,
        ),
        Radius.circular(s.height * 0.12),
      ),
      glass,
    );
  }

  final double cabinFrom = kei ? (forward > 0 ? hl * 0.25 : -hl) : -hl * 0.55;
  final double cabinTo = kei ? (forward > 0 ? hl : -hl * 0.25) : hl * 0.45;
  final double cab0 = forward > 0 ? cabinFrom : -cabinTo;
  final double cab1 = forward > 0 ? cabinTo : -cabinFrom;
  parts.addAll(
    <MachiItem?>[part(-hl, hl, 0.18, height * 0.55, 0, body)].nonNulls,
  );
  final Map<MachiSide, MachiDecal> cabinDecals = <MachiSide, MachiDecal>{
    MachiSide.front: windows,
    MachiSide.back: windows,
    MachiSide.left: windows,
    MachiSide.right: windows,
  };
  parts.addAll(
    <MachiItem?>[
      part(
        cab0,
        cab1,
        height * 0.55,
        height,
        width * 0.06,
        body,
        decals: cabinDecals,
      ),
    ].nonNulls,
  );
  if (kei) {
    // 轻卡的货斗：一圈矮栏板。
    final double b0 = forward > 0 ? -hl : hl * 0.25;
    final double b1 = forward > 0 ? hl * 0.2 : hl;
    parts.addAll(
      <MachiItem?>[
        part(b0, b1, height * 0.55, height * 0.72, 0, machiScale(body, 0.8)),
      ].nonNulls,
    );
  }
  // 轮子。
  for (final double s in <double>[-hl * 0.62, hl * 0.62]) {
    for (final double side in <double>[-1, 1]) {
      if (s - 0.32 < a0 || s + 0.32 > a1) continue;
      // 轮子收在车身两侧里面，只露出外侧一面。
      final double cx = alongX ? x + s : x + side * (hw - 0.13);
      final double cz = alongX ? z + side * (hw - 0.13) : z + s;
      final double rx = alongX ? 0.27 : 0.11;
      final double rz = alongX ? 0.11 : 0.27;
      parts.add(
        machiBox(
          cx - rx,
          0,
          cz - rz,
          cx + rx,
          0.5,
          cz + rz,
          MachiPalette.rubber,
          outline: false,
          snowable: false,
        ),
      );
    }
  }
  if (taxi && roofSign != null) {
    final double rx = alongX ? x : x;
    final double rz = alongX ? z : z;
    final double cen = (cab0 + cab1) / 2;
    final double ax = alongX ? rx + cen : rx;
    final double az = alongX ? rz : rz + cen;
    if (cen > a0 && cen < a1) {
      // 顶灯（行灯）：横在车顶，两面朝车头、车尾，写下一句。
      parts.add(
        alongX
            ? machiBox(
                ax - 0.12,
                height,
                az - 0.42,
                ax + 0.12,
                height + 0.26,
                az + 0.42,
                machiHex(0xf4f1ea),
                decals: <MachiSide, MachiDecal>{
                  MachiSide.right: roofSign,
                  MachiSide.left: roofSign,
                },
                emissive: const <MachiSide>{MachiSide.right, MachiSide.left},
              )
            : machiBox(
                ax - 0.42,
                height,
                az - 0.12,
                ax + 0.42,
                height + 0.26,
                az + 0.12,
                machiHex(0xf4f1ea),
                decals: <MachiSide, MachiDecal>{
                  MachiSide.front: roofSign,
                  MachiSide.back: roofSign,
                },
                emissive: const <MachiSide>{MachiSide.front, MachiSide.back},
              ),
      );
    }
  }
  // 前后灯（双闪时黄灯一闪一闪）。
  final double front = forward * (hl + 0.01);
  if (front > a0 && front < a1) {
    parts.add(
      MachiCustom(
        alongX ? MachiV3(x + front, 0.6, z) : MachiV3(x, 0.6, z + front),
        (MachiRenderer r) {
          final MachiFrame f = r.frame;
          for (final double side in <double>[-1, 1]) {
            final MachiV3 at = alongX
                ? MachiV3(x + front, height * 0.42, z + side * hw * 0.62)
                : MachiV3(x + side * hw * 0.62, height * 0.42, z + front);
            final bool blink = hazard && ((f.ambient * 1.6) % 1) < 0.5;
            r.glow(
              at,
              0.35,
              blink ? MachiPalette.caution : machiHex(0xfff4dc),
              hazard ? (blink ? 0.9 : 0.1) : 0.65 * f.look.streetLamps,
            );
          }
        },
      ),
    );
  }
  return MachiGroup(parts, MachiV3(x, height / 2, z));
}

/// 自行车：两个轮子、车架几笔线（竖在 [alongX] 方向的平面里）。
MachiCustom machiBike(
  double x,
  double z,
  bool alongX,
  Color color,
) => MachiCustom(MachiV3(x, 0.45, z), (MachiRenderer r) {
  final MachiV3 u = alongX ? const MachiV3(1, 0, 0) : const MachiV3(0, 0, 1);
  final Color wheel = r.frame.lighting.shade(MachiPalette.rubber, MachiV3.up);
  final Color frameColor = r.frame.lighting.shade(color, MachiV3.up);
  final Paint ring = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 7
    ..color = wheel;
  for (final double s in <double>[-0.52, 0.52]) {
    final MachiV3 c = MachiV3(x, 0.34, z) + u * s;
    r.canvas.save();
    r.canvas.transform(r.camera.planeMatrix(c, u, MachiV3.down));
    r.canvas.drawCircle(Offset.zero, 30, ring);
    r.canvas.restore();
  }
  final MachiV3 a = MachiV3(x, 0.34, z) + u * -0.52;
  final MachiV3 b = MachiV3(x, 0.34, z) + u * 0.52;
  final MachiV3 seat = MachiV3(x, 0.86, z) + u * -0.15;
  final MachiV3 bar = MachiV3(x, 0.95, z) + u * 0.42;
  r.line(a, seat, frameColor, 0.04);
  r.line(seat, b, frameColor, 0.04);
  r.line(MachiV3(x, 0.4, z), bar, frameColor, 0.04);
  r.line(bar, b, frameColor, 0.04);
  r.line(seat - u * 0.1, seat + u * 0.1, wheel, 0.06);
});

/// のぼり旗：一根杆、一面竖长的旗，按风向飘（顶点着色器里随风飘的样子用剪切近似）。
MachiCustom machiNobori({
  required double x,
  required double z,
  required MachiV3 facing,
  required String text,
  required Color color,
  required Color textColor,
  required int index,
}) {
  const double height = 2.2;
  const double width = 0.5;
  final MachiV3 u = MachiV3(facing.z, 0, -facing.x).normalized();
  return MachiCustom(MachiV3(x, height / 2, z), (MachiRenderer r) {
    final MachiFrame f = r.frame;
    r.line(
      MachiV3(x, 0, z),
      MachiV3(x, height + 0.1, z),
      f.lighting.shade(MachiPalette.pole, MachiV3.up),
      0.035,
    );
    final double sway = f.motion
        ? math.sin(f.ambient * 2.1 + index * 1.7) * 0.06
        : 0;
    final MachiV3 origin = MachiV3(x, height, z) + u * 0.02;
    final MachiV3 v = (MachiV3.down + facing * sway).normalized();
    r.canvas.save();
    r.canvas.transform(r.camera.planeMatrix(origin, u, v));
    const Size s = Size(
      width * machiLocalPxPerMeter,
      1.6 * machiLocalPxPerMeter,
    );
    final bool front = r.camera.faces(facing);
    final Color bg = f.lighting.shade(
      color,
      front ? facing : -facing,
      snowable: false,
    );
    r.canvas.drawRect(Offset.zero & s, Paint()..color = bg);
    r.canvas.drawRect(
      Rect.fromLTWH(0, 0, s.width, s.height * 0.08),
      Paint()..color = f.lighting.shade(machiHex(0xf4f1ea), facing),
    );
    if (front) {
      f.text.drawVertical(
        r.canvas,
        text,
        Rect.fromLTWH(
          s.width * 0.1,
          s.height * 0.12,
          s.width * 0.8,
          s.height * 0.84,
        ),
        f.lighting.shade(textColor, facing, snowable: false),
      );
    }
    r.canvas.restore();
  });
}

/// 窗格：在面上按格子铺窗，亮窗按 seed 挑（暖白 / 冷白 / 霓虹色），[avoid] 里的地方不铺。
MachiDecal machiWindowsDecal({
  required int seed,
  required double cellW,
  required double cellH,
  double top = 0,
  double bottom = 0,
  double litRatio = 0.45,
  List<Rect> avoid = const <Rect>[],
  Color frameColor = const Color(0xFF2B2F36),
  bool grille = false,
}) {
  return (Canvas c, Size s, MachiFrame f) {
    final double cw = cellW * machiLocalPxPerMeter;
    final double ch = cellH * machiLocalPxPerMeter;
    final int cols = (s.width / cw).floor();
    final int rows = ((s.height - (top + bottom) * machiLocalPxPerMeter) / ch)
        .floor();
    if (cols <= 0 || rows <= 0) return;
    final double x0 = (s.width - cols * cw) / 2;
    final double y0 = top * machiLocalPxPerMeter;
    final Paint p = Paint();
    final Color dark = f.lighting.shade(
      machiHex(0x1a1e26),
      const MachiV3(0, 0, 1),
    );
    const List<int> warm = <int>[
      0xffd79a,
      0xffe9c4,
      0xf6c97f,
      0xcfe6ff,
      0xffb37a,
    ];
    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < cols; col++) {
        final Rect cell = Rect.fromLTWH(
          x0 + col * cw + cw * 0.18,
          y0 + row * ch + ch * 0.2,
          cw * 0.64,
          ch * 0.56,
        );
        bool skip = false;
        for (final Rect a in avoid) {
          if (a.overlaps(
            Rect.fromLTWH(
              cell.left / machiLocalPxPerMeter,
              cell.top / machiLocalPxPerMeter,
              cell.width / machiLocalPxPerMeter,
              cell.height / machiLocalPxPerMeter,
            ),
          )) {
            skip = true;
            break;
          }
        }
        if (skip) continue;
        final double h = machiHash01(seed, row * 97 + col, 0x77);
        final bool lit = h < litRatio;
        if (lit) {
          final Color wc = machiHex(warm[(h * 1000).floor() % warm.length]);
          p.color = machiMix(
            f.lighting.shade(machiHex(0x8c96a6), const MachiV3(0, 0, 1)),
            f.emissive(wc, 0.9 * f.beat.warm),
            machiClamp(f.artificial * 1.15 - 0.25 * f.env.daylight, 0, 1),
          );
        } else {
          p.color = dark;
        }
        c.drawRect(cell, p);
        c.drawRect(
          cell,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = cw * 0.06
            ..color = f.lighting.shade(frameColor, const MachiV3(0, 0, 1)),
        );
        if (grille) {
          final Paint g = Paint()
            ..strokeWidth = cw * 0.03
            ..color = f.lighting.shade(
              machiHex(0x3b3f45),
              const MachiV3(0, 0, 1),
            );
          for (int k = 1; k < 4; k++) {
            c.drawLine(
              Offset(cell.left + cell.width * k / 4, cell.top - ch * 0.05),
              Offset(cell.left + cell.width * k / 4, cell.bottom + ch * 0.05),
              g,
            );
          }
        }
      }
    }
  };
}

/// 品牌三色条（横）。
void machiPaintBrandStripes(Canvas c, Rect r, MachiFrame f, {double k = 1}) {
  final List<Color> b = f.palette.brand;
  final double h = r.height / 3;
  for (int i = 0; i < 3; i++) {
    c.drawRect(
      Rect.fromLTWH(r.left, r.top + i * h, r.width, h + 0.5),
      Paint()..color = f.emissive(b[i], k),
    );
  }
}

/// 主题“图标”：没有 folia 的主题图标，用封面色画一个圆章加首字母。
void machiPaintLogo(Canvas c, Rect r, MachiFrame f, String text) {
  final Offset center = r.center;
  final double radius = r.shortestSide / 2;
  c.drawCircle(
    center,
    radius,
    Paint()
      ..shader = ui.Gradient.linear(r.topLeft, r.bottomRight, <Color>[
        f.emissive(f.palette.brand[0]),
        f.emissive(f.palette.brand[2]),
      ]),
  );
  final String initial = text.isEmpty
      ? '♪'
      : text.characters.first.toUpperCase();
  f.text.drawFitted(
    c,
    initial,
    Rect.fromCircle(center: center, radius: radius * 0.78),
    f.emissive(machiHex(0xffffff)),
    fill: 0.8,
  );
}

/// 开过的车（场景的 dynamicItems 用）。
List<MachiItem> machiTraffic(
  MachiFrame f,
  List<MachiLane> lanes,
  List<Color> colors,
) {
  final MachiCarPass? car = f.car;
  if (car == null || car.lane >= lanes.length) return const <MachiItem>[];
  final MachiLane lane = lanes[car.lane];
  final double t = car.distance / math.max(1e-3, lane.length);
  final double x = machiLerp(lane.fromX, lane.toX, t);
  final double z = machiLerp(lane.fromZ, lane.toZ, t);
  final bool alongX =
      (lane.toX - lane.fromX).abs() > (lane.toZ - lane.fromZ).abs();
  final double forward = alongX
      ? (lane.toX > lane.fromX ? 1 : -1)
      : (lane.toZ > lane.fromZ ? 1 : -1);
  final bool taxi = car.colorIndex % 4 == 0;
  final Color body = taxi
      ? machiHex(0xf2c14e)
      : colors[car.colorIndex % colors.length];
  final MachiGroup g = machiCar(
    x: x,
    z: z,
    alongX: alongX,
    forward: forward,
    body: body,
    length: 3.0,
    width: 1.46,
    height: 1.32,
    clip: true,
  );
  // 前灯在路面上的光斑。
  return <MachiItem>[
    MachiCustom(MachiV3(x, 0, z), (MachiRenderer r) {
      final MachiV3 ahead = alongX
          ? MachiV3(x + forward * 2.6, 0.03, z)
          : MachiV3(x, 0.03, z + forward * 2.6);
      if (ahead.x.abs() < machiBaseHalf && ahead.z.abs() < machiBaseHalf) {
        r.groundPool(
          ahead,
          1.4,
          machiHex(0xfff2d6),
          0.3 * r.frame.look.streetLamps + 0.05,
        );
      }
    }),
    g,
  ];
}
