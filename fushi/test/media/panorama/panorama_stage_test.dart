// 媒体库全景的真实渲染路径冒烟：建图集（占位封面 + 字形三种）→ Rust 建图 → 分享动画 16 秒
// （13.5 秒交接给翻书，翻完打开锁定的书）；交互模式点中央封面同样走飞入 → 翻开 → 打开。
// 原生库是硬依赖：找不到 fushi_compute 要失败，不 skip。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/panorama/panorama_atlas.dart';
import 'package:fushi/src/media/panorama/panorama_book_flip.dart';
import 'package:fushi/src/media/panorama/panorama_library.dart';
import 'package:fushi/src/media/panorama/panorama_page.dart';
import 'package:fushi/src/media/panorama/panorama_stage.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:fushi_compute/fushi_compute.dart';
import 'package:material_ui/material_ui.dart';

const PanoramaLibrary _library = PanoramaLibrary(
  works: <PanoramaWork>[
    PanoramaWork(
      kind: PanoramaWorkKind.book,
      key: 'b0',
      title: '本その一',
      coverPath: null,
      lastOpenedAt: 5,
    ),
    PanoramaWork(
      kind: PanoramaWorkKind.video,
      key: 'v0',
      title: 'Video',
      coverPath: null,
    ),
    PanoramaWork(
      kind: PanoramaWorkKind.game,
      key: 'g0',
      title: 'Game',
      coverPath: null,
    ),
  ],
  words: <PanoramaWord>[
    PanoramaWord('食べる', 0),
    PanoramaWord('魔法', 1),
    PanoramaWord('散歩', -1),
  ],
  minedTotal: 3,
);

const PanoramaAtlasSpec _spec = PanoramaAtlasSpec(
  pageSize: 1024,
  thumbPx: 64,
  emPx: 18,
  maxGlyphs: 200,
);

Future<PanoramaAssets> _assets(
  WidgetTester tester, [
  PanoramaLibrary library = _library,
]) async {
  final PanoramaAtlas atlas = (await tester.runAsync(
    () => buildPanoramaAtlas(
      library,
      fonts: const <PanoramaFontSet>[PanoramaFontSet(null)],
      spec: _spec,
    ),
  ))!;
  addTearDown(atlas.dispose);
  return PanoramaAssets(library: library, atlas: atlas);
}

