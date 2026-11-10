// 反馈 sYPkmtitOM「跟随原书」：书本自带的排版方向 / 翻页方向只从 OPF 元数据取
// （spine page-progression-direction、primary-writing-mode）。本测试锁两层：
//   ① BookOriginalLayout.resolve 的映射规则（纯函数）；
//   ② EpubParser 从真实 OPF 把两项元数据读进 EpubBook，originalLayout 与 ① 一致。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/book_original_layout.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';

void main() {
  group('BookOriginalLayout.resolve', () {
    test('什么都没声明 → none（全部回落全局设置）', () {
      final BookOriginalLayout layout = BookOriginalLayout.resolve();
      expect(layout, BookOriginalLayout.none);
      expect(layout.isEmpty, isTrue);
    });

    test('只有 page-progression-direction=rtl（日文竖排书的典型写法）→ 竖排 + rtl', () {
      expect(
        BookOriginalLayout.resolve(
          pageProgressionDirection: 'rtl',
          language: 'ja',
        ),
        const BookOriginalLayout(
          writingMode: 'vertical-rl',
          spreadDirection: 'rtl',
        ),
      );
    });

    test('只有 page-progression-direction=ltr → 横排 + ltr', () {
      expect(
        BookOriginalLayout.resolve(
          pageProgressionDirection: 'LTR',
          language: 'ja',
        ),
        const BookOriginalLayout(
          writingMode: 'horizontal-tb',
          spreadDirection: 'ltr',
        ),
      );
    });

    test('rtl 但正文是阿拉伯文 / 希伯来文 → 横排 + rtl（不误判成竖排）', () {
      for (final String lang in <String>['ar', 'he-IL', 'fa_IR']) {
        expect(
          BookOriginalLayout.resolve(
            pageProgressionDirection: 'rtl',
            language: lang,
          ),
          const BookOriginalLayout(
            writingMode: 'horizontal-tb',
            spreadDirection: 'rtl',
          ),
          reason: lang,
        );
      }
    });

    test('page-progression-direction=default 等非法值视同未声明', () {
      expect(
        BookOriginalLayout.resolve(pageProgressionDirection: 'default'),
        BookOriginalLayout.none,
      );
    });

    test('primary-writing-mode 决定文字方向，且优先于 page-progression-direction', () {
      expect(
        BookOriginalLayout.resolve(primaryWritingMode: 'vertical-rl'),
        const BookOriginalLayout(
          writingMode: 'vertical-rl',
          spreadDirection: 'rtl',
        ),
      );
      expect(
        BookOriginalLayout.resolve(primaryWritingMode: 'horizontal-lr'),
        const BookOriginalLayout(
          writingMode: 'horizontal-tb',
          spreadDirection: 'ltr',
        ),
      );
      // Kindle 的 horizontal-rl：横排正文、从右往左翻。
      expect(
        BookOriginalLayout.resolve(primaryWritingMode: 'horizontal-rl'),
        const BookOriginalLayout(
          writingMode: 'horizontal-tb',
          spreadDirection: 'rtl',
        ),
      );
      // 横排书声明了 rtl 翻页：文字方向听 primary-writing-mode，页序听 spine。
      expect(
        BookOriginalLayout.resolve(
          primaryWritingMode: 'horizontal-lr',
          pageProgressionDirection: 'rtl',
        ),
        const BookOriginalLayout(
          writingMode: 'horizontal-tb',
          spreadDirection: 'rtl',
        ),
      );
    });

    test('阅读器不支持的 vertical-lr：文字方向不覆盖，页序照 spine', () {
      expect(
        BookOriginalLayout.resolve(
          primaryWritingMode: 'vertical-lr',
          pageProgressionDirection: 'ltr',
        ),
        const BookOriginalLayout(spreadDirection: 'ltr'),
      );
    });
  });

  group('EpubParser 读出原书排版元数据', () {
    late Directory extractDir;

    setUp(() {
      extractDir = Directory.systemTemp.createTempSync('epub_layout_test_');
    });

    tearDown(() {
      if (extractDir.existsSync()) {
        extractDir.deleteSync(recursive: true);
      }
    });

    EpubBook parse({String spineAttrs = '', String extraMeta = ''}) {
      return EpubParser.parseSync(
        _buildEpub(spineAttrs: spineAttrs, extraMeta: extraMeta),
        extractDir.path,
      );
    }

    test('spine page-progression-direction="rtl" → 竖排 + rtl', () {
      final EpubBook book = parse(
        spineAttrs: ' page-progression-direction="rtl"',
      );
      expect(book.pageProgressionDirection, 'rtl');
      expect(book.primaryWritingMode, isNull);
      expect(
        book.originalLayout,
        const BookOriginalLayout(
          writingMode: 'vertical-rl',
          spreadDirection: 'rtl',
        ),
      );
    });

    test('spine page-progression-direction="ltr" → 横排 + ltr', () {
      final EpubBook book = parse(
        spineAttrs: ' page-progression-direction="ltr"',
      );
      expect(
        book.originalLayout,
        const BookOriginalLayout(
          writingMode: 'horizontal-tb',
          spreadDirection: 'ltr',
        ),
      );
    });

    test('EPUB 3.0 <meta property="primary-writing-mode">', () {
      final EpubBook book = parse(
        extraMeta: '<meta property="primary-writing-mode">vertical-rl</meta>',
      );
      expect(book.primaryWritingMode, 'vertical-rl');
      expect(book.originalLayout.writingMode, 'vertical-rl');
    });

    test('Kindle 式 <meta name="primary-writing-mode" content>', () {
      final EpubBook book = parse(
        spineAttrs: ' page-progression-direction="rtl"',
        extraMeta:
            '<meta name="primary-writing-mode" content="horizontal-rl"/>',
      );
      expect(book.primaryWritingMode, 'horizontal-rl');
      expect(
        book.originalLayout,
        const BookOriginalLayout(
          writingMode: 'horizontal-tb',
          spreadDirection: 'rtl',
        ),
      );
    });

    test('什么都没写 / page-progression-direction="default" → none', () {
      expect(parse().originalLayout, BookOriginalLayout.none);
      final EpubBook book = parse(
        spineAttrs: ' page-progression-direction="default"',
      );
      expect(book.pageProgressionDirection, isNull);
      expect(book.originalLayout, BookOriginalLayout.none);
    });
  });
}

Uint8List _buildEpub({required String spineAttrs, required String extraMeta}) {
  final String opf =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="uid">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:identifier id="uid">urn:uuid:layout-test</dc:identifier>'
      '<dc:title>テスト</dc:title>'
      '<dc:language>ja</dc:language>'
      '$extraMeta'
      '</metadata>'
      '<manifest>'
      '<item id="c1" href="text/chapter-1.xhtml" '
      'media-type="application/xhtml+xml"/>'
      '</manifest>'
      '<spine$spineAttrs><itemref idref="c1"/></spine>'
      '</package>';
  const String container =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
      'version="1.0"><rootfiles>'
      '<rootfile full-path="content.opf" '
      'media-type="application/oebps-package+xml"/>'
      '</rootfiles></container>';
  const String chapter =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>一</title></head>'
      '<body><p>本文。</p></body></html>';
  final Archive archive = Archive()
    ..addFile(_textFile('META-INF/container.xml', container))
    ..addFile(_textFile('content.opf', opf))
    ..addFile(_textFile('text/chapter-1.xhtml', chapter));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

ArchiveFile _textFile(String name, String content) {
  final List<int> bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}
