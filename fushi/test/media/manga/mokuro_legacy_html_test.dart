/// mokuro 0.1 旧版产物（`<卷名>.html` + `<卷名>/` 页图 + `_ocr/<卷名>/` 逐页 JSON）
/// 的导入契约（反馈 NdpewUzW1C：从 jidoujisho 迁来的用户手里是这种产物）。
///
/// 修复前：漫画框只认 `.mokuro`。选整个目录时页图判据把 `<卷名>/` 压平成一卷
/// **没字**的纯页图，选 `.html` 则被当文本转成 EPUB；来源库同样把卷目录当纯页图卷
/// 导入。三条路都把 mokuro 的文字层丢掉，读的时候阅读器再在设备上跑一遍本地 OCR。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi/src/media/manga/import/manga_folder_batch.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/manga_folder_plan.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart';
import 'package:fushi_engine/media/manga/manga_pdf_text_layer.dart'
    show mangaVolumeOcrSettled;
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_legacy_html.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

Uint8List _png(int width, int height) =>
    Uint8List.fromList(img.encodePng(img.Image(width: width, height: height)));

/// 按 mokuro 0.1 的布局在 [parent] 下写出一卷 [volume]，返回 `.html` 路径。
///
/// [pagesWithOcr] 之外的页不写 JSON（mokuro 半途失败的那种卷）。页名故意用
/// `10.png` / `2.png` 检验自然序。
String _writeLegacyVolume(
  String parent, {
  required String volume,
  List<String> pages = const <String>['1.png', '2.png', '10.png'],
  Set<String>? pagesWithOcr,
}) {
  final Directory images = Directory(p.join(parent, volume))
    ..createSync(recursive: true);
  final Directory ocr = Directory(p.join(parent, '_ocr', volume))
    ..createSync(recursive: true);
  for (final String page in pages) {
    File(p.join(images.path, page)).writeAsBytesSync(_png(40, 60));
    if (pagesWithOcr != null && !pagesWithOcr.contains(page)) continue;
    File(
      p.join(ocr.path, '${p.withoutExtension(page)}.json'),
    ).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'version': '0.1.7',
        'img_width': 1200,
        'img_height': 1700,
        'blocks': <Object?>[
          <String, Object?>{
            'box': <int>[10, 20, 110, 220],
            'vertical': true,
            'font_size': 32,
            'lines_coords': <Object?>[
              <Object?>[
                <double>[10, 20],
                <double>[110, 20],
                <double>[110, 220],
                <double>[10, 220],
              ],
            ],
            'lines': <String>['$volume $page'],
          },
        ],
      }),
    );
  }
  final String html = p.join(parent, '$volume.html');
  File(html).writeAsStringSync('<html><body>mokuro</body></html>');
  return html;
}

ImportCarrier _classify(String path) => classifyImportCarrier(
  path,
  isDirectory: (String pth) => Directory(pth).existsSync(),
  isImageArchive: MangaModule.isImageArchive,
  directoryHasPageImages: MangaModule.directoryHasPageImages,
  directoryCarrierFileCount: MangaModule.directoryCarrierFileCount,
  directoryMokuroFileCount: MangaModule.directoryMokuroFileCount,
);

