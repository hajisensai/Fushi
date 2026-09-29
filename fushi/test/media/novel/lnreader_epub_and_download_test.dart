import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/media/novel/online/lnreader_epub_assembler.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:xml/xml.dart';

/// 1×1 PNG。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

Archive _unzip(Uint8List bytes) => ZipDecoder().decodeBytes(bytes);

String _entry(Archive archive, String name) =>
    utf8.decode(archive.findFile(name)!.content as List<int>);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LnReaderEpubAssembler', () {
    Uint8List build() => LnReaderEpubAssembler.build(
      title: 'とんでもスキル & 異世界',
      languageTag: 'ja',
      identifier: 'lnreader:yomou.syosetu:/n2710db/',
      author: '江口　連',
      description: '<b>あらすじ</b>',
      cover: (fileName: 'cover.png', bytes: _png, mediaType: 'image/png'),
      chapters: <LnReaderEpubChapter>[
        (
          title: '第一話　勇者召喚',
          xhtmlBody: '<p>俺の名前は<ruby>向田剛志<rt>むこうだつよし</rt></ruby>。</p>',
          images: const <LnReaderEpubImage>[],
        ),
        (
          title: '第二話 <挿絵>',
          xhtmlBody: '<h1>第二話</h1><p><img src="images/c2-0.png" alt=""/></p>',
          images: <LnReaderEpubImage>[
            (fileName: 'images/c2-0.png', bytes: _png, mediaType: 'image/png'),
          ],
        ),
      ],
    );

    test('章节标题进目录，所有 XML 良构，封面与插图进 manifest', () {
      final Archive archive = _unzip(build());
      expect(archive.files.first.name, 'mimetype');
      for (final ArchiveFile file in archive.files) {
        if (file.name.endsWith('.xhtml') ||
            file.name.endsWith('.opf') ||
            file.name.endsWith('.ncx') ||
            file.name.endsWith('.xml')) {
          expect(
            () => XmlDocument.parse(_entry(archive, file.name)),
            returnsNormally,
            reason: '${file.name} 必须是良构 XML（阅读器按 XHTML 解析）。',
          );
        }
      }
      final String nav = _entry(archive, 'OEBPS/nav.xhtml');
      expect(nav, contains('第一話　勇者召喚'));
      expect(nav, contains('第二話 &lt;挿絵&gt;'));
      final String opf = _entry(archive, 'OEBPS/content.opf');
      expect(opf, contains('properties="cover-image"'));
      expect(opf, contains('href="images/c2-0.png"'));
      expect(opf, contains('<dc:language>ja</dc:language>'));
      expect(opf, contains('<dc:creator>江口　連</dc:creator>'));
      expect(archive.findFile('OEBPS/images/c2-0.png'), isNotNull);
    });

    test('正文自带标题时不重复补标题；没有时补一个', () {
      final Archive archive = _unzip(build());
      final String first = _entry(archive, 'OEBPS/chapter-1.xhtml');
      final String second = _entry(archive, 'OEBPS/chapter-2.xhtml');
      expect(first, contains('<h2>第一話　勇者召喚</h2>'));
      expect(second, isNot(contains('<h2>')));
      expect(first, contains('<ruby>向田剛志<rt>むこうだつよし</rt></ruby>'));
    });

    group('真实导入', () {
      late Directory root;
      late FushiDatabase db;

      setUp(() {
        root = Directory.systemTemp.createTempSync('lnreader_epub_');
        EpubStorage.debugBaseDirectoryOverride = root.path;
        db = FushiDatabase.forTesting(NativeDatabase.memory());
      });

      tearDown(() async {
        await db.close();
        EpubStorage.debugBaseDirectoryOverride = null;
        root.deleteSync(recursive: true);
      });

      testWidgets('产物能被既有 EPUB 导入管线吃下，章数与封面都在', (WidgetTester tester) async {
        late String key;
        await tester.runAsync(() async {
          key = await EpubImporter.import(
            db: db,
            bytes: build(),
            fileName: 'novel.epub',
          );
        });
        final EpubBookRow? row = await db.getEpubBook(key);
        expect(row, isNotNull);
        expect(row!.chapterCount, 2);
        expect(row.coverPath, isNotNull);
      });
    });
  });

  test('图片类型按魔数判，认不出的丢弃', () {
    expect(sniffLnReaderImageMediaType(_png), 'image/png');
    expect(
      sniffLnReaderImageMediaType(
        Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0]),
      ),
      'image/jpeg',
    );
    expect(
      sniffLnReaderImageMediaType(Uint8List.fromList(utf8.encode('<html>'))),
      isNull,
    );
  });

  test('失败插图的引用从 XHTML 摘掉；简介 HTML 转纯文本', () {
    expect(
      removeLnReaderImageReference(
        '<p>a<img src="images/c1-0.jpg" alt=""/>b</p>',
        'images/c1-0.jpg',
      ),
      '<p>ab</p>',
    );
    expect(stripLnReaderHtml('一行<br>二行&amp;<p>三</p>'), '一行\n二行&三');
  });

  test('语言本地名 → BCP 47', () {
    expect(lnReaderLanguageTag('日本語'), 'ja');
    expect(lnReaderLanguageTag('中文, 汉语, 漢語'), 'zh');
    expect(lnReaderLanguageTag('English'), 'en');
    expect(lnReaderLanguageTag('Klingon'), 'und');
  });

  test('分页目录合并：保序、按 path 去重', () {
    const LnReaderChapter a = LnReaderChapter(name: 'a', path: '/a');
    const LnReaderChapter b = LnReaderChapter(name: 'b', path: '/b');
    const LnReaderChapter c = LnReaderChapter(name: 'c', path: '/c');
    expect(
      mergeLnReaderChapterPages(<List<LnReaderChapter>>[
        <LnReaderChapter>[a, b],
        <LnReaderChapter>[b, c],
      ]).map((LnReaderChapter e) => e.path),
      <String>['/a', '/b', '/c'],
    );
  });

  test('筛选器解析与传给插件的形态', () {
    final List<LnReaderFilter> filters = LnReaderFilter.parseAll(
      <String, Object?>{
        'ranking': <String, Object?>{
          'type': 'Picker',
          'label': 'Ranked by',
          'value': 'total',
          'options': <Object?>[
            <String, Object?>{'label': '日間', 'value': 'daily'},
          ],
        },
        'genres': <String, Object?>{
          'type': 'XCheckbox',
          'label': 'G',
          'value': <String, Object?>{},
        },
        'weird': <String, Object?>{'type': 'Unknown', 'label': 'x', 'value': 1},
      },
    );
    expect(filters.map((LnReaderFilter f) => f.key), <String>[
      'ranking',
      'genres',
    ]);
    expect(
      lnReaderFilterValues(<LnReaderFilter>[
        filters.first.withValue('daily'),
        filters.last,
      ]),
      <String, Object?>{
        'ranking': <String, Object?>{'type': 'Picker', 'value': 'daily'},
        'genres': <String, Object?>{
          'type': 'XCheckbox',
          'value': <String, List<String>>{
            'include': <String>[],
            'exclude': <String>[],
          },
        },
      },
    );
  });
}
