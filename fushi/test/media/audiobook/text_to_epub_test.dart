import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:fushi_engine/media/audiobook/text_to_epub.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

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

String _textWithBreaks(XmlNode node) {
  if (node is XmlText) return node.value;
  if (node is XmlElement && node.name.local == 'br') return '\n';
  return node.children.map(_textWithBreaks).join();
}

/// Reads every bounded XHTML chapter in order and returns the text of each
/// paragraph-level block ([blockName]; `<br/>` read as LF). Checks the size
/// contract on the raw body HTML and that every chapter is well-formed XML.
List<String> _readBoundedBlocks(
  EpubZipReader reader, {
  String blockName = 'p',
}) {
  final int chapterCount = reader.names
      .where((String name) => name.startsWith('OEBPS/chapter-'))
      .length;
  expect(chapterCount, greaterThan(1));
  final List<String> blocks = <String>[];
  for (int i = 1; i <= chapterCount; i++) {
    final String name = 'OEBPS/chapter-$i.xhtml';
    final String chapter = reader[name]!;
    // Exclude the wrapper's opening LF, but retain all body HTML code units,
    // including the paragraph's trailing LF, when checking the size contract.
    final String bodyHtml = RegExp(
      r'<body>\n([\s\S]*?)</body>',
    ).firstMatch(chapter)!.group(1)!;
    expect(
      bodyHtml.length,
      lessThanOrEqualTo(TextToEpub.kMaxCharsPerChapter),
      reason: '$name must not contain an oversized body',
    );
    // XML parsing catches broken escapes/tags; the decoded text equality also
    // catches surrogate pairs replaced during the EPUB's UTF-8 encoding.
    final XmlDocument document = XmlDocument.parse(chapter);
    final XmlElement body = document.descendants
        .whereType<XmlElement>()
        .singleWhere((XmlElement element) => element.name.local == 'body');
    for (final XmlElement block in body.descendants.whereType<XmlElement>()) {
      if (block.name.local != blockName) continue;
      final String text = _textWithBreaks(block);
      expect(
        text.startsWith('\n'),
        isFalse,
        reason: '$name: a split block must not start with <br/>',
      );
      blocks.add(text);
    }
  }
  return blocks;
}

