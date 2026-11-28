import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_fit_title.dart';
import 'package:fushi/src/utils/components/prebaked_blur_image.dart';
import 'package:material_ui/material_ui.dart';

// 没有刮削背景图的色块（未刮削的书 / 漫画、有声书、无图游戏、远端条目）垫一层
// 放大模糊的自家封面（与详情页「没有背景图就封面模糊垫底」同一做法），大字水印
// 让位；有背景图、横版 / 唱片摆法、墨水屏不垫。
void main() {
  // 1×1 透明 PNG（可解码）：图源本身不重要，只看垫底层挂没挂、挂的是哪张。
  final Uint8List png = Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);
  late MemoryImage cover;

  setUp(() => cover = MemoryImage(png));

  Future<void> pumpBlock(
    WidgetTester tester,
    FushiCoverBlock block, {
    bool eink = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: <ThemeExtension<dynamic>>[FushiEinkTheme(eink)],
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 480, height: 220, child: block),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  FushiCoverBlock blockOf({
    FushiCoverBlockArt art = FushiCoverBlockArt.book,
    Widget? backdrop,
    ImageProvider? fallback,
    Widget? disc,
  }) => FushiCoverBlock(
    title: 'Watermark title',
    art: art,
    covers: <Widget>[Image(image: cover)],
    tintImage: cover,
    backdrop: backdrop,
    backdropFallback: fallback,
    disc: disc,
  );

  final Finder fallbackLayer = find.byKey(kFushiCoverBlockBackdropFallbackKey);
  final Finder watermark = find.byWidgetPredicate(
    (Widget w) =>
        w is CustomPaint &&
        w.painter is FushiFitTitlePainter &&
        (w.painter! as FushiFitTitlePainter).text == 'Watermark title',
  );

  for (final FushiCoverBlockArt art in <FushiCoverBlockArt>[
    FushiCoverBlockArt.book,
    FushiCoverBlockArt.box,
    FushiCoverBlockArt.square,
    FushiCoverBlockArt.portrait,
  ]) {
    testWidgets('${art.name}：没有背景图 → 模糊封面垫底铺满整块，水印让位', (
      WidgetTester tester,
    ) async {
      await pumpBlock(tester, blockOf(art: art, fallback: cover));
      expect(tester.takeException(), isNull);
      expect(fallbackLayer, findsOneWidget);
      final PrebakedBlurImage blur = tester.widget<PrebakedBlurImage>(
        find.descendant(
          of: fallbackLayer,
          matching: find.byType(PrebakedBlurImage),
        ),
      );
      expect(blur.image, same(cover));
      expect(blur.sigma, greaterThan(0));
      // 垫底层铺满色块（Positioned.fill），不是只占背景槽。
      expect(tester.getSize(fallbackLayer), const Size(480, 220));
      expect(watermark, findsNothing, reason: '模糊画面上不再叠淡色大字');
    });
  }

  testWidgets('不给 backdropFallback：原样只有底色 + 大字水印', (WidgetTester tester) async {
    await pumpBlock(tester, blockOf());
    expect(fallbackLayer, findsNothing);
    expect(find.byType(PrebakedBlurImage), findsNothing);
    expect(watermark, findsOneWidget);
  });

  testWidgets('有背景图（海报摆法）：用背景图，不垫模糊封面', (WidgetTester tester) async {
    await pumpBlock(
      tester,
      blockOf(
        art: FushiCoverBlockArt.portrait,
        backdrop: const ColoredBox(
          key: ValueKey<String>('real-backdrop'),
          color: Color(0xFF336699),
        ),
        fallback: cover,
      ),
    );
    expect(find.byKey(const ValueKey<String>('real-backdrop')), findsOneWidget);
    expect(fallbackLayer, findsNothing);
  });

  testWidgets('横版摆法：首个封面本身就铺满，不垫', (WidgetTester tester) async {
    await pumpBlock(
      tester,
      blockOf(art: FushiCoverBlockArt.landscape, fallback: cover),
    );
    expect(fallbackLayer, findsNothing);
  });

  testWidgets('唱片摆法：不垫', (WidgetTester tester) async {
    await pumpBlock(
      tester,
      blockOf(
        art: FushiCoverBlockArt.square,
        fallback: cover,
        disc: const ColoredBox(color: Color(0xFF000000)),
      ),
    );
    expect(fallbackLayer, findsNothing);
  });

  testWidgets('墨水屏：不垫照片背景', (WidgetTester tester) async {
    await pumpBlock(tester, blockOf(fallback: cover), eink: true);
    expect(fallbackLayer, findsNothing);
  });
}
