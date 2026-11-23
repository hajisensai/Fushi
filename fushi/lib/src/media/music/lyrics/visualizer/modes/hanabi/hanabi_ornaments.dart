/// MG 装饰件（移植 folia `hanabi/mg/ornamentKit.ts` 的布点 / 时序，21 种件按 folia 的形状与节奏用 Canvas 重画）：
/// 圆环、集中线、轨道、放射、虚线圈、网点、方块、括号、印章、星光、十字、箭头、纸屑、碎片、速度线、花瓣、
/// 折线、波浪、下划线、点线、闪光。每件只由时间决定。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_text_layout.dart';

class OrnamentSite {
  OrnamentSite(
    this.x,
    this.y,
    this.w,
    this.h,
    this.angle, {
    this.glyph = -1,
    required this.start,
    this.hollow = false,
  });
  final double x;
  final double y;
  final double w;
  final double h;
  final double angle;
  final int glyph;
  final double start;
  final bool hollow;
}

class _GlyphInfo {
  const _GlyphInfo(
    this.index,
    this.x,
    this.y,
    this.size,
    this.sungAt,
    this.sungEnd,
  );
  final int index;
  final double x;
  final double y;
  final double size;
  final double sungAt;
  final double sungEnd;
}

/// 装饰件的公共布点与时序。
class OrnamentKit {
  OrnamentKit({
    required this.spec,
    required this.palette,
    required this.width,
    required this.height,
    required String seed,
    required LayoutRect bounds,
    required this.anchorsAt,
    required double enterAt,
    required this.exitAt,
    required this.exitDuration,
    required double amount,
  }) : rng = hanabiRng(
         '$seed:ornament:${spec.kind.name}:${spec.placement.name}',
       ),
       start = enterAt + spec.delay,
       end = exitAt + math.max(0, exitDuration),
       cx = bounds.cx,
       cy = bounds.cy,
       hw = math.max(1, bounds.width / 2),
       hh = math.max(1, bounds.height / 2) {
    final List<GlyphAnchor> initial = anchorsAt(enterAt);
    final double landed = initial.fold(
      enterAt,
      (double m, GlyphAnchor a) => math.max(m, a.landedAt),
    );
    final double settle = math.min(exitAt - 1e-3, landed + 0.05);
    final List<GlyphAnchor> settled = settle > enterAt
        ? anchorsAt(settle)
        : initial;
    for (int i = 0; i < settled.length; i++) {
      final GlyphAnchor a = settled[i];
      if (a.blank) continue;
      glyphs.add(_GlyphInfo(i, a.x, a.y, a.size, a.sungAt, a.sungEnd));
    }
    final List<double> sizes = glyphs.map((_GlyphInfo g) => g.size).toList()
      ..sort();
    base = sizes.isNotEmpty
        ? sizes[sizes.length ~/ 2]
        : math.max(
            12,
            math.max(math.min(hw, hh) * 0.8, math.min(width, height) * 0.06),
          );
    size = base * math.max(0.1, spec.scale);
    if (glyphs.length > 1) {
      final List<double> xs = glyphs.map((_GlyphInfo g) => g.x).toList();
      final List<double> ys = glyphs.map((_GlyphInfo g) => g.y).toList();
      vertical =
          ys.reduce(math.max) - ys.reduce(math.min) >
          (xs.reduce(math.max) - xs.reduce(math.min)) * 1.3;
    }
    factor = math.max(0, amount) * (0.35 + 0.9 * clamp01(spec.density));
    firstSung = glyphs.fold(
      double.infinity,
      (double m, _GlyphInfo g) => math.min(m, g.sungAt),
    );
  }

  final OrnamentSpec spec;
  final HanabiPalette palette;
  final double width;
  final double height;
  final HanabiRng rng;
  final List<GlyphAnchor> Function(double time) anchorsAt;
  final double exitAt;
  final double exitDuration;
  final double start;
  final double end;
  final double cx;
  final double cy;
  final double hw;
  final double hh;
  final List<_GlyphInfo> glyphs = <_GlyphInfo>[];
  late final double base;
  late final double size;
  bool vertical = false;
  late final double factor;
  late final double firstSung;

  int count(double baseCount, [int min = 1]) =>
      factor <= 0 ? 0 : math.max(min, (baseCount * factor).round());

  int _pick(List<int> list, int i, int fallback) => list.isEmpty
      ? fallback
      : list[((i % list.length) + list.length) % list.length];

  int color(int i) => switch (spec.color) {
    OrnamentColor.spark => _pick(palette.sparks, i, palette.accent),
    OrnamentColor.block => _pick(palette.blocks, i, palette.accent),
    OrnamentColor.paper => palette.paper,
    OrnamentColor.glow => palette.glow,
    OrnamentColor.accent => palette.accent,
  };

  List<OrnamentSite> sites(bool scatter, int maxGlyphSites) {
    final double pad = base * 0.35;
    switch (spec.placement) {
      case OrnamentPlacement.behind:
        return <OrnamentSite>[
          OrnamentSite(cx, cy, hw, hh, -math.pi / 2, start: start),
        ];
      case OrnamentPlacement.around:
        return <OrnamentSite>[
          OrnamentSite(
            cx,
            cy,
            hw + pad,
            hh + pad,
            -math.pi / 2,
            start: start,
            hollow: scatter,
          ),
        ];
      case OrnamentPlacement.corners:
        const List<(int, int)> corners = <(int, int)>[
          (-1, -1),
          (1, -1),
          (1, 1),
          (-1, 1),
        ];
        return <OrnamentSite>[
          for (int k = 0; k < 4; k++)
            OrnamentSite(
              cx + corners[k].$1 * (hw + pad * 0.6),
              cy + corners[k].$2 * (hh + pad * 0.6),
              base * 0.6,
              base * 0.6,
              math.atan2(corners[k].$2.toDouble(), corners[k].$1.toDouble()),
              start: start + k * 0.07,
            ),
        ];
      case OrnamentPlacement.lineStart:
        return <OrnamentSite>[
          vertical
              ? OrnamentSite(
                  cx,
                  cy - hh - pad,
                  base * 0.7,
                  base * 0.7,
                  -math.pi / 2,
                  start: start,
                )
              : OrnamentSite(
                  cx - hw - pad,
                  cy,
                  base * 0.7,
                  base * 0.7,
                  math.pi,
                  start: start,
                ),
        ];
      case OrnamentPlacement.lineEnd:
        return <OrnamentSite>[
          vertical
              ? OrnamentSite(
                  cx,
                  cy + hh + pad,
                  base * 0.7,
                  base * 0.7,
                  math.pi / 2,
                  start: start,
                )
              : OrnamentSite(
                  cx + hw + pad,
                  cy,
                  base * 0.7,
                  base * 0.7,
                  0,
                  start: start,
                ),
        ];
      case OrnamentPlacement.screen:
        return <OrnamentSite>[
          OrnamentSite(
            0,
            0,
            width * 0.55,
            height * 0.55,
            -math.pi / 2,
            start: start,
          ),
        ];
      case OrnamentPlacement.glyphs:
        if (glyphs.isEmpty) {
          return <OrnamentSite>[
            OrnamentSite(cx, cy, hw, hh, -math.pi / 2, start: start),
          ];
        }
        final int limit = math.max(1, math.min(glyphs.length, maxGlyphSites));
        return <OrnamentSite>[
          for (int i = 0; i < limit; i++)
            () {
              final _GlyphInfo g =
                  glyphs[((i + 0.5) * glyphs.length / limit).floor()];
              return OrnamentSite(
                g.x,
                g.y,
                g.size * 0.55,
                g.size * 0.55,
                -math.pi / 2,
                glyph: g.index,
                start: math.max(start, g.sungAt),
              );
            }(),
        ];
    }
  }

