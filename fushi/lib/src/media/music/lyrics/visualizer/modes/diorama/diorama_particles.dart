/// 镜台的点云层（folia `dioramaParticleSurfaces.ts` / `dioramaParticleModel.ts` /
/// `dioramaParticleShaders.ts` / `DioramaParticleField.tsx` 的 CPU 移植）。
///
/// 每个阵列锚点展开成焊接好的点阵（立方体壳 / 圆柱壳 / 四面体 / 圆环），长廊模式是沿路径的
/// 圆环网格。每帧在 CPU 上算位移：波纹源（由歌词起字触发，代替 folia 的频段起音 / 节拍）
/// 产生扩散、振荡、衰减的波包，加上慢呼吸；投影后用 `drawRawAtlas` 一次画完（对比层 + 可选的
/// 叠加辉光层）。folia 在顶点着色器里做的事，这里逐点做一遍，所以点数按 CPU 预算减半。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_path.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_rig.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_scene_layout.dart';

const int dioramaParticleDensityMin = 96;
const int dioramaParticleDensityMax = 1536;
const int dioramaParticleDensityStep = 24;
const int _maxCloudPointsPerCluster = 1024;
const int _maxCorridorPointsPerSpan = 2048;

/// CPU 逐点计算的份额：folia 在 GPU 上跑满预算，这里每个锚点只取一半的点。
const double dioramaCpuPointShare = 0.5;

int dioramaNormalizeDensity(double density) {
  final double c = density.clamp(
    dioramaParticleDensityMin.toDouble(),
    dioramaParticleDensityMax.toDouble(),
  );
  return math.max(
    dioramaParticleDensityMin,
    (c / dioramaParticleDensityStep).floor() * dioramaParticleDensityStep,
  );
}

// ─── 图元点阵 ──────────────────────────────────────────────────────────────

class DioramaSurface {
  const DioramaSurface({
    required this.positions,
    required this.normals,
    required this.radius,
    required this.count,
    required this.spacing,
  });

  final Float32List positions;
  final Float32List normals;

  /// 点阵到中心的平均距离（图元自身尺寸）：位移按它的比例算。
  final double radius;
  final int count;

  /// 相邻点间距（以 radius 为单位），决定波纹细节上限。
  final double spacing;
}

const double _boxHalf = 0.55;
const double _cylRadius = 0.58;
const double _cylHalfHeight = 0.75;
const double _torusMajor = 0.68;
const double _torusTube = 0.12;
const List<List<double>> _tetraVertices = <List<double>>[
  <double>[0, 0.86, 0],
  <double>[-0.81, -0.5, 0.47],
  <double>[0.81, -0.5, 0.47],
  <double>[0, -0.5, -0.94],
];
const List<List<int>> _tetraFaces = <List<int>>[
  <int>[0, 1, 2],
  <int>[0, 2, 3],
  <int>[0, 3, 1],
  <int>[1, 3, 2],
];

final Map<String, DioramaSurface> _surfaceCache = <String, DioramaSurface>{};

int _countBoxShell(int across, int tall) =>
    2 * (across * tall + tall * across + across * across) -
    4 * (across + tall + across) +
    8;

