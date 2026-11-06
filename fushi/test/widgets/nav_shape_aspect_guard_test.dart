import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/pages/implementations/home_nav_peek.dart';
import 'package:fushi/src/utils/adaptive/nav_shape.dart';
import 'package:material_ui/material_ui.dart';

// 导航选中形状画进正方形槽：宽高比偏离 1:1 太多就会显得被压扁
// （2026-10-25 用户「怎么感觉游戏扁的」——游戏用的官方 puffy 纵向压到 0.742）。

void expectSquarish(RoundedPolygon shape, String name) {
  // 按实际绘制的轮廓量：画进 100×100 正方形槽后的外接矩形。
  final Rect bounds = MaterialShapeBorder(
    shape: shape,
  ).getOuterPath(const Rect.fromLTWH(0, 0, 100, 100)).getBounds();
  final double ratio = bounds.width / bounds.height;
  expect(ratio, inInclusiveRange(0.9, 1.1), reason: '$name 宽高比 $ratio');
}

void main() {
  test('首页各模块的选中形状宽高接近 1:1', () {
    for (final HomeTab tab in HomeTab.values) {
      expectSquarish(homeNavRailShapeFor(tab), tab.name);
    }
  });

  test('回退形状表宽高接近 1:1', () {
    for (int i = 0; i < kNavRailFallbackShapes.length; i++) {
      expectSquarish(kNavRailFallbackShapes[i], 'fallback[$i]');
    }
  });
}