MokuroPayload _readStoredPayload(EpubBookRow row) => parseMangaJson(
  File(
    p.join(row.extractDir, MangaStorage.kMangaJsonFileName),
  ).readAsStringSync(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory src;
  late Directory app;
  late FushiDatabase db;

  setUp(() {
    src = Directory.systemTemp.createTempSync('mokuro_legacy_src_');
    app = Directory.systemTemp.createTempSync('mokuro_legacy_app_');
    EpubStorage.debugBaseDirectoryOverride = app.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    for (final Directory d in <Directory>[src, app]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  group('判据（纯路径）', () {
    test('有 _ocr/<卷名>/ 的 html 是一卷；没有的、被同名 .mokuro 覆盖的不是', () {
      final List<String> picked = legacyMokuroHtmlPathsIn(<String>[
        '/m/Series/vol1.html',
        '/m/Series/vol1/001.jpg',
        '/m/Series/_ocr/vol1/001.json',
        // 普通网页：没有 _ocr。
        '/m/Series/readme.html',
        // 新版 mokuro 加 --legacy_html：.mokuro 才是 manifest。
        '/m/Series/vol2.html',
        '/m/Series/vol2.mokuro',
        '/m/Series/_ocr/vol2/001.json',
      ], context: p.posix);
      expect(picked, <String>['/m/Series/vol1.html']);
    });

    test('远端 href（p.url）原样交回，不被规范化改写', () {
      const String html = 'https://dav.example/m/Series/vol%201.html';
      final List<String> picked = legacyMokuroHtmlPathsIn(<String>[
        html,
        'https://dav.example/m/Series/vol%201/001.jpg',
        'https://dav.example/m/Series/_ocr/vol%201/001.json',
      ], context: p.url);
      expect(picked, <String>[html]);
    });

    test('来源库归卷：html 是一卷，同名页图目录让位，不再当无字纯页图卷', () {
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: '/m',
        context: p.posix,
        filePaths: <String>[
          '/m/vol1.html',
          '/m/vol1/001.jpg',
          '/m/vol1/002.jpg',
          '/m/_ocr/vol1/001.json',
          '/m/_ocr/vol1/002.json',
          '/m/vol2.html',
          '/m/vol2/001.jpg',
          '/m/_ocr/vol2/001.json',
        ],
      );
      expect(plan.mokuroPaths, <String>['/m/vol1.html', '/m/vol2.html']);
      expect(plan.imageFolders, isEmpty);
    });

    test('app 侧扫描计划（含远端 p.url 路径）同样把 html 计成 mokuro 卷', () {
      SourceFileEntry f(String path) => SourceFileEntry(
        path: path,
        name: p.url.basename(path),
        isDirectory: false,
      );
      final ScanPlan plan = planScanFromFileList(
        <SourceFileEntry>[
          f('/share/m/vol1.html'),
          f('/share/m/vol1/001.jpg'),
          f('/share/m/_ocr/vol1/001.json'),
        ],
        mangaRootPath: '/share/m',
        mangaPathContext: p.url,
      );
      expect(plan.mangas.map((ScanMangaItem i) => i.mokuroPath), <String>[
        '/share/m/vol1.html',
      ]);
      expect(plan.mangaFolders, isEmpty);
    });
  });

  group('导入（真实文件系统）', () {
    test('html 卷导入后带 mokuro 文字层，阅读器判为已识别、不再跑本地 OCR', () async {
      final String html = _writeLegacyVolume(
        p.join(src.path, 'Yotsuba'),
        volume: 'vol1',
        pagesWithOcr: <String>{'1.png', '2.png'},
      );
      expect(isLegacyMokuroHtmlVolume(html), isTrue);
      expect(mangaImportCanImport(<String>[html]), isTrue);

      final String bookKey = await MangaImporter.importFromMokuroPath(
        db: db,
        mokuroPath: html,
      );
      final EpubBookRow row = (await db.getEpubBook(bookKey))!;
      expect(row.format, 'manga');
      // 与 mokuro 0.2 写进 .mokuro 的 title / volume 同口径：`上级目录 卷名`。
      expect(row.title, 'Yotsuba vol1');
      expect(row.chapterCount, 3);

      final MokuroPayload stored = _readStoredPayload(row);
      expect(stored.images.map((MokuroImage i) => i.url).toList(), <String>[
        'images/vol1/1.png',
        'images/vol1/2.png',
        'images/vol1/10.png',
      ], reason: '页序与 mokuro 一致（自然序），页图随卷目录拷进书目录');
      expect(stored.images[0].blocks.single.lines, <String>['vol1 1.png']);
      expect(stored.images[0].size.width, 1200);
      expect(stored.images[0].blocks.single.linesCoords, isNotNull);
      // 缺 JSON 的页照常入卷：文字层空、宽高取页图真实尺寸。
      expect(stored.images[2].blocks, isEmpty);
      expect(stored.images[2].size.width, 40);
      expect(stored.images[2].size.height, 60);
      expect(
        mangaVolumeOcrSettled(stored),
        isTrue,
        reason: '阅读器据此跳过自动整卷 OCR（manga_fushi_page.dart）',
      );
    });

    test('载体判定：选 html 文件或装着它的目录都按 mokuro 导，普通 html 仍是文本', () {
      final Directory series = Directory(p.join(src.path, 'Series'))
        ..createSync();
      final String html = _writeLegacyVolume(series.path, volume: 'vol1');
      final String plain = p.join(src.path, 'notes.html');
      File(plain).writeAsStringSync('<p>hi</p>');

      expect(_classify(html), ImportCarrier.mangaMokuro);
      expect(_classify(plain), ImportCarrier.text);
      // 修复前：页图判据递归压平 → mangaFolder（一卷没字的纯页图）。
      expect(_classify(series.path), ImportCarrier.mangaMokuro);
      expect(MangaModule.directorySingleMokuroPath(series.path), html);

      // 只剩一个孤零零的 html（选择器只交回了副本）：导入门拒绝。
      final Directory lone = Directory(p.join(src.path, 'lone'))..createSync();
      final String copy = p.join(lone.path, 'vol1.html');
      File(html).copySync(copy);
      expect(MangaModule.canImportPath(copy), isFalse);
    });

    test('装着多卷旧版产物的目录逐卷导入，每卷都带文字层', () async {
      final Directory series = Directory(p.join(src.path, 'Series'))
        ..createSync();
      _writeLegacyVolume(series.path, volume: 'vol1');
      _writeLegacyVolume(series.path, volume: 'vol2');

      expect(_classify(series.path), ImportCarrier.mangaBatchFolder);
      final MangaBatchImportReport report = await MangaModule.importBatchFolder(
        db: db,
        path: series.path,
      );
      expect(report.importedCount, 2);

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      // 批量导入的标题沿用既有口径（逐卷取文件名），与 `.mokuro` 批量一致。
      expect(books.map((EpubBookRow b) => b.title).toSet(), <String>{
        'vol1',
        'vol2',
      });
      for (final EpubBookRow book in books) {
        expect(mangaVolumeOcrSettled(_readStoredPayload(book)), isTrue);
      }
    });

    test('本地来源库扫描：旧版产物导成带文字层的卷，不再多出一本无字页图卷', () async {
      _writeLegacyVolume(src.path, volume: 'vol1');
      final int sid = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Manga',
          mediaKind: 'manga',
          rootPath: src.path,
          recursive: const Value(true),
          createdAt: 1000,
        ),
      );
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await SourceLibraryScanner(db).scan(source);

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1));
      expect(books.single.sourceId, sid);
      expect(mangaVolumeOcrSettled(_readStoredPayload(books.single)), isTrue);
      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.lastScanError, isNull);
    });
  });
}
