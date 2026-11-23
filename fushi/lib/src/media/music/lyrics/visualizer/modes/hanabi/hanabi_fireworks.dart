/// 烟花（移植 folia `hanabi/mg/burstPlan.ts` + `fireworks.ts` + `textures.ts`）：每颗星的轨迹是闭式解
/// （带阻力的抛体 + 下坠），任何时刻的画面只由时间决定；画的时候把精灵攒成一批，用 drawRawAtlas / drawVertices
/// 一次画完。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';

/// 一次开花（镜头容器坐标）。
class BurstEvent {
  const BurstEvent({
    required this.x,
    required this.y,
    required this.at,
    required this.spec,
    required this.seed,
    this.scale = 1,
    this.squash = 1,
    this.rotation = 0,
  });
  final double x;
  final double y;
  final double at;
  final BurstSpec spec;
  final String seed;
  final double scale;
  final double squash;
  final double rotation;
}

/// 一道升空尾迹。
class LaunchEvent {
  const LaunchEvent({
    required this.fromX,
    required this.fromY,
    required this.toX,
    required this.toY,
    required this.at,
    required this.duration,
    required this.color,
    required this.seed,
  });
  final double fromX;
  final double fromY;
  final double toX;
  final double toY;
  final double at;
  final double duration;
  final int color;
  final String seed;
}

class StarPlan {
  StarPlan({
    required this.x0,
    required this.y0,
    required this.vx,
    required this.vy,
    required this.drag,
    required this.fall,
    required this.start,
    required this.life,
    required this.size,
    required this.color,
    required this.endColor,
    required this.shift,
    required this.trailColor,
    required this.trail,
    required this.segments,
    required this.fadeTail,
    required this.strobe,
    required this.strobeFrom,
    required this.twinkle,
    required this.glitter,
    required this.spiral,
    required this.spin,
    required this.phase,
    required this.depth,
    required this.tex,
  });
  final double x0;
  final double y0;
  final double vx;
  final double vy;
  final double drag;
  final double fall;
  final double start;
  final double life;
  final double size;
  final int color;
  final int endColor;
  final double shift;
  final int trailColor;
  final double trail;
  final int segments;
  final double fadeTail;
  final double strobe;
  final double strobeFrom;
  final double twinkle;
  final double glitter;
  final double spiral;
  final double spin;
  final double phase;
  final double depth;
  double rank = 0;
  final int tex;
}

class FlashPlan {
  const FlashPlan(this.x, this.y, this.at, this.size, this.color, this.life);
  final double x;
  final double y;
  final double at;
  final double size;
  final int color;
  final double life;
}

class BurstPlan {
  const BurstPlan(this.at, this.end, this.stars, this.flashes);
  final double at;
  final double end;
  final List<StarPlan> stars;
  final List<FlashPlan> flashes;
}

const double _golden = 0.6180339887498949;
const double _goldenAngle = 2.399963229728653;

int _sparkColor(HanabiPalette palette, List<int> colors, int i) {
  final List<int> sparks = palette.sparks.isNotEmpty
      ? palette.sparks
      : const <int>[kWhite];
  final int n = sparks.length;
  final int index = colors.isNotEmpty
      ? colors[((i % colors.length) + colors.length) % colors.length]
      : i;
  return sparks[((index % n) + n) % n];
}

