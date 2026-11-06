// BUG-3933：歌词模式静止 mesh 背景在高 DPR 手机上出现菱形网格。缓存图以前按
// **逻辑**尺寸的 1/8 画，DPR 3 的 iPhone 上一个纹素被拉成 24×24 物理像素，8-bit
// 量化的渐变经双线性插值露出网格，静止时钉在屏幕上。现在静止背景按物理像素全
// 分辨率画（只画一次），流动时按物理像素降采样。
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart';
import 'package:material_ui/material_ui.dart';

Future<List<(int, int)>> _renderedSizes(
  WidgetTester tester, {
  required bool animate,
}) async {
  final List<(int, int)> sizes = <(int, int)>[];
  debugOnFushiMeshImageRendered = (ui.Image image) =>
      sizes.add((image.width, image.height));
  addTearDown(() => debugOnFushiMeshImageRendered = null);
  tester.view
    ..physicalSize = const Size(1170, 2532)
    ..devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: FushiMeshBackdrop(animate: animate, colorTransition: true),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  // 流动背景不会停帧，卸掉再收尾。
  await tester.pumpWidget(const SizedBox.shrink());
  return sizes;
}

void main() {
  testWidgets('静止背景：缓存图与屏幕物理像素一一对应（不拉伸）', (WidgetTester tester) async {
    final List<(int, int)> sizes = await _renderedSizes(tester, animate: false);
    expect(sizes, isNotEmpty);
    expect(sizes.toSet(), <(int, int)>{(1170, 2532)});
  });

  testWidgets('流动背景：按物理像素降采样（8 物理像素一纹素，与 DPR 无关）', (WidgetTester tester) async {
    final List<(int, int)> sizes = await _renderedSizes(tester, animate: true);
    expect(sizes, isNotEmpty);
    // 1170 / 8 = 146.25 → 147；2532 / 8 = 316.5 → 317。旧实现按逻辑尺寸
    // 1/8 只有 49×106（一纹素 24 物理像素）。
    expect(sizes.toSet(), <(int, int)>{(147, 317)});
  });
}