/// 某种图元的点阵（按图元、预算、竖向拉伸分桶缓存）。法线是位置的连续函数（径向），
/// 所以大幅位移时面与面不会撕开（folia 的焊接规则）。
DioramaSurface dioramaSurface(
  DioramaShapeKind kind,
  int budget,
  double stretchY,
) {
  final double stretchKey = (math.max(0.2, stretchY) * 4).round() / 4;
  final String key = '${kind.name}:$budget:$stretchKey';
  final DioramaSurface? hit = _surfaceCache[key];
  if (hit != null) return hit;
  final List<double> pos = <double>[];
  final List<double> nor = <double>[];
  double spacing = 0;
  void push(double x, double y, double z, double nx, double ny, double nz) {
    pos
      ..add(x)
      ..add(y)
      ..add(z);
    nor
      ..add(nx)
      ..add(ny)
      ..add(nz);
  }

  void pushRadial(
    double x,
    double y,
    double z, [
    double cx = 0,
    double cy = 0,
    double cz = 0,
  ]) {
    final double dx = x - cx, dy = y - cy, dz = z - cz;
    final double l = math.sqrt(dx * dx + dy * dy + dz * dz);
    final double inv = l == 0 ? 0 : 1 / l;
    push(x, y, z, dx * inv, dy * inv, dz * inv);
  }

  switch (kind) {
    case DioramaShapeKind.box:
      int bestA = 2, bestT = 2;
      for (int across = 2; across <= 96; across++) {
        final int tall = math.max(2, (1 + (across - 1) * stretchKey).round());
        if (_countBoxShell(across, tall) > budget) break;
        bestA = across;
        bestT = tall;
      }
      double axis(int i, int steps) => (i / (steps - 1) - 0.5) * 2 * _boxHalf;
      spacing = 2 * _boxHalf / math.max(1, math.min(bestA, bestT) - 1);
      for (int iy = 0; iy < bestT; iy++) {
        for (int iz = 0; iz < bestA; iz++) {
          for (int ix = 0; ix < bestA; ix++) {
            final bool interior =
                ix > 0 &&
                ix < bestA - 1 &&
                iy > 0 &&
                iy < bestT - 1 &&
                iz > 0 &&
                iz < bestA - 1;
            if (interior) continue;
            pushRadial(axis(ix, bestA), axis(iy, bestT), axis(iz, bestA));
          }
        }
      }
    case DioramaShapeKind.sphere:
      final double aspect =
          (math.pi * 2 * _cylRadius) /
          (2 * _cylHalfHeight * math.max(0.2, stretchKey));
      final int rows = math.max(
        2,
        math.sqrt(budget / math.max(0.1, aspect)).round(),
      );
      final int cols = math.max(3, budget ~/ rows);
      spacing = math.max(
        2 * _cylHalfHeight / (rows - 1),
        math.pi * 2 * _cylRadius / cols,
      );
      for (int row = 0; row < rows; row++) {
        final double y = (row / (rows - 1) - 0.5) * 2 * _cylHalfHeight;
        for (int c = 0; c < cols; c++) {
          final double a = c / cols * math.pi * 2;
          final double co = math.cos(a), si = math.sin(a);
          push(co * _cylRadius, y, si * _cylRadius, co, 0, si);
        }
      }
    case DioramaShapeKind.cone:
      int steps = 1;
      while (_tetraFaces.length * ((steps + 2) * (steps + 3) ~/ 2) <= budget) {
        steps++;
      }
      final List<double> v0 = _tetraVertices[0], v1 = _tetraVertices[1];
      spacing =
          math.sqrt(
            math.pow(v0[0] - v1[0], 2) +
                math.pow(v0[1] - v1[1], 2) +
                math.pow(v0[2] - v1[2], 2),
          ) /
          steps;
      for (final List<int> face in _tetraFaces) {
        final List<double> a = _tetraVertices[face[0]];
        final List<double> b = _tetraVertices[face[1]];
        final List<double> c = _tetraVertices[face[2]];
        for (int i = 0; i <= steps; i++) {
          for (int j = 0; j <= steps - i; j++) {
            final double wa = i / steps, wb = j / steps, wc = 1 - wa - wb;
            pushRadial(
              a[0] * wa + b[0] * wb + c[0] * wc,
              a[1] * wa + b[1] * wb + c[1] * wc,
              a[2] * wa + b[2] * wb + c[2] * wc,
              0,
              -0.16,
              0,
            );
          }
        }
      }
    case DioramaShapeKind.torus:
      final int minor = math.max(4, math.sqrt(budget / 4).round());
      final int major = math.max(6, budget ~/ minor);
      spacing = math.max(
        math.pi * 2 * (_torusMajor + _torusTube) / major,
        math.pi * 2 * _torusTube / minor,
      );
      for (int i = 0; i < major; i++) {
        final double ma = i / major * math.pi * 2;
        final double mc = math.cos(ma), ms = math.sin(ma);
        for (int j = 0; j < minor; j++) {
          final double na = j / minor * math.pi * 2;
          final double nc = math.cos(na), ns = math.sin(na);
          final double rr = _torusMajor + _torusTube * nc;
          push(rr * mc, _torusTube * ns, rr * ms, nc * mc, ns, nc * ms);
        }
      }
  }
  final int count = pos.length ~/ 3;
  double total = 0;
  for (int i = 0; i < count; i++) {
    total += math.sqrt(
      pos[i * 3] * pos[i * 3] +
          pos[i * 3 + 1] * pos[i * 3 + 1] +
          pos[i * 3 + 2] * pos[i * 3 + 2],
    );
  }
  final double radius = count > 0 ? total / count : 1;
  final DioramaSurface s = DioramaSurface(
    positions: Float32List.fromList(pos),
    normals: Float32List.fromList(nor),
    radius: radius,
    count: count,
    spacing: spacing / radius,
  );
  _surfaceCache[key] = s;
  return s;
}

