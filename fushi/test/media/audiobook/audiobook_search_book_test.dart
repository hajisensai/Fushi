import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:path/path.dart' as p;

// c40 novel-14：书内搜索以前首搜时在 UI isolate 上逐章读 `chapter.html`（lazy 章节
// 一读就常驻在章节对象里），缓存再按 html 字符串的对象同一性判新旧。现在 UI
// isolate 不碰正文：lazy 章节只把路径交给后台 isolate 自读，缓存按显式的章内容
// 版本号（`discardCachedHtml` 一次加一）判新旧、只重算变了的章。

String _chapter(String body) =>
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head>'
    '<body><p>$body</p></body></html>';

void main() {
  late Directory dir;
  late EpubBook book;

  File file(int i) => File(p.join(dir.path, 'chapter-$i.xhtml'));

  setUp(() {
    dir = Directory.systemTemp.createTempSync('audiobook_search_');
    file(0).writeAsStringSync(_chapter('吾輩は猫である。'));
    file(1).writeAsStringSync(_chapter('名前はまだ無い。'));
    file(2).writeAsStringSync(_chapter('猫と犬。'));
    book = EpubBook(
      title: 't',
      chapters: <EpubChapter>[
        for (int i = 0; i < 3; i++)
          EpubChapter.lazy(
            id: 'c$i',
            href: 'chapter-$i.xhtml',
            mediaType: 'application/xhtml+xml',
            filePath: file(i).path,
          ),
      ],
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('首搜不在 UI isolate 读章节正文，也不把正文留在章节对象里', () async {
    final List<BookSearchResult> results = await AudiobookBridge.searchBook(
      book,
      '猫',
    );
    expect(results.map((BookSearchResult r) => r.sectionIndex).toList(), <int>[
      0,
      2,
    ]);
    expect(results.first.context, contains('吾輩は猫である'));

    // 搜索之后改盘上文件：章节对象若在搜索时读进并缓存了正文，这里读到的还是
    // 旧内容。
    file(0).writeAsStringSync(_chapter('書き換えた本文'));
    expect(book.chapters[0].html, contains('書き換えた本文'));
  });

  test('缓存按章内容版本号判新旧，只重算版本变了的章', () async {
    expect(
      (await AudiobookBridge.searchBook(
        book,
        '猫',
      )).map((BookSearchResult r) => r.sectionIndex),
      <int>[0, 2],
    );

    // 第 0 章被换掉并按约定 discardCachedHtml；第 2 章盘上也改了但没人通知。
    file(0).writeAsStringSync(_chapter('もう犬しかいない。'));
    file(2).writeAsStringSync(_chapter('鳥。'));
    final int before = book.chapters[0].contentVersion;
    book.chapters[0].discardCachedHtml();
    expect(book.chapters[0].contentVersion, before + 1);

    // 第 0 章按新正文重算（不再命中「猫」），第 2 章版本没变、沿用缓存。
    expect(
      (await AudiobookBridge.searchBook(
        book,
        '猫',
      )).map((BookSearchResult r) => r.sectionIndex),
      <int>[2],
    );
    expect(
      (await AudiobookBridge.searchBook(
        book,
        '犬',
      )).map((BookSearchResult r) => r.sectionIndex),
      <int>[0, 2],
    );
  });

  test('eager 章节（没有盘上文件）照常可搜', () async {
    final EpubBook eager = EpubBook(
      title: 't',
      chapters: <EpubChapter>[
        EpubChapter(
          id: 'a',
          href: 'a',
          mediaType: 'application/xhtml+xml',
          html: _chapter('メモリ上の猫'),
        ),
      ],
    );
    final List<BookSearchResult> results = await AudiobookBridge.searchBook(
      eager,
      '猫',
    );
    expect(results.single.sectionIndex, 0);
    expect(results.single.charOffset, 'メモリ上の'.length);
  });
}
