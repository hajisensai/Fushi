/// 花火的纯数学：确定性随机流、散列、缓动、颜色混合（移植 folia `hanabiRandom.ts`、
/// `mg/mgMath.ts`、`text/animations.ts` 的缓动与 `timeline.ts` 的 easeSeptic / easeSwing）。
///
/// 颜色一律是 0xRRGGBB 的 int（与 folia 的 Pixi 颜色一致），画的时候再转 [Color]。
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

/// 0..1 的随机流。
typedef HanabiRng = double Function();

const double kTau = math.pi * 2;

/// 按 key 播种的随机流（folia `createVisualizerRng`：FNV-1a 散列 + mulberry32）。
HanabiRng hanabiRng(String key) {
  final LyricVisualizerRandom r = LyricVisualizerRandom(
    lyricVisualizerSeedOf(key),
  );
  return r.next;
}

/// FNV-1a 32 位散列（folia `hashVisualizerSeed` / `hashString`）。
int hanabiHashString(String key) => lyricVisualizerSeedOf(key);

/// JS `Math.imul` 的低 32 位（无符号）。
int imul32(int a, int b) => ((a & 0xFFFFFFFF) * (b & 0xFFFFFFFF)) & 0xFFFFFFFF;

double clamp01(double v) => v <= 0 ? 0 : (v >= 1 ? 1 : v);
double clampD(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);
double lerpD(double a, double b, double t) => a + (b - a) * t;
double fract(double v) => v - v.floorToDouble();

/// 落在 [0, span) 里的取模（负数也对）。
double wrapD(double v, double span) => v - span * (v / span).floorToDouble();

/// 确定性噪声（mgMath `hash01`）：同一 (n, salt) 永远同一个 [0, 1) 值。
double mgHash01(double n, [double salt = 0]) =>
    fract(math.sin(n * 127.1 + salt * 311.7) * 43758.5453123);

/// 整数散列 → 0..1（animations `hash01`，乱码、故障逐帧取值用）。
double intHash01(int a, [int b = 0]) {
  int h =
      imul32(a ^ 0x9e3779b9, 0x85ebca6b) ^ imul32(b + 0x632be5ab, 0xc2b2ae35);
  h &= 0xFFFFFFFF;
  h ^= h >> 15;
  h = imul32(h, 0x2c1b3c6d);
  h ^= h >> 12;
  h = imul32(h, 0x297a2d39);
  h ^= h >> 15;
  return (h & 0xFFFFFFFF) / 4294967296.0;
}

// ─── 缓动 ──────────────────────────────────────────────────────────────

double easeOutQuad(double t) {
  final double x = clamp01(t);
  return 1 - (1 - x) * (1 - x);
}

double easeOutCubic(double t) {
  final double x = clamp01(t);
  return 1 - math.pow(1 - x, 3).toDouble();
}

double easeOutQuart(double t) {
  final double x = clamp01(t);
  return 1 - math.pow(1 - x, 4).toDouble();
}

double easeInCubic(double t) {
  final double x = clamp01(t);
  return x * x * x;
}

double easeInQuad(double t) {
  final double x = clamp01(t);
  return x * x;
}

double easeInOutCubic(double t) {
  final double x = clamp01(t);
  return x < 0.5 ? 4 * x * x * x : 1 - math.pow(-2 * x + 2, 3) / 2;
}

double easeOutExpo(double t) {
  final double x = clamp01(t);
  return x >= 1 ? 1 : 1 - math.pow(2, -10 * x).toDouble();
}

/// 过冲：冲过 1 再落回（输入钳在 0..1）。
double easeOutBack(double t, [double s = 1.70158]) {
  final double x = clamp01(t) - 1;
  return 1 + x * x * ((s + 1) * x + s);
}

/// 反向蓄力。
double easeInBack(double t, [double s = 1.70158]) {
  final double x = clamp01(t);
  return x * x * ((s + 1) * x - s);
}

