import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show computeTocAnchorCharOffsets, tocAnchorKey;
import 'package:fushi/src/reader/reader_gallery_page.dart';
import 'package:fushi/src/reader/ttu_toc_flatten.dart';

/// BUG-2722：照《無職転生 25》的结构造书——
///
/// - `ch1.xhtml` 一个文件装第五～七話，目录靠 `#anchor` 分节，第七話里有一张插图；
/// - `ch2.xhtml` 装两篇間話（「鎧」在章首，「僕は…」靠锚点）；
/// - `ch3`～`ch5` 是三个各只有一张插图、不进目录的插图页。
///
/// 旧画廊按 spine 章分节：第七話的插图挂在「第五話」名下，三张插图页拆成三个
/// 同名节。目录分节后前者归第七話，后者合成一节。
EpubBook _book() {
  EpubChapter chapter(int i, String body) => EpubChapter(
        id: 'c$i',
        href: 'ch$i.xhtml',
        mediaType: 'application/xhtml+xml',
        html: '<html><body>$body</body></html>',
      );
  return EpubBook(
    title: '無職転生 25',
    chapters: <EpubChapter>[
      chapter(0, '<h2>第四話</h2><p>あいうえおかきくけこ</p><img src="i0.png"/>'),
      chapter(
        1,
        '<h2>第五話</h2><p>あいうえおかきくけこ</p><img src="i1.png"/>'
        '<h2 id="a6">第六話</h2><p>さしすせそたちつてと</p>'
        '<h2 id="a7">第七話</h2><p>なにぬねの</p><img src="i2.png"/>'
        '<p>はひふへほ</p>',
      ),
      chapter(
        2,
        '<h2>間話「鎧」</h2><p>まみむめも</p>'
        '<h2 id="b2">間話「僕は英雄になりたかった」</h2><p>やゆよ</p>',
      ),
      chapter(3, '<img src="p3.png"/>'),
      chapter(4, '<img src="p4.png"/>'),
      chapter(5, '<img src="p5.png"/>'),
    ],
    toc: <EpubTocItem>[
      EpubTocItem(label: '第四話', href: 'ch0.xhtml'),
      EpubTocItem(label: '第五話', href: 'ch1.xhtml'),
      EpubTocItem(label: '第六話', href: 'ch1.xhtml#a6'),
      EpubTocItem(label: '第七話', href: 'ch1.xhtml#a7'),
      EpubTocItem(label: '間話「鎧」', href: 'ch2.xhtml'),
      EpubTocItem(label: '間話「僕は英雄になりたかった」', href: 'ch2.xhtml#b2'),
    ],
  );
}

/// 与阅读器 / 书架端宿主同一条链路：isolate 里算的锚点偏移喂给压平。
List<TtuTocEntry> _tocOf(EpubBook book) {
  final Map<String, int> anchors = computeTocAnchorCharOffsets(book);
  return flattenTtuTocEntries(
    book.toc,
    book.chapterIndexForHref,
    anchorCharOffset: (int chapter, String fragment) =>
        anchors[tocAnchorKey(chapter, fragment)],
  );
}

Finder _tocSection(int entry) =>
    find.byKey(ValueKey<String>('fushi_gallery_section_toc_$entry'));
Finder _card(String src) =>
    find.byKey(ValueKey<String>('fushi_gallery_card_$src'));

/// 节头 key 挂在 sliver 上，取它里面那个盒子的顶边。
double _headerTop(WidgetTester tester, Finder header) => tester
    .getTopLeft(
      find.descendant(of: header, matching: find.byType(SizedBox)).first,
    )
    .dy;

/// 页面上全部节头的 key，按从上到下的顺序。
List<String> _sectionKeys(WidgetTester tester) {
  final List<Element> headers = find
      .byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
                  'fushi_gallery_section_',
                ),
      )
      .evaluate()
      .toList()
    ..sort(
      (Element a, Element b) => _headerTop(tester, find.byWidget(a.widget))
          .compareTo(_headerTop(tester, find.byWidget(b.widget))),
    );
  return <String>[
    for (final Element e in headers) (e.widget.key! as ValueKey<String>).value,
  ];
}

/// [src] 的卡片落在 [entry] 那一节：卡片在该节节头之下、下一个节头之上。
void _expectCardUnder(WidgetTester tester, String src, int entry) {
  final double cardTop = tester.getTopLeft(_card(src)).dy;
  final double headerTop = _headerTop(tester, _tocSection(entry));
  expect(cardTop, greaterThan(headerTop), reason: '$src 应在目录项 $entry 之下');
  for (final String key in _sectionKeys(tester)) {
    final double top = _headerTop(tester, find.byKey(ValueKey<String>(key)));
    if (top > headerTop) {
      expect(cardTop, lessThan(top), reason: '$src 越过了下一节 $key');
      break;
    }
  }
}

