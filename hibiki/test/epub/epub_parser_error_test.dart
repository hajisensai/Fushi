import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_parser.dart';

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

void main() {
  late Directory extractDir;

  setUp(() {
    extractDir = Directory.systemTemp.createTempSync('epub_error_test_');
  });

  tearDown(() {
    if (extractDir.existsSync()) {
      extractDir.deleteSync(recursive: true);
    }
  });

  group('EpubParser error handling', () {
    test('empty ZIP archive throws FormatException', () {
      final bytes = _encodeArchive([]);
      expect(
        () => EpubParser.parseSync(bytes, extractDir.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('container pointing to missing OPF throws FormatException', () {
      final bytes = _encodeArchive([
        _textFile(
          'META-INF/container.xml',
          '<?xml version="1.0"?>'
              '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">'
              '<rootfiles><rootfile full-path="missing.opf" media-type="application/oebps-package+xml"/></rootfiles>'
              '</container>',
        ),
      ]);
      expect(
        () => EpubParser.parseSync(bytes, extractDir.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('malformed container.xml throws FormatException', () {
      final bytes = _encodeArchive([
        _textFile('META-INF/container.xml', 'not xml at all {{{'),
      ]);
      expect(
        () => EpubParser.parseSync(bytes, extractDir.path),
        throwsA(isA<Exception>()),
      );
    });

    test('OPF with empty spine throws FormatException about no chapters', () {
      final bytes = _encodeArchive([
        _textFile(
          'META-INF/container.xml',
          '<?xml version="1.0"?>'
              '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">'
              '<rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>'
              '</container>',
        ),
        _textFile(
          'content.opf',
          '<?xml version="1.0"?>'
              '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
              '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
              '<dc:title>Empty Spine</dc:title></metadata>'
              '<manifest></manifest>'
              '<spine></spine>'
              '</package>',
        ),
      ]);

      expect(
        () => EpubParser.parseSync(bytes, extractDir.path),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('no readable chapters'),
        )),
      );
    });

    test('manifest item pointing to missing file throws FormatException', () {
      final bytes = _encodeArchive([
        _textFile(
          'META-INF/container.xml',
          '<?xml version="1.0"?>'
              '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">'
              '<rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>'
              '</container>',
        ),
        _textFile(
          'content.opf',
          '<?xml version="1.0"?>'
              '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
              '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
              '<dc:title>Missing Chapter</dc:title></metadata>'
              '<manifest>'
              '<item id="ch1" href="ghost.xhtml" media-type="application/xhtml+xml"/>'
              '</manifest>'
              '<spine><itemref idref="ch1"/></spine>'
              '</package>',
        ),
      ]);

      expect(
        () => EpubParser.parseSync(bytes, extractDir.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('random bytes (not a ZIP) throws ArchiveException', () {
      final garbage = Uint8List.fromList(List.generate(100, (i) => i % 256));
      expect(
        () => EpubParser.parseSync(garbage, extractDir.path),
        throwsA(isA<Exception>()),
      );
    });

    test('valid EPUB with one chapter parses correctly', () {
      final bytes = _encodeArchive([
        _textFile(
          'META-INF/container.xml',
          '<?xml version="1.0"?>'
              '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">'
              '<rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>'
              '</container>',
        ),
        _textFile(
          'content.opf',
          '<?xml version="1.0"?>'
              '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
              '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
              '<dc:title>Good Book</dc:title></metadata>'
              '<manifest>'
              '<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
              '</manifest>'
              '<spine><itemref idref="ch1"/></spine>'
              '</package>',
        ),
        _textFile(
          'ch1.xhtml',
          '<html><body><p>Hello World</p></body></html>',
        ),
      ]);

      final book = EpubParser.parseSync(bytes, extractDir.path);
      expect(book.title, 'Good Book');
      expect(book.chapters, hasLength(1));
    });
  });
}
