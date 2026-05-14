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
