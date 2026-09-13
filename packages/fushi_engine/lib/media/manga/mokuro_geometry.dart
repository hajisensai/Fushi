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
  String toString() => 'MokuroRect.fromLTRB('
      '${left.toStringAsFixed(1)}, ${top.toStringAsFixed(1)}, '
      '${right.toStringAsFixed(1)}, ${bottom.toStringAsFixed(1)})';
}
