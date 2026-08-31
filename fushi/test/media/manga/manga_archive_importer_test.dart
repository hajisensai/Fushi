import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_storage.dart';
import 'package:fushi/src/media/manga/import/manga_archive_importer.dart';
import 'package:fushi/src/media/manga/manga_storage.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory app;
  late FushiDatabase db;

  setUp(() {
    root = Directory.systemTemp.createTempSync('manga_archive_');
    app = Directory.systemTemp.createTempSync('manga_archive_app_');
    EpubStorage.debugBaseDirectoryOverride = app.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
    if (app.existsSync()) app.deleteSync(recursive: true);
  });

  test('CBZ images import in natural order', () async {
    final Uint8List png =
        Uint8List.fromList(img.encodePng(img.Image(width: 40, height: 80)));
    final String path = _writeArchive(
      root,
      <ArchiveFile>[
        ArchiveFile('10.png', png.length, png),
        ArchiveFile('2.png', png.length, png),
        ArchiveFile('1.png', png.length, png),
      ],
    );
    final String key = await MangaArchiveImporter.importArchive(
      db: db,
      archivePath: path,
    );
    final EpubBookRow row = (await db.getEpubBook(key))!;
    final String json =
        File(p.join(row.extractDir, MangaStorage.kMangaJsonFileName))
            .readAsStringSync();
    expect(
        json.indexOf('images/1.png'), lessThan(json.indexOf('images/2.png')));
    expect(
        json.indexOf('images/2.png'), lessThan(json.indexOf('images/10.png')));
  });

  test('RAR images import through 7-Zip with path and size preflight',
      () async {
    final Uint8List png =
        Uint8List.fromList(img.encodePng(img.Image(width: 40, height: 80)));
    final String archivePath = p.join(root.path, 'book.rar');
    File(archivePath).writeAsBytesSync(<int>[0x52, 0x61, 0x72, 0x21]);
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'RAR manga',
        mediaKind: 'manga',
        rootPath: root.path,
        createdAt: 1000,
      ),
    );
    final List<List<String>> calls = <List<String>>[];
    final MangaSevenZipExtractor extractor = MangaSevenZipExtractor(
      sevenZipOverride: 'fake-7z',
      runProcess: (String executable, List<String> arguments) async {
        calls.add(arguments);
        if (arguments.first == 'l') {
          return ProcessResult(1, 0, '''
Path = $archivePath
Type = Rar

----------
Path = pages\\001.png
Size = ${png.length}
Attributes = A

Path = notes.txt
Size = 5000000000
Attributes = A
''', '');
        }
        final String outputArg =
            arguments.firstWhere((String arg) => arg.startsWith('-o'));
        final File page = File(p.join(outputArg.substring(2), 'pages', '001.png'));
        page.parent.createSync(recursive: true);
        page.writeAsBytesSync(png);
        return ProcessResult(2, 0, '', '');
      },
    );

    final String key = await MangaArchiveImporter.importArchive(
      db: db,
      archivePath: archivePath,
      sourceId: sourceId,
      sevenZipExtractor: extractor,
    );

    expect((await db.getEpubBook(key))!.sourceId, sourceId);
    expect(calls.map((List<String> args) => args.first), <String>['l', 'x']);
    expect(calls.last, contains('-ir!*.png'));
  });

  test('RAR traversal is rejected before extraction', () async {
    final String archivePath = p.join(root.path, 'unsafe.cbr');
    File(archivePath).writeAsBytesSync(<int>[0x52, 0x61, 0x72, 0x21]);
    bool extracted = false;
    final MangaSevenZipExtractor extractor = MangaSevenZipExtractor(
      sevenZipOverride: 'fake-7z',
      runProcess: (String executable, List<String> arguments) async {
        if (arguments.first == 'l') {
          return ProcessResult(1, 0, '''
Path = $archivePath
Type = Rar

----------
Path = ..\\escape.png
Size = 3
Attributes = A
''', '');
        }
        extracted = true;
        return ProcessResult(2, 0, '', '');
      },
    );

    await expectLater(
      MangaArchiveImporter.importArchive(
        db: db,
        archivePath: archivePath,
        sevenZipExtractor: extractor,
      ),
      throwsA(isA<MangaImportException>()),
    );
    expect(extracted, isFalse);
    expect(await db.getAllEpubBooks(), isEmpty);
  });

  test('rejects traversal before extracting any archive entry', () async {
    final String path = _writeArchive(
      root,
      <ArchiveFile>[
        ArchiveFile('../escape.png', 3, <int>[1, 2, 3])
      ],
    );
    await expectLater(
      MangaArchiveImporter.importArchive(db: db, archivePath: path),
      throwsA(isA<MangaImportException>()),
    );
    expect(File(p.join(root.parent.path, 'escape.png')).existsSync(), isFalse);
    expect(await db.getAllEpubBooks(), isEmpty);
  });

  test('pure image EPUB imports in spine order', () async {
    final Uint8List first = Uint8List.fromList(
      img.encodePng(img.Image(width: 20, height: 40)),
    );
    final Uint8List second = Uint8List.fromList(
      img.encodePng(img.Image(width: 30, height: 40)),
    );
    final String path = _writeImageEpub(
      root,
      first: first,
      second: second,
      firstSpineId: 'page2',
    );
    expect(MangaArchiveImporter.looksLikeImageArchive(path), isTrue);

    final String key = await MangaArchiveImporter.importArchive(
      db: db,
      archivePath: path,
    );
    final EpubBookRow row = (await db.getEpubBook(key))!;
    final img.Image importedFirst = img.decodeImage(
      File(p.join(row.extractDir, 'images', 'page_000000.png'))
          .readAsBytesSync(),
    )!;
    expect(importedFirst.width, 30);
  });

  test('EPUB containing a text spine page stays a normal EPUB', () {
    final Uint8List png =
        Uint8List.fromList(img.encodePng(img.Image(width: 20, height: 40)));
    final String path = _writeImageEpub(
      root,
      first: png,
      second: png,
      firstSpineId: 'page1',
      page1Body: '<p>これは画像だけではない本文ページです。</p>',
    );
    expect(MangaArchiveImporter.looksLikeImageArchive(path), isFalse);
  });
}