// ─── 点缓冲 ────────────────────────────────────────────────────────────────

/// 每点字段：本地位置 xyz、位移方向 xyz、锚点 xyz、整体缩放、竖向拉伸、图元半径、
/// 相位、颜色槽、远景、渐变静态相位、波坐标 w1/w2。
const int _stride = 18;

/// [DioramaParticleGeometry.data] 每点的 float 数（GPU 端按这个布局直接当实例缓冲上传）。
const int dioramaParticleStride = _stride;

class DioramaParticleGeometry {
  DioramaParticleGeometry._(this.data, this.count, this.spacing, this.corridor);

  final Float32List data;
  final int count;
  final double spacing;
  final bool corridor;

  double get waveNumberMax => (math.pi * 2) / math.max(1e-4, spacing * 4);

  /// [share]：每个锚点取预算的多少（Canvas 后备逐点在 CPU 上算，取 [dioramaCpuPointShare]；
  /// GPU 在顶点着色器里算，跑满 1.0，和 folia 一样）。
  static DioramaParticleGeometry clouds(
    List<DioramaCluster> clusters,
    double density, {
    double share = dioramaCpuPointShare,
  }) {
    final int budget = dioramaNormalizeDensity(
      math.min(density, _maxCloudPointsPerCluster.toDouble()) * share,
    );
    final List<DioramaSurface> surfaces = <DioramaSurface>[
      for (final DioramaCluster c in clusters)
        dioramaSurface(c.shape.kind, budget, c.shape.stretchY),
    ];
    int count = 0;
    double spacing = 0;
    for (final DioramaSurface s in surfaces) {
      count += s.count;
      spacing = math.max(spacing, s.spacing);
    }
    final Float32List d = Float32List(count * _stride);
    int t = 0;
    for (int ci = 0; ci < clusters.length; ci++) {
      final DioramaCluster c = clusters[ci];
      final DioramaSurface s = surfaces[ci];
      final double phase =
          dioramaSeededUnit(c.particleSeed + 31.0) * math.pi * 2;
      for (int p = 0; p < s.count; p++, t++) {
        final int o = t * _stride;
        final double px = s.positions[p * 3],
            py = s.positions[p * 3 + 1],
            pz = s.positions[p * 3 + 2];
        d[o] = px;
        d[o + 1] = py;
        d[o + 2] = pz;
        d[o + 3] = s.normals[p * 3];
        d[o + 4] = s.normals[p * 3 + 1];
        d[o + 5] = s.normals[p * 3 + 2];
        d[o + 6] = c.shape.position.x;
        d[o + 7] = c.shape.position.y;
        d[o + 8] = c.shape.position.z;
        d[o + 9] = c.shape.scale;
        d[o + 10] = c.shape.stretchY;
        d[o + 11] = s.radius;
        d[o + 12] = phase;
        d[o + 13] = c.shape.colorSlot.toDouble();
        d[o + 14] = c.shape.isFar ? 1 : 0;
        d[o + 15] =
            px * 0.2 +
            py * c.shape.stretchY * 0.16 +
            pz * 0.13 +
            phase * 0.05 +
            c.shape.colorSlot * 0.5;
        d[o + 16] = phase + (px + pz * 0.6) * 2.2;
        d[o + 17] = phase * 0.7 + py * 2.6;
      }
    }
    return DioramaParticleGeometry._(d, count, spacing, false);
  }

