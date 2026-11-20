import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_disc_art.dart';
import 'package:fushi/src/pages/implementations/music/music_collection_view.dart';
import 'package:fushi/src/utils/components/fushi_continue_blocks.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_fit_title.dart';
import 'package:material_ui/material_ui.dart';

// 11-20 反馈 #5：音乐卡照 W 原型（w_proto.html）的「扇形」唱片摆法与标题大字。
// - 只有真实盘面图（[FushiCoverBlock.disc]）才画唱片，没有就是无盘版式；
// - 标题大字装在给定盒子里（原型 `fit()`：padding-top .1em、overflow-wrap
//   anywhere），任何尺寸档都不溢出；
// - 宽块无盘 = 原型无盘双格卡（封面占满高度、大字铺在封面右侧、底下一行元信息）；
// - 半高卡（125 高）有盘 = 横排（原型的「标题在封面下方」在这个高度画不出字）。
void main() {
  const ValueKey<String> blockKey = ValueKey<String>('block');
  const ValueKey<String> discKey = ValueKey<String>('disc');
  const ValueKey<String> coverKey = ValueKey<String>('cover');

  Future<void> pumpSized(WidgetTester tester, Widget child, Size size) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              key: blockKey,
              width: size.width,
              height: size.height,
              child: child,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> hover(WidgetTester tester) async {
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(blockKey)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
  }

  Finder fitPaint(String text) => find.byWidgetPredicate(
    (Widget w) =>
        w is CustomPaint &&
        w.painter is FushiFitTitlePainter &&
        (w.painter! as FushiFitTitlePainter).text == text,
  );

  /// 标题大字画在自己的盒子里：排出来的外框不越出 CustomPaint，且盒子在色块内。
  void expectTitleInside(WidgetTester tester, String title) {
    final Finder paint = fitPaint(title);
    expect(paint, findsOneWidget, reason: '大字没画出来');
    final CustomPaint w = tester.widget<CustomPaint>(paint);
    final Rect canvas = tester.getRect(paint);
    final Rect inner = (w.painter! as FushiFitTitlePainter).titleRect(
      canvas.size,
    );
    expect(inner.left, greaterThanOrEqualTo(-0.01));
    expect(inner.top, greaterThanOrEqualTo(-0.01));
    expect(inner.right, lessThanOrEqualTo(canvas.width + 0.5));
    expect(inner.bottom, lessThanOrEqualTo(canvas.height + 0.01));
    final Rect block = tester.getRect(find.byKey(blockKey));
    expect(block.contains(canvas.topLeft), isTrue);
    expect(canvas.right, lessThanOrEqualTo(block.right + 0.01));
    expect(canvas.bottom, lessThanOrEqualTo(block.bottom + 0.01));
    // 不是退回到最小字号的一行小字：W 原型的大字至少是正文的两倍。
    final double fontSize =
        (w.painter! as FushiFitTitlePainter).style.fontSize!;
    expect(fontSize, greaterThan(20), reason: '字号 $fontSize');
  }

  const String title = 'K-ON!! ORIGINAL SOUND TRACK Vol.1';

  group('唱片摆法：只有真实盘面图才画', () {
    // 原型桌面档双格（486×281）、单格（235×281），Fushi 规整块（420×204）、
    // 拼贴首块（800×264）、半高卡（400×125）。
    for (final Size size in <Size>[
      const Size(486, 281),
      const Size(235, 281),
      const Size(420, 204),
      const Size(800, 264),
      const Size(400, 125),
    ]) {
      testWidgets('${size.width}×${size.height}：有盘面图 → 唱片 + 大字不溢出 + CD', (
        WidgetTester tester,
      ) async {
        await pumpSized(
          tester,
          const FushiCoverBlock(
            title: title,
            art: FushiCoverBlockArt.square,
            chip: 'CD',
            albumPoster: true,
            disc: ColoredBox(key: discKey, color: Colors.black),
            covers: <Widget>[ColoredBox(key: coverKey, color: Colors.teal)],
          ),
          size,
        );
        expect(find.byKey(discKey), findsOneWidget);
        expect(find.text('CD'), findsOneWidget);
        expectTitleInside(tester, title);

        // 悬停：唱片弹簧转出（往右上），大字横移 6 后仍在盒内。
        final Rect discRest = tester.getRect(find.byKey(discKey));
        await hover(tester);
        final Rect discHover = tester.getRect(find.byKey(discKey));
        expect(discHover.center.dx, greaterThan(discRest.center.dx + 2));
        expect(discHover.center.dy, lessThan(discRest.center.dy));
      });
    }

    testWidgets('没有盘面图 → 不画唱片（不造假唱片）', (WidgetTester tester) async {
      for (final Size size in <Size>[
        const Size(486, 281),
        const Size(235, 281),
        const Size(400, 125),
      ]) {
        await pumpSized(
          tester,
          const FushiCoverBlock(
            title: title,
            art: FushiCoverBlockArt.square,
            albumPoster: true,
            covers: <Widget>[ColoredBox(key: coverKey, color: Colors.teal)],
          ),
          size,
        );
        expect(find.byKey(discKey), findsNothing);
        expect(find.text('CD'), findsNothing);
      }
    });
  });

  group('无盘双格卡（专辑海报版式）', () {
    testWidgets('封面占满高度在左、大字铺在右侧、底下一行元信息', (WidgetTester tester) async {
      const Size size = Size(486, 281);
      await pumpSized(
        tester,
        const FushiCoverBlock(
          title: title,
          art: FushiCoverBlockArt.square,
          albumPoster: true,
          subtitle: '百石元 · 2010',
          covers: <Widget>[ColoredBox(key: coverKey, color: Colors.teal)],
        ),
        size,
      );
      final Rect cover = tester.getRect(find.byKey(coverKey));
      // 原型：S = H − 2p = 249，位于 (p + 4, p + 2)，不斜放。
      expect(cover.width, moreOrLessEquals(size.height - 32, epsilon: 0.5));
      expect(cover.left, moreOrLessEquals(20, epsilon: 0.5));
      expect(cover.top, moreOrLessEquals(18, epsilon: 0.5));
      expectTitleInside(tester, title);
      final Rect big = tester.getRect(fitPaint(title));
      expect(big.left, greaterThanOrEqualTo(cover.right));
      final Rect meta = tester.getRect(find.text('百石元 · 2010'));
      expect(meta.left, greaterThanOrEqualTo(cover.right));
      expect(meta.top, greaterThanOrEqualTo(big.bottom - 0.5));
    });

    testWidgets('刚够宽的块：元信息行带长 chip / 附加件也不溢出', (WidgetTester tester) async {
      await pumpSized(
        tester,
        const FushiCoverBlock(
          title: title,
          art: FushiCoverBlockArt.square,
          albumPoster: true,
          subtitle: 'A very long artist credit line',
          chip: 'FLAC 24/96 · Hi-Res',
          trailing: SizedBox(width: 120, height: 20),
          covers: <Widget>[ColoredBox(key: coverKey, color: Colors.teal)],
        ),
        const Size(330, 204),
      );
      expect(tester.takeException(), isNull);
      expectTitleInside(tester, title);
    });

    testWidgets('窄块（单格）仍是原摆法，不走海报版式', (WidgetTester tester) async {
      await pumpSized(
        tester,
        const FushiCoverBlock(
          title: title,
          art: FushiCoverBlockArt.square,
          albumPoster: true,
          subtitle: 'artist',
          covers: <Widget>[ColoredBox(key: coverKey, color: Colors.teal)],
        ),
        const Size(235, 281),
      );
      // 原摆法的标题是真 Text（水印另画），海报版式只有 FushiFitTitle 大字。
      expect(find.text(title), findsOneWidget);
    });
  });

  test('W 原型 fit()：wrapAnywhere 只看盒高，顶上留 0.1em', () {
    const TextStyle style = TextStyle(fontWeight: FontWeight.w900, height: .92);
    const Size box = Size(183, 223);
    final double? anywhere = fushiFitTitleFontSize(
      text: title,
      style: style,
      box: box,
      minSize: 10,
      maxSize: 84,
      direction: TextDirection.ltr,
      wrapAnywhere: true,
    );
    final double? keepWords = fushiFitTitleFontSize(
      text: title,
      style: style,
      box: box,
      minSize: 10,
      maxSize: 84,
      direction: TextDirection.ltr,
    );
    expect(anywhere, isNotNull);
    expect(keepWords, isNotNull);
    expect(anywhere!, greaterThanOrEqualTo(keepWords!));
    final TextPainter p = TextPainter(
      text: TextSpan(
        text: title,
        style: style.copyWith(
          fontSize: anywhere,
          letterSpacing: -0.04 * anywhere,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: box.width);
    expect(
      p.height + anywhere * kFushiFitTitleTopPad,
      lessThanOrEqualTo(box.height),
    );
    p.dispose();
  });

  group('调用点', () {
    testWidgets('继续收听色块：blockDisc 有 → 唱片；没有 → 不画', (WidgetTester tester) async {
      FushiContinueEntry entry({Widget? disc}) => FushiContinueEntry(
        key: const ValueKey<String>('entry'),
        cover: const ColoredBox(key: coverKey, color: Colors.teal),
        coverAspectRatio: 1,
        title: title,
        blockDisc: disc,
        onOpen: () {},
      );
      await pumpSized(
        tester,
        FushiContinueBlockCard(
          entry: entry(
            disc: const ColoredBox(key: discKey, color: Colors.black),
          ),
          size: FushiCoverBlockSize.half,
        ),
        const Size(400, 125),
      );
      expect(find.byKey(discKey), findsOneWidget);
      expectTitleInside(tester, title);

      await pumpSized(
        tester,
        FushiContinueBlockCard(entry: entry(), size: FushiCoverBlockSize.half),
        const Size(400, 125),
      );
      expect(find.byKey(discKey), findsNothing);
    });

    testWidgets('服务器 / Apple Music 专辑块（albumPoster）宽块走无盘海报版式', (
      WidgetTester tester,
    ) async {
      await pumpSized(
        tester,
        const MusicCollectionBlock(
          title: title,
          size: FushiCoverBlockSize.regular,
          subtitle: 'TOMORROW X TOGETHER · 2023',
          albumPoster: true,
        ),
        const Size(420, 204),
      );
      expectTitleInside(tester, title);
      expect(find.text('TOMORROW X TOGETHER · 2023'), findsOneWidget);
      expect(find.byKey(discKey), findsNothing);
    });

    testWidgets('曲库色块不起拼贴加大首块：所有块等尺寸', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);
      final List<FushiCoverBlockSize> sizes = <FushiCoverBlockSize>[];
      final List<Size> boxes = <Size>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicStyledCollection(
              style: MusicViewStyle.blocks,
              itemCount: 9,
              rowBuilder: (BuildContext context, int i) =>
                  const SizedBox.shrink(),
              blockBuilder:
                  (BuildContext context, int i, FushiCoverBlockSize size) {
                    sizes.add(size);
                    return LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints c) {
                        boxes.add(c.biggest);
                        return MusicCollectionBlock(
                          title: 'Album $i',
                          size: size,
                          albumPoster: true,
                        );
                      },
                    );
                  },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(sizes, isNotEmpty);
      expect(sizes.toSet(), <FushiCoverBlockSize>{FushiCoverBlockSize.regular});
      expect(boxes.map((Size b) => b.height).toSet().length, 1);
      // 等尺寸块够宽（W 原型双格比例），无盘专辑走海报版式的装盒大字。
      expect(boxes.first.width / boxes.first.height, greaterThan(1.6));
      expect(fitPaint('Album 0'), findsOneWidget);
    });

    testWidgets('专辑块给了盘面图才画唱片（插件 / 最近播放共用 MusicCollectionBlock）', (
      WidgetTester tester,
    ) async {
      await pumpSized(
        tester,
        const MusicCollectionBlock(
          title: title,
          size: FushiCoverBlockSize.regular,
          albumPoster: true,
          disc: ColoredBox(key: discKey, color: Colors.black),
        ),
        const Size(420, 204),
      );
      expect(find.byKey(discKey), findsOneWidget);
      expectTitleInside(tester, title);
    });

    test('盘面图映射发布：内容不变不通知', () {
      final MusicDiscArtIndex index = MusicDiscArtIndex.instance;
      int calls = 0;
      void listener() => calls++;
      index.albums.addListener(listener);
      addTearDown(() {
        index.albums.removeListener(listener);
        index.publish(const <String, String>{});
      });
      index.publish(const <String, String>{'a': '/x/disc.jpg'});
      index.publish(const <String, String>{'a': '/x/disc.jpg'});
      expect(calls, 1);
      expect(index.albums.value['a'], '/x/disc.jpg');
    });
  });
}