  /// 布点此刻的位置（字上的点跟着字走）：(x, y, alpha, size)。
  (double, double, double, double) pos(
    OrnamentSite site,
    List<GlyphAnchor> anchors,
  ) {
    if (site.glyph >= 0 && site.glyph < anchors.length) {
      final GlyphAnchor a = anchors[site.glyph];
      return (a.x, a.y, a.alpha, a.size);
    }
    return (site.x, site.y, 1, math.max(site.w, site.h));
  }

  double exit(double time, [double stagger = 0]) {
    final double span = math.max(0.05, exitDuration);
    return clamp01((time - exitAt - stagger) / math.max(0.05, span - stagger));
  }

  (double, double) scatter(OrnamentSite site) {
    if (!site.hollow) {
      return ((rng() * 2 - 1) * site.w, (rng() * 2 - 1) * site.h);
    }
    final double ow = site.w + base * 1.3;
    final double oh = site.h + base * 1.0;
    for (int tries = 0; tries < 12; tries++) {
      final double x = (rng() * 2 - 1) * ow;
      final double y = (rng() * 2 - 1) * oh;
      if (x.abs() > site.w || y.abs() > site.h) return (x, y);
    }
    final double a = rng() * kTau;
    return (math.cos(a) * ow, math.sin(a) * oh);
  }

  double siteRadius(OrnamentSite site, double fallback) =>
      switch (spec.placement) {
        OrnamentPlacement.behind =>
          math.sqrt(site.w * site.w + site.h * site.h) * 0.8,
        OrnamentPlacement.around =>
          math.sqrt(site.w * site.w + site.h * site.h) * 0.95,
        OrnamentPlacement.screen => math.min(site.w, site.h) * 0.75,
        _ => math.max(site.w, fallback) * 1.3,
      };

  bool get big =>
      spec.placement == OrnamentPlacement.behind ||
      spec.placement == OrnamentPlacement.around ||
      spec.placement == OrnamentPlacement.screen;
}

typedef OrnamentPainter = void Function(ui.Canvas canvas, double time);

Paint _fill(int color, double alpha) => Paint()..color = rgbColor(color, alpha);
Paint _stroke(int color, double alpha, double width) => Paint()
  ..color = rgbColor(color, alpha)
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

ui.Path _star4(double r) {
  final double pinch = r * 0.12;
  return ui.Path()
    ..moveTo(0, -r)
    ..quadraticBezierTo(pinch, -pinch, r, 0)
    ..quadraticBezierTo(pinch, pinch, 0, r)
    ..quadraticBezierTo(-pinch, pinch, -r, 0)
    ..quadraticBezierTo(-pinch, -pinch, 0, -r)
    ..close();
}

/// 一个装饰件（布点在构造时定好）。
class HanabiOrnament {
  HanabiOrnament(this.kit)
    : _paint = kit.factor <= 0 ? null : _builders[kit.spec.kind]!(kit) {
    _from = math.min(kit.start, kit.firstSung) - 0.05;
  }

  final OrnamentKit kit;
  final OrnamentPainter? _paint;
  late final double _from;

  void paint(ui.Canvas canvas, double time) {
    if (_paint == null || time < _from || time > kit.end) return;
    _paint(canvas, time);
  }
}

final Map<OrnamentKind, OrnamentPainter Function(OrnamentKit kit)> _builders =
    <OrnamentKind, OrnamentPainter Function(OrnamentKit kit)>{
      OrnamentKind.ring: _ring,
      OrnamentKind.spokes: _spokes,
      OrnamentKind.orbit: _orbit,
      OrnamentKind.rays: _rays,
      OrnamentKind.dashCircle: _dashCircle,
      OrnamentKind.halftone: _halftone,
      OrnamentKind.squares: _squares,
      OrnamentKind.brackets: _brackets,
      OrnamentKind.stamp: _stamp,
      OrnamentKind.sparkle: _sparkle,
      OrnamentKind.cross: _cross,
      OrnamentKind.chevrons: _chevrons,
      OrnamentKind.confetti: _confetti,
      OrnamentKind.shards: _shards,
      OrnamentKind.streaks: _streaks,
      OrnamentKind.petals: _petals,
      OrnamentKind.zigzag: _zigzag,
      OrnamentKind.wave: _wave,
      OrnamentKind.underline: _underline,
      OrnamentKind.dotsLine: _dotsLine,
      OrnamentKind.glints: _glints,
    };

// ─── 形状类 ─────────────────────────────────────────────────────────────

