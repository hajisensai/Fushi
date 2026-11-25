import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_controller.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_settings.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_status.dart';
import 'package:fushi/src/sync/auto_backup/restore_point_catalog.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'temp_dir_cleanup.dart';

/// 假宿主：真的备份服务 + 临时库目录，导出锁 / 提示记在字段里。
class _FakeHost implements AutoBackupHost {
  _FakeHost(this.dbDir, this.db);

  final String dbDir;
  FushiDatabase db;
  AutoBackupSettings settings = const AutoBackupSettings();
  bool exportActive = false;
  bool failService = false;
  final List<String> failures = <String>[];
  Future<void> Function(String destPath)? srsWriter;

  @override
  String get databaseDirectory => dbDir;

  @override
  AutoBackupSettings readSettings() => settings;

  @override
  bool get supportsCustomFolder => true;

  @override
  BackupService createBackupService() {
    if (failService) throw StateError('service unavailable');
    return BackupService(db: db, dbDirectory: dbDir, appVersion: '9.9.9');
  }

  @override
  Map<BackupCategory, String> get contentTreeRoots =>
      const <BackupCategory, String>{};

  @override
  String get srsMediaRoot => p.join(dbDir, 'srs_media');

  @override
  bool get backupExportActive => exportActive;

  @override
  void beginBackupExport() => exportActive = true;

  @override
  void endBackupExport() => exportActive = false;

  @override
  void reportBackupExportProgress(double fraction) {}

  @override
  Future<Future<void> Function(String destPath)?> srsSnapshotWriter() async =>
      srsWriter;

  @override
  void notifyFailure(String reason) => failures.add(reason);

  @override
  void notifyPreOperationFailure(String reason) => failures.add(reason);
}

