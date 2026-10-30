import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show ValueListenable, immutable, listEquals, visibleForTesting;
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/music/music_cover.dart'
    show kMusicCoverRequestHeaders;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';

// 歌词页流体背景（参照 QPlayer / Apple Music-like Lyrics 的三种背景思路，实现是
// 本仓自写的 Canvas 版，不含上游代码）：
//
// - pixi：四层封面贴图——铺满对角线的大层居中慢转、0.8 倍层偏左上反转、0.5 倍
//   层沿对角线来回、0.25 倍小层居中——整组超大模糊后提饱和度与对比度；
// - meshGradient：封面缩到 32px 后先把颜色「拉开」（压对比 → 饱和度 ×3 → 加对比
//   → 压亮）再糊一遍，当贴图铺到一张随机扭曲的双三次 Hermite 曲面网格上
//   （drawVertices + ImageShader 贴图坐标），贴图坐标随时间绕偏心点慢转，于是
//   封面颜色被拉成一道道流动的色带；再叠一圈暗角；
// - classic：静态大模糊封面。
//
// 没有封面时 pixi / mesh 都退回主题色的 Catmull-Rom 顶点色网格。
//
// 性能纪律（歌词页每帧都在动，背景不能每帧整屏跑重活）：三种样式都只在一张
// 低分辨率离屏图（长边 ≤ [_kMaxRenderSide] 像素）里画，模糊也在这张小图上做，
// 最后整屏只贴一张图（ColorFilter 矩阵同时做饱和度与压暗 / 提亮，零额外 pass）。
// 动态模式按 ≈30fps 档位要帧（不用 Ticker，原因同 FushiMeshBackdrop 的
// `_ThrottledFrameDriver`）；静态模式 / classic / 减弱动态效果 / 墨水屏下只渲染
// 一次，之后每帧只是贴同一张缓存图。

/// 歌词页流体背景算法（偏好 `music_lyrics_backdrop_style`）。
enum MusicLyricsBackdropStyle {
  pixi('pixi'),
  meshGradient('mesh'),
  classic('classic');

  const MusicLyricsBackdropStyle(this.prefValue);

  /// 持久化值（冻结）。
  final String prefValue;

  /// 未知 / 缺省值回落到默认 [meshGradient]。
  static MusicLyricsBackdropStyle fromPref(String? value) {
    for (final MusicLyricsBackdropStyle s in values) {
      if (s.prefValue == value) return s;
    }
    return meshGradient;
  }
}

/// 背景饱和度下限 / 上限 / 默认（倍数；设置页按 % 显示）。
const double kMusicLyricsBackdropSaturationMin = 0.5;
const double kMusicLyricsBackdropSaturationMax = 2.0;
const double kMusicLyricsBackdropSaturationDefault = 1.0;

/// 深色主题下背景的亮度保留比例（其余压向黑）：歌词是浅色字，背景压暗保证可读。
const double kMusicBackdropDarkScrimKeep = 0.62;

/// 浅色主题下背景的颜色保留比例（其余提向白）：歌词是深色字，背景提亮保证可读。
const double kMusicBackdropLightScrimKeep = 0.55;

/// 离屏图长边上限（像素）。内容是重度模糊的低频图，放大后看不出差别。
const int _kMaxRenderSide = 240;

/// 离屏图长边下限（像素）。
const int _kMinRenderSide = 64;

/// pixi 四层先画进的极小图的长边像素（见 `_paintPixi`）。
const int _kPixiTinySide = 40;

/// pixi 着色器取样的封面贴图边长：越小越糊（B 样条放大后约等于一次超大模糊）。
const int _kPixiTextureSide = 16;

/// 重画间隔（≈30fps）。
const int _kFrameMicros = 33000;

/// 无封面回退网格流动一周的秒数。
const double _kFallbackMeshPeriodSeconds = 40;

/// 流动时钟（秒）绕回的上限：远超一次播放时长，绕回时的跳变看不出来。
const double _kClockWrapSeconds = 100000;

/// mesh 贴图坐标的旋转角速度（弧度 / 秒，约 31 秒一圈）。
const double _kMeshSpinPerSecond = 0.2;

/// mesh 贴图边长：封面缩到这么小再处理，曲面上看到的是被拉开的色带而不是细节。
const int kMusicMeshTextureSide = 32;

/// Hermite 曲面控制点网格边长（5×5）与每段细分数。
const int kMusicHermiteControlSide = 5;
const int kMusicHermiteSubdivisions = 10;

/// mesh 控制点网格边长（4×4）。
const int kMusicMeshGridSize = 4;

/// 每个网格单元细分段数（顶点网格 = (n-1)·s+1 见方）。
const int kMusicMeshSubdivisions = 8;

/// 封面采样边长：取色在这么大的缩略图上做。
const int _kPaletteSampleSide = kMusicMeshTextureSide;

// ---------------------------------------------------------------------------
// 纯函数：颜色矩阵 / 取色 / mesh 几何
// ---------------------------------------------------------------------------

/// 背景最终贴图用的 4×5 颜色矩阵：先按 Rec.709 亮度调饱和度，再按主题压暗
/// （深色）或提亮（浅色）。偏移列按 0–255 量纲（与 [ColorFilter.matrix] 一致）。
List<double> musicBackdropColorMatrix({
  required double saturation,
  required Brightness brightness,
  double? darkKeep,
}) {
  final double s = saturation.clamp(0.0, 3.0);
  const double lr = 0.2126;
  const double lg = 0.7152;
  const double lb = 0.0722;
  final double inv = 1 - s;
  final bool dark = brightness == Brightness.dark;
  final double k = dark
      ? (darkKeep ?? kMusicBackdropDarkScrimKeep)
      : kMusicBackdropLightScrimKeep;
  final double offset = dark ? 0 : 255 * (1 - k);
  return <double>[
    k * (lr * inv + s), k * (lg * inv), k * (lb * inv), 0, offset, //
    k * (lr * inv), k * (lg * inv + s), k * (lb * inv), 0, offset, //
    k * (lr * inv), k * (lg * inv), k * (lb * inv + s), 0, offset, //
    0, 0, 0, 1, 0,
  ];
}

/// 把 [musicBackdropColorMatrix] 作用到一个颜色上（与 GPU 端同一公式，测试用）。
Color applyMusicBackdropColorMatrix(List<double> m, Color c) {
  final double r = c.r * 255;
  final double g = c.g * 255;
  final double b = c.b * 255;
  final double a = c.a * 255;
  int ch(int row) {
    final int i = row * 5;
    final double v =
        m[i] * r + m[i + 1] * g + m[i + 2] * b + m[i + 3] * a + m[i + 4];
    return v.round().clamp(0, 255);
  }

  return Color.fromARGB(ch(3), ch(0), ch(1), ch(2));
}