OrnamentPainter _ring(OrnamentKit kit) {
  final bool oneShot = kit.spec.placement == OrnamentPlacement.glyphs;
  final int layers = oneShot ? 1 : math.min(3, kit.count(2.4, 1));
  final double line = math.max(1.5, kit.size * 0.055);
  final List<(OrnamentSite, double, int)> units = <(OrnamentSite, double, int)>[
    for (final (int si, OrnamentSite site) in kit.sites(false, 8).indexed)
      (site, kit.siteRadius(site, kit.size * 0.5) * (oneShot ? 1.3 : 1), si),
  ];
  return (ui.Canvas canvas, double time) {
    final List<GlyphAnchor> anchors = kit.anchorsAt(time);
    for (final (OrnamentSite site, double radius, int si) in units) {
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double e = time - site.start;
      for (int j = 0; j < layers; j++) {
        final double local = e - j * 0.09;
        final double x = kit.exit(time, j * 0.05);
        if (local < 0 || x >= 1) continue;
        double scale;
        double alpha;
        if (oneShot) {
          final double k = clamp01(local / 0.8);
          scale = 0.3 + 1.1 * easeOutExpo(k);
          alpha = math.pow(1 - k, 1.5).toDouble();
        } else {
          scale =
              lerpD(0.2, 1, easeOutBack(local / 0.55, 2.4)) *
              (1 + 0.025 * math.sin(kTau * (time * 0.5 + j / 3)));
          alpha = clamp01(local / 0.08);
          scale *= 1 - easeInBack(x, 2);
          alpha *= 1 - x;
        }
        if (alpha <= 0.005 || scale <= 0.001) continue;
        canvas.drawCircle(
          Offset(px, py),
          radius * (1 + 0.14 * j) * scale,
          _stroke(
            kit.color(si + j),
            alpha * pa,
            line * (j == 0 ? 1.6 : 0.8) * scale,
          ),
        );
      }
      if (!oneShot && e > 0.6) {
        final double q = fract((e - 0.6) / 1.8);
        final double x = kit.exit(time);
        if (x < 1) {
          canvas.drawCircle(
            Offset(px, py),
            radius * (1 + 0.55 * easeOutCubic(q)),
            _stroke(
              kit.color(si + 1),
              0.55 * (1 - q) * (1 - q) * (1 - x) * pa,
              line * 0.6,
            ),
          );
        }
      }
    }
  };
}

OrnamentPainter _spokes(OrnamentKit kit) {
  final bool oneShot = kit.spec.placement == OrnamentPlacement.glyphs;
  final bool big = kit.big;
  final double pad = kit.size * 0.45;
  final List<(OrnamentSite, List<List<double>>)> units =
      <(OrnamentSite, List<List<double>>)>[];
  for (final (int si, OrnamentSite site) in kit.sites(false, 6).indexed) {
    final int n = oneShot ? 8 : kit.count(big ? 28 : 10, 6);
    units.add((
      site,
      <List<double>>[
        for (int i = 0; i < n; i++)
          () {
            final double angle =
                kTau * i / n + (kit.rng() - 0.5) * (kTau / n) * 0.7;
            final double cos = math.cos(angle);
            final double sin = math.sin(angle);
            final double inner = big
                ? 1 /
                      math.sqrt(
                        math.pow(cos / (site.w + pad), 2) +
                            math.pow(sin / (site.h + pad), 2),
                      )
                : site.w * 1.1;
            return <double>[
              cos,
              sin,
              inner,
              kit.size *
                  (oneShot ? 0.5 + kit.rng() * 0.5 : 0.7 + kit.rng() * 1.7),
              math.max(1.2, kit.size * (0.035 + kit.rng() * 0.05)),
              (i % 6) * 0.015,
              (si * 97 + i).toDouble(),
              kit.color(si + i).toDouble(),
            ];
          }(),
      ],
    ));
  }
  return (ui.Canvas canvas, double time) {
    final List<GlyphAnchor> anchors = kit.anchorsAt(time);
    final double beat = (time * 12).floorToDouble();
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final (OrnamentSite site, List<List<double>> spokes) in units) {
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double e = time - site.start;
      for (final List<double> s in spokes) {
        final double local = e - s[5];
        if (local < 0) continue;
        final double grow = easeOutExpo(local / 0.25);
        final double jitter = 0.72 + 0.45 * mgHash01(beat, s[6]);
        double length = s[3] * grow * jitter * (1 - x);
        double push = kit.size * 2.5 * easeInCubic(x);
        double alpha = (0.55 + 0.45 * mgHash01(beat + 7, s[6])) * pa;
        if (oneShot) {
          final double k = clamp01((local - 0.3) / 0.35);
          push += kit.size * 0.8 * easeOutCubic(k);
          length *= 1 - k;
          alpha *= 1 - k;
        }
        if (length <= 0.5 || alpha <= 0.01) continue;
        final double r0 = s[2] + push;
        canvas.drawLine(
          Offset(px + s[0] * r0, py + s[1] * r0),
          Offset(px + s[0] * (r0 + length), py + s[1] * (r0 + length)),
          _stroke(s[7].toInt(), alpha, s[4] * (1 - x * 0.5)),
        );
      }
    }
  };
}

OrnamentPainter _orbit(OrnamentKit kit) {
  final bool big = kit.big;
  const double tilt = -0.18;
  final List<OrnamentSite> sites = kit.sites(false, 4);
  final int trains = big ? math.max(2, math.min(6, kit.count(4, 2))) : 2;
  final int cars = big ? 5 : 3;
  return (ui.Canvas canvas, double time) {
    final List<GlyphAnchor> anchors = kit.anchorsAt(time);
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final (int si, OrnamentSite site) in sites.indexed) {
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double rx = big ? site.w + kit.size * 0.5 : site.w * 1.5;
      final double ry = big ? site.h + kit.size * 0.6 : site.h * 0.8;
      final double e = time - site.start;
      canvas.save();
      canvas.translate(px, py);
      canvas.rotate(tilt);
      for (int r = 0; r < 2; r++) {
        final double omega = r == 0 ? 0.55 : -0.85;
        final double reach = r == 0 ? 1 : 1.2;
        final int ringTrains = r == 0 ? trains : math.max(1, trains - 1);
        final double grow = easeOutCubic(clamp01((e - r * 0.12) / 0.5));
        if (grow <= 0) continue;
        final double alpha = grow * (1 - x) * pa;
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset.zero,
            width: rx * reach * 2 * grow,
            height: ry * reach * 2 * grow,
          ),
          _stroke(kit.color(si + r), alpha * 0.6, math.max(1, kit.size * 0.02)),
        );
        for (int train = 0; train < ringTrains; train++) {
          for (int car = 0; car < cars; car++) {
            final double delay = train * 0.06 + car * 0.03 + r * 0.12;
            if (e < delay) continue;
            final double theta =
                kTau * train / ringTrains +
                r * 0.5 -
                omega.sign * car * 0.11 +
                omega * time;
            final double sx = math.cos(theta) * rx * reach * grow;
            final double sy = math.sin(theta) * ry * reach * grow;
            final double dot =
                kit.size * (car == 0 ? 0.17 : 0.07 * (1 - car / (cars + 1)));
            final int c = kit.color(si + r + train);
            if (car == 0) {
              canvas.save();
              canvas.translate(sx, sy);
              canvas.drawPath(_star4(dot), _fill(c, alpha));
              canvas.restore();
            } else {
              canvas.drawCircle(Offset(sx, sy), dot, _fill(c, alpha));
            }
          }
        }
      }
      canvas.restore();
    }
  };
}