Future<void> _pumpGallery(
  WidgetTester tester, {
  required EpubBook book,
  required List<TtuTocEntry> toc,
  required int currentChapter,
  required int currentCharOffset,
}) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: ReaderGalleryPage(
        images: book.images,
        currentChapter: currentChapter,
        fileForRef: (_) => null,
        onOpenImage: (_) {},
        onJumpTo: (_) {},
        toc: ReaderGalleryToc(
          entries: toc,
          currentEntry: resolveCurrentTocEntry(
            toc,
            currentChapter,
            currentCharOffset,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  tester
      .widget<CustomScrollView>(find.byType(CustomScrollView))
      .controller
      ?.jumpTo(0);
  await tester.pump();
}

void main() {
  test('插图带上与目录锚点同一把尺的章内字符偏移', () {
    final EpubBook book = _book();
    final Map<String, int> anchors = computeTocAnchorCharOffsets(book);
    final EpubImageRef i2 =
        book.images.firstWhere((EpubImageRef r) => r.src == 'i2.png');
    // 第七話锚点之后、正文五个字之后。
    expect(i2.chapterIndex, 1);
    expect(i2.charOffset, anchors[tocAnchorKey(1, 'a7')]! + 3 + 5);
  });

  test('锚点与插图同一偏移时按文档顺序判先后', () {
    final EpubBook book = EpubBook(
      title: 'T',
      chapters: <EpubChapter>[
        EpubChapter(
          id: 'c0',
          href: 'ch0.xhtml',
          mediaType: 'application/xhtml+xml',
          // close.png 收尾第一話（紧贴第二話标题之前）；open.png 开启第三話
          // （锚点挂在包裹元素上，图在标题之前）。
          html: '<html><body><h2>第一話</h2><p>あいうえお</p>'
              '<img src="close.png"/>\n'
              '<h2 id="n2">第二話</h2><p>かきくけこ</p>'
              '<div id="n3">\n<img src="open.png"/><h2>第三話</h2></div>'
              '<p>さしすせそ</p></body></html>',
        ),
      ],
      toc: <EpubTocItem>[
        EpubTocItem(label: '第一話', href: 'ch0.xhtml'),
        EpubTocItem(label: '第二話', href: 'ch0.xhtml#n2'),
        EpubTocItem(label: '第三話', href: 'ch0.xhtml#n3'),
      ],
    );
    final List<TtuTocEntry> toc = _tocOf(book);
    final EpubImageRef close = book.images[0];
    final EpubImageRef open = book.images[1];
    // 前提：两张图都与后一个锚点同偏移，只靠字符数分不出来。
    expect(close.charOffset, toc[1].anchorCharOffset);
    expect(open.charOffset, toc[2].anchorCharOffset);

    expect(resolveTocEntryForImage(toc, close), 0);
    expect(resolveTocEntryForImage(toc, open), 2);
  });

  test('锚点偏移未知时退回章首语义，不因平局规则丢掉', () {
    final List<TtuTocEntry> toc = <TtuTocEntry>[
      TtuTocEntry(index: 0, label: 'A'),
      TtuTocEntry(index: 1, label: 'B', fragment: 'x'),
    ];
    const EpubImageRef ref = EpubImageRef(
      chapterIndex: 1,
      orderInBook: 0,
      src: 'a.png',
      revealKey: 'a.png',
    );
    expect(resolveTocEntryForImage(toc, ref), 1);
    // 封面不归任何一条。
    const EpubImageRef cover = EpubImageRef(
      chapterIndex: kEpubCoverChapterIndex,
      orderInBook: 0,
      src: 'c.png',
      revealKey: 'c.png',
    );
    expect(resolveTocEntryForImage(toc, cover), isNull);
  });

  testWidgets('同一文件里的各话各自分节，连续插图页合成一节', (WidgetTester tester) async {
    final EpubBook book = _book();
    final List<TtuTocEntry> toc = _tocOf(book);
    await _pumpGallery(
      tester,
      book: book,
      toc: toc,
      // 读到书末：全部插图已解锁，点卡片直接进单图查看器。
      currentChapter: 5,
      currentCharOffset: 0,
    );

    // 第四話 / 第五話 / 第七話 / 間話「僕は…」各一节；第六話和「鎧」没有插图，
    // ch3～ch5 三张插图页不再各成一节。
    expect(_sectionKeys(tester), <String>[
      'fushi_gallery_section_toc_0',
      'fushi_gallery_section_toc_1',
      'fushi_gallery_section_toc_3',
      'fushi_gallery_section_toc_5',
    ]);
    expect(find.text('第七話'), findsOneWidget);
    expect(find.text('間話「僕は英雄になりたかった」'), findsOneWidget);
    expect(find.text('間話「鎧」'), findsNothing);

    _expectCardUnder(tester, 'i1.png', 1);
    _expectCardUnder(tester, 'i2.png', 3);
    for (final String src in <String>['p3.png', 'p4.png', 'p5.png']) {
      _expectCardUnder(tester, src, 5);
    }

    // 单图查看器顶栏的章名也跟着走。
    await tester.tap(_card('i2.png'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('fushi_gallery_viewer')),
        matching: find.text('第七話'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('当前阅读位置按目录项判：读在第七話就标第七話那一节', (WidgetTester tester) async {
    final EpubBook book = _book();
    final List<TtuTocEntry> toc = _tocOf(book);
    await _pumpGallery(
      tester,
      book: book,
      toc: toc,
      currentChapter: 1,
      currentCharOffset: toc[3].charOffsetInChapter + 1,
    );

    expect(find.text('Current reading position'), findsOneWidget);
    final double badgeTop =
        tester.getTopLeft(find.text('Current reading position')).dy;
    final double headerTop = _headerTop(tester, _tocSection(3));
    // 徽标画在第七話节头那一行上，而不是同一 xhtml 的第五話。
    expect((badgeTop - headerTop).abs(), lessThan(44));
  });

  testWidgets('当前话没有插图：标记条插在第五話与第七話之间', (WidgetTester tester) async {
    final EpubBook book = _book();
    final List<TtuTocEntry> toc = _tocOf(book);
    await _pumpGallery(
      tester,
      book: book,
      toc: toc,
      currentChapter: 1,
      currentCharOffset: toc[2].charOffsetInChapter + 1,
    );

    expect(find.text('Current reading position'), findsOneWidget);
    final double markerTop =
        tester.getTopLeft(find.text('Current reading position')).dy;
    expect(markerTop, greaterThan(_headerTop(tester, _tocSection(1))));
    expect(markerTop, lessThan(_headerTop(tester, _tocSection(3))));
  });
}
