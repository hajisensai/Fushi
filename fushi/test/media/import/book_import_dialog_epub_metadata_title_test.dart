// BUG-3774：选中 EPUB 后，导入对话框的标题框必须显示 OPF `dc:title`，而不是文件名。
// 入库书名本来就取 OPF，标题框显示文件名会让用户以为书会以文件名入库。走真对话框 +
// 真 EPUB 文件 + 真 EpubImporter，证明「框里看到的」和「库里落的」是同一个书名。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

Uint8List _epubBytes({required String? title}) {
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
    <dc:identifier id="book-id">bug-3774</dc:identifier>
    ${title == null ? '' : '<dc:title>$title</dc:title>'}
    <dc:language>ja</dc:language>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml"
        media-type="application/xhtml+xml"/>
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
  <body><p>吾輩は猫である。名前はまだ無い。</p></body>
</html>
''');
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Widget _host(BookImportDialog dialog) {
  return TranslationProvider(
    child: MaterialApp(
      home: Scaffold(body: Center(child: dialog)),
    ),
  );
}

String _titleFieldText(WidgetTester tester) {
  final Iterable<TextField> fields = tester.widgetList<TextField>(
    find.byType(TextField),
  );
  return fields.first.controller!.text;
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Future<bool> Function() condition,
) async {
  for (int attempt = 0; attempt < 300; attempt += 1) {
    final bool done =
        await tester.runAsync<bool>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return condition();
        }) ??
        false;
    await tester.pump();
    if (done) return;
  }
  fail('Timed out waiting for condition');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<({FushiDatabase db, Directory root})> setUpEnv(String tag) async {
    final Directory root = Directory.systemTemp.createTempSync(tag);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    EpubStorage.debugBaseDirectoryOverride = root.path;
    addTearDown(() async {
      EpubStorage.debugBaseDirectoryOverride = null;
      await db.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return (db: db, root: root);
  }

  testWidgets('标题框显示 OPF dc:title，且与入库书名一致', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1000);
    addTearDown(tester.view.reset);

    final ({FushiDatabase db, Directory root}) env = await setUpEnv(
      'bug_3774_meta_title_',
    );
    const String metadataTitle = '吾輩は猫である';
    final File epub = File(p.join(env.root.path, 'neko_v01 [scan].epub'))
      ..writeAsBytesSync(_epubBytes(title: metadataTitle));

    await tester.pumpWidget(
      _host(
        BookImportDialog(
          repo: SrtBookRepository(env.db),
          audiobookRepo: AudiobookRepository(env.db),
          db: env.db,
          initialEpubPath: epub.path,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () async => _titleFieldText(tester) == metadataTitle,
    );
    expect(
      _titleFieldText(tester),
      metadataTitle,
      reason: '选中 EPUB 后标题框必须换成 OPF 书名，不能停在文件名',
    );

    await tester.tap(find.text(t.dialog_import));
    await tester.pump();
    await _pumpUntil(
      tester,
      () async => (await env.db.getAllEpubBooks()).length == 1,
    );
    final List<EpubBookRow> books =
        await tester.runAsync(() => env.db.getAllEpubBooks()) ??
        <EpubBookRow>[];
    expect(books.single.title, metadataTitle, reason: '标题框显示的书名必须就是入库书名');
  });

  testWidgets('OPF 没写书名时标题框保留文件名', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1000);
    addTearDown(tester.view.reset);

    final ({FushiDatabase db, Directory root}) env = await setUpEnv(
      'bug_3774_no_meta_title_',
    );
    final File epub = File(p.join(env.root.path, 'untitled_book.epub'))
      ..writeAsBytesSync(_epubBytes(title: null));

    await tester.pumpWidget(
      _host(
        BookImportDialog(
          repo: SrtBookRepository(env.db),
          audiobookRepo: AudiobookRepository(env.db),
          db: env.db,
          initialEpubPath: epub.path,
        ),
      ),
    );
    // 给后台 isolate 足够时间读完 OPF，确认它没有把文件名清掉。
    for (int i = 0; i < 30; i += 1) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(_titleFieldText(tester), 'untitled_book');
  });
}