/// 一次开花的全部星（闭式轨迹参数）与闪光。
BurstPlan planBurst(
  BurstEvent event,
  HanabiPalette palette, {
  required double unit,
  required double amount,
}) {
  final BurstSpec spec = event.spec;
  final BurstKind kind = spec.kind;
  final HanabiRng rng = hanabiRng('${event.seed}:${_kindName(kind)}');
  final double r0 = math.max(
    4,
    spec.radius * unit * (event.scale == 0 ? 1 : event.scale),
  );
  final double d = math.max(0.2, spec.duration);
  final double at = event.at;
  final int n = math.max(0, (spec.count * math.max(0, amount)).round());
  final double trailK = clamp01(spec.trail);
  final double twinkleK = clamp01(spec.twinkle);
  final double cosR = math.cos(event.rotation);
  final double sinR = math.sin(event.rotation);
  int c(int i) => _sparkColor(palette, spec.colors, i);
  final List<StarPlan> stars = <StarPlan>[];
  final List<FlashPlan> flashes = <FlashPlan>[];
  final double minSize = math.max(1.4, unit * 0.0022);

  void add({
    double x0 = 0,
    double y0 = 0,
    double start = 0,
    required double vx,
    required double vy,
    required double drag,
    double fall = 0,
    required double life,
    required double size,
    required int color,
    int? endColor,
    double shift = 1,
    int? trailColor,
    double trail = 0,
    int segments = 3,
    double fadeTail = 0.3,
    double strobe = 0,
    double strobeFrom = 0,
    double twinkle = 0,
    double glitter = 0,
    double spiral = 0,
    double spin = 0,
    double? phase,
    double depth = 1,
    int tex = 0,
  }) {
    final double l = math.min(life, d - start - 0.02);
    if (l <= 0.05) return;
    stars.add(
      StarPlan(
        x0: event.x + x0,
        y0: event.y + y0,
        vx: vx,
        vy: vy,
        drag: drag,
        fall: fall,
        start: at + start,
        life: l,
        size: math.max(minSize, size),
        color: color,
        endColor: endColor ?? color,
        shift: shift,
        trailColor: trailColor ?? mixRgb(color, kEmber, 0.3),
        trail: trail,
        segments: trail > 0 ? math.max(1, segments) : 0,
        fadeTail: fadeTail,
        strobe: strobe,
        strobeFrom: strobeFrom,
        twinkle: twinkle,
        glitter: glitter,
        spiral: spiral,
        spin: spin,
        phase: phase ?? rng() * kTau,
        depth: depth,
        tex: tex,
      ),
    );
  }

  void flash(
    double x,
    double y,
    double delay,
    double size,
    int color, [
    double life = 0.32,
  ]) {
    if (delay >= d) return;
    flashes.add(
      FlashPlan(
        event.x + x,
        event.y + y,
        at + delay,
        size,
        mixRgb(color, kWhite, 0.7),
        math.min(life, d - delay),
      ),
    );
  }

  final double tiltA = rng() * kTau;
  final double tiltCos = math.cos(tiltA);
  final double tiltSin = math.sin(tiltA);
  (double, double, double) sphere(int i, int count, [double jitter = 0.25]) {
    final double z = 1 - (2 * (i + 0.5)) / count;
    final double r = math.sqrt(math.max(0, 1 - z * z));
    final double phi = i * _goldenAngle + (rng() - 0.5) * jitter;
    final double x = r * math.cos(phi);
    final double y0 = r * math.sin(phi);
    return (x, y0 * tiltCos - z * tiltSin, y0 * tiltSin + z * tiltCos);
  }

  (double, double) planar(double x, double y) {
    final double sy = y * event.squash;
    return (x * cosR - sy * sinR, x * sinR + sy * cosR);
  }

  double depthOf(double z) => 0.62 + 0.38 * (z + 1) / 2;
  double life(double low, double high) => d * lerpD(low, high, rng());
  final int c0 = c(0);
  final int c1 = c(1);
  final int c2 = c(2);
  final double R = r0; // ignore: non_constant_identifier_names

  switch (kind) {
    case BurstKind.kiku:
      final int core = (n * 0.2).round();
      final int main = n - core;
      const double k = 3.2;
      for (int i = 0; i < main; i++) {
        final (double dx, double dy, double dz) = sphere(i, main);
        final double speed = R * k * (0.94 + rng() * 0.12);
        add(
          vx: dx * speed,
          vy: dy * speed,
          drag: k,
          fall: R * 0.3,
          life: life(0.78, 0.98),
          size: R * 0.02,
          color: c0,
          endColor: mixRgb(c0, kWhite, 0.65),
          shift: 0.7,
          trail: 0.1 + trailK * 0.38,
          segments: 3,
          trailColor: mixRgb(c0, kEmber, 0.3),
          twinkle: twinkleK,
          depth: depthOf(dz),
        );
      }
      for (int i = 0; i < core; i++) {
        final (double dx, double dy, double dz) = sphere(i, core);
        final double speed = R * 3.6 * 0.42 * (0.95 + rng() * 0.1);
        add(
          vx: dx * speed,
          vy: dy * speed,
          drag: 3.6,
          fall: R * 0.2,
          life: life(0.4, 0.55),
          size: R * 0.017,
          color: c1,
          trail: 0.04 + trailK * 0.08,
          segments: 1,
          fadeTail: 0.2,
          depth: depthOf(dz),
        );
      }
      flash(0, 0, 0, R * 1.1, c0, 0.36);
    case BurstKind.botan:
      final int core = (n * 0.22).round();
      final int main = n - core;
      const double k = 3.6;
      for (int i = 0; i < main; i++) {
        final (double dx, double dy, double dz) = sphere(i, main, 0.12);
        final double speed = R * k * (0.97 + rng() * 0.06);
        add(
          vx: dx * speed,
          vy: dy * speed,
          drag: k,
          fall: R * 0.24,
          life: life(0.85, 0.97),
          size: R * 0.034,
          color: c0,
          endColor: c1,
          shift: 0.48,
          fadeTail: 0.12,
          twinkle: twinkleK * 0.6,
          depth: depthOf(dz),
        );
      }
      for (int i = 0; i < core; i++) {
        final (double dx, double dy, double dz) = sphere(i, core, 0.12);
        final double speed = R * k * 0.5;
        add(
          vx: dx * speed,
          vy: dy * speed,
          drag: k,
          fall: R * 0.2,
          life: life(0.6, 0.72),
          size: R * 0.03,
          color: c2,
          endColor: mixRgb(c2, kWhite, 0.5),
          shift: 0.55,
          fadeTail: 0.12,
          depth: depthOf(dz),
        );
      }
      flash(0, 0, 0, R * 1.2, c0, 0.3);
    case BurstKind.yanagi:
      const double k = 2.5;
      final int gold = mixRgb(c0, kGold, 0.6);
      for (int i = 0; i < n; i++) {
        final (double dx, double dy, double dz) = sphere(i, n, 0.4);
        final double speed = R * k * 0.72 * (0.9 + rng() * 0.2);
        add(
          vx: dx * speed,
          vy: dy * speed - R * 0.25,
          drag: k,
          fall: R * 0.95,
          life: life(0.88, 0.99),
          size: R * 0.013,
          color: gold,
          endColor: mixRgb(gold, kEmber, 0.6),
          shift: 0.6,
          trail: 0.35 + trailK * 0.95,
          segments: 4,
          trailColor: mixRgb(gold, kEmber, 0.35),
          fadeTail: 0.45,
          glitter: 0.25 + twinkleK * 0.5,
          depth: depthOf(dz) * 0.9,
        );
      }
      flash(0, 0, 0, R * 0.8, gold, 0.3);
    case BurstKind.kamuro:
      const double k = 3.0;
      final int gold = mixRgb(c0, kGold, 0.78);
      for (int i = 0; i < n; i++) {
        final (double dx, double dy, double dz) = sphere(i, n, 0.2);
        final double speed = R * k * 1.05 * (0.95 + rng() * 0.1);
        add(
          vx: dx * speed,
          vy: dy * speed - R * 0.12,
          drag: k,
          fall: R * 0.55,
          life: life(0.9, 0.99),
          size: R * 0.017,
          color: gold,
          endColor: mixRgb(gold, kEmber, 0.5),
          shift: 0.55,
          trail: 0.45 + trailK * 0.8,
          segments: 4,
          trailColor: mixRgb(gold, kEmber, 0.25),
          fadeTail: 0.5,
          glitter: 0.55 + twinkleK * 0.45,
          depth: depthOf(dz),
        );
      }
      flash(0, 0, 0, R * 1.3, gold, 0.42);
    case BurstKind.senrin:
      final int flowers = math.max(4, math.min(10, (n / 14).round()));
      final int per = math.max(6, (n / flowers).round());
      const double k = 4.4;
      for (int f = 0; f < flowers; f++) {
        final double angle = f * _goldenAngle + rng() * 0.6;
        final double dist = R * 0.78 * math.sqrt((f + 0.5) / flowers);
        final double ox = math.cos(angle) * dist;
        final double oy = math.sin(angle) * dist;
        final double delay = 0.06 + (f / flowers) * d * 0.42 + rng() * 0.05;
        final double r = R * (0.2 + rng() * 0.08);
        final int color = c(f);
        for (int i = 0; i < per; i++) {
          final (double dx, double dy, double dz) = sphere(i, per, 0.3);
          final double speed = r * k * (0.92 + rng() * 0.16);
          add(
            x0: ox,
            y0: oy,
            start: delay,
            vx: dx * speed,
            vy: dy * speed,
            drag: k,
            fall: R * 0.16,
            life: d * (0.32 + rng() * 0.12),
            size: R * 0.017,
            color: color,
            endColor: mixRgb(color, kWhite, 0.6),
            shift: 0.65,
            trail: trailK * 0.08,
            segments: 1,
            fadeTail: 0.25,
            twinkle: 0.3 + twinkleK * 0.7,
            depth: depthOf(dz),
          );
        }
        flash(ox, oy, delay, r * 1.4, color, 0.22);
      }
    case BurstKind.ring:
      const double k = 3.4;
      final int outer = (n * 0.7).round();
      final int inner = (n * 0.2).round();
      final int core = n - outer - inner;
      void ringOf(
        int count,
        double reach,
        int color,
        double size,
        double lifeLow,
      ) {
        for (int i = 0; i < count; i++) {
          final (double dx, double dy) = planar(
            math.cos(kTau * i / count),
            math.sin(kTau * i / count),
          );
          final double speed = R * k * reach * (0.99 + rng() * 0.02);
          add(
            vx: dx * speed,
            vy: dy * speed,
            drag: k,
            fall: R * 0.18,
            life: life(lifeLow, lifeLow + 0.12),
            size: size,
            color: color,
            endColor: mixRgb(color, kWhite, 0.5),
            shift: 0.75,
            trail: 0.05 + trailK * 0.2,
            segments: 2,
            twinkle: twinkleK,
          );
        }
      }

      ringOf(outer, 1, c0, R * 0.022, 0.85);
      ringOf(inner, 0.58, c1, R * 0.018, 0.7);
      for (int i = 0; i < core; i++) {
        final (double dx, double dy, double dz) = sphere(i, math.max(1, core));
        final double speed = R * k * 0.18;
        add(
          vx: dx * speed,
          vy: dy * speed,
          drag: k,
          fall: R * 0.15,
          life: life(0.45, 0.6),
          size: R * 0.02,
          color: c2,
          depth: depthOf(dz),
        );
      }
      flash(0, 0, 0, R * 0.9, c0, 0.3);
    case BurstKind.heart:
    case BurstKind.star:
      const double k = 3.4;
      final int outline = math.max(12, (n * 0.88).round());
      for (int i = 0; i < outline; i++) {
        final double u = i / outline;
        double x;
        double y;
        if (kind == BurstKind.heart) {
          final double t = u * kTau;
          x = (16 * math.pow(math.sin(t), 3)) / 17;
          y =
              -(13 * math.cos(t) -
                  5 * math.cos(2 * t) -
                  2 * math.cos(3 * t) -
                  math.cos(4 * t)) /
              17;
        } else {
          final double edge = u * 10;
          final int e = edge.floor();
          final double f = edge - e;
          (double, double) vertex(int index) {
            final double radius = index.isEven ? 1 : 0.4;
            final double a = -math.pi / 2 + (index * math.pi) / 5;
            return (math.cos(a) * radius, math.sin(a) * radius);
          }

          final (double ax, double ay) = vertex(e);
          final (double bx, double by) = vertex(e + 1);
          x = lerpD(ax, bx, f);
          y = lerpD(ay, by, f);
        }
        final (double dx, double dy) = planar(x, y);
        final double speed = R * k * (0.99 + rng() * 0.02);
        add(
          vx: dx * speed,
          vy: dy * speed,
          drag: k,
          fall: R * 0.1,
          life: life(0.8, 0.92),
          size: R * 0.024,
          color: c0,
          endColor: mixRgb(c0, kWhite, 0.55),
          shift: 0.7,
          trail: 0.04 + trailK * 0.1,
          segments: 1,
          fadeTail: 0.25,
          twinkle: twinkleK,
        );
      }
      final int core = n - outline;
      for (int i = 0; i < core; i++) {
        final (double dx, double dy, double dz) = sphere(i, math.max(1, core));
        final double speed = R * k * 0.15;
        add(
          vx: dx * speed,
          vy: dy * speed,
          drag: k,
          fall: R * 0.1,
          life: life(0.4, 0.55),
          size: R * 0.018,
          color: c1,
          depth: depthOf(dz),
        );
      }
      flash(0, 0, 0, R * 0.8, c0, 0.28);
    case BurstKind.palm:
      final int branches = math.max(6, math.min(14, (n / 9).round()));
      final int crumbs = math.max(
        0,
        math.min(6, ((n - branches) / branches).floor()),
      );
      const double k = 2.3;
      final int gold = mixRgb(c0, kGold, 0.45);
      for (int b = 0; b < branches; b++) {
        final double angle = (kTau * b) / branches + (rng() - 0.5) * 0.35;
        final double up = -math.sin(angle);
        final double reach = 1 + up * 0.15 + (rng() - 0.5) * 0.1;
        final double dx = math.cos(angle);
        final double dy = math.sin(angle);
        final double speed = R * k * reach;
        add(
          vx: dx * speed,
          vy: dy * speed,
          drag: k,
          fall: R * 0.7,
          life: life(0.88, 0.98),
          size: R * 0.05,
          color: gold,
          endColor: mixRgb(gold, kEmber, 0.55),
          shift: 0.55,
          trail: 0.4 + trailK * 0.55,
          segments: 5,
          trailColor: mixRgb(gold, kEmber, 0.3),
          fadeTail: 0.4,
          glitter: 0.3 + twinkleK * 0.4,
        );
        for (int j = 0; j < crumbs; j++) {
          final double f = 0.9 - j * 0.1;
          add(
            vx: dx * speed * f + (rng() - 0.5) * R * 0.3,
            vy: dy * speed * f + (rng() - 0.5) * R * 0.3,
            drag: k,
            fall: R * 0.75,
            life: life(0.55, 0.85),
            size: R * 0.014,
            color: mixRgb(gold, kWhite, 0.3),
            trail: 0.08,
            segments: 1,
            fadeTail: 0.5,
            glitter: 0.8,
          );
        }
      }
      flash(0, 0, 0, R * 1.0, gold, 0.4);
    case BurstKind.crossette:
      final int parents = math.max(6, math.min(16, (n / 5).round()));
      const double k = 2.8;
      const double kc = 3.4;
      final double fall = R * 0.32;
      for (int p = 0; p < parents; p++) {
        final double angle = (kTau * p) / parents + (rng() - 0.5) * 0.4;
        final double speed = R * k * 0.72 * (0.9 + rng() * 0.2);
        final double vx = math.cos(angle) * speed;
        final double vy = math.sin(angle) * speed;
        final double split = d * (0.28 + rng() * 0.08);
        add(
          vx: vx,
          vy: vy,
          drag: k,
          fall: fall,
          life: split,
          size: R * 0.024,
          color: c0,
          trail: 0.08 + trailK * 0.2,
          segments: 2,
          fadeTail: 0.05,
        );
        final double e = math.exp(-k * split);
        final double f = (1 - e) / k;
        final double sx = vx * f;
        final double sy = vy * f + fall * (split - f);
        final double svx = vx * e;
        final double svy = (vy - fall) * e + fall;
        final double turn = angle + math.pi / 4 + (rng() - 0.5) * 0.3;
        for (int q = 0; q < 4; q++) {
          final double a = turn + (q * math.pi) / 2;
          final double cs = R * kc * 0.36;
          add(
            x0: sx,
            y0: sy,
            start: split,
            vx: svx * 0.35 + math.cos(a) * cs,
            vy: svy * 0.35 + math.sin(a) * cs,
            drag: kc,
            fall: R * 0.38,
            life: d * (0.45 + rng() * 0.12),
            size: R * 0.018,
            color: c1,
            endColor: mixRgb(c1, kWhite, 0.5),
            shift: 0.7,
            trail: 0.06 + trailK * 0.18,
            segments: 2,
            twinkle: twinkleK,
          );
        }
        flash(sx, sy, split, R * 0.2, c1, 0.16);
      }
      flash(0, 0, 0, R * 0.8, c0, 0.3);
    case BurstKind.strobe:
      const double k = 4;
      final int white = mixRgb(c0, kWhite, 0.55);
      for (int i = 0; i < n; i++) {
        final (double dx, double dy, double dz) = sphere(i, n, 0.6);
        final double speed = R * k * 0.88 * (0.8 + rng() * 0.3);
        add(
          vx: dx * speed,
          vy: dy * speed,
          drag: k,
          fall: R * 0.12,
          life: life(0.85, 0.99),
          size: R * 0.028,
          color: white,
          endColor: c(i),
          shift: 0.25,
          strobe: 7 + rng() * 7,
          strobeFrom: 0.3 + rng() * 0.25,
          fadeTail: 0.15,
          depth: depthOf(dz),
          tex: rng() < 0.3 ? 1 : 0,
        );
      }
      flash(0, 0, 0, R * 0.9, white, 0.3);
    case BurstKind.hachi:
      const double k = 2.5;
      final int silver = mixRgb(c0, kWhite, 0.7);
      for (int i = 0; i < n; i++) {
        final double angle = rng() * kTau;
        final double speed = R * k * (0.3 + rng() * 0.6);
        add(
          vx: math.cos(angle) * speed,
          vy: math.sin(angle) * speed,
          drag: k,
          fall: R * 0.25,
          life: life(0.5, 0.98),
          size: R * 0.013,
          color: silver,
          endColor: c(i),
          shift: 0.6,
          trail: 0.08 + trailK * 0.14,
          segments: 2,
          trailColor: mixRgb(silver, kEmber, 0.3),
          spiral: R * (0.05 + rng() * 0.11),
          spin: (rng() < 0.5 ? -1 : 1) * (9 + rng() * 12),
          twinkle: 0.4 + twinkleK * 0.6,
          fadeTail: 0.3,
        );
      }
      flash(0, 0, 0, R * 0.6, silver, 0.24);
    case BurstKind.willowRing:
      final int inner = (n * 0.35).round();
      final int outer = n - inner;
      final int gold = mixRgb(c1, kGold, 0.7);
      for (int i = 0; i < inner; i++) {
        final (double dx, double dy) = planar(
          math.cos(kTau * i / inner),
          math.sin(kTau * i / inner),
        );
        final double speed = R * 3.6 * 0.46;
        add(
          vx: dx * speed,
          vy: dy * speed,
          drag: 3.6,
          fall: R * 0.15,
          life: life(0.45, 0.55),
          size: R * 0.03,
          color: c0,
          endColor: mixRgb(c0, kWhite, 0.5),
          shift: 0.6,
          fadeTail: 0.1,
        );
      }
      for (int i = 0; i < outer; i++) {
        final (double dx, double dy, double dz) = sphere(i, outer, 0.4);
        final double speed = R * 2.6 * (0.92 + rng() * 0.12);
        add(
          vx: dx * speed,
          vy: dy * speed - R * 0.2,
          drag: 2.6,
          fall: R * 0.9,
          life: life(0.88, 0.99),
          size: R * 0.013,
          color: gold,
          endColor: mixRgb(gold, kEmber, 0.6),
          shift: 0.6,
          trail: 0.35 + trailK * 0.9,
          segments: 4,
          trailColor: mixRgb(gold, kEmber, 0.3),
          fadeTail: 0.45,
          glitter: 0.3 + twinkleK * 0.4,
          depth: depthOf(dz) * 0.9,
        );
      }
      flash(0, 0, 0, R * 1.0, c0, 0.34);
    case BurstKind.mine:
      final int volleys = math.max(4, math.min(8, (d * 2.6).round()));
      final int per = math.max(4, (n / volleys).round());
      const double k = 1.7;
      for (int v = 0; v < volleys; v++) {
        final double delay = (v / volleys) * d * 0.55;
        final double lean = (v.isEven ? -1 : 1) * (0.12 + rng() * 0.2);
        final int color = c(v);
        final double lifeV = math.min(0.9 + rng() * 0.5, d * 0.6);
        for (int i = 0; i < per; i++) {
          final double angle =
              -math.pi / 2 +
              lean +
              ((i + 0.5) / per - 0.5) * 1.3 +
              (rng() - 0.5) * 0.12;
          final double speed = R * k * (1.45 + rng() * 0.45);
          add(
            start: delay,
            vx: math.cos(angle) * speed,
            vy: math.sin(angle) * speed,
            drag: k,
            fall: R * 0.9,
            life: lifeV * (0.8 + rng() * 0.2),
            size: R * 0.02,
            color: color,
            endColor: mixRgb(color, kWhite, 0.6),
            shift: 0.7,
            trail: 0.1 + trailK * 0.3,
            segments: 3,
            fadeTail: 0.3,
            twinkle: twinkleK,
          );
        }
        flash(0, 0, delay, R * 0.35, color, 0.18);
      }
  }
  for (int i = 0; i < stars.length; i++) {
    stars[i].rank = ((i + 1) * _golden) % 1;
  }
  double end = at;
  for (final StarPlan s in stars) {
    end = math.max(end, s.start + s.life);
  }
  for (final FlashPlan f in flashes) {
    end = math.max(end, f.at + f.life);
  }
  return BurstPlan(at, end, stars, flashes);
}