/// 欠阻尼弹簧：从 0 弹到 1。
double springEase(double seconds, [double freq = 2.6, double decay = 7]) =>
    seconds <= 0
    ? 0
    : 1 - math.exp(-decay * seconds) * math.cos(kTau * freq * seconds);

/// 一拍一格地走：每个节拍用 easeOutBack 跳到下一格。
double beatSteps(double beats, [double snap = 0.35]) {
  final double whole = beats.floorToDouble();
  return whole + easeOutBack(fract(beats) / snap, 2.2);
}

double smoothstep01(double v) {
  final double t = clamp01(v);
  return t * t * (3 - 2 * t);
}

/// 七次 smootherstep：两端速度、加速度、加加速度都为 0。
double easeSeptic(double value) {
  final double t = clamp01(value);
  return math.pow(t, 4) * (35 + t * (-84 + t * (70 - 20 * t)));
}

/// easeSeptic 从 0 积到 t，积到 1 是 1/2。
double easeSepticIntegral(double t) =>
    math.pow(t, 5) * (7 + t * (-14 + t * (10 - 2.5 * t)));

/// 镜头之间的快转、上升的缓急：速度曲线是 (1 − u²)^n 的圆顶鼓包。
const int kSwingSharpness = 4;

double _binomial(int n, int k) {
  double r = 1;
  for (int i = 1; i <= k; i++) {
    r = r * (n - k + i) / i;
  }
  return r;
}

final List<double> _swingTerms = <double>[
  for (int k = 0; k <= kSwingSharpness; k++)
    _binomial(kSwingSharpness, k) * (k.isEven ? 1 : -1) / (2 * k + 1),
];

double _swingPrimitive(double u) {
  final double u2 = u * u;
  double power = u;
  double sum = 0;
  for (final double term in _swingTerms) {
    sum += term * power;
    power *= u2;
  }
  return sum;
}

final double _swingHalf = _swingPrimitive(1);

/// 镜头之间的过渡缓动（两端速度、加速度都为 0，中间一下甩过去）。
double easeSwing(double value) =>
    0.5 + _swingPrimitive(2 * clamp01(value) - 1) / (2 * _swingHalf);

// ─── 颜色 ──────────────────────────────────────────────────────────────

const int kWhite = 0xffffff;

/// 火药燃烧的金色。
const int kGold = 0xffc760;

/// 尾迹里的橙色火粉。
const int kEmber = 0xff9a3c;

/// 0xRRGGBB 逐通道线性混合。
int mixRgb(int a, int b, double t) {
  final double k = clamp01(t);
  if (k <= 0) return a;
  if (k >= 1) return b;
  final int r =
      (((a >> 16) & 255) + ((((b >> 16) & 255) - ((a >> 16) & 255)) * k))
          .round();
  final int g = (((a >> 8) & 255) + ((((b >> 8) & 255) - ((a >> 8) & 255)) * k))
      .round();
  final int bl = ((a & 255) + (((b & 255) - (a & 255)) * k)).round();
  return (r << 16) | (g << 8) | bl;
}

/// 压暗。
int darkenRgb(int color, double amount) {
  final double k = 1 - amount;
  final int r = (((color >> 16) & 0xff) * k).round();
  final int g = (((color >> 8) & 0xff) * k).round();
  final int b = ((color & 0xff) * k).round();
  return (r << 16) | (g << 8) | b;
}

/// 0xRRGGBB + 透明度 → [Color]。
Color rgbColor(int rgb, [double alpha = 1]) {
  final int a = (clamp01(alpha) * 255).round();
  return Color((a << 24) | (rgb & 0xFFFFFF));
}

/// [Color] → 0xRRGGBB。
int rgbOf(Color c) => c.toARGB32() & 0xFFFFFF;

/// 从一串里等距取不超过 max 个。
List<T> thinList<T>(List<T> items, int max) {
  if (items.length <= max) return items;
  final double step = items.length / max;
  return <T>[for (int k = 0; k < max; k++) items[(k * step).floor()]];
}
