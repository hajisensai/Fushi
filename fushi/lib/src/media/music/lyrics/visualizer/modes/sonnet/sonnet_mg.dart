/// 商籁每个镜头背后的 MG（motion graphics）图形库（folia `sonnetShotMg.ts` /
/// `sonnetSpatialMgGeometry.ts` / `sonnetBackgroundMgVariants.ts` / `sonnetFixedGeoVariants.ts` /
/// `sonnetBackgroundDecor.ts` / `sonnetIcons.ts`）：HUD 边框（8 种）、几何主图（18 种）、
/// 固定几何（8 种）、漂浮粒子（6 种排布）。全部按镜头种子选变体，坐标以镜头中心为原点。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_graphics.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_program.dart';

typedef _G = SonnetAnimatedGraphics;

/// folia 的几何主图共 100 种（0–17 基础库，18–99 主题插画）；这里移植了基础库 18 种，
/// 种子落到主题区间时按 18 取模回到基础库。
const int sonnetGeoVariantCount = 100;
const int sonnetPortedGeoVariantCount = 18;

int resolveSonnetGeoVariant(int seed) =>
    ((seed % sonnetGeoVariantCount) + sonnetGeoVariantCount) %
    sonnetGeoVariantCount;

int _geoSubVariant(int seed, int count) {
  final int cycle = seed ~/ sonnetGeoVariantCount;
  return ((cycle % count) + count) % count;
}

int resolveSonnetBackgroundMgVariant(int seed) =>
    mixSonnetSeed(seed, 0x9e3779b9) % 8;

int resolveSonnetFixedGeoVariant(int seed) =>
    mixSonnetSeed(seed, 0x85ebca6b) % 8;

int resolveSonnetBackgroundDecorVariant(int seed) =>
    mixSonnetSeed(seed, 0xc2b2ae35) % 6;

// ---------------------------------------------------------------------------
// 立体块
// ---------------------------------------------------------------------------

void _face(_G g, List<Offset> pts, Color c, double alpha) {
  g.moveTo(pts[0].dx, pts[0].dy);
  for (int i = 1; i < pts.length; i++) {
    g.lineTo(pts[i].dx, pts[i].dy);
  }
  g.lineTo(pts[0].dx, pts[0].dy).fill(c, alpha: alpha);
}

void _solidCuboid(
  _G g,
  double x,
  double y,
  double w,
  double h,
  double dx,
  double dy,
  Color c,
  double a,
) {
  final double l = x - w / 2;
  final double r = x + w / 2;
  final double t = y - h / 2;
  final double b = y + h / 2;
  _face(
    g,
    <Offset>[
      Offset(l, t),
      Offset(l + dx, t + dy),
      Offset(r + dx, t + dy),
      Offset(r, t),
    ],
    c,
    a * 0.42,
  );
  _face(
    g,
    <Offset>[
      Offset(r, t),
      Offset(r + dx, t + dy),
      Offset(r + dx, b + dy),
      Offset(r, b),
    ],
    c,
    a * 0.68,
  );
  _face(
    g,
    <Offset>[Offset(l, t), Offset(r, t), Offset(r, b), Offset(l, b)],
    c,
    a * 0.24,
  );
}

void _extruded(
  _G g,
  List<Offset> front,
  double dx,
  double dy,
  Color c,
  double a,
) {
  final List<Offset> back = <Offset>[
    for (final Offset p in front) p.translate(dx, dy),
  ];
  for (int i = 0; i < front.length; i++) {
    final int n = (i + 1) % front.length;
    _face(
      g,
      <Offset>[front[i], back[i], back[n], front[n]],
      c,
      a * (0.34 + (i % 3) * 0.12),
    );
  }
  _face(g, front, c, a * 0.22);
}

void _triPrism(
  _G g,
  double x,
  double y,
  double w,
  double h,
  double dx,
  double dy,
  Color c,
  double a,
) => _extruded(
  g,
  <Offset>[
    Offset(x, y - h / 2),
    Offset(x + w / 2, y + h / 2),
    Offset(x - w / 2, y + h / 2),
  ],
  dx,
  dy,
  c,
  a,
);

void _hexPrism(
  _G g,
  double x,
  double y,
  double w,
  double h,
  double dx,
  double dy,
  Color c,
  double a,
) => _extruded(
  g,
  <Offset>[
    Offset(x - w * 0.25, y - h / 2),
    Offset(x + w * 0.25, y - h / 2),
    Offset(x + w / 2, y),
    Offset(x + w * 0.25, y + h / 2),
    Offset(x - w * 0.25, y + h / 2),
    Offset(x - w / 2, y),
  ],
  dx,
  dy,
  c,
  a,
);

void _trapPrism(
  _G g,
  double x,
  double y,
  double tw,
  double bw,
  double h,
  double dx,
  double dy,
  Color c,
  double a,
) => _extruded(
  g,
  <Offset>[
    Offset(x - tw / 2, y - h / 2),
    Offset(x + tw / 2, y - h / 2),
    Offset(x + bw / 2, y + h / 2),
    Offset(x - bw / 2, y + h / 2),
  ],
  dx,
  dy,
  c,
  a,
);

// ---------------------------------------------------------------------------
// 几何主图（type-impact / fragment-collage）
// ---------------------------------------------------------------------------