String _kindName(BurstKind kind) =>
    kind == BurstKind.willowRing ? 'willow-ring' : kind.name;

/// 星在 tau 秒时的位置。
(double, double) starPosition(StarPlan star, double tau) {
  final double t = tau < 0 ? 0 : tau;
  final double e = math.exp(-star.drag * t);
  final double f = (1 - e) / star.drag;
  double x = star.x0 + star.vx * f;
  double y = star.y0 + star.vy * f + star.fall * (t - f);
  if (star.spiral > 0) {
    final double r = star.spiral * (1 - math.exp(-3 * t));
    final double a = star.phase + star.spin * t;
    x += r * math.cos(a);
    y += r * math.sin(a);
  }
  return (x, y);
}

double _starBase(StarPlan star, double tau) {
  if (tau < 0 || tau > star.life) return 0;
  final double u = tau / star.life;
  double b = star.depth * clamp01(tau / 0.035);
  if (u > 1 - star.fadeTail) {
    final double k = (1 - u) / star.fadeTail;
    b *= k * k * (3 - 2 * k);
  }
  return b;
}

double starBrightness(StarPlan star, double tau) {
  double b = _starBase(star, tau);
  if (b <= 0) return 0;
  if (star.strobe > 0 && tau > star.strobeFrom) {
    final bool on = (tau * star.strobe + star.phase) % 1 < 0.42;
    b *= on ? 1 : 0.05;
  }
  final double u = tau / star.life;
  if (star.twinkle > 0 && u > 0.5) {
    final double n = mgHash01((tau * 24).floorToDouble(), star.phase * 97);
    b *= 1 - star.twinkle * clamp01((u - 0.5) / 0.2) * (n < 0.45 ? 0.85 : 0);
  }
  return b;
}