  static DioramaParticleGeometry corridorTunnel(
    List<DioramaCorridorSpan> spans,
    double density, {
    double share = dioramaCpuPointShare,
  }) {
    const double radius = dioramaCorridorRadius;
    final int perSpanBudget = dioramaNormalizeDensity(
      math.min(density, _maxCorridorPointsPerSpan.toDouble()) * share,
    );
    final int segs = math.max(
      12,
      math.min(256, math.sqrt(perSpanBudget * 2.4).round()),
    );
    final int rings = math.max(1, perSpanBudget ~/ segs);
    final int count = spans.length * segs * rings;
    const double spanUnits = dioramaStepDistance / radius;
    final double spacing = math.max(
      spanUnits / math.max(1, rings),
      math.pi * 2 / segs,
    );
    final Float32List d = Float32List(count * _stride);
    int t = 0;
    for (final DioramaCorridorSpan span in spans) {
      for (int ring = 0; ring < rings; ring++) {
        final double tt = rings > 1 ? ring / (rings - 1) : 0.5;
        final DioramaVec center =
            span.from.position + (span.to.position - span.from.position) * tt;
        final DioramaVec right =
            (span.from.right + (span.to.right - span.from.right) * tt)
                .normalized;
        final DioramaVec up =
            (span.from.up + (span.to.up - span.from.up) * tt).normalized;
        final double longitudinal = span.pathStart + tt;
        for (int s = 0; s < segs; s++, t++) {
          final double angle = s / segs * math.pi * 2;
          final DioramaVec radial =
              (right * math.cos(angle) + up * math.sin(angle)).normalized;
          final int o = t * _stride;
          d[o] = radial.x * radius;
          d[o + 1] = radial.y * radius;
          d[o + 2] = radial.z * radius;
          d[o + 3] = radial.x;
          d[o + 4] = radial.y;
          d[o + 5] = radial.z;
          d[o + 6] = center.x;
          d[o + 7] = center.y;
          d[o + 8] = center.z;
          d[o + 9] = 1;
          d[o + 10] = 1;
          d[o + 11] = radius;
          d[o + 12] = longitudinal * 1.7;
          final int slot = (span.pathStart + ring) % 2;
          d[o + 13] = slot.abs().toDouble();
          d[o + 14] = 0;
          d[o + 15] =
              (radial.x * 0.2 + radial.y * 0.16 + radial.z * 0.13) * radius +
              longitudinal * 1.7 * 0.05 +
              slot.abs() * 0.5;
          d[o + 16] = longitudinal * spanUnits;
          d[o + 17] = angle;
        }
      }
    }
    return DioramaParticleGeometry._(d, count, spacing, true);
  }
}

// ─── 波纹源 ────────────────────────────────────────────────────────────────

/// 三种尺度的波纹：低频宽而慢，高频窄而快（folia `RIPPLE_BANDS`）。
class DioramaRippleBand {
  const DioramaRippleBand(
    this.strength,
    this.speed,
    this.width,
    this.wavenumber,
  );

  final double strength;
  final double speed;
  final double width;
  final double wavenumber;
}

const List<DioramaRippleBand> dioramaRippleBands = <DioramaRippleBand>[
  DioramaRippleBand(1.45, 0.9, 0.66, 3.4),
  DioramaRippleBand(0.9, 1.6, 0.36, 5.5),
  DioramaRippleBand(0.5, 2.5, 0.22, 9),
];
const int dioramaRippleSlotsPerBand = 3;
const int dioramaRippleCount = 9;

class DioramaRipplePool {
  final Float32List sources = Float32List(dioramaRippleCount * 4);
  final Float32List shapes = Float32List(dioramaRippleCount * 4);
  final List<int> cursor = <int>[0, 0, 0];
  int spawned = 0;