/// 画第 [variant] 号几何主图（0–17）。
void drawSonnetGeoVariant(
  _G g,
  int variant,
  double radius,
  double width,
  double height,
  int seed,
  Color primary,
  Color secondary,
) {
  final double r0 = radius;
  switch (variant) {
    case 0:
      g.circle(0, 0, r0 * 0.6).stroke(primary, width: 6, alpha: 0.8);
      g.circle(0, 0, r0 * 0.58).stroke(primary, width: 2, alpha: 0.4);
      for (int i = 0; i < 32; i++) {
        final double a = i / 32 * math.pi * 2;
        final double r1 = r0 * (0.3 + (i % 3) * 0.05);
        final double r2 = r0 * 0.55;
        g
            .moveTo(math.cos(a) * r1, math.sin(a) * r1)
            .lineTo(math.cos(a) * r2, math.sin(a) * r2)
            .stroke(primary, width: 1, alpha: 0.2 + (i % 2) * 0.1);
      }
    case 1:
      final double r = r0 * 0.7;
      void diamond(double k, double w, double a) => g
          .moveTo(0, -r * k)
          .lineTo(r * k, 0)
          .lineTo(0, r * k)
          .lineTo(-r * k, 0)
          .lineTo(0, -r * k)
          .stroke(primary, width: w, alpha: a);
      diamond(1, 6, 0.8);
      diamond(0.96, 2, 0.4);
      diamond(0.4, 1, 0.6);
      g.moveTo(-r, 0).lineTo(r, 0).stroke(primary, width: 1, alpha: 0.3);
      g.moveTo(0, -r).lineTo(0, r).stroke(primary, width: 1, alpha: 0.3);
    case 2:
      void hex(double r, double w, double a) {
        g.moveTo(0, -r);
        for (int j = 1; j <= 6; j++) {
          g.lineTo(
            r * math.sin(j * math.pi / 3),
            -r * math.cos(j * math.pi / 3),
          );
        }
        g.stroke(primary, width: w, alpha: a);
      }
      hex(r0 * 0.6, 6, 0.8);
      hex(r0 * 0.57, 2, 0.4);
      hex(r0 * 0.25, 1, 0.5);
      for (int j = 0; j < 6; j++) {
        final double a = j * math.pi / 3 - math.pi / 6;
        g
            .moveTo(math.cos(a) * r0 * 0.25, math.sin(a) * r0 * 0.25)
            .lineTo(math.cos(a) * r0 * 0.57, math.sin(a) * r0 * 0.57)
            .stroke(primary, width: 2, alpha: 0.4);
      }
    case 3:
      _molecule(g, _geoSubVariant(seed, 3), r0, primary);
    case 4:
      final double ell = r0 * 0.7;
      for (int i = 0; i < 3; i++) {
        final double ang = i * math.pi / 3;
        for (int j = 0; j <= 60; j++) {
          final double t = j * math.pi * 2 / 60;
          final double ex = math.cos(t) * ell;
          final double ey = math.sin(t) * ell * 0.18;
          final double rx = ex * math.cos(ang) - ey * math.sin(ang);
          final double ry = ex * math.sin(ang) + ey * math.cos(ang);
          if (j == 0) {
            g.moveTo(rx, ry);
          } else {
            g.lineTo(rx, ry);
          }
        }
        g.stroke(primary, width: 1, alpha: 0.3);
      }
      g.circle(0, 0, r0 * 0.05).fill(primary, alpha: 0.8);
    case 5:
      final double pr = r0 * 0.25;
      g.circle(0, 0, pr).fill(primary, alpha: 0.15);
      g
          .moveTo(-pr * 0.7, -pr * 0.5)
          .quadraticCurveTo(0, -pr * 0.2, pr * 0.7, -pr * 0.5)
          .stroke(primary, width: 1, alpha: 0.4);
      g
          .moveTo(-pr * 0.9, 0)
          .quadraticCurveTo(0, pr * 0.3, pr * 0.9, 0)
          .stroke(primary, width: 1, alpha: 0.4);
      const double tilt = math.pi / 6;
      void ellipse(double rx, double ry, double w, double a) {
        for (int j = 0; j <= 60; j++) {
          final double t = j * math.pi * 2 / 60;
          final double ex = math.cos(t) * rx;
          final double ey = math.sin(t) * ry;
          final double x = ex * math.cos(tilt) - ey * math.sin(tilt);
          final double y = ex * math.sin(tilt) + ey * math.cos(tilt);
          if (j == 0) {
            g.moveTo(x, y);
          } else {
            g.lineTo(x, y);
          }
        }
        g.stroke(primary, width: w, alpha: a);
      }
      ellipse(r0 * 0.6, r0 * 0.15, 4, 0.5);
      ellipse(r0 * 0.66, r0 * 0.1725, 1, 0.3);
      ellipse(r0 * 0.75, r0 * 0.195, 2, 0.2);
      g.circle(0, 0, r0 * 0.7).stroke(primary, width: 1, alpha: 0.2);
      g
          .circle(
            math.cos(math.pi / 4) * r0 * 0.7,
            math.sin(math.pi / 4) * r0 * 0.7,
            8,
          )
          .fill(primary, alpha: 0.6);
    case 6:
      final double bx = math.max(r0 * 0.92, width * 0.64);
      final double by = math.max(r0 * 0.92, height * 0.64);
      final double w = bx * 1.08;
      final double h = r0 * 0.8;
      final double baseY = r0 * 0.2;
      g
          .circle(0, baseY - h * 0.6, r0 * 0.3)
          .stroke(primary, width: 2, alpha: 0.4);
      for (int i = 0; i < 5; i++) {
        g
            .moveTo(-bx, baseY - h * 0.6 + i * 15)
            .lineTo(bx, baseY - h * 0.6 + i * 15)
            .stroke(primary, width: 1, alpha: 0.3);
      }
      for (int layer = 0; layer < 3; layer++) {
        final double lw = w * (1 + layer * 0.2);
        final double lh = h * (0.5 + layer * 0.25);
        g.moveTo(-lw / 2, baseY);
        for (int i = 1; i < 7; i++) {
          g.lineTo(
            -lw / 2 + (lw / 7) * i,
            baseY -
                lh * (0.3 + 0.7 * math.sin(seed + layer * 11 + i * 7.0).abs()),
          );
        }
        g
            .lineTo(lw / 2, baseY)
            .stroke(primary, width: 3.0 - layer, alpha: 0.6 - layer * 0.15);
      }
      g
          .moveTo(-w, baseY)
          .lineTo(w, baseY)
          .stroke(primary, width: 4, alpha: 0.8);
      for (int i = 0; i < 5; i++) {
        final double gy = baseY + math.pow(i, 1.5) * 12;
        g
            .moveTo(-w, gy)
            .lineTo(w, gy)
            .stroke(primary, width: 1, alpha: 0.4 - i * 0.08);
      }
      for (int i = -4; i <= 4; i++) {
        g
            .moveTo(i * r0 * 0.2, baseY)
            .lineTo(i * bx * 0.32, by)
            .stroke(primary, width: 1, alpha: 0.3);
      }
    case 7:
      for (int i = 1; i <= 6; i++) {
        g
            .circle(0, 0, r0 * 0.15 * i)
            .stroke(
              primary,
              width: i.isEven ? 2 : 1,
              alpha: 0.2 + (i % 3) * 0.1,
            );
      }
      g
          .moveTo(-r0 * 0.9, 0)
          .lineTo(r0 * 0.9, 0)
          .stroke(primary, width: 1, alpha: 0.4);
      g
          .moveTo(0, -r0 * 0.9)
          .lineTo(0, r0 * 0.9)
          .stroke(primary, width: 1, alpha: 0.4);
      g
          .moveTo(0, 0)
          .arc(0, 0, r0 * 0.75, 0, math.pi / 4)
          .lineTo(0, 0)
          .fill(primary, alpha: 0.1);
      final double ro = r0 * 0.8;
      for (int i = 0; i < 72; i++) {
        final double a = i / 72 * math.pi * 2;
        final double len = i % 18 == 0 ? 20 : (i % 6 == 0 ? 10 : 5);
        g
            .moveTo(math.cos(a) * ro, math.sin(a) * ro)
            .lineTo(math.cos(a) * (ro + len), math.sin(a) * (ro + len))
            .stroke(primary, width: 1, alpha: 0.4);
      }
      final double la = (seed % 360) * math.pi / 180;
      final double lx = math.cos(la) * r0 * 0.45;
      final double ly = math.sin(la) * r0 * 0.45;
      g.rect(lx - 15, ly - 15, 30, 30).stroke(primary, width: 2, alpha: 0.8);
      g
          .moveTo(lx, ly - 20)
          .lineTo(lx, ly + 20)
          .stroke(primary, width: 1, alpha: 0.6);
      g
          .moveTo(lx - 20, ly)
          .lineTo(lx + 20, ly)
          .stroke(primary, width: 1, alpha: 0.6);
    case 8:
      final double fw = r0 * 0.85;
      final double fh = r0 * 0.65;
      final double bs = r0 * 0.15;
      void bracket(double cx, double cy, double sx, double sy) {
        g
            .moveTo(cx - sx * bs, cy)
            .lineTo(cx, cy)
            .lineTo(cx, cy - sy * bs)
            .stroke(primary, width: 3, alpha: 0.7);
        g
            .moveTo(cx - sx * bs * 0.8, cy - sy * 8)
            .lineTo(cx - sx * 8, cy - sy * 8)
            .lineTo(cx - sx * 8, cy - sy * bs * 0.8)
            .stroke(primary, width: 1, alpha: 0.4);
      }
      bracket(-fw, -fh, -1, -1);
      bracket(fw, -fh, 1, -1);
      bracket(-fw, fh, -1, 1);
      bracket(fw, fh, 1, 1);
      for (double i = -fw + 20; i < fw - 20; i += 20) {
        final double len = (i % 60).abs() < 1e-6 ? 12 : 6;
        g
            .moveTo(i, -fh)
            .lineTo(i, -fh - len)
            .stroke(primary, width: 1, alpha: 0.5);
        g
            .moveTo(i, fh)
            .lineTo(i, fh + len)
            .stroke(primary, width: 1, alpha: 0.5);
      }
      g.circle(0, 0, r0 * 0.1).stroke(primary, width: 2, alpha: 0.4);
      g
          .moveTo(-r0 * 0.15, 0)
          .lineTo(r0 * 0.15, 0)
          .stroke(primary, width: 1, alpha: 0.4);
      g
          .moveTo(0, -r0 * 0.15)
          .lineTo(0, r0 * 0.15)
          .stroke(primary, width: 1, alpha: 0.4);
      g.rect(-fw, -fh + 20, 10, 40).fill(primary, alpha: 0.5);
      g.rect(-fw, -fh + 65, 10, 15).fill(primary, alpha: 0.3);
      g.rect(fw - 10, fh - 60, 10, 40).fill(primary, alpha: 0.5);
    case 9:
      void cube(double cx, double cy, double s, double a) {
        final double dy = s * 0.5;
        final double dx = s * 0.866;
        g
            .moveTo(cx, cy - s)
            .lineTo(cx + dx, cy - dy)
            .lineTo(cx, cy)
            .lineTo(cx - dx, cy - dy)
            .lineTo(cx, cy - s)
            .fill(primary, alpha: a * 0.15);
        g
            .moveTo(cx, cy)
            .lineTo(cx + dx, cy - dy)
            .lineTo(cx + dx, cy + s - dy)
            .lineTo(cx, cy + s)
            .lineTo(cx, cy)
            .fill(primary, alpha: a * 0.3);
        g
            .moveTo(cx, cy)
            .lineTo(cx - dx, cy - dy)
            .lineTo(cx - dx, cy + s - dy)
            .lineTo(cx, cy + s)
            .lineTo(cx, cy)
            .fill(primary, alpha: a * 0.05);
      }
      cube(0, 0, r0 * 0.35, 0.8);
      cube(r0 * 0.4, -r0 * 0.15, r0 * 0.2, 0.5);
      cube(-r0 * 0.45, r0 * 0.25, r0 * 0.25, 0.6);
      cube(0, r0 * 0.45, r0 * 0.15, 0.4);
      g
          .moveTo(0, 0)
          .lineTo(r0 * 0.4, -r0 * 0.15)
          .stroke(primary, width: 1, alpha: 0.3);
      g
          .moveTo(0, 0)
          .lineTo(-r0 * 0.45, r0 * 0.25)
          .stroke(primary, width: 1, alpha: 0.3);
    case 10:
      g.circle(0, 0, r0 * 0.75).stroke(primary, width: 1, alpha: 0.2);
      g.circle(0, 0, r0 * 0.73).stroke(primary, width: 2, alpha: 0.1);
      final List<Offset> nodes = <Offset>[
        for (int i = 0; i < 18; i++)
          () {
            final double r = r0 * (0.1 + ((seed * 17 + i * 23) % 65) / 100);
            final double a = ((seed * 11 + i * 37) % 360) * math.pi / 180;
            return Offset(math.cos(a) * r, math.sin(a) * r);
          }(),
      ];
      for (int i = 0; i < nodes.length; i++) {
        g.circle(nodes[i].dx, nodes[i].dy, 3).fill(primary, alpha: 0.7);
        g
            .circle(nodes[i].dx, nodes[i].dy, 6)
            .stroke(primary, width: 1, alpha: 0.3);
        for (int j = i + 1; j < nodes.length; j++) {
          final double d = (nodes[i] - nodes[j]).distance;
          if (d < r0 * 0.45) {
            g
                .moveTo(nodes[i].dx, nodes[i].dy)
                .lineTo(nodes[j].dx, nodes[j].dy)
                .stroke(primary, width: 1, alpha: 0.4 * (1 - d / (r0 * 0.45)));
          }
        }
      }
    case 11:
      final double mr = r0 * 0.4;
      g
          .moveTo(0, -mr)
          .arc(0, 0, mr, -math.pi / 2, math.pi / 2)
          .quadraticCurveTo(-mr * 0.4, 0, 0, -mr)
          .fill(primary, alpha: 0.8);
      g.circle(0, 0, mr).stroke(primary, width: 1, alpha: 0.3);
      final double orbit = r0 * 0.65;
      g.circle(0, 0, orbit).stroke(primary, width: 1, alpha: 0.2);
      for (int i = 0; i < 8; i++) {
        final double a = i / 8 * math.pi * 2 - math.pi / 2;
        final double mx = math.cos(a) * orbit;
        final double my = math.sin(a) * orbit;
        g.circle(mx, my, 8).stroke(primary, width: 1, alpha: 0.5);
        if (i == 4) {
          g.circle(mx, my, 6).fill(primary, alpha: 0.8);
        } else if (i != 0) {
          g
              .moveTo(mx, my - 6)
              .arc(mx, my, 6, -math.pi / 2, math.pi / 2, anticlockwise: i > 4)
              .lineTo(mx, my - 6)
              .fill(primary, alpha: 0.5);
        }
      }
      void star(double sx, double sy, double sr) => g
          .moveTo(sx, sy - sr)
          .lineTo(sx + sr * 0.2, sy - sr * 0.2)
          .lineTo(sx + sr, sy)
          .lineTo(sx + sr * 0.2, sy + sr * 0.2)
          .lineTo(sx, sy + sr)
          .lineTo(sx - sr * 0.2, sy + sr * 0.2)
          .lineTo(sx - sr, sy)
          .lineTo(sx - sr * 0.2, sy - sr * 0.2)
          .fill(primary, alpha: 0.7);
      star(-r0 * 0.4, -r0 * 0.5, 12);
      star(r0 * 0.5, -r0 * 0.3, 8);
      star(-r0 * 0.2, r0 * 0.5, 15);
    case 12:
      final double petalLen = r0 * 0.5;
      void petal(double angle, double length, double w, double a) {
        final double ex = math.cos(angle) * length;
        final double ey = math.sin(angle) * length;
        final double cd = length * 0.5;
        g
            .moveTo(0, 0)
            .quadraticCurveTo(
              math.cos(angle - w) * cd,
              math.sin(angle - w) * cd,
              ex,
              ey,
            )
            .quadraticCurveTo(
              math.cos(angle + w) * cd,
              math.sin(angle + w) * cd,
              0,
              0,
            )
            .stroke(primary, width: 1, alpha: a);
      }
      for (int layer = 0; layer < 4; layer++) {
        final int petals = 8 + layer * 4;
        for (int i = 0; i < petals; i++) {
          petal(
            i / petals * math.pi * 2 + layer * (math.pi / petals),
            petalLen * (1 - layer * 0.2),
            0.3 - layer * 0.05,
            0.8 - layer * 0.15,
          );
        }
      }
      g.circle(0, 0, r0 * 0.08).stroke(primary, width: 2, alpha: 0.8);
      g.circle(0, 0, r0 * 0.03).fill(primary, alpha: 0.9);
      final double stemR = r0 * 0.65;
      for (int i = 0; i < 3; i++) {
        final double s = i / 3 * math.pi * 2;
        g
            .moveTo(math.cos(s) * stemR, math.sin(s) * stemR)
            .bezierCurveTo(
              math.cos(s + 1) * stemR * 1.2,
              math.sin(s + 1) * stemR * 1.2,
              math.cos(s + 2) * stemR * 0.8,
              math.sin(s + 2) * stemR * 0.8,
              math.cos(s + 3) * stemR,
              math.sin(s + 3) * stemR,
            )
            .stroke(primary, width: 1, alpha: 0.4);
        g
            .circle(
              math.cos(s + 1.5) * stemR * 1.05,
              math.sin(s + 1.5) * stemR * 1.05,
              4,
            )
            .fill(primary, alpha: 0.6);
      }
    case 13:
      final double sr = r0 * 0.25;
      g.circle(0, 0, sr).stroke(primary, width: 1.5, alpha: 0.35);
      for (int i = 0; i < 6; i++) {
        final double a = i / 6 * math.pi * 2;
        g
            .circle(math.cos(a) * sr, math.sin(a) * sr, sr)
            .stroke(primary, width: 1.5, alpha: 0.2);
      }
      for (int i = 0; i < 12; i++) {
        final double a = i / 12 * math.pi * 2;
        final double d = i.isEven ? sr * 2 : sr * math.sqrt(3);
        g
            .circle(math.cos(a) * d, math.sin(a) * d, sr)
            .stroke(secondary, width: 1, alpha: 0.1);
      }
      g.circle(0, 0, sr * 3).stroke(primary, width: 1.5, alpha: 0.2);
      g.circle(0, 0, sr * 3.1).stroke(secondary, width: 1, alpha: 0.08);
      for (int i = 0; i < 12; i++) {
        final double a = i / 12 * math.pi * 2;
        g
            .moveTo(math.cos(a) * sr * 0.5, math.sin(a) * sr * 0.5)
            .lineTo(math.cos(a) * sr * 3, math.sin(a) * sr * 3)
            .stroke(secondary, width: 1, alpha: 0.05);
      }
    case 14:
      final double d = seed.isEven ? 1 : -1;
      _solidCuboid(
        g,
        r0 * 0.18 * d,
        r0 * 0.03,
        r0 * 0.62,
        r0 * 0.7,
        r0 * 0.22 * d,
        -r0 * 0.16,
        primary,
        0.34,
      );
      _solidCuboid(
        g,
        -r0 * 0.48 * d,
        r0 * 0.24,
        r0 * 0.28,
        r0 * 0.38,
        r0 * 0.12 * d,
        -r0 * 0.09,
        primary,
        0.24,
      );
      _solidCuboid(
        g,
        r0 * 0.55 * d,
        -r0 * 0.3,
        r0 * 0.2,
        r0 * 0.26,
        r0 * 0.09 * d,
        -r0 * 0.07,
        primary,
        0.2,
      );
    case 15:
      final double d = seed.isEven ? 1 : -1;
      _triPrism(
        g,
        -r0 * 0.12 * d,
        r0 * 0.02,
        r0 * 0.72,
        r0 * 0.68,
        r0 * 0.18 * d,
        -r0 * 0.13,
        primary,
        0.34,
      );
      _triPrism(
        g,
        r0 * 0.48 * d,
        r0 * 0.26,
        r0 * 0.28,
        r0 * 0.25,
        -r0 * 0.08 * d,
        -r0 * 0.06,
        primary,
        0.22,
      );
      _triPrism(
        g,
        -r0 * 0.5 * d,
        -r0 * 0.3,
        r0 * 0.2,
        r0 * 0.18,
        r0 * 0.06 * d,
        -r0 * 0.05,
        primary,
        0.18,
      );
    case 16:
      final double d = seed.isEven ? 1 : -1;
      _hexPrism(
        g,
        r0 * 0.12 * d,
        0,
        r0 * 0.68,
        r0 * 0.72,
        r0 * 0.2 * d,
        -r0 * 0.14,
        primary,
        0.32,
      );
      _hexPrism(
        g,
        -r0 * 0.48 * d,
        r0 * 0.27,
        r0 * 0.25,
        r0 * 0.28,
        r0 * 0.07 * d,
        -r0 * 0.05,
        primary,
        0.2,
      );
      _hexPrism(
        g,
        r0 * 0.52 * d,
        -r0 * 0.3,
        r0 * 0.18,
        r0 * 0.2,
        -r0 * 0.06 * d,
        -r0 * 0.045,
        primary,
        0.17,
      );
    default:
      final double d = seed.isEven ? 1 : -1;
      _trapPrism(
        g,
        r0 * 0.12 * d,
        r0 * 0.04,
        r0 * 0.3,
        r0 * 0.68,
        r0 * 0.62,
        r0 * 0.18 * d,
        -r0 * 0.13,
        primary,
        0.34,
      );
      _trapPrism(
        g,
        -r0 * 0.42 * d,
        r0 * 0.28,
        r0 * 0.2,
        r0 * 0.38,
        r0 * 0.22,
        r0 * 0.08 * d,
        -r0 * 0.06,
        primary,
        0.21,
      );
      _trapPrism(
        g,
        r0 * 0.5 * d,
        -r0 * 0.3,
        r0 * 0.2,
        r0 * 0.12,
        r0 * 0.22,
        -r0 * 0.06 * d,
        -r0 * 0.05,
        primary,
        0.18,
      );
  }
}