OrnamentPainter _rays(OrnamentKit kit) {
  final List<OrnamentSite> sites = kit.sites(false, 3);
  final int n = math.max(8, kit.count(16, 8));
  final double phase0 = kit.rng() * kTau;
  return (ui.Canvas canvas, double time) {
    final List<GlyphAnchor> anchors = kit.anchorsAt(time);
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final (int si, OrnamentSite site) in sites.indexed) {
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double e = time - site.start;
      if (e < 0) continue;
      final double grow = easeOutExpo(e / 0.6);
      final double radius =
          kit.siteRadius(site, kit.size) *
          2.2 *
          grow *
          (1 + 0.3 * easeInCubic(x));
      final double alpha = 0.32 * clamp01(e / 0.15) * (1 - x) * pa;
      final double turn = phase0 + time * 0.12;
      final ui.Path wedges = ui.Path();
      for (int i = 0; i < n; i++) {
        final double a0 = turn + kTau * i / n;
        final double a1 = a0 + kTau / n * 0.5;
        wedges
          ..moveTo(0, 0)
          ..lineTo(math.cos(a0) * radius, math.sin(a0) * radius)
          ..lineTo(math.cos(a1) * radius, math.sin(a1) * radius)
          ..close();
      }
      canvas.save();
      canvas.translate(px, py);
      canvas.drawPath(
        wedges,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset.zero,
            math.max(1, radius),
            <Color>[rgbColor(kit.color(si), alpha), rgbColor(kit.color(si), 0)],
          ),
      );
      canvas.restore();
    }
  };
}

OrnamentPainter _dashCircle(OrnamentKit kit) {
  final List<OrnamentSite> sites = kit.sites(false, 4);
  final int dashes = math.max(12, kit.count(28, 12));
  final double line = math.max(1.4, kit.size * 0.05);
  return (ui.Canvas canvas, double time) {
    final List<GlyphAnchor> anchors = kit.anchorsAt(time);
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final (int si, OrnamentSite site) in sites.indexed) {
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double e = time - site.start;
      if (e < 0) continue;
      final double grow = easeOutBack(e / 0.6, 1.8) * (1 - easeInBack(x, 2));
      final double radius = kit.siteRadius(site, kit.size * 0.5) * 1.05 * grow;
      if (radius <= 0.5) continue;
      final double sweep = easeOutCubic(e / 0.8);
      final double turn = time * 0.4 * (si.isEven ? 1 : -1);
      final Paint paint = _stroke(
        kit.color(si),
        (1 - x) * pa * clamp01(e / 0.1),
        line,
      );
      final Rect oval = Rect.fromCircle(center: Offset(px, py), radius: radius);
      final double step = kTau / dashes;
      for (int i = 0; i < (dashes * sweep).floor(); i++) {
        canvas.drawArc(oval, turn + i * step, step * 0.55, false, paint);
      }
    }
  };
}

OrnamentPainter _halftone(OrnamentKit kit) {
  final List<OrnamentSite> sites = kit.sites(false, 2);
  final double pitch = math.max(6, kit.size * 0.22);
  return (ui.Canvas canvas, double time) {
    final List<GlyphAnchor> anchors = kit.anchorsAt(time);
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final (int si, OrnamentSite site) in sites.indexed) {
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double e = time - site.start;
      if (e < 0) continue;
      final double w = site.w * 1.25;
      final double h = site.h * 1.25;
      final int cols = math.min(40, (w * 2 / pitch).ceil());
      final int rows = math.min(30, (h * 2 / pitch).ceil());
      final Paint paint = _fill(kit.color(si), 0.55 * (1 - x) * pa);
      for (int r = 0; r <= rows; r++) {
        for (int c = 0; c <= cols; c++) {
          final double lx = -w + c * pitch + (r.isOdd ? pitch / 2 : 0);
          final double ly = -h + r * pitch;
          final double d = math.sqrt((lx / w) * (lx / w) + (ly / h) * (ly / h));
          if (d > 1) continue;
          final double wave =
              clamp01((e * 2.2 - d) / 0.4) *
              (1 - clamp01((x * 1.6 - (1 - d)) / 0.4));
          final double radius = pitch * 0.42 * (1 - d) * wave;
          if (radius < 0.4) continue;
          canvas.drawCircle(Offset(px + lx, py + ly), radius, paint);
        }
      }
    }
  };
}

OrnamentPainter _squares(OrnamentKit kit) {
  final List<List<double>> items = <List<double>>[];
  for (final (int si, OrnamentSite site) in kit.sites(true, 6).indexed) {
    final int n = kit.spec.placement == OrnamentPlacement.corners
        ? 1
        : kit.count(7, 2);
    for (int i = 0; i < n; i++) {
      final (
        double ox,
        double oy,
      ) = kit.spec.placement == OrnamentPlacement.corners
          ? (0.0, 0.0)
          : kit.scatter(site);
      items.add(<double>[
        site.x + ox,
        site.y + oy,
        kit.size * (0.12 + kit.rng() * 0.22),
        kit.rng() * kTau,
        (kit.rng() - 0.5) * 2,
        site.start + i * 0.05,
        kit.color(si + i).toDouble(),
        kit.rng() < 0.5 ? 1 : 0,
      ]);
    }
  }
  return (ui.Canvas canvas, double time) {
    for (final (int k, List<double> s) in items.indexed) {
      final double e = time - s[5];
      final double x = kit.exit(time, (k % 5) * 0.03);
      if (e < 0 || x >= 1) continue;
      final double scale =
          easeOutBack(e / 0.35, 2.2) * (1 - easeInBack(x, 1.6));
      if (scale <= 0.01) continue;
      canvas.save();
      canvas.translate(s[0], s[1]);
      canvas.rotate(s[3] + s[4] * time * 0.8);
      final Rect r = Rect.fromCenter(
        center: Offset.zero,
        width: s[2] * scale,
        height: s[2] * scale,
      );
      canvas.drawRect(
        r,
        s[7] > 0
            ? _fill(s[6].toInt(), 0.9)
            : _stroke(s[6].toInt(), 0.9, math.max(1.2, s[2] * 0.14)),
      );
      canvas.restore();
    }
  };
}

