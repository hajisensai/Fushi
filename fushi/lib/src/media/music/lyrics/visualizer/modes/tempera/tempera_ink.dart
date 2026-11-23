/// 凝彩「墨染奥行」里的墨（folia `temperaInkFlash.ts`）：纸面平时一层浅灰水渍；鼓点打下时漫过一片
/// 强调色的墨渍、水渍同时退掉，约 0.4 秒淡回。每帧只由当前时间之前最近的两次击打决定，不累积状态：
/// 拖进度、暂停后画面一致。
///
/// folia 用一张噪声纹理 + 片元着色器逐像素判「是不是墨」；这里在 CPU 上按击打时刻的种子生成几块
/// 边缘起伏的墨块（谐波扰动的闭合曲线），填强调色并描一圈更浓的水痕。形状只由击打时刻决定，
/// 同一次击打每帧一样，路径按击打缓存。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

/// 两次闪至少相隔（秒）。
const double kTemperaInkHitGap = 0.2;

const double _flashAttack = 0.015;
const double _flashHold = 0.16;
const double _flashFall = 0.09;
const double _flashAlpha = 0.28;
const double _stainAlpha = 0.07;
const double _stainLift = 0.9;

/// 一次闪在击打后 [age] 秒的强度：15 ms 升起、保持、再指数回落（folia `flashEnvelope`）。
double temperaInkFlashEnvelope(double age) {
  if (age < 0) return 0;
  if (age < _flashAttack) return age / _flashAttack;
  if (age < _flashAttack + _flashHold) return 1;
  return math.exp(-(age - _flashAttack - _flashHold) / _flashFall);
}

/// 挑出会闪的击打（秒，升序）：间隔不足 [kTemperaInkHitGap] 的并掉（folia `resolveFlashIndices`）。
List<double> temperaInkFlashHits(Iterable<double> hits) {
  final List<double> out = <double>[];
  double last = double.negativeInfinity;
  for (final double t in hits) {
    if (t - last < kTemperaInkHitGap) continue;
    out.add(t);
    last = t;
  }
  return out;
}