/// Asserts [blocks] reassemble [content] exactly. A split that lands on a
/// source line break absorbs that one LF into the block boundary; with
/// [cutsOnlyAtNewlines] every split must land on one (no mid-line splits).
void _expectReassembles(
  List<String> blocks,
  String content, {
  bool cutsOnlyAtNewlines = false,
}) {
  int pos = 0;
  for (int i = 0; i < blocks.length; i++) {
    final String block = blocks[i];
    expect(
      content.startsWith(block, pos),
      isTrue,
      reason: 'block $i must continue the source text at $pos',
    );
    pos += block.length;
    if (i == blocks.length - 1) break;
    if (pos < content.length && content[pos] == '\n') {
      pos++;
    } else if (cutsOnlyAtNewlines) {
      fail('block $i was split mid-line at $pos');
    }
  }
  expect(pos, content.length, reason: 'no source text may be lost');
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
    'malformed html with a self-closing <script/> keeps the body (BUG-2017)',
    () async {
      // 不良构（<br> 未闭合）→ 走 HTML5 回退；head 里 kobo 式自闭合 <script/> 不能把
      // 整个 <body> 吞成脚本文本。
      final reader = await _convertText(
        tmpDir,
        '<html><head><script src="kobo.js"/></head>'
        '<body><p>一行目<br>二行目</p></body></html>',
        name: 'input.html',
      );
      final String chapter = reader['OEBPS/chapter-1.xhtml']!;
      expect(chapter, contains('一行目'));
      expect(chapter, contains('二行目'));
      expect(chapter, isNot(contains('kobo.js')));
    },
  );

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

  test('750 KiB TXT with only single newlines has bounded chapters', () async {
    // Each line is 119 UTF-8 bytes; join LFs and the final ASCII byte make
    // exactly 750 KiB without introducing any blank-line paragraph breaks.
    final String line = '${'日' * 39}ab';
    final String content = '${List<String>.filled(6400, line).join('\n')}z';
    expect(utf8.encode(content).length, 750 * 1024);
    expect(content, isNot(contains('\n\n')));

    final EpubZipReader reader = await _convertText(tmpDir, content);

    final List<String> blocks = _readBoundedBlocks(reader);
    // Every split lands on an original line break: no sentence is cut.
    _expectReassembles(blocks, content, cutsOnlyAtNewlines: true);
    for (final String block in blocks) {
      for (final String l in block.split('\n')) {
        expect(l == line || l == '${line}z', isTrue, reason: l);
      }
    }
  });

  test('one long paragraph without newlines has bounded chapters', () async {
    final String content = 'あ' * (TextToEpub.kMaxCharsPerChapter * 3 + 17);

    final EpubZipReader reader = await _convertText(tmpDir, content);

    _expectReassembles(_readBoundedBlocks(reader), content);
  });

  test(
    'chapter boundaries preserve escapes, line breaks and non-BMP text',
    () async {
      const String special = '&<>"\'😀𠮷\n続';
      // Slide the escaped/non-BMP sequence across every possible code-unit
      // boundary in its HTML representation, including entity, br and surrogate
      // interiors. The source is one paragraph, so decoded chunks must join
      // exactly with no added whitespace or replacement characters.
      for (int offset = 0; offset < 40; offset++) {
        final String content =
            '${'あ' * (TextToEpub.kMaxCharsPerChapter - 8 - offset)}'
            '$special'
            '${'い' * (TextToEpub.kMaxCharsPerChapter + 17)}';
        final EpubZipReader reader = await _convertText(
          tmpDir,
          content,
          name: 'boundary-$offset.txt',
        );

        _expectReassembles(_readBoundedBlocks(reader), content);
      }
    },
  );

  test(
    'markdown paragraph with single newlines splits only at lines',
    () async {
      final String line = '${'本' * 50}。';
      final String content =
          '# 見出し\n\n${List<String>.filled(1500, line).join('\n')}';

      final EpubZipReader reader = await _convertText(
        tmpDir,
        content,
        name: 'long.md',
      );

      expect(reader['OEBPS/chapter-1.xhtml'], contains('<h1>見出し</h1>'));
      _expectReassembles(
        _readBoundedBlocks(reader),
        content.substring('# 見出し\n\n'.length),
        cutsOnlyAtNewlines: true,
      );
    },
  );

  test('html with one oversized block splits inside the block', () async {
    final String line = '${'字' * 50}。';
    final List<String> lines = List<String>.filled(1500, line);
    final String content =
        '<html><head><title>t</title></head><body>'
        '<div class="c"><p>${lines.join('<br>')}</p></div>'
        '</body></html>';

    final EpubZipReader reader = await _convertText(
      tmpDir,
      content,
      name: 'long.html',
    );

    // Malformed HTML (<br> unclosed) is re-serialised as well-formed XHTML and
    // the split block keeps its full ancestor chain in every chapter.
    final int chapterCount = reader.names
        .where((String name) => name.startsWith('OEBPS/chapter-'))
        .length;
    for (int i = 1; i <= chapterCount; i++) {
      expect(
        reader['OEBPS/chapter-$i.xhtml'],
        contains('<div class="c"><p>'),
        reason: 'chapter $i',
      );
    }
    _expectReassembles(
      _readBoundedBlocks(reader),
      lines.join('\n'),
      cutsOnlyAtNewlines: true,
    );
  });

  // HBK-AUDIT-003：HTML 允许省略 <body>（甚至 <head>）标签，正文由 HTML 的隐含
  // body 规则确定。这类输入恰好也是良构 XML 时，以前 XML 路径找不到 <body> 就把
  // 根 <html> 的全部子节点丢掉，导出一本只有空段落的书。
  test(
    'well-formed html with omitted <body> keeps content and anchors',
    () async {
      final EpubZipReader reader = await _convertText(
        tmpDir,
        '<!DOCTYPE html>\n<html><head><title>題名</title>'
        '<style>p{color:red}</style></head>\n'
        '<p id="s1">一段目</p><p>二段<a id="n1"/>目</p></html>',
        name: 'input.html',
      );
      final String chapter = reader['OEBPS/chapter-1.xhtml']!;
      expect(chapter, contains('<p id="s1">一段目</p>'));
      expect(chapter, contains('<p>二段<a id="n1"></a>目</p>'));
      expect(chapter, isNot(contains('題名')));
      expect(chapter, isNot(contains('color:red')));
      XmlDocument.parse(chapter);
    },
  );

  test(
    'well-formed html with omitted <head> and <body> drops head content only',
    () async {
      final EpubZipReader reader = await _convertText(
        tmpDir,
        '<html><title>題名</title><meta charset="utf-8"/>'
        '<link rel="stylesheet" href="a.css"/>'
        '前文<p id="s1">本文</p><script>var x;</script></html>',
        name: 'input.xhtml',
      );
      final String chapter = reader['OEBPS/chapter-1.xhtml']!;
      final String body = RegExp(
        r'<body>\n([\s\S]*)</body>',
      ).firstMatch(chapter)!.group(1)!;
      // head 类元素只在正文开始前归 head；首个文本 / 正文元素起其余全归 body
      // （与 HTML5 树构建一致，body 里的 <script> 照旧留在 body）。
      expect(body, '前文<p id="s1">本文</p><script>var x;</script>');
    },
  );

  // 同一条 HTML body 规则下，<body> 标签在场也不能只取它的子节点：浏览器把
  // <body> 前（head 之后）、</body> 后、以及 <head> 里非 head 元素起的内容都
  // 归进正文（结果与 HTML5 解析器 parse(...).body 逐一核对过）。
  test('well-formed html keeps body content outside the <body> tags', () async {
    const String input =
        '<html><head><title>題名</title><p id="h">頭</p></head>'
        '<noframes>nf</noframes><p id="b">前</p>'
        '<body><p id="m">中</p></body><p id="a">後</p></html>';
    const String expected =
        '<p id="h">頭</p><noframes>nf</noframes><p id="b">前</p>'
        '<p id="m">中</p><p id="a">後</p>';
    // 期望值就是浏览器（HTML5 树构建）给出的 body。
    expect(html_parser.parse(input).body!.innerHtml, expected);
    final EpubZipReader reader = await _convertText(
      tmpDir,
      input,
      name: 'input.xhtml',
    );
    final String chapter = reader['OEBPS/chapter-1.xhtml']!;
    final String body = RegExp(
      r'<body>\n([\s\S]*)</body>',
    ).firstMatch(chapter)!.group(1)!;
    expect(body, expected);
  });

  test(
    'well-formed short html fragment without <html> keeps its anchor',
    () async {
      final EpubZipReader reader = await _convertText(
        tmpDir,
        '<p id="only">短い章<a id="end"/></p>',
        name: 'input.html',
      );
      final String chapter = reader['OEBPS/chapter-1.xhtml']!;
      expect(chapter, contains('<p id="only">短い章<a id="end"></a></p>'));
    },
  );

  test('well-formed xhtml keeps self-closed non-void elements empty', () async {
    final EpubZipReader reader = await _convertText(
      tmpDir,
      '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
      '<p><a id="p1"/>本文&amp;続き</p></body></html>',
      name: 'input.xhtml',
    );
    final String chapter = reader['OEBPS/chapter-1.xhtml']!;
    expect(chapter, contains('<p><a id="p1"></a>本文&amp;続き</p>'));
    XmlDocument.parse(chapter);
  });

  // c40 novel-14：切章 + XHTML 拼装 + ZIP 压缩与输入大小成正比，以前整段在调用方
  // （UI）isolate 上同步跑，几 MB 的 TXT 导入时界面卡住。自校准：先量同样的
  // 输入在本 isolate 同步转换的耗时 D，再断言经 convert 入口时本 isolate 最长的
  // 一段卡顿不到 D 的一半，且产物（除 OPF 里的生成时间戳）与同步转换相同。
  // 两边都取 kEventLoopStallSamples 次里的最小值滤掉并发负载下的抢占噪声；
  // convert 每次都重新读文件、重新转换，没有缓存。
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
    final Duration syncCost = measureMinSync(kEventLoopStallSamples, () {
      syncBytes = TextToEpub.convertText(content: content, title: '大きい本');
    });
    expect(
      syncCost,
      greaterThan(const Duration(milliseconds: 40)),
      reason: '输入要大到同步转换有可测的耗时，否则断言没有区分力',
    );

    final ({List<Uint8List> results, Duration minStall, List<Duration> stalls})
    measured = await measureMinEventLoopStall(
      kEventLoopStallSamples,
      (int run) => TextToEpub.convert(file: file, title: '大きい本'),
    );
    expect(
      measured.minStall,
      lessThan(syncCost ~/ 2),
      reason: 'sync=$syncCost stalls=${measured.stalls}',
    );
    // OPF 里带生成时间戳，其余条目（各章正文、目录）必须与同步转换一致。
    final EpubZipReader background = EpubZipReader(measured.results.last);
    final EpubZipReader reference = EpubZipReader(syncBytes);
    expect(background.names, reference.names);
    expect(background.names.length, greaterThan(10));
    for (final String name in reference.names) {
      if (name == 'OEBPS/content.opf') continue;
      expect(background[name], reference[name], reason: name);
    }
  });
}