/// 封面取色结果（ARGB int，跨 isolate 传递）。
@immutable
class MusicBackdropPalette {
  const MusicBackdropPalette({
    required this.dominant,
    required this.grid,
    required this.gridSize,
  });

  static const MusicBackdropPalette empty = MusicBackdropPalette(
    dominant: <int>[],
    grid: <int>[],
    gridSize: 0,
  );

  /// 主色（按「面积 × 鲜艳度」降序、彼此可区分），最多 maxColors 个。
  final List<int> dominant;

  /// gridSize × gridSize 的分区平均色（行优先）：mesh 控制点颜色。
  final List<int> grid;
  final int gridSize;

  bool get isEmpty => dominant.isEmpty;
}

/// 从 RGBA 像素（[width]×[height]，alpha < 128 的像素忽略）取主色与分区平均色。
///
/// 主色：RGB 各量化到 4 bit 建直方图，按「像素数 × (0.3 + 饱和度)」打分，贪心挑
/// 与已选色 RGB 距离 ≥ 40 的桶（不够再放宽到 16），桶内取像素均值。
MusicBackdropPalette extractMusicBackdropPalette(
  Uint8List rgba,
  int width,
  int height, {
  int maxColors = 4,
  int gridSize = kMusicMeshGridSize,
}) {
  if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
    return MusicBackdropPalette.empty;
  }
  final Int32List count = Int32List(4096);
  final Float64List sumR = Float64List(4096);
  final Float64List sumG = Float64List(4096);
  final Float64List sumB = Float64List(4096);
  final int cells = gridSize * gridSize;
  final Float64List cellR = Float64List(cells);
  final Float64List cellG = Float64List(cells);
  final Float64List cellB = Float64List(cells);
  final Int32List cellN = Int32List(cells);
  double totR = 0, totG = 0, totB = 0;
  int total = 0;
  for (int y = 0; y < height; y++) {
    final int gy = math.min(gridSize - 1, y * gridSize ~/ height);
    for (int x = 0; x < width; x++) {
      final int i = (y * width + x) * 4;
      if (rgba[i + 3] < 128) continue;
      final int r = rgba[i];
      final int g = rgba[i + 1];
      final int b = rgba[i + 2];
      final int bin = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
      count[bin]++;
      sumR[bin] += r;
      sumG[bin] += g;
      sumB[bin] += b;
      final int gx = math.min(gridSize - 1, x * gridSize ~/ width);
      final int cell = gy * gridSize + gx;
      cellR[cell] += r;
      cellG[cell] += g;
      cellB[cell] += b;
      cellN[cell]++;
      totR += r;
      totG += g;
      totB += b;
      total++;
    }
  }
  if (total == 0) return MusicBackdropPalette.empty;

  final List<({int r, int g, int b, double score})> bins =
      <({int r, int g, int b, double score})>[];
  for (int bin = 0; bin < 4096; bin++) {
    final int n = count[bin];
    if (n == 0) continue;
    final int r = (sumR[bin] / n).round();
    final int g = (sumG[bin] / n).round();
    final int b = (sumB[bin] / n).round();
    final int hi = math.max(r, math.max(g, b));
    final int lo = math.min(r, math.min(g, b));
    final double sat = hi == 0 ? 0 : (hi - lo) / hi;
    bins.add((r: r, g: g, b: b, score: n * (0.3 + sat)));
  }
  bins.sort((a, b) => b.score.compareTo(a.score));

  final List<({int r, int g, int b})> picked = <({int r, int g, int b})>[];
  for (final double minDistance in <double>[40, 16]) {
    for (final ({int r, int g, int b, double score}) c in bins) {
      if (picked.length >= maxColors) break;
      final bool distinct = picked.every((({int r, int g, int b}) p) {
        final int dr = p.r - c.r;
        final int dg = p.g - c.g;
        final int db = p.b - c.b;
        return math.sqrt(dr * dr + dg * dg + db * db) >= minDistance;
      });
      if (distinct) picked.add((r: c.r, g: c.g, b: c.b));
    }
  }

  int argb(int r, int g, int b) => 0xFF000000 | (r << 16) | (g << 8) | b;
  final int mean = argb(
    (totR / total).round(),
    (totG / total).round(),
    (totB / total).round(),
  );
  return MusicBackdropPalette(
    dominant: <int>[for (final p in picked) argb(p.r, p.g, p.b)],
    grid: <int>[
      for (int c = 0; c < cells; c++)
        cellN[c] == 0
            ? mean
            : argb(
                (cellR[c] / cellN[c]).round(),
                (cellG[c] / cellN[c]).round(),
                (cellB[c] / cellN[c]).round(),
              ),
    ],
    gridSize: gridSize,
  );
}

/// 没有封面时的 mesh 网格颜色：把 [colors] 按对角错开铺成 n×n（行优先 ARGB）。
List<int> musicMeshGridFromColors(List<Color> colors, int n) {
  if (colors.isEmpty) return List<int>.filled(n * n, 0xFF000000);
  return <int>[
    for (int r = 0; r < n; r++)
      for (int c = 0; c < n; c++)
        colors[(r * 2 + c * 3 + (r * c)) % colors.length].toARGB32(),
  ];
}

/// mesh 控制点（单位正方形坐标，行优先 n×n）在相位 [phase]（0–1）的位置：
/// 四角固定；边上的点只沿边滑动（网格始终铺满画布）；内部点二维扰动。扰动
/// 幅度 ≤ 0.35 格，相邻点不会交叉；频率取整数，一周后无缝回到原位。
List<Offset> musicMeshControlPoints(int n, double phase) {
  final double step = 1 / (n - 1);
  final double t = phase * 2 * math.pi;
  return <Offset>[
    for (int r = 0; r < n; r++)
      for (int c = 0; c < n; c++) _controlPoint(n, r, c, step, t),
  ];
}

Offset _controlPoint(int n, int r, int c, double step, double t) {
  final double bx = c * step;
  final double by = r * step;
  final bool edgeRow = r == 0 || r == n - 1;
  final bool edgeCol = c == 0 || c == n - 1;
  final int f = 1 + (r + c) % 2;
  final double seed = r * 1.7 + c * 2.3;
  if (edgeRow && edgeCol) return Offset(bx, by);
  if (edgeRow) return Offset(bx + 0.28 * step * math.sin(f * t + seed), by);
  if (edgeCol) return Offset(bx, by + 0.28 * step * math.sin(f * t + seed));
  final int f2 = 1 + (r * 3 + c) % 2;
  return Offset(
    bx + 0.35 * step * math.sin(f * t + seed),
    by + 0.35 * step * math.cos(f2 * t + seed * 1.3),
  );
}

