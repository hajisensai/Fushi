/// 跟着每段字走的装饰（folia `sonnetGuides.ts` / `sonnetFrameDecor.ts` /
/// `sonnetTextFixedGeo.ts` / `sonnetStaffView.ts`）：入场轨迹线与碎片爆散、开口画框、
/// 字后的固定几何块、纯音乐时的《La Folia》五线谱。坐标均为段局部（段中心为原点）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_motion.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_typography.dart';

final Paint _p = Paint();

Paint _stroke(Color c, double w, double a) => _p
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeCap = StrokeCap.butt
  ..color = c.withValues(alpha: a.clamp(0.0, 1.0));

Paint _fill(Color c, double a) => _p
  ..style = PaintingStyle.fill
  ..color = c.withValues(alpha: a.clamp(0.0, 1.0));

Offset _bezier(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
  final double mt = 1 - t;
  return p0 * (mt * mt * mt) +
      p1 * (3 * mt * mt * t) +
      p2 * (3 * mt * t * t) +
      p3 * (t * t * t);
}

// ---------------------------------------------------------------------------
// 轨迹线
// ---------------------------------------------------------------------------

class _GuideShape {
  _GuideShape(this.type, this.size, this.angle, this.speed, this.rotSpeed);

  final int type;
  final double size;
  final double angle;
  final double speed;
  final double rotSpeed;
}

class _Trail {
  _Trail(this.p0, this.p1, this.p2, this.p3, this.delay);

  final Offset p0;
  final Offset p1;
  final Offset p2;
  final Offset p3;
  final double delay;
}

/// 字出现前从入场方向划进来的彗星轨迹，落点处碎片爆开（folia 用 Math.random，这里用段种子）。
class SonnetGuide {
  SonnetGuide({
    required SonnetSegment segment,
    required SonnetPlacement placement,
    required this.color,
    required double fontSize,
    required double textStart,
    required int seed,
  }) : x = placement.x,
       y = placement.y,
       isHero = isSonnetEmphasisRole(placement.resolvedRole) {
    final SonnetRng rng = SonnetRng(seed);
    final double fallback = placement.timingPhase < 0.5 ? -1 : 1;
    final double sx = placement.enterX != 0
        ? placement.enterX
        : fallback * fontSize * 1.8;
    final double sy = placement.enterY != 0
        ? placement.enterY
        : -fontSize * 0.9;
    _p0 = Offset(sx, sy);
    _p1 = Offset(sx * 0.6, sy * 0.4);
    _p2 = Offset(sx * 0.2, sy * 0.1);
    _alpha = isHero ? 0.82 : 0.55;
    final int numShapes = isHero ? 6 : 3;
    for (int i = 0; i < numShapes; i++) {
      _shapes.add(
        _GuideShape(
          (rng.next() * 4).floor(),
          (isHero ? 3 : 1.5) + rng.next() * 3.5,
          rng.next() * math.pi * 2,
          (15 + rng.next() * 45) * (isHero ? 1 : 0.7),
          (rng.next() - 0.5) * 8,
        ),
      );
    }
    if (isHero || rng.next() > 0.4) {
      final double d = rng.next() > 0.5 ? 1 : -1;
      final double yo = (rng.next() - 0.5) * fontSize * 0.8;
      _trails.add(
        _Trail(
          Offset(-d * fontSize * 2.5, yo + fontSize * 1.5),
          Offset(-d * fontSize * 0.8, yo - fontSize * 2.0),
          Offset(d * fontSize * 0.8, yo + fontSize * 2.0),
          Offset(d * fontSize * 2.5, yo - fontSize * 1.5),
          rng.next() * 0.15,
        ),
      );
    }
    if (isHero || rng.next() > 0.6) {
      final double d = rng.next() > 0.5 ? 1 : -1;
      _trails.add(
        _Trail(
          Offset(-fontSize * 2.0, -d * fontSize * 1.8),
          Offset(fontSize * 2.0, d * fontSize * 1.8),
          Offset(-fontSize * 2.0, d * fontSize * 1.8),
          Offset(fontSize * 2.0, -d * fontSize * 1.8),
          rng.next() * 0.1,
        ),
      );
    }
    if (rng.next() > 0.4) {
      final double length = fontSize * (1.2 + rng.next() * 1.5);
      final double thickness = (isHero ? 6 : 3) + rng.next() * 8;
      final double angle = (rng.next() - 0.5) * math.pi;
      final double rx = (rng.next() - 0.5) * fontSize * 1.2;
      final double ry = (rng.next() - 0.5) * fontSize * 1.2;
      _rect = (
        Offset(rx, ry),
        Offset(rx + math.cos(angle) * length, ry + math.sin(angle) * length),
        thickness,
        rng.next() * 0.15,
        0.25 + rng.next() * 0.2,
      );
    }
    final double lead = math.min(
      0.38,
      math.max(0.2, 0.18 + (segment.end - segment.start) * 0.1),
    );
    start = textStart - lead;
    end = textStart + 0.65;
  }

