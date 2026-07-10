import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

Uint8List _minimalEpub(String title) {
  final Archive archive = Archive();
  void add(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');
  add('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="chapter"/>
  </spine>
</package>
''');
  add('OEBPS/chapter.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body><p>Hello.</p></body>
</html>
''');

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EpubImporter', () {
    late Directory tempRoot;
    late HibikiDatabase db;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('epub_importer_');
      EpubStorage.debugBaseDirectoryOverride = tempRoot.path;
      db = _memDb();
    });

    tearDown(() async {
      await db.close();
      EpubStorage.debugBaseDirectoryOverride = null;
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    testWidgets('replaces an unreferenced non-empty destination directory',
        (WidgetTester tester) async {
      const String title = '謎解きはディナーのあとで';
      final File epub = File(p.join(tempRoot.path, 'book.epub'))
        ..writeAsBytesSync(_minimalEpub(title));

      final String orphanDir = await EpubStorage.bookDirectory(
        sanitizeTtuFilename(title),
      );
      File(p.join(orphanDir, 'stale.txt')).writeAsStringSync('stale');

      await tester.runAsync(() async {
        final String key = await EpubImporter.importFromPath(
          db: db,
          filePath: epub.path,
          fileName: p.basename(epub.path),
        );
        expect(key, sanitizeTtuFilename(title));
      });

      final EpubBookRow? row = await db.getEpubBook(sanitizeTtuFilename(title));
      expect(row, isNotNull);
      expect(File(p.join(orphanDir, 'stale.txt')).existsSync(), isFalse);
      expect(File(p.join(orphanDir, 'META-INF', 'container.xml')).existsSync(),
          isTrue);
    });
  });
}