OrnamentPainter _brackets(OrnamentKit kit) {
  final OrnamentSite site = kit.sites(false, 1).first;
  final double arm = kit.size * 0.45;
  final double line = math.max(1.6, kit.size * 0.06);
  return (ui.Canvas canvas, double time) {
    final double e = time - site.start;
    final double x = kit.exit(time);
    if (e < 0 || x >= 1) return;
    final double k = easeOutBack(e / 0.45, 1.8);
    final double out = 1 + 0.25 * (1 - k) + 0.2 * easeInCubic(x);
    final double w = (site.w + kit.base * 0.2) * out;
    final double h = (site.h + kit.base * 0.15) * out;
    final double alpha = clamp01(e / 0.1) * (1 - x);
    final double breathe = 1 + 0.02 * math.sin(time * 2.4);
    for (int c = 0; c < 4; c++) {
      final double sx = c == 0 || c == 3 ? -1 : 1;
      final double sy = c < 2 ? -1 : 1;
      final double bx = site.x + sx * w * breathe;
      final double by = site.y + sy * h * breathe;
      final ui.Path path = ui.Path()
        ..moveTo(bx - sx * arm, by)
        ..lineTo(bx, by)
        ..lineTo(bx, by - sy * arm);
      canvas.drawPath(
        path,
        _stroke(kit.color(c), alpha, line)..strokeCap = StrokeCap.square,
      );
    }
  };
}

OrnamentPainter _stamp(OrnamentKit kit) {
  final OrnamentSite site = kit.sites(false, 1).first;
  final double radius = kit.size * 0.55;
  final double tilt = (kit.rng() - 0.5) * 0.5;
  final int c = kit.color(0);
  return (ui.Canvas canvas, double time) {
    final double e = time - site.start;
    final double x = kit.exit(time);
    if (e < 0 || x >= 1) return;
    final double f = clamp01(e / 0.22);
    final double scale =
        (f < 1
            ? 2.2 - 1.2 * f * f
            : 1 +
                  0.12 *
                      math.exp(-(e - 0.22) * 9) *
                      math.cos((e - 0.22) * 40)) *
        (1 - easeInBack(x, 1.6));
    final double alpha = clamp01(f * 2) * (1 - x);
    if (scale <= 0.01) return;
    canvas.save();
    canvas.translate(site.x, site.y);
    canvas.rotate(tilt);
    canvas.scale(scale);
    canvas.drawCircle(Offset.zero, radius, _stroke(c, alpha, radius * 0.1));
    canvas.drawCircle(
      Offset.zero,
      radius * 0.78,
      _stroke(c, alpha * 0.8, radius * 0.04),
    );
    canvas.drawPath(_star4(radius * 0.5), _fill(c, alpha));
    canvas.restore();
  };
}

// ─── 粒子类 ─────────────────────────────────────────────────────────────

OrnamentPainter _sparkle(OrnamentKit kit) {
  final bool onGlyphs = kit.spec.placement == OrnamentPlacement.glyphs;
  final List<(OrnamentSite, double, double, double, int, double)> items =
      <(OrnamentSite, double, double, double, int, double)>[];
  for (final (int si, OrnamentSite site) in kit.sites(true, 12).indexed) {
    final int n = onGlyphs ? 1 : kit.count(6, 2);
    for (int i = 0; i < n; i++) {
      final (double ox, double oy) = onGlyphs
          ? (
              (kit.rng() - 0.5) * site.w * 1.6,
              -site.h * (0.6 + kit.rng() * 0.6),
            )
          : kit.scatter(site);
      items.add((
        site,
        ox,
        oy,
        kit.size * (0.14 + kit.rng() * 0.16),
        kit.color(si + i),
        kit.rng() * 2,
      ));
    }
  }
  return (ui.Canvas canvas, double time) {
    final List<GlyphAnchor> anchors = kit.anchorsAt(time);
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final (
          OrnamentSite site,
          double ox,
          double oy,
          double r,
          int c,
          double phase,
        )
        in items) {
      final double e = time - site.start - phase * (onGlyphs ? 0 : 0.2);
      if (e < 0) continue;
      final (double px, double py, double pa, _) = kit.pos(site, anchors);
      final double pop = onGlyphs
          ? easeOutBack(e / 0.25, 2.5) *
                math.max(0, 1 - clamp01((e - 0.25) / 0.6))
          : easeOutBack(e / 0.3, 2.2) *
                (0.75 + 0.25 * math.sin(time * 5 + phase * 3));
      final double scale = pop * (1 - x);
      if (scale <= 0.01) continue;
      canvas.save();
      canvas.translate(px + ox, py + oy);
      canvas.rotate(time * 0.8 + phase);
      canvas.drawPath(_star4(r * scale), _fill(c, pa * clamp01(e / 0.05)));
      canvas.restore();
    }
  };
}