  final double x;
  final double y;
  final bool isHero;
  final Color color;
  late final double start;
  late final double end;
  late final Offset _p0;
  late final Offset _p1;
  late final Offset _p2;
  static const Offset _p3 = Offset.zero;
  late final double _alpha;
  final List<_GuideShape> _shapes = <_GuideShape>[];
  final List<_Trail> _trails = <_Trail>[];
  (Offset, Offset, double, double, double)? _rect;

  double get maxAlpha => isHero ? 0.95 : 0.7;

  bool activeAt(double time) => time >= start && time <= end;

  /// 画在段局部坐标（调用方已平移到段中心，并乘好 [maxAlpha]）。
  void paint(Canvas canvas, double time, double alphaMul) {
    final double progress = sonnetClamp01(
      (time - start) / math.max(0.001, end - start),
    );
    final double draw = math.min(1, math.max(0, progress / 0.35));
    final double fade = 1 - math.min(1, math.max(0, (progress - 0.4) / 0.3));
    final double a = alphaMul;
    if (draw > 0 && fade > 0) {
      Offset prev = _p0;
      for (int i = 1; i <= 20; i++) {
        final Offset pt = _bezier(_p0, _p1, _p2, _p3, (i / 20) * draw);
        final double k = math.pow(i / 20, 2).toDouble();
        canvas.drawLine(
          prev,
          pt,
          _stroke(
            color,
            (isHero ? 2.5 : 1.5) + k * (isHero ? 5.0 : 3.0),
            math.min(1, k * _alpha * fade * 1.6) * a,
          ),
        );
        prev = pt;
      }
      final Offset head = _bezier(_p0, _p1, _p2, _p3, draw);
      canvas.drawCircle(head, isHero ? 14 : 9, _fill(color, 0.5 * fade * a));
      canvas.drawCircle(head, isHero ? 4.5 : 3, _fill(Colors.white, fade * a));
    }
    for (final _Trail t in _trails) {
      final double lp = (progress - t.delay) / 0.55;
      if (lp <= 0 || lp >= 1.3 || fade <= 0) continue;
      final double headT = math.min(1, lp);
      final double tailT = math.max(0, lp - 0.35);
      if (headT > tailT) {
        Offset prev = _bezier(t.p0, t.p1, t.p2, t.p3, tailT);
        for (int i = 1; i <= 25; i++) {
          final Offset pos = _bezier(
            t.p0,
            t.p1,
            t.p2,
            t.p3,
            tailT + (i / 25) * (headT - tailT),
          );
          final double k = math.pow(i / 25, 2).toDouble();
          canvas.drawLine(
            prev,
            pos,
            _stroke(
              color,
              (isHero ? 2 : 1) + k * (isHero ? 5 : 2.5),
              k * _alpha * fade * 0.9 * a,
            ),
          );
          prev = pos;
        }
      }
      if (headT > 0 && headT < 1) {
        final Offset hp = _bezier(t.p0, t.p1, t.p2, t.p3, headT);
        canvas.drawCircle(hp, isHero ? 7 : 4, _fill(color, 0.9 * fade * a));
        canvas.drawCircle(
          hp,
          isHero ? 2.5 : 1.5,
          _fill(Colors.white, fade * a),
        );
        canvas.drawCircle(
          hp,
          isHero ? 20 : 12,
          _stroke(color, isHero ? 2 : 1, 0.4 * fade * a),
        );
      }
    }
    final (Offset, Offset, double, double, double)? r = _rect;
    if (r != null) {
      final double lp = (progress - r.$4) / r.$5;
      if (lp > 0 && lp < 1.3 && fade > 0) {
        final double headT = math.min(1, math.max(0, lp * 1.5));
        final double tailT = math.min(1, math.max(0, (lp - 0.3) * 1.5));
        if (headT > tailT) {
          final Offset h = Offset.lerp(r.$1, r.$2, headT)!;
          final Offset tl = Offset.lerp(r.$1, r.$2, tailT)!;
          canvas.drawLine(tl, h, _stroke(color, r.$3, _alpha * fade * 0.7 * a));
          canvas.drawLine(
            tl,
            h,
            _stroke(Colors.white, r.$3 * 0.3, _alpha * fade * 0.9 * a),
          );
        }
      }
    }
    final double burst = math.min(1, math.max(0, (progress - 0.3) / 0.7));
    final double ease = 1 - math.pow(1 - burst, 3).toDouble();
    for (final _GuideShape s in _shapes) {
      final double alpha =
          (1 - burst) * (isHero ? 1 : 0.8) * (isHero ? 0.8 : 0.6) * a;
      if (alpha <= 0.001) continue;
      canvas.save();
      canvas.translate(
        math.cos(s.angle) * s.speed * ease,
        math.sin(s.angle) * s.speed * ease,
      );
      canvas.rotate(s.rotSpeed * burst);
      canvas.scale(1 - burst * 0.4);
      final double z = s.size;
      switch (s.type) {
        case 0:
          canvas.drawCircle(Offset.zero, z, _fill(color, alpha));
        case 1:
          canvas.drawRect(
            Rect.fromLTWH(-z, -z, z * 2, z * 2),
            _fill(color, alpha),
          );
        case 2:
          final Paint sp = _stroke(color, 2, alpha);
          canvas.drawLine(Offset(-z, 0), Offset(z, 0), sp);
          canvas.drawLine(Offset(0, -z), Offset(0, z), sp);
        default:
          canvas.drawPath(
            Path()
              ..moveTo(0, -z)
              ..lineTo(z, 0)
              ..lineTo(0, z)
              ..lineTo(-z, 0)
              ..close(),
            _fill(color, alpha),
          );
      }
      canvas.restore();
    }
  }
}

