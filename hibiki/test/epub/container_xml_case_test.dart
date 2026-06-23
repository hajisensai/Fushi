import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:path/path.dart' as p;

/// TODO-739: cross-device book download failed with
/// `FormatException: Invalid EPUB: missing META-INF/container.xml`.
///
/// Two complementary fixes, both guarded here:
///  1. extraction-side (treats the cause): `_safeArchivePath` now writes the
///     archive entry with its ORIGINAL case (it used `p.canonicalize`, which
///     lower-cases on Windows). The zip-slip boundary check is preserved —
///     covered by `path_traversal_test.dart` plus the absolute-path case below.
///  2. lookup-side (rescues legacy data): `parseFromExtracted` now finds
///     `META-INF/container.xml` case-insensitively, so books already extracted
///     to a lower-cased `meta-inf/` by older builds still open after a
///     re-extraction on a case-sensitive filesystem.
void main() {
  late Directory extractDir;

  setUp(() {
    extractDir = Directory.systemTemp.createTempSync('epub_case_test_');
  });

  tearDown(() {
    if (extractDir.existsSync()) {
      extractDir.deleteSync(recursive: true);
    }
  });

  void writeContainer(String metaInfDirName) {
    final Directory metaInf = Directory(p.join(extractDir.path, metaInfDirName))
      ..createSync();
    File(p.join(metaInf.path, 'container.xml'))
        .writeAsStringSync(_containerXml);
    final Directory oebps = Directory(p.join(extractDir.path, 'OEBPS'))
      ..createSync();
    File(p.join(oebps.path, 'content.opf')).writeAsStringSync(_contentOpf);
    File(p.join(oebps.path, 'chapter.xhtml')).writeAsStringSync(_chapterXhtml);
  }

  group('parseFromExtracted finds container.xml case-insensitively', () {
    test('spec-correct upper-case META-INF parses', () {
      writeContainer('META-INF');
      final book = EpubParser.parseFromExtracted(extractDir.path);
      expect(book.chapters, hasLength(1));
    });

    test('legacy lower-case meta-inf (Windows regression) still parses', () {
      writeContainer('meta-inf');
      final book = EpubParser.parseFromExtracted(extractDir.path);
      expect(book.chapters, hasLength(1),
          reason: 'legacy lower-cased meta-inf/container.xml must still parse');
    });

    test('mixed-case Meta-Inf with lower-case Container.xml parses', () {
      final Directory metaInf = Directory(p.join(extractDir.path, 'Meta-Inf'))
        ..createSync();
      File(p.join(metaInf.path, 'Container.xml'))
          .writeAsStringSync(_containerXml);
      final Directory oebps = Directory(p.join(extractDir.path, 'OEBPS'))
        ..createSync();
      File(p.join(oebps.path, 'content.opf')).writeAsStringSync(_contentOpf);
      File(p.join(oebps.path, 'chapter.xhtml'))
          .writeAsStringSync(_chapterXhtml);

      final book = EpubParser.parseFromExtracted(extractDir.path);
      expect(book.chapters, hasLength(1));
    });

    test('genuinely missing container.xml still throws FormatException', () {
      Directory(p.join(extractDir.path, 'META-INF')).createSync();
      expect(
        () => EpubParser.parseFromExtracted(extractDir.path),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('extraction preserves archive entry case (TODO-739 cause)', () {
    test('upper-case META-INF entry lands on disk with its original case', () {
      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF/container.xml', _containerXml),
        _textFile('OEBPS/content.opf', _contentOpf),
        _textFile('OEBPS/chapter.xhtml', _chapterXhtml),
      ]);

      EpubParser.parseSync(bytes, extractDir.path);

      final List<String> topLevel = Directory(extractDir.path)
          .listSync()
          .map((FileSystemEntity e) => p.basename(e.path))
          .toList();
      expect(topLevel, contains('META-INF'),
          reason: 'extraction must NOT lower-case META-INF on disk');
      expect(topLevel, isNot(contains('meta-inf')));
    });
  });

  group('zip-slip protection survives the case-preserving rewrite', () {
    test('absolute-path archive entry does not escape extractDir', () {
      final String evilName =
          Platform.isWindows ? 'C:/Windows/evil_739.txt' : '/tmp/evil_739.txt';
      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF/container.xml', _containerXml),
        _textFile('OEBPS/content.opf', _contentOpf),
        _textFile('OEBPS/chapter.xhtml', _chapterXhtml),
        _textFile(evilName, 'should never be written'),
      ]);

      EpubParser.parseSync(bytes, extractDir.path);

      final String evilTarget =
          Platform.isWindows ? 'C:/Windows/evil_739.txt' : '/tmp/evil_739.txt';
      expect(File(evilTarget).existsSync(), isFalse);
    });

    test('deep ../ traversal entry does not escape extractDir', () {
      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF/container.xml', _containerXml),
        _textFile('OEBPS/content.opf', _contentOpf),
        _textFile('OEBPS/chapter.xhtml', _chapterXhtml),
        _textFile('../../../escape_739.txt', 'should never be written'),
      ]);

      EpubParser.parseSync(bytes, extractDir.path);

      final String parent = p.dirname(extractDir.path);
      expect(File(p.join(parent, 'escape_739.txt')).existsSync(), isFalse);
      expect(
          File(p.normalize(
                  p.join(extractDir.path, '..', '..', '..', 'escape_739.txt')))
              .existsSync(),
          isFalse);
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
    <dc:title>Case Test Book</dc:title>
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
