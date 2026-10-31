/// 漫画 OCR 数据模型（`mokuro_payload.dart`）用的纯 Dart 几何值类型。
///
/// 引擎包会被 `dart compile exe`，闭包里不能有 `dart:ui`，所以 `Rect` / `Size` /
/// `Offset` 在这里各有一个同形替身。成员名刻意与 `dart:ui` 一致（`left` / `top` /
/// `right` / `bottom` / `width` / `height` / `center` / `isEmpty` / `shift` /
/// `contains` / `dx` / `dy`），app 侧纯数值读取不用改字；真要喂给 Flutter 绘制或
/// 命中测试时，在边界用 `fushi/lib/src/media/manga/mokuro_geometry_ui.dart` 的
/// `toRect()` / `toSize()` / `toOffset()` 转一下。
///
/// 语义对齐 `dart:ui`：[MokuroRect.isEmpty] 是「左 >= 右 或 上 >= 下」，
/// [MokuroRect.contains] 是左上闭、右下开。
library;

import 'dart:math' as math;

/// `dart:ui` `Offset` 的纯 Dart 替身（二维位移 / 点）。
class MokuroPoint {
  const MokuroPoint(this.dx, this.dy);

  static const MokuroPoint zero = MokuroPoint(0, 0);

  final double dx;
  final double dy;

  @override
  bool operator ==(Object other) =>
      other is MokuroPoint && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(dx, dy);

  @override
  String toString() =>
      'MokuroPoint(${dx.toStringAsFixed(1)}, ${dy.toStringAsFixed(1)})';
}

/// `dart:ui` `Size` 的纯 Dart 替身（页图像素宽高）。
class MokuroSize {
  const MokuroSize(this.width, this.height);

  static const MokuroSize zero = MokuroSize(0, 0);

  final double width;
  final double height;

  /// 与 `dart:ui` `Size.isEmpty` 同义：任一边 <= 0。
  bool get isEmpty => width <= 0 || height <= 0;

  @override
  bool operator ==(Object other) =>
      other is MokuroSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() =>
      'MokuroSize(${width.toStringAsFixed(1)}, ${height.toStringAsFixed(1)})';
}

/// `dart:ui` `Rect` 的纯 Dart 替身（页图像素矩形，左上原点）。
class MokuroRect {
  const MokuroRect.fromLTRB(this.left, this.top, this.right, this.bottom);

  const MokuroRect.fromLTWH(
    double left,
    double top,
    double width,
    double height,
  ) : this.fromLTRB(left, top, left + width, top + height);

  static const MokuroRect zero = MokuroRect.fromLTRB(0, 0, 0, 0);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  MokuroSize get size => MokuroSize(width, height);
  MokuroPoint get topLeft => MokuroPoint(left, top);
  MokuroPoint get center => MokuroPoint(left + width / 2, top + height / 2);

  /// 与 `dart:ui` `Rect.isEmpty` 同义：左 >= 右 或 上 >= 下。
  bool get isEmpty => left >= right || top >= bottom;

  MokuroRect shift(MokuroPoint offset) => MokuroRect.fromLTRB(
    left + offset.dx,
    top + offset.dy,
    right + offset.dx,
    bottom + offset.dy,
  );

  /// 与 `dart:ui` `Rect.contains` 同义：左上闭、右下开。
  bool contains(MokuroPoint point) =>
      point.dx >= left &&
      point.dx < right &&
      point.dy >= top &&
      point.dy < bottom;

  @override
  bool operator ==(Object other) =>
      other is MokuroRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() =>
      'MokuroRect.fromLTRB('
      '${left.toStringAsFixed(1)}, ${top.toStringAsFixed(1)}, '
      '${right.toStringAsFixed(1)}, ${bottom.toStringAsFixed(1)})';
}

/// 绕中心旋转的矩形（页图像素）：先按 [width] × [height] 摆正在 [center]，再绕
/// [center] 转 [rotation] 弧度（图像坐标 y 向下，正值即屏幕上顺时针）。
///
/// 用来承载 mokuro `lines_coords` 里倾斜的行四边形：轴对齐外接框会把斜行
/// 撑成又宽又高的框，按它均分出来的逐字格落不到字上。
class MokuroOrientedRect {
  const MokuroOrientedRect({
    required this.center,
    required this.width,
    required this.height,
    this.rotation = 0,
  });

  final MokuroPoint center;

  /// 沿旋转后 x 轴的边长。
  final double width;