// ---------------------------------------------------------------------------
// 开口画框
// ---------------------------------------------------------------------------

/// 段外一圈从四边描出的画框，角上再长出刻度 / 花 / 括号 / 三角（40% 的段有）。
class SonnetFrameDecor {
  SonnetFrameDecor._(
    this.x,
    this.y,
    this.rotation,
    this.variant,
    this.halfW,
    this.halfH,
    this.cornerGap,
    this.pad,
    this.color,
    this.strokeWidth,
    this.fontSize,
    this.start,
    this.end,
  );

  final double x;
  final double y;
  final double rotation;
  final int variant;
  final double halfW;
  final double halfH;
  final double cornerGap;
  final double pad;
  final Color color;
  final double strokeWidth;
  final double fontSize;
  final double start;
  final double end;

  static (bool, int) specOf(SonnetSegment s) {
    final int hash = hashSonnetSeed(
      '${s.text}:${s.startOffset}:${s.endOffset}:frame-decor',
    );
    return ((hash & 1023) / 1024 < 0.4, (hash >> 10) % 4);
  }

  static SonnetFrameDecor? build({
    required SonnetSegment segment,
    required SonnetPlacement placement,
    required Color primary,
    required double fontSize,
    required double shotStart,
    required double shotEnd,
    required double firstGlyphStart,
  }) {
    if (placement.resolvedRole == SonnetSegmentRole.decoration) return null;
    final (bool applied, int variant) = specOf(segment);
    if (!applied) return null;
    final double pad = (fontSize * 0.22).clamp(8.0, 20.0);
    final int quarter = (placement.rotation / (math.pi / 2)).round();
    final bool odd =
        (placement.rotation - quarter * math.pi / 2).abs() < 1e-6 &&
        quarter.abs() % 2 == 1;
    final double w = odd ? placement.measuredHeight : placement.measuredWidth;
    final double h = odd ? placement.measuredWidth : placement.measuredHeight;
    final double halfW = w / 2 + pad;
    final double halfH = h / 2 + pad;
    final double cornerGap =
        (math.min(halfW, halfH) * (variant == 1 ? 0.42 : 0.3)).clamp(6.0, 30.0);
    final Color dim = Color.fromARGB(
      255,
      ((primary.r * 255) * 0.55).round(),
      ((primary.g * 255) * 0.55).round(),
      ((primary.b * 255) * 0.55).round(),
    );
    final double grow =
        resolveSonnetGlyphMotionDuration(shotStart, shotEnd) * 1.25;
    return SonnetFrameDecor._(
      placement.x,
      placement.y,
      placement.rotation,
      variant,
      halfW,
      halfH,
      cornerGap,
      pad,
      dim,
      (fontSize * 0.03).clamp(1.2, 2.2),
      fontSize,
      firstGlyphStart,
      firstGlyphStart + grow,
    );
  }