void _molecule(_G g, int sub, double radius, Color primary) {
  final double hexR = radius * 0.22;
  if (sub == 0) {
    void benzene(double cx, double cy, double scale) {
      final double r = hexR * scale;
      g.moveTo(cx, cy - r);
      for (int j = 1; j <= 6; j++) {
        g.lineTo(
          cx + r * math.sin(j * math.pi / 3),
          cy - r * math.cos(j * math.pi / 3),
        );
      }
      g.stroke(primary, width: 3, alpha: 0.8);
      for (int j = 0; j < 6; j += 2) {
        final double ir = r * 0.82;
        g
            .moveTo(
              cx + ir * math.sin(j * math.pi / 3),
              cy - ir * math.cos(j * math.pi / 3),
            )
            .lineTo(
              cx + ir * math.sin((j + 1) * math.pi / 3),
              cy - ir * math.cos((j + 1) * math.pi / 3),
            )
            .stroke(primary, width: 2, alpha: 0.5);
      }
    }

    final double rMain = hexR * 1.2;
    benzene(0, 0, 1.2);
    final double dx = math.sin(math.pi / 3) * rMain * 2;
    benzene(dx, 0, 1.2);
    benzene(-math.sin(math.pi / 6) * dx, -math.cos(math.pi / 6) * dx, 1.2);
    g
        .moveTo(0, rMain)
        .lineTo(0, rMain + radius * 0.2)
        .lineTo(radius * 0.15, rMain + radius * 0.35)
        .stroke(primary, width: 2, alpha: 0.6);
  } else if (sub == 1) {
    g.moveTo(0, -hexR);
    for (int j = 1; j <= 6; j++) {
      g.lineTo(
        hexR * math.sin(j * math.pi / 3),
        -hexR * math.cos(j * math.pi / 3),
      );
    }
    g.stroke(primary, width: 3, alpha: 0.8);
    void bond(int a, int b) => g
        .moveTo(
          hexR * 0.8 * math.sin(a * math.pi / 3),
          -hexR * 0.8 * math.cos(a * math.pi / 3),
        )
        .lineTo(
          hexR * 0.8 * math.sin(b * math.pi / 3),
          -hexR * 0.8 * math.cos(b * math.pi / 3),
        )
        .stroke(primary, width: 2, alpha: 0.5);
    bond(1, 2);
    bond(4, 5);
    final double px1 = hexR * math.sqrt(3) / 2;
    final double py1 = -hexR / 2;
    final double py2 = hexR / 2;
    final double pmx = px1 + hexR * 1.2;
    g
        .moveTo(px1, py1)
        .lineTo(px1 + hexR * 0.8, py1 - hexR * 0.1)
        .lineTo(pmx, 0)
        .lineTo(px1 + hexR * 0.8, py2 + hexR * 0.1)
        .lineTo(px1, py2)
        .stroke(primary, width: 3, alpha: 0.8);
    void branch(double sx, double sy, double a, double len, bool node) {
      final double ex = sx + math.cos(a) * len;
      final double ey = sy + math.sin(a) * len;
      g.moveTo(sx, sy).lineTo(ex, ey).stroke(primary, width: 2, alpha: 0.6);
      if (node) g.circle(ex, ey, 6).stroke(primary, width: 2, alpha: 0.8);
    }

    branch(0, -hexR, -math.pi / 2, radius * 0.15, true);
    branch(-px1, hexR / 2, math.pi * 0.8, radius * 0.2, true);
    branch(-px1, -hexR / 2, -math.pi * 0.8, radius * 0.15, false);
    branch(pmx, 0, 0, radius * 0.18, false);
    branch(pmx + radius * 0.18, 0, math.pi / 4, radius * 0.1, true);
  } else {
    final double seg = radius * 0.18;
    const int steps = 7;
    final List<Offset> pts = <Offset>[
      Offset(-seg * (steps / 2) * math.cos(math.pi / 6), 0),
    ];
    double cx = pts.first.dx;
    for (int i = 0; i < steps; i++) {
      cx += seg * math.cos(math.pi / 6);
      pts.add(Offset(cx, (i.isEven ? 1 : -1) * seg * math.sin(math.pi / 6)));
    }
    g.moveTo(pts[0].dx, pts[0].dy);
    for (int i = 1; i <= steps; i++) {
      g.lineTo(pts[i].dx, pts[i].dy);
    }
    g.stroke(primary, width: 3, alpha: 0.8);
    final double nx = -math.sin(math.pi / 6) * 6;
    final double ny = math.cos(math.pi / 6) * 6;
    g
        .moveTo(pts[1].dx + nx, pts[1].dy + ny)
        .lineTo(pts[2].dx + nx, pts[2].dy + ny)
        .stroke(primary, width: 2, alpha: 0.5);
    for (int i = 1; i < steps; i++) {
      final double a = i.isEven ? math.pi / 2 : -math.pi / 2;
      final double bx = pts[i].dx;
      final double by = pts[i].dy + math.sin(a) * seg * 0.6;
      g
          .moveTo(pts[i].dx, pts[i].dy)
          .lineTo(bx, by)
          .stroke(primary, width: 2, alpha: 0.5);
      if (i.isOdd) {
        g.circle(bx, by, 5).stroke(primary, width: 2, alpha: 0.8);
      } else {
        g
            .moveTo(bx, by)
            .lineTo(bx + seg * 0.5, by - seg * 0.3)
            .stroke(primary, width: 2, alpha: 0.5);
      }
    }
  }
}

