/// BUG-1649：在漫画框选一个**装着整卷文件的文件夹**（一卷一个 `.epub`/`.cbz`）。
///
/// 修复前目录只有「一卷页图目录」一种解释，这种文件夹会被 `enumerateMangaPages`
/// 扫出 0 张图，报 `Manga image folder has no pages`——那句话描述的是判定结果，
/// 不是用户做错了什么。这里钉死新的目录形态判定与逐卷导入的编排契约。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_series.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/manga_folder_plan.dart';
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi/src/media/manga/import/manga_folder_batch.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory app;
  late FushiDatabase db;

  setUp(() {
    root = Directory.systemTemp.createTempSync('manga_batch_');
    app = Directory.systemTemp.createTempSync('manga_batch_app_');
    EpubStorage.debugBaseDirectoryOverride = app.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
    if (app.existsSync()) app.deleteSync(recursive: true);
  });

  group('目录形态判定（生产实参）', () {
    test('装着整卷文件的目录 → mangaBatchFolder，而不是「没有页」的页图目录', () {
      _writeCbz(root, 'vol1.cbz');
      _writeCbz(root, 'vol2.cbz');

      expect(MangaModule.directoryHasPageImages(root.path), isFalse);
      expect(MangaModule.directoryCarrierFileCount(root.path), 2);
      expect(
        _classifyWithRealPredicates(root.path),
        ImportCarrier.mangaBatchFolder,
      );
    });

    test('页图目录仍是 mangaFolder（修复不得改动既有路径）', () {
      File(p.join(root.path, '001.png')).writeAsBytesSync(_pngBytes());

      expect(MangaModule.directoryHasPageImages(root.path), isTrue);
      expect(_classifyWithRealPredicates(root.path), ImportCarrier.mangaFolder);
    });

    // iycDWb7ys6：直接子层的散图只是整卷文件的封面 / 目录图，与来源库扫描
    // （planMangaFolders）同一让位判据——此前这里钉的是「页图优先」，同一个文件夹
    // 在「导入文件夹」里逐卷导入、在导入框里却成了一卷只有封面的页图目录。
    test('散图与整卷文件同层 → 散图让位，这是一批卷（与来源库扫描同判）', () {
      File(p.join(root.path, 'cover.jpg')).writeAsBytesSync(_jpgBytes());
      _writeCbz(root, 'vol1.cbz');

      expect(MangaModule.directoryHasPageImages(root.path), isFalse);
      expect(
        _classifyWithRealPredicates(root.path),
        ImportCarrier.mangaBatchFolder,
      );
      final MangaFolderPlan plan = planMangaFoldersInDirectory(root);
      expect(plan.imageFolders, isEmpty, reason: '扫描侧对同一目录的解释');
      expect(plan.carrierPaths, <String>[p.join(root.path, 'vol1.cbz')]);
    });

    test('子目录里的真页图旁边多一个包 → 仍是一卷页图目录（不被包吞掉）', () {
      final Directory ch01 = Directory(p.join(root.path, 'ch01'))..createSync();
      File(p.join(ch01.path, '001.png')).writeAsBytesSync(_pngBytes());
      _writeCbz(root, 'extra.cbz');

      expect(MangaModule.directoryHasPageImages(root.path), isTrue);
      expect(_classifyWithRealPredicates(root.path), ImportCarrier.mangaFolder);
    });

    // BUG-2785：mokuro 标准产物「卷.mokuro + 同名页图子目录」。页图判据递归进子目录
    // 抢先认成页图目录，OCR 静默丢失。真文件系统判据下钉死新的优先级。
    test('卷.mokuro + 同名页图子目录 → mangaMokuro，且能换出那个 .mokuro 文件', () {
      File(p.join(root.path, 'vol1.mokuro')).writeAsStringSync('{}');
      Directory(p.join(root.path, 'vol1')).createSync();
      File(p.join(root.path, 'vol1', '001.png')).writeAsBytesSync(_pngBytes());

      expect(
        MangaModule.directoryHasPageImages(root.path),
        isTrue,
        reason: '前提：页图判据会递归看到子目录里的图（这正是抢先误判的来源）',
      );
      expect(MangaModule.directoryMokuroFileCount(root.path), 1);
      expect(_classifyWithRealPredicates(root.path), ImportCarrier.mangaMokuro);
      expect(
        MangaModule.directorySingleMokuroPath(root.path),
        p.join(root.path, 'vol1.mokuro'),
      );
    });

    test('两个 .mokuro → mangaBatchFolder；换不出单个文件', () {
      for (final String vol in <String>['vol1', 'vol2']) {
        File(p.join(root.path, '$vol.mokuro')).writeAsStringSync('{}');
        Directory(p.join(root.path, vol)).createSync();
        File(p.join(root.path, vol, '001.png')).writeAsBytesSync(_pngBytes());
      }

      expect(
        _classifyWithRealPredicates(root.path),
        ImportCarrier.mangaBatchFolder,
      );
      expect(MangaModule.directorySingleMokuroPath(root.path), isNull);
    });
  });

  group('候选枚举', () {
    test('只认整卷扩展名，且只看直接子层', () {
      _writeCbz(root, 'vol2.cbz');
      _writeCbz(root, 'vol10.cbz');
      _writeCbz(root, 'vol1.cbz');
      File(p.join(root.path, 'notes.txt')).writeAsStringSync('not a volume');
      final Directory nested = Directory(p.join(root.path, 'nested'))
        ..createSync();
      _writeCbz(nested, 'vol99.cbz');

      final List<String> names = mangaCarrierFilesIn(
        root,
      ).map((File f) => p.basename(f.path)).toList();
      // 自然序：vol2 在 vol10 之前（字典序会把 vol10 排前面，那会打乱卷号）。
      expect(names, <String>['vol1.cbz', 'vol2.cbz', 'vol10.cbz']);
    });

    test('候选集与文件选择器白名单同源（不得各抄一份）', () {
      for (final String ext in kMangaCarrierFileExtensions) {
        final File file = File(p.join(root.path, 'v$ext'))
          ..writeAsBytesSync(<int>[0]);
        expect(
          mangaCarrierFilesIn(root).map((File f) => f.path),
          contains(file.path),
          reason: '$ext 在白名单里就必须能被批量捡起来',
        );
        file.deleteSync();
      }
    });
  });

  group('逐卷导入', () {
    test('每卷各成一本，标题取各自文件名', () async {
      _writeCbz(root, '銀河英雄伝説 01.cbz');
      _writeCbz(root, '銀河英雄伝説 02.cbz');

      final MangaBatchImportReport report = await importMangaBatchFolder(
        db: db,
        path: root.path,
      );

      expect(report.importedCount, 2);
      expect(report.failedCount, 0);
      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books.map((EpubBookRow b) => b.title).toList()..sort(), <String>[
        '銀河英雄伝説 01',
        '銀河英雄伝説 02',
      ]);
      expect(
        books.every(
          (EpubBookRow b) =>
              BookFormat.parseOrEpub(b.format) == BookFormat.manga,
        ),
        isTrue,
      );
    });

    test('一卷坏包不中断整批：其余卷照样进库', () async {
      _writeCbz(root, 'vol1.cbz');
      File(
        p.join(root.path, 'vol2.cbz'),
      ).writeAsBytesSync(<int>[0x00, 0x01, 0x02, 0x03]); // 不是 zip
      _writeCbz(root, 'vol3.cbz');

      final MangaBatchImportReport report = await importMangaBatchFolder(
        db: db,
        path: root.path,
      );

      expect(report.importedCount, 2, reason: '坏的那一卷不该把另外两卷一起废掉');
      expect(report.failedCount, 1);
      expect(
        report.volumes
            .firstWhere(
              (MangaBatchVolumeResult v) =>
                  v.status == MangaBatchVolumeStatus.failed,
            )
            .name,
        'vol2.cbz',
      );
      expect((await db.getAllEpubBooks()).length, 2);
    });

    test('自带插图的 Yomitan 词典 zip 被如实计为「不是漫画」，不落库', () async {
      _writeCbz(root, 'vol1.cbz');
      _writeYomitanDictZip(root, 'dict.zip');

      final MangaBatchImportReport report = await importMangaBatchFolder(
        db: db,
        path: root.path,
      );

      expect(report.importedCount, 1);
      expect(report.notMangaCount, 1);
      expect(
        (await db.getAllEpubBooks()).length,
        1,
        reason: '词典包被导成一本只有插图的垃圾「漫画」是糟蹋用户数据',
      );
    });

    test('重跑同一个文件夹是幂等的：已在库的卷计入跳过而不是复制一份', () async {
      _writeCbz(root, 'vol1.cbz');

      final MangaBatchImportReport first = await importMangaBatchFolder(
        db: db,
        path: root.path,
      );
      expect(first.importedCount, 1);

      final MangaBatchImportReport second = await importMangaBatchFolder(
        db: db,
        path: root.path,
      );
      expect(second.importedCount, 0);
      expect(second.duplicateCount, 1);
      expect(
        (await db.getAllEpubBooks()).length,
        1,
        reason: '批量路径用 skip 策略，不得留下 `vol1 (2)`',
      );
    });

    test('一卷都没进来时报告 isEmpty（调用方据此报失败而不是「成功 0 卷」）', () async {
      _writeYomitanDictZip(root, 'dict.zip');

      final MangaBatchImportReport report = await importMangaBatchFolder(
        db: db,
        path: root.path,
      );

      expect(report.importedCount, 0);
      expect(report.isEmpty, isTrue);
    });

    test('进度按卷回报，末次等于总卷数', () async {
      _writeCbz(root, 'vol1.cbz');
      _writeCbz(root, 'vol2.cbz');
      final List<(int, int)> progress = <(int, int)>[];

      await importMangaBatchFolder(
        db: db,
        path: root.path,
        onVolumeProgress: (int done, int total) => progress.add((done, total)),
      );

      expect(progress.first, (0, 2));
      expect(progress.last, (2, 2));
    });
  });

  // 用户实报：多选拖入漫画只导进来一本。拖 N 卷进来必须与「选一个装着 N 卷的文件夹」
  // 得到同一种结果。
  group('多选路径逐卷导入（importMangaBatchPaths）', () {
    test('同时拖入的每一卷各成一本，标题取各自文件名', () async {
      _writeCbz(root, '01.cbz');
      _writeCbz(root, '02.cbz');
      _writeCbz(root, '03.cbz');

      final MangaBatchImportReport report = await importMangaBatchPaths(
        db: db,
        paths: <String>[
          p.join(root.path, '01.cbz'),
          p.join(root.path, '02.cbz'),
          p.join(root.path, '03.cbz'),
        ],
      );

      expect(report.importedCount, 3);
      expect(
        (await db.getAllEpubBooks()).map((EpubBookRow b) => b.title).toList()
          ..sort(),
        <String>['01', '02', '03'],
      );
    });

    test('页图目录与整卷文件混拖：目录按一卷导入，目录名里的点不当扩展名', () async {
      final Directory pages = Directory(p.join(root.path, '第01巻.v2'))
        ..createSync();
      File(p.join(pages.path, '001.png')).writeAsBytesSync(_pngBytes());
      _writeCbz(root, '02.cbz');

      final MangaBatchImportReport report = await importMangaBatchPaths(
        db: db,
        paths: <String>[pages.path, p.join(root.path, '02.cbz')],
      );

      expect(report.importedCount, 2, reason: '${report.volumes}');
      expect(
        (await db.getAllEpubBooks()).map((EpubBookRow b) => b.title).toList()
          ..sort(),
        <String>['02', '第01巻.v2'],
      );
    });

    test('拖入装着整卷文件的目录 = 展开成其中每一卷；同一卷重复给只导一次', () async {
      final Directory series = Directory(p.join(root.path, 'series'))
        ..createSync();
      _writeCbz(series, 'a.cbz');
      _writeCbz(series, 'b.cbz');

      final MangaBatchImportReport report = await importMangaBatchPaths(
        db: db,
        paths: <String>[series.path, p.join(series.path, 'a.cbz')],
      );

      expect(report.volumes.length, 2, reason: '重复路径不得成为第三卷');
      expect(report.importedCount, 2);
    });

    test('混进来的词典 zip 计为「不是漫画」，其余照样进库', () async {
      _writeCbz(root, 'vol1.cbz');
      _writeYomitanDictZip(root, 'dict.zip');

      final MangaBatchImportReport report = await importMangaBatchPaths(
        db: db,
        paths: <String>[
          p.join(root.path, 'vol1.cbz'),
          p.join(root.path, 'dict.zip'),
        ],
      );

      expect(report.importedCount, 1);
      expect(report.notMangaCount, 1);
    });
  });

  // iycDWb7ys6：TMW 下载的一卷一个纯图 `.epub`、旁边带一张封面图的文件夹。导入框选
  // 这个文件夹 / 拖进来，都要逐卷识别出来，并归进同一个系列合集。
  group('纯图 EPUB 文件夹（iycDWb7ys6）', () {
    test('导入框判成一批卷，逐卷导入后自动归进同一个合集', () async {
      File(p.join(root.path, 'cover.jpg')).writeAsBytesSync(_jpgBytes());
      _writeImageEpub(root, 'テスト漫画 1.epub');
      _writeImageEpub(root, 'テスト漫画 2.epub');

      expect(
        _classifyWithRealPredicates(root.path),
        ImportCarrier.mangaBatchFolder,
      );
      expect(MangaModule.directoryCarrierFileCount(root.path), 2);

      final MangaBatchImportReport report = await MangaModule.importBatchFolder(
        db: db,
        path: root.path,
      );

      expect(report.importedCount, 2, reason: '${report.volumes}');
      final List<MediaCollectionRow> collections = await db
          .getAllMediaCollections();
      expect(collections, hasLength(1), reason: '两卷应归进同一个系列合集');
      expect(collections.single.name, 'テスト漫画');
      expect(await db.getCollectionItems(collections.single.id), hasLength(2));
    });

    test('拖入同一个文件夹（importMangaBatchPaths）得到同样的结果', () async {
      File(p.join(root.path, 'cover.jpg')).writeAsBytesSync(_jpgBytes());
      _writeImageEpub(root, 'テスト漫画 1.epub');
      _writeImageEpub(root, 'テスト漫画 2.epub');

      final MangaBatchImportReport report = await importMangaBatchPaths(
        db: db,
        paths: <String>[root.path],
      );

      expect(report.importedCount, 2, reason: '${report.volumes}');
      expect(
        (await db.getAllEpubBooks()).map((EpubBookRow b) => b.title).toList()
          ..sort(),
        <String>['テスト漫画 1', 'テスト漫画 2'],
        reason: '封面图不得被当成第三卷',
      );
      expect(await db.getAllMediaCollections(), hasLength(1));
    });

    test('文件名没有系列线索时按 OPF 声明的系列归组', () async {
      _writeImageEpub(
        root,
        '始まりの日.epub',
        series: const EpubSeries(name: '声明系列', index: 1),
      );
      _writeImageEpub(
        root,
        '終わりの夜.epub',
        series: const EpubSeries(name: '声明系列', index: 2),
      );

      final MangaBatchImportReport report = await importMangaBatchPaths(
        db: db,
        paths: <String>[root.path],
      );

      expect(report.importedCount, 2, reason: '${report.volumes}');
      for (final EpubBookRow book in await db.getAllEpubBooks()) {
        expect(
          decodeEpubSeriesMetadata(book.sourceMetadata)?.name,
          '声明系列',
          reason: '纯图 EPUB 落成漫画后原包不在书目录里，系列声明只能在导入时留下',
        );
      }
      final List<MediaCollectionRow> collections = await db
          .getAllMediaCollections();
      expect(collections, hasLength(1));
      expect(collections.single.name, '声明系列');
    });

    test('一卷都没导进来时不归组、不建合集', () async {
      _writeYomitanDictZip(root, 'dict.zip');

      final MangaBatchImportReport report = await importMangaBatchPaths(
        db: db,
        paths: <String>[p.join(root.path, 'dict.zip')],
      );

      expect(report.isEmpty, isTrue);
      expect(await db.getAllMediaCollections(), isEmpty);
    });
  });

  group('散图让位判据（mangaImageDirsClaimedByCarriers）', () {
    final p.Context ctx = p.posix;
    test('每个页图目录自己或其子树都有包 → 让位', () {
      expect(
        mangaImageDirsClaimedByCarriers(
          imageDirs: <String>['/s'],
          carrierPaths: <String>['/s/v1.epub'],
          context: ctx,
        ),
        isTrue,
      );
      expect(
        mangaImageDirsClaimedByCarriers(
          imageDirs: <String>['/s'],
          carrierPaths: <String>['/s/sub/v1.cbz'],
          context: ctx,
        ),
        isTrue,
      );
    });

    test('有一个页图目录的子树里没有包 → 不让位；没有页图 → 不让位', () {
      expect(
        mangaImageDirsClaimedByCarriers(
          imageDirs: <String>['/s', '/s/ch01'],
          carrierPaths: <String>['/s/extra.cbz'],
          context: ctx,
        ),
        isFalse,
        reason: '包在 /s，认领不了更深的 /s/ch01',
      );
      expect(
        mangaImageDirsClaimedByCarriers(
          imageDirs: const <String>[],
          carrierPaths: <String>['/s/v1.cbz'],
          context: ctx,
        ),
        isFalse,
      );
    });
  });

  group('逐卷失败必须落进错误日志', () {
    // 批量路径把每卷异常收进报告、只给调用方一句「成功 N / 失败 M」的汇总，于是
    // ImportFlowMixin.runImport 那道 ErrorLogService 永远拿不到真正的原因，用户
    // 事后翻错误日志页是空的。落盘因此必须在**吞掉异常的这一层**。
    test('坏卷的真实原因写进 ErrorLogService，而不是只 debugPrint', () async {
      final int before = ErrorLogService.instance.entries.length;

      // 一卷好的 + 一卷坏的：坏卷是页图在任何布局下都找不到的 .mokuro——正是用户
      // 撞上的那种失败，只不过这里让它发生在批量路径里。
      _writeCbz(root, 'good.cbz');
      File(p.join(root.path, 'broken.mokuro')).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': '0.2.0',
          'title': 'Broken',
          'pages': <Object?>[
            <String, Object?>{
              'img_width': 800,
              'img_height': 1200,
              'img_path': 'nowhere.jpg',
              'blocks': <Object?>[],
            },
          ],
        }),
      );

      final MangaBatchImportReport report = await importMangaBatchFolder(
        db: db,
        path: root.path,
      );

      expect(report.failedCount, 1, reason: '坏卷必须计入失败');
      final List<ErrorLogEntry> added = ErrorLogService.instance.entries
          .skip(before)
          .toList();
      expect(
        added.where((ErrorLogEntry e) => e.source == 'MangaBatchImport.volume'),
        isNotEmpty,
        reason: '坏卷的原因必须以 MangaBatchImport.volume 落进错误日志',
      );
      expect(
        added
            .where((ErrorLogEntry e) => e.source == 'MangaBatchImport.volume')
            .map((ErrorLogEntry e) => e.error)
            .join('\n'),
        contains('broken.mokuro'),
        reason: '日志必须指名道姓说是哪一卷，否则 20 卷里的失败无从定位',
      );
    });

    test('全成功时不往错误日志塞噪声', () async {
      final int before = ErrorLogService.instance.entries.length;
      _writeCbz(root, 'ok1.cbz');
      _writeCbz(root, 'ok2.cbz');

      final MangaBatchImportReport report = await importMangaBatchFolder(
        db: db,
        path: root.path,
      );

      expect(report.failedCount, 0);
      expect(
        ErrorLogService.instance.entries
            .skip(before)
            .where((ErrorLogEntry e) => e.source == 'MangaBatchImport.volume'),
        isEmpty,
      );
    });
  });
}