  List<(Offset, double, double)> get _corners => <(Offset, double, double)>[
    (Offset(-halfW, -halfH), -1, -1),
    (Offset(halfW, -halfH), 1, -1),
    (Offset(halfW, halfH), 1, 1),
    (Offset(-halfW, halfH), -1, 1),
  ];

  (Offset, Offset) _side(int side) {
    final List<(Offset, double, double)> cs = _corners;
    final Offset from = cs[side].$1;
    final Offset to = cs[(side + 1) % 4].$1;
    final double ix = to.dx == from.dx
        ? 0
        : cornerGap * (to.dx > from.dx ? 1 : -1);
    final double iy = to.dy == from.dy
        ? 0
        : cornerGap * (to.dy > from.dy ? 1 : -1);
    return (Offset(from.dx + ix, from.dy + iy), Offset(to.dx - ix, to.dy - iy));
  }

  double _ornament(double eased, int corner) =>
      easeSonnetElasticOut(sonnetClamp01((eased - 0.35 - corner * 0.14) / 0.3));

  void paint(Canvas canvas, double time) {
    final double eased = easeSonnetExpoOut(
      sonnetClamp01((time - start) / math.max(0.001, end - start)),
    );
    if (eased <= 0) return;
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(rotation);
    final bool dashed = variant == 3;
    for (int side = 0; side < 4; side++) {
      final double sp = sonnetClamp01((eased - side * 0.2) / 0.4);
      if (sp <= 0) continue;
      final (Offset a, Offset b) = _side(side);
      final Offset tip = Offset.lerp(a, b, sp)!;
      final Paint pt = _stroke(color, strokeWidth, 0.85);
      if (!dashed) {
        canvas.drawLine(a, tip, pt);
        continue;
      }
      final double len = (b - a).distance;
      if (len < 1) continue;
      final Offset u = (b - a) / len;
      final double dash = (fontSize * 0.14).clamp(5.0, 8.0);
      final double gap = dash * 0.7;
      final double traced = len * sp;
      for (double o = 0; o + dash <= traced + 0.001; o += dash + gap) {
        canvas.drawLine(a + u * o, a + u * (o + dash), pt);
      }
    }
    final List<(Offset, double, double)> cs = _corners;
    for (int i = 0; i < 4; i++) {
      final double op = _ornament(eased, i);
      if (op <= 0.02) continue;
      final Offset c = cs[i].$1;
      final double sx = cs[i].$2;
      final double sy = cs[i].$3;
      switch (variant) {
        case 0:
          final double arm = (pad * 0.8).clamp(5.0, 12.0);
          final Offset inner = c + Offset(sx * 3, sy * 3);
          canvas.drawPath(
            Path()
              ..moveTo(inner.dx + sx * arm * op, inner.dy)
              ..lineTo(inner.dx, inner.dy)
              ..lineTo(inner.dx, inner.dy + sy * arm * op),
            _stroke(color, strokeWidth, 0.9 * math.min(1, op)),
          );
        case 1:
          final double r = (pad * 0.55).clamp(4.0, 9.0);
          final double petal = r * 0.44 * op;
          if (petal > 0) {
            for (final Offset d in <Offset>[
              Offset(-r, 0),
              Offset(r, 0),
              Offset(0, -r),
              Offset(0, r),
            ]) {
              canvas.drawCircle(c + d, petal, _fill(color, 0.8));
            }
            canvas.drawCircle(
              c,
              math.max(0, r * 0.3 * op),
              _fill(Colors.white, 0.5),
            );
          }
        case 2:
          final double arm = pad.clamp(6.0, 14.0);
          final Offset inner = c + Offset(sx * 2.5, sy * 2.5);
          canvas.drawPath(
            Path()
              ..moveTo(inner.dx + sx * arm * op, inner.dy)
              ..lineTo(inner.dx, inner.dy)
              ..lineTo(inner.dx, inner.dy + sy * arm * op),
            _stroke(color, strokeWidth * 1.4, 0.9),
          );
          canvas.drawPath(
            Path()
              ..moveTo(inner.dx + sx * (arm * op + 4), inner.dy + sy * 4)
              ..lineTo(inner.dx + sx * 4, inner.dy + sy * 4)
              ..lineTo(inner.dx + sx * 4, inner.dy + sy * (arm * op + 4)),
            _stroke(color, strokeWidth * 0.8, 0.5),
          );
          final (Offset a, Offset b) = _side(i);
          final Offset mid = (a + b) / 2;
          final double size = (pad * 0.45).clamp(3.5, 7.0) * op;
          canvas.drawPath(
            Path()
              ..moveTo(mid.dx, mid.dy - size)
              ..lineTo(mid.dx + size, mid.dy)
              ..lineTo(mid.dx, mid.dy + size)
              ..lineTo(mid.dx - size, mid.dy)
              ..close(),
            _fill(color, 0.85),
          );
        default:
          final double size = (pad * 0.6).clamp(4.0, 9.0);
          final Offset diag = Offset(sx, sy) / math.sqrt2;
          final Offset perp = Offset(sy, -sx) / math.sqrt2;
          final Offset tip = c + diag * (2 + size * op);
          final Offset base = c + diag * 2;
          final double half = size * 0.7 * op;
          canvas.drawPath(
            Path()
              ..moveTo(tip.dx, tip.dy)
              ..lineTo((base + perp * half).dx, (base + perp * half).dy)
              ..lineTo((base - perp * half).dx, (base - perp * half).dy)
              ..close(),
            _fill(color, 0.85),
          );
          canvas.drawCircle(c, strokeWidth, _fill(color, 0.9));
      }
    }
    canvas.restore();
  }
}