/// 几何主图是否保持直立（其余按种子任意转角；HUD 框按 90° 转）。
double resolveSonnetGeoRotation(int variant, int seed) {
  const List<int> upright = <int>[6, 8, 9, 14, 15, 16, 17];
  if (!upright.contains(variant)) return ((seed * 13) % 360) * (math.pi / 180);
  if (variant == 8) return _geoSubVariant(seed, 4) * (math.pi / 2);
  return 0;
}

// ---------------------------------------------------------------------------
// HUD 边框（bg 层）
// ---------------------------------------------------------------------------

void _cross(_G g, double x, double y, double s, Color c, [double a = 0.5]) {
  g.moveTo(x - s, y - s).lineTo(x + s, y + s).stroke(c, width: 1, alpha: a);
  g.moveTo(x + s, y - s).lineTo(x - s, y + s).stroke(c, width: 1, alpha: a);
}

/// 第 [variant] 号 HUD 边框（8 种，同一组边距，只换角标 / 刻度 / 弧 / 点）。
void drawSonnetBackgroundHud(
  _G g,
  int variant,
  double width,
  double height,
  int seed,
  Color primary,
  Color secondary,
) {
  final double hw = width / 2;
  final double hh = height / 2;
  final double mx = width * 0.05;
  final double my = height * 0.05;
  switch (variant % 8) {
    case 1:
      final double arm = math.min(hw, hh) * 0.08;
      const double inset = 6;
      final List<List<double>> corners = <List<double>>[
        <double>[-hw + mx, -hh + my, 1, 1],
        <double>[hw - mx, -hh + my, -1, 1],
        <double>[-hw + mx, hh - my, 1, -1],
        <double>[hw - mx, hh - my, -1, -1],
      ];
      for (int i = 0; i < 4; i++) {
        final double cx = corners[i][0],
            cy = corners[i][1],
            sx = corners[i][2],
            sy = corners[i][3];
        g
            .moveTo(cx + sx * arm, cy)
            .lineTo(cx, cy)
            .lineTo(cx, cy + sy * arm)
            .stroke(primary, width: 2, alpha: 0.55);
        g
            .moveTo(cx + sx * (arm + inset), cy + sy * inset)
            .lineTo(cx + sx * inset, cy + sy * inset)
            .lineTo(cx + sx * inset, cy + sy * (arm + inset))
            .stroke(primary, width: 1, alpha: 0.25);
        if (i.isEven) {
          g
              .rect(cx + sx * arm * 0.4 - 2, cy + sy * arm * 0.4 - 2, 4, 4)
              .fill(secondary, alpha: 0.6);
        }
      }
      final double ry = hh - my + inset;
      g
          .moveTo(-hw + mx + arm + 12, ry)
          .lineTo(hw - mx - arm - 12, ry)
          .stroke(primary, width: 1, alpha: 0.3);
      final double span = (hw - mx - arm - 12) * 2;
      for (int i = 0; i <= 24; i++) {
        final double x = -hw + mx + arm + 12 + span * i / 24;
        final bool long = i % 6 == 0;
        g
            .moveTo(x, ry)
            .lineTo(x, ry - (long ? 8 : 4))
            .stroke(
              long ? secondary : primary,
              width: 1,
              alpha: long ? 0.55 : 0.3,
            );
      }
      for (int i = 0; i < 5; i++) {
        final double y =
            -hh + my + arm + 14 + i * ((hh - my - arm - 14) * 2) / 5;
        g.circle(-hw + mx - 4, y, 1.5).fill(primary, alpha: 0.35);
        g.circle(hw - mx + 4, y + (seed % 7), 1.5).fill(primary, alpha: 0.35);
      }
    case 2:
      final double left = -hw + mx;
      final double right = hw - mx;
      for (final double dir in const <double>[-1, 1]) {
        final double y = dir * (hh - my);
        g
            .moveTo(left, y)
            .lineTo(right, y)
            .stroke(primary, width: 2, alpha: 0.45);
        g
            .moveTo(left, y + dir * 6)
            .lineTo(right, y + dir * 6)
            .stroke(primary, width: 1, alpha: 0.2);
        g.rect(left, y - 3, 14, 6).fill(secondary, alpha: 0.55);
        g.rect(right - 14, y - 3, 14, 6).fill(secondary, alpha: 0.55);
        for (int i = 1; i < 18; i++) {
          if (i % 3 != 0) continue;
          final double x = left + (right - left) * i / 18;
          g
              .moveTo(x, y)
              .lineTo(x, y + dir * 6)
              .stroke(primary, width: 1, alpha: 0.35);
        }
      }
      _cross(g, 0, -hh + my, 4, primary, 0.5);
      g
          .moveTo(-6, hh - my - 14)
          .lineTo(0, hh - my - 8)
          .lineTo(6, hh - my - 14)
          .stroke(secondary, width: 1, alpha: 0.6);
    case 3:
      final double corner = math.min(hw, hh) * 0.12;
      final List<List<double>> cs = <List<double>>[
        <double>[-hw + mx, -hh + my, 1, 1],
        <double>[hw - mx, -hh + my, -1, 1],
        <double>[-hw + mx, hh - my, 1, -1],
        <double>[hw - mx, hh - my, -1, -1],
      ];
      for (int i = 0; i < 4; i++) {
        final double cx = cs[i][0], cy = cs[i][1], sx = cs[i][2], sy = cs[i][3];
        g
            .moveTo(cx + sx * corner, cy)
            .lineTo(cx, cy)
            .lineTo(cx, cy + sy * corner)
            .lineTo(cx + sx * corner, cy)
            .stroke(primary, width: 1.5, alpha: 0.5);
        g
            .moveTo(cx + sx * corner * 0.55, cy)
            .lineTo(cx, cy + sy * corner * 0.55)
            .stroke(i.isEven ? secondary : primary, width: 1, alpha: 0.4);
        g
            .moveTo(cx + sx * corner * 0.3, cy)
            .lineTo(cx, cy + sy * corner * 0.3)
            .stroke(primary, width: 1, alpha: 0.25);
      }
      final double by = hh - my - 12;
      g
          .moveTo(-hw + mx + corner + 10, by)
          .lineTo(hw - mx - corner - 10, by)
          .stroke(primary, width: 1, alpha: 0.3);
      for (int i = 0; i < 5; i++) {
        final double x = -hw + mx + corner + 30 + i * 26;
        final double s = i == 2 ? 5 : 3;
        g
            .moveTo(x, by - s)
            .lineTo(x + s, by)
            .lineTo(x, by + s)
            .lineTo(x - s, by)
            .lineTo(x, by - s)
            .stroke(i == 2 ? secondary : primary, width: 1, alpha: 0.55);
      }
    case 4:
      for (int i = 0; i < 14; i++) {
        final double y = -hh + my + 10 + i * ((hh - my - 10) * 2) / 13;
        final bool strong = i % 4 == 0;
        g
            .circle(-hw + mx, y, strong ? 2.4 : 1.4)
            .fill(strong ? secondary : primary, alpha: strong ? 0.6 : 0.3);
        g
            .circle(hw - mx, y, strong ? 2.4 : 1.4)
            .fill(strong ? secondary : primary, alpha: strong ? 0.6 : 0.3);
      }
      g.moveTo(-18, 0).lineTo(18, 0).stroke(primary, width: 1, alpha: 0.22);
      g.moveTo(0, -18).lineTo(0, 18).stroke(primary, width: 1, alpha: 0.22);
      g.circle(0, 0, 6).stroke(primary, width: 1, alpha: 0.3);
      final double by = hh - my - 8;
      g
          .moveTo(-hw + mx + 16, by)
          .lineTo(hw - mx - 16, by)
          .stroke(primary, width: 1, alpha: 0.3);
      _cross(g, -hw + mx + 8, by, 3, primary, 0.5);
      _cross(g, hw - mx - 8, by, 3, primary, 0.5);
    case 5:
      final double l = -hw + mx, r = hw - mx, t = -hh + my, b = hh - my;
      final double gx = (r - l) * 0.18, gy = (b - t) * 0.22;
      final double cx = (l + r) / 2, cy = (t + b) / 2;
      void seg(double x1, double y1, double x2, double y2) => g
          .moveTo(x1, y1)
          .lineTo(x2, y2)
          .stroke(primary, width: 2, alpha: 0.45);
      seg(l, t, cx - gx / 2, t);
      seg(cx + gx / 2, t, r, t);
      seg(l, b, cx - gx / 2, b);
      seg(cx + gx / 2, b, r, b);
      seg(l, t, l, cy - gy / 2);
      seg(l, cy + gy / 2, l, b);
      seg(r, t, r, cy - gy / 2);
      seg(r, cy + gy / 2, r, b);
      g
          .rect(l + 7, t + 7, r - l - 14, b - t - 14)
          .stroke(primary, width: 1, alpha: 0.18);
      final List<Offset> cornersPts = <Offset>[
        Offset(l, t),
        Offset(r, t),
        Offset(l, b),
        Offset(r, b),
      ];
      for (int i = 0; i < 4; i++) {
        g
            .rect(cornersPts[i].dx - 3, cornersPts[i].dy - 3, 6, 6)
            .fill(i.isEven ? secondary : primary, alpha: 0.6);
      }
      g
          .moveTo(cx - 5, t)
          .lineTo(cx + 5, t)
          .stroke(secondary, width: 3, alpha: 0.5);
      g
          .moveTo(cx - 5, b)
          .lineTo(cx + 5, b)
          .stroke(secondary, width: 3, alpha: 0.5);
    case 6:
      final double l = -hw + mx, r = hw - mx, t = -hh + my, b = hh - my;
      for (int i = 0; i <= 32; i++) {
        final double x = l + (r - l) * i / 32;
        final bool major = i % 8 == 0;
        final double len = major ? 12 : (i % 4 == 0 ? 7 : 4);
        final Color c = major ? secondary : primary;
        g
            .moveTo(x, t)
            .lineTo(x, t + len)
            .stroke(c, width: 1, alpha: major ? 0.55 : 0.32);
        g
            .moveTo(x, b)
            .lineTo(x, b - len)
            .stroke(c, width: 1, alpha: major ? 0.55 : 0.32);
      }
      for (int i = 0; i <= 18; i++) {
        final double y = t + (b - t) * i / 18;
        final bool major = i % 6 == 0;
        final double len = major ? 12 : (i % 3 == 0 ? 7 : 4);
        final Color c = major ? secondary : primary;
        g
            .moveTo(l, y)
            .lineTo(l + len, y)
            .stroke(c, width: 1, alpha: major ? 0.55 : 0.32);
        g
            .moveTo(r, y)
            .lineTo(r - len, y)
            .stroke(c, width: 1, alpha: major ? 0.55 : 0.32);
      }
      g.circle(0, 0, 10).stroke(primary, width: 1, alpha: 0.25);
      g.circle(0, 0, 3).fill(secondary, alpha: 0.4);
    case 7:
      final double arcR = math.min(hw, hh) * 0.11;
      final List<List<double>> cs = <List<double>>[
        <double>[-hw + mx, -hh + my, 0, math.pi / 2],
        <double>[hw - mx, -hh + my, math.pi / 2, math.pi],
        <double>[hw - mx, hh - my, math.pi, math.pi * 1.5],
        <double>[-hw + mx, hh - my, math.pi * 1.5, math.pi * 2],
      ];
      void arcFrom(double cx, double cy, double r, double s, double e) => g
          .moveTo(cx + math.cos(s) * r, cy + math.sin(s) * r)
          .arc(cx, cy, r, s, e);
      for (int i = 0; i < 4; i++) {
        final double cx = cs[i][0], cy = cs[i][1], s = cs[i][2], e = cs[i][3];
        arcFrom(cx, cy, arcR, s, e);
        g.stroke(primary, width: 2, alpha: 0.5);
        arcFrom(cx, cy, arcR * 0.72, s, e);
        g.stroke(primary, width: 1, alpha: 0.25);
        final double mid = (s + e) / 2;
        g
            .circle(cx + math.cos(mid) * arcR, cy + math.sin(mid) * arcR, 2)
            .fill(i.isEven ? secondary : primary, alpha: 0.6);
      }
      g.circle(0, -hh + my, 2).fill(primary, alpha: 0.45);
      g.circle(-hw + mx, 0, 2).fill(primary, alpha: 0.45);
      g.circle(hw - mx, 0, 2).fill(primary, alpha: 0.45);
      final double gaugeY = hh - my + arcR * 0.4;
      final double gaugeR = math.min(hw, hh) * 0.16;
      arcFrom(0, gaugeY, gaugeR, math.pi, math.pi * 2);
      g.stroke(primary, width: 1.5, alpha: 0.4);
      for (int i = 0; i <= 8; i++) {
        final double a = math.pi + i / 8 * math.pi;
        g
            .moveTo(
              math.cos(a) * (gaugeR - 5),
              gaugeY + math.sin(a) * (gaugeR - 5),
            )
            .lineTo(math.cos(a) * gaugeR, gaugeY + math.sin(a) * gaugeR)
            .stroke(i % 4 == 0 ? secondary : primary, width: 1, alpha: 0.45);
      }
      final double needle = math.pi + (seed % 100) / 100 * math.pi;
      g
          .moveTo(0, gaugeY)
          .lineTo(
            math.cos(needle) * (gaugeR - 8),
            gaugeY + math.sin(needle) * (gaugeR - 8),
          )
          .stroke(secondary, width: 2, alpha: 0.6);
      g.circle(0, gaugeY, 2.5).fill(primary, alpha: 0.7);
    default:
      _cross(g, -hw + mx, -hh + my, 4, primary, 0.4);
      _cross(g, hw - mx, -hh + my, 4, primary, 0.4);
      _cross(g, -hw + mx, hh - my, 4, primary, 0.4);
      _cross(g, hw - mx, hh - my, 4, primary, 0.4);
      for (int i = 0; i < 8; i++) {
        _cross(g, -hw + mx, -hh + my + i * 20 + 30, 3, primary, 0.3);
      }
      final double by = hh - my - 10;
      g
          .moveTo(-hw + mx + 20, by)
          .lineTo(hw - mx - 20, by)
          .stroke(primary, width: 1, alpha: 0.3);
      _cross(g, -hw + mx + 10, by, 3, primary, 0.5);
      _cross(g, -hw + mx + 30, by, 3, primary, 0.5);
      _cross(g, hw - mx - 10, by, 3, primary, 0.5);
      g.circle(0, by, 2).fill(secondary, alpha: 0.8);
  }
}

