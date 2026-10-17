// 「超级大西瓜」视图的几何：字数 → 球半径、球 → 静态堆叠位置（纯 Dart，可测）。
//
// 只算一次、不跑物理：按名次从大到小依次「竖直落下」，每颗球选一个能落得最低
// 的横坐标（同高取更靠中间），停在第一次碰到的地面 / 墙 / 已有球上——这就是
// 合成大西瓜里球静止后的样子，且构造上保证任意两球不重叠。

import 'dart:math' as math;

/// 最小 / 最大球半径（逻辑像素，视图可再整体缩放）。
const double kWatermelonMinRadius = 18;
const double kWatermelonMaxRadius = 96;

/// 字数 → 半径。字数差距常是几个数量级（几千对几百万），线性面积会让小球
/// 小到看不见，纯对数又把差距压得看不出来：取「开方（面积 ∝ 字数）」与
/// 「对数」各一半，保序、头部仍明显更大、尾部也有能认出头像的尺寸。
double watermelonRadius(
  int value,
  int maxValue, {
  double minRadius = kWatermelonMinRadius,
  double maxRadius = kWatermelonMaxRadius,
}) {
  if (maxValue <= 0 || value <= 0) return minRadius;
  final double v = math.min(value, maxValue).toDouble();
  final double m = maxValue.toDouble();
  final double sqrtPart = math.sqrt(v / m);
  final double logPart = math.log(1 + v) / math.log(1 + m);
  final double t = 0.5 * sqrtPart + 0.5 * logPart;
  return minRadius + (maxRadius - minRadius) * t;
}

/// 一颗已放好的球：[center] 以容器左上角为原点（y 向下）。
class WatermelonBall {
  const WatermelonBall({
    required this.index,
    required this.center,
    required this.radius,
  });

  /// 在输入列表里的下标。
  final int index;
  final math.Point<double> center;
  final double radius;
}

/// 整堆的布局结果。
class WatermelonPile {
  const WatermelonPile({
    required this.width,
    required this.height,
    required this.balls,
  });

  final double width;
  final double height;
  final List<WatermelonBall> balls;
}

/// 容器宽度：让整堆的宽高比大致等于 [aspect]（宽 / 高，按视口给，手机竖屏堆得
/// 高一些、桌面摊得宽一些；总面积 / 堆积率换算），且至少放得下最大球再留一点余地。
double watermelonContainerWidth(List<double> radii, {double aspect = 1}) {
  if (radii.isEmpty) return 0;
  double area = 0;
  double maxR = 0;
  for (final double r in radii) {
    area += math.pi * r * r;
    maxR = math.max(maxR, r);
  }
  final double a = aspect.isFinite && aspect > 0 ? aspect : 1;
  return math.max(maxR * 2.4, math.sqrt(area / 0.62 * a));
}

/// 按 [radii] 的顺序（应当从大到小）逐颗落下，返回静止后的位置。
/// [step] 是候选落点的横向采样间距。
WatermelonPile layoutWatermelonPile(
  List<double> radii, {
  double? width,
  double aspect = 1,
  double step = 2,
}) {
  if (radii.isEmpty) {
    return const WatermelonPile(width: 0, height: 0, balls: <WatermelonBall>[]);
  }
  final double w = width ?? watermelonContainerWidth(radii, aspect: aspect);
  // 先在「y 向上、地面为 0」的坐标里放，最后翻成 y 向下。
  final List<double> xs = <double>[];
  final List<double> ys = <double>[];
  final List<double> rs = <double>[];
  for (final double r in radii) {
    final double lo = r;
    final double hi = math.max(r, w - r);
    double bestX = (lo + hi) / 2;
    double bestY = double.infinity;
    double bestCenterDist = double.infinity;
    for (double x = lo; x <= hi + 1e-9; x += step) {
      final double y = _restHeight(x, r, xs, ys, rs);
      final double centerDist = (x - w / 2).abs();
      if (y < bestY - 1e-6 ||
          ((y - bestY).abs() <= 1e-6 && centerDist < bestCenterDist)) {
        bestX = x;
        bestY = y;
        bestCenterDist = centerDist;
      }
    }
    xs.add(bestX);
    ys.add(bestY);
    rs.add(r);
  }
  double top = 0;
  for (int i = 0; i < rs.length; i++) {
    top = math.max(top, ys[i] + rs[i]);
  }
  return WatermelonPile(
    width: w,
    height: top,
    balls: <WatermelonBall>[
      for (int i = 0; i < rs.length; i++)
        WatermelonBall(
          index: i,
          center: math.Point<double>(xs[i], top - ys[i]),
          radius: rs[i],
        ),
    ],
  );
}

/// 半径 [r] 的球沿 x = [x] 从高处落下，停住时的球心高度（地面 = 0）。
double _restHeight(
  double x,
  double r,
  List<double> xs,
  List<double> ys,
  List<double> rs,
) {
  double y = r;
  for (int j = 0; j < xs.length; j++) {
    final double reach = r + rs[j];
    final double dx = (x - xs[j]).abs();
    if (dx >= reach) continue;
    final double contact = ys[j] + math.sqrt(reach * reach - dx * dx);
    if (contact > y) y = contact;
  }
  return y;
}