bool _glittering(StarPlan star, double tau) =>
    star.glitter > 0 &&
    mgHash01((tau * 30).floorToDouble(), star.phase * 53) < star.glitter * 0.35;

int starColor(StarPlan star, double tau) {
  final double u = tau / star.life;
  int color = star.shift < 1
      ? mixRgb(star.color, star.endColor, (u - star.shift) / 0.1)
      : star.color;
  if (_glittering(star, tau)) color = mixRgb(color, kWhite, 0.75);
  return color;
}

double starSize(StarPlan star, double tau) {
  final double u = clamp01(tau / star.life);
  double size = star.size * (1 - 0.45 * u);
  if (_glittering(star, tau)) size *= 1.6;
  return size;
}

// ─── 精灵批 ─────────────────────────────────────────────────────────────

/// 精灵贴图：glow（柔光点）、dot（实心点）、star4（四角星）。白色，画时按颜色 modulate。
enum SparkTexture { glow, dot, star4 }

/// 三张白色精灵贴图拼成的一张图（[cell] 像素一格）。
class HanabiSprites {
  HanabiSprites._(this.image, this.cell);

  final ui.Image image;
  final double cell;

  static HanabiSprites create() {
    const double cell = 96;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    const double r = cell / 2;
    // glow
    canvas.drawCircle(
      const ui.Offset(r, r),
      r,
      ui.Paint()
        ..shader = ui.Gradient.radial(
          const ui.Offset(r, r),
          r,
          const <ui.Color>[
            ui.Color(0xFFFFFFFF),
            ui.Color(0xF2FFFFFF),
            ui.Color(0x8CFFFFFF),
            ui.Color(0x2EFFFFFF),
            ui.Color(0x0DFFFFFF),
            ui.Color(0x00FFFFFF),
          ],
          const <double>[0, 0.1, 0.22, 0.42, 0.7, 1],
        ),
    );
    // dot
    canvas.drawCircle(
      const ui.Offset(cell + r, r),
      r,
      ui.Paint()
        ..shader = ui.Gradient.radial(
          const ui.Offset(cell + r, r),
          r,
          const <ui.Color>[
            ui.Color(0xFFFFFFFF),
            ui.Color(0xFFFFFFFF),
            ui.Color(0x00FFFFFF),
          ],
          <double>[0, 1 - 2 / r, 1],
        ),
    );
    // star4
    const double c = r;
    const double sr = cell * 0.48;
    const double pinch = sr * 0.1;
    canvas.save();
    canvas.translate(cell * 2, 0);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, cell, cell),
      ui.Paint()
        ..shader = ui.Gradient.radial(
          const ui.Offset(c, c),
          sr * 0.5,
          const <ui.Color>[ui.Color(0xE6FFFFFF), ui.Color(0x00FFFFFF)],
        ),
    );
    final ui.Path star = ui.Path()
      ..moveTo(c, c - sr)
      ..quadraticBezierTo(c + pinch, c - pinch, c + sr, c)
      ..quadraticBezierTo(c + pinch, c + pinch, c, c + sr)
      ..quadraticBezierTo(c - pinch, c + pinch, c - sr, c)
      ..quadraticBezierTo(c - pinch, c - pinch, c, c - sr)
      ..close();
    canvas.drawPath(star, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
    canvas.restore();
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = picture.toImageSync(
      (cell * 3).toInt(),
      cell.toInt(),
    );
    picture.dispose();
    return HanabiSprites._(image, cell);
  }

  void dispose() => image.dispose();
}

