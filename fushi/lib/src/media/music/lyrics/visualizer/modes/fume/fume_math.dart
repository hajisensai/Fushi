/// 浮名的数值小工具（folia `fume/fumeMath.ts`）：夹紧、插值、缓动、字符串种子。
library;

import 'dart:math' as math;

double fumeClamp(double value, double min, double max) =>
    value < min ? min : (value > max ? max : value);

double fumeMix(double from, double to, double amount) =>
    from + (to - from) * amount;

double fumeQuadraticBezier(
  double from,
  double control,
  double to,
  double amount,
) {
  final double n = fumeClamp(amount, 0, 1);
  final double inv = 1 - n;
  return inv * inv * from + 2 * inv * n * control + n * n * to;
}

double fumeEaseOutCubic(double value) =>
    1 - math.pow(1 - fumeClamp(value, 0, 1), 3).toDouble();

double fumeEaseInCubic(double value) =>
    math.pow(fumeClamp(value, 0, 1), 3).toDouble();

double fumeEaseInOutCubic(double value) {
  final double n = fumeClamp(value, 0, 1);
  return n < 0.5 ? 4 * n * n * n : 1 - math.pow(-2 * n + 2, 3) / 2;
}

/// 先升到 [peakProgress] 处的峰值，再回落（当前句整体辉光的包络）。
double fumeDelayedGlowEnvelope(double progress, [double peakProgress = 0.8]) {
  final double n = fumeClamp(progress, 0, 1);
  final double peak = fumeClamp(peakProgress, 0.05, 0.95);
  if (n <= peak) return fumeEaseOutCubic(n / peak);
  return 1 - fumeEaseInCubic((n - peak) / (1 - peak));
}

final RegExp _cjk = RegExp(r'[一-鿿぀-ヿ가-힯]');

/// 含中日韩字（决定基线略偏下与打印方块的最小宽度）。
bool fumeIsCjk(String text) => _cjk.hasMatch(text);

/// FNV-1a 32 位（与 folia `hashString` 同值，便于对照）。
int fumeHashString(String input) {
  int hash = 2166136261;
  for (int i = 0; i < input.length; i++) {
    hash ^= input.codeUnitAt(i);
    hash = (hash * 16777619) & 0xFFFFFFFF;
  }
  return hash;
}

/// 字符串 → [0, 1) 的稳定伪随机数。
double fumeSeeded(String seed) => (fumeHashString(seed) % 10000) / 10000;