/// mesh 控制点颜色随相位缓慢与对角邻格混色（最多混 30%），画面不只是形变。
List<int> musicMeshAnimatedColors(List<int> grid, int n, double phase) {
  final double t = phase * 2 * math.pi;
  return <int>[
    for (int r = 0; r < n; r++)
      for (int c = 0; c < n; c++)
        _lerpArgb(
          grid[r * n + c],
          grid[((r + 1) % n) * n + (c + 2) % n],
          0.15 * (1 + math.sin(t + r * 1.1 + c * 0.7)),
        ),
  ];
}

int _lerpArgb(int a, int b, double t) {
  int ch(int shift) {
    final int x = (a >> shift) & 0xFF;
    final int y = (b >> shift) & 0xFF;
    return (x + (y - x) * t).round().clamp(0, 255);
  }

  return 0xFF000000 | (ch(16) << 16) | (ch(8) << 8) | ch(0);
}

/// mesh 顶点网格（单位坐标）：三角形顶点 / 逐顶点颜色 / 索引。
@immutable
class MusicMeshSurface {
  const MusicMeshSurface({
    required this.side,
    required this.positions,
    required this.colors,
    required this.indices,
  });

  /// 顶点网格边长（side × side 个顶点）。
  final int side;

  /// x0,y0,x1,y1,…（单位坐标）。
  final Float32List positions;

  /// 逐顶点 ARGB。
  final Int32List colors;
  final Uint16List indices;
}

/// 把 n×n 控制点（位置 [points] + 颜色 [colors]，行优先）按 Catmull-Rom 双三次
/// 插值细分成 ((n-1)·[subdivisions]+1)² 个顶点（端点钳制，曲面经过每个控制点）。
MusicMeshSurface buildMusicMeshSurface({
  required List<Offset> points,
  required List<int> colors,
  required int n,
  int subdivisions = kMusicMeshSubdivisions,
}) {
  assert(points.length == n * n && colors.length == n * n);
  final int side = (n - 1) * subdivisions + 1;
  final Float32List pos = Float32List(side * side * 2);
  final Int32List col = Int32List(side * side);
  final Float64List px = Float64List(n * n);
  final Float64List py = Float64List(n * n);
  final Float64List cr = Float64List(n * n);
  final Float64List cg = Float64List(n * n);
  final Float64List cb = Float64List(n * n);
  for (int i = 0; i < n * n; i++) {
    px[i] = points[i].dx;
    py[i] = points[i].dy;
    cr[i] = ((colors[i] >> 16) & 0xFF).toDouble();
    cg[i] = ((colors[i] >> 8) & 0xFF).toDouble();
    cb[i] = (colors[i] & 0xFF).toDouble();
  }
  int clampIdx(int i) => i < 0 ? 0 : (i > n - 1 ? n - 1 : i);
  double surface(Float64List f, int cx, double tx, int cy, double ty) {
    final Float64List rows = Float64List(4);
    for (int j = 0; j < 4; j++) {
      final int row = clampIdx(cy - 1 + j) * n;
      rows[j] = _catmullRom(
        f[row + clampIdx(cx - 1)],
        f[row + cx],
        f[row + clampIdx(cx + 1)],
        f[row + clampIdx(cx + 2)],
        tx,
      );
    }
    return _catmullRom(rows[0], rows[1], rows[2], rows[3], ty);
  }

  for (int gy = 0; gy < side; gy++) {
    final double v = gy / subdivisions;
    final int cy = math.min(v.floor(), n - 2);
    final double ty = v - cy;
    for (int gx = 0; gx < side; gx++) {
      final double u = gx / subdivisions;
      final int cx = math.min(u.floor(), n - 2);
      final double tx = u - cx;
      final int k = gy * side + gx;
      pos[k * 2] = surface(px, cx, tx, cy, ty);
      pos[k * 2 + 1] = surface(py, cx, tx, cy, ty);
      final int r = surface(cr, cx, tx, cy, ty).round().clamp(0, 255);
      final int g = surface(cg, cx, tx, cy, ty).round().clamp(0, 255);
      final int b = surface(cb, cx, tx, cy, ty).round().clamp(0, 255);
      col[k] = (0xFF000000 | (r << 16) | (g << 8) | b).toSigned(32);
    }
  }
  final Uint16List idx = Uint16List((side - 1) * (side - 1) * 6);
  int w = 0;
  for (int y = 0; y < side - 1; y++) {
    for (int x = 0; x < side - 1; x++) {
      final int a = y * side + x;
      final int b = a + 1;
      final int c = a + side;
      final int d = c + 1;
      idx[w++] = a;
      idx[w++] = b;
      idx[w++] = c;
      idx[w++] = b;
      idx[w++] = d;
      idx[w++] = c;
    }
  }
  return MusicMeshSurface(
    side: side,
    positions: pos,
    colors: col,
    indices: idx,
  );
}