void main() {
  late Directory root;
  late String dbDir;
  late FushiDatabase db;
  late _FakeHost host;
  late DateTime now;
  late AutoBackupController controller;

  Future<void> addStat(String title) => db.customStatement(
    'INSERT INTO reading_statistics (title, date_key, characters_read, '
    'reading_time_ms, last_statistic_modified) '
    "VALUES (?, '2026-11-01', 100, 1000, 1)",
    <Object?>[title],
  );

  Future<Set<String>> statTitles(FushiDatabase d) async => <String>{
    for (final row
        in await d.customSelect('SELECT title FROM reading_statistics').get())
      row.read<String>('title'),
  };

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi_auto_backup_');
    dbDir = p.join(root.path, 'db');
    Directory(dbDir).createSync(recursive: true);
    db = FushiDatabase(dbDir);
    await addStat('kept-before-backup');
    host = _FakeHost(dbDir, db);
    now = DateTime(2026, 11, 25, 9);
    controller = AutoBackupController(host: host, clock: () => now);
  });

  tearDown(() async {
    controller.dispose();
    await db.close();
    await cleanupTempDir(root);
  });

  test('到期 → 建定时还原点（压缩 zip + 元数据），状态记成功', () async {
    expect(await controller.checkNow(), AutoBackupOutcome.created);
    final RestorePoint point = controller.scheduledPoints().single;
    expect(point.kind, RestorePointKind.scheduled);
    expect(File(point.archivePath!).existsSync(), isTrue);
    expect(point.categories, containsAll(<String>['statistics', 'srs']));
    expect(point.excludedCategories, contains('books'));
    expect(point.includesSrsMedia, isFalse);
    final AutoBackupStatus status = controller.status.value;
    expect(status.lastResult, AutoBackupResult.success);
    expect(status.lastSuccessPointId, point.id);
    expect(status.lastSuccessBytes, point.totalBytes);
    // 状态写在文件里，新控制器读得回来。
    expect(readAutoBackupStatus(dbDir).lastSuccessPointId, point.id);
    expect(host.exportActive, isFalse);
    // 定时备份的库条目是 deflate 压缩的（手动导出是 STORE）。
    final InputFileStream input = InputFileStream(point.archivePath!);
    try {
      final ArchiveFile entry = ZipDecoder()
          .decodeBuffer(input)
          .findFile('fushi.db')!;
      expect(entry.compressionType, ArchiveFile.DEFLATE);
    } finally {
      await input.close();
    }
  });

  test('没到期不跑；到期但数据没变记「跳过」；立即备份照样建', () async {
    expect(await controller.checkNow(), AutoBackupOutcome.created);
    now = now.add(const Duration(hours: 1));
    expect(await controller.checkNow(), AutoBackupOutcome.notDue);
    now = now.add(const Duration(days: 2));
    expect(await controller.checkNow(), AutoBackupOutcome.skippedNoChanges);
    expect(controller.status.value.lastResult, AutoBackupResult.skipped);
    expect(controller.scheduledPoints().length, 1);
    // 跳过也算这一期满足：马上再查不到期。
    expect(await controller.checkNow(), AutoBackupOutcome.notDue);
    expect(await controller.backUpNow(), AutoBackupOutcome.created);
    expect(controller.scheduledPoints().length, 2);
  });

  test('数据变了、内容设置变了都不跳过', () async {
    expect(await controller.checkNow(), AutoBackupOutcome.created);
    now = now.add(const Duration(days: 2));
    await addStat('changed');
    expect(await controller.checkNow(), AutoBackupOutcome.created);
    now = now.add(const Duration(days: 2));
    host.settings = host.settings.copyWith(includeSrsMedia: true);
    expect(await controller.checkNow(), AutoBackupOutcome.created);
  });

  test('已有导出在跑：不跑（busy）；关着：disabled', () async {
    host.exportActive = true;
    expect(await controller.checkNow(), AutoBackupOutcome.busy);
    host.exportActive = false;
    host.settings = const AutoBackupSettings(interval: AutoBackupInterval.off);
    expect(await controller.checkNow(), AutoBackupOutcome.disabled);
    expect(controller.scheduledPoints(), isEmpty);
  });

  test('失败：记状态、提示一次、不留半截目录、导出锁放开', () async {
    host.failService = true;
    expect(await controller.checkNow(), AutoBackupOutcome.failed);
    expect(controller.status.value.lastRunFailed, isTrue);
    expect(host.failures, hasLength(1));
    expect(host.exportActive, isFalse);
    final Directory store = Directory(p.join(dbDir, kRestorePointsDirName));
    expect(store.listSync().whereType<Directory>(), isEmpty);
    // 失败不算满足：下次检查照样到期。
    host.failService = false;
    expect(await controller.checkNow(), AutoBackupOutcome.created);
  });

  test('自定义文件夹：定时还原点写进去，目录清单一并列出', () async {
    final String folder = p.join(root.path, 'custom');
    host.settings = host.settings.copyWith(customFolder: () => folder);
    expect(await controller.backUpNow(), AutoBackupOutcome.created);
    final RestorePoint point = controller.scheduledPoints().single;
    expect(p.isWithin(folder, point.directory), isTrue);
    final List<RestorePointEntry> entries = listRestorePointEntries(
      dbDirectory: dbDir,
      extraRoots: <String>[folder],
    );
    expect(entries.single.kindName, 'scheduled');
    expect(entries.single.canFillIn, isTrue);
    expect(entries.single.canReplace, isTrue);
  });

  test('定时还原点往返：补回缺少的内容 / 替换', () async {
    expect(await controller.backUpNow(), AutoBackupOutcome.created);
    final RestorePoint point = controller.scheduledPoints().single;
    await db.customStatement(
      'DELETE FROM reading_statistics WHERE title = ?',
      <Object?>['kept-before-backup'],
    );
    await addStat('added-after-backup');

    // 补回：从 zip 解出主库，只补缺合并 → 删掉的那行回来，后加的那行还在。
    final String extracted = p.join(root.path, 'extracted.db');
    await BackupRestoreService.extractBackupDatabase(
      zipPath: point.archivePath!,
      destPath: extracted,
    );
    await db.close();
    await BackupRestoreService.mergeFromOverwriteSnapshot(
      dbDirectory: dbDir,
      snapshotPath: extracted,
    );
    db = FushiDatabase(dbDir);
    expect(await statTitles(db), <String>{
      'kept-before-backup',
      'added-after-backup',
    });

    // 替换：整体回到备份那一刻 → 后加的那行没了。
    await db.close();
    await BackupRestoreService.restoreBackup(
      dbDirectory: dbDir,
      zipPath: point.archivePath!,
    );
    db = FushiDatabase(dbDir);
    host.db = db;
    expect(await statTitles(db), <String>{'kept-before-backup'});
  });

  test('操作前还原点：主库 + 复习库快照，可按库换回', () async {
    final String liveSrs = p.join(dbDir, 'srs4.db');
    void writeSrs(String path, String marker) {
      final sqlite3.Database s = sqlite3.sqlite3.open(path);
      s.execute('CREATE TABLE IF NOT EXISTS t (v TEXT)');
      s.execute('DELETE FROM t');
      s.execute('INSERT INTO t VALUES (?)', <Object?>[marker]);
      s.close();
    }

    writeSrs(liveSrs, 'srs-before');
    host.srsWriter = (String dest) async => File(liveSrs).copySync(dest);
    final RestorePoint point = await controller.createPreOperationPoint(
      kRestorePointReasonReplace,
    );
    expect(point.kind, RestorePointKind.preOperation);
    expect(point.reason, 'replace');
    expect(point.fromSchema, kFushiDbSchemaVersion);
    expect(point.rawDatabasePath(RestorePointDatabase.fushi), isNotNull);
    expect(point.rawDatabasePath(RestorePointDatabase.srs), isNotNull);

    await addStat('after-point');
    writeSrs(liveSrs, 'srs-after');
    final RestorePointEntry entry = listRestorePointEntries(
      dbDirectory: dbDir,
    ).firstWhere((RestorePointEntry e) => e.id == point.id);
    expect(entry.canReplace, isTrue);
    await db.close();
    await RestorePointStore(dbDir).rollback(<RestorePointRollbackPlan>[
      RestorePointRollbackPlan(
        target: point,
        database: RestorePointDatabase.fushi,
      ),
      RestorePointRollbackPlan(
        target: point,
        database: RestorePointDatabase.srs,
      ),
    ]);
    db = FushiDatabase(dbDir);
    expect(await statTitles(db), isNot(contains('after-point')));
    final sqlite3.Database s = sqlite3.sqlite3.open(liveSrs);
    expect(s.select('SELECT v FROM t').first.columnAt(0), 'srs-before');
    s.close();
    // 换下来的当前库留成回滚前还原点。
    expect(
      RestorePointStore(dbDir).list().where(
        (RestorePoint e) => e.kind == RestorePointKind.preRollback,
      ),
      hasLength(2),
    );
  });

  test('takePreOperationRestorePoint：没登记控制器时什么都不做', () async {
    registerAutoBackupController(null);
    expect(
      await takePreOperationRestorePoint(kRestorePointReasonSyncDownload),
      isNull,
    );
    registerAutoBackupController(controller);
    final RestorePoint? point = await takePreOperationRestorePoint(
      kRestorePointReasonSyncDownload,
    );
    expect(point?.reason, 'sync_download');
    registerAutoBackupController(null);
  });

  test('存量副本（检查数据库的备份）一并列出，只能补回 / 不能替换', () async {
    File(
      p.join(dbDir, databaseCheckBackupFileName(1700000000000)),
    ).writeAsBytesSync(<int>[1, 2, 3]);
    final RestorePointEntry entry = listRestorePointEntries(
      dbDirectory: dbDir,
    ).single;
    expect(entry.kindName, 'db_check');
    expect(entry.createdAt, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(entry.canFillIn, isTrue);
    expect(entry.canReplace, isFalse);
    deleteRestorePointEntry(entry);
    expect(listRestorePointEntries(dbDirectory: dbDir), isEmpty);
  });

  test('默认设置（D1 / D2）', () {
    const AutoBackupSettings s = AutoBackupSettings();
    expect(s.interval, AutoBackupInterval.daily);
    expect(s.includeSrsMedia, isFalse);
    expect(s.categories, kAutoBackupDefaultCategories);
    expect(
      s.categories.contains(BackupCategory.books) ||
          s.categories.contains(BackupCategory.videos),
      isFalse,
    );
  });

  test('statTitles 辅助函数自检', () async {
    expect(await statTitles(db), <String>{'kept-before-backup'});
    final rows = await db
        .customSelect(
          'SELECT COUNT(*) AS n FROM reading_statistics WHERE title = ?',
          variables: <Variable<Object>>[Variable<String>('kept-before-backup')],
        )
        .get();
    expect(rows.single.read<int>('n'), 1);
  });
}
