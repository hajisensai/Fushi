import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/migration/migration_exporter.dart';
import 'package:fushi/src/migration/migration_manifest.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_migration_test_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File writeBytes(String name, List<int> bytes) =>
      File(p.join(tmp.path, name))..writeAsBytesSync(bytes, flush: true);

  String makeTestDb({int books = 3, int positions = 2, int userVersion = 62}) {
    final String dbPath = p.join(tmp.path, 'hibiki.db');
    final sqlite.Database db = sqlite.sqlite3.open(dbPath);
    db.execute('PRAGMA user_version = $userVersion');
    db.execute('CREATE TABLE epub_books (id INTEGER PRIMARY KEY, t TEXT)');
    db.execute('CREATE TABLE reader_positions (id INTEGER PRIMARY KEY)');
    for (int i = 0; i < books; i++) {
      db.execute("INSERT INTO epub_books (t) VALUES ('b$i')");
    }
    for (int i = 0; i < positions; i++) {
      db.execute('INSERT INTO reader_positions DEFAULT VALUES');
    }
    db.dispose();
    return dbPath;
  }

  group('MigrationManifest', () {
    test('JSON 编解码往返无损', () {
      const MigrationManifest m = MigrationManifest(
        version: MigrationManifest.currentVersion,
        batch: 'core',
        sourcePackage: 'app.fushi.reader',
        sourceAppVersion: '1.2.3+45',
        sourceSchemaVersion: 62,
        createdAt: 1754500000000,
        archiveSize: 1234,
        archiveSha256: 'abc',
        tableCounts: <String, int>{'epub_books': 3},
      );
      final MigrationManifest back = MigrationManifest.decode(m.encode());
      expect(back.toJson(), m.toJson());
    });

    test('sha256OfFile 与 verifyArchive：一致为空，篡改/截断报差异', () async {
      final File f =
          writeBytes('a.zip', List<int>.generate(70000, (i) => i % 251));
      final String digest = await MigrationManifest.sha256OfFile(f);
      final MigrationManifest m = MigrationManifest(
        version: 1,
        batch: 'core',
        sourcePackage: 'p',
        sourceAppVersion: 'v',
        sourceSchemaVersion: null,
        createdAt: 0,
        archiveSize: 70000,
        archiveSha256: digest,
        tableCounts: const <String, int>{},
      );
      expect(await m.verifyArchive(f), isEmpty);
      // 篡改一个字节 → sha 不符。
      final List<int> bytes = f.readAsBytesSync();
      bytes[100] = (bytes[100] + 1) & 0xff;
      f.writeAsBytesSync(bytes, flush: true);
      final List<String> problems = await m.verifyArchive(f);
      expect(problems, hasLength(1));
      expect(problems.single, contains('SHA-256'));
      // 截断 → size 与 sha 都不符。
      f.writeAsBytesSync(bytes.sublist(0, 50000), flush: true);
      expect(await m.verifyArchive(f), hasLength(2));
      // 文件消失。
      f.deleteSync();
      expect(await m.verifyArchive(f), hasLength(1));
    });

    test('countTablesInDb 只数存在的核对表；schemaVersion 读 user_version', () {
      final String dbPath = makeTestDb(books: 3, positions: 2);
      final Map<String, int> counts = MigrationManifest.countTablesInDb(dbPath);
      expect(counts, <String, int>{'epub_books': 3, 'reader_positions': 2});
      expect(MigrationManifest.schemaVersionOfDb(dbPath), 62);
    });

    test('countsFromArchive 从 zip 内 DB 计数；无 DB 的归档返回空', () async {
      final String dbPath = makeTestDb(books: 5, positions: 1);
      final String zipPath = p.join(tmp.path, 'core.zip');
      final ZipFileEncoder encoder = ZipFileEncoder()..create(zipPath);
      await encoder.addFile(File(dbPath), 'hibiki.db');
      encoder.close();
      final (Map<String, int> counts, int? schema) =
          await MigrationManifest.countsFromArchive(zipPath);
      expect(counts['epub_books'], 5);
      expect(schema, 62);

      final String zip2 = p.join(tmp.path, 'nodb.zip');
      final ZipFileEncoder enc2 = ZipFileEncoder()..create(zip2);
      final File other = writeBytes('other.txt', <int>[1, 2, 3]);
      await enc2.addFile(other, 'other.txt');
      enc2.close();
      final (Map<String, int> c2, int? s2) =
          await MigrationManifest.countsFromArchive(zip2);
      expect(c2, isEmpty);
      expect(s2, isNull);
    });

    test('computeForArchive 端到端：清单能验证自己的归档', () async {
      final String dbPath = makeTestDb(books: 2, positions: 4);
      final String zipPath = p.join(tmp.path, 'books.zip');
      final ZipFileEncoder encoder = ZipFileEncoder()..create(zipPath);
      await encoder.addFile(File(dbPath), 'hibiki.db');
      encoder.close();
      final MigrationManifest m = await MigrationManifest.computeForArchive(
        archivePath: zipPath,
        batchName: 'books',
        sourcePackage: 'app.fushi.reader',
        sourceAppVersion: '9.9.9',
        nowMs: 42,
        archiveContainsDb: true,
      );
      expect(m.batch, 'books');
      expect(m.sourceSchemaVersion, 62);
      expect(m.tableCounts['epub_books'], 2);
      expect(await m.verifyArchive(File(zipPath)), isEmpty);
      expect(m.diffTableCounts(<String, int>{'epub_books': 2}), isEmpty);
      expect(m.diffTableCounts(<String, int>{'epub_books': 1}), hasLength(1));
      // 导入侧缺某表（导出方老 schema 没有的表）不算差异。
      expect(m.diffTableCounts(<String, int>{}), isEmpty);
    });
  });

  group('MigrationExporter 纯逻辑', () {
    test('categoriesForBatch：每批都带核心四类，videos 永不出现', () {
      const Set<BackupCategory> core = <BackupCategory>{
        BackupCategory.progress,
        BackupCategory.statistics,
        BackupCategory.settings,
        BackupCategory.profiles,
      };
      for (final MigrationBatch b in MigrationBatch.values) {
        final Set<BackupCategory> cats = categoriesForBatch(b);
        expect(cats.containsAll(core), isTrue, reason: '$b 应带核心四类');
        expect(cats.contains(BackupCategory.videos), isFalse,
            reason: 'videos 永不打包');
      }
      expect(categoriesForBatch(MigrationBatch.books),
          contains(BackupCategory.books));
      expect(categoriesForBatch(MigrationBatch.core), core);
    });

    test('planBatches：批次集合恒定，localAudio 默认关', () {
      final MigrationExporter exporter = MigrationExporter(
        backupService: _NeverCalledBackupService(),
        transferDir: tmp,
        sourcePackage: 'app.fushi.reader',
        sourceAppVersion: 'v',
        nowMs: () => 0,
      );
      expect(
        exporter.planBatches(includeLocalAudio: false).batches,
        <MigrationBatch>[
          MigrationBatch.core,
          MigrationBatch.dictionaries,
          MigrationBatch.books,
          MigrationBatch.audiobooks,
          MigrationBatch.fonts,
        ],
      );
      expect(exporter.planBatches(includeLocalAudio: true).batches,
          contains(MigrationBatch.localAudio));
    });

    test('MigrationExportState 断点状态读写往返 + 损坏容错', () {
      final MigrationExportState s = MigrationExportState.read(tmp);
      expect(s.completed, isEmpty);
      s.completed.addAll(<String>['core', 'books']);
      s.write(tmp);
      expect(MigrationExportState.read(tmp).completed, {'core', 'books'});
      File(p.join(tmp.path, MigrationExportState.fileName))
          .writeAsStringSync('not json', flush: true);
      expect(MigrationExportState.read(tmp).completed, isEmpty);
    });
  });
}

/// planBatches/状态测试不触备份；真被调用即测试失败。
class _NeverCalledBackupService implements BackupService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('BackupService 不应在纯逻辑测试中被调用: ${invocation.memberName}');
}
