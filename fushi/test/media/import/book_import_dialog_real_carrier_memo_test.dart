import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/epub/epub_storage.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

Uint8List _realEpubBytes(String title, {bool pureImage = false}) {
  final Archive archive = Archive();

  void addText(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  addText('mimetype', 'application/epub+zip');
  addText('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0"
    xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf"
        media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');
  addText('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0"
    unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">todo-2189-$title</dc:identifier>
    <dc:title>$title</dc:title>
    <dc:language>ja</dc:language>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml"
        media-type="application/xhtml+xml"/>
    <item id="page" href="page.png" media-type="image/png"/>
  </manifest>
  <spine>
    <itemref idref="chapter"/>
  </spine>
</package>
''');
  addText('OEBPS/chapter.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body>
    ${pureImage ? '' : '<p>これは真の EPUB と字幕を通る回帰テストです。</p>'}
    <img src="page.png" alt="${pureImage ? '' : 'not a pure image manga'}"/>
  </body>
</html>
''');
  final List<int> png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  archive.addFile(ArchiveFile('OEBPS/page.png', png.length, png));

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Widget _host(BookImportDialog dialog) {
  return TranslationProvider(
    child: MaterialApp(
      home: Scaffold(body: Center(child: dialog)),
    ),
  );
}

Future<void> _pumpUntil(
  WidgetTester tester, {
  required Future<bool> Function() condition,
}) async {
  for (int attempt = 0; attempt < 200; attempt += 1) {
    final bool done = await tester.runAsync<bool>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return condition();
        }) ??
        false;
    await tester.pump();
    if (done) return;
  }
  fail('Timed out waiting for the real import path to finish');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('resolver reuses one real path and recomputes for another real path',
      () {
    final Directory root =
        Directory.systemTemp.createTempSync('todo_2189_real_path_cache_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final File first = File(p.join(root.path, 'first.epub'))
      ..writeAsBytesSync(_realEpubBytes('TODO 2189 first'));
    final File second = File(p.join(root.path, 'second.epub'))
      ..writeAsBytesSync(_realEpubBytes('TODO 2189 second'));
    final List<String> probedPaths = <String>[];
    final ImportCarrierResolver resolver = ImportCarrierResolver(
      isDirectory: (String path) => Directory(path).existsSync(),
      isImageArchive: (String path) {
        probedPaths.add(path);
        return MangaModule.isImageArchive(path);
      },
      directoryHasPageImages: MangaModule.directoryHasPageImages,
      directoryCarrierFileCount: MangaModule.directoryCarrierFileCount,
    );

    expect(resolver.resolve(first.path), ImportCarrier.epub);
    expect(resolver.resolve(first.path), ImportCarrier.epub);
    expect(resolver.resolve(second.path), ImportCarrier.epub);

    expect(probedPaths, <String>[first.path, second.path],
        reason: '同一路径只真开包一次，换真实路径必须重新调用真 MangaModule 判据');
  });

  testWidgets(
      'real EPUB + matching SRT imports through the real dialog with one '
      'image-archive probe', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1000);
    addTearDown(tester.view.reset);

    final Directory root =
        Directory.systemTemp.createTempSync('todo_2189_real_epub_srt_');
    final File epub = File(p.join(root.path, 'aligned.epub'))
      ..writeAsBytesSync(_realEpubBytes('TODO 2189 aligned'));
    final File srt = File(p.join(root.path, 'aligned.srt'))
      ..writeAsStringSync('''
1
00:00:00,000 --> 00:00:03,000
これは真の EPUB と字幕を通る回帰テストです。
''');
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    EpubStorage.debugBaseDirectoryOverride = root.path;
    AudiobookStorage.documentsRootResolver = () async => root;
    addTearDown(() async {
      EpubStorage.debugBaseDirectoryOverride = null;
      AudiobookStorage.documentsRootResolver = null;
      await db.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final List<String> probedPaths = <String>[];
    bool countThenRunRealProbe(String path) {
      probedPaths.add(path);
      return MangaModule.isImageArchive(path);
    }

    await tester.pumpWidget(
      _host(
        BookImportDialog(
          repo: SrtBookRepository(db),
          audiobookRepo: AudiobookRepository(db),
          db: db,
          initialEpubPath: epub.path,
          initialSubtitlePath: srt.path,
          imageArchiveProbe: countThenRunRealProbe,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text(t.dialog_import));
    await tester.pump();
    await _pumpUntil(
      tester,
      condition: () async {
        final List<EpubBookRow> books = await db.getAllEpubBooks();
        if (books.length != 1) return false;
        return AudiobookRepository(db)
            .findByBookKey(books.single.bookKey)
            .then((Audiobook? value) => value != null);
      },
    );

    expect(probedPaths, <String>[epub.path], reason: '同一路径的漫画误投闸门只能执行一次真整包判定');
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books, hasLength(1), reason: '必须由真 EpubImporter 完成导入');
    final Audiobook? audiobook =
        await AudiobookRepository(db).findByBookKey(books.single.bookKey);
    expect(audiobook, isNotNull,
        reason: 'EPUB+SRT 必须走 _importEpubWithAlignment 并落有声书对齐记录');
    final SrtBook? paired =
        await SrtBookRepository(db).findByBookKey(books.single.bookKey);
    expect(paired, isNotNull, reason: '匹配字幕必须落配对 SRT 书记录');
  });

  testWidgets('real EPUB-only import reuses the same probe at final dispatch',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1000);
    addTearDown(tester.view.reset);

    final Directory root =
        Directory.systemTemp.createTempSync('todo_2189_real_epub_only_');
    final File epub = File(p.join(root.path, 'plain.epub'))
      ..writeAsBytesSync(_realEpubBytes('TODO 2189 plain'));
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    EpubStorage.debugBaseDirectoryOverride = root.path;
    addTearDown(() async {
      EpubStorage.debugBaseDirectoryOverride = null;
      await db.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final List<String> probedPaths = <String>[];
    bool countThenRunRealProbe(String path) {
      probedPaths.add(path);
      return MangaModule.isImageArchive(path);
    }

    await tester.pumpWidget(
      _host(
        BookImportDialog(
          repo: SrtBookRepository(db),
          audiobookRepo: AudiobookRepository(db),
          db: db,
          initialEpubPath: epub.path,
          imageArchiveProbe: countThenRunRealProbe,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text(t.dialog_import));
    await tester.pump();
    await _pumpUntil(
      tester,
      condition: () async => (await db.getAllEpubBooks()).length == 1,
    );

    expect(probedPaths, <String>[epub.path],
        reason: '闸门与 _importEpubOnly 最终分派必须共用同一真实判定结果');
    expect(await db.getAllEpubBooks(), hasLength(1));
  });

  testWidgets(
      'dedicated manga dialog has no carrier confirmation while book '
      'misroute shows exactly one', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1000);
    addTearDown(tester.view.reset);
    final Directory root =
        Directory.systemTemp.createTempSync('todo_2189_manga_route_');
    final File manga = File(p.join(root.path, 'pages.epub'))
      ..writeAsBytesSync(
        _realEpubBytes('TODO 2189 manga', pureImage: true),
      );
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: MangaImportDialog(db: db, initialPath: manga.path),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text(t.manga_import_detected_title), findsNothing,
        reason: '漫画专用入口已知道载体，不得再弹书籍误投确认');
    expect(find.text(t.dialog_import), findsOneWidget);

    await tester.pumpWidget(
      _host(
        BookImportDialog(
          repo: SrtBookRepository(db),
          audiobookRepo: AudiobookRepository(db),
          db: db,
          initialEpubPath: manga.path,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text(t.dialog_import));
    await tester.pumpAndSettle();

    expect(find.text(t.manga_import_detected_title), findsOneWidget,
        reason: '书籍入口误投漫画必须保留一次明确安全确认');
    expect(find.text(t.manga_import_detected_confirm), findsOneWidget);
  });
}