ImportCarrier _classifyWithRealPredicates(String path) => classifyImportCarrier(
  path,
  isDirectory: (String pth) => Directory(pth).existsSync(),
  isImageArchive: MangaModule.isImageArchive,
  directoryHasPageImages: MangaModule.directoryHasPageImages,
  directoryCarrierFileCount: MangaModule.directoryCarrierFileCount,
  directoryMokuroFileCount: MangaModule.directoryMokuroFileCount,
);

Uint8List _pngBytes() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 20, height: 40)));

Uint8List _jpgBytes() =>
    Uint8List.fromList(img.encodeJpg(img.Image(width: 20, height: 40)));

/// 一卷纯图 EPUB（每章一张页图、没有正文），可选 OPF 系列声明（Calibre 写法）。
void _writeImageEpub(Directory dir, String name, {EpubSeries? series}) {
  final Archive archive = Archive();
  void addText(String entry, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(entry, bytes.length, bytes));
  }

  final String title = p.basenameWithoutExtension(name);
  addText('mimetype', 'application/epub+zip');
  addText('META-INF/container.xml', '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');
  final String seriesMeta = series == null
      ? ''
      : '<meta name="calibre:series" content="${series.name}"/>'
            '<meta name="calibre:series_index" content="${series.index}"/>';
  addText('OEBPS/content.opf', '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">iycDWb7ys6-$title</dc:identifier>
    <dc:title>$title</dc:title>
    <dc:language>ja</dc:language>
    $seriesMeta
  </metadata>
  <manifest>
    <item id="p1" href="p1.xhtml" media-type="application/xhtml+xml"/>
    <item id="p2" href="p2.xhtml" media-type="application/xhtml+xml"/>
    <item id="i1" href="i1.png" media-type="image/png"/>
    <item id="i2" href="i2.png" media-type="image/png"/>
  </manifest>
  <spine>
    <itemref idref="p1"/>
    <itemref idref="p2"/>
  </spine>
</package>
''');
  for (final int page in <int>[1, 2]) {
    addText('OEBPS/p$page.xhtml', '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>p$page</title></head>
  <body><img src="i$page.png" alt=""/></body>
</html>
''');
    final Uint8List png = _pngBytes();
    archive.addFile(ArchiveFile('OEBPS/i$page.png', png.length, png));
  }
  File(
    p.join(dir.path, name),
  ).writeAsBytesSync(ZipEncoder().encode(archive) ?? <int>[]);
}

void _writeCbz(Directory dir, String name) {
  final Uint8List png = _pngBytes();
  final Archive archive = Archive()
    ..addFile(ArchiveFile('001.png', png.length, png));
  File(
    p.join(dir.path, name),
  ).writeAsBytesSync(ZipEncoder().encode(archive) ?? <int>[]);
}

/// 词典包与图片包同形，唯一的结构指纹是 `index.json` + `*_bank_*.json`；这里连
/// 插图一起放，正是「只看有没有图片」会误判的那种包。
void _writeYomitanDictZip(Directory dir, String name) {
  final Uint8List png = _pngBytes();
  final List<int> index = utf8.encode(
    '{"title":"Test Dict","format":3,"revision":"1"}',
  );
  final List<int> bank = utf8.encode('[]');
  final Archive archive = Archive()
    ..addFile(ArchiveFile('index.json', index.length, index))
    ..addFile(ArchiveFile('term_bank_1.json', bank.length, bank))
    ..addFile(ArchiveFile('illustration.png', png.length, png));
  File(
    p.join(dir.path, name),
  ).writeAsBytesSync(ZipEncoder().encode(archive) ?? <int>[]);
}
