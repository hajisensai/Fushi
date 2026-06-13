import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:path/path.dart' as p;

/// TODO-296 / BUG-270: lazy chapter parsing guard.
///
/// Open-book must NOT slurp every spine chapter's XHTML into memory at parse
/// time; chapter bodies are read + decoded from disk on first [EpubChapter.html]
/// access and cached. These tests assert both that lazy reads return the exact
/// on-disk content (so audiobook alignment / search / spread analysis stay
/// correct) and that the read genuinely happens at access time, not parse time.
void main() {
  late Directory extractDir;

  setUp(() {
    extractDir = Directory.systemTemp.createTempSync('epub_lazy_test_');
  });

  tearDown(() {
    if (extractDir.existsSync()) {
      extractDir.deleteSync(recursive: true);
    }
  });

  Uint8List encodeArchive(List<ArchiveFile> files) {
    final Archive archive = Archive();
    for (final ArchiveFile file in files) {
      archive.addFile(file);
    }
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  ArchiveFile textFile(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    return ArchiveFile(name, bytes.length, bytes);
  }

  test('lazy chapter html returns exact on-disk content', () {
    final EpubBook book = EpubParser.parseSync(
      encodeArchive(<ArchiveFile>[
        textFile('META-INF/container.xml', _containerXml),
        textFile('OEBPS/content.opf', _twoChapterOpf),
        textFile('OEBPS/ch1.xhtml', _chapter('第一章<ruby>漢<rt>かん</rt></ruby>')),
        textFile('OEBPS/ch2.xhtml', _chapter('第二章 本文')),
      ]),
      extractDir.path,
    );

    expect(book.chapters, hasLength(2));
    // The html getter pulls the same bytes the structure parse left on disk.
    expect(book.chapters[0].html, contains('第一章'));
    expect(book.chapters[1].html, contains('第二章 本文'));
    // chapterPlainText (audiobook-alignment path) reads via the lazy getter and
    // still strips ruby annotations correctly.
    expect(book.chapterPlainText(0), '第一章漢');
    expect(book.chapterPlainText(1), '第二章 本文');
  });

  test('chapter html is read lazily, not eagerly at parse time', () {
    final EpubBook book = EpubParser.parseSync(
      encodeArchive(<ArchiveFile>[
        textFile('META-INF/container.xml', _containerXml),
        textFile('OEBPS/content.opf', _twoChapterOpf),
        textFile('OEBPS/ch1.xhtml', _chapter('eager check ch1')),
        textFile('OEBPS/ch2.xhtml', _chapter('eager check ch2')),
      ]),
      extractDir.path,
    );

    // Read chapter 0 -> caches it in memory.
    expect(book.chapters[0].html, contains('eager check ch1'));

    // Delete chapter 1's backing file AFTER parse but BEFORE first access. If
    // the parser had eagerly slurped it, the content would survive in memory.
    // Lazy reads it at access time, so a missing file degrades to '' — proving
    // the spine parse did NOT read it.
    File(p.join(extractDir.path, 'OEBPS', 'ch2.xhtml')).deleteSync();
    expect(book.chapters[1].html, isEmpty);

    // Chapter 0 stays available from its cache (read before deletion / kept).
    expect(book.chapters[0].html, contains('eager check ch1'));
  });

  test('lazy html is cached after first read (stable across reads)', () {
    final EpubBook book = EpubParser.parseSync(
      encodeArchive(<ArchiveFile>[
        textFile('META-INF/container.xml', _containerXml),
        textFile('OEBPS/content.opf', _twoChapterOpf),
        textFile('OEBPS/ch1.xhtml', _chapter('cache me')),
        textFile('OEBPS/ch2.xhtml', _chapter('other')),
      ]),
      extractDir.path,
    );

    final String first = book.chapters[0].html;
    // Remove the file after the cache is populated; the cached value must hold.
    File(p.join(extractDir.path, 'OEBPS', 'ch1.xhtml')).deleteSync();
    final String second = book.chapters[0].html;
    expect(second, first);
    expect(second, contains('cache me'));
  });

  test('eager EpubChapter still serves in-memory html (DB/legacy fallback)',
      () {
    final EpubChapter eager = EpubChapter(
      id: 'x',
      href: 'x.xhtml',
      mediaType: 'text/html',
      html: '<p>inline</p>',
    );
    expect(eager.html, '<p>inline</p>');
  });
}

String _chapter(String body) => '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>c</title></head>
  <body><p>$body</p></body>
</html>
''';

const String _containerXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

const String _twoChapterOpf = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Lazy Book</dc:title>
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>
''';
