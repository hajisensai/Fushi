/// 隐喻的固定贴图：融球 / 圆环的轮廓精灵、半调网点的一格、阈值噪点、砂纸颗粒和杂点。
/// folia 在显影着色器里逐像素算这些；这里一次画成小图（PictureRecorder → toImageSync），每帧只
/// 平铺 / 实例化，画面在 GPU 上合成。噪点和散列与 folia 着色器同一套式子（周期化以便平铺）。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// 不带 sin 的散列（folia `hash`）：0..1。
double metaphorHash(double x, double y) {
  double qx = (x * 0.1031) % 1;
  double qy = (y * 0.1031) % 1;
  double qz = (x * 0.1031) % 1;
  final double d = qx * (qy + 33.33) + qy * (qz + 33.33) + qz * (qx + 33.33);
  qx += d;
  qy += d;
  qz += d;
  return ((qx + qy) * qz) % 1;
}

/// 值噪声（folia `vnoise`）；[period] 大于 0 时格点按它折回，贴图平铺无缝。
double metaphorValueNoise(double x, double y, [int period = 0]) {
  final double ix = x.floorToDouble();
  final double iy = y.floorToDouble();
  double fx = x - ix;
  double fy = y - iy;
  fx = fx * fx * (3 - 2 * fx);
  fy = fy * fy * (3 - 2 * fy);
  double h(double a, double b) {
    if (period > 0) {
      a = a % period;
      b = b % period;
    }
    return metaphorHash(a, b);
  }

  final double a = h(ix, iy);
  final double b = h(ix + 1, iy);
  final double c = h(ix, iy + 1);
  final double d = h(ix + 1, iy + 1);
  return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy;
}

/// 世界共用的手抖位移场（folia 图形着色器里的 shake，未乘幅度）。
(double, double) metaphorShake(double x, double y, double t) {
  double sx =
      (math.sin(y * 1.7 + t * 0.35) + math.sin(x * 0.9 - t * 0.2)) * 0.5;
  double sy =
      (math.sin(x * 1.3 - t * 0.3) + math.sin(y * 1.1 + t * 0.25)) * 0.5;
  sx += 0.32 * math.sin(y * 7.1 + x * 2.3 + t * 0.6);
  sy += 0.32 * math.sin(x * 6.3 - y * 1.9 - t * 0.5);
  sx += 0.12 * (math.sin(y * 37.0 + x * 17.0) + math.sin(x * 53.0));
  sy += 0.12 * (math.sin(x * 41.0 - y * 13.0) + math.sin(y * 59.0));
  return (sx, sy);
}

/// 精灵的半径（像素）。
const double metaphorSpriteRadius = 128;
const double metaphorRingSpriteRadius = 256;

/// 半调一格的边长（像素）。
const double metaphorDotCell = 32;

