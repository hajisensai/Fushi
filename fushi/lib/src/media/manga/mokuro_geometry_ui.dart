/// `mokuro_geometry.dart` 纯 Dart 几何 ↔ `dart:ui` 的边界换算。
///
/// 引擎包里的 [MokuroRect] / [MokuroSize] / [MokuroPoint] 没有 `dart:ui`；app 侧
/// 只在真要交给 Flutter 绘制 / 命中测试 / `Rect` 类型的既有 API 时才在这里换一下，
/// 纯数值读取（`left` / `width` / `center.dx` …）直接用同名成员，不要来回转。
library;

import 'dart:ui' show Offset, Rect, Size;

import 'package:fushi_engine/media/manga/mokuro_geometry.dart';

extension MokuroRectToUi on MokuroRect {
  Rect toRect() => Rect.fromLTRB(left, top, right, bottom);
}

extension RectToMokuro on Rect {
  MokuroRect toMokuroRect() => MokuroRect.fromLTRB(left, top, right, bottom);
}

extension MokuroSizeToUi on MokuroSize {
  Size toSize() => Size(width, height);
}

extension SizeToMokuro on Size {
  MokuroSize toMokuroSize() => MokuroSize(width, height);
}

extension MokuroPointToUi on MokuroPoint {
  Offset toOffset() => Offset(dx, dy);
}

extension OffsetToMokuro on Offset {
  MokuroPoint toMokuroPoint() => MokuroPoint(dx, dy);
}