class _Layer {
  final List<double> xf = <double>[];
  final List<double> rects = <double>[];
  final List<int> colors = <int>[];
  void clear() {
    xf.clear();
    rects.clear();
    colors.clear();
  }

  bool get isEmpty => colors.isEmpty;
}

/// 一帧里攒起来的精灵与拖尾，flush 时一次画完。
class SparkBatch {
  SparkBatch({this.budget = 1 << 30});

  int budget;
  int used = 0;
  final _Layer _normal = _Layer();
  final _Layer _additive = _Layer();
  final List<double> _streakPos = <double>[];
  final List<int> _streakColors = <int>[];

  /// 辉光（tuning.glow）：每个光点额外叠一圈加色的大光晕。
  double halo = 0;

  /// 之后加入的精灵 / 拖尾整体平移（像素）。
  double offsetX = 0;
  double offsetY = 0;

  /// 之后加入的精灵 / 拖尾整体乘的透明度。
  double alphaScale = 1;

  bool get full => used >= budget;

  void reset(int budget) {
    this.budget = budget;
    used = 0;
  }

  static int _argb(int rgb, double alpha) =>
      (((clamp01(alpha) * 255).round()) << 24) | (rgb & 0xFFFFFF);

  /// 一个方形精灵；返回 false 表示预算用完。
  bool sprite(
    SparkTexture tex,
    double x,
    double y,
    double size,
    double rotation,
    double alpha,
    int tint, {
    bool additive = false,
  }) {
    if (used >= budget) return false;
    used++;
    alpha *= alphaScale;
    x += offsetX;
    y += offsetY;
    if (alpha < 0.004 || size <= 0.05) return true;
    _push(
      additive ? _additive : _normal,
      tex,
      x,
      y,
      size,
      rotation,
      alpha,
      tint,
    );
    if (halo > 0 && tex == SparkTexture.glow && !additive) {
      _push(
        _additive,
        SparkTexture.glow,
        x,
        y,
        size * 2.6,
        0,
        alpha * 0.22 * halo,
        tint,
      );
    }
    return true;
  }