double _catmullRom(double p0, double p1, double p2, double p3, double t) {
  final double t2 = t * t;
  final double t3 = t2 * t;
  return 0.5 *
      (2 * p1 +
          (-p0 + p2) * t +
          (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
          (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
}

/// mesh 贴图预处理（就地改 [rgba]，[side]×[side]）：先压对比（0.4）把颜色往
/// 中灰收，再把饱和度拉到 3 倍、对比加到 1.7、整体压到 0.75，最后 4 遍半径 2
/// 的盒式模糊。效果是封面里的几种主色被「拉开」成鲜明的大色块，铺到扭曲网格上
/// 才有成片的色带而不是脏灰。
Uint8List musicMeshTextureFromCover(Uint8List rgba, int side) {
  final int n = side * side;
  assert(rgba.length >= n * 4);
  for (int i = 0; i < n * 4; i += 4) {
    double r = (rgba[i] - 128) * 0.4 + 128;
    double g = (rgba[i + 1] - 128) * 0.4 + 128;
    double b = (rgba[i + 2] - 128) * 0.4 + 128;
    final double gray = r * 0.3 + g * 0.59 + b * 0.11;
    r = gray * -2 + r * 3;
    g = gray * -2 + g * 3;
    b = gray * -2 + b * 3;
    r = ((r - 128) * 1.7 + 128) * 0.75;
    g = ((g - 128) * 1.7 + 128) * 0.75;
    b = ((b - 128) * 1.7 + 128) * 0.75;
    rgba[i] = r.round().clamp(0, 255);
    rgba[i + 1] = g.round().clamp(0, 255);
    rgba[i + 2] = b.round().clamp(0, 255);
    rgba[i + 3] = 255;
  }
  final Uint8List tmp = Uint8List(n * 4);
  const int radius = 2;
  // 横、竖各一遍算一轮，共 4 轮；边缘按钳制取样。
  void pass(Uint8List src, Uint8List dst, bool horizontal) {
    for (int y = 0; y < side; y++) {
      for (int x = 0; x < side; x++) {
        int sr = 0, sg = 0, sb = 0;
        for (int k = -radius; k <= radius; k++) {
          final int xx = horizontal ? (x + k).clamp(0, side - 1) : x;
          final int yy = horizontal ? y : (y + k).clamp(0, side - 1);
          final int j = (yy * side + xx) * 4;
          sr += src[j];
          sg += src[j + 1];
          sb += src[j + 2];
        }
        final int o = (y * side + x) * 4;
        dst[o] = sr ~/ (radius * 2 + 1);
        dst[o + 1] = sg ~/ (radius * 2 + 1);
        dst[o + 2] = sb ~/ (radius * 2 + 1);
        dst[o + 3] = 255;
      }
    }
  }

  for (int q = 0; q < 4; q++) {
    pass(rgba, tmp, true);
    pass(tmp, rgba, false);
  }
  return rgba;
}

/// mesh 的扭曲曲面：顶点位置（`[-1, 1]²`，y 朝上）、贴图坐标（`[0, 1]²`）与
/// 三角形索引。位置与贴图坐标都不随时间变；每帧只把贴图坐标绕偏心点转一下。
@immutable
class MusicHermiteMesh {
  const MusicHermiteMesh({
    required this.side,
    required this.positions,
    required this.uvs,
    required this.indices,
  });

  /// 顶点网格边长（side × side 个顶点）。
  final int side;
  final Float32List positions;
  final Float32List uvs;
  final Uint16List indices;
}

/// 生成一张随机扭曲的双三次 Hermite 曲面（[seed] 决定形状，同一首歌稳定）。
///
/// [controlSide]×[controlSide] 个控制点：边框上的点钉在画布边缘、切线不转，
/// 保证曲面铺满；内部点在格内抖动 ±0.45 格，u / v 切线各自旋转 ±60°、长度
/// 0.6–1.3 倍——切线一扭，贴图就沿曲面被拧成弧形色带。每片按 [subdivisions]
/// 细分，相邻片共用边上的顶点。
MusicHermiteMesh buildMusicHermiteMesh({
  required int seed,
  int controlSide = kMusicHermiteControlSide,
  int subdivisions = kMusicHermiteSubdivisions,
}) {
  final math.Random rnd = math.Random(seed);
  double range(double lo, double hi) => lo + (hi - lo) * rnd.nextDouble();
  final int c = controlSide;
  final double cell = 2 / (c - 1);
  final Float64List lx = Float64List(c * c);
  final Float64List ly = Float64List(c * c);
  final Float64List ux = Float64List(c * c);
  final Float64List uy = Float64List(c * c);
  final Float64List vx = Float64List(c * c);
  final Float64List vy = Float64List(c * c);
  for (int j = 0; j < c; j++) {
    for (int i = 0; i < c; i++) {
      final int k = j * c + i;
      final bool border = i == 0 || j == 0 || i == c - 1 || j == c - 1;
      lx[k] = i * cell - 1 + (border ? 0 : range(-0.45, 0.45) * cell);
      ly[k] = j * cell - 1 + (border ? 0 : range(-0.45, 0.45) * cell);
      final double ur = border ? 0 : range(-60, 60) * math.pi / 180;
      final double vr = border ? 0 : range(-60, 60) * math.pi / 180;
      final double us = cell * (border ? 1 : range(0.6, 1.3));
      final double vs = cell * (border ? 1 : range(0.6, 1.3));
      ux[k] = math.cos(ur) * us;
      uy[k] = math.sin(ur) * us;
      vx[k] = -math.sin(vr) * vs;
      vy[k] = math.cos(vr) * vs;
    }
  }
  // Hermite 基函数：位置两项 + 切线两项。
  double h0(double t) => 2 * t * t * t - 3 * t * t + 1;
  double h1(double t) => -2 * t * t * t + 3 * t * t;
  double g0(double t) => t * t * t - 2 * t * t + t;
  double g1(double t) => t * t * t - t * t;

  final int side = (c - 1) * subdivisions + 1;
  final Float32List pos = Float32List(side * side * 2);
  final Float32List uv = Float32List(side * side * 2);
  for (int gy = 0; gy < side; gy++) {
    final int pj = math.min(gy ~/ subdivisions, c - 2);
    final double t = gy / subdivisions - pj;
    for (int gx = 0; gx < side; gx++) {
      final int pi = math.min(gx ~/ subdivisions, c - 2);
      final double s = gx / subdivisions - pi;
      final int a = pj * c + pi; // (i, j)
      final int b = a + 1; // (i+1, j)
      final int d = a + c; // (i, j+1)
      final int e = d + 1; // (i+1, j+1)
      final double w00 = h0(s) * h0(t);
      final double w10 = h1(s) * h0(t);
      final double w01 = h0(s) * h1(t);
      final double w11 = h1(s) * h1(t);
      final double su00 = g0(s) * h0(t);
      final double su10 = g1(s) * h0(t);
      final double su01 = g0(s) * h1(t);
      final double su11 = g1(s) * h1(t);
      final double sv00 = h0(s) * g0(t);
      final double sv10 = h1(s) * g0(t);
      final double sv01 = h0(s) * g1(t);
      final double sv11 = h1(s) * g1(t);
      double eval(Float64List l, Float64List u, Float64List v) =>
          w00 * l[a] +
          w10 * l[b] +
          w01 * l[d] +
          w11 * l[e] +
          su00 * u[a] +
          su10 * u[b] +
          su01 * u[d] +
          su11 * u[e] +
          sv00 * v[a] +
          sv10 * v[b] +
          sv01 * v[d] +
          sv11 * v[e];
      final int o = (gy * side + gx) * 2;
      pos[o] = eval(lx, ux, vx);
      pos[o + 1] = eval(ly, uy, vy);
      uv[o] = gx / (side - 1);
      uv[o + 1] = 1 - gy / (side - 1);
    }
  }
  final Uint16List idx = Uint16List((side - 1) * (side - 1) * 6);
  int w = 0;
  for (int y = 0; y < side - 1; y++) {
    for (int x = 0; x < side - 1; x++) {
      final int q = y * side + x;
      idx[w++] = q;
      idx[w++] = q + 1;
      idx[w++] = q + side;
      idx[w++] = q + 1;
      idx[w++] = q + side + 1;
      idx[w++] = q + side;
    }
  }
  return MusicHermiteMesh(side: side, positions: pos, uvs: uv, indices: idx);
}

/// 离屏图尺寸：长边落在 [_kMinRenderSide, _kMaxRenderSide]（约逻辑尺寸的 1/6），
/// 保持画布宽高比。
Size musicBackdropRenderSize(Size logical) {
  if (logical.isEmpty || !logical.isFinite) return Size.zero;
  final double longest = logical.longestSide;
  final double target = (longest / 6).clamp(
    _kMinRenderSide.toDouble(),
    _kMaxRenderSide.toDouble(),
  );
  final double scale = target / longest;
  return Size(
    math.max(1, (logical.width * scale).ceil()).toDouble(),
    math.max(1, (logical.height * scale).ceil()).toDouble(),
  );
}

/// 封面地址 → ImageProvider：`http(s)://` 走全应用代理装配的 [AppHttpImage]，
/// 本地文件存在才用 [FileImage]，其余 null（背景改用主题色 mesh）。
ImageProvider? musicLyricsBackdropCoverProvider(String? coverPath) {
  if (coverPath == null || coverPath.isEmpty) return null;
  if (coverPath.startsWith('http://') || coverPath.startsWith('https://')) {
    return AppHttpImage(coverPath, headers: kMusicCoverRequestHeaders);
  }
  final File file = File(coverPath);
  return file.existsSync() ? FileImage(file) : null;
}

// ---------------------------------------------------------------------------
// 组件
// ---------------------------------------------------------------------------

/// 歌词页流体背景：按 [style] 渲染封面派生的流动背景，叠主题相关的压暗 / 提亮
/// 保证歌词可读；换歌时新旧背景交叉淡化。[animate] = false（静态）只渲染一次。
class MusicLyricsBackdrop extends StatefulWidget {
  const MusicLyricsBackdrop({
    super.key,
    required this.coverPath,
    this.style = MusicLyricsBackdropStyle.meshGradient,
    this.animate = true,
    this.saturation = kMusicLyricsBackdropSaturationDefault,
  });

  /// 封面：本地文件路径或 `http(s)://` 地址；null = 用主题色。
  final String? coverPath;
  final MusicLyricsBackdropStyle style;

  /// false = 静态（只渲染一次）。
  final bool animate;

  /// 饱和度倍数（[kMusicLyricsBackdropSaturationMin]–[kMusicLyricsBackdropSaturationMax]）。
  final double saturation;

  /// 测试钩子：每渲染一张离屏图回调一次（参数为样式）。
  @visibleForTesting
  static ValueChanged<MusicLyricsBackdropStyle>? debugOnFrameRendered;

  @override
  State<MusicLyricsBackdrop> createState() => _MusicLyricsBackdropState();
}

/// 一首歌的背景素材：缩略封面 + 取色。引用计数——交叉淡化期间新旧两个场景、
/// 以及持有「当前素材」的外层 State 各持一份引用，最后一个释放时回收图片。
class _BackdropSource {
  _BackdropSource({
    required this.id,
    this.image,
    this.meshTexture,
    required this.palette,
  });

  final int id;
  ui.Image? image;

  /// mesh 样式的 32px 预处理贴图（[musicMeshTextureFromCover]）。
  ui.Image? meshTexture;
  final MusicBackdropPalette palette;

  /// 这首歌的扭曲曲面（按 [id] 定形，换歌才换）。
  late final MusicHermiteMesh mesh = buildMusicHermiteMesh(seed: id);

  ui.Image? _pixiTexture;

  /// pixi 着色器取样的极小封面（边长 [_kPixiTextureSide]，首次用到时生成）。
  ui.Image? get pixiTexture {
    final ui.Image? cover = image;
    if (cover == null) return null;
    return _pixiTexture ??= _shrinkCover(cover, _kPixiTextureSide);
  }

  int _refs = 1;

  void retain() => _refs++;

  void release() {
    if (--_refs > 0) return;
    image?.dispose();
    image = null;
    meshTexture?.dispose();
    meshTexture = null;
    _pixiTexture?.dispose();
    _pixiTexture = null;
  }
}

/// 封面整张缩进 side×side（带 mipmap 的缩小 = 区域平均）。
ui.Image _shrinkCover(ui.Image cover, int side) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    cover,
    Rect.fromLTWH(0, 0, cover.width.toDouble(), cover.height.toDouble()),
    Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image out = picture.toImageSync(side, side);
  picture.dispose();
  return out;
}

Future<ui.FragmentProgram?>? _pixiProgramLoad;

/// pixi 着色器（`shaders/music_backdrop_pixi.frag`）。加载失败（如 widget 测试
/// 没打包着色器）记日志并返回 null，pixi 退回离屏图画法。
Future<ui.FragmentProgram?> _pixiProgram() => _pixiProgramLoad ??=
    ui.FragmentProgram.fromAsset(
      'shaders/music_backdrop_pixi.frag',
    ).then<ui.FragmentProgram?>(
      (ui.FragmentProgram p) => p,
      onError: (Object e) {
        debugPrint('[music-backdrop] pixi shader unavailable: $e');
        return null;
      },
    );

class _MusicLyricsBackdropState extends State<MusicLyricsBackdrop> {
  _BackdropSource? _source;
  int _loadToken = 0;
  bool _loadedOnce = false;
  ImageStream? _pendingStream;
  ImageStreamListener? _pendingListener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loadedOnce) {
      _loadedOnce = true;
      _load(widget.coverPath, rebuild: false);
    }
  }

  @override
  void didUpdateWidget(covariant MusicLyricsBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverPath != widget.coverPath) {
      _load(widget.coverPath, rebuild: true);
    }
  }

  @override
  void dispose() {
    _cancelPending();
    _source?.release();
    _source = null;
    super.dispose();
  }

  void _cancelPending() {
    final ImageStreamListener? listener = _pendingListener;
    if (listener != null) _pendingStream?.removeListener(listener);
    _pendingStream = null;
    _pendingListener = null;
  }

  void _replaceSource(_BackdropSource next, {required bool rebuild}) {
    void swap() {
      _source?.release();
      _source = next;
    }

    rebuild ? setState(swap) : swap();
  }

  void _load(String? coverPath, {required bool rebuild}) {
    _cancelPending();
    final int token = ++_loadToken;
    final ImageProvider? provider = musicLyricsBackdropCoverProvider(coverPath);
    if (provider == null) {
      _replaceSource(
        _BackdropSource(id: token, palette: MusicBackdropPalette.empty),
        rebuild: rebuild,
      );
      return;
    }
    // 只要一张 160px 宽的缩略图：糊到看不出细节，省解码、内存与贴图带宽。
    final ImageStream stream = ResizeImage.resizeIfNeeded(
      160,
      null,
      provider,
    ).resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool synchronousCall) {
        stream.removeListener(listener);
        if (identical(_pendingListener, listener)) {
          _pendingStream = null;
          _pendingListener = null;
        }
        final ui.Image image = info.image.clone();
        info.dispose();
        unawaited(_finishLoad(token, image));
      },
      onError: (Object error, StackTrace? stackTrace) {
        stream.removeListener(listener);
        if (!mounted || token != _loadToken) return;
        _pendingStream = null;
        _pendingListener = null;
        // 封面解码失败：退回主题色 mesh（与封面缺失同一路径）。
        _replaceSource(
          _BackdropSource(id: token, palette: MusicBackdropPalette.empty),
          rebuild: true,
        );
      },
    );
    _pendingStream = stream;
    _pendingListener = listener;
    stream.addListener(listener);
  }

  Future<void> _finishLoad(int token, ui.Image image) async {
    final (MusicBackdropPalette palette, ui.Image? texture) = await _analyse(
      image,
    );
    if (!mounted || token != _loadToken) {
      image.dispose();
      texture?.dispose();
      return;
    }
    _replaceSource(
      _BackdropSource(
        id: token,
        image: image,
        meshTexture: texture,
        palette: palette,
      ),
      rebuild: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final _BackdropSource? source = _source;
    final bool dark = cs.brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 交叉淡化中途两层都半透明，垫一层底色不透出页面后面的东西。
        ColoredBox(color: dark ? Colors.black : cs.surface),
        if (source != null)
          AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.long),
            switchInCurve: FushiMotion.standard,
            switchOutCurve: FushiMotion.standard,
            layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
              fit: StackFit.expand,
              children: <Widget>[...previous, if (current != null) current],
            ),
            child: _BackdropScene(
              key: ValueKey<String>('${source.id}-${widget.style.name}'),
              source: source,
              style: widget.style,
              animate: widget.animate,
              saturation: widget.saturation,
            ),
          ),
      ],
    );
  }
}

