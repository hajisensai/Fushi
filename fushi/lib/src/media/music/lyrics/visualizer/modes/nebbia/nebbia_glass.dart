/// 雾笺前面玻璃上的水（folia `nebbiaDrops.ts` / `nebbiaHits.ts` / `nebbiaCondensation.ts` / `nebbiaSnow.ts`
/// 的 Canvas 版）：雨窗的凝结水珠和车身颠簸、雨点打窗；凝露的细小冷凝水珠；融雪的雪花粘上玻璃再化成水珠。
///
/// folia 里这些是逐帧积分的状态（弹簧、掉落、拖痕）；这里一律按时钟直接算出来（颠簸和水珠掉落按
/// 窗外时钟、雨点按歌词时间），拖进度、重建、暂停都对得上，也不必在 painter 里攒状态。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_layout.dart'
    show nebbiaClamp, nebbiaSmooth;
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_tuning.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_window.dart'
    show nebbiaRand;

// ---------------------------------------------------------------------------
// 颠簸
// ---------------------------------------------------------------------------

/// 一下颠簸：时刻（窗外时钟秒）和幅度。
class NebbiaBump {
  const NebbiaBump(this.t, this.a, this.share);
  final double t;
  final double a;

  /// 这一下震落水珠的份额（和上一下隔得越久越满）。
  final double share;
}

/// 随机颠簸的时间表（folia：平均 7.5 秒一下，间隔 3–12 秒），按种子一次排开、按需往后补。
class NebbiaBumps {
  NebbiaBumps(int seed) : _rng = LyricVisualizerRandom(seed ^ 0x7a11);

  final LyricVisualizerRandom _rng;
  final List<NebbiaBump> _list = <NebbiaBump>[];
  double _next = 0;
  double _last = -double.infinity;

  void _extend(double until) {
    if (_list.isEmpty && _next == 0) {
      _next = (3 + _rng.next() * 9) / NebbiaFixed.bumpRate;
    }
    while (_next <= until) {
      final double share = nebbiaClamp((_next - _last) / 7.5);
      _list.add(NebbiaBump(_next, 0.5 + _rng.next() * 0.7, share));
      _last = _next;
      _next += (3 + _rng.next() * 9) / NebbiaFixed.bumpRate;
    }
  }

  /// [from, to] 之间的颠簸。
  Iterable<NebbiaBump> between(double from, double to) sync* {
    _extend(to);
    // 二分找第一个不早于 from 的。
    int lo = 0;
    int hi = _list.length;
    while (lo < hi) {
      final int m = (lo + hi) >> 1;
      if (_list[m].t < from) {
        lo = m + 1;
      } else {
        hi = m;
      }
    }
    for (int i = lo; i < _list.length && _list[i].t <= to; i++) {
      yield _list[i];
    }
  }

  /// t 时刻的车身位移（像素）：先往下一沉，再阻尼回弹，横向带一点。
  Offset shakeAt(double t, double strength) {
    if (strength <= 0) return Offset.zero;
    double x = 0;
    double y = 0;
    for (final NebbiaBump b in between(t - 3, t)) {
      final double dt = t - b.t;
      final double k = b.a * strength;
      y += k * 7 * math.exp(-dt * 4.5) * math.sin(dt * math.pi * 2 * 3.8);
      x +=
          k *
          2 *
          math.exp(-dt * 5.5) *
          math.sin(dt * math.pi * 2 * 2.7 + 1.2) *
          (1 - math.exp(-dt * 60));
    }
    return Offset(x, y);
  }

  /// 水珠表面的细颤（颠簸后自己来回压扁、拉长几下）。
  double wobbleAt(double t, double strength, double phase) {
    double w = 0;
    for (final NebbiaBump b in between(t - 3, t)) {
      final double dt = t - b.t;
      w +=
          b.a *
          strength *
          0.07 *
          math.exp(-dt * 3.2) *
          math.sin(dt * math.pi * 2 * 7 + phase);
    }
    return w;
  }
}

// ---------------------------------------------------------------------------
// 水珠的画法
// ---------------------------------------------------------------------------