  void spawn(
    int band,
    double strength,
    double now, {
    required bool corridor,
    required double readHeadAlong,
  }) {
    final int seed = dioramaHashString('diorama-ripple:$spawned');
    final DioramaRippleBand preset = dioramaRippleBands[band];
    final double height = dioramaSeededUnit(seed + 1.0);
    final double spread = dioramaSeededUnit(seed + 2.0);
    final double pace = dioramaSeededUnit(seed + 3.0);
    final int o = (band * dioramaRippleSlotsPerBand + cursor[band]) * 4;
    if (corridor) {
      sources[o] = readHeadAlong + 0.4 + dioramaSeededUnit(seed + 4.0) * 2.2;
      sources[o + 1] = dioramaSeededUnit(seed + 5.0) * math.pi * 2;
      sources[o + 2] = 0;
    } else {
      final double up = dioramaSeededUnit(seed + 4.0) * 2 - 1;
      final double around = dioramaSeededUnit(seed + 5.0) * math.pi * 2;
      final double ring = math.sqrt(math.max(0, 1 - up * up));
      sources[o] = ring * math.cos(around);
      sources[o + 1] = up;
      sources[o + 2] = ring * math.sin(around);
    }
    sources[o + 3] = now;
    shapes[o] = preset.strength * strength * (0.7 + height * 0.6);
    shapes[o + 1] = preset.speed * (0.8 + pace * 0.45);
    shapes[o + 2] = preset.width * (0.78 + spread * 0.5);
    shapes[o + 3] = preset.wavenumber;
    cursor[band] = (cursor[band] + 1) % dioramaRippleSlotsPerBand;
    spawned++;
  }
}

/// 欠阻尼弹簧：一拍落下是回弹而不是硬切（folia `stepDioramaParticleElasticResponse`）。
class DioramaElastic {
  double value = 1;
  double velocity = 0;

  double step(double target, double delta) {
    double remaining = delta.clamp(0.0, 0.1);
    final double safe = target.clamp(0.9, dioramaParticleAudioScaleMax);
    while (remaining > 0) {
      final double s = math.min(1 / 240, remaining);
      final double acc = (safe - value) * 150 - velocity * 15;
      velocity += acc * s;
      value += velocity * s;
      remaining -= s;
    }
    value = value.clamp(0.9, dioramaParticleAudioScaleMax);
    return value;
  }
}

/// 一帧点云的驱动量（音频代用品由场景按歌词算好传进来）。
class DioramaParticleFrame {
  const DioramaParticleFrame({
    required this.time,
    required this.amplitude,
    required this.maxSwell,
    required this.offsetGain,
    required this.flow,
    required this.formation,
    required this.scatter,
    required this.pulse,
    required this.sizeBase,
    required this.sizeGain,
    required this.glowIntensity,
    required this.centroid,
  });

  final double time;
  final double amplitude;
  final double maxSwell;
  final double offsetGain;
  final double flow;
  final double formation;
  final double scatter;
  final double pulse;
  final double sizeBase;
  final double sizeGain;

  /// 点云整体辉光（0 = 关）。
  final double glowIntensity;
  final double centroid;
}