/// 缩略封面 → 32px 采样 → 后台 isolate 取色 + 做 mesh 贴图。
Future<(MusicBackdropPalette, ui.Image?)> _analyse(ui.Image image) async {
  const int side = _kPaletteSampleSide;
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    const Rect.fromLTWH(0, 0, side * 1.0, side * 1.0),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image sample = picture.toImageSync(side, side);
  picture.dispose();
  final ByteData? bytes = await sample.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  sample.dispose();
  if (bytes == null) return (MusicBackdropPalette.empty, null);
  final Uint8List rgba = Uint8List.fromList(
    bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
  );
  final (MusicBackdropPalette palette, Uint8List texel) = await Isolate.run(
    () => (
      extractMusicBackdropPalette(rgba, side, side),
      musicMeshTextureFromCover(Uint8List.fromList(rgba), side),
    ),
  );
  final Completer<ui.Image> done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    texel,
    side,
    side,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return (palette, await done.future);
}

class _BackdropScene extends StatefulWidget {
  const _BackdropScene({
    super.key,
    required this.source,
    required this.style,
    required this.animate,
    required this.saturation,
  });

  final _BackdropSource source;
  final MusicLyricsBackdropStyle style;
  final bool animate;
  final double saturation;

  @override
  State<_BackdropScene> createState() => _BackdropSceneState();
}

