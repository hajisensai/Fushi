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
  void expectTitleInside(
    WidgetTester tester,
    String title, {
    double minFont = 20,
  }) {
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
    expect(fontSize, greaterThan(minFont), reason: '字号 $fontSize');
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
      // 窄盒里「ORIGINAL」要整词一行，测试字体（Ahem 每字等宽 = 字号）下只剩小字号。
      expectTitleInside(tester, title, minFont: 10);
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

  group('fit()：拉丁单词不拆开、中日文照常逐字换行', () {
    const TextStyle style = TextStyle(fontWeight: FontWeight.w900, height: .92);

    TextPainter layout(String text, double size, double width) => TextPainter(
      text: TextSpan(
        text: text,
        style: style.copyWith(fontSize: size, letterSpacing: -0.04 * size),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);

    test('「SUPERSTAR - EP」：最长的词整个放进一行，顶上留 0.1em', () {
      // 用户截图里的海报大字盒（420×204 块：封面右侧约 175 宽）。
      const Size box = Size(175, 136);
      const String text = 'SUPERSTAR - EP';
      final double size = fushiFitTitleFontSize(
        text: text,
        style: style,
        box: box,
        minSize: 10,
        maxSize: 61,
        direction: TextDirection.ltr,
      )!;
      final TextPainter p = layout(text, size, box.width);
      expect(p.minIntrinsicWidth, lessThanOrEqualTo(box.width + 0.5));
      // 首行恰好以整个「SUPERSTAR」结束，不在词中间断开。
      final TextRange firstLine = p.getLineBoundary(
        const TextPosition(offset: 0),
      );
      expect(
        text.substring(firstLine.start, firstLine.end).trim(),
        startsWith('SUPERSTAR'),
      );
      expect(
        p.height + size * kFushiFitTitleTopPad,
        lessThanOrEqualTo(box.height),
      );
      p.dispose();
    });

    test('中日文没有词边界，照常逐字换行（不被压成一行小字）', () {
      const Size box = Size(175, 136);
      const String text = '十一月的萧邦';
      final double size = fushiFitTitleFontSize(
        text: text,
        style: style,
        box: box,
        minSize: 10,
        maxSize: 61,
        direction: TextDirection.ltr,
      )!;
      // 一行排下 6 个字最多 175 / 6 ≈ 29；逐字换行能拿到更大的字号。
      expect(size, greaterThan(box.width / text.length + 5));
    });

    test('单词在最小字号（10 px）下仍放不进盒宽时才词内换行，照样完整显示', () {
      const Size box = Size(60, 200);
      const String text = 'Supercalifragilisticexpialidocious';
      final double? size = fushiFitTitleFontSize(
        text: text,
        style: style,
        box: box,
        minSize: 10,
        maxSize: 60,
        direction: TextDirection.ltr,
      );
      expect(size, isNotNull);
      final TextPainter p = layout(text, size!, box.width);
      expect(p.height, lessThanOrEqualTo(box.height));
      p.dispose();
    });
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

    testWidgets('曲库色块跟库页布局：拼贴下首块加大、旁边叠半高卡（与书架一致）', (WidgetTester tester) async {
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
      // 用户 11-21 拍板撤回「音乐一律等尺寸」：首块是拼贴加大块，旁边有半高卡。
      expect(sizes.first, FushiCoverBlockSize.hero);
      expect(sizes, contains(FushiCoverBlockSize.half));
      // 加大首块够宽，无盘专辑走海报版式的装盒大字。
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
