import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_dialog.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_mosaic.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import 'advanced_mining_test_host.dart';

/// 「高级制卡」打码：拖动 → 归一化区域的换算、画布框选交互，以及对话框里
/// 「打码 → 编辑页框选 / 撤销 / 完成 → 确认」一路产出的覆盖项。
void main() {
  group('mosaicRegionFromDrag', () {
    const Rect image = Rect.fromLTWH(100, 0, 200, 300);

    test('画布像素 → 相对图的归一化矩形（与拖动方向无关）', () {
      final MiningMosaicRegion r = mosaicRegionFromDrag(
        const Offset(250, 150),
        const Offset(150, 30),
        image,
      )!;
      expect(r.left, closeTo(0.25, 1e-9));
      expect(r.top, closeTo(0.1, 1e-9));
      expect(r.right, closeTo(0.75, 1e-9));
      expect(r.bottom, closeTo(0.5, 1e-9));
    });

    test('拖出图外的部分夹到图边', () {
      final MiningMosaicRegion r = mosaicRegionFromDrag(
        const Offset(0, -50),
        const Offset(200, 400),
        image,
      )!;
      expect(r.left, 0);
      expect(r.top, 0);
      expect(r.right, closeTo(0.5, 1e-9));
      expect(r.bottom, 1);
    });

    test('太小的拖动（误触）不算一块', () {
      expect(
        mosaicRegionFromDrag(
          const Offset(150, 150),
          const Offset(150.5, 151),
          image,
        ),
        isNull,
      );
      expect(
        mosaicRegionFromDrag(Offset.zero, const Offset(10, 10), Rect.zero),
        isNull,
      );
    });
  });

  testWidgets('画布：图按 contain 摆放，拖动在图上拉出一块区域', (WidgetTester tester) async {
    final List<MiningMosaicRegion> added = <MiningMosaicRegion>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 300,
            child: MiningMosaicCanvas(
              // 2:3 竖图放进 4:3 画布：图占中间 200×300（x 100..300）。
              imageSize: const Size(200, 300),
              image: const ColoredBox(color: Colors.blue),
              regions: const <MiningMosaicRegion>[],
              onAdd: added.add,
            ),
          ),
        ),
      ),
    );
    await tester.dragFrom(const Offset(150, 30), const Offset(100, 120));
    await tester.pumpAndSettle();
    expect(added, hasLength(1));
    // 拖动起点要越过 slop 才认领，起点在识别时已记下按下位置，终点 = 起点 + 位移。
    expect(added.single.left, closeTo(0.25, 0.02));
    expect(added.single.top, closeTo(0.1, 0.02));
    expect(added.single.right, closeTo(0.75, 0.02));
    expect(added.single.bottom, closeTo(0.5, 0.02));

    // 点一下不算拖动，不新增。
    await tester.tapAt(const Offset(200, 200));
    await tester.pumpAndSettle();
    expect(added, hasLength(1));
  });

  testWidgets('禁用时不响应拖动', (WidgetTester tester) async {
    final List<MiningMosaicRegion> added = <MiningMosaicRegion>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 300,
            child: MiningMosaicCanvas(
              imageSize: const Size(400, 300),
              image: const ColoredBox(color: Colors.blue),
              regions: const <MiningMosaicRegion>[],
              onAdd: added.add,
              enabled: false,
            ),
          ),
        ),
      ),
    );
    await tester.dragFrom(const Offset(50, 50), const Offset(100, 100));
    await tester.pumpAndSettle();
    expect(added, isEmpty);
  });

  group('对话框里打码', () {
    late FakeAdvancedMiningHost host;
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

    setUp(() => host = FakeAdvancedMiningHost());

    // 400×300 的真 PNG：编辑页要从字节读出尺寸才摆画布。
    final Uint8List png = Uint8List.fromList(
      img.encodePng(img.Image(width: 400, height: 300)),
    );

    Future<void> open(WidgetTester tester, {bool historical = false}) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      FushiToast.navigatorKey = navKey;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => Center(
                child: TextButton(
                  onPressed: () => unawaited(
                    showAdvancedMiningDialog(
                      context: ctx,
                      capabilities: host.capabilities(
                        deck: host.deck(),
                        still: AdvancedMiningStillImageSection(
                          loadImage: () async => png,
                          mosaicForcesStill: true,
                          historicalLine: historical,
                        ),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    /// 编辑页从字节读尺寸是真异步（引擎解码），在真实时间里等它摆出画布。
    Future<void> waitForCanvas(WidgetTester tester) async {
      for (int i = 0; i < 50; i++) {
        if (find.byType(MiningMosaicCanvas).evaluate().isNotEmpty) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      fail('mosaic canvas never appeared');
    }

    Rect canvasImageRect(WidgetTester tester) {
      final Rect box = tester.getRect(find.byType(MiningMosaicCanvas));
      // 400×300 图 contain 进画布。
      final double scale = (box.width / 400) < (box.height / 300)
          ? box.width / 400
          : box.height / 300;
      final Size size = Size(400 * scale, 300 * scale);
      return Rect.fromCenter(
        center: box.center,
        width: size.width,
        height: size.height,
      );
    }

    testWidgets('框两块 → 撤销一块 → 完成 → 确认：覆盖项带剩下那块', (WidgetTester tester) async {
      await open(tester);
      expect(find.text(t.popup_advanced_mining_image_section), findsOneWidget);
      expect(find.text(t.popup_advanced_mining_mosaic_none), findsOneWidget);

      await tester.tap(find.text(t.popup_advanced_mining_mosaic_edit));
      await tester.pumpAndSettle();
      await waitForCanvas(tester);
      expect(find.text(t.popup_advanced_mining_mosaic_hint), findsOneWidget);

      final Rect image = canvasImageRect(tester);
      Offset at(double x, double y) =>
          Offset(image.left + image.width * x, image.top + image.height * y);
      await tester.dragFrom(at(0.1, 0.1), at(0.4, 0.4) - at(0.1, 0.1));
      await tester.pumpAndSettle();
      await tester.dragFrom(at(0.6, 0.6), at(0.9, 0.9) - at(0.6, 0.6));
      await tester.pumpAndSettle();
      expect(
        find.text(t.popup_advanced_mining_mosaic_count(count: 2)),
        findsOneWidget,
      );

      await tester.tap(find.text(t.popup_advanced_mining_mosaic_undo));
      await tester.pumpAndSettle();
      expect(
        find.text(t.popup_advanced_mining_mosaic_count(count: 1)),
        findsOneWidget,
      );

      await tester.tap(find.text(t.popup_advanced_mining_crop_done));
      await tester.pumpAndSettle();
      // 回到对话框：打码行显示 1 处，并提示改出静图（一键「+」是动图）。
      expect(
        find.text(t.popup_advanced_mining_mosaic_count(count: 1)),
        findsOneWidget,
      );
      expect(
        find.text(t.popup_advanced_mining_mosaic_forces_still),
        findsOneWidget,
      );

      await tester.tap(
        find.text(t.popup_advanced_mining_confirm_to_deck(deck: '日语::挖矿')),
      );
      await tester.pumpAndSettle();
      final MiningRequestOverrides o = host.confirms.single;
      expect(o.mosaic, hasLength(1));
      final MiningMosaicRegion r = o.mosaic.single;
      expect(r.left, closeTo(0.1, 0.03));
      expect(r.top, closeTo(0.1, 0.03));
      expect(r.right, closeTo(0.4, 0.03));
      expect(r.bottom, closeTo(0.4, 0.03));
    });

    testWidgets('历史台词：截图分区提示这不是那句当时的画面', (WidgetTester tester) async {
      await open(tester, historical: true);
      expect(find.text(t.popup_advanced_mining_still_stale), findsOneWidget);
    });

    testWidgets('最新台词：不显示历史画面提示', (WidgetTester tester) async {
      await open(tester);
      expect(find.text(t.popup_advanced_mining_still_stale), findsNothing);
    });

    testWidgets('编辑页「×」放弃：不改对话框里的码；「清除」可撤销', (WidgetTester tester) async {
      await open(tester);
      await tester.tap(find.text(t.popup_advanced_mining_mosaic_edit));
      await tester.pumpAndSettle();
      await waitForCanvas(tester);
      final Rect image = canvasImageRect(tester);
      await tester.dragFrom(
        image.topLeft + const Offset(10, 10),
        const Offset(80, 60),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.popup_advanced_mining_mosaic_clear));
      await tester.pumpAndSettle();
      expect(find.text(t.popup_advanced_mining_mosaic_hint), findsOneWidget);
      await tester.tap(find.text(t.popup_advanced_mining_mosaic_undo));
      await tester.pumpAndSettle();
      expect(
        find.text(t.popup_advanced_mining_mosaic_count(count: 1)),
        findsOneWidget,
        reason: '清除也能撤销',
      );

      await tester.tap(find.byTooltip(t.popup_ctx_cancel).last);
      await tester.pumpAndSettle();
      expect(find.text(t.popup_advanced_mining_mosaic_none), findsOneWidget);
    });
  });
}
