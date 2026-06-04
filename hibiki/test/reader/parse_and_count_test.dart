import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show parseAndCountChapters, ParsedBookData;

void main() {
  late Directory extractDir;

  setUp(() {
    extractDir = Directory.systemTemp.createTempSync('parse_and_count_test_');
    // Reuse the same extracted-directory fixture style as
    // test/epub/epub_parser_test.dart: encode an archive, then let parseSync
    // extract it into extractDir so parseFromExtracted has real files to read.
    final Uint8List bytes = _encodeArchive(<ArchiveFile>[
      _textFile('META-INF/container.xml', _containerXml),
      _textFile('OEBPS/content.opf', _contentOpf),
      _textFile('OEBPS/chapter1.xhtml', _chapter('First chapter body text.')),
      _textFile('OEBPS/chapter2.xhtml',
          _chapter('Second chapter has a different length of body text here.')),
    ]);
    EpubParser.parseSync(bytes, extractDir.path);
  });

  tearDown(() {
    if (extractDir.existsSync()) {
      extractDir.deleteSync(recursive: true);
    }
  });

  test('parseAndCountChapters 的字符数与逐章 chapterPlainText 等价', () {
    final ParsedBookData result = parseAndCountChapters(extractDir.path);
    final EpubBook book = EpubParser.parseFromExtracted(extractDir.path);

    expect(result.book.chapters.length, book.chapters.length);
    expect(result.book.chapters.length, greaterThan(1));

    final List<int> expected = List<int>.generate(
      book.chapters.length,
      (int i) => book.chapterPlainText(i).length,
    );
    expect(result.charCounts, expected);
    // Non-trivial counts: guards against an all-zero false equivalence.
    expect(expected.every((int c) => c > 0), isTrue);
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

String _chapter(String body) => '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
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

const String _contentOpf = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Two Chapter Book</dc:title>
  </metadata>
  <manifest>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>
''';