class _BackdropSceneState extends State<_BackdropScene> {
  late final _BackdropFrameDriver _driver = _BackdropFrameDriver(
    onFrame: _onFrame,
  );
  final ValueNotifier<double> _phase = ValueNotifier<double>(0);
  final _LowResCache _cache = _LowResCache();
  int? _lastFrameMicros;
  ui.FragmentShader? _pixiShader;

  @override
  void initState() {
    super.initState();
    widget.source.retain();
    _pixiProgram().then((ui.FragmentProgram? program) {
      if (program == null || !mounted) return;
      setState(() => _pixiShader = program.fragmentShader());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncDriver();
  }

  @override
  void didUpdateWidget(covariant _BackdropScene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      widget.source.retain();
      oldWidget.source.release();
      _cache.invalidate();
    }
    _syncDriver();
  }

  @override
  void dispose() {
    _driver.stop();
    _phase.dispose();
    _cache.dispose();
    _pixiShader?.dispose();
    widget.source.release();
    super.dispose();
  }

  /// 只有动态样式（pixi / mesh）+ 动态模式 + 动效开 + 未被别的路由盖住才要帧。
  void _syncDriver() {
    final bool motion =
        widget.animate &&
        widget.style != MusicLyricsBackdropStyle.classic &&
        fushiExpressiveMotionEnabled(context) &&
        TickerMode.valuesOf(context).enabled;
    if (motion && !_driver.isActive) {
      _lastFrameMicros = null;
      _driver.start();
    } else if (!motion && _driver.isActive) {
      // 停在当前相位（静态 = 定格，不跳回起点）。
      _driver.stop();
    }
  }

  void _onFrame(int frameMicros) {
    final int? last = _lastFrameMicros;
    _lastFrameMicros = frameMicros;
    if (last == null) return;
    // 累加真实流逝时间（秒；单帧封顶 100ms：后台恢复后不跳一大截）。
    final int dt = (frameMicros - last).clamp(0, 100000);
    _phase.value = (_phase.value + dt / 1e6) % _kClockWrapSeconds;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final MusicBackdropPalette palette = widget.source.palette;
    final List<int> grid = palette.isEmpty
        ? musicMeshGridFromColors(<Color>[
            cs.primaryContainer,
            cs.tertiaryContainer,
            cs.secondaryContainer,
            cs.surfaceContainer,
          ], kMusicMeshGridSize)
        : palette.grid;
    final Color base = palette.isEmpty
        ? cs.surface
        : Color(palette.dominant.first);
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        isComplex: true,
        painter: _BackdropPainter(
          phase: _phase,
          cache: _cache,
          style: widget.style,
          image: widget.source.image,
          meshTexture: widget.source.meshTexture,
          pixiShader: widget.style == MusicLyricsBackdropStyle.pixi
              ? _pixiShader
              : null,
          pixiTexture: widget.style == MusicLyricsBackdropStyle.pixi
              ? widget.source.pixiTexture
              : null,
          mesh: widget.source.mesh,
          grid: grid,
          base: base,
          matrix: musicBackdropColorMatrix(
            saturation: widget.saturation,
            brightness: cs.brightness,
            // 封面 mesh 的贴图已压过亮度、还有暗角，再按默认比例压会发闷。
            darkKeep:
                widget.style == MusicLyricsBackdropStyle.meshGradient &&
                    widget.source.meshTexture != null
                ? 0.85
                : null,
          ),
        ),
      ),
    );
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.phase,
    required this.cache,
    required this.style,
    required this.image,
    required this.meshTexture,
    required this.pixiShader,
    required this.pixiTexture,
    required this.mesh,
    required this.grid,
    required this.base,
    required this.matrix,
  }) : super(repaint: phase);

  /// pixi 的全分辨率着色器与它取样的极小封面；任一为 null 时走离屏图画法。
  final ui.FragmentShader? pixiShader;
  final ui.Image? pixiTexture;

  /// 流动时钟（秒）。
  final ValueListenable<double> phase;
  final _LowResCache cache;
  final MusicLyricsBackdropStyle style;
  final ui.Image? image;
  final ui.Image? meshTexture;
  final MusicHermiteMesh mesh;
  final List<int> grid;
  final Color base;
  final List<double> matrix;

  @override
  void paint(Canvas canvas, Size size) {
    final ui.FragmentShader? shader = pixiShader;
    final ui.Image? texture = pixiTexture;
    if (shader != null && texture != null && !size.isEmpty) {
      shader
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, phase.value)
        ..setFloat(3, texture.width.toDouble())
        ..setFloat(4, texture.height.toDouble())
        ..setImageSampler(0, texture, filterQuality: FilterQuality.low);
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = shader
          ..colorFilter = ColorFilter.matrix(matrix),
      );
      MusicLyricsBackdrop.debugOnFrameRendered?.call(style);
      return;
    }
    final Size low = musicBackdropRenderSize(size);
    if (low.isEmpty) return;
    final double p = phase.value;
    final ui.Image frame = cache.resolve(low, p, (Canvas c, Size s) {
      _paintScene(c, s, p);
      MusicLyricsBackdrop.debugOnFrameRendered?.call(style);
    });
    canvas.drawImageRect(
      frame,
      Rect.fromLTWH(0, 0, frame.width.toDouble(), frame.height.toDouble()),
      Offset.zero & size,
      Paint()
        ..filterQuality = FilterQuality.high
        ..colorFilter = ColorFilter.matrix(matrix),
    );
  }

  void _paintScene(Canvas canvas, Size size, double p) {
    final Rect bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = base);
    final ui.Image? cover = image;
    // 没有封面时 pixi / classic 也退回 mesh（主题色网格）。
    final MusicLyricsBackdropStyle effective = cover == null
        ? MusicLyricsBackdropStyle.meshGradient
        : style;
    switch (effective) {
      case MusicLyricsBackdropStyle.pixi:
        _paintPixi(canvas, size, cover!, p);
      case MusicLyricsBackdropStyle.meshGradient:
        final ui.Image? texture = meshTexture;
        texture == null
            ? _paintMesh(canvas, size, p)
            : _paintCoverMesh(canvas, size, texture, p);
      case MusicLyricsBackdropStyle.classic:
        _paintClassic(canvas, size, cover!);
    }
  }

  // 四层封面：① 边长取长边 ×√2、居中慢转（任意角度都铺满）；② 0.8 倍、在
  // (w/2.5, h/2.5) 反向转得快一倍；③ 0.5 倍、沿对角线来回（≈140 s 一个来回）；
  // ④ 0.25 倍、居中略偏反转。整组一次超大模糊 + 提饱和度 / 对比度。
  void _paintPixi(Canvas canvas, Size size, ui.Image cover, double sec) {
    final Rect bounds = Offset.zero & size;
    final double w = size.width;
    final double h = size.height;
    final double maxSide = size.longestSide;
    final Rect src = Rect.fromLTWH(
      0,
      0,
      cover.width.toDouble(),
      cover.height.toDouble(),
    );
    final double orbit = math.cos(sec * 0.045);
    final List<({Offset c, double side, double rot})> layers =
        <({Offset c, double side, double rot})>[
          (
            c: Offset(w / 2, h / 2),
            side: maxSide * math.sqrt2,
            rot: 0.06 * sec,
          ),
          (c: Offset(w / 2.5, h / 2.5), side: maxSide * 0.8, rot: -0.12 * sec),
          (
            c: Offset(w / 2 + w / 4 * orbit, h / 2 + w / 4 * orbit),
            side: maxSide * 0.5,
            rot: 0.06 * sec,
          ),
          (
            c: Offset(w / 2 + w / 40, h / 2 + w / 40),
            side: maxSide * 0.25,
            rot: -0.08 * sec,
          ),
        ];
    // 先把四层画进一张极小的图（长边 [_kPixiTinySide] 像素）：封面在这里被双线性
    // 缩到只剩大色块，本身就是一次超大模糊。再用三次插值放大回离屏图并补一次小
    // 模糊。不在离屏图上直接做超大 sigma 的模糊——Impeller 会先降采样再双线性放
    // 大，两次放大叠起来就是看得见的方格。
    final double tinyScale = _kPixiTinySide / maxSide;
    final int tw = math.max(1, (w * tinyScale).ceil());
    final int th = math.max(1, (h * tinyScale).ceil());
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas tiny = Canvas(recorder)..scale(tinyScale);
    for (final ({Offset c, double side, double rot}) l in layers) {
      tiny
        ..save()
        ..translate(l.c.dx, l.c.dy)
        ..rotate(l.rot);
      tiny.drawImageRect(
        cover,
        src,
        Rect.fromCenter(center: Offset.zero, width: l.side, height: l.side),
        Paint()..filterQuality = FilterQuality.medium,
      );
      tiny.restore();
    }
    final ui.Picture picture = recorder.endRecording();
    final ui.Image small = picture.toImageSync(tw, th);
    picture.dispose();
    final double sigma = maxSide * 0.025;
    canvas.saveLayer(
      bounds,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.mirror,
        )
        ..colorFilter = const ColorFilter.matrix(_pixiGrade),
    );
    canvas.drawImageRect(
      small,
      Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
      bounds,
      Paint()..filterQuality = FilterQuality.high,
    );
    canvas.restore();
    small.dispose();
  }

  /// pixi 的调色：饱和度 ×1.5、对比度 ×1.2（围绕中灰）。压暗交给最终的主题矩阵。
  static const List<double> _pixiGrade = <double>[
    1.6724, -0.4291, -0.0433, 0, -25.6, //
    -0.1276, 1.3709, -0.0433, 0, -25.6, //
    -0.1276, -0.4291, 1.7567, 0, -25.6, //
    0, 0, 0, 1, 0,
  ];

  // 封面 mesh：曲面铺在以画布中心为心、边长 = 长边的正方形上（短边方向裁掉），
  // 贴图坐标每帧绕 (0.2, 0.2) 转 [_kMeshSpinPerSecond]·t 弧度后平移到中心，镜像
  // 平铺取样；最后乘一圈暗角（中心 1 → 边缘 0.6）。
  void _paintCoverMesh(Canvas canvas, Size size, ui.Image texture, double sec) {
    final MusicHermiteMesh m = mesh;
    final double half = size.longestSide / 2;
    final Offset c = size.center(Offset.zero);
    final double angle = sec * _kMeshSpinPerSecond;
    final double cs = math.cos(angle);
    final double sn = math.sin(angle);
    final double tw = texture.width.toDouble();
    final double th = texture.height.toDouble();
    final int n = m.side * m.side;
    final Float32List pos = Float32List(n * 2);
    final Float32List tex = Float32List(n * 2);
    for (int i = 0; i < n * 2; i += 2) {
      pos[i] = c.dx + m.positions[i] * half;
      pos[i + 1] = c.dy - m.positions[i + 1] * half;
      final double u = m.uvs[i] - 0.2;
      final double v = m.uvs[i + 1] - 0.2;
      tex[i] = (cs * u - sn * v + 0.5) * tw;
      tex[i + 1] = (sn * u + cs * v + 0.5) * th;
    }
    final ui.Vertices vertices = ui.Vertices.raw(
      VertexMode.triangles,
      pos,
      textureCoordinates: tex,
      indices: m.indices,
    );
    canvas.drawVertices(
      vertices,
      BlendMode.srcOver,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..shader = ImageShader(
          texture,
          TileMode.mirror,
          TileMode.mirror,
          Matrix4.identity().storage,
          filterQuality: FilterQuality.medium,
        ),
    );
    vertices.dispose();
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..blendMode = BlendMode.modulate
        ..shader = ui.Gradient.radial(
          c,
          half * 1.6,
          const <Color>[Colors.white, Colors.white, Color(0xFF999999)],
          const <double>[0, 0.375, 1],
        ),
    );
  }

  void _paintMesh(Canvas canvas, Size size, double sec) {
    const int n = kMusicMeshGridSize;
    final double p = (sec / _kFallbackMeshPeriodSeconds) % 1.0;
    final MusicMeshSurface surface = buildMusicMeshSurface(
      points: musicMeshControlPoints(n, p),
      colors: musicMeshAnimatedColors(grid, n, p),
      n: n,
    );
    final Float32List pos = surface.positions;
    final Float32List scaled = Float32List(pos.length);
    for (int i = 0; i < pos.length; i += 2) {
      scaled[i] = pos[i] * size.width;
      scaled[i + 1] = pos[i + 1] * size.height;
    }
    final ui.Vertices vertices = ui.Vertices.raw(
      VertexMode.triangles,
      scaled,
      colors: surface.colors,
      indices: surface.indices,
    );
    // 顶点 Gouraud 着色在三角形边上会有极淡的折痕，低分辨率上轻模糊一次抹平。
    final double sigma = size.longestSide * 0.02;
    canvas.saveLayer(
      Offset.zero & size,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.mirror,
        ),
    );
    // BlendMode.dst：只用顶点颜色（Paint 没有 shader）。
    canvas.drawVertices(vertices, BlendMode.dst, Paint());
    canvas.restore();
    vertices.dispose();
  }

  void _paintClassic(Canvas canvas, Size size, ui.Image cover) {
    final Rect bounds = Offset.zero & size;
    // 封面 cover 铺满并放大 1.2 倍（模糊边缘不露底）。
    final double coverSide = size.longestSide * 1.2;
    final Rect dst = Rect.fromCenter(
      center: bounds.center,
      width: coverSide,
      height: coverSide,
    );
    final double sigma = size.longestSide * 0.06;
    canvas.saveLayer(
      bounds,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.mirror,
        ),
    );
    canvas.drawImageRect(
      cover,
      Rect.fromLTWH(0, 0, cover.width.toDouble(), cover.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BackdropPainter old) {
    final bool content =
        old.style != style ||
        !identical(old.image, image) ||
        !identical(old.meshTexture, meshTexture) ||
        !identical(old.pixiShader, pixiShader) ||
        !identical(old.pixiTexture, pixiTexture) ||
        old.base != base ||
        !listEquals(old.grid, grid);
    if (content) cache.invalidate();
    return content || old.phase != phase || !listEquals(old.matrix, matrix);
  }
}