OrnamentPainter _cross(OrnamentKit kit) {
  final List<List<double>> items = <List<double>>[];
  for (final (int si, OrnamentSite site) in kit.sites(true, 6).indexed) {
    final int n = kit.spec.placement == OrnamentPlacement.corners
        ? 1
        : kit.count(7, 2);
    for (int i = 0; i < n; i++) {
      final (
        double ox,
        double oy,
      ) = kit.spec.placement == OrnamentPlacement.corners
          ? (0.0, 0.0)
          : kit.scatter(site);
      items.add(<double>[
        site.x + ox,
        site.y + oy,
        kit.size * (0.12 + kit.rng() * 0.16),
        kit.rng() * 0.6,
        site.start + kit.rng() * 0.3,
        kit.color(si + i).toDouble(),
        (kit.rng() - 0.5) * 2,
      ]);
    }
  }
  return (ui.Canvas canvas, double time) {
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final List<double> s in items) {
      final double e = time - s[4];
      if (e < 0) continue;
      final double scale = easeOutBack(e / 0.3, 2.4) * (1 - easeInBack(x, 1.6));
      if (scale <= 0.01) continue;
      final double r = s[2] * scale;
      canvas.save();
      canvas.translate(
        s[0],
        s[1] - kit.base * 0.1 * math.sin(time * 1.4 + s[3] * 9),
      );
      canvas.rotate(s[3] + s[6] * time * 0.6);
      final Paint p = _stroke(s[5].toInt(), 0.92, math.max(1.4, r * 0.32))
        ..strokeCap = StrokeCap.butt;
      canvas.drawLine(Offset(-r, 0), Offset(r, 0), p);
      canvas.drawLine(Offset(0, -r), Offset(0, r), p);
      canvas.restore();
    }
  };
}

OrnamentPainter _chevrons(OrnamentKit kit) {
  final List<OrnamentSite> sites = kit.sites(false, 3);
  final int n = math.max(3, kit.count(4, 3));
  return (ui.Canvas canvas, double time) {
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final (int si, OrnamentSite site) in sites.indexed) {
      final double e = time - site.start;
      if (e < 0) continue;
      final double angle = kit.spec.placement == OrnamentPlacement.around
          ? 0
          : site.angle + math.pi;
      final double dir = kit.spec.placement == OrnamentPlacement.lineStart
          ? -1
          : 1;
      final double s = kit.size * 0.3;
      canvas.save();
      canvas.translate(site.x, site.y);
      canvas.rotate(angle);
      for (int i = 0; i < n; i++) {
        final double local = e - i * 0.06;
        if (local < 0) continue;
        final double march = fract(time * 1.2 - i / n);
        final double alpha =
            clamp01(local / 0.15) * (1 - x) * (0.35 + 0.65 * (1 - march));
        final double cx =
            -dir * (i * s * 1.05 + s * 0.5) +
            dir * march * s * 0.4 -
            dir * x * kit.size;
        final ui.Path path = ui.Path()
          ..moveTo(cx - dir * s * 0.45, -s * 0.6)
          ..lineTo(cx + dir * s * 0.15, 0)
          ..lineTo(cx - dir * s * 0.45, s * 0.6);
        canvas.drawPath(
          path,
          _stroke(kit.color(si + i), alpha, math.max(1.6, s * 0.28))
            ..strokeCap = StrokeCap.square,
        );
      }
      canvas.restore();
    }
  };
}

OrnamentPainter _confetti(OrnamentKit kit) {
  final List<List<double>> items = <List<double>>[];
  for (final (int si, OrnamentSite site) in kit.sites(true, 6).indexed) {
    final int n = kit.count(
      kit.spec.placement == OrnamentPlacement.screen ? 26 : 12,
      3,
    );
    for (int i = 0; i < n; i++) {
      final (double ox, double oy) = kit.scatter(site);
      items.add(<double>[
        site.x + ox,
        site.y + oy,
        kit.size * (0.08 + kit.rng() * 0.08),
        kit.rng() * kTau,
        2 + kit.rng() * 4,
        site.start + kit.rng() * 0.5,
        kit.color(si + i).toDouble(),
        kit.rng() * kTau,
      ]);
    }
  }
  return (ui.Canvas canvas, double time) {
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final List<double> s in items) {
      final double e = time - s[5];
      if (e < 0) continue;
      final double fall =
          kit.base * 0.4 * e + kit.height * 0.25 * easeInQuad(x);
      final double sway = kit.base * 0.25 * math.sin(e * 2.2 + s[7]);
      final double flip = math.cos(e * s[4] + s[7]);
      final double alpha = clamp01(e / 0.12) * (1 - x);
      canvas.save();
      canvas.translate(s[0] + sway, s[1] + fall);
      canvas.rotate(s[3] + e * 1.5);
      canvas.scale(1, flip.abs() < 0.12 ? 0.12 : flip.abs());
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: s[2], height: s[2] * 0.55),
        _fill(s[6].toInt(), alpha),
      );
      canvas.restore();
    }
  };
}

OrnamentPainter _shards(OrnamentKit kit) {
  final List<List<double>> items = <List<double>>[];
  for (final (int si, OrnamentSite site) in kit.sites(true, 6).indexed) {
    final int n = kit.count(9, 3);
    for (int i = 0; i < n; i++) {
      final (double ox, double oy) = kit.scatter(site);
      items.add(<double>[
        site.x + ox,
        site.y + oy,
        kit.size * (0.15 + kit.rng() * 0.25),
        kit.rng() * kTau,
        (kit.rng() - 0.5) * 3,
        site.start + kit.rng() * 0.15,
        kit.color(si + i).toDouble(),
        kit.rng(),
      ]);
    }
  }
  return (ui.Canvas canvas, double time) {
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final List<double> s in items) {
      final double e = time - s[5];
      if (e < 0) continue;
      final double fly = 1 - easeOutCubic(e / 0.5);
      final double dx = (s[0] - kit.cx) * 0.6 * fly;
      final double dy = (s[1] - kit.cy) * 0.6 * fly;
      final double scatterOut = easeInCubic(x);
      final double alpha = clamp01(e / 0.08) * (1 - x);
      final double r = s[2];
      canvas.save();
      canvas.translate(
        s[0] - dx + (s[0] - kit.cx) * scatterOut * 0.8,
        s[1] -
            dy +
            (s[1] - kit.cy) * scatterOut * 0.8 +
            kit.base * 0.05 * math.sin(time * 1.3 + s[7] * 7),
      );
      canvas.rotate(s[3] + s[4] * (fly * 2 + time * 0.3));
      final ui.Path tri = ui.Path()
        ..moveTo(0, -r)
        ..lineTo(r * 0.55, r * (0.3 + s[7] * 0.4))
        ..lineTo(-r * 0.5, r * 0.45)
        ..close();
      canvas.drawPath(tri, _fill(s[6].toInt(), alpha));
      canvas.restore();
    }
  };
}

