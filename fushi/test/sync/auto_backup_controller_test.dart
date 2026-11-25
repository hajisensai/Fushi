import 'dart:convert';
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
  Object? exportOwner;
  @override
  bool databaseAvailable = true;
  bool failService = false;
  int serviceCalls = 0;
  final List<String> failures = <String>[];
  Future<void> Function(String destPath)? srsWriter;
  String? srsBlocked;

  @override
  String get databaseDirectory => dbDir;

  @override
  AutoBackupSettings readSettings() => settings;

  @override
  bool get supportsCustomFolder => true;

  void Function()? onCreateService;

  @override
  BackupService createBackupService() {
    serviceCalls++;
    onCreateService?.call();
    if (failService) throw StateError('service unavailable');
    return BackupService(db: db, dbDirectory: dbDir, appVersion: '9.9.9');
  }

  @override
  Map<BackupCategory, String> get contentTreeRoots =>
      const <BackupCategory, String>{};

  @override
  String get srsMediaRoot => p.join(dbDir, 'srs_media');

  bool get exportActive => exportOwner != null;

  @override
  bool get backupExportActive => exportActive;

  @override
  Object? beginBackupExport() {
    if (exportOwner != null) return null;
    return exportOwner = Object();
  }

  @override
  void endBackupExport(Object token) {
    if (identical(exportOwner, token)) exportOwner = null;
  }

  @override
  void reportBackupExportProgress(double fraction) {}

  @override
  String? srsUnavailableReason() => srsBlocked;

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
    final Object other = host.beginBackupExport()!;
    expect(await controller.checkNow(), AutoBackupOutcome.busy);
    // 自动备份没拿到锁，也就不会把别人的锁放掉。
    expect(host.exportActive, isTrue);
    host.endBackupExport(other);
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
    Directory(folder).createSync();
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

  test('默认设置（D1 / D2，整库 + 挑文件）', () {
    const AutoBackupSettings s = AutoBackupSettings();
    expect(s.interval, AutoBackupInterval.daily);
    expect(s.includeSrsMedia, isFalse);
    expect(s.categories, <BackupCategory>{BackupCategory.fonts});
    expect(s.categories.every(kBackupFileCategories.contains), isTrue);
  });

  test('老偏好里的数据类别安全丢掉，只留文件类别；坏值 / 缺键回到缺省', () {
    expect(
      decodeAutoBackupCategories(
        '["settings","profiles","progress","statistics","music","srs",'
        '"fonts","books","nonsense"]',
      ),
      <BackupCategory>{BackupCategory.fonts, BackupCategory.books},
    );
    expect(decodeAutoBackupCategories('["settings","srs"]'), isEmpty);
    expect(decodeAutoBackupCategories('{bad'), kAutoBackupDefaultCategories);
    expect(decodeAutoBackupCategories(null), kAutoBackupDefaultCategories);
    expect(decodeAutoBackupCategories(42), kAutoBackupDefaultCategories);
  });

  test('默认定时点是整库：元数据带 fullDatabase，数据类别都在、没带的只是文件', () async {
    expect(await controller.backUpNow(), AutoBackupOutcome.created);
    final RestorePoint point = controller.scheduledPoints().single;
    expect(point.fullDatabase, isTrue);
    expect(
      point.categories,
      containsAll(<String>[
        'progress',
        'statistics',
        'settings',
        'profiles',
        'music',
        'srs',
        'fonts',
      ]),
    );
    expect(point.categories, isNot(contains('books')));
    expect(
      point.excludedCategories,
      unorderedEquals(<String>[
        'dictionary',
        'books',
        'audiobooks',
        'videos',
        'localAudio',
        'games',
      ]),
    );
    final InputFileStream input = InputFileStream(point.archivePath!);
    try {
      final ArchiveFile metaEntry = ZipDecoder()
          .decodeBuffer(input)
          .findFile('backup_meta.json')!;
      final BackupMeta meta = BackupMeta.tryParse(
        utf8.decode(metaEntry.content as List<int>),
      )!;
      expect(meta.fullDatabase, isTrue);
    } finally {
      await input.close();
    }
  });

  test('复习库还在等升级：照样备份其余数据，复习记成没带（恢复时保留本机那份），状态说明', () async {
    host.srsBlocked = 'needsMigration';
    expect(await controller.backUpNow(), AutoBackupOutcome.created);
    final RestorePoint point = controller.scheduledPoints().single;
    expect(point.categories, isNot(contains('srs')));
    expect(point.excludedCategories, contains('srs'));
    expect(controller.status.value.missingData, <String>['srs']);
    expect(host.failures, isEmpty);
    final InputFileStream input = InputFileStream(point.archivePath!);
    try {
      final ArchiveFile metaEntry = ZipDecoder()
          .decodeBuffer(input)
          .findFile('backup_meta.json')!;
      final BackupMeta meta = BackupMeta.tryParse(
        utf8.decode(metaEntry.content as List<int>),
      )!;
      // 恢复侧（_prepareSrsRestoreUnits）看到 srs 在排除表里就不碰本机复习库。
      expect(meta.excludedCategories, contains('srs'));
      expect(meta.fullDatabase, isTrue);
    } finally {
      await input.close();
    }
    // 状态文件往返保留它；升级完成后的下一份不再带这条。
    expect(
      AutoBackupStatus.fromJson(
        jsonDecode(jsonEncode(controller.status.value.toJson())),
      ).missingData,
      <String>['srs'],
    );
    host.srsBlocked = null;
    expect(await controller.backUpNow(), AutoBackupOutcome.created);
    expect(controller.status.value.missingData, isEmpty);
  });

  test('上次成功的那份被删了：指纹没变也不跳过，照样新建', () async {
    expect(await controller.checkNow(), AutoBackupOutcome.created);
    final RestorePoint first = controller.scheduledPoints().single;
    Directory(first.directory).deleteSync(recursive: true);
    now = now.add(const Duration(days: 2));
    expect(await controller.checkNow(), AutoBackupOutcome.created);
    expect(controller.scheduledPoints(), hasLength(1));
  });

  test('换了文件夹：存储根进签名，新文件夹里照样建', () async {
    expect(await controller.checkNow(), AutoBackupOutcome.created);
    final String folder = p.join(root.path, 'moved');
    Directory(folder).createSync();
    host.settings = host.settings.copyWith(customFolder: () => folder);
    now = now.add(const Duration(days: 2));
    expect(await controller.checkNow(), AutoBackupOutcome.created);
    expect(
      p.isWithin(folder, controller.scheduledPoints().single.directory),
      isTrue,
    );
  });

  test('一进 _run 就拿锁：指纹还在算时别的导出拿不到锁；跑完放的是自己的锁', () async {
    final Future<AutoBackupOutcome> run = controller.checkNow();
    // checkNow → _run 在第一个 await 之前就拿了锁。
    expect(host.beginBackupExport(), isNull);
    expect(host.exportActive, isTrue);
    expect(await run, AutoBackupOutcome.created);
    expect(host.exportActive, isFalse);
  });

  test('库不可用（导入 / 替换中、已关库）：不跑、不建服务', () async {
    host.databaseAvailable = false;
    expect(await controller.checkNow(), AutoBackupOutcome.busy);
    expect(await controller.backUpNow(), AutoBackupOutcome.busy);
    expect(host.serviceCalls, 0);
    expect(host.exportActive, isFalse);
    expect(controller.status.value.lastResult, isNull);
  });

  test('写到一半进程没了：下次启动记成「被打断」、提示一次、清半截目录，这一时段不再重跑', () async {
    final RestorePointStore store = controller.scheduledStore();
    final RestorePointDraft half = store.begin(
      kind: RestorePointKind.scheduled,
      nowMs: now.millisecondsSinceEpoch,
    );
    // 模拟「进程没了」：草稿登记只在进程内，换进程就不在了。
    store.discard(half);
    Directory(half.directory).createSync(recursive: true);
    File(
      p.join(half.directory, kRestorePointArchiveFileName),
    ).writeAsStringSync('half');
    writeAutoBackupStatus(
      dbDir,
      AutoBackupStatus(runningSinceMs: now.millisecondsSinceEpoch),
    );
    final AutoBackupController next = AutoBackupController(
      host: host,
      clock: () => now,
    );
    try {
      expect(next.recoverInterruptedRun(), isTrue);
      final AutoBackupStatus status = next.status.value;
      expect(status.lastResult, AutoBackupResult.failed);
      expect(status.lastError, kAutoBackupErrorInterrupted);
      expect(status.runningSinceMs, isNull);
      expect(status.lastInterruptedMs, now.millisecondsSinceEpoch);
      expect(host.failures, <String>[kAutoBackupErrorInterrupted]);
      expect(Directory(half.directory).existsSync(), isFalse);
      // 再认一次不会重复提示。
      expect(next.recoverInterruptedRun(), isFalse);
      expect(host.failures, hasLength(1));
      // 同一时段（今天）不重跑；第二天照常。
      now = now.add(const Duration(hours: 3));
      expect(await next.checkNow(), AutoBackupOutcome.notDue);
      now = now.add(const Duration(days: 1));
      expect(await next.checkNow(), AutoBackupOutcome.created);
      expect(next.status.value.lastInterruptedMs, isNull);
    } finally {
      next.dispose();
    }
  });

  test('写备份期间落「开始」标记，成功后清掉', () async {
    AutoBackupStatus? during;
    host.onCreateService = () => during = readAutoBackupStatus(dbDir);
    expect(await controller.backUpNow(), AutoBackupOutcome.created);
    expect(during?.runningSinceMs, isNotNull);
    expect(controller.status.value.runningSinceMs, isNull);
    expect(readAutoBackupStatus(dbDir).runningSinceMs, isNull);
  });

  test('自定义文件夹不在：按「文件夹不可用」失败，不在本机盘上建它', () async {
    final String folder = p.join(root.path, 'unplugged', 'backups');
    host.settings = host.settings.copyWith(customFolder: () => folder);
    expect(await controller.checkNow(), AutoBackupOutcome.failed);
    expect(Directory(folder).existsSync(), isFalse);
    expect(
      controller.status.value.lastError,
      kAutoBackupErrorFolderUnavailable,
    );
    expect(host.failures, <String>[kAutoBackupErrorFolderUnavailable]);
    expect(host.exportActive, isFalse);
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