  void _push(
    _Layer layer,
    SparkTexture tex,
    double x,
    double y,
    double size,
    double rotation,
    double alpha,
    int tint,
  ) {
    const double cell = 96;
    final double scale = size / cell;
    final double sc = scale * math.cos(rotation);
    final double ss = scale * math.sin(rotation);
    const double a = cell / 2;
    layer.xf
      ..add(sc)
      ..add(ss)
      ..add(x - sc * a + ss * a)
      ..add(y - ss * a - sc * a);
    final double left = tex.index * cell;
    layer.rects
      ..add(left)
      ..add(0)
      ..add(left + cell)
      ..add(cell);
    layer.colors.add(_argb(tint, alpha));
  }

  /// 一段拖尾：从 a（亮）到 b（暗）的软边带。
  bool streak(
    double ax,
    double ay,
    double bx,
    double by,
    double thickness,
    double alpha,
    int tint,
  ) {
    if (used >= budget) return false;
    used++;
    alpha *= alphaScale;
    ax += offsetX;
    bx += offsetX;
    ay += offsetY;
    by += offsetY;
    final double dx = ax - bx;
    final double dy = ay - by;
    final double length = math.sqrt(dx * dx + dy * dy);
    if (length < 0.6 || alpha < 0.01) return true;
    final double nx = -dy / length * thickness / 2;
    final double ny = dx / length * thickness / 2;
    final int head = _argb(tint, alpha);
    final int tail = _argb(tint, alpha * 0.28);
    _streakPos.addAll(<double>[
      ax + nx,
      ay + ny,
      ax - nx,
      ay - ny,
      bx - nx,
      by - ny,
      ax + nx,
      ay + ny,
      bx - nx,
      by - ny,
      bx + nx,
      by + ny,
    ]);
    _streakColors.addAll(<int>[head, head, tail, head, tail, tail]);
    return true;
  }