OrnamentPainter _streaks(OrnamentKit kit) {
  final bool screen = kit.spec.placement == OrnamentPlacement.screen;
  final List<List<double>> items = <List<double>>[];
  for (final (int si, OrnamentSite site) in kit.sites(true, 4).indexed) {
    final int n = kit.count(screen ? 18 : 6, 3);
    for (int i = 0; i < n; i++) {
      final (double ox, double oy) = screen
          ? kit.scatter(site)
          : (0.0, (kit.rng() - 0.5) * kit.size * 1.4);
      items.add(<double>[
        site.x + ox,
        site.y + oy,
        kit.size * (screen ? 0.8 + kit.rng() * 2.4 : 0.5 + kit.rng() * 0.9),
        math.max(1, kit.size * (0.02 + kit.rng() * 0.03)),
        0.6 + kit.rng() * 1.2,
        kit.rng(),
        kit.color(si + i).toDouble(),
        site.angle,
      ]);
    }
  }
  return (ui.Canvas canvas, double time) {
    final double x = kit.exit(time);
    if (x >= 1) return;
    final double e0 = time - kit.start;
    if (e0 < 0) return;
    for (final List<double> s in items) {
      // 速度线一直往上（画面）或往外（行首 / 行尾）刷过去，循环。
      final double cycle = fract(e0 * s[4] + s[5]);
      final double travel = (cycle - 0.5) * kit.size * (screen ? 6 : 2.4);
      final double dirX = screen ? 0 : math.cos(s[7]);
      final double dirY = screen ? -1 : math.sin(s[7]);
      final double cx = s[0] + dirX * travel;
      final double cy = s[1] + dirY * travel;
      final double alpha =
          math.sin(cycle * math.pi) * clamp01(e0 / 0.2) * (1 - x) * 0.85;
      final double half = s[2] / 2;
      canvas.drawLine(
        Offset(cx - dirX * half, cy - dirY * half),
        Offset(cx + dirX * half, cy + dirY * half),
        _stroke(s[6].toInt(), alpha, s[3]),
      );
    }
  };
}

OrnamentPainter _petals(OrnamentKit kit) {
  final List<List<double>> items = <List<double>>[];
  for (final (int si, OrnamentSite site) in kit.sites(true, 4).indexed) {
    final int n = kit.count(
      kit.spec.placement == OrnamentPlacement.screen ? 16 : 8,
      3,
    );
    for (int i = 0; i < n; i++) {
      final (double ox, double oy) = kit.scatter(site);
      items.add(<double>[
        site.x + ox,
        site.y + oy - site.h * 0.6,
        kit.size * (0.1 + kit.rng() * 0.1),
        kit.rng() * kTau,
        0.3 + kit.rng() * 0.5,
        kit.rng() * kTau,
        kit.color(si + i).toDouble(),
        site.start + kit.rng() * 0.8,
      ]);
    }
  }
  return (ui.Canvas canvas, double time) {
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final List<double> s in items) {
      final double e = time - s[7];
      if (e < 0) continue;
      final double fall = wrapD(e * kit.base * s[4], kit.height * 0.9);
      final double sway = kit.base * 0.4 * math.sin(e * 1.4 + s[5]);
      final double alpha = clamp01(e / 0.3) * (1 - x) * 0.9;
      canvas.save();
      canvas.translate(s[0] + sway, s[1] + fall);
      canvas.rotate(s[3] + math.sin(e * 1.8 + s[5]) * 0.8);
      canvas.scale(1, 0.45 + 0.4 * math.cos(e * 2.6 + s[5]).abs());
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: s[2] * 1.6, height: s[2]),
        _fill(s[6].toInt(), alpha),
      );
      canvas.restore();
    }
  };
}

// ─── 线类 ───────────────────────────────────────────────────────────────

ui.Path _polyline(List<Offset> points) {
  final ui.Path path = ui.Path();
  for (int i = 0; i < points.length; i++) {
    if (i == 0) {
      path.moveTo(points[i].dx, points[i].dy);
    } else {
      path.lineTo(points[i].dx, points[i].dy);
    }
  }
  return path;
}

/// 沿 site 的方向画的一条线段（around：围在文字上下；其余：从布点往外）。
(Offset, Offset) _lineSpan(OrnamentKit kit, OrnamentSite site, int k) {
  if (kit.spec.placement == OrnamentPlacement.around ||
      kit.spec.placement == OrnamentPlacement.behind) {
    final double y = site.y + (k.isEven ? -1 : 1) * (site.h + kit.base * 0.25);
    return (Offset(site.x - site.w, y), Offset(site.x + site.w, y));
  }
  if (kit.spec.placement == OrnamentPlacement.screen) {
    final double y = site.y + (k.isEven ? -0.7 : 0.7) * site.h;
    return (Offset(site.x - site.w, y), Offset(site.x + site.w, y));
  }
  final double len = kit.size * 2.2;
  final Offset from = Offset(site.x, site.y);
  final Offset dir = Offset(math.cos(site.angle), math.sin(site.angle));
  return (from, from + dir * len);
}

OrnamentPainter _zigzag(OrnamentKit kit) {
  final List<OrnamentSite> sites = kit.sites(false, 3);
  final int lines = kit.spec.placement == OrnamentPlacement.around ? 2 : 1;
  return (ui.Canvas canvas, double time) {
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final (int si, OrnamentSite site) in sites.indexed) {
      for (int k = 0; k < lines; k++) {
        final double e = time - site.start - k * 0.1;
        if (e < 0) continue;
        final (Offset a, Offset b) = _lineSpan(kit, site, k);
        final Offset d = b - a;
        final double len = d.distance;
        if (len < 1) continue;
        final Offset n = Offset(-d.dy / len, d.dx / len);
        final double amp = kit.size * 0.16;
        final int teeth = math.max(4, (len / (kit.size * 0.3)).round());
        final double head = easeOutCubic(e / 0.5);
        final double tail = easeInCubic(x);
        final List<Offset> points = <Offset>[];
        for (int i = 0; i <= teeth; i++) {
          final double f = i / teeth;
          if (f < tail || f > head) continue;
          points.add(
            a +
                d * f +
                n *
                    (i.isEven ? amp : -amp) *
                    (1 + 0.15 * math.sin(time * 6 + i)),
          );
        }
        if (points.length < 2) continue;
        canvas.drawPath(
          _polyline(points),
          _stroke(kit.color(si + k), 0.9, math.max(1.4, kit.size * 0.05)),
        );
      }
    }
  };
}

