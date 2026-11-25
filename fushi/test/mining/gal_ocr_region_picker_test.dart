import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_ocr_line_source.dart';
import 'package:fushi/src/mining/gal_ocr_region_picker.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

/// OCR 游戏模式的框选（拍板台 v5GSgDau9u）：在截图上拖动得到客户区归一化的框。
void main() {
  final Uint8List png = img.encodePng(
    img.Image(width: 800, height: 400)..clear(img.ColorRgb8(200, 200, 200)),
  );

  test('galOcrPngSize 读 IHDR；非 PNG 返回 null', () {
    expect(galOcrPngSize(png), (width: 800, height: 400));
    expect(galOcrPngSize(Uint8List.fromList(List<int>.filled(30, 1))), isNull);
  });

  testWidgets('拖动以按下点为一角重新拉框，坐标按截图归一化', (WidgetTester tester) async {
    GalOcrRegion region = GalOcrRegion.defaultDialogue;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 200,
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) =>
                    GalOcrRegionSelector(
                      framePng: png,
                      aspectRatio: 2,
                      region: region,
                      onChanged: (GalOcrRegion next) =>
                          setState(() => region = next),
                    ),
              ),
            ),
          ),
        ),
      ),
    );
    final Rect box = tester.getRect(find.byType(GalOcrRegionSelector));
    expect(box.size, const Size(400, 200));
    // 从 (90%, 95%) 拖到 (10%, 60%)：反方向拖也得到同一个框。
    final TestGesture gesture = await tester.startGesture(
      box.topLeft + const Offset(360, 190),
    );
    await gesture.moveBy(const Offset(-20, -10));
    await gesture.moveTo(box.topLeft + const Offset(40, 120));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(region.left, closeTo(0.1, 0.01));
    expect(region.top, closeTo(0.6, 0.01));
    expect(region.right, closeTo(0.9, 0.01));
    expect(region.bottom, closeTo(0.95, 0.01));
    expect(region.isValid, isTrue);

    // 拖出画面外的部分夹到边上。
    final TestGesture out = await tester.startGesture(
      box.topLeft + const Offset(200, 100),
    );
    await out.moveBy(const Offset(20, 20));
    await out.moveTo(box.topLeft + const Offset(600, 400));
    await out.up();
    await tester.pumpAndSettle();
    expect(region.right, 1.0);
    expect(region.bottom, 1.0);
  });

  testWidgets('对话框：二值化开关带初值，确认时与框一起交回（BUG-5141 ③）', (
    WidgetTester tester,
  ) async {
    // 对话框内容（截图 + 开关）比默认 800×600 测试窗高：给一个桌面量级的窗口。
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    GalOcrRegionChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showDialog<GalOcrRegionChoice>(
                    context: context,
                    builder: (_) => GalOcrRegionDialog(
                      framePng: png,
                      aspectRatio: 2,
                      initial: GalOcrRegion.defaultDialogue,
                      initialBinarize: true,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final Finder toggle = find.byKey(
      const ValueKey<String>('gal-ocr-binarize'),
    );
    expect(toggle, findsOneWidget);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    // 初值是这个游戏上次的选择（开）；关掉再确认。
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('gal-ocr-region-confirm')),
    );
    await tester.pumpAndSettle();
    expect(result, (region: GalOcrRegion.defaultDialogue, binarize: false));
  });
}
