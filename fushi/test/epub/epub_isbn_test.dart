import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_isbn_backfill.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/epub/isbn.dart';
import 'package:path/path.dart' as p;

/// v114：`epub_books.isbn`——OPF `dc:identifier` → 规范化 ISBN-13 → 导入落库 /
/// 存量回填。

const String _container = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

const String _chapter = '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body><p>Hello.</p></body>
</html>
''';

String _opf(String title, String identifiers, {String extraMeta = ''}) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
    $identifiers
    $extraMeta
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="chapter"/>
  </spine>
</package>
''';

/// 在 [dir] 下写一棵最小的已解压 EPUB 树。
void _writeExtracted(String dir, String opf) {
  Directory(p.join(dir, 'META-INF')).createSync(recursive: true);
  Directory(p.join(dir, 'OEBPS')).createSync(recursive: true);
  File(p.join(dir, 'META-INF', 'container.xml')).writeAsStringSync(_container);
  File(p.join(dir, 'OEBPS', 'content.opf')).writeAsStringSync(opf);
  File(p.join(dir, 'OEBPS', 'chapter.xhtml')).writeAsStringSync(_chapter);
}

Uint8List _epubBytes(String opf) {
  final Archive archive = Archive();
  void add(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', _container);
  add('OEBPS/content.opf', opf);
  add('OEBPS/chapter.xhtml', _chapter);
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  group('normalizeIsbn13', () {
    test('accepts prefixed / hyphenated ISBN-13 and ISBN-10', () {
      expect(normalizeIsbn13('978-4-06-159299-5'), '9784061592995');
      expect(normalizeIsbn13('urn:isbn:9780306406157'), '9780306406157');
      expect(normalizeIsbn13('URN:ISBN:978-0-306-40615-7'), '9780306406157');
      expect(normalizeIsbn13('ISBN-13: 978 0 306 40615 7'), '9780306406157');
      expect(normalizeIsbn13('9791234567896'), '9791234567896');
      // ISBN-10 → ISBN-13（重算 EAN 校验位），含末位 X。
      expect(normalizeIsbn13('4061592998'), '9784061592995');
      expect(normalizeIsbn13('isbn:4-06-159299-8'), '9784061592995');
      expect(normalizeIsbn13('ISBN 0-8044-2957-X'), '9780804429573');
      expect(normalizeIsbn13('080442957x'), '9780804429573');
    });

    test('rejects bad check digits and non-ISBN identifiers', () {
      expect(normalizeIsbn13('9780306406158'), isNull, reason: '校验位错');
      expect(normalizeIsbn13('0306406153'), isNull, reason: 'ISBN-10 校验位错');
      expect(
        normalizeIsbn13('1234567890128'),
        isNull,
        reason: 'EAN-13 合法但不是 978/979 书号',
      );
      expect(
        normalizeIsbn13('urn:uuid:12345678-1234-1234-1234-123456789012'),
        isNull,
      );
      expect(normalizeIsbn13('X061592998'), isNull, reason: 'X 只能在末位');
      expect(normalizeIsbn13('978-4-06-159299-5 (pbk)'), isNull);
      expect(normalizeIsbn13(''), isNull);
    });
  });

  group('EpubParser ISBN', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('epub_isbn_parse_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    String? parseIsbn(String identifiers, {String extraMeta = ''}) {
      final String dir = p.join(
        tempRoot.path,
        'b${tempRoot.listSync().length}',
      );
      _writeExtracted(dir, _opf('T', identifiers, extraMeta: extraMeta));
      final EpubBook book = EpubParser.parseFromExtracted(dir);
      // 轻量只读 OPF 的回填入口与完整解析同一口径。
      expect(EpubParser.readIsbnFromExtracted(dir), book.isbn);
      return book.isbn;
    }

    test('EPUB 2 opf:scheme="ISBN"', () {
      expect(
        parseIsbn(
          '<dc:identifier id="book-id">urn:uuid:abc</dc:identifier>'
          '<dc:identifier opf:scheme="ISBN">4-06-159299-8</dc:identifier>',
        ),
        '9784061592995',
      );
    });

    test('urn:isbn: identifier', () {
      expect(
        parseIsbn(
          '<dc:identifier id="book-id">urn:isbn:9780306406157'
          '</dc:identifier>',
        ),
        '9780306406157',
      );
    });

    test('EPUB 3 identifier-type refines (ONIX 15)', () {
      expect(
        parseIsbn(
          '<dc:identifier id="book-id">9780306406157</dc:identifier>',
          extraMeta:
              '<meta refines="#book-id" property="identifier-type" '
              'scheme="onix:codelist5">15</meta>',
        ),
        '9780306406157',
      );
    });

    test('bare hyphenated number with a valid check digit', () {
      expect(
        parseIsbn(
          '<dc:identifier id="book-id">978-4-06-159299-5'
          '</dc:identifier>',
        ),
        '9784061592995',
      );
    });

    test('explicit ISBN wins over an earlier bare number', () {
      expect(
        parseIsbn(
          '<dc:identifier id="a">9791234567896</dc:identifier>'
          '<dc:identifier id="b" opf:scheme="ISBN">0306406152'
          '</dc:identifier>',
        ),
        '9780306406157',
      );
    });

    test('invalid check digit / uuid only → null', () {
      expect(
        parseIsbn(
          '<dc:identifier id="book-id" opf:scheme="ISBN">'
          '9780306406158</dc:identifier>'
          '<dc:identifier>urn:uuid:1234</dc:identifier>',
        ),
        isNull,
      );
      expect(parseIsbn(''), isNull);
    });

    test('readIsbnFromExtracted: missing container → null', () {
      final Directory empty = Directory(p.join(tempRoot.path, 'empty'))
        ..createSync();
      expect(EpubParser.readIsbnFromExtracted(empty.path), isNull);
    });
  });

  group('import + backfill', () {
    late Directory tempRoot;
    late FushiDatabase db;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('epub_isbn_db_');
      EpubStorage.debugBaseDirectoryOverride = tempRoot.path;
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
      EpubStorage.debugBaseDirectoryOverride = null;
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    test('EpubImporter writes the normalized ISBN-13', () async {
      final File epub = File(p.join(tempRoot.path, 'book.epub'))
        ..writeAsBytesSync(
          _epubBytes(
            _opf(
              'ISBN Book',
              '<dc:identifier id="book-id" opf:scheme="ISBN">4061592998'
                  '</dc:identifier>',
            ),
          ),
        );
      final String key = await EpubImporter.importFromPath(
        db: db,
        filePath: epub.path,
        fileName: 'book.epub',
      );
      expect((await db.getEpubBook(key))!.isbn, '9784061592995');
    });

    test('EpubImporter leaves isbn NULL when the OPF has none', () async {
      final File epub = File(p.join(tempRoot.path, 'plain.epub'))
        ..writeAsBytesSync(
          _epubBytes(
            _opf(
              'Plain Book',
              '<dc:identifier id="book-id">urn:uuid:1234</dc:identifier>',
            ),
          ),
        );
      final String key = await EpubImporter.importFromPath(
        db: db,
        filePath: epub.path,
        fileName: 'plain.epub',
      );
      expect((await db.getEpubBook(key))!.isbn, isNull);
    });

    Future<void> insertBook(
      String key, {
      required String extractDir,
      String format = 'epub',
      String? isbn,
    }) => db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: '$key.epub',
        extractDir: extractDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 0,
        format: Value<String>(format),
        isbn: Value<String?>(isbn),
      ),
    );

    test(
      'backfillEpubIsbns reads only the OPF of books missing an ISBN',
      () async {
        final String withIsbn = p.join(tempRoot.path, 'x', 'with');
        _writeExtracted(
          withIsbn,
          _opf(
            'with',
            '<dc:identifier id="book-id">urn:isbn:0306406152'
                '</dc:identifier>',
          ),
        );
        final String without = p.join(tempRoot.path, 'x', 'without');
        _writeExtracted(
          without,
          _opf(
            'without',
            '<dc:identifier id="book-id">urn:uuid:1'
                '</dc:identifier>',
          ),
        );
        final String already = p.join(tempRoot.path, 'x', 'already');
        _writeExtracted(
          already,
          _opf(
            'already',
            '<dc:identifier id="book-id">urn:isbn:0306406152'
                '</dc:identifier>',
          ),
        );
        final String manga = p.join(tempRoot.path, 'x', 'manga');
        _writeExtracted(
          manga,
          _opf(
            'manga',
            '<dc:identifier id="book-id">urn:isbn:0306406152'
                '</dc:identifier>',
          ),
        );

        await insertBook('with', extractDir: withIsbn);
        await insertBook('without', extractDir: without);
        await insertBook('already', extractDir: already, isbn: '9784061592995');
        await insertBook('manga', extractDir: manga, format: 'manga');
        // 解压目录不在：只跳过这本，不影响其它书。
        await insertBook(
          'gone',
          extractDir: p.join(tempRoot.path, 'x', 'missing'),
        );
        // OPF 坏了：同样只跳过。
        final String broken = p.join(tempRoot.path, 'x', 'broken');
        _writeExtracted(broken, '<package><metadata>');
        await insertBook('broken', extractDir: broken);

        expect(await backfillEpubIsbns(db), 1);
        expect((await db.getEpubBook('with'))!.isbn, '9780306406157');
        expect((await db.getEpubBook('without'))!.isbn, isNull);
        expect(
          (await db.getEpubBook('already'))!.isbn,
          '9784061592995',
          reason: '已有值不被覆盖',
        );
        expect(
          (await db.getEpubBook('manga'))!.isbn,
          isNull,
          reason: '只回填 format=epub',
        );
        expect((await db.getEpubBook('gone'))!.isbn, isNull);
        expect((await db.getEpubBook('broken'))!.isbn, isNull);

        // 再跑一次：已回填的不再计数。
        expect(await backfillEpubIsbns(db), 0);
      },
    );
  });
}