double _smoothstep(double e0, double e1, double x) {
  final double t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// 一张图集里所有的固定贴图。
class MetaphorTextures {
  MetaphorTextures._(
    this.blobCore,
    this.blobHalo,
    this.ringCore,
    this.ringHalo,
    this.dotCell,
    this.rough,
    this.grain,
    this.speck,
  );

  factory MetaphorTextures.create() => MetaphorTextures._(
    _radialSprite(metaphorSpriteRadius, (double r) {
      final double k = math.max(0, 1 - r * r);
      return math.min(1, k * k * k * 1.45);
    }, _evenStops(48)),
    _radialSprite(metaphorSpriteRadius, (double r) {
      final double k = math.max(0, 1 - r * r);
      return k * k;
    }, _evenStops(48)),
    _radialSprite(
      metaphorRingSpriteRadius,
      (double r) => 1 - _smoothstep(0.012, 0.03, (r - 0.88).abs()),
      _ringStops(),
    ),
    _radialSprite(
      metaphorRingSpriteRadius,
      (double r) => 1 - _smoothstep(0.02, 0.12, (r - 0.88).abs()),
      _ringStops(),
    ),
    _dotCellImage(),
    _noiseTile(240, (int x, int y) {
      // folia 的阈值噪点：(vnoise(frag * 0.45) - 0.5) * 0.16 + (hash(floor(frag * 0.9)) - 0.5) * 0.08，
      // 归一到 0..1（调用方按 0.24 × 颗粒加上去，再把阈值抬高一半）
      final double v = metaphorValueNoise(x * 0.45, y * 0.45, 108);
      final double h = metaphorHash(
        ((x * 0.9).floor() % 216).toDouble(),
        ((y * 0.9).floor() % 216).toDouble(),
      );
      return (v * 0.16 + h * 0.08) / 0.24;
    }),
    _noiseTile(250, (int x, int y) {
      // 砂纸：细颗粒 + 纸的斑驳，围绕 0.5 的灰（叠加混合时 0.5 不改颜色），按颗粒 2 倍的幅度烤进去
      final double fine = metaphorHash(
        (x / 1.4).floorToDouble(),
        (y / 1.4).floorToDouble(),
      );
      final double mottle = metaphorValueNoise(x * 0.12, y * 0.12, 30);
      final double d = ((fine - 0.5) * 0.22 + (mottle - 0.5) * 0.1) * 2;
      return (0.5 + d / 2).clamp(0.0, 1.0);
    }),
    _speckTile(),
  );

  /// 融球：k³ × 1.45（封顶 1）和 k²，k = 1 − r²。
  final ui.Image blobCore;
  final ui.Image blobHalo;

  /// 圆环：0.88 处的细环带和它两边的一圈。
  final ui.Image ringCore;
  final ui.Image ringHalo;

  /// 半调的一格：α = 1 − (d / 0.58)²（只在圆点半径以内）。
  final ui.Image dotCell;

  /// 阈值噪点（灰度 0..1）。
  final ui.Image rough;

  /// 砂纸颗粒（叠加混合用的灰）。
  final ui.Image grain;

  /// 杂点（白点，透明底）。
  final ui.Image speck;

  void dispose() {
    for (final ui.Image i in <ui.Image>[
      blobCore,
      blobHalo,
      ringCore,
      ringHalo,
      dotCell,
      rough,
      grain,
      speck,
    ]) {
      i.dispose();
    }
  }
}

List<double> _evenStops(int n) => <double>[
  for (int i = 0; i < n; i++) i / (n - 1),
];

List<double> _ringStops() => <double>[
  0,
  0.2,
  0.4,
  0.6,
  0.7,
  for (int i = 0; i <= 60; i++) 0.72 + i * 0.0047,
  1,
];

ui.Image _radialSprite(
  double radius,
  double Function(double r) alpha,
  List<double> stops,
) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Offset c = Offset(radius, radius);
  canvas.drawCircle(
    c,
    radius,
    Paint()
      ..shader = ui.Gradient.radial(c, radius, <Color>[
        for (final double s in stops)
          Color.from(
            alpha: alpha(s).clamp(0.0, 1.0),
            red: 1,
            green: 1,
            blue: 1,
          ),
      ], stops),
  );
  final ui.Picture picture = recorder.endRecording();
  final int side = (radius * 2).ceil();
  final ui.Image image = picture.toImageSync(side, side);
  picture.dispose();
  return image;
}

ui.Image _dotCellImage() {
  const double r0 = metaphorDotCell * 0.58;
  final List<double> stops = _evenStops(24);
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  const Offset c = Offset(metaphorDotCell / 2, metaphorDotCell / 2);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, metaphorDotCell, metaphorDotCell),
    Paint()
      ..shader = ui.Gradient.radial(c, r0, <Color>[
        for (final double s in stops)
          Color.from(alpha: 1 - s * s, red: 1, green: 1, blue: 1),
      ], stops),
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = picture.toImageSync(
    metaphorDotCell.toInt(),
    metaphorDotCell.toInt(),
  );
  picture.dispose();
  return image;
}

/// 灰度小图：按 32 级量化，每级一次 drawRawPoints。
ui.Image _noiseTile(int side, double Function(int x, int y) value) {
  const int levels = 32;
  final List<List<double>> buckets = List<List<double>>.generate(
    levels,
    (_) => <double>[],
  );
  for (int y = 0; y < side; y++) {
    for (int x = 0; x < side; x++) {
      final int level = (value(x, y).clamp(0.0, 1.0) * (levels - 1)).round();
      buckets[level]
        ..add(x + 0.5)
        ..add(y + 0.5);
    }
  }
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  for (int level = 0; level < levels; level++) {
    if (buckets[level].isEmpty) continue;
    final double g = level / (levels - 1);
    canvas.drawRawPoints(
      ui.PointMode.points,
      Float32List.fromList(buckets[level]),
      Paint()
        ..color = Color.from(alpha: 1, red: g, green: g, blue: g)
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.square,
    );
  }
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = picture.toImageSync(side, side);
  picture.dispose();
  return image;
}

/// 杂点：2.2 像素一格，千分之十二的格子有一个点。
ui.Image _speckTile() {
  const int cells = 100;
  const double cell = 2.2;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  final Paint paint = Paint()..color = Colors.white;
  for (int y = 0; y < cells; y++) {
    for (int x = 0; x < cells; x++) {
      if (metaphorHash(x.toDouble(), y + 0.5) < 0.988) continue;
      canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), paint);
    }
  }
  final ui.Picture picture = recorder.endRecording();
  final int side = (cells * cell).round();
  final ui.Image image = picture.toImageSync(side, side);
  picture.dispose();
  return image;
}