/// editorial-column 的格网 / quiet-tableau 与 mask-reveal 的零星方块（同在 bg 层）。
void drawSonnetShotKindBackground(
  _G g,
  SonnetShotKind kind,
  double width,
  double height,
  int seed,
  Color primary,
) {
  final double hw = width / 2;
  final double hh = height / 2;
  if (kind == SonnetShotKind.editorialColumn) {
    for (int i = 1; i <= 6; i++) {
      final double x = -hw + width * (i / 7);
      g.moveTo(x, -hh).lineTo(x, hh).stroke(primary, width: 1, alpha: 0.15);
    }
    for (int i = 1; i <= 4; i++) {
      final double y = -hh + height * (i / 5);
      g.moveTo(-hw, y).lineTo(hw, y).stroke(primary, width: 1, alpha: 0.15);
    }
    g
        .rect(-hw + width * 0.2, -hh + height * 0.2, width * 0.6, height * 0.6)
        .stroke(primary, width: 4, alpha: 0.5);
  } else if (kind != SonnetShotKind.typeImpact &&
      kind != SonnetShotKind.fragmentCollage) {
    for (int i = 0; i < 5; i++) {
      final double size = 10.0 + (seed % (i + 1)) * 5;
      g
          .rect(
            -hw + width * (0.2 + ((seed * 11 + i) % 60) / 100),
            -hh + height * (0.2 + ((seed * 17 + i) % 60) / 100),
            size,
            size,
          )
          .fill(primary, alpha: 0.4);
    }
  }
}

