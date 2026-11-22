// 拍板 83Fe7zQbhv：书籍导入框收到「一包书」（装着 EPUB / TXT 的 zip）→ 转交批量导入框，
// 真 ArchiveUnpacker 解包、真 EpubImporter / TextToEpub 落库，结束只给一份汇总。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/import/book_archive_import_dialog.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/book_archive/book_archive_import.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

List<int> _epubBytes(String title) {
  final Archive archive = Archive();
  void add(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
''');
  add('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">$title</dc:identifier>
    <dc:title>$title</dc:title>
    <dc:language>ja</dc:language>
  </metadata>
  <manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="c"/></spine>
</package>
''');
  add('OEBPS/c.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>c</title></head>
<body><p>$title の本文です。</p></body></html>
''');
  return ZipEncoder().encode(archive)!;
}

Future<void> _pumpUntil(
  WidgetTester tester, {
  required Future<bool> Function() condition,
}) async {
  for (int attempt = 0; attempt < 400; attempt += 1) {
    final bool done =
        await tester.runAsync<bool>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return condition();
        }) ??
        false;
    await tester.pump();
    if (done) return;
  }
  fail('Timed out');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('拖一包书进书籍导入框：整批落库，一份汇总，关掉后书籍框也关', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1000);
    addTearDown(tester.view.reset);

    final Directory root = Directory.systemTemp.createTempSync(
      'book_archive_dialog_',
    );
    final Archive pack = Archive();
    void add(String name, List<int> bytes) =>
        pack.addFile(ArchiveFile(name, bytes.length, bytes));
    add('合集/一巻.epub', _epubBytes('一巻'));
    add('合集/二巻.epub', _epubBytes('二巻'));
    add('合集/外伝.txt', utf8.encode('外伝の本文です。\n二行目。'));
    add('合集/readme.html', utf8.encode('<p>not a book</p>'));
    final File zip = File(p.join(root.path, 'novels.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(pack)!);

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    EpubStorage.debugBaseDirectoryOverride = p.join(root.path, 'library');
    addTearDown(() async {
      EpubStorage.debugBaseDirectoryOverride = null;
      await db.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    bool? bookDialogResult;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    bookDialogResult = await Navigator.of(context).push<bool>(
                      MaterialPageRoute<bool>(
                        builder: (_) => Scaffold(
                          body: BookImportDialog(
                            repo: SrtBookRepository(db),
                            audiobookRepo: AudiobookRepository(db),
                            db: db,
                          ),
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final FushiFileDropTarget dropTarget = tester.widget<FushiFileDropTarget>(
      find.byType(FushiFileDropTarget),
    );
    unawaited(
      Future<void>.sync(
        () => dropTarget.onDrop(<String>[zip.path], Offset.zero),
      ),
    );
    await _pumpUntil(
      tester,
      condition: () async =>
          find.byType(BookArchiveImportDialog).evaluate().isNotEmpty,
    );
    final String summary = t.book_archive_import_result(
      imported: 3,
      skipped: 0,
      failed: 0,
    );
    await _pumpUntil(
      tester,
      condition: () async => find.text(summary).evaluate().isNotEmpty,
    );
    final List<String> titles = <String>[
      for (final EpubBookRow b
          in await tester.runAsync(db.getAllEpubBooks) ?? <EpubBookRow>[])
        b.title,
    ]..sort();
    expect(titles, <String>['一巻', '二巻', '外伝']);
    // 暂存解包目录用完即删，书库根下不留 `.tmp-*`。
    expect(
      Directory(p.join(root.path, 'library')).listSync().where(
        (FileSystemEntity e) => p.basename(e.path).startsWith('.tmp'),
      ),
      isEmpty,
    );

    await tester.tap(find.text(t.dialog_ok));
    await tester.pumpAndSettle();
    expect(find.byType(BookArchiveImportDialog), findsNothing);
    expect(find.byType(BookImportDialog), findsNothing);
    expect(bookDialogResult, isTrue);
  });

  testWidgets('汇总列出没解开的包与导入失败的书', (WidgetTester tester) async {
    final BookArchiveImporter importer = BookArchiveImporter(
      importEpub: (String path) async =>
          throw const FormatException('bad epub'),
      importText: (String path) async => null,
      importPdf: (String path) async => null,
      createStagingDir: () async =>
          Directory.systemTemp.createTempSync('unused_').path,
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: BookArchiveImportDialog(
              importer: importer,
              paths: const <String>['/nowhere/a.epub', '/nowhere/b.txt'],
            ),
          ),
        ),
      ),
    );
    await _pumpUntil(
      tester,
      condition: () async => find
          .text(
            t.book_archive_import_result(imported: 0, skipped: 1, failed: 1),
          )
          .evaluate()
          .isNotEmpty,
    );
    expect(find.textContaining('a.epub'), findsOneWidget);
    expect(find.textContaining('bad epub'), findsOneWidget);
  });
}
