import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:fushi_engine/media/audiobook/text_to_epub.dart';

import '../../helpers/epub_zip_reader.dart';
import '../../helpers/event_loop_stall.dart';

// ── helpers ──────────────────────────────────────────────────────────────────

Future<EpubZipReader> _convertText(
  Directory dir,
  String content, {
  String name = 'input.txt',
  String title = 'テスト本',
  String? author,
}) async {
  final File file = File('${dir.path}/$name');
  file.writeAsStringSync(content);
  final bytes = await TextToEpub.convert(
    file: file,
    title: title,
    author: author,
  );
  return EpubZipReader(bytes);
}

// ── tests ────────────────────────────────────────────────────────────────────

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('text_to_epub_test_');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  test('isSupported accepts known extensions and rejects others', () {
    expect(TextToEpub.isSupported('a.txt'), isTrue);
    expect(TextToEpub.isSupported('a.md'), isTrue);
    expect(TextToEpub.isSupported('a.HTML'), isTrue);
    expect(TextToEpub.isSupported('a.epub'), isFalse);
    expect(TextToEpub.isSupported('a.mp3'), isFalse);
  });

  test(
    'mimetype is the first entry, stored, with the EPUB media type',
    () async {
      final reader = await _convertText(tmpDir, 'こんにちは。\n\n二段落目。');
      expect(reader.firstEntry, 'mimetype');
      expect(reader.firstEntryMethod, 0); // STORE per EPUB spec
      expect(reader['mimetype'], 'application/epub+zip');
    },
  );

  test('container structure and OPF metadata are generated', () async {
    final reader = await _convertText(
      tmpDir,
      'こんにちは。',
      title: 'A & B <C>',
      author: "O'Brien",
    );
    expect(
      reader.names,
      containsAll(<String>{
        'META-INF/container.xml',
        'OEBPS/content.opf',
        'OEBPS/toc.ncx',
        'OEBPS/nav.xhtml',
        'OEBPS/chapter-1.xhtml',
      }),
    );
    expect(
      reader['META-INF/container.xml'],
      contains('full-path="OEBPS/content.opf"'),
    );

    final String opf = reader['OEBPS/content.opf']!;
    // Identity prefix distinguishes text-generated books; must stay stable.
    expect(opf, contains('<dc:identifier id="uid">fushi-text-'));
    expect(opf, contains('<dc:title>A &amp; B &lt;C&gt;</dc:title>'));
    expect(opf, contains('<dc:creator>O&apos;Brien</dc:creator>'));
    expect(opf, contains('<itemref idref="chapter-1"/>'));
  });

  test(
    'plain text paragraphs become <p>, single newlines become <br/>',
    () async {
      final reader = await _convertText(tmpDir, '一行目\n二行目\n\n次の段落');
      final String chapter = reader['OEBPS/chapter-1.xhtml']!;
      expect(chapter, contains('<p>一行目<br/>二行目</p>'));
      expect(chapter, contains('<p>次の段落</p>'));
    },
  );

  test('markdown headings map to <hN>', () async {
    final reader = await _convertText(
      tmpDir,
      '# 見出し\n\n本文です。',
      name: 'input.md',
    );
    final String chapter = reader['OEBPS/chapter-1.xhtml']!;
    expect(chapter, contains('<h1>見出し</h1>'));
    expect(chapter, contains('<p>本文です。</p>'));
  });

  test('html input keeps only body content', () async {
    final reader = await _convertText(
      tmpDir,
      '<html><head><title>t</title></head>'
      '<body><p>中身</p></body></html>',
      name: 'input.html',
    );
    final String chapter = reader['OEBPS/chapter-1.xhtml']!;
    expect(chapter, contains('<p>中身</p>'));
    expect(chapter, isNot(contains('<title>t</title>')));
  });

  test(
    'long input splits into multiple chapters at paragraph boundaries',
    () async {
      // Build > kMaxCharsPerChapter of HTML from many paragraphs.
      final String para = '${'あ' * 200}。';
      final String content = List<String>.filled(
        200,
        para,
      ).join('\n\n'); // ~40k chars of <p>
      final reader = await _convertText(tmpDir, content);

      expect(reader.names, contains('OEBPS/chapter-1.xhtml'));
      expect(reader.names, contains('OEBPS/chapter-2.xhtml'));

      final String opf = reader['OEBPS/content.opf']!;
      expect(opf, contains('<itemref idref="chapter-2"/>'));
      // NCX and nav must list every chapter.
      final int chapterCount = reader.names
          .where((n) => n.startsWith('OEBPS/chapter-'))
          .length;
      expect(
        RegExp('<navPoint ').allMatches(reader['OEBPS/toc.ncx']!).length,
        chapterCount,
      );
      expect(
        RegExp('<li>').allMatches(reader['OEBPS/nav.xhtml']!).length,
        chapterCount,
      );
    },
  );

  // 反馈 f2k9m1oU0j：剪贴板文本不落临时文件，直接走内存入口；与读文件入口
  // 同一套解析（txt = 段落 / <br/>，XML 转义）。
  test('convertText converts in-memory plain text like a .txt file', () {
    final EpubZipReader reader = EpubZipReader(
      TextToEpub.convertText(
        content: '﻿一行目\r\n二行目\r\n\r\n<タグ> & 次',
        title: '貼り付け',
      ),
    );
    final String chapter = reader['OEBPS/chapter-1.xhtml']!;
    expect(chapter, contains('<p>一行目<br/>二行目</p>'));
    expect(chapter, contains('<p>&lt;タグ&gt; &amp; 次</p>'));
    expect(reader['OEBPS/content.opf'], contains('<dc:title>貼り付け</dc:title>'));
  });
  // c40 novel-14：切章 + XHTML 拼装 + ZIP 压缩与输入大小成正比，以前整段在调用方
  // （UI）isolate 上同步跑，几 MB 的 TXT 导入时界面卡住。自校准：先量同样的
  // 输入在本 isolate 同步转换的耗时 D，再断言经 convert 入口时本 isolate 最长的
  // 一段卡顿不到 D 的一半，且产物（除 OPF 里的生成时间戳）与同步转换相同。
  test('convert does the heavy assembly off the calling isolate', () async {
    final StringBuffer text = StringBuffer();
    for (int i = 0; i < 60000; i++) {
      text
        ..write('第$i段。吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。')
        ..write(i.isEven ? '\n' : '\n\n');
    }
    final String content = text.toString();
    final File file = File('${tmpDir.path}/big.txt')
      ..writeAsStringSync(content);

    late Uint8List syncBytes;
    final Duration syncCost = measureSync(() {
      syncBytes = TextToEpub.convertText(content: content, title: '大きい本');
    });
    expect(
      syncCost,
      greaterThan(const Duration(milliseconds: 40)),
      reason: '输入要大到同步转换有可测的耗时，否则断言没有区分力',
    );

    final ({Uint8List result, Duration maxStall}) measured =
        await measureEventLoopStall(
          () => TextToEpub.convert(file: file, title: '大きい本'),
        );
    expect(
      measured.maxStall,
      lessThan(syncCost ~/ 2),
      reason: 'sync=$syncCost stall=${measured.maxStall}',
    );
    // OPF 里带生成时间戳，其余条目（各章正文、目录）必须与同步转换一致。
    final EpubZipReader background = EpubZipReader(measured.result);
    final EpubZipReader reference = EpubZipReader(syncBytes);
    expect(background.names, reference.names);
    expect(background.names.length, greaterThan(10));
    for (final String name in reference.names) {
      if (name == 'OEBPS/content.opf') continue;
      expect(background[name], reference[name], reason: name);
    }
  });
}