// ---------------------------------------------------------------------------
// 固定几何（逆着镜头旋转，像印刷色块）
// ---------------------------------------------------------------------------

/// 一块斜线阴影：录在自己的记录器里，画时裁到矩形。
class SonnetHatch {
  SonnetHatch(this.graphics, this.clip);

  final SonnetAnimatedGraphics graphics;
  final Rect clip;
}

class SonnetFixedGeo {
  SonnetFixedGeo(this.geo, this.hatches);

  final SonnetAnimatedGraphics geo;
  final List<SonnetHatch> hatches;

  void paint(Canvas canvas, double progress) {
    geo.paint(canvas, progress);
    for (final SonnetHatch h in hatches) {
      canvas.save();
      canvas.clipRect(h.clip);
      h.graphics.paint(canvas, progress);
      canvas.restore();
    }
  }

  void dispose() {
    geo.dispose();
    for (final SonnetHatch h in hatches) {
      h.graphics.dispose();
    }
  }
}

SonnetFixedGeo buildSonnetFixedGeo(
  int variant,
  double r,
  int seed,
  Color primary,
  Color secondary,
) {
  final _G geo = _G(seed ^ 0x51ed);
  final List<SonnetHatch> hatches = <SonnetHatch>[];
  final Color accent = seed.isEven ? secondary : primary;
  final double dir = seed.isEven ? 1 : -1;
  void hatch(double x, double y, double w, double h, [double spacing = 6]) {
    final _G g = _G(seed + hatches.length);
    for (double i = -w; i < w + h; i += spacing) {
      g
          .moveTo(x + i, y)
          .lineTo(x + i + h, y + h)
          .stroke(primary, width: 1, alpha: 0.15);
    }
    hatches.add(SonnetHatch(g, Rect.fromLTWH(x, y, w, h)));
  }

  switch (variant % 8) {
    case 1:
      geo
          .rect(-r * 0.34, -r * 0.28, r * 0.12, r * 0.56)
          .fill(accent, alpha: 0.65);
      geo
          .rect(
            -r * 0.34 + r * 0.035,
            -r * 0.28 + r * 0.035,
            r * 0.05,
            r * 0.49,
          )
          .fill(primary, alpha: 0.35);
      geo
          .rect(r * 0.06, -r * 0.34, r * 0.28, r * 0.68)
          .stroke(primary, width: 2, alpha: 0.6);
      geo
          .rect(r * 0.1, -r * 0.3, r * 0.2, r * 0.6)
          .stroke(primary, width: 1, alpha: 0.3);
      hatch(-r * 0.14, -r * 0.2, r * 0.12, r * 0.4, 5);
    case 2:
      geo.circle(-r * 0.2, r * 0.12, r * 0.15).fill(accent, alpha: 0.7);
      geo.circle(-r * 0.2, r * 0.12, r * 0.06).fill(primary, alpha: 0.5);
      geo
          .circle(r * 0.14, -r * 0.06, r * 0.3)
          .stroke(primary, width: 2, alpha: 0.6);
      geo
          .circle(r * 0.14, -r * 0.06, r * 0.22)
          .stroke(primary, width: 1, alpha: 0.3);
      hatch(r * 0.02, -r * 0.14, r * 0.24, r * 0.16, 5);
    case 3:
      final double dr = r * 0.3;
      final double cx = -r * 0.08 * dir;
      geo
          .moveTo(cx, -dr)
          .lineTo(cx + dr, 0)
          .lineTo(cx, dr)
          .lineTo(cx - dr, 0)
          .lineTo(cx, -dr)
          .stroke(primary, width: 2, alpha: 0.6);
      geo
          .moveTo(cx, -dr * 0.7)
          .lineTo(cx + dr * 0.7, 0)
          .lineTo(cx, dr * 0.7)
          .lineTo(cx - dr * 0.7, 0)
          .lineTo(cx, -dr * 0.7)
          .stroke(primary, width: 1, alpha: 0.3);
      final double sr = r * 0.11;
      final double sx = r * 0.3 * dir;
      final double sy = -r * 0.2;
      geo
          .moveTo(sx, sy - sr)
          .lineTo(sx + sr, sy)
          .lineTo(sx, sy + sr)
          .lineTo(sx - sr, sy)
          .lineTo(sx, sy - sr)
          .fill(accent, alpha: 0.7);
      hatch(sx - sr * 0.8, r * 0.16, sr * 1.6, sr * 1.2, 4);
    case 4:
      geo
          .rect(-r * 0.36 * dir - r * 0.2, -r * 0.26, r * 0.56, r * 0.09)
          .fill(accent, alpha: 0.7);
      geo
          .rect(-r * 0.28, -r * 0.06, r * 0.56, r * 0.16)
          .stroke(primary, width: 2, alpha: 0.6);
      geo
          .rect(-r * 0.2 * dir, r * 0.2, r * 0.4, r * 0.045)
          .fill(primary, alpha: 0.5);
      hatch(r * 0.26 * dir, -r * 0.3, r * 0.12, r * 0.6, 5);
    case 5:
      final double arm = r * 0.24;
      final double thick = r * 0.07;
      final double x1 = -r * 0.3 * dir;
      final double y1 = -r * 0.24;
      geo
          .rect(x1 - (dir < 0 ? arm : 0), y1, arm, thick)
          .fill(accent, alpha: 0.7);
      geo
          .rect(dir < 0 ? x1 - arm : x1, y1, thick, arm)
          .fill(accent, alpha: 0.7);
      final double x2 = r * 0.3 * dir;
      final double y2 = r * 0.24;
      geo
          .rect(dir < 0 ? x2 : x2 - arm, y2 - thick, arm, thick)
          .fill(primary, alpha: 0.55);
      geo
          .rect(dir < 0 ? x2 + arm - thick : x2 - thick, y2 - arm, thick, arm)
          .fill(primary, alpha: 0.55);
      geo
          .rect(-r * 0.13, -r * 0.13, r * 0.26, r * 0.26)
          .stroke(primary, width: 2, alpha: 0.6);
      hatch(-r * 0.09 * dir, r * 0.02, r * 0.16, r * 0.1, 4);
    case 6:
      final double wx = -r * 0.14 * dir;
      geo
          .moveTo(wx, -r * 0.3)
          .lineTo(wx + r * 0.24, r * 0.02)
          .lineTo(wx - r * 0.24, r * 0.02)
          .lineTo(wx, -r * 0.3)
          .fill(accent, alpha: 0.6);
      final double hx = r * 0.16 * dir;
      geo
          .moveTo(hx, r * 0.3)
          .lineTo(hx + r * 0.24, -r * 0.02)
          .lineTo(hx - r * 0.24, -r * 0.02)
          .lineTo(hx, r * 0.3)
          .stroke(primary, width: 2, alpha: 0.6);
      geo
          .moveTo(hx, r * 0.2)
          .lineTo(hx + r * 0.15, 0)
          .lineTo(hx - r * 0.15, 0)
          .lineTo(hx, r * 0.2)
          .stroke(primary, width: 1, alpha: 0.3);
      hatch(-r * 0.3 * dir - r * 0.05, r * 0.1, r * 0.2, r * 0.18, 5);
    case 7:
      final double cx = (seed % 3 - 1) * r * 0.08;
      final double arm = r * 0.17;
      final double thick = r * 0.075;
      geo.rect(cx - arm, -thick / 2, arm * 2, thick).fill(accent, alpha: 0.7);
      geo.rect(cx - thick / 2, -arm, thick, arm * 2).fill(accent, alpha: 0.7);
      geo.circle(cx, 0, r * 0.3).stroke(primary, width: 2, alpha: 0.6);
      geo.circle(cx, 0, r * 0.36).stroke(primary, width: 1, alpha: 0.25);
      hatch(cx + r * 0.18, r * 0.14, r * 0.16, r * 0.16, 4);
    default:
      geo.rect(-r * 0.4, -r * 0.2, r * 0.6, r * 0.15).fill(primary, alpha: 0.7);
      geo
          .rect(-r * 0.1, r * 0.1, r * 0.5, r * 0.3)
          .stroke(primary, width: 2, alpha: 0.6);
      hatch(-r * 0.3, -r * 0.4, r * 0.4, r * 0.25);
  }
  return SonnetFixedGeo(geo, hatches);
}

