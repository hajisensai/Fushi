/// 绘光的小工具（纯函数）：缓动、与着色器一致的噪声、按 key 播种的随机流、线性 RGB。
/// 对应 folia `lumiere/color.ts`、`lumiereRandom.ts` 与 `light/rig.ts` 里的噪声。
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

const double kTau = math.pi * 2;

double clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

double lerpD(double a, double b, double k) => a + (b - a) * k;

/// smoothstep(0, 1, v)。
double smooth(double v) {
  final double t = clamp01(v);
  return t * t * (3 - 2 * t);
}

double smoothstep(double e0, double e1, double x) {
  final double d = e1 - e0;
  final double t = clamp01(d == 0 ? (x < e0 ? 0 : 1) : (x - e0) / d);
  return t * t * (3 - 2 * t);
}

double easeInOutCubic(double v) {
  final double t = clamp01(v);
  return t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2;
}

double easeInOutSine(double v) => (1 - math.cos(math.pi * clamp01(v))) / 2;

double easeOutCubic(double v) {
  final double t = 1 - clamp01(v);
  return 1 - t * t * t;
}

double easeOutExpo(double v) {
  final double t = clamp01(v);
  return t >= 1 ? 1 : 1 - math.pow(2, -10 * t).toDouble();
}

double fract(double v) => v - v.floorToDouble();

/// Dave Hoskins 的 hash11（与 GLSL 一致，不用 sin）。
double hash11(double input) {
  double p = fract(input * 0.1031);
  p *= p + 33.33;
  p *= p + p;
  return fract(p);
}

double hash12(double x, double y) {
  double a = fract(x * 0.1031);
  double b = fract(y * 0.1031);
  double c = fract(x * 0.1031);
  final double d = a * (b + 33.33) + b * (c + 33.33) + c * (a + 33.33);
  a += d;
  b += d;
  c += d;
  return fract((a + b) * c);
}

double valueNoise1(double x) {
  final double i = x.floorToDouble();
  final double f = x - i;
  final double u = f * f * (3 - 2 * f);
  return hash11(i) * (1 - u) + hash11(i + 1) * u;
}

double valueNoise2(double x, double y) {
  final double ix = x.floorToDouble();
  final double iy = y.floorToDouble();
  final double fx = x - ix;
  final double fy = y - iy;
  final double ux = fx * fx * (3 - 2 * fx);
  final double uy = fy * fy * (3 - 2 * fy);
  final double a = hash12(ix, iy);
  final double b = hash12(ix + 1, iy);
  final double c = hash12(ix, iy + 1);
  final double d = hash12(ix + 1, iy + 1);
  return (a * (1 - ux) + b * ux) * (1 - uy) + (c * (1 - ux) + d * ux) * uy;
}

/// 着色器里的 fbm（旋转 + 2.03 倍频）。
double fbm(double x, double y, int octaves) {
  double sum = 0;
  double amp = 0.5;
  double norm = 0;
  double px = x;
  double py = y;
  for (int i = 0; i < 6 && i < octaves; i++) {
    sum += amp * valueNoise2(px, py);
    norm += amp;
    final double nx = (0.8 * px + 0.6 * py) * 2.03 + 17.1;
    final double ny = (-0.6 * px + 0.8 * py) * 2.03 + 9.2;
    px = nx;
    py = ny;
    amp *= 0.5;
  }
  return sum / math.max(norm, 1e-4);
}

/// 按 key 播种的 mulberry32 流（folia `createRng(key)`：key 先经 FNV-1a 散列）。
typedef LumiereRng = double Function();

LumiereRng lumiereRng(String key) {
  final LyricVisualizerRandom r = LyricVisualizerRandom(
    lyricVisualizerSeedOf(key),
  );
  return r.next;
}

/// 0..1 线性小数组上的颜色（folia `Rgb`）。
class Rgb {
  const Rgb(this.r, this.g, this.b);

  factory Rgb.of(Color c) => Rgb(c.r, c.g, c.b);

  final double r;
  final double g;
  final double b;

  Rgb mix(Rgb o, double k) =>
      Rgb(r + (o.r - r) * k, g + (o.g - g) * k, b + (o.b - b) * k);

  Rgb scale(double k) => Rgb(r * k, g * k, b * k);

  Rgb times(Rgb o) => Rgb(r * o.r, g * o.g, b * o.b);

  double get peak => math.max(r, math.max(g, b));

  double get luminance => 0.2126 * r + 0.7152 * g + 0.0722 * b;

  Color toColor([double alpha = 1]) => Color.from(
    alpha: clamp01(alpha),
    red: clamp01(r),
    green: clamp01(g),
    blue: clamp01(b),
  );

  /// ARGB 整数（drawVertices / drawAtlas 的逐点颜色）。
  int argb(double alpha) {
    int c(double v) => (clamp01(v) * 255).round();
    return (c(alpha) << 24) | (c(r) << 16) | (c(g) << 8) | c(b);
  }

  @override
  bool operator ==(Object other) =>
      other is Rgb && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);
}

const Rgb kWhite = Rgb(1, 1, 1);

/// 参考图的香槟金。
const Rgb kChampagne = Rgb(1, 0.86, 0.62);