String _writeArchive(Directory root, List<ArchiveFile> entries) {
  final Archive archive = Archive();
  for (final ArchiveFile entry in entries) {
    archive.addFile(entry);
  }
  final String path = p.join(root.path, 'book.cbz');
  File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
  return path;
}

String _writeImageEpub(
  Directory root, {
  required Uint8List first,
  required Uint8List second,
  required String firstSpineId,
  String page1Body = '<img src="../images/1.png"/>',
}) {
  final String secondSpineId = firstSpineId == 'page1' ? 'page2' : 'page1';
  final Map<String, List<int>> entries = <String, List<int>>{
    'META-INF/container.xml': utf8.encode('''
<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
</container>'''),
    'OEBPS/content.opf': utf8.encode('''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Image EPUB</dc:title>
  </metadata>
  <manifest>
    <item id="page1" href="text/1.xhtml" media-type="application/xhtml+xml"/>
    <item id="page2" href="text/2.xhtml" media-type="application/xhtml+xml"/>
    <item id="image1" href="images/1.png" media-type="image/png"/>
    <item id="image2" href="images/2.png" media-type="image/png"/>
  </manifest>
  <spine>
    <itemref idref="$firstSpineId"/>
    <itemref idref="$secondSpineId"/>
  </spine>
</package>'''),
    'OEBPS/text/1.xhtml': utf8.encode(
      '<html xmlns="http://www.w3.org/1999/xhtml"><body>$page1Body</body></html>',
    ),
    'OEBPS/text/2.xhtml': utf8.encode(
      '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
      '<img src="../images/2.png"/></body></html>',
    ),
    'OEBPS/images/1.png': first,
    'OEBPS/images/2.png': second,
  };
  final Archive archive = Archive();
  entries.forEach((String name, List<int> bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  final String path = p.join(root.path, 'book.epub');
  File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
  return path;
}