OrnamentPainter _wave(OrnamentKit kit) {
  final List<OrnamentSite> sites = kit.sites(false, 3);
  final int lines =
      kit.spec.placement == OrnamentPlacement.lineStart ||
          kit.spec.placement == OrnamentPlacement.lineEnd
      ? 2
      : math.max(2, kit.count(3, 2));
  return (ui.Canvas canvas, double time) {
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final (int si, OrnamentSite site) in sites.indexed) {
      for (int k = 0; k < lines; k++) {
        final double e = time - site.start - k * 0.12;
        if (e < 0) continue;
        final (Offset a0, Offset b0) = _lineSpan(kit, site, k);
        final Offset d = b0 - a0;
        final double len = d.distance;
        if (len < 1) continue;
        final Offset n = Offset(-d.dy / len, d.dx / len);
        final Offset shift = n * (k * kit.size * 0.22);
        final double amp = kit.size * 0.12;
        final double head = easeOutCubic(e / 0.7);
        final double tail = easeInCubic(x);
        const int steps = 40;
        final List<Offset> points = <Offset>[];
        for (int i = 0; i <= steps; i++) {
          final double f = i / steps;
          if (f < tail || f > head) continue;
          points.add(
            a0 +
                shift +
                d * f +
                n * amp * math.sin(f * kTau * 2.5 - time * 3 + k),
          );
        }
        if (points.length < 2) continue;
        canvas.drawPath(
          _polyline(points),
          _stroke(kit.color(si + k), 0.75, math.max(1.2, kit.size * 0.04)),
        );
      }
    }
  };
}

OrnamentPainter _underline(OrnamentKit kit) {
  final List<OrnamentSite> sites = kit.sites(false, 24);
  return (ui.Canvas canvas, double time) {
    final List<GlyphAnchor> anchors = kit.anchorsAt(time);
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final (int si, OrnamentSite site) in sites.indexed) {
      final double e = time - site.start;
      if (e < 0) continue;
      final (double px, double py, double pa, double ps) = kit.pos(
        site,
        anchors,
      );
      final double grow = easeOutCubic(e / 0.25);
      final double w = ps * 0.9 * kit.spec.scale * grow * (1 - x);
      if (w <= 0.5) continue;
      final double y = py + ps * 0.62;
      canvas.drawLine(
        Offset(px - w / 2, y),
        Offset(px + w / 2, y),
        _stroke(kit.color(si), pa * 0.9, math.max(2, ps * 0.09))
          ..strokeCap = StrokeCap.butt,
      );
    }
  };
}

OrnamentPainter _dotsLine(OrnamentKit kit) {
  final bool onGlyphs = kit.spec.placement == OrnamentPlacement.glyphs;
  final List<OrnamentSite> sites = kit.sites(false, 24);
  final int dots = math.max(4, kit.count(7, 4));
  return (ui.Canvas canvas, double time) {
    final List<GlyphAnchor> anchors = kit.anchorsAt(time);
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final (int si, OrnamentSite site) in sites.indexed) {
      final double e = time - site.start;
      if (e < 0) continue;
      if (onGlyphs) {
        final (double px, double py, double pa, double ps) = kit.pos(
          site,
          anchors,
        );
        for (int i = 0; i < 3; i++) {
          final double pop = easeOutBack((e - i * 0.05) / 0.25, 2.4) * (1 - x);
          if (pop <= 0.01) continue;
          canvas.drawCircle(
            Offset(px + (i - 1) * ps * 0.28, py - ps * 0.78),
            ps * 0.05 * pop * kit.spec.scale,
            _fill(kit.color(si + i), pa),
          );
        }
        continue;
      }
      final (Offset a, Offset b) = _lineSpan(kit, site, 0);
      for (int i = 0; i < dots; i++) {
        final double f = (i + 0.5) / dots;
        final double pop =
            easeOutBack((e - i * 0.05) / 0.3, 2.2) * (1 - easeInBack(x, 1.4));
        if (pop <= 0.01) continue;
        final double r =
            kit.size * 0.06 * (1 + 0.3 * math.sin(time * 4 - i)) * pop;
        canvas.drawCircle(
          Offset.lerp(a, b, f)!,
          r,
          _fill(kit.color(si + i), 0.9),
        );
      }
    }
  };
}

OrnamentPainter _glints(OrnamentKit kit) {
  final List<OrnamentSite> sites = kit.sites(false, 16);
  final List<(double, double, double)> offsets = <(double, double, double)>[
    for (int i = 0; i < sites.length; i++)
      ((kit.rng() - 0.5) * 0.8, (kit.rng() - 0.5) * 0.8, kit.rng()),
  ];
  return (ui.Canvas canvas, double time) {
    final List<GlyphAnchor> anchors = kit.anchorsAt(time);
    final double x = kit.exit(time);
    if (x >= 1) return;
    for (final (int si, OrnamentSite site) in sites.indexed) {
      final double e = time - site.start;
      if (e < 0) continue;
      final (double px, double py, double pa, double ps) = kit.pos(
        site,
        anchors,
      );
      final (double ox, double oy, double phase) = offsets[si];
      // 唱到时一闪，之后偶尔再闪。
      final double first = math.exp(-e / 0.18) * clamp01(e / 0.03);
      final double again =
          math.max(0, math.sin((time + phase * 5) * 2.3) - 0.85) / 0.15;
      final double k = math.max(first, again * 0.7) * (1 - x);
      if (k <= 0.01) continue;
      final double r = ps * 0.35 * kit.spec.scale * (0.5 + 0.5 * k);
      canvas.save();
      canvas.translate(px + ox * ps, py + oy * ps);
      final Paint p = _stroke(kit.color(si), pa * k, math.max(1, r * 0.12));
      canvas.drawLine(Offset(-r, 0), Offset(r, 0), p);
      canvas.drawLine(Offset(0, -r), Offset(0, r), p);
      canvas.drawCircle(Offset.zero, r * 0.16, _fill(kit.color(si), pa * k));
      canvas.restore();
    }
  };
}
