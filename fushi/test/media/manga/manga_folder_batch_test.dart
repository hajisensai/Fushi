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
import 'package:fushi/src/epub/epub_storage.dart';
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi/src/media/manga/import/manga_folder_batch.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
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
      expect(_classifyWithRealPredicates(root.path),
          ImportCarrier.mangaBatchFolder);
    });

    test('页图目录仍是 mangaFolder（修复不得改动既有路径）', () {
      File(p.join(root.path, '001.png')).writeAsBytesSync(_pngBytes());

      expect(MangaModule.directoryHasPageImages(root.path), isTrue);
      expect(_classifyWithRealPredicates(root.path), ImportCarrier.mangaFolder);
    });

    test('页图与整卷文件同时在场 → 页图这条解释优先', () {
      File(p.join(root.path, '001.png')).writeAsBytesSync(_pngBytes());
      _writeCbz(root, 'vol1.cbz');

      expect(_classifyWithRealPredicates(root.path), ImportCarrier.mangaFolder);
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

      final List<String> names = mangaCarrierFilesIn(root)
          .map((File f) => p.basename(f.path))
          .toList();
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

      final MangaBatchImportReport report =
          await importMangaBatchFolder(db: db, path: root.path);

      expect(report.importedCount, 2);
      expect(report.failedCount, 0);
      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(
        books.map((EpubBookRow b) => b.title).toList()..sort(),
        <String>['銀河英雄伝説 01', '銀河英雄伝説 02'],
      );
      expect(books.every((EpubBookRow b) => b.format == 'manga'), isTrue);
    });

    test('一卷坏包不中断整批：其余卷照样进库', () async {
      _writeCbz(root, 'vol1.cbz');
      File(p.join(root.path, 'vol2.cbz'))
          .writeAsBytesSync(<int>[0x00, 0x01, 0x02, 0x03]); // 不是 zip
      _writeCbz(root, 'vol3.cbz');

      final MangaBatchImportReport report =
          await importMangaBatchFolder(db: db, path: root.path);

      expect(report.importedCount, 2, reason: '坏的那一卷不该把另外两卷一起废掉');
      expect(report.failedCount, 1);
      expect(
        report.volumes
            .firstWhere((MangaBatchVolumeResult v) =>
                v.status == MangaBatchVolumeStatus.failed)
            .name,
        'vol2.cbz',
      );
      expect((await db.getAllEpubBooks()).length, 2);
    });

    test('自带插图的 Yomitan 词典 zip 被如实计为「不是漫画」，不落库', () async {
      _writeCbz(root, 'vol1.cbz');
      _writeYomitanDictZip(root, 'dict.zip');

      final MangaBatchImportReport report =
          await importMangaBatchFolder(db: db, path: root.path);

      expect(report.importedCount, 1);
      expect(report.notMangaCount, 1);
      expect((await db.getAllEpubBooks()).length, 1,
          reason: '词典包被导成一本只有插图的垃圾「漫画」是糟蹋用户数据');
    });

    test('重跑同一个文件夹是幂等的：已在库的卷计入跳过而不是复制一份', () async {
      _writeCbz(root, 'vol1.cbz');

      final MangaBatchImportReport first =
          await importMangaBatchFolder(db: db, path: root.path);
      expect(first.importedCount, 1);

      final MangaBatchImportReport second =
          await importMangaBatchFolder(db: db, path: root.path);
      expect(second.importedCount, 0);
      expect(second.duplicateCount, 1);
      expect((await db.getAllEpubBooks()).length, 1,
          reason: '批量路径用 skip 策略，不得留下 `vol1 (2)`');
    });

    test('一卷都没进来时报告 isEmpty（调用方据此报失败而不是「成功 0 卷」）', () async {
      _writeYomitanDictZip(root, 'dict.zip');

      final MangaBatchImportReport report =
          await importMangaBatchFolder(db: db, path: root.path);

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
}

ImportCarrier _classifyWithRealPredicates(String path) => classifyImportCarrier(
      path,
      isDirectory: (String pth) => Directory(pth).existsSync(),
      isImageArchive: MangaModule.isImageArchive,
      directoryHasPageImages: MangaModule.directoryHasPageImages,
      directoryCarrierFileCount: MangaModule.directoryCarrierFileCount,
    );

Uint8List _pngBytes() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 20, height: 40)));

void _writeCbz(Directory dir, String name) {
  final Uint8List png = _pngBytes();
  final Archive archive = Archive()
    ..addFile(ArchiveFile('001.png', png.length, png));
  File(p.join(dir.path, name))
      .writeAsBytesSync(ZipEncoder().encode(archive) ?? <int>[]);
}

/// 词典包与图片包同形，唯一的结构指纹是 `index.json` + `*_bank_*.json`；这里连
/// 插图一起放，正是「只看有没有图片」会误判的那种包。
void _writeYomitanDictZip(Directory dir, String name) {
  final Uint8List png = _pngBytes();
  final List<int> index =
      utf8.encode('{"title":"Test Dict","format":3,"revision":"1"}');
  final List<int> bank = utf8.encode('[]');
  final Archive archive = Archive()
    ..addFile(ArchiveFile('index.json', index.length, index))
    ..addFile(ArchiveFile('term_bank_1.json', bank.length, bank))
    ..addFile(ArchiveFile('illustration.png', png.length, png));
  File(p.join(dir.path, name))
      .writeAsBytesSync(ZipEncoder().encode(archive) ?? <int>[]);
}