  bool get isEmpty =>
      _normal.isEmpty && _additive.isEmpty && _streakColors.isEmpty;

  void flush(ui.Canvas canvas, HanabiSprites sprites, {double alpha = 1}) {
    if (_streakColors.isNotEmpty) {
      final ui.Vertices vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        Float32List.fromList(_streakPos),
        colors: Int32List.fromList(_streakColors),
      );
      canvas.drawVertices(
        vertices,
        ui.BlendMode.dst,
        ui.Paint()..color = ui.Color.fromRGBO(255, 255, 255, alpha),
      );
      vertices.dispose();
    }
    _drawLayer(canvas, sprites, _normal, ui.BlendMode.srcOver);
    _drawLayer(canvas, sprites, _additive, ui.BlendMode.plus);
    _normal.clear();
    _additive.clear();
    _streakPos.clear();
    _streakColors.clear();
  }

  void _drawLayer(
    ui.Canvas canvas,
    HanabiSprites sprites,
    _Layer layer,
    ui.BlendMode blend,
  ) {
    if (layer.isEmpty) return;
    canvas.drawRawAtlas(
      sprites.image,
      Float32List.fromList(layer.xf),
      Float32List.fromList(layer.rects),
      Int32List.fromList(layer.colors),
      ui.BlendMode.modulate,
      null,
      ui.Paint()
        ..blendMode = blend
        ..filterQuality = ui.FilterQuality.low,
    );
  }
}

// ─── 画开花与尾迹 ───────────────────────────────────────────────────────

bool _active(BurstPlan plan, double time) =>
    time >= plan.at && time <= plan.end;

/// 画一组开花：预算不够时按 rank 均匀抽稀。
void drawBursts(List<BurstPlan> plans, double time, SparkBatch out) {
  int stars = 0;
  int flashes = 0;
  for (final BurstPlan plan in plans) {
    if (!_active(plan, time)) continue;
    for (final FlashPlan f in plan.flashes) {
      if (time >= f.at && time < f.at + f.life) flashes += 2;
    }
    for (final StarPlan s in plan.stars) {
      final double tau = time - s.start;
      if (tau >= 0 && tau <= s.life) stars += 1 + s.segments;
    }
  }
  final int budget = out.budget - out.used;
  if (stars + flashes == 0 || budget <= 0) return;
  final double keep = stars + flashes <= budget
      ? 2
      : math.max(0, (budget - flashes) * 0.97) / math.max(1, stars);
  for (final BurstPlan plan in plans) {
    if (!_active(plan, time)) continue;
    for (final FlashPlan f in plan.flashes) {
      final double age = time - f.at;
      if (age < 0 || age >= f.life) continue;
      final double k = age / f.life;
      final double alpha = clamp01(age / 0.02) * (1 - k) * (1 - k);
      final double halo = f.size * (0.55 + 0.6 * math.sqrt(k));
      if (!out.sprite(
        SparkTexture.glow,
        f.x,
        f.y,
        halo,
        0,
        alpha * 0.55,
        f.color,
        additive: true,
      )) {
        return;
      }
      final double core = f.size * 0.35 * (1 - k * 0.6);
      if (!out.sprite(
        SparkTexture.glow,
        f.x,
        f.y,
        core,
        0,
        alpha,
        kWhite,
        additive: true,
      )) {
        return;
      }
    }
  }
  for (final BurstPlan plan in plans) {
    if (!_active(plan, time)) continue;
    for (final StarPlan star in plan.stars) {
      final double tau = time - star.start;
      if (tau < 0 || tau > star.life || star.rank >= keep) continue;
      final double base = _starBase(star, tau);
      if (base <= 0) continue;
      final (double hx, double hy) = starPosition(star, tau);
      final double size = starSize(star, tau);
      if (star.segments > 0) {
        final double step = star.trail / star.segments;
        double prevX = hx;
        double prevY = hy;
        for (int j = 1; j <= star.segments; j++) {
          final double back = math.max(0, tau - step * j);
          final (double ox, double oy) = starPosition(star, back);
          final double fade = math
              .pow(1 - (j - 1) / star.segments, 1.3)
              .toDouble();
          final double thickness = math.max(
            1.2,
            size * 0.75 * (1 - 0.45 * (j / star.segments)),
          );
          if (!out.streak(
            prevX,
            prevY,
            ox,
            oy,
            thickness,
            base * fade * 0.95,
            star.trailColor,
          )) {
            return;
          }
          prevX = ox;
          prevY = oy;
          if (back <= 0) break;
        }
      }
      final double alpha = starBrightness(star, tau);
      if (alpha < 0.01) continue;
      final int tint = starColor(star, tau);
      if (!out.sprite(
        star.tex == 1 ? SparkTexture.star4 : SparkTexture.glow,
        hx,
        hy,
        size * 3.4,
        star.phase,
        alpha,
        tint,
      )) {
        return;
      }
    }
  }
}