double _smoothstep(double e0, double e1, double v) {
  final double a = ((v - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return a * a * (3 - 2 * a);
}

double _hash11(double n) {
  final double x = math.sin(n) * 43758.5453123;
  return x - x.floorToDouble();
}

/// 调色板权重查表（folia 着色器里的 cos 三相权重），按相位（圈）取。
final List<Float32List> _paletteLut = () {
  const int n = 256;
  final Float32List a = Float32List(n), b = Float32List(n), c = Float32List(n);
  for (int i = 0; i < n; i++) {
    final double ph = i / n * math.pi * 2;
    double wx = math.max(0, 0.5 + 0.5 * math.cos(ph));
    double wy = math.max(0, 0.5 + 0.5 * math.cos(ph - 2.094));
    double wz = math.max(0, 0.5 + 0.5 * math.cos(ph - 4.188));
    wx *= wx;
    wy *= wy;
    wz *= wz;
    final double s = math.max(wx + wy + wz, 0.001);
    a[i] = wx / s;
    b[i] = wy / s;
    c[i] = wz / s;
  }
  return <Float32List>[a, b, c];
}();

/// 投影后的点批次（drawRawAtlas 的输入），缓冲按需扩容复用。
class DioramaPointBatch {
  Float32List transforms = Float32List(0);
  Float32List rects = Float32List(0);
  Int32List colors = Int32List(0);
  int count = 0;
  double _spriteSize = -1;

  void reset(int capacity, double spriteSize) {
    if (transforms.length < capacity * 4) {
      transforms = Float32List(capacity * 4);
      rects = Float32List(capacity * 4);
      colors = Int32List(capacity);
      _spriteSize = -1;
    }
    if (_spriteSize != spriteSize) {
      for (int i = 0; i < rects.length; i += 4) {
        rects[i] = 0;
        rects[i + 1] = 0;
        rects[i + 2] = spriteSize;
        rects[i + 3] = spriteSize;
      }
      _spriteSize = spriteSize;
    }
    count = 0;
  }

  /// 以 (x, y) 为中心、直径 [sizePx] 加一个点。
  void add(double x, double y, double sizePx, double spriteSize, int argb) {
    final double scale = sizePx / spriteSize;
    final int o = count * 4;
    transforms[o] = scale;
    transforms[o + 1] = 0;
    transforms[o + 2] = x - scale * spriteSize / 2;
    transforms[o + 3] = y - scale * spriteSize / 2;
    colors[count] = argb;
    count++;
  }

  void draw(ui.Canvas canvas, ui.Image sprite, ui.Paint paint) {
    if (count == 0) return;
    canvas.drawRawAtlas(
      sprite,
      count * 4 == transforms.length
          ? transforms
          : Float32List.sublistView(transforms, 0, count * 4),
      count * 4 == rects.length
          ? rects
          : Float32List.sublistView(rects, 0, count * 4),
      count == colors.length ? colors : Int32List.sublistView(colors, 0, count),
      ui.BlendMode.modulate,
      null,
      paint,
    );
  }
}

int _argb(double a, double r, double g, double b) {
  final int ai = (a.clamp(0.0, 1.0) * 255).round();
  final int ri = (r.clamp(0.0, 1.0) * 255).round();
  final int gi = (g.clamp(0.0, 1.0) * 255).round();
  final int bi = (b.clamp(0.0, 1.0) * 255).round();
  return (ai << 24) | (ri << 16) | (gi << 8) | bi;
}

/// 逐点：波纹 + 呼吸位移 → 投影 → 对比层 / 辉光层颜色（folia 顶点 + 片元着色器）。
void dioramaEvaluateParticles({
  required DioramaParticleGeometry geometry,
  required DioramaRipplePool pool,
  required DioramaParticleFrame f,
  required DioramaCamera camera,
  required List<ui.Color> palette,
  required DioramaPointBatch contrast,
  required DioramaPointBatch glow,
  required double spriteSize,
}) {
  final int n = geometry.count;
  contrast.reset(n, spriteSize);
  glow.reset(f.glowIntensity > 0 ? n : 0, spriteSize);
  if (n == 0) return;
  final Float32List d = geometry.data;
  final bool corridor = geometry.corridor;
  final double kMax = geometry.waveNumberMax;

  // 活着的波纹源：本帧常量预先算好。
  final List<double> live = <double>[];
  for (int i = 0; i < dioramaRippleCount; i++) {
    final double strength = pool.shapes[i * 4];
    final double age = f.time - pool.sources[i * 4 + 3];
    if (strength <= 0 || age < 0) continue;
    final double amp = strength * math.exp(-age * 1.15);
    if (amp < 0.002) continue;
    final double width = pool.shapes[i * 4 + 2];
    live
      ..add(pool.sources[i * 4])
      ..add(pool.sources[i * 4 + 1])
      ..add(pool.sources[i * 4 + 2])
      ..add(age * pool.shapes[i * 4 + 1])
      ..add(width * width)
      ..add(math.min(pool.shapes[i * 4 + 3], kMax))
      ..add(amp)
      ..add(width * 3);
  }
  final int liveCount = live.length ~/ 8;

  final ui.Color pc = palette[0], ac = palette[1], sc = palette[2];
  final double hotMix = _smoothstep(0.2, 0.9, f.centroid);
  final double hotR = ac.r + (sc.r - ac.r) * hotMix;
  final double hotG = ac.g + (sc.g - ac.g) * hotMix;
  final double hotB = ac.b + (sc.b - ac.b) * hotMix;
  final double formed = _smoothstep(0, 0.45, f.formation);
  final double scatter = 1 - f.formation;
  final double dynPhase = f.time * 0.02 + f.centroid * 0.3;
  final double t = f.time;
  final double glowScale = 1.9 + f.glowIntensity * 1.3;

  final DioramaVec cp = camera.position;
  final DioramaVec cr = camera.right, cu = camera.up, cb = camera.back;
  final double halfW = camera.width / 2,
      halfH = camera.height / 2,
      focal = camera.focal;

  double lastPhase = double.nan;
  double spin = 1, spun = 0;

  for (int i = 0; i < n; i++) {
    final int o = i * _stride;
    final double localRadius = d[o + 11];
    final double phase = d[o + 12];
    final double scale = d[o + 9];
    // 先按锚点粗剔：整个图元都在生命周期外就跳过逐点计算。
    final double ax = d[o + 6], ay = d[o + 7], az = d[o + 8];
    final double px = d[o], py = d[o + 1], pz = d[o + 2];
    final double nx = d[o + 3], ny = d[o + 4], nz = d[o + 5];
    final double bx = px, by = py * d[o + 10], bz = pz;
    double audio = 0;
    double idle;
    if (corridor) {
      final double w1 = d[o + 16], w2 = d[o + 17];
      for (int s = 0; s < liveCount; s++) {
        final int so = s * 8;
        final double da = w1 - live[so];
        double dAng = w2 - live[so + 1];
        dAng =
            dAng -
            (math.pi * 2) * ((dAng + math.pi) / (math.pi * 2)).floorToDouble();
        final double r = math.sqrt(da * da + dAng * dAng);
        final double dr = r - live[so + 3];
        if (dr.abs() > live[so + 7]) continue;
        audio +=
            live[so + 6] *
            math.exp(-(dr * dr) / live[so + 4]) *
            math.sin(dr * live[so + 5]) *
            math.exp(-r * 0.35);
      }
      final double ft = t * f.flow;
      final double region = 0.6 + 0.4 * math.sin(w1 * 0.42 - ft * 0.33);
      idle =
          region *
          (0.62 * math.sin(w1 * 1.25 - ft * 1.15) +
              0.30 * math.sin(w1 * 0.8 + w2 * 2.0 - ft * 0.8) +
              0.08 * math.sin(w2 * 3.0 + ft * 0.5));
    } else {
      final double ux = px / localRadius,
          uy = py / localRadius,
          uz = pz / localRadius;
      if (phase != lastPhase) {
        lastPhase = phase;
        spin = math.cos(phase);
        spun = math.sin(phase);
      }
      for (int s = 0; s < liveCount; s++) {
        final int so = s * 8;
        final double sx = live[so], sy = live[so + 1], sz = live[so + 2];
        final double ox = sx * spin - sz * spun;
        final double oz = sx * spun + sz * spin;
        final double ddx = ux - ox, ddy = uy - sy, ddz = uz - oz;
        final double r = math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz);
        final double dr = r - live[so + 3];
        if (dr.abs() > live[so + 7]) continue;
        audio +=
            live[so + 6] *
            math.exp(-(dr * dr) / live[so + 4]) *
            math.sin(dr * live[so + 5]) *
            math.exp(-r * 0.35);
      }
      idle =
          0.11 * math.sin(ux * 1.7 + t * 0.5) * math.cos(uz * 1.4 - t * 0.37) +
          0.06 * math.sin(uy * 2.1 - t * 0.66);
    }
    final double clampedAudio = audio.clamp(-1.6, 1.6);
    final double swell = (audio + idle).clamp(-1.6, 1.6) * f.amplitude;
    double dx = bx + nx * swell * localRadius;
    double dy = by + ny * swell * localRadius;
    double dz = bz + nz * swell * localRadius;
    final double reach =
        (clampedAudio * f.amplitude).abs() / math.max(f.maxSwell, 0.0001);
    final double dd = reach > 1 ? 1 : reach;
    dz += math.sin(t * 0.6 + phase) * 0.12 * f.offsetGain * localRadius;
    if (scatter > 0.001) {
      final double r1 = _hash11(phase * 12.9898 + d[o + 16] * 78.233);
      final double r2 = _hash11(phase * 39.346 + d[o + 17] * 11.135 + 3.7);
      final double r3 = _hash11(r1 * 91.7 + r2 * 47.3);
      double sx = nx * 0.75 + (r1 - 0.5) * 1.6;
      double sy = ny * 0.75 + (r2 - 0.5) * 1.6;
      double sz = nz * 0.75 + (r3 - 0.5) * 1.6;
      final double sl = math.sqrt(sx * sx + sy * sy + sz * sz);
      if (sl > 0) {
        final double k = scatter * scatter * f.scatter * (0.55 + r3 * 0.9) / sl;
        sx *= k;
        sy *= k;
        sz *= k;
        dx += sx;
        dy += sy;
        dz += sz;
      }
    }
    final double m = scale * f.pulse;
    final double wx = ax + dx * m, wy = ay + dy * m, wz = az + dz * m;
    final double rx = wx - cp.x, ry = wy - cp.y, rz = wz - cp.z;
    final double dist = math.sqrt(rx * rx + ry * ry + rz * rz);
    final double life = resolveDioramaShapeLife(dist);
    if (life <= 0.002) continue;
    final double depth = -(rx * cb.x + ry * cb.y + rz * cb.z);
    if (depth <= DioramaCamera.near) continue;
    final double xc = rx * cr.x + ry * cr.y + rz * cr.z;
    final double yc = rx * cu.x + ry * cu.y + rz * cu.z;
    final double sxp = halfW + xc / depth * focal;
    final double syp = halfH - yc / depth * focal;
    final double baseSize = f.sizeBase + dd * dd * dd * f.sizeGain;
    final double sizePx = baseSize * focal / depth;
    final double margin = math.max(sizePx * glowScale, 4);
    if (sxp < -margin ||
        syp < -margin ||
        sxp > camera.width + margin ||
        syp > camera.height + margin) {
      continue;
    }
    // 颜色：三色调色板漂移，被推动的点偏向热色。
    final double turns = d[o + 15] + dynPhase;
    final int li = ((turns - turns.floorToDouble()) * 256).floor() & 255;
    final double w0 = _paletteLut[0][li],
        w1c = _paletteLut[1][li],
        w2c = _paletteLut[2][li];
    double cR = pc.r * w0 + ac.r * w1c + sc.r * w2c;
    double cG = pc.g * w0 + ac.g * w1c + sc.g * w2c;
    double cB = pc.b * w0 + ac.b * w1c + sc.b * w2c;
    final double hot = math.min(1.0, _smoothstep(0.1, 0.75, dd) * 0.75);
    final double gain = 0.92 + dd * 0.5;
    cR = (cR + (hotR - cR) * hot) * gain;
    cG = (cG + (hotG - cG) * hot) * gain;
    cB = (cB + (hotB - cB) * hot) * gain;
    final double layerBase = d[o + 14] > 0.5 ? 0.5 : 0.72;
    final double alpha = formed * life * math.min(1.0, layerBase + dd * 0.28);
    final double emission = 0.95 + dd * 0.22;
    if (alpha > 0.01) {
      contrast.add(
        sxp,
        syp,
        sizePx.clamp(1.0, 22.0),
        spriteSize,
        _argb(alpha, cR * emission, cG * emission, cB * emission),
      );
    }
    if (f.glowIntensity > 0) {
      final double ga = math.min(
        0.5,
        formed *
            life *
            _smoothstep(0.1, 0.8, dd) *
            1.15 *
            f.glowIntensity *
            0.4,
      );
      if (ga > 0.003) {
        final double boost = 1 + f.glowIntensity * 0.25;
        glow.add(
          sxp,
          syp,
          (sizePx * glowScale).clamp(1.6, 54.0),
          spriteSize,
          _argb(ga, cR * boost, cG * boost, cB * boost),
        );
      }
    }
  }
}

// ─── 对比度 ────────────────────────────────────────────────────────────────

double _luminance(ui.Color c) {
  double lin(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

double dioramaContrastRatio(ui.Color a, ui.Color b) {
  final double la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// 点的颜色要在背景上看得见：不够 [minRatio] 时朝黑 / 白里离背景远的那头二分推（folia
/// `resolveDioramaParticleContrastColors` 的简化：只保证最低对比，不模拟着色器的发光与混合）。
ui.Color dioramaEnsureContrast(
  ui.Color color,
  ui.Color background, {
  double minRatio = 3.0,
}) {
  if (dioramaContrastRatio(color, background) >= minRatio) return color;
  final ui.Color pole = _luminance(background) > 0.4
      ? const ui.Color(0xFF000000)
      : const ui.Color(0xFFFFFFFF);
  double lo = 0, hi = 1;
  for (int i = 0; i < 10; i++) {
    final double mid = (lo + hi) / 2;
    if (dioramaContrastRatio(ui.Color.lerp(color, pole, mid)!, background) >=
        minRatio) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return ui.Color.lerp(color, pole, hi)!;
}