/// 一颗水珠的画法（raindrop-fx 的透镜近似）：比雾暗一点的身子（折射了身后较暗的窗外），底部一弯
/// 被折上来的灯光，左上一点高光。[look] 带着这一帧的颜色。
class NebbiaDropLook {
  NebbiaDropLook({required this.body, required this.glow, required this.glint});
  final Color body;
  final Color glow;
  final double glint;
  final Paint _p = Paint();

  void draw(
    Canvas canvas,
    Offset c,
    double r,
    double alpha, {
    double sx = 1,
    double sy = 1,
  }) {
    if (r < 0.5 || alpha <= 0.01) return;
    final double rx = r * sx;
    final double ry = r * sy;
    final Rect rect = Rect.fromCenter(center: c, width: rx * 2, height: ry * 2);
    canvas.drawOval(rect, _p..color = body.withValues(alpha: body.a * alpha));
    canvas.drawOval(
      Rect.fromCenter(
        center: c.translate(0, ry * 0.38),
        width: rx * 1.3,
        height: ry * 0.75,
      ),
      _p..color = glow.withValues(alpha: glow.a * alpha),
    );
    if (glint > 0) {
      canvas.drawOval(
        Rect.fromCenter(
          center: c.translate(-rx * 0.35, -ry * 0.38),
          width: rx * 0.5,
          height: ry * 0.38,
        ),
        _p
          ..color = Color.fromRGBO(
            255,
            255,
            255,
            nebbiaClamp(0.65 * glint * alpha),
          ),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// 雨窗：凝结水珠与掉落
// ---------------------------------------------------------------------------

class NebbiaFieldDrop {
  NebbiaFieldDrop(this.x, this.y, this.w, this.h, this.phase, this.index);
  final double x;
  final double y;

  /// 精灵宽高（folia 的单位：看得见的半径是 w / 8）。
  final double w;
  final double h;
  final double phase;
  final int index;
}

/// 一颗水珠的掉落：从哪年哪月开始、走多远、走多久。
class NebbiaFall {
  const NebbiaFall(this.t0, this.len, this.dur, this.seed);
  final double t0;
  final double len;
  final double dur;
  final double seed;
}

/// 雾上的凝结水珠：下半部分略多略大；颠簸时大水珠被震落，留下水痕，过一会儿在原处重新凝出来。
class NebbiaFieldDrops {
  NebbiaFieldDrops(double width, double height) {
    final LyricVisualizerRandom rnd = LyricVisualizerRandom(4242);
    final int n = (width * height / 2200 * NebbiaFixed.fieldDrops).round();
    for (int i = 0; i < n; i++) {
      final bool big = rnd.next() < 0.12;
      final double w = big
          ? 40 + rnd.next() * 34
          : 14 + math.pow(rnd.next(), 1.4) * 22;
      final double sp = rnd.next() * 0.25;
      final double x = rnd.next() * width;
      final double y = height * (1 - math.pow(rnd.next(), 1.25));
      drops.add(
        NebbiaFieldDrop(
          x,
          y,
          w * (1 + sp * 0.5),
          w * (1 + sp),
          rnd.next() * 6.28,
          i,
        ),
      );
    }
  }

  final List<NebbiaFieldDrop> drops = <NebbiaFieldDrop>[];

  /// 这颗水珠最近一次被震落（[now] 往前 [window] 秒内），没有就 null。
  NebbiaFall? fallOf(
    NebbiaFieldDrop d,
    NebbiaBumps bumps,
    double now,
    double window,
    double strength,
  ) {
    if (d.w < 26 || strength <= 0) return null;
    NebbiaFall? out;
    for (final NebbiaBump b in bumps.between(now - window, now)) {
      final double r = nebbiaRand(d.index * 13.17 + b.t * 7.31);
      if (r <
          NebbiaFixed.bumpFall * b.a * strength * b.share * (d.w - 24) / 45) {
        final double r2 = nebbiaRand(d.index * 3.3 + b.t);
        out = NebbiaFall(
          b.t + r2 * 0.12,
          (30 + nebbiaRand(d.index + b.t * 1.7) * 150) * d.w / 50,
          1 + nebbiaRand(d.index * 0.7 + b.t * 2.9) * 2.2,
          r2 * 100,
        );
      }
    }
    return out;
  }
}

/// 掉落的进度：走走停停（u − sin(6πu)/6π）。
double nebbiaFallEase(double u) =>
    u - math.sin(u * 6 * math.pi) / (6 * math.pi);

// ---------------------------------------------------------------------------
// 雨点打窗
// ---------------------------------------------------------------------------

/// 一颗雨点。
class NebbiaHit {
  const NebbiaHit(
    this.t,
    this.x,
    this.y,
    this.r,
    this.big,
    this.sat,
    this.seed,
  );
  final double t;
  final double x;
  final double y;
  final double r;
  final bool big;

  /// 大雨点溅出的一圈小水珠（相对偏移 + 半径）。
  final List<(double, double, double)> sat;
  final double seed;
}

/// 一格 20 毫秒。
const double kNebbiaHitBucket = 0.02;

/// 一颗雨点从落下到完全消失要几秒。
double nebbiaHitLife(double refog) =>
    0.4 + refog * 0.3 + NebbiaFixed.beadHold * 0.5 + refog;

/// 大雨点：每个词开唱处六成砸一颗，躲开正在唱的那句。整首一次排好（大小按 1 倍，画的时候再乘）。
List<NebbiaHit> nebbiaBigHits(
  List<NebbiaLaidLine> laid,
  List<List<List<int>>> words,
  double width,
  double height,
  int seed,
) {
  final LyricVisualizerRandom rnd = LyricVisualizerRandom(seed ^ 911);
  final double k = math.min(width, height) / 720;
  final List<NebbiaHit> out = <NebbiaHit>[];
  for (int li = 0; li < laid.length; li++) {
    final NebbiaLaidLine line = laid[li];
    if (line.credits != null) continue;
    final NebbiaLineRect rect = line.rect;
    for (final List<int> w in words[li]) {
      if (w.isEmpty || w.first >= line.chars.length) continue;
      final double t = line.chars[w.first].t;
      if (rnd.next() >= 0.6) continue;
      double x = 0;
      double y = 0;
      for (int tries = 0; tries < 8; tries++) {
        x = width * (0.03 + 0.94 * rnd.next());
        y = height * (0.03 + 0.94 * rnd.next());
        if (!rect.isFinite ||
            x < rect.x0 - 20 ||
            x > rect.x1 + 20 ||
            y < rect.y0 - 20 ||
            y > rect.y1 + 20) {
          break;
        }
      }
      final double r = (7 + rnd.next() * 6) * k;
      final int ns = 4 + (rnd.next() * 5).floor();
      final List<(double, double, double)> sat = <(double, double, double)>[
        for (int i = 0; i < ns; i++)
          () {
            final double a = rnd.next() * 6.28;
            final double d = r * (1.5 + rnd.next() * 1.4);
            return (
              math.cos(a) * d,
              math.sin(a) * d * 0.85 + r * 0.2,
              (1 + rnd.next() * 1.6) * k,
            );
          }(),
      ];
      out.add(NebbiaHit(t, x, y, r, true, sat, rnd.next() * 100));
    }
  }
  out.sort((NebbiaHit a, NebbiaHit b) => a.t.compareTo(b.t));
  return out;
}

/// 小雨点：每 20 毫秒一格，按这一格的人声强度（这里是歌词节拍包络）以泊松速率 0.15–7 个/秒落下；
/// 每格的随机数只由歌和格号决定，同一时刻同一首歌落在同一处。返回 [T − life, T] 里落下的。
List<NebbiaHit> nebbiaSmallHits(
  double t,
  double life,
  double density,
  double Function(double t) energy,
  double width,
  double height,
  int seed,
) {
  if (density <= 0) return const <NebbiaHit>[];
  final double k = math.min(width, height) / 720;
  final int b1 = (t / kNebbiaHitBucket).floor();
  final int b0 = b1 - (life / kNebbiaHitBucket).ceil();
  final List<NebbiaHit> out = <NebbiaHit>[];
  for (int b = b0; b <= b1; b++) {
    final LyricVisualizerRandom rnd = LyricVisualizerRandom(
      (seed + b * 0x9E3779B1) ^ 0x5ad1,
    );
    final double e = energy(b * kNebbiaHitBucket);
    final double rate = (0.15 + 7 * e * e) * density * kNebbiaHitBucket;
    if (rnd.next() >= rate) continue;
    final double ht = (b + rnd.next()) * kNebbiaHitBucket;
    if (ht > t) continue;
    out.add(
      NebbiaHit(
        ht,
        width * (0.03 + 0.94 * rnd.next()),
        height * (0.03 + 0.94 * rnd.next()),
        (2 + rnd.next() * 3.5) * k,
        false,
        const <(double, double, double)>[],
        rnd.next() * 100,
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// 凝露
// ---------------------------------------------------------------------------

/// 凝露：一层很密的细小冷凝水珠，一颗颗慢慢凝出、挂一阵再缩没、在别处再凝出（按窗外时钟直接算）。
void nebbiaPaintDew(
  Canvas canvas,
  Size size,
  double time,
  NebbiaSettings s,
  Color fog,
) {
  if (s.dew <= 0) return;
  final int n = math.min(
    4000,
    (size.width * size.height / 700 * s.dew).round(),
  );
  // 按半径分几档，一档一次 drawPoints。
  const int buckets = 6;
  final List<List<Offset>> bodies = List<List<Offset>>.generate(
    buckets,
    (_) => <Offset>[],
  );
  final double rMax = 2.6 * s.dewSize;
  for (int i = 0; i < n; i++) {
    final double period = 14 + 18 * nebbiaRand(i * 1.37 + 0.5);
    final double raw = time / period + nebbiaRand(i * 2.71);
    final double cycle = raw.floorToDouble();
    final double u = raw - cycle;
    // 0..0.25 凝出，0.25..0.75 挂着，0.75..0.9 缩没，之后空着。
    final double grow = u < 0.25
        ? nebbiaSmooth(u / 0.25)
        : (u < 0.75 ? 1 : (u < 0.9 ? 1 - nebbiaSmooth((u - 0.75) / 0.15) : 0));
    if (grow <= 0.05) continue;
    final double x = nebbiaRand(i * 5.11 + cycle * 1.93) * size.width;
    final double y =
        size.height * (1 - math.pow(nebbiaRand(i * 7.07 + cycle * 3.1), 1.15));
    final double r = (0.5 + 0.5 * nebbiaRand(i * 9.9 + cycle)) * rMax * grow;
    final int bk = (r / rMax * (buckets - 1)).round().clamp(0, buckets - 1);
    bodies[bk].add(Offset(x, y));
  }
  final Paint body = Paint()
    ..strokeCap = StrokeCap.round
    ..color = Color.lerp(
      fog,
      const Color(0xFFFFFFFF),
      0.25,
    )!.withValues(alpha: 0.55);
  final Paint glint = Paint()
    ..strokeCap = StrokeCap.round
    ..color = Color.fromRGBO(255, 255, 255, nebbiaClamp(0.45 * s.dewGlint));
  for (int b = 0; b < buckets; b++) {
    if (bodies[b].isEmpty) continue;
    final double r = math.max(0.6, (b + 0.5) / buckets * rMax);
    canvas.drawPoints(
      ui.PointMode.points,
      bodies[b],
      body..strokeWidth = r * 2,
    );
    if (s.dewGlint > 0 && r > 1) {
      canvas.drawPoints(ui.PointMode.points, <Offset>[
        for (final Offset p in bodies[b]) p.translate(-r * 0.35, -r * 0.35),
      ], glint..strokeWidth = r * 0.6);
    }
  }
}

// ---------------------------------------------------------------------------
// 融雪
// ---------------------------------------------------------------------------

/// 一片贴在玻璃上的雪：从远处飘过来（由小变大、由淡变清），粘住，慢慢化，化出一颗水珠，水珠再慢慢干掉。
class NebbiaFlakeState {
  const NebbiaFlakeState(
    this.center,
    this.radius,
    this.alpha,
    this.melt,
    this.water,
    this.dendrite,
    this.seed,
  );
  final Offset center;
  final double radius;
  final double alpha;

  /// 化了多少 0..1。
  final double melt;

  /// 化出的水珠半径（像素，0 没有）。
  final double water;
  final bool dendrite;
  final double seed;
}

/// 这一刻玻璃上的雪（按窗外时钟直接算）。
List<NebbiaFlakeState> nebbiaFlakesAt(
  double time,
  Size size,
  NebbiaSettings s,
) {
  if (s.snow <= 0) return const <NebbiaFlakeState>[];
  final int slots = math.min(
    160,
    (s.snow * size.width * size.height / 14000).round(),
  );
  final double melt = 9 / s.snowMelt;
  final List<NebbiaFlakeState> out = <NebbiaFlakeState>[];
  for (int i = 0; i < slots; i++) {
    final double period = 1.4 + melt + 10 + 8 * nebbiaRand(i * 1.9);
    final double raw = time / period + nebbiaRand(i * 4.3);
    final double cycle = raw.floorToDouble();
    final double age = (raw - cycle) * period;
    final double seed = nebbiaRand(i * 6.1 + cycle * 2.3) * 100;
    final Offset land = Offset(
      nebbiaRand(i * 2.2 + cycle * 5.5) * size.width,
      nebbiaRand(i * 8.8 + cycle * 1.1) * size.height,
    );
    final double r =
        (0.012 + 0.02 * math.pow(nebbiaRand(seed), 2)) *
        size.height *
        s.snowSize;
    final bool dendrite = nebbiaRand(seed + 3) < 0.4;
    if (age < 1.4) {
      // 飞过来：按透视从小、淡变大、清楚，跟着雪往下落，快到时慢下来。
      final double u = nebbiaSmooth(age / 1.4);
      out.add(
        NebbiaFlakeState(
          land.translate(0, -(1 - u) * size.height * 0.08),
          r * (0.25 + 0.75 * u),
          u,
          0,
          0,
          dendrite,
          seed,
        ),
      );
      continue;
    }
    final double m = nebbiaClamp((age - 1.4) / melt);
    // 水量和雪花大小是对数关系，雪调大也不会满屏大水。
    final double water =
        math.log(1 + r) * 1.1 * nebbiaSmooth(nebbiaClamp(m * 1.4));
    final double dry = 1 - nebbiaSmooth(nebbiaClamp((age - 1.4 - melt) / 10));
    out.add(
      NebbiaFlakeState(
        land,
        r * (1 - 0.7 * m),
        1 - nebbiaSmooth(m),
        m,
        water * dry,
        dendrite,
        seed,
      ),
    );
  }
  return out;
}

/// 画一片雪：六成小团（几团软的白），四成枝晶（六个角带细枝，一半缺一两个角）。
void nebbiaPaintFlake(Canvas canvas, NebbiaFlakeState f, Color light) {
  if (f.alpha <= 0.01 || f.radius < 0.6) return;
  final Color col = Color.lerp(
    const Color(0xFFF4F8FF),
    light,
    0.15,
  )!.withValues(alpha: 0.9 * f.alpha);
  if (!f.dendrite) {
    final Paint p = Paint()
      ..color = col
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        f.radius * (0.25 + 0.3 * f.melt),
      );
    for (int k = 0; k < 4; k++) {
      final double a = nebbiaRand(f.seed + k) * 6.28;
      final double d = f.radius * 0.35 * nebbiaRand(f.seed + k * 2.0);
      canvas.drawCircle(
        f.center.translate(math.cos(a) * d, math.sin(a) * d),
        f.radius * (0.45 + 0.25 * nebbiaRand(f.seed + k * 3.0)),
        p,
      );
    }
    return;
  }
  final Paint p = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = math.max(0.7, f.radius * 0.09)
    ..color = col;
  final Path path = Path();
  final double rot = nebbiaRand(f.seed + 9) * math.pi;
  final int missing = nebbiaRand(f.seed + 5) < 0.5
      ? (1 + (nebbiaRand(f.seed + 6) * 2).floor())
      : 0;
  for (int k = 0; k < 6; k++) {
    if (k < missing) continue;
    final double a = rot + k * math.pi / 3;
    final Offset dir = Offset(math.cos(a), math.sin(a));
    final Offset tip = f.center + dir * f.radius;
    path
      ..moveTo(f.center.dx, f.center.dy)
      ..lineTo(tip.dx, tip.dy);
    for (final double along in <double>[0.45, 0.7]) {
      final Offset base = f.center + dir * f.radius * along;
      for (final double side in <double>[-1, 1]) {
        final double b = a + side * math.pi / 3;
        final Offset end =
            base + Offset(math.cos(b), math.sin(b)) * f.radius * 0.28;
        path
          ..moveTo(base.dx, base.dy)
          ..lineTo(end.dx, end.dy);
      }
    }
  }
  canvas.drawPath(path, p);
}