const double kLaunchEmberLife = 0.6;
const double _launchEmberStep = 0.032;
const int _launchTrailSegments = 5;

double launchEnd(LaunchEvent launch) =>
    launch.at + launch.duration + kLaunchEmberLife;

(double, double) _launchHead(LaunchEvent launch, double p, double salt) {
  final double k = clamp01(p);
  final double rise = 1 - (1 - k) * (1 - k);
  final double dx = launch.toX - launch.fromX;
  final double dy = launch.toY - launch.fromY;
  final double span = math.sqrt(dx * dx + dy * dy);
  final double freq = 2.2 + mgHash01(1, salt) * 1.6;
  final double phase = mgHash01(2, salt) * kTau;
  final double sway =
      math.sin(k * freq * kTau + phase) * span * 0.018 * (1 - k * 0.7);
  return (
    lerpD(launch.fromX, launch.toX, rise) + sway,
    lerpD(launch.fromY, launch.toY, rise),
  );
}

/// 升空尾迹：飞行中的火球 + 拖尾 + 沿途掉落的火粉。
bool drawLaunch(LaunchEvent launch, double time, double unit, SparkBatch out) {
  final double age = time - launch.at;
  if (age < 0 || time > launchEnd(launch)) return true;
  final double salt = (hanabiHashString(launch.seed) % 100000).toDouble();
  final double duration = math.max(0.05, launch.duration);
  final int color = launch.color;
  final int ember = mixRgb(color, kGold, 0.55);
  final double size = unit * 0.009;
  final int firstJ = math.max(
    0,
    ((age - kLaunchEmberLife) / _launchEmberStep).ceil(),
  );
  final int lastJ = (math.min(age, duration) / _launchEmberStep).floor();
  for (int j = firstJ; j <= lastJ; j++) {
    final double born = j * _launchEmberStep;
    final double tau = age - born;
    if (tau < 0 || tau > kLaunchEmberLife) continue;
    final (double fx, double fy) = _launchHead(launch, born / duration, salt);
    final double vx = (mgHash01(j * 3 + 1, salt) - 0.5) * unit * 0.12;
    final double vy = (mgHash01(j * 3 + 2, salt) - 0.2) * unit * 0.05;
    const double drag = 2.4;
    final double fall = unit * 0.09;
    final double e = math.exp(-drag * tau);
    final double f = (1 - e) / drag;
    final double x = fx + vx * f;
    final double y = fy + vy * f + fall * (tau - f);
    final double k = tau / kLaunchEmberLife;
    final double flicker =
        mgHash01(j * 7 + (tau * 20).floorToDouble(), salt) < 0.3 ? 0.4 : 1;
    final double alpha = math.pow(1 - k, 1.5) * flicker * 0.85;
    final double s =
        size * (0.35 + mgHash01(j * 5.0, salt) * 0.35) * (1 - k * 0.5);
    if (!out.sprite(SparkTexture.glow, x, y, s * 2.6, 0, alpha, ember)) {
      return false;
    }
  }
  if (age > duration) return true;
  final double p = age / duration;
  final (double hx, double hy) = _launchHead(launch, p, salt);
  double prevX = hx;
  double prevY = hy;
  for (int j = 1; j <= _launchTrailSegments; j++) {
    final (double ox, double oy) = _launchHead(
      launch,
      math.max(0, p - (0.07 * j) / duration),
      salt,
    );
    final double fade = 1 - (j - 1) / _launchTrailSegments;
    if (!out.streak(
      prevX,
      prevY,
      ox,
      oy,
      math.max(1, size * 0.9 * fade),
      0.8 * fade,
      mixRgb(color, kEmber, 0.3),
    )) {
      return false;
    }
    prevX = ox;
    prevY = oy;
  }
  final double pulse = 0.85 + 0.15 * math.sin(age * 40 + salt);
  final double dim = 1 - 0.35 * clamp01((p - 0.8) / 0.2);
  if (!out.sprite(
    SparkTexture.glow,
    hx,
    hy,
    size * 4.2 * pulse,
    0,
    0.9 * dim,
    color,
  )) {
    return false;
  }
  return out.sprite(
    SparkTexture.dot,
    hx,
    hy,
    size * 0.9,
    0,
    dim,
    mixRgb(color, kWhite, 0.8),
  );
}