// ---------------------------------------------------------------------------
// 漂浮粒子（particle 层）
// ---------------------------------------------------------------------------

enum _DecorShape {
  square,
  diamond,
  sparkle,
  plus,
  ring,
  triangle,
  hexagon,
  bar,
  dot,
  chevron,
}

const List<List<_DecorShape>> _palettes = <List<_DecorShape>>[
  <_DecorShape>[_DecorShape.square, _DecorShape.diamond, _DecorShape.sparkle],
  <_DecorShape>[_DecorShape.ring, _DecorShape.hexagon, _DecorShape.dot],
  <_DecorShape>[_DecorShape.bar, _DecorShape.plus, _DecorShape.square],
  <_DecorShape>[_DecorShape.triangle, _DecorShape.diamond, _DecorShape.plus],
  <_DecorShape>[_DecorShape.dot, _DecorShape.ring, _DecorShape.sparkle],
  <_DecorShape>[_DecorShape.chevron, _DecorShape.bar, _DecorShape.hexagon],
];

/// 一个粒子：图形或「主题图标」（folia 用主题的 Lucide 图标，缺省是花；这里程序化画一朵描边花）。
class SonnetParticle {
  SonnetParticle({
    required this.x,
    required this.y,
    required this.rotation,
    required this.size,
    required this.color,
    required this.alpha,
    required this.shape,
    this.icon = false,
    this.preferredDuration = 0,
    this.phase = 0,
  });

  final double x;
  final double y;
  final double rotation;
  final double size;
  final Color color;
  final double alpha;
  final _DecorShape shape;
  final bool icon;
  final double preferredDuration;
  final double phase;
  double entryPhase = 0;
}

/// 主题图标占位：每个镜头约四分之一的粒子换成图标，保证至少出现一次。
List<int?> buildSonnetIconParticleIndices(
  int iconCount,
  int particleCount,
  int seed,
) {
  if (iconCount <= 0) return List<int?>.filled(particleCount, null);
  final int iconParticles = math.min(
    particleCount,
    math.max((particleCount / 4).ceil(), iconCount),
  );
  int emitted = 0;
  return <int?>[
    for (int i = 0; i < particleCount; i++)
      () {
        final int prev = (i * iconParticles) ~/ particleCount;
        final int cur = ((i + 1) * iconParticles) ~/ particleCount;
        if (cur == prev) return null;
        final int idx = ((seed + emitted) % iconCount + iconCount) % iconCount;
        emitted++;
        return idx;
      }(),
  ];
}