// ---------------------------------------------------------------------------
// 字后的固定几何（随字入场，像背景浮标）
// ---------------------------------------------------------------------------

class SonnetTextFixedGeo {
  SonnetTextFixedGeo({
    required this.seed,
    required this.isChorusEffect,
    required double fontSize,
    required double layoutWidth,
    required Color primary,
    required this.secondary,
    required this.accent,
  }) : color = seed.isEven ? primary : secondary,
       alpha = (isChorusEffect ? 0.4 : 0.25) + (seed % 10) * 0.03,
       fontSize = fontSize {
    final double mul = isChorusEffect ? 1.5 + (seed % 5) * 0.3 : 1;
    width = math.max(fontSize * 2.5 * mul, layoutWidth * 0.12 * mul);
    height = math.max(fontSize * 1.8 * mul, layoutWidth * 0.08 * mul);
    const List<String> hollow = <String>[
      'straight-frame',
      'rotated-frame',
      'orbit-crosshair',
      'split-arches',
    ];
    const List<String> solid = <String>[
      'orb-hatch',
      'music-steps',
      'bent-lines',
    ];
    String hollowAt(int divisor, int offset) {
      final int i = seed ~/ divisor + offset;
      return hollow[((i % 4) + 4) % 4];
    }

    if (isChorusEffect) {
      final int cs = ((seed % 10) + 10) % 10;
      plan = cs < 9 ? hollowAt(10, cs) : solid[(seed ~/ 10) % 3];
    } else {
      final int legacy = ((seed % 4) + 4) % 4;
      plan = legacy == 1 || legacy == 2
          ? hollowAt(4, legacy)
          : solid[(seed ~/ 4) % 3];
    }
  }

