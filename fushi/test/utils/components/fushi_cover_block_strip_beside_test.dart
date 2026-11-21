import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart'
    show RenderRepaintBoundary, RenderViewportBase;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart';
import 'package:material_ui/material_ui.dart';

// 11-20 反馈 #1（用户截图 shots/28.png）：视频首页「继续观看」主卡右侧两行横滑条
// 的视口向起始侧外扩了悬停余量 20dp，比与主卡的间距 16dp 还宽——视口伸进主卡
// 4dp，滑走的卡画在主卡右缘之上：主卡右侧两个圆角被盖成直角，卡片在主卡边上
// 竖直硬切。紧挨着主卡的横滑条（besideLeading）起始侧不外扩，视口从条自己的
// 起点开始；结束侧还能滑时渐隐。
void main() {
  const double leadWidth = 300;
  final GlobalKey shotKey = GlobalKey();
  const double spacing = kFushiCoverBlockSpacing;

  Future<void> pumpRow(WidgetTester tester, {required bool beside}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: shotKey,
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(40),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const SizedBox(width: leadWidth, height: 300),
                  const SizedBox(width: spacing),
                  Expanded(
                    child: FushiCoverBlockStrip(
                      leadingHero: false,
                      staggerEntrance: false,
                      rowSize: FushiCoverBlockSize.regular,
                      rows: 2,
                      tileHeight: 140,
                      tileWidth: 300,
                      besideLeading: beside,
                      itemCount: 12,
                      itemBuilder:
                          (
                            BuildContext context,
                            int i,
                            FushiCoverBlockSize _,
                          ) => ColoredBox(
                            key: ValueKey<int>(i),
                            color: const Color(0xFF3366AA),
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
  }

  /// 真实像素：(x, y) 处的 RGBA。
  Future<List<int>> pixelAt(WidgetTester tester, int x, int y) async {
    final List<int>? rgba = await tester.runAsync<List<int>>(() async {
      final RenderRepaintBoundary boundary = tester
          .renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
      final ui.Image image = await boundary.toImage();
      final ByteData? data = await image.toByteData();
      final int i = (y * image.width + x) * 4;
      image.dispose();
      return <int>[for (int k = 0; k < 4; k++) data!.getUint8(i + k)];
    });
    return rgba!;
  }

  double viewportLeft(WidgetTester tester) {
    final RenderViewportBase viewport = tester
        .renderObjectList<RenderViewportBase>(find.byType(Viewport))
        .first;
    return viewport.localToGlobal(Offset.zero).dx;
  }

  const double stripLeft = 40 + leadWidth + spacing;

  testWidgets('紧挨主卡的横滑条：视口不伸进主卡（起点 = 条起点），右缘渐隐', (WidgetTester tester) async {
    await pumpRow(tester, beside: true);
    expect(tester.takeException(), isNull);
    expect(viewportLeft(tester), greaterThanOrEqualTo(stripLeft - 0.01));
    // 内容超出视口（12 张 × 300 宽），结束侧渐隐。
    expect(find.byType(ShaderMask), findsOneWidget);
    // 渐隐只作用在结束边：条内首张卡的像素照常画出（真实像素，不只看结构）。
    final List<int> inside = await pixelAt(
      tester,
      (stripLeft + 100).round(),
      40 + 70,
    );
    expect(inside, <int>[0x33, 0x66, 0xAA, 0xFF]);

    // 滑走：首张卡左缘跑到条起点左边，可见部分仍被裁在条起点（视口边）上。
    await tester.drag(find.byType(Viewport).first, const Offset(-150, 0));
    await tester.pump(const Duration(seconds: 1));
    expect(viewportLeft(tester), greaterThanOrEqualTo(stripLeft - 0.01));
    expect(await pixelAt(tester, (stripLeft + 100).round(), 40 + 70), <int>[
      0x33,
      0x66,
      0xAA,
      0xFF,
    ]);
    // 主卡与横滑条之间的间距里不画任何卡（滑走的卡被裁在视口边上）。
    expect(
      await pixelAt(tester, (stripLeft - spacing / 2).round(), 40 + 70),
      isNot(<int>[0x33, 0x66, 0xAA, 0xFF]),
    );
  });

  testWidgets('不挨着别的卡的横滑条照旧向两侧外扩悬停余量（对照）', (WidgetTester tester) async {
    await pumpRow(tester, beside: false);
    expect(viewportLeft(tester), lessThan(stripLeft - spacing));
    expect(find.byType(ShaderMask), findsNothing);
  });
}
