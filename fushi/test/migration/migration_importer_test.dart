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