  final int seed;
  final bool isChorusEffect;
  final Color color;
  final Color secondary;
  final Color accent;
  final double alpha;
  final double fontSize;
  late final double width;
  late final double height;
  late final String plan;

  /// 画在 (0,0)；[a] 是整体透明度。
  void paint(Canvas canvas, double a) {
    final double w = width;
    final double h = height;
    final double al = alpha * a;
    switch (plan) {
      case 'orbit-crosshair':
        final double r = math.min(w, h) * 0.46;
        canvas.drawCircle(Offset.zero, r, _stroke(color, 1.5, al));
        canvas.drawCircle(
          Offset(-w * 0.17, 0),
          r * 0.72,
          _stroke(secondary, 1, al * 0.72),
        );
        canvas.drawCircle(
          Offset(w * 0.17, 0),
          r * 0.72,
          _stroke(secondary, 1, al * 0.72),
        );
        canvas.drawLine(
          Offset(-w * 0.62, 0),
          Offset(w * 0.62, 0),
          _stroke(color, 1, al * 0.64),
        );
        canvas.drawLine(
          Offset(0, -h * 0.62),
          Offset(0, h * 0.62),
          _stroke(color, 1, al * 0.64),
        );
      case 'split-arches':
        final double half = w * 0.46;
        final double ar = math.min(w * 0.34, h * 0.52);
        for (int i = 0; i < 2; i++) {
          final double cx = (i == 0 ? -1 : 1) * half * 0.42;
          for (final (double k, double sw, double am, Color c)
              in <(double, double, double, Color)>[
                (0.72, 1.5, 1, i == 0 ? color : secondary),
                (0.48, 1, 0.58, i == 0 ? secondary : color),
              ]) {
            final double rr = ar * k;
            final Path path = Path()
              ..moveTo(cx - rr, h * 0.42)
              ..lineTo(cx - rr, 0)
              ..arcTo(
                Rect.fromCircle(center: Offset(cx, 0), radius: rr),
                math.pi,
                math.pi,
                false,
              )
              ..lineTo(cx + rr, h * 0.42);
            canvas.drawPath(path, _stroke(c, sw, al * am));
          }
        }
        canvas.drawLine(
          Offset(-half, h * 0.42),
          Offset(half, h * 0.42),
          _stroke(color, 2, al * 0.72),
        );
      case 'straight-frame':
      case 'rotated-frame':
        final bool rotated = plan == 'rotated-frame';
        final double fw = rotated ? w * 0.8 : w;
        final double fh = rotated ? h * 0.8 : h;
        canvas.save();
        if (rotated) canvas.rotate(math.pi / 4);
        canvas.drawRect(
          Rect.fromCenter(center: Offset.zero, width: fw, height: fh),
          _stroke(color, math.max(1.5, fontSize * 0.02), al),
        );
        if (isChorusEffect && seed.isEven) {
          canvas.drawRect(
            Rect.fromCenter(
              center: Offset.zero,
              width: fw * 1.2,
              height: fh * 1.2,
            ),
            _stroke(color, 1, al * 0.5),
          );
        }
        canvas.restore();
      case 'music-steps':
        const List<double> heights = <double>[
          0.24,
          0.35,
          0.2,
          0.82,
          0.3,
          0.1,
          0.23,
          0.16,
        ];
        final double spacing = w / (heights.length + 1);
        for (int i = 0; i < heights.length; i++) {
          final double x = -w / 2 + spacing * (i + 1);
          final double base = h * (0.12 - i * 0.035);
          canvas.drawLine(
            Offset(x - spacing * 0.12, base - h * heights[i] * 0.5),
            Offset(x + spacing * 0.12, base + h * heights[i] * 0.5),
            _stroke(
              i.isEven ? accent : secondary,
              math.max(2, h * 0.025),
              al * 0.52,
            ),
          );
        }
      case 'bent-lines':
        for (int i = 0; i < 5; i++) {
          final double x = -w * 0.34 + i * w * 0.17;
          canvas.drawPath(
            Path()
              ..moveTo(x - w * 0.16, -h * (0.42 - i * 0.035))
              ..lineTo(x, -h * (0.08 - i * 0.025))
              ..lineTo(x - w * 0.015, h * (0.35 + i * 0.035)),
            _stroke(
              i.isEven ? accent : secondary,
              math.max(2, h * 0.022),
              al * 0.52,
            ),
          );
        }
      default:
        final double r = w * 0.5;
        canvas.drawCircle(Offset.zero, r, _fill(color, al * 0.15));
        final double spacing = math.max(4, w * 0.05);
        final Paint hp = _stroke(color, 1.5, al * 0.6);
        for (double o = -r; o < r; o += spacing) {
          final double lh = math.sqrt(math.max(0, r * r - o * o));
          canvas.drawLine(
            Offset(o + r * 0.4, -lh + r * 0.4),
            Offset(o + r * 0.4, lh + r * 0.4),
            hp,
          );
        }
    }
  }
}