/// 低分辨率离屏图缓存：尺寸与相位都没变时复用上一张（静态模式就此只渲染一次）。
class _LowResCache {
  ui.Image? _image;
  Size? _size;
  double? _phase;

  void invalidate() => _phase = null;

  ui.Image resolve(
    Size size,
    double phase,
    void Function(Canvas canvas, Size size) paint,
  ) {
    final ui.Image? cached = _image;
    if (cached != null && _size == size && _phase == phase) return cached;
    final int w = size.width.round();
    final int h = size.height.round();
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    paint(Canvas(recorder), Size(w.toDouble(), h.toDouble()));
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = picture.toImageSync(w, h);
    picture.dispose();
    _image?.dispose();
    _image = image;
    _size = size;
    _phase = phase;
    return image;
  }

  void dispose() {
    _image?.dispose();
    _image = null;
  }
}

/// 按 [_kFrameMicros] 档位要帧的驱动（同 FushiMeshBackdrop 的做法：Ticker 一开
/// 就逐 vsync 出整帧，这里只在需要时 `scheduleFrameCallback`；后台 / 熄屏时引擎
/// 不出帧，链条自然停住）。
class _BackdropFrameDriver {
  _BackdropFrameDriver({required this.onFrame});

  final void Function(int frameMicros) onFrame;

  Timer? _timer;
  int? _callbackId;
  bool _active = false;

  bool get isActive => _active;

  void start() {
    if (_active) return;
    _active = true;
    _callbackId = SchedulerBinding.instance.scheduleFrameCallback(_handle);
  }

  void stop() {
    _active = false;
    _timer?.cancel();
    _timer = null;
    final int? id = _callbackId;
    if (id != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
      _callbackId = null;
    }
  }

  void _handle(Duration _) {
    _callbackId = null;
    if (!_active) return;
    final int now =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    onFrame(now);
    if (!_active) return;
    final int wait = _kFrameMicros - now % _kFrameMicros;
    _timer = Timer(Duration(microseconds: wait), () {
      _timer = null;
      if (_active) {
        _callbackId = SchedulerBinding.instance.scheduleFrameCallback(_handle);
      }
    });
  }
}
