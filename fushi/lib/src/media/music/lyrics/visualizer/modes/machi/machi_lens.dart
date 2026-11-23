/// 町景的景深与移轴（folia `engine/lens.ts` + `fx/lensPass.ts` 的近似）：folia 按深度算每个像素的
/// 离焦圆；这里是正交斜俯视，离镜头的远近大致就是画面的上下，所以按画面高度切成几条横带，
/// 每条按“离对焦线多远”和“离画面上下边多近”（移轴）给一个模糊半径。光圈每大一档清晰的
/// 那一层薄到 1/√2、离焦圆大到 √2 倍（与 folia 一致），从清晰到最虚的过渡按光圈的平方根收窄。
/// 纯函数。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_math.dart';

/// 一条横带：上下界（像素）与高斯模糊的 sigma（像素）。
class MachiLensBand {
  const MachiLensBand(this.top, this.bottom, this.sigma);

  final double top;
  final double bottom;
  final double sigma;
}

/// 画面某一高度 [y] 的模糊 sigma（像素）。
double resolveMachiBlurAt({
  required double y,
  required double height,
  required double focusY,
  required double aperture,
  required double dof,
  required double dofRange,
  required double tiltShift,
}) {
  final double h = math.max(1, height);
  final double stop = math.sqrt(8 / machiClamp(aperture, 1.4, 16));
  // 清晰的那一层：f/8 时约画面高的 16%，乘清晰范围，光圈每大一档薄到 1/√2。
  final double sharpHalf = h * 0.16 * dofRange / stop;
  // 从清晰到最虚的过渡长度按光圈的平方根收窄。
  final double ramp = h * 0.4 / math.sqrt(stop);
  final double away = math.max(0, (y - focusY).abs() - sharpHalf);
  final double dofSigma = dof * stop * h / 220 * machiSmoothstep(0, ramp, away);
  // 移轴：画面上下两头虚掉。
  final double edge = ((y / h) - 0.5).abs();
  final double tiltSigma =
      tiltShift * h / 180 * machiSmoothstep(0.18, 0.5, edge);
  return dofSigma + tiltSigma;
}

/// 切成 [count] 条横带，太清楚（sigma < 0.6）的不出。
List<MachiLensBand> resolveMachiLensBands({
  required double height,
  required double focusY,
  required double aperture,
  required double dof,
  required double dofRange,
  required double tiltShift,
  int count = 12,
}) {
  final List<MachiLensBand> out = <MachiLensBand>[];
  if (dof <= 0 && tiltShift <= 0) return out;
  final double step = height / count;
  for (int i = 0; i < count; i++) {
    final double top = i * step;
    final double sigma = resolveMachiBlurAt(
      y: top + step / 2,
      height: height,
      focusY: focusY,
      aperture: aperture,
      dof: dof,
      dofRange: dofRange,
      tiltShift: tiltShift,
    );
    if (sigma < 0.6) continue;
    out.add(MachiLensBand(top, top + step, sigma));
  }
  return out;
}