// ---------------------------------------------------------------------------
// 纯音乐的五线谱
// ---------------------------------------------------------------------------

/// La Folia 主题（公有领域，D 小调 3/4）：音高在谱上的位置 / 拍数 / 是否升号。
const List<(int, double, bool)> _laFolia = <(int, double, bool)>[
  (6, 1, false),
  (6, 1.5, false),
  (7, 0.5, false),
  (5, 1, true),
  (5, 1, true),
  (5, 1, true),
  (6, 1, false),
  (6, 1.5, false),
  (6, 0.5, false),
  (7, 1, false),
  (7, 1, false),
  (7, 1, false),
  (8, 1, false),
  (8, 1.5, false),
  (8, 0.5, false),
  (7, 1, false),
  (7, 1, false),
  (7, 1, false),
  (6, 1, false),
  (6, 1.5, false),
  (5, 0.5, true),
  (6, 3, false),
];

class SonnetStaff {
  SonnetStaff({
    required double baseFontSize,
    required double width,
    required this.shotStart,
    required this.primary,
    required this.accent,
  }) : staffWidth = math.max(300, width * 0.6),
       lineSpacing = baseFontSize * 0.25;

  final double staffWidth;
  final double lineSpacing;
  final double shotStart;
  final Color primary;
  final Color accent;

  static final double _totalBeats = _laFolia.fold<double>(
    0,
    (double s, (int, double, bool) n) => s + n.$2,
  );

