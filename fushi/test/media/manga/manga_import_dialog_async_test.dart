/// 路线图 #3722 c39（BUG-4909，manga-3）：漫画导入的 `.epub` 定性不再在 UI isolate
/// 上同步开包。
///
/// - 导入框单选 / 预填：定性走 [ImportCarrierResolver.resolveAsync]，开包判据跑在
///   后台 isolate，判定未回来时界面照常出帧；
/// - 批量：`.epub` 不预定性，导入器自己在页图落盘之前否决文字 EPUB；
/// - 探测的解压落点可以由调用方指定（app 内是书库根下的 `.tmp-*`），后台入口用完即删。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi/src/media/manga/import/manga_folder_batch.dart';
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/manga_archive_importer.dart';
import 'package:fushi_engine/media/manga/manga_archive_probe.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory app;
  late FushiDatabase db;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    root = Directory.systemTemp.createTempSync('manga_c39_');
    app = Directory.systemTemp.createTempSync('manga_c39_app_');
    EpubStorage.debugBaseDirectoryOverride = app.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    for (final Directory d in <Directory>[root, app]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  Set<String> stagingDirs() {
    final Directory booksRoot = Directory(p.join(app.path, 'fushi_books'));
    if (!booksRoot.existsSync()) return <String>{};
    return <String>{
      for (final Directory dir
          in booksRoot.listSync(followLinks: false).whereType<Directory>())
        if (p.basename(dir.path).startsWith(EpubStorage.kStagingDirPrefix))
          dir.path,
    };
  }

  group('探测落点（c26 遗留：不进系统临时目录）', () {
    test('给了 probeDir 就解进它、且不替调用方删', () {
      final String epub = _writeEpub(root, 'vol.epub');
      final Directory probe = Directory(p.join(app.path, 'probe'))
        ..createSync();

      expect(
        MangaArchiveImporter.imageEpubRejection(epub, probeDir: probe.path),
        isNull,
      );
      expect(
        File(p.join(probe.path, 'META-INF', 'container.xml')).existsSync(),
        isTrue,
        reason: 'spine 文档应落在调用方给的目录里，而不是系统临时目录',
      );
      expect(
        File(p.join(probe.path, 'OEBPS', 'i1.png')).existsSync(),
        isFalse,
        reason: '页图条目不落盘（manga-23）',
      );
    });

    test('后台入口带 db：判定正确，书库根下的探测目录用完即删', () async {
      final String manga = _writeEpub(root, 'manga.epub');
      final String novel = _writeEpub(root, 'novel.epub', textPage: true);

      expect(await looksLikeImageArchiveInBackground(manga, db: db), isTrue);
      expect(await looksLikeImageArchiveInBackground(novel, db: db), isFalse);
      expect(stagingDirs(), isEmpty, reason: '探测目录不得残留在书库根下');
    });
  });

  group('导入器自己判「不是漫画」（批量不预定性的前提）', () {
    test('文字 EPUB 在页图落盘之前被否决，抛 MangaArchiveNotMangaException', () async {
      // 插图是一张随机像素的大 PNG，超过注入的 4 KiB 单条上限。修复前导入器先把
      // 整本（含插图）解出来再判纯图，于是先撞上「too large」，报的是导入失败；
      // 现在先只解 spine 文档、判出有正文，插图根本不落盘。
      final String novel = _writeEpub(
        root,
        'novel.epub',
        textPage: true,
        firstImage: _noisyPng(),
      );
      final Set<String> before = stagingDirs();

      await expectLater(
        MangaArchiveImporter.importArchive(
          db: db,
          archivePath: novel,
          limits: const MangaArchiveExtractionLimits(maxEntryBytes: 4096),
        ),
        throwsA(isA<MangaArchiveNotMangaException>()),
      );
      expect(stagingDirs(), before, reason: '暂存与解压树都要收掉');
      expect(await db.getAllEpubBooks(), isEmpty);
    });

    test('没有任何图片条目的 EPUB 直接否决', () async {
      final String plain = _writeEpub(root, 'plain.epub', withImages: false);
      await expectLater(
        MangaArchiveImporter.importArchive(db: db, archivePath: plain),
        throwsA(isA<MangaArchiveNotMangaException>()),
      );
    });

    test('纯图 EPUB 照常导入（两遍解压不丢页）', () async {
      final String manga = _writeEpub(root, 'manga.epub');
      await MangaArchiveImporter.importArchive(db: db, archivePath: manga);
      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1));
      expect(books.single.title, 'manga');
    });
  });

  group('批量导入：.epub 不预定性', () {
    test('纯图卷照常导入、文字卷计为不是漫画，且没有任何一次预定性探测', () async {
      _writeEpub(root, 'テスト 1.epub');
      _writeEpub(root, 'テスト 2.epub');
      _writeEpub(root, 'novel.epub', textPage: true);
      final int probesBefore = MangaArchiveImporter.debugEpubProbeCount;

      final MangaBatchImportReport report = await importMangaBatchPaths(
        db: db,
        paths: <String>[root.path],
      );

      expect(report.importedCount, 2, reason: '${report.volumes}');
      expect(report.notMangaCount, 1, reason: '${report.volumes}');
      expect(report.failedCount, 0, reason: '${report.volumes}');
      expect(
        MangaArchiveImporter.debugEpubProbeCount - probesBefore,
        0,
        reason: '修复前每本 EPUB 先在 UI isolate 上同步探测一遍、导入再解析一遍',
      );
    });
  });

  group('ImportCarrierResolver.resolveAsync', () {
    ({ImportCarrierResolver resolver, List<String> probes}) make(
      Future<bool> Function(String path) answer,
    ) {
      final List<String> probes = <String>[];
      return (
        resolver: ImportCarrierResolver(
          isDirectory: (String _) => false,
          probeImageArchive: (String path) {
            probes.add(path);
            return answer(path);
          },
          directoryHasPageImages: (String _) => false,
          directoryCarrierFileCount: (String _) => 0,
          directoryMokuroFileCount: (String _) => 0,
        ),
        probes: probes,
      );
    }

    test('同一路径并发提问共用一次开包，之后走记忆', () async {
      final Completer<bool> gate = Completer<bool>();
      final r = make((String _) => gate.future);
      final Future<ImportCarrier> a = r.resolver.resolveAsync('/m/vol.epub');
      final Future<ImportCarrier> b = r.resolver.resolveAsync('/m/vol.epub');
      gate.complete(true);
      expect(await a, ImportCarrier.mangaArchive);
      expect(await b, ImportCarrier.mangaArchive);
      expect(
        await r.resolver.resolveAsync('/m/vol.epub'),
        ImportCarrier.mangaArchive,
      );
      expect(r.probes, <String>['/m/vol.epub']);
    });

    test('扩展名不二义的不开包；异步判据的结论照常决定载体', () async {
      final r = make((String _) async => false);
      expect(
        await r.resolver.resolveAsync('/m/vol.cbz'),
        ImportCarrier.mangaArchive,
      );
      expect(
        await r.resolver.resolveAsync('/b/novel.epub'),
        ImportCarrier.epub,
      );
      expect(r.probes, <String>['/b/novel.epub']);
    });

    test('只给异步判据的 resolver 不能同步 resolve（不得悄悄回 UI isolate 开包）', () {
      final r = make((String _) async => true);
      expect(() => r.resolver.resolve('/m/vol.epub'), throwsStateError);
    });
  });

  group('MangaImportDialog 预填 .epub', () {
    Future<void> pumpDialog(
      WidgetTester tester,
      String path,
      Future<bool> Function(String path) probe,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: MangaImportDialog(
                  db: db,
                  initialPath: path,
                  imageArchiveProbe: probe,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    String titleText(WidgetTester tester) => tester
        .widget<EditableText>(find.byType(EditableText).first)
        .controller
        .text;

    testWidgets('判定没回来时界面照常出帧，回来后才收下路径', (WidgetTester tester) async {
      final Completer<bool> gate = Completer<bool>();
      final List<String> asked = <String>[];
      final String vol = p.join(root.path, 'vol01.epub');
      await pumpDialog(tester, vol, (String path) {
        asked.add(path);
        return gate.future;
      });

      expect(asked, <String>[vol]);
      expect(find.byType(MangaImportDialog), findsOneWidget);
      expect(titleText(tester), isEmpty, reason: '还没定性，不能先收下');
      await tester.pump(const Duration(milliseconds: 16));

      gate.complete(true);
      await tester.pump();
      expect(titleText(tester), 'vol01');
    });

    testWidgets('判定回来前对话框已关：晚到的结果被丢弃，不抛错', (WidgetTester tester) async {
      final Completer<bool> gate = Completer<bool>();
      await pumpDialog(
        tester,
        p.join(root.path, 'vol01.epub'),
        (String _) => gate.future,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete(true);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('定性期间用户对旧选择点了导入：晚到的新选择不得收下', (WidgetTester tester) async {
      // 旧选择是 `.cbz`（扩展名不二义，不开包、马上收下）；随后拖进一本 `.epub`，
      // 定性挂起时用户点「导入」——导入已把旧路径拷成局部量。修复前定性回来后照样
      // 收下新路径：界面显示的与正在导入的不是同一本，选文件夹路径还会删掉正在导入
      // 的暂存副本。
      final Completer<bool> gate = Completer<bool>();
      final String cbz = _writeCbz(root, 'volA.cbz');
      await pumpDialog(tester, cbz, (String _) => gate.future);
      expect(titleText(tester), 'volA');

      final FushiFileDropTarget target = tester.widget<FushiFileDropTarget>(
        find.byType(FushiFileDropTarget),
      );
      target.onDrop(<String>[p.join(root.path, 'volB.epub')], Offset.zero);
      await tester.pump();

      await tester.tap(find.text(t.dialog_import));
      await tester.pump();
      expect(
        find.text(t.dialog_importing),
        findsOneWidget,
        reason: '前提：导入正在进行（真实文件 IO 在 fake async 里不会完成）',
      );

      gate.complete(true);
      await tester.pump();
      expect(titleText(tester), 'volA', reason: '正在导入的是 volA，不能换成 volB');
      expect(find.textContaining('volB'), findsNothing);

      // 收尾：先拆掉对话框，再交替推进真实 IO 与 fake 时钟，让挂起的导入走完并
      // 关掉 volA.cbz 的句柄（否则 Windows 上 tearDown 删不掉临时目录）。
      await tester.pumpWidget(const SizedBox.shrink());
      for (int i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    });

    testWidgets('预填的不是漫画：留空、不弹不支持格式', (WidgetTester tester) async {
      await pumpDialog(
        tester,
        p.join(root.path, 'novel.epub'),
        (String _) async => false,
      );
      await tester.pump();
      expect(titleText(tester), isEmpty);
    });
  });
}

/// 两页页图的 `.cbz`。
String _writeCbz(Directory dir, String name) {
  final Archive archive = Archive();
  for (final String page in <String>['001.png', '002.png']) {
    final Uint8List bytes = _png();
    archive.addFile(ArchiveFile(page, bytes.length, bytes));
  }
  final String path = p.join(dir.path, name);
  File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
  return path;
}

Uint8List _png() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 20, height: 40)));

/// 随机像素的 PNG：压不动，体积远超 4 KiB。
Uint8List _noisyPng() {
  final Random random = Random(39);
  final img.Image noisy = img.Image(width: 64, height: 64);
  for (final img.Pixel pixel in noisy) {
    pixel
      ..r = random.nextInt(256)
      ..g = random.nextInt(256)
      ..b = random.nextInt(256);
  }
  final Uint8List bytes = Uint8List.fromList(img.encodePng(noisy));
  expect(bytes.length, greaterThan(4096));
  return bytes;
}

/// 两页 EPUB：默认每页一张图（纯图漫画）；[textPage] 时第 2 页是正文（小说）；
/// [withImages] 为 false 时连图片条目都没有。
String _writeEpub(
  Directory dir,
  String name, {
  bool textPage = false,
  bool withImages = true,
  Uint8List? firstImage,
}) {
  final Archive archive = Archive();
  void add(String entry, List<int> bytes) =>
      archive.addFile(ArchiveFile(entry, bytes.length, bytes));
  void addText(String entry, String content) =>
      add(entry, utf8.encode(content));

  final String title = p.basenameWithoutExtension(name);
  addText('mimetype', 'application/epub+zip');
  addText('META-INF/container.xml', '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');
  addText('OEBPS/content.opf', '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">c39-$title</dc:identifier>
    <dc:title>$title</dc:title>
    <dc:language>ja</dc:language>
  </metadata>
  <manifest>
    <item id="p1" href="p1.xhtml" media-type="application/xhtml+xml"/>
    <item id="p2" href="p2.xhtml" media-type="application/xhtml+xml"/>
    ${withImages ? '<item id="i1" href="i1.png" media-type="image/png"/>' : ''}
    ${withImages ? '<item id="i2" href="i2.png" media-type="image/png"/>' : ''}
  </manifest>
  <spine>
    <itemref idref="p1"/>
    <itemref idref="p2"/>
  </spine>
</package>
''');
  String page(String body) =>
      '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>p</title></head>
  <body>$body</body>
</html>
''';
  addText(
    'OEBPS/p1.xhtml',
    page(withImages ? '<img src="i1.png" alt=""/>' : '<p>はじめに</p>'),
  );
  addText(
    'OEBPS/p2.xhtml',
    page(
      textPage || !withImages
          ? '<p>これは本文です。吾輩は猫である。</p>'
          : '<img src="i2.png" alt=""/>',
    ),
  );
  if (withImages) {
    add('OEBPS/i1.png', firstImage ?? _png());
    add('OEBPS/i2.png', _png());
  }
  final String path = p.join(dir.path, name);
  File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
  return path;
}
