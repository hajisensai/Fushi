import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/migration/migration_exporter.dart';
import 'package:fushi/src/migration/migration_importer.dart';
import 'package:fushi/src/migration/migration_manifest.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late Directory tmp;
  const MigrationImporter importer = MigrationImporter();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_import_test_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String makeDb(String name, {int books = 0, int positions = 0}) {
    final String dbPath = p.join(tmp.path, name);
    final sqlite.Database db = sqlite.sqlite3.open(dbPath);
    db.execute('PRAGMA user_version = 62');
    db.execute('CREATE TABLE epub_books (id INTEGER PRIMARY KEY)');
    db.execute('CREATE TABLE reader_positions (id INTEGER PRIMARY KEY)');
    for (int i = 0; i < books; i++) {
      db.execute('INSERT INTO epub_books DEFAULT VALUES');
    }
    for (int i = 0; i < positions; i++) {
      db.execute('INSERT INTO reader_positions DEFAULT VALUES');
    }
    db.dispose();
    return dbPath;
  }

  Future<void> writeBatch(MigrationBatch batch,
      {int books = 0, int positions = 0}) async {
    final String dbPath =
        makeDb('src_${batch.name}.db', books: books, positions: positions);
    final String zipPath =
        p.join(tmp.path, MigrationExporter.archiveNameFor(batch));
    final ZipFileEncoder enc = ZipFileEncoder()..create(zipPath);
    await enc.addFile(File(dbPath), 'hibiki.db');
    enc.close();
    final MigrationManifest m = await MigrationManifest.computeForArchive(
      archivePath: zipPath,
      batchName: batch.name,
      sourcePackage: 'app.hibiki.reader',
      sourceAppVersion: 'v',
      nowMs: 1,
      archiveContainsDb: true,
    );
    File(p.join(tmp.path, MigrationExporter.manifestNameFor(batch)))
        .writeAsStringSync(m.encode(), flush: true);
  }

  group('缺「所有文件访问权限」时的扫描行为（用户实测翻车形态）', () {
    test('短路返回，绝不产出「清单损坏」这种假话', () async {
      // 真实翻车：中转目录由老包创建，分区存储下 Fushi 没有 MANAGE_EXTERNAL_
      // STORAGE 就连 683 字节的清单都读不到，6 批全报「清单损坏」。文件其实
      // 逐个 sha256 都对得上——报「损坏」会把用户推去重新导出 11GB，而重导
      // 多少次都一样。
      await writeBatch(MigrationBatch.core, positions: 2);
      await writeBatch(MigrationBatch.books, books: 3);

      final MigrationScanResult r =
          await importer.scan(tmp, permissionGranted: false);

      expect(r.storagePermissionGranted, isFalse);
      expect(r.problems, isEmpty, reason: '没权限不是「数据有问题」，一条批次级错误都不该产生');
      expect(r.ready, isEmpty);
      expect(r.hasAnything, isFalse);
    });

    test('有权限时照常逐批扫（不因新增的门把正常路径掐掉）', () async {
      await writeBatch(MigrationBatch.core, positions: 2);
      final MigrationScanResult r =
          await importer.scan(tmp, permissionGranted: true);
      expect(r.storagePermissionGranted, isTrue);
      expect(r.ready.map((MigrationImportBatch b) => b.batch),
          <MigrationBatch>[MigrationBatch.core]);
    });
  });

  test('scan 逐批回调进度（11GB 全量 sha256 要几分钟，不报进度＝和卡死没区别）', () async {
    await writeBatch(MigrationBatch.core, positions: 1);
    final List<String> seen = <String>[];
    int? seenTotal;
    await importer.scan(
      tmp,
      onProgress: (MigrationBatch batch, int done, int total) {
        seen.add('${batch.name}@$done');
        seenTotal = total;
      },
    );
    expect(seenTotal, MigrationBatch.values.length);
    // 每一批都要报，含目录里不存在的批——否则进度会在缺批处停住不动。
    expect(seen.length, MigrationBatch.values.length);
    expect(seen.first, 'core@0', reason: 'done 从 0 起算，调用方 +1 显示');
  });

  // 权限拒绝（PathAccessException）无法在 Windows 单测里可靠制造——chmod 000
  // 没有 Dart API，用目录顶替文件又会先被 existsSync 挡成「清单缺失」。故这条
  // 不变式落在源码层：读失败必须与「内容损坏」分开归类。
  test('源码守卫：清单/归档读失败与「清单损坏」分开归类，且 catch-all 在后', () {
    final String src =
        File('lib/src/migration/migration_importer.dart').readAsStringSync();

    final int manifestFsIdx = src.indexOf('on FileSystemException catch');
    expect(manifestFsIdx, greaterThan(-1),
        reason: '没有 FileSystemException 专门分支＝权限错误又会被吞成「清单损坏」');

    final int corruptIdx = src.indexOf(r"'清单损坏: $e'");
    expect(corruptIdx, greaterThan(manifestFsIdx),
        reason: 'catch-all 必须排在专门分支之后，否则专门分支永远够不着');

    expect(src.substring(manifestFsIdx, corruptIdx), contains('无法读取'),
        reason: '读失败的文案必须说「无法读取」，不能说「损坏」——'
            '后者会把用户推去重新导出 11GB，而重导多少次都一样');

    // 归档校验同样要兜住：不兜的话异常炸穿整个 scan，连「哪批出问题」都丢了。
    expect(src.indexOf('on FileSystemException catch', corruptIdx),
        greaterThan(corruptIdx),
        reason: 'verifyArchive 也必须有 FileSystemException 兜底');
  });

  test('scan：齐全批次通过、损坏批次进 problems 且不阻塞其他批', () async {
    await writeBatch(MigrationBatch.core, positions: 2);
    await writeBatch(MigrationBatch.books, books: 3, positions: 2);
    // 弄坏 books 的归档（截断）。
    final File booksZip = File(p.join(
        tmp.path, MigrationExporter.archiveNameFor(MigrationBatch.books)));
    final List<int> bytes = booksZip.readAsBytesSync();
    booksZip.writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2), flush: true);

    final MigrationScanResult r = await importer.scan(tmp);
    expect(r.ready.map((MigrationImportBatch b) => b.batch),
        <MigrationBatch>[MigrationBatch.core]);
    expect(r.problems.keys, <String>['books']);
    expect(r.problems['books']!.join(), contains('不符'));
    // 问题批文件保留（重传通道）。
    expect(booksZip.existsSync(), isTrue);
  });

  test('scan：缺清单/清单损坏分别报出；空目录无事', () async {
    expect(
        (await importer.scan(Directory(p.join(tmp.path, 'nope')))).hasAnything,
        isFalse);
    await writeBatch(MigrationBatch.core, positions: 1);
    File(p.join(
            tmp.path, MigrationExporter.manifestNameFor(MigrationBatch.core)))
        .writeAsStringSync('junk', flush: true);
    final MigrationScanResult r = await importer.scan(tmp);
    expect(r.problems['core']!.single, contains('清单损坏'));
  });

  test('aggregateExpectedCounts 取逐表最大；verifyImportedCounts 不足才红', () async {
    await writeBatch(MigrationBatch.core, positions: 5);
    await writeBatch(MigrationBatch.books, books: 3, positions: 5);
    final MigrationScanResult r = await importer.scan(tmp);
    final Map<String, int> expected =
        MigrationImporter.aggregateExpectedCounts(r.ready);
    expect(expected, {'epub_books': 3, 'reader_positions': 5});

    final String merged = makeDb('merged.db', books: 3, positions: 7);
    expect(
        MigrationImporter.verifyImportedCounts(
            dbPath: merged, expected: expected),
        isEmpty,
        reason: '实际≥期望（本地新增行不算差异）');
    final String broken = makeDb('broken.db', books: 1, positions: 5);
    final List<String> problems = MigrationImporter.verifyImportedCounts(
        dbPath: broken, expected: expected);
    expect(problems.single, contains('epub_books'));
  });

  test('deleteBatchFiles + cleanupTransferDirIfEmpty', () async {
    await writeBatch(MigrationBatch.core, positions: 1);
    importer.deleteBatchFiles(tmp, MigrationBatch.core);
    expect(
        File(p.join(tmp.path,
                MigrationExporter.archiveNameFor(MigrationBatch.core)))
            .existsSync(),
        isFalse);
    // 目录里已无 zip → 整目录清掉。
    importer.cleanupTransferDirIfEmpty(tmp);
    expect(tmp.existsSync(), isFalse);
  });
}
