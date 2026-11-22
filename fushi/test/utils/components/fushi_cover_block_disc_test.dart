import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_disc_art.dart';
import 'package:fushi/src/pages/implementations/music/music_collection_view.dart';
import 'package:fushi/src/utils/components/fushi_continue_blocks.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_fit_title.dart';
import 'package:material_ui/material_ui.dart';

// 音乐专辑色块（2026-11-21 用户：音乐页「参考别的模块，太丑了」）：与书架 / 漫画 /
// 视频同一套文字区（水印 + 标题 + 副行 + chip），W 原型的整块标题大字版式退役。
// - 只有真实盘面图（[FushiCoverBlock.disc]）才画唱片，没有就是普通方形封面摆法；
// - 唱片垫在封套后面、从结束侧露出，文字区从唱片之后起排、不压唱片；
// - 悬停时唱片再滑出一截。
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

  /// 标题是真 Text（读得出来），整块落在色块里，且在唱片 / 封面右侧、不压它们。
  void expectTextClearOfArt(WidgetTester tester, String title) {
    final Finder text = find.text(title);
    expect(text, findsOneWidget, reason: '标题没画出来');
    final Rect block = tester.getRect(find.byKey(blockKey));
    final Rect t = tester.getRect(text);
    expect(t.right, lessThanOrEqualTo(block.right + 0.5));
    expect(t.bottom, lessThanOrEqualTo(block.bottom + 0.5));
    for (final Finder art in <Finder>[
      find.byKey(discKey),
      find.byKey(coverKey),
    ]) {
      if (art.evaluate().isEmpty) continue;
      expect(t.left, greaterThanOrEqualTo(tester.getRect(art).right - 0.5));
    }
  }

  const String title = 'K-ON!! ORIGINAL SOUND TRACK Vol.1';

  group('唱片摆法：只有真实盘面图才画', () {
    // Fushi 规整块（420×204）、拼贴首块（800×264）、半高卡（400×125）、单格（235×281）。
    for (final Size size in <Size>[
      const Size(420, 204),
      const Size(800, 264),
      const Size(400, 125),
      const Size(235, 281),
    ]) {
      testWidgets('${size.width}×${size.height}：有盘面图 → 唱片从封套后露出 + 文字不压唱片', (
        WidgetTester tester,
      ) async {
        await pumpSized(
          tester,
          const FushiCoverBlock(
            title: title,
            art: FushiCoverBlockArt.square,
            subtitle: '百石元 · 2010',
            chip: 'CD',
            disc: ColoredBox(key: discKey, color: Colors.black),
            covers: <Widget>[ColoredBox(key: coverKey, color: Colors.teal)],
          ),
          size,
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(discKey), findsOneWidget);
        expect(find.text('CD'), findsOneWidget);
        expect(find.text('百石元 · 2010'), findsOneWidget);
        expectTextClearOfArt(tester, title);
        final Rect block = tester.getRect(find.byKey(blockKey));
        final Rect cover = tester.getRect(find.byKey(coverKey));
        final Rect discRest = tester.getRect(find.byKey(discKey));
        // 唱片在封套结束侧露出一截，且整张在色块里。
        expect(discRest.right, greaterThan(cover.right + 4));
        expect(block.inflate(0.5).contains(discRest.topLeft), isTrue);
        expect(discRest.bottom, lessThanOrEqualTo(block.bottom + 0.5));

        // 悬停：唱片再往结束侧滑出。
        await hover(tester);
        final Rect discHover = tester.getRect(find.byKey(discKey));
        expect(discHover.center.dx, greaterThan(discRest.center.dx + 2));
      });
    }

    testWidgets('没有盘面图 → 不画唱片（不造假唱片），标题照常是正文', (WidgetTester tester) async {
      for (final Size size in <Size>[
        const Size(486, 281),
        const Size(420, 204),
        const Size(400, 125),
      ]) {
        await pumpSized(
          tester,
          const FushiCoverBlock(
            title: title,
            art: FushiCoverBlockArt.square,
            covers: <Widget>[ColoredBox(key: coverKey, color: Colors.teal)],
          ),
          size,
        );
        expect(find.byKey(discKey), findsNothing);
        expect(find.text('CD'), findsNothing);
        expectTextClearOfArt(tester, title);
      }
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
      expectTextClearOfArt(tester, title);

      await pumpSized(
        tester,
        FushiContinueBlockCard(entry: entry(), size: FushiCoverBlockSize.half),
        const Size(400, 125),
      );
      expect(find.byKey(discKey), findsNothing);
    });

    testWidgets('服务器 / Apple Music 专辑块：普通方形封面摆法，标题与副行是正文', (
      WidgetTester tester,
    ) async {
      await pumpSized(
        tester,
        const MusicCollectionBlock(
          title: title,
          size: FushiCoverBlockSize.regular,
          subtitle: 'TOMORROW X TOGETHER · 2023',
        ),
        const Size(420, 204),
      );
      expect(find.text(title), findsOneWidget);
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
      expect(boxes.first.width / boxes.first.height, greaterThan(1.6));
      // 标题是正文（不再是整块标题大字）。
      expect(find.text('Album 0'), findsOneWidget);
    });

    testWidgets('专辑块给了盘面图才画唱片（插件 / 最近播放共用 MusicCollectionBlock）', (
      WidgetTester tester,
    ) async {
      await pumpSized(
        tester,
        const MusicCollectionBlock(
          title: title,
          size: FushiCoverBlockSize.regular,
          disc: ColoredBox(key: discKey, color: Colors.black),
        ),
        const Size(420, 204),
      );
      expect(find.byKey(discKey), findsOneWidget);
      expectTextClearOfArt(tester, title);
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
