import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:path/path.dart' as p;

void main() {
  group('EpubParser rejects path traversal in archive entries', () {
    late Directory extractDir;

    setUp(() {
      extractDir = Directory.systemTemp.createTempSync('epub_traversal_test_');
    });

    tearDown(() {
      if (extractDir.existsSync()) {
        extractDir.deleteSync(recursive: true);
      }
    });

    test('archive entry with ../ does not escape extract directory', () {
      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF/container.xml', _containerXml),
        _textFile('OEBPS/content.opf', _contentOpf),
        _textFile('OEBPS/chapter.xhtml', _chapterXhtml),
        _textFile('../escape.txt', 'should not be extracted'),
      ]);

      EpubParser.parseSync(bytes, extractDir.path);

      final String escapePath =
          p.normalize(p.join(extractDir.path, '..', 'escape.txt'));
      expect(File(escapePath).existsSync(), isFalse);
    });

    test('sibling prefix collision entry is not treated as child', () {
      final String siblingDir = '${extractDir.path}_evil';
      addTearDown(() {
        final Directory d = Directory(siblingDir);
        if (d.existsSync()) d.deleteSync(recursive: true);
      });

      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF/container.xml', _containerXml),
        _textFile('OEBPS/content.opf', _contentOpf),
        _textFile('OEBPS/chapter.xhtml', _chapterXhtml),
      ]);

      EpubParser.parseSync(bytes, extractDir.path);

      expect(Directory(siblingDir).existsSync(), isFalse);
    });

    test('legitimate nested path is extracted normally', () {
      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF/container.xml', _containerXml),
        _textFile('OEBPS/content.opf', _contentOpf),
        _textFile('OEBPS/chapter.xhtml', _chapterXhtml),
      ]);

      final book = EpubParser.parseSync(bytes, extractDir.path);

      expect(book.chapters, hasLength(1));
      final String chapterPath =
          p.join(extractDir.path, 'OEBPS', 'chapter.xhtml');
      expect(File(chapterPath).existsSync(), isTrue);
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
    <dc:title>Traversal Test Book</dc:title>
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
  <body><p>Test content.</p></body>
</html>
''';