/// 升序表里最后一个 ≤ [time] 的下标；没有为 -1。
int temperaInkLastHit(List<double> hits, double time) {
  int lo = 0;
  int hi = hits.length;
  while (lo < hi) {
    final int mid = (lo + hi) >> 1;
    if (hits[mid] <= time) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo - 1;
}

/// folia `seededRandom`（LCG）。
double Function() _seeded(int seed) {
  int state = ((seed * 2654435761 + 12345) & 0xFFFFFFFF);
  if (state == 0) state = 1;
  return () {
    state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
    return state / 4294967296;
  };
}

/// 一片墨渍：几块墨。坐标是 0–1 视口比例。
List<ui.Path> _blots(int seed, ui.Size size, double coverage) {
  final double Function() r = _seeded(seed);
  final double diag = math.sqrt(
    size.width * size.width + size.height * size.height,
  );
  final int count = 4 + (r() * 4).floor();
  // 每块的平均半径：块数 × πr² ≈ coverage × 面积。
  final double area = size.width * size.height * coverage;
  final double base = math.sqrt(area / (count * math.pi));
  final List<ui.Path> out = <ui.Path>[];
  for (int b = 0; b < count; b++) {
    final double cx = r() * size.width;
    final double cy = r() * size.height;
    final double radius = base * (0.55 + r() * 0.9);
    final double rot = r() * math.pi * 2;
    final double stretch = 0.7 + r() * 0.6;
    final List<(int, double, double)> harmonics = <(int, double, double)>[
      (2, 0.12 + r() * 0.16, r() * math.pi * 2),
      (3, 0.06 + r() * 0.1, r() * math.pi * 2),
      (5, 0.03 + r() * 0.05, r() * math.pi * 2),
      (9, 0.01 + r() * 0.025, r() * math.pi * 2),
    ];
    const int steps = 56;
    final ui.Path path = ui.Path();
    for (int i = 0; i <= steps; i++) {
      final double a = i / steps * math.pi * 2;
      double k = 1;
      for (final (int n, double amp, double ph) in harmonics) {
        k += amp * math.sin(a * n + ph);
      }
      final double lx = math.cos(a) * radius * k * stretch;
      final double ly = math.sin(a) * radius * k / stretch;
      final double x = cx + lx * math.cos(rot) - ly * math.sin(rot);
      final double y = cy + lx * math.sin(rot) + ly * math.cos(rot);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    out.add(path);
  }
  if (diag <= 0) return const <ui.Path>[];
  return out;
}

/// 墨层：缓存每次击打 / 每段水渍的墨块路径（尺寸变了清空）。
class TemperaInkLayer {
  ui.Size _size = ui.Size.zero;
  final Map<int, List<ui.Path>> _hitShapes = <int, List<ui.Path>>{};
  final Map<int, List<ui.Path>> _stainShapes = <int, List<ui.Path>>{};
  final ui.Paint _fill = ui.Paint()..style = ui.PaintingStyle.fill;
  final ui.Paint _rim = ui.Paint()..style = ui.PaintingStyle.stroke;

  List<ui.Path> _shapes(
    Map<int, List<ui.Path>> cache,
    int key,
    double coverage,
  ) {
    if (cache.length > 24) cache.clear();
    return cache.putIfAbsent(key, () => _blots(key, _size, coverage));
  }

  /// 画一帧。[hits] 是 [temperaInkFlashHits] 过的击打（显示时间，秒）；[strength] 0–2，0 不画。
  void paint(
    ui.Canvas canvas,
    ui.Size size,
    double time, {
    required List<double> hits,
    required double strength,
    required int paragraphIndex,
    required ui.Color ink,
  }) {
    if (strength <= 0 || hits.isEmpty || size.isEmpty) return;
    if (size != _size) {
      _size = size;
      _hitShapes.clear();
      _stainShapes.clear();
    }
    final int last = temperaInkLastHit(hits, time);
    double lift = 0;
    final List<(List<ui.Path>, double)> flashes = <(List<ui.Path>, double)>[];
    // 前一次（还在淡出）在下，最近一次在上。
    for (int slot = 1; slot >= 0; slot--) {
      final int at = last - slot;
      if (at < 0) continue;
      final double env = temperaInkFlashEnvelope(time - hits[at]);
      if (env < 0.01) continue;
      lift = math.max(lift, env);
      flashes.add((
        _shapes(_hitShapes, (hits[at] * 100).round(), 0.3),
        (env * _flashAlpha * strength).clamp(0.0, 1.0),
      ));
    }
    // 水渍：按段落换形，慢慢上漂。
    final double stainA =
        _stainAlpha * math.min(1, strength) * (1 - _stainLift * lift);
    if (stainA > 0.003) {
      final double drift = -time * math.min(size.width, size.height) * 0.006;
      canvas.save();
      canvas.translate(0, drift % size.height);
      _drawBlots(
        canvas,
        _shapes(_stainShapes, math.max(0, paragraphIndex) * 7 + 3, 0.3),
        const ui.Color(0xFF000000),
        stainA,
      );
      canvas.restore();
    }
    for (final (List<ui.Path> shapes, double a) in flashes) {
      if (a > 0.003) _drawBlots(canvas, shapes, ink, a);
    }
  }

  void _drawBlots(
    ui.Canvas canvas,
    List<ui.Path> shapes,
    ui.Color c,
    double a,
  ) {
    // 内部平整（0.88），边上一圈干掉的浓痕（+0.3）。
    _fill.color = c.withValues(alpha: (a * 0.88).clamp(0.0, 1.0));
    _rim
      ..color = c.withValues(alpha: (a * 0.3).clamp(0.0, 1.0))
      ..strokeWidth = 2.5;
    for (final ui.Path p in shapes) {
      canvas.drawPath(p, _fill);
      canvas.drawPath(p, _rim);
    }
  }
}