  void paint(Canvas canvas, double time, double a) {
    final double halfW = staffWidth / 2;
    final double halfH = lineSpacing * 2;
    final double playable = staffWidth * 0.92;
    final double beatW = playable / _totalBeats;
    for (int i = 0; i < 5; i++) {
      final double y = -halfH + i * lineSpacing;
      canvas.drawLine(
        Offset(-halfW, y),
        Offset(halfW, y),
        _stroke(primary, 2, 0.3 * a),
      );
    }
    for (int bar = 1; bar < 8; bar++) {
      final double x = -playable / 2 + beatW * bar * 3;
      canvas.drawLine(
        Offset(x, -halfH),
        Offset(x, halfH),
        _stroke(primary, 1, 0.16 * a),
      );
    }
    canvas.drawLine(
      Offset(-halfW + 10, -halfH),
      Offset(-halfW + 10, halfH),
      _stroke(primary, 4, 0.5 * a),
    );
    canvas.drawLine(
      Offset(halfW - 10, -halfH),
      Offset(halfW - 10, halfH),
      _stroke(primary, 2, 0.5 * a),
    );
    canvas.drawLine(
      Offset(halfW - 4, -halfH),
      Offset(halfW - 4, halfH),
      _stroke(primary, 6, 0.5 * a),
    );
    final double cycle = ((time - shotStart) % 8 + 8) % 8;
    final double beatPos = cycle / 8 * _totalBeats;
    final double cursorX = -playable / 2 + beatW * beatPos;
    canvas.drawLine(
      Offset(cursorX, -halfH - lineSpacing * 0.8),
      Offset(cursorX, halfH + lineSpacing * 0.8),
      _stroke(accent, 1.5, 0.34 * a),
    );
    double startBeat = 0;
    for (int i = 0; i < _laFolia.length; i++) {
      final (int step, double beats, bool sharp) = _laFolia[i];
      final bool active = beatPos >= startBeat && beatPos < startBeat + beats;
      final double pulse = active
          ? (math.sin(cycle * math.pi * 5 + i * 0.4) + 1) * 0.5
          : 0;
      final double ns = active ? 1 + pulse * 0.12 : 1;
      final double rx = lineSpacing * 0.42 * ns;
      final double ry = lineSpacing * 0.29 * ns;
      final double x = -playable / 2 + beatW * (startBeat + beats * 0.5);
      final double y = halfH - step * lineSpacing * 0.5;
      final double alpha = active ? 0.78 + pulse * 0.16 : 0.28 + (i % 3) * 0.03;
      final bool down = step >= 6;
      final double stemX = x + (down ? -rx : rx);
      final double stemEnd =
          y + (down ? lineSpacing * 3.1 : -lineSpacing * 3.1);
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, y), width: rx * 2, height: ry * 2),
        _fill(accent, alpha * a),
      );
      final Paint sp = _stroke(primary, 1.6, math.min(0.9, alpha + 0.08) * a);
      canvas.drawLine(Offset(stemX, y), Offset(stemX, stemEnd), sp);
      if (beats <= 0.5) {
        final double dir = down ? -1 : 1;
        canvas.drawPath(
          Path()
            ..moveTo(stemX, stemEnd)
            ..quadraticBezierTo(
              stemX + lineSpacing * 1.1,
              stemEnd + lineSpacing * 0.55 * dir,
              stemX + lineSpacing * 0.1,
              stemEnd + lineSpacing * dir,
            ),
          sp,
        );
      }
      if (sharp) {
        final double sx = x - rx * 2.3;
        final double sh = lineSpacing * 1.15;
        final Paint shp = _stroke(
          primary,
          1.2,
          math.min(0.86, alpha + 0.08) * a,
        );
        canvas.drawLine(
          Offset(sx - lineSpacing * 0.16, y - sh * 0.5),
          Offset(sx - lineSpacing * 0.16, y + sh * 0.5),
          shp,
        );
        canvas.drawLine(
          Offset(sx + lineSpacing * 0.16, y - sh * 0.5),
          Offset(sx + lineSpacing * 0.16, y + sh * 0.5),
          shp,
        );
        canvas.drawLine(
          Offset(sx - lineSpacing * 0.34, y - lineSpacing * 0.12),
          Offset(sx + lineSpacing * 0.34, y - lineSpacing * 0.28),
          shp,
        );
        canvas.drawLine(
          Offset(sx - lineSpacing * 0.34, y + lineSpacing * 0.28),
          Offset(sx + lineSpacing * 0.34, y + lineSpacing * 0.12),
          shp,
        );
      }
      startBeat += beats;
    }
  }
}