void main() {
  testWidgets('atlas packs one cell per work plus three per unique glyph', (
    WidgetTester tester,
  ) async {
    final PanoramaAssets a = await _assets(tester);
    final FfcPanoScene s = a.atlas.scene;
    // 唯一字：食 べ る 魔 法 散 歩 = 7。
    expect(s.workCount, 3);
    expect(s.cellCount, 3 + 7 * 3);
    expect(s.wordCount, 3);
    expect(s.glyphCount, 7);
    expect(a.defaultTarget, 0, reason: 'most recent book');
    for (int c = 0; c < s.cellCount; c++) {
      expect(s.cellRects[c * 4 + 2], greaterThan(0));
      expect(
        s.cellRects[c * 4] + s.cellRects[c * 4 + 2],
        lessThanOrEqualTo(_spec.pageSize),
      );
    }
  });

  testWidgets('share animation hands off at 13.5 s, flips, opens the target', (
    WidgetTester tester,
  ) async {
    final PanoramaAssets a = await _assets(tester);
    final List<PanoramaWork> opened = <PanoramaWork>[];
    bool done = false;
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: PanoramaStage(
            assets: a,
            mode: FfcPanoMode.cinematic,
            cinematicTarget: 0,
            onOpen: (PanoramaWork w) async => opened.add(w),
            onCinematicDone: () => done = true,
          ),
        ),
      ),
    );
    for (int i = 0; i < 132; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PanoramaBookFlip), findsNothing);
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PanoramaBookFlip), findsOneWidget);
    expect(opened, isEmpty);
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(opened.single.key, 'b0');
    expect(done, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'interactive: idle scene stops scheduling frames, input wakes it',
    (WidgetTester tester) async {
      final PanoramaAssets a = await _assets(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: PanoramaStage(assets: a, onOpen: (PanoramaWork w) async {}),
          ),
        ),
      );
      // 刚开场环境动效在跑：一直有帧排着。
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);
      // 环境动效约 9 秒收敛到零；给足 30 秒。
      int pumps = 0;
      while (tester.binding.hasScheduledFrame && pumps < 300) {
        await tester.pump(const Duration(milliseconds: 100));
        pumps++;
      }
      expect(
        tester.binding.hasScheduledFrame,
        isFalse,
        reason: 'settled scene must stop the ticker',
      );
      expect(pumps, greaterThan(30), reason: 'ambient motion eases out');
      // 静止后多等一会儿仍然不排帧。
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse);

      // 拖拽输入：立刻恢复出帧。
      final TestGesture g = await tester.startGesture(
        tester.getCenter(find.byType(PanoramaStage)),
      );
      await g.moveBy(const Offset(40, 0));
      await g.moveBy(const Offset(40, 0));
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump(const Duration(milliseconds: 16));
      await g.up();
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isTrue);

      // 再次空闲后又停。
      pumps = 0;
      while (tester.binding.hasScheduledFrame && pumps < 300) {
        await tester.pump(const Duration(milliseconds: 100));
        pumps++;
      }
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion: tapping a card opens it directly', (
    WidgetTester tester,
  ) async {
    final PanoramaAssets a = await _assets(
      tester,
      PanoramaLibrary(
        works: <PanoramaWork>[
          for (int i = 0; i < 40; i++)
            PanoramaWork(
              kind: PanoramaWorkKind.book,
              key: 'b$i',
              title: 'Book $i',
              coverPath: null,
            ),
        ],
        words: const <PanoramaWord>[],
        minedTotal: 0,
      ),
    );
    final List<PanoramaWork> opened = <PanoramaWork>[];
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: PanoramaStage(
            assets: a,
            onOpen: (PanoramaWork w) async => opened.add(w),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // 整个视口逐格点：从球心看 40 张卡铺满球面，视野里一定有卡。
    final Size size = tester.getSize(find.byType(PanoramaStage));
    for (double y = 20; y < size.height && opened.isEmpty; y += 40) {
      for (double x = 20; x < size.width && opened.isEmpty; x += 40) {
        await tester.tapAt(Offset(x, y));
        await tester.pump();
      }
    }
    expect(find.byType(PanoramaBookFlip), findsNothing);
    expect(opened, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  PanoramaLibrary books(int n) => PanoramaLibrary(
    works: <PanoramaWork>[
      for (int i = 0; i < n; i++)
        PanoramaWork(
          kind: PanoramaWorkKind.book,
          key: 'b$i',
          title: 'Book $i',
          coverPath: null,
        ),
    ],
    words: const <PanoramaWord>[],
    minedTotal: 0,
  );

  testWidgets('full page idle drift: words keep moving, frames never stop', (
    WidgetTester tester,
  ) async {
    final PanoramaAssets a = await _assets(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: PanoramaStage(
            assets: a,
            idleDrift: kPanoramaPageIdleDrift,
            onOpen: (PanoramaWork w) async {},
          ),
        ),
      ),
    );
    for (int i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      tester.binding.hasScheduledFrame,
      isTrue,
      reason: 'idle drift keeps the ambient orbit running',
    );
    // 卸载时停掉帧循环。
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('stage controller toggles galaxy <-> sphere smoothly', (
    WidgetTester tester,
  ) async {
    final PanoramaAssets a = await _assets(tester);
    final PanoramaStageController c = PanoramaStageController();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 800,
          height: 600,
          child: PanoramaStage(
            assets: a,
            controller: c,
            onOpen: (PanoramaWork w) async {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(c.sphere, isFalse, reason: 'opens on the galaxy');
    c.toggleStage();
    expect(c.sphere, isTrue, reason: 'button flips at once');
    final List<bool> seen = <bool>[];
    c.addListener(() => seen.add(c.sphere));
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(c.sphere, isTrue);
    expect(seen, isEmpty, reason: 'no flicker back while easing in');
    c.toggleStage();
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(c.sphere, isFalse);
    expect(seen, <bool>[false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Esc during the fly-in cancels the lock without opening', (
    WidgetTester tester,
  ) async {
    final PanoramaAssets a = await _assets(tester, books(40));
    final PanoramaStageController c = PanoramaStageController();
    addTearDown(c.dispose);
    final List<PanoramaWork> opened = <PanoramaWork>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PanoramaStage(
          assets: a,
          controller: c,
          autofocus: true,
          onOpen: (PanoramaWork w) async => opened.add(w),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    // 先推到球心：40 张卡铺满球面，视野里一定有卡可点。
    c.toggleStage();
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final Size size = tester.getSize(find.byType(PanoramaStage));
    bool flipping = false;
    for (double y = 40; y < size.height && !flipping; y += 60) {
      for (double x = 40; x < size.width && !flipping; x += 60) {
        await tester.tapAt(Offset(x, y));
        for (int i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        flipping = find.byType(PanoramaBookFlip).evaluate().isNotEmpty;
      }
    }
    expect(flipping, isTrue, reason: 'some card was hit and flew in');
    expect(opened, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(PanoramaBookFlip), findsNothing);
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(opened, isEmpty, reason: 'cancelled, nothing opened');
    expect(c.sphere, isTrue, reason: 'back where we were, not the galaxy');
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  test('cover thumbnails scale with library size within the budget', () {
    expect(_spec.thumbPxFor(3), _spec.thumbPx, reason: 'fixed when no max');
    const PanoramaAtlasSpec d = PanoramaAtlasSpec.desktop;
    expect(d.thumbPxFor(20), d.maxThumbPx);
    expect(d.thumbPxFor(132), greaterThan(300));
    expect(d.thumbPxFor(100000), d.thumbPx);
    for (final int n in <int>[1, 50, 132, 400, 2000]) {
      final double px = d.thumbPxFor(n);
      expect(
        n * px * px,
        lessThanOrEqualTo(math.max(d.coverBudgetPx, n * d.thumbPx * d.thumbPx)),
      );
    }
  });

  test('share picker puts the default target first, then most recent', () {
    final List<int> order = panoramaShareTargetOrder(_library);
    expect(order.first, 0, reason: 'most recent book = default target');
    expect(order.toSet(), <int>{0, 1, 2});
  });
}