  /// 沿旋转后 y 轴的边长。
  final double height;

  final double rotation;

  /// 摆正（未旋转）时的矩形；配合 [rotation] 绕其中心旋转即得真实位置。
  MokuroRect get unrotated => MokuroRect.fromLTWH(
    center.dx - width / 2,
    center.dy - height / 2,
    width,
    height,
  );

  /// 轴对齐外接框。
  MokuroRect get bounds {
    final double c = math.cos(rotation).abs();
    final double s = math.sin(rotation).abs();
    final double halfW = (width * c + height * s) / 2;
    final double halfH = (width * s + height * c) / 2;
    return MokuroRect.fromLTRB(
      center.dx - halfW,
      center.dy - halfH,
      center.dx + halfW,
      center.dy + halfH,
    );
  }

  /// 局部坐标（以 [center] 为原点、沿旋转后的轴）→ 页面坐标。
  MokuroPoint toPage(double localX, double localY) {
    final double c = math.cos(rotation);
    final double s = math.sin(rotation);
    return MokuroPoint(
      center.dx + localX * c - localY * s,
      center.dy + localX * s + localY * c,
    );
  }
}

/// 行两端的跨轴漂移不到行厚的这个比例，就当正立处理。
const double kMokuroTiltMaxDriftRatio = 0.1;

/// 长 [length]、厚 [thickness] 的行斜 [tilt] 弧度时，不转它是否也无所谓。
///
/// 判据不看角度本身，看后果：不转时按正立行均分的字格，两端会横向偏出
/// `length / 2 · |sin tilt|`。偏移不到行厚的 [kMokuroTiltMaxDriftRatio] 才算
/// 可忽略——同样斜 3°，3 个字的短列两端只偏 0.08 字宽，20 个字的长列要偏半个
/// 字宽、首尾的字点不中。所以长行斜一点也照样转，短行不会被噪声角度带着转。
bool mokuroTiltIsNegligible(double length, double thickness, double tilt) =>
    length / 2 * math.sin(tilt).abs() < kMokuroTiltMaxDriftRatio * thickness;

/// 把 mokuro `lines_coords` 的一个四点多边形拟合成 [MokuroOrientedRect]。
///
/// 顶点顺序（顺 / 逆时针、从哪个角起）都不要求；旋转角折进 (-π/4, π/4]，边长
/// 随之对调。不是四个点、或四边形明显不是矩形（对边不等长 / 邻边不垂直，例如
/// 手写的梯形）时返回 null，调用方退回轴对齐外接框。
MokuroOrientedRect? mokuroOrientedRectFromQuad(List<List<double>> polygon) {
  if (polygon.length != 4 ||
      polygon.any((List<double> point) => point.length < 2)) {
    return null;
  }
  double ex(int i) => polygon[(i + 1) % 4][0] - polygon[i][0];
  double ey(int i) => polygon[(i + 1) % 4][1] - polygon[i][1];
  double len(int i) => math.sqrt(ex(i) * ex(i) + ey(i) * ey(i));
  final double l0 = len(0), l1 = len(1), l2 = len(2), l3 = len(3);
  if (math.min(math.min(l0, l1), math.min(l2, l3)) <= 0) return null;
  bool similar(double a, double b) =>
      (a - b).abs() <= 0.15 * math.max(a, b) + 1;
  if (!similar(l0, l2) || !similar(l1, l3)) return null;
  final double cosine = (ex(0) * ex(1) + ey(0) * ey(1)) / (l0 * l1);
  if (cosine.abs() > 0.1) return null;
  double rotation = math.atan2(ey(0), ex(0));
  double width = (l0 + l2) / 2;
  double height = (l1 + l3) / 2;
  // 折进 (-π/4, π/4]：每转 90° 对调一次边长，转 180° 不变。
  while (rotation > math.pi / 4) {
    rotation -= math.pi / 2;
    final double t = width;
    width = height;
    height = t;
  }
  while (rotation <= -math.pi / 4) {
    rotation += math.pi / 2;
    final double t = width;
    width = height;
    height = t;
  }
  double cx = 0, cy = 0;
  for (final List<double> point in polygon) {
    cx += point[0] / 4;
    cy += point[1] / 4;
  }
  return MokuroOrientedRect(
    center: MokuroPoint(cx, cy),
    width: width,
    height: height,
    rotation:
        mokuroTiltIsNegligible(
          math.max(width, height),
          math.min(width, height),
          rotation,
        )
        ? 0
        : rotation,
  );
}
