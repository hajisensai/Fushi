import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:path/path.dart' as p;

void main() {
  group('EpubParser.parseSync', () {
    late Directory extractDir;

    setUp(() {
      extractDir = Directory.systemTemp.createTempSync('epub_parser_test_');
    });

    tearDown(() {
      if (extractDir.existsSync()) {
        extractDir.deleteSync(recursive: true);
      }
    });

    test('treats file-like parent entries as directories when children exist',
        () {
      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF', ''),
        _textFile('META-INF/container.xml', _containerXml),
        _textFile('OEBPS/content.opf', _contentOpf),
        _textFile('OEBPS/chapter.xhtml', _chapterXhtml),
      ]);

      final EpubBook book = EpubParser.parseSync(bytes, extractDir.path);

      expect(book.title, 'Directory Placeholder Book');
      expect(book.chapters, hasLength(1));
      expect(
        FileSystemEntity.typeSync(p.join(extractDir.path, 'META-INF')),
        FileSystemEntityType.directory,
      );
    });

    test(
        'percent-encoded TOC hrefs resolve to non-ASCII chapter files '
        '(HBK-AUDIT-010)', () {
      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF/container.xml', _containerXml),
        _textFile('OEBPS/content.opf', _opfWithNav),
        _textFile('OEBPS/nav.xhtml', _navXhtmlEncoded),
        _textFile('OEBPS/第1章.xhtml', _chapterXhtml),
      ]);

      final EpubBook book = EpubParser.parseSync(bytes, extractDir.path);

      expect(book.chapters, hasLength(1));
      expect(book.toc, isNotEmpty);
      // The nav href is the percent-encoded form (%E7%AC%AC1%E7%AB%A0.xhtml)
      // but must resolve to the same decoded href as the chapter.
      expect(book.toc.first.href, book.chapters.first.href);
    });

    test('non-UTF-8 chapter bytes do not crash the parse (HBK-AUDIT-033)', () {
      final List<int> malformed = <int>[
        ...utf8.encode('<?xml version="1.0"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>'),
        0x82, 0xA0, // lone Shift_JIS-style bytes: invalid as standalone UTF-8
        ...utf8.encode('</p></body></html>'),
      ];
      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF/container.xml', _containerXml),
        _textFile('OEBPS/content.opf', _contentOpf),
        _binFile('OEBPS/chapter.xhtml', malformed),
      ]);

      // Strict utf8 decoding would throw FormatException and abort the import;
      // the parser must degrade gracefully instead.
      final EpubBook book = EpubParser.parseSync(bytes, extractDir.path);
      expect(book.chapters, hasLength(1));
    });
  });
}

Uint8List _encodeArchive(List<ArchiveFile> files) {
  final Archive archive = Archive();
  for (final ArchiveFile file in files) {
    archive.addFile(file);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

ArchiveFile _textFile(String name, String content) {
  final List<int> bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

ArchiveFile _binFile(String name, List<int> bytes) =>
    ArchiveFile(name, bytes.length, bytes);

const String _opfWithNav = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Encoded TOC Book</dc:title>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ch1" href="第1章.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
  </spine>
</package>
''';

const String _navXhtmlEncoded = '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <body>
    <nav epub:type="toc">
      <ol><li><a href="%E7%AC%AC1%E7%AB%A0.xhtml">Chapter 1</a></li></ol>
    </nav>
  </body>
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

const String _contentOpf = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Directory Placeholder Book</dc:title>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="chapter"/>
  </spine>
</package>
''';

const String _chapterXhtml = '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body><p>Hello.</p></body>
</html>
''';