double resolveSonnetIconEntryPhase(int index, int count) {
  if (count <= 1) return 0.12;
  return 0.04 + (index.clamp(0, count - 1) / (count - 1)) * 0.82;
}

List<SonnetParticle> buildSonnetParticles(
  SonnetShotKind kind,
  double width,
  double height,
  int seed,
  Color primary,
  Color secondary,
  Color iconColor,
) {
  final int variant = resolveSonnetBackgroundDecorVariant(seed);
  final List<_DecorShape> palette = _palettes[variant];
  final int count = kind == SonnetShotKind.typeImpact ? 24 : 12;
  final List<int?> iconSlots = buildSonnetIconParticleIndices(1, count, seed);
  final double hw = width / 2;
  final double hh = height / 2;
  final double radius = math.min(width, height);
  final List<SonnetParticle> out = <SonnetParticle>[];
  for (int i = 0; i < count; i++) {
    final double pSize = 4.0 + (seed + i) % 12;
    double jitter(int salt, double range) =>
        (sonnetHash01(seed, i, salt) - 0.5) * range;
    final double baseRot = sonnetHash01(seed, i, 11) * math.pi * 2;
    double x;
    double y;
    double rot = baseRot;
    switch (variant) {
      case 1:
        final int ring = i % 2;
        final double rr = radius * (0.36 + ring * 0.26);
        final double a = (i / count) * math.pi * 4 + jitter(13, 0.35);
        x = math.cos(a) * rr;
        y = math.sin(a) * rr * 0.86;
        rot = a + math.pi / 2;
      case 2:
        final double side = i.isEven ? -1 : 1;
        final double t = ((i ~/ 2) + 0.5) / math.max(1, count ~/ 2);
        x = -hw + width * (0.06 + 0.88 * t) + jitter(17, width * 0.03);
        y = side * hh * 0.78 + jitter(19, height * 0.05);
        rot = side < 0 ? 0 : math.pi;
      case 3:
        final int corner = i % 4;
        x = (corner.isEven ? -1 : 1) * hw * 0.68 + jitter(23, width * 0.12);
        y = (corner < 2 ? -1 : 1) * hh * 0.62 + jitter(29, height * 0.12);
      case 4:
        final int col = i % 6;
        final int row = (i ~/ 6) % 4;
        x = -hw * 0.8 + (col / 5) * hw * 1.6 + jitter(31, width * 0.06);
        y = -hh * 0.72 + (row / 3) * hh * 1.44 + jitter(37, height * 0.06);
      case 5:
        final double side = i.isEven ? -1 : 1;
        final double t = ((i ~/ 2) + 0.5) / math.max(1, (count / 2).ceil());
        x = side * hw * 0.74 + jitter(41, width * 0.04);
        y = -hh * 0.8 + t * hh * 1.6 + jitter(43, height * 0.05);
        rot = side < 0 ? math.pi : 0;
      default:
        x = -hw + width * sonnetHash01(seed, i, 47);
        y = -hh + height * sonnetHash01(seed, i, 53);
    }
    final bool isIcon = iconSlots[i] != null;
    final int iconSeed = (seed + i * 17).abs();
    out.add(
      SonnetParticle(
        x: x,
        y: y,
        rotation: rot,
        size: pSize,
        color: isIcon ? iconColor : (i.isEven ? primary : secondary),
        alpha: isIcon ? 0.85 : 0.55 + sonnetHash01(seed, i, 59) * 0.3,
        shape: palette[(seed + i) % palette.length],
        icon: isIcon,
        preferredDuration: 0.62 + (iconSeed % 4) * 0.08,
        phase: (iconSeed % 31) * 0.2,
      ),
    );
  }
  final List<SonnetParticle> icons = out
      .where((SonnetParticle p) => p.icon)
      .toList();
  for (int i = 0; i < icons.length; i++) {
    icons[i].entryPhase = resolveSonnetIconEntryPhase(i, icons.length);
  }
  return out;
}

final Paint _particlePaint = Paint();

/// 画一个粒子（中心在原点）。[scale] / [alphaMul] 只作用于图标的入场与呼吸。
void paintSonnetParticle(
  Canvas canvas,
  SonnetParticle p, {
  double scale = 1,
  double alphaMul = 1,
}) {
  canvas.save();
  canvas.translate(p.x, p.y);
  canvas.rotate(p.rotation);
  final double s = p.size;
  final Paint paint = _particlePaint;
  if (p.icon) {
    // 描边花：七倍粒子大小的外接框里五瓣 + 花心。
    final double box = s * 7 * scale;
    final double a = (p.alpha * alphaMul).clamp(0.0, 1.0);
    if (a <= 0.001) {
      canvas.restore();
      return;
    }
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, box / 24 * 1.5)
      ..color = p.color.withValues(alpha: a);
    for (int k = 0; k < 5; k++) {
      canvas.save();
      canvas.rotate(k * math.pi * 2 / 5);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(0, -box * 0.22),
          width: box * 0.26,
          height: box * 0.4,
        ),
        paint,
      );
      canvas.restore();
    }
    canvas.drawCircle(Offset.zero, box * 0.1, paint);
    canvas.restore();
    return;
  }
  final Color c = p.color;
  final double a = p.alpha;
  void fill(double alpha) => paint
    ..style = PaintingStyle.fill
    ..color = c.withValues(alpha: alpha.clamp(0.0, 1.0));
  void stroke(double w, double alpha) => paint
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..color = c.withValues(alpha: alpha.clamp(0.0, 1.0));
  switch (p.shape) {
    case _DecorShape.diamond:
      fill(a * 0.85);
      canvas.drawPath(
        Path()
          ..moveTo(0, -s)
          ..lineTo(s, 0)
          ..lineTo(0, s)
          ..lineTo(-s, 0)
          ..close(),
        paint,
      );
    case _DecorShape.sparkle:
      fill(a * 1.2);
      canvas.drawPath(
        Path()
          ..moveTo(0, -s * 1.5)
          ..quadraticBezierTo(0, 0, s * 1.5, 0)
          ..quadraticBezierTo(0, 0, 0, s * 1.5)
          ..quadraticBezierTo(0, 0, -s * 1.5, 0)
          ..quadraticBezierTo(0, 0, 0, -s * 1.5),
        paint,
      );
    case _DecorShape.plus:
      fill(a * 0.9);
      final double arm = s * 0.34;
      canvas.drawRect(Rect.fromLTWH(-s, -arm, s * 2, arm * 2), paint);
      canvas.drawRect(Rect.fromLTWH(-arm, -s, arm * 2, s * 2), paint);
    case _DecorShape.ring:
      stroke(math.max(1, s * 0.22), a * 0.9);
      canvas.drawCircle(Offset.zero, s, paint);
    case _DecorShape.triangle:
      fill(a * 0.85);
      canvas.drawPath(
        Path()
          ..moveTo(0, -s)
          ..lineTo(s * 0.9, s * 0.7)
          ..lineTo(-s * 0.9, s * 0.7)
          ..close(),
        paint,
      );
    case _DecorShape.hexagon:
      stroke(math.max(1, s * 0.16), a);
      final Path h = Path();
      for (int j = 0; j <= 6; j++) {
        final double an = j * math.pi / 3;
        if (j == 0) {
          h.moveTo(math.sin(an) * s, -math.cos(an) * s);
        } else {
          h.lineTo(math.sin(an) * s, -math.cos(an) * s);
        }
      }
      canvas.drawPath(h, paint);
    case _DecorShape.bar:
      fill(a * 0.85);
      canvas.drawRect(Rect.fromLTWH(-s, -s * 0.18, s * 2, s * 0.36), paint);
    case _DecorShape.dot:
      fill(a);
      canvas.drawCircle(Offset.zero, s * 0.34, paint);
    case _DecorShape.chevron:
      stroke(math.max(1.5, s * 0.2), a);
      canvas.drawPath(
        Path()
          ..moveTo(-s * 0.5, -s * 0.55)
          ..lineTo(s * 0.35, 0)
          ..lineTo(-s * 0.5, s * 0.55),
        paint,
      );
    case _DecorShape.square:
      fill(a);
      canvas.drawRect(Rect.fromLTWH(-s / 2, -s / 2, s, s), paint);
  }
  canvas.restore();
}
