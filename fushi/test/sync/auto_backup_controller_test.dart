import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_controller.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_messages.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_settings.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_status.dart';
import 'package:fushi/src/sync/auto_backup/backup_folder_mirror.dart';
import 'package:fushi/src/sync/auto_backup/backup_folder_platform.dart';
import 'package:fushi/src/sync/auto_backup/cloud_backup_mirror.dart';
import 'package:fushi/src/sync/auto_backup/restore_point_catalog.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'fake_asset_store.dart';
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

  @override
  BackupFolderPlatform mirrorPlatform = const UnsupportedBackupFolderPlatform();

  final List<String> mirrorFailures = <String>[];
  final List<AutoBackupMirrorFolder> savedMirrorFolders =
      <AutoBackupMirrorFolder>[];

  @override
  Future<({String id, String name})> deviceIdentity() async =>
      (id: 'device-1', name: 'Test phone');

  @override
  Future<void> saveMirrorFolder(AutoBackupMirrorFolder folder) async {
    savedMirrorFolders.add(folder);
    settings = settings.copyWith(mirrorFolder: () => folder);
  }

  @override
  void notifyMirrorFailure(AutoBackupMirrorKind kind, String reason) =>
      mirrorFailures.add(
        kind == AutoBackupMirrorKind.folder ? reason : '${kind.name}:$reason',
      );

  /// 云端副本目标（null = 没有可用的同步后端）。
  AutoBackupMirrorTarget? cloud;

  /// 非空时 [cloudTarget] 抛它（后端配置了但登录不上 / 宿主漏掉没归类的错误）。
  Object? cloudError;
  bool unmetered = true;

  /// 非空时 [networkUnmetered] 先等它（模拟查网络的那一下 await）。
  Future<void>? unmeteredGate;

  @override
  Future<AutoBackupMirrorTarget?> cloudTarget() async {
    final Object? error = cloudError;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
    return cloud;
  }

  @override
  Future<String?> cloudBackendLabel() async => cloud?.label;

  /// 服务器副本目标（null = 没有设置互联服务器）。
  AutoBackupMirrorTarget? server;

  /// 非空时 [serverTarget] 抛它（配对失效 / 连不上）。
  Object? serverError;

  @override
  Future<AutoBackupMirrorTarget?> serverTarget() async {
    final Object? error = serverError;
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
    return server;
  }

  @override
  Future<String?> serverLabel() async => server?.label;

  @override
  Future<bool> networkUnmetered() async {
    final Future<void>? gate = unmeteredGate;
    if (gate != null) await gate;
    return unmetered;
  }
}

/// 假的用户文件夹平台：「文件夹」是临时目录，经真的 [IoBackupFolderMirror] 读写。
class _FakeFolderPlatform implements BackupFolderPlatform {
  _FakeFolderPlatform(this.roots);

  /// 句柄 → 目录。
  final Map<String, String> roots;
  bool available = true;
  bool failUpload = false;

  /// 非空时 open 先等它（模拟卡住的提供者）。
  Future<void>? listGate;

  /// 上传前等它（模拟卡住的上传）；[uploadStarted] 在开始上传时完成。
  Future<void>? uploadGate;
  Completer<void>? uploadStarted;

  /// 这些 id 删不掉（修剪 / 清理失败）。
  final Set<String> undeletable = <String>{};

  /// 所有删除都失败。
  bool failAllDeletes = false;

  /// 关目标时抛错（iOS 停止访问书签失败）。
  bool failClose = false;
  int opens = 0;
  int closes = 0;

  @override
  bool get supported => true;

  @override
  Future<AutoBackupMirrorFolder?> pick() async => null;

  @override
  Future<void> forget(AutoBackupMirrorFolder folder) async {}

  @override
  Future<BackupFolderSession> open(AutoBackupMirrorFolder folder) async {
    opens++;
    final Future<void>? gate = listGate;
    if (gate != null) await gate;
    final String? root = roots[folder.handle];
    if (!available || root == null) {
      throw BackupFolderUnavailableException(folder.label);
    }
    final IoBackupFolderMirror io = IoBackupFolderMirror(root);
    return BackupFolderSession(
      mirror: _ScriptedMirror(io, this),
      close: () async {
        closes++;
        if (failClose) throw StateError('stopAccessingBookmark failed');
      },
    );
  }
}

class _ScriptedMirror implements BackupFolderMirror {
  _ScriptedMirror(this.inner, this.platform);

  final IoBackupFolderMirror inner;
  final _FakeFolderPlatform platform;

  @override
  Future<MirrorFolderListing> list() => inner.list();

  @override
  Future<void> upload(RestorePoint local, {required String metaText}) async {
    platform.uploadStarted?.complete();
    final Future<void>? gate = platform.uploadGate;
    if (gate != null) await gate;
    if (platform.failUpload) {
      // 写了一半就失败：留下没有元数据的半截目录。
      final Directory dir = Directory(p.join(inner.root, local.id))
        ..createSync(recursive: true);
      File(
        p.join(dir.path, kRestorePointArchiveFileName),
      ).writeAsStringSync('ha');
      throw FileSystemException('disk full', p.join(dir.path, 'x'));
    }
    return inner.upload(local, metaText: metaText);
  }

  @override
  Future<void> download(MirroredRestorePoint copy, String destDirectory) =>
      inner.download(copy, destDirectory);

  @override
  Future<void> delete(String id) async {
    if (platform.failAllDeletes || platform.undeletable.contains(id)) {
      throw FileSystemException('locked', id);
    }
    return inner.delete(id);
  }

  @override
  Future<void> deleteCopy(MirroredRestorePoint copy) => delete(copy.id);
}

/// 在 [folder] 里造一份别人（或本机）写的副本。
void _writeFolderCopy(
  String folder,
  String id, {
  required DateTime createdAt,
  String? deviceId,
}) {
  final Directory dir = Directory(p.join(folder, id))
    ..createSync(recursive: true);
  File(p.join(dir.path, kRestorePointArchiveFileName)).writeAsStringSync('zip');
  final RestorePoint point = RestorePoint(
    id: id,
    directory: dir.path,
    kind: RestorePointKind.scheduled,
    database: RestorePointDatabase.fushi,
    createdAtMs: createdAt.millisecondsSinceEpoch,
    fromSchema: kFushiDbSchemaVersion,
    toSchema: kFushiDbSchemaVersion,
    files: const <RestorePointFile>[
      RestorePointFile(name: kRestorePointArchiveFileName, size: 3),
    ],
    fullDatabase: true,
    deviceId: deviceId,
    deviceName: deviceId == null ? null : 'Device $deviceId',
  );
  File(
    p.join(dir.path, kRestorePointMetaFileName),
  ).writeAsStringSync(jsonEncode(point.toJson()));
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

  group('写之前查空间（第五期）', () {
    int? free;
    late AutoBackupController spaced;

    setUp(() {
      free = null;
      spaced = AutoBackupController(
        host: host,
        clock: () => now,
        freeBytes: (String _) => free,
      );
    });

    tearDown(() => spaced.dispose());

    int liveDatabaseBytes() {
      int total = 0;
      for (final String name in <String>[
        'fushi.db',
        'fushi.db-wal',
        'srs4.db',
        'srs4.db-wal',
      ]) {
        final File f = File(p.join(dbDir, name));
        if (f.existsSync()) total += f.lengthSync();
      }
      return total;
    }

    test('定时：空间不够 → 失败 not_enough_space，不写、锁放开；同一原因只提示一次；腾出空间后照常', () async {
      free = 1;
      expect(await spaced.checkNow(), AutoBackupOutcome.failed);
      expect(spaced.status.value.lastError, kNotEnoughSpaceError);
      expect(host.failures, <String>[kNotEnoughSpaceError]);
      expect(host.serviceCalls, 0, reason: '没开始打包');
      expect(host.exportActive, isFalse);
      expect(spaced.scheduledPoints(), isEmpty);
      // 还到期、还不够：再失败，但不再提示。
      expect(await spaced.checkNow(), AutoBackupOutcome.failed);
      expect(host.failures, hasLength(1));
      free = 1 << 50;
      expect(await spaced.checkNow(), AutoBackupOutcome.created);
      // 成功过之后再不够：是新的一次，要再提示。
      free = 1;
      expect(await spaced.backUpNow(), AutoBackupOutcome.failed);
      expect(host.failures, hasLength(2), reason: '成功之后再不够要再提示');
    });

    test('估算按不压缩算：库（另算一份临时快照）+ 勾选的文件树；不知道可用空间照常写', () async {
      final File media = File(p.join(dbDir, 'srs_media', 'a.bin'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(Uint8List(1 << 20));
      expect(media.lengthSync(), 1 << 20);
      // 同一个卷（读数相同）：库 × 2（还原点里一份 + 临时快照一份）+ 余量，留 512 KiB 宽裕。
      free = liveDatabaseBytes() * 2 + kBackupSpaceMarginBytes + (512 << 10);
      expect(await spaced.backUpNow(), AutoBackupOutcome.created);
      host.settings = host.settings.copyWith(includeSrsMedia: true);
      expect(await spaced.backUpNow(), AutoBackupOutcome.failed);
      expect(spaced.status.value.lastError, kNotEnoughSpaceError);
      free = null;
      expect(await spaced.backUpNow(), AutoBackupOutcome.created);
    });

    test('操作前还原点：空间不够 → 抛 NotEnoughSpaceException、什么都没写；兜底入口提示原因并返回 null', () async {
      free = 1;
      await expectLater(
        spaced.createPreOperationPoint(kRestorePointReasonReplace),
        throwsA(isA<NotEnoughSpaceException>()),
      );
      expect(RestorePointStore(dbDir).list(), isEmpty);
      registerAutoBackupController(spaced);
      try {
        expect(
          await takePreOperationRestorePoint(kRestorePointReasonSyncDownload),
          isNull,
        );
      } finally {
        registerAutoBackupController(null);
      }
      expect(host.failures, <String>[kNotEnoughSpaceError]);
      expect(
        autoBackupMirrorErrorCode(
          const NotEnoughSpaceException(
            directory: 'x',
            neededBytes: 2,
            freeBytes: 1,
          ),
        ),
        kNotEnoughSpaceError,
      );
      free = 1 << 50;
      expect(
        (await spaced.createPreOperationPoint(kRestorePointReasonReplace))
            .reason,
        kRestorePointReasonReplace,
      );
    });
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

  group('用户文件夹（第三期）', () {
    late String folderDir;
    late _FakeFolderPlatform platform;
    const AutoBackupMirrorFolder folder = AutoBackupMirrorFolder(
      handle: 'tree://backups',
      label: 'Backups',
    );

    setUp(() {
      folderDir = p.join(root.path, 'user_folder');
      Directory(folderDir).createSync(recursive: true);
      platform = _FakeFolderPlatform(<String, String>{
        folder.handle: folderDir,
      });
      host.mirrorPlatform = platform;
      host.settings = host.settings.copyWith(mirrorFolder: () => folder);
    });

    test('写好的定时还原点原样复制进文件夹（带本机设备），别的设备的副本不动', () async {
      _writeFolderCopy(
        folderDir,
        '20250101-000000-000-fushi-scheduled',
        createdAt: DateTime.utc(2025),
        deviceId: 'device-2',
      );
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final RestorePoint local = controller.scheduledPoints().single;
      final MirrorFolderListing listing = await IoBackupFolderMirror(
        folderDir,
      ).list();
      final MirroredRestorePoint copy = listing.points.firstWhere(
        (MirroredRestorePoint c) => c.id == local.id,
      );
      expect(copy.point.deviceId, 'device-1');
      expect(copy.point.deviceName, 'Test phone');
      expect(copy.point.fullDatabase, isTrue);
      expect(
        File(
          p.join(folderDir, local.id, kRestorePointArchiveFileName),
        ).lengthSync(),
        File(local.archivePath!).lengthSync(),
      );
      // 本机仍是唯一的真相源：还原点先在本机存储里。
      expect(File(local.archivePath!).existsSync(), isTrue);
      expect(
        listing.points.map((MirroredRestorePoint c) => c.id),
        contains('20250101-000000-000-fushi-scheduled'),
      );
      final AutoBackupMirrorStatus mirror = controller.status.value.mirror;
      expect(mirror.holds(folder.key, local.id), isTrue);
      expect(mirror.pendingId, isNull);
      expect(platform.closes, platform.opens);
      expect(host.exportActive, isFalse);
    });

    test('文件夹不可用：本机备份照样成功，复制记失败并提示一次；没到期不重试，下个时段补上', () async {
      platform.available = false;
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      expect(controller.status.value.lastResult, AutoBackupResult.success);
      expect(
        controller.status.value.mirror.error,
        kAutoBackupErrorFolderUnavailable,
      );
      expect(host.mirrorFailures, <String>[kAutoBackupErrorFolderUnavailable]);
      expect(host.failures, isEmpty);

      platform.available = true;
      final int opens = platform.opens;
      now = now.add(const Duration(hours: 1));
      expect(await controller.checkNow(), AutoBackupOutcome.notDue);
      expect(platform.opens, opens, reason: '明确失败过：没到期不每次都重试');

      now = now.add(const Duration(days: 1));
      expect(await controller.checkNow(), AutoBackupOutcome.skippedNoChanges);
      final String id = controller.status.value.lastSuccessPointId!;
      expect(controller.status.value.mirror.holds(folder.key, id), isTrue);
      expect(Directory(p.join(folderDir, id)).existsSync(), isTrue);
      expect(host.mirrorFailures, hasLength(1));
    });

    test('复制失败（写不进去）不留完整标记，半截目录删掉，状态记错误码（不带路径原文）', () async {
      platform.failUpload = true;
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      expect(controller.status.value.mirror.error, kBackupMirrorErrorFailed);
      expect(controller.status.value.mirror.pendingId, isNull);
      expect((await IoBackupFolderMirror(folderDir).list()).points, isEmpty);
      final String id = controller.status.value.lastSuccessPointId!;
      expect(Directory(p.join(folderDir, id)).existsSync(), isFalse);
      expect(controller.status.value.mirror.leftovers, isEmpty);
    });

    test('复制到一半进程没了：下次检查按 id 精确清掉半截副本并补复制', () async {
      host.settings = host.settings.copyWith(mirrorFolder: () => null);
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final String id = controller.status.value.lastSuccessPointId!;
      // 模拟：上次复制另一个点到一半被杀（半截目录没有元数据），别的设备也有一个半截目录。
      const String half = '20261124-000000-000-fushi-scheduled';
      const String foreignHalf = '20261124-010000-000-fushi-scheduled';
      Directory(p.join(folderDir, half)).createSync();
      Directory(p.join(folderDir, foreignHalf)).createSync();
      writeAutoBackupStatus(
        dbDir,
        controller.status.value.withMirror(
          const AutoBackupMirrorStatus().started(
            folderKey: folder.key,
            id: half,
          ),
        ),
      );
      controller.reloadStatus();
      host.settings = host.settings.copyWith(mirrorFolder: () => folder);
      now = now.add(const Duration(hours: 1));
      expect(await controller.checkNow(), AutoBackupOutcome.notDue);
      expect(Directory(p.join(folderDir, half)).existsSync(), isFalse);
      expect(Directory(p.join(folderDir, foreignHalf)).existsSync(), isTrue);
      expect(controller.status.value.mirror.holds(folder.key, id), isTrue);
      expect(host.mirrorFailures, isEmpty);
    });

    test('换了文件夹：没到期也把最新那份补复制进新文件夹', () async {
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final String id = controller.status.value.lastSuccessPointId!;
      final String second = p.join(root.path, 'second_folder');
      Directory(second).createSync();
      const AutoBackupMirrorFolder other = AutoBackupMirrorFolder(
        handle: 'tree://second',
        label: 'Second',
      );
      platform.roots[other.handle] = second;
      host.settings = host.settings.copyWith(mirrorFolder: () => other);
      now = now.add(const Duration(minutes: 5));
      expect(await controller.checkNow(), AutoBackupOutcome.notDue);
      expect(Directory(p.join(second, id)).existsSync(), isTrue);
      expect(controller.status.value.mirror.holds(other.key, id), isTrue);
    });

    test('文件夹副本取回本机：进默认存储、能补回 / 替换；再取一次直接用本机那份', () async {
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final String id = controller.status.value.lastSuccessPointId!;
      // 本机那份没了（比如重装之后），文件夹里还在。
      Directory(
        p.join(dbDir, kRestorePointsDirName, id),
      ).deleteSync(recursive: true);
      final MirrorFolderListing listing = (await controller
          .listMirrorCopies())!;
      final MirroredRestorePoint copy = listing.points.single;
      final RestorePoint restored = await controller.copyMirrorCopyToDevice(
        copy,
      );
      expect(restored.id, id);
      expect(restored.kind, RestorePointKind.scheduled);
      expect(File(restored.archivePath!).existsSync(), isTrue);
      final RestorePointEntry entry = listRestorePointEntries(
        dbDirectory: dbDir,
      ).firstWhere((RestorePointEntry e) => e.id == id);
      expect(entry.canFillIn, isTrue);
      expect(entry.canReplace, isTrue);
      expect(
        Directory(p.join(dbDir, '.restore_point_download')).existsSync(),
        isFalse,
      );
      expect(
        (await controller.copyMirrorCopyToDevice(copy)).directory,
        restored.directory,
      );
      expect(host.exportActive, isFalse);

      await controller.deleteMirrorCopy(copy);
      expect((await controller.listMirrorCopies())!.points, isEmpty);
      expect(File(restored.archivePath!).existsSync(), isTrue);
    });

    test('导出锁不挡文件夹操作；同一文件夹上已有操作在跑才报 busy', () async {
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final MirroredRestorePoint copy =
          (await controller.listMirrorCopies())!.points.single;
      final Object other = host.beginBackupExport()!;
      // 别处拿着导出锁（手动导出 / 还原）：取回副本照样能做。
      final RestorePoint back = await controller.copyMirrorCopyToDevice(copy);
      expect(back.id, copy.id);
      host.endBackupExport(other);
      // 文件夹上有一个卡住的操作：第二个报 busy，什么都不动。
      final Completer<void> gate = Completer<void>();
      platform.listGate = gate.future;
      final Future<MirrorFolderListing?> stuck = controller
          .copyMirrorCopyToDevice(copy)
          .then((_) => null);
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        controller.deleteMirrorCopy(copy),
        throwsA(isA<AutoBackupBusyException>()),
      );
      gate.complete();
      await stuck;
      expect((await controller.listMirrorCopies())!.points, hasLength(1));
    });
    test('被打断的记录只清没有元数据的那份：完整副本、别的文件夹的记录都不删', () async {
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      // 上次被杀在修剪途中：pendingId 那份元数据已经写好，是完整副本。
      const String complete = '20261124-000000-000-fushi-scheduled';
      _writeFolderCopy(
        folderDir,
        complete,
        createdAt: DateTime.utc(2026, 11, 24),
        deviceId: 'device-1',
      );
      writeAutoBackupStatus(
        dbDir,
        controller.status.value.withMirror(
          controller.status.value.mirror.started(
            folderKey: folder.key,
            id: complete,
          ),
        ),
      );
      controller.reloadStatus();
      now = now.add(const Duration(days: 1));
      expect(await controller.backUpNow(), AutoBackupOutcome.created);
      expect(Directory(p.join(folderDir, complete)).existsSync(), isTrue);

      // 别的文件夹里被打断的 id：在这个文件夹里同名的半截目录也不碰（不是这里留下的）。
      const String elsewhere = '20261123-000000-000-fushi-scheduled';
      Directory(p.join(folderDir, elsewhere)).createSync();
      writeAutoBackupStatus(
        dbDir,
        controller.status.value.withMirror(
          const AutoBackupMirrorStatus(
            target: 'another-folder',
          ).started(folderKey: 'another-folder', id: elsewhere),
        ),
      );
      controller.reloadStatus();
      now = now.add(const Duration(days: 1));
      expect(await controller.backUpNow(), AutoBackupOutcome.created);
      expect(Directory(p.join(folderDir, elsewhere)).existsSync(), isTrue);
    });

    test('被打断的那份这次读不出元数据（iCloud 占位 / 元数据坏了）：不删，留着下次再判', () async {
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      const String placeholder = '20261124-000000-000-fushi-scheduled';
      const String broken = '20261124-010000-000-fushi-scheduled';
      final Directory a = Directory(p.join(folderDir, placeholder))
        ..createSync();
      File(p.join(a.path, kRestorePointArchiveFileName)).writeAsStringSync('z');
      File(
        p.join(a.path, '.$kRestorePointMetaFileName.icloud'),
      ).writeAsStringSync('');
      final Directory b = Directory(p.join(folderDir, broken))..createSync();
      File(p.join(b.path, kRestorePointArchiveFileName)).writeAsStringSync('z');
      File(p.join(b.path, kRestorePointMetaFileName)).writeAsStringSync('{');
      final AutoBackupMirrorStatus before = controller.status.value.mirror;
      writeAutoBackupStatus(
        dbDir,
        controller.status.value.withMirror(
          AutoBackupMirrorStatus(
            target: folder.key,
            pointId: before.pointId,
            atMs: before.atMs,
            leftovers: const <String>[broken],
          ).started(folderKey: folder.key, id: placeholder),
        ),
      );
      controller.reloadStatus();
      now = now.add(const Duration(days: 1));
      expect(await controller.backUpNow(), AutoBackupOutcome.created);
      expect(a.existsSync(), isTrue);
      expect(b.existsSync(), isTrue);
      final AutoBackupMirrorStatus after = controller.status.value.mirror;
      expect(after.error, isNull);
      expect(after.leftovers, <String>[placeholder, broken]);
      expect(
        after.holds(folder.key, controller.status.value.lastSuccessPointId),
        isTrue,
      );
    });

    test('关目标失败（iOS 停止访问书签）不盖掉操作的结果 / 错误，目标也不会一直「正在用」', () async {
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      platform.failClose = true;
      final MirroredRestorePoint copy =
          (await controller.listMirrorCopies())!.points.single;
      platform.undeletable.add(copy.id);
      await expectLater(
        controller.deleteMirrorCopy(copy),
        throwsA(isA<FileSystemException>()),
      );
      expect(controller.mirroring, isFalse);
      platform.undeletable.clear();
      await controller.deleteMirrorCopy(copy);
      expect(controller.mirroring, isFalse);
      expect((await controller.listMirrorCopies())!.points, isEmpty);
    });

    test('失败后删不掉的半截副本记进 leftovers，下一次复制时清掉', () async {
      platform.failUpload = true;
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final String id = controller.status.value.lastSuccessPointId!;
      // 让删除也失败：残留记下来。
      expect(Directory(p.join(folderDir, id)).existsSync(), isFalse);
      platform.failAllDeletes = true;
      now = now.add(const Duration(days: 1));
      expect(await controller.backUpNow(), AutoBackupOutcome.created);
      final String second = controller.status.value.lastSuccessPointId!;
      expect(controller.status.value.mirror.leftovers, contains(second));
      expect(controller.status.value.mirror.error, kBackupMirrorErrorFailed);
      // 恢复正常：下一次复制先清掉残留（没有元数据），再复制。
      platform
        ..failUpload = false
        ..failAllDeletes = false;
      now = now.add(const Duration(days: 1));
      expect(await controller.backUpNow(), AutoBackupOutcome.created);
      expect(Directory(p.join(folderDir, second)).existsSync(), isFalse);
      expect(controller.status.value.mirror.leftovers, isEmpty);
      expect(controller.status.value.mirror.error, isNull);
    });

    test('修剪时一份删不掉：这份复制照样成功、不提示，删不掉的记进 pruneError', () async {
      const String old = '20250101-000000-000-fushi-scheduled';
      _writeFolderCopy(
        folderDir,
        old,
        createdAt: DateTime.utc(2025),
        deviceId: 'device-1',
      );
      platform.undeletable.add(old);
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final AutoBackupMirrorStatus mirror = controller.status.value.mirror;
      expect(
        mirror.holds(folder.key, controller.status.value.lastSuccessPointId),
        isTrue,
      );
      expect(mirror.error, isNull);
      expect(mirror.pruneError, old);
      expect(host.mirrorFailures, isEmpty);
      platform.undeletable.clear();
      now = now.add(const Duration(days: 1));
      expect(await controller.backUpNow(), AutoBackupOutcome.created);
      expect(controller.status.value.mirror.pruneError, isNull);
      expect(Directory(p.join(folderDir, old)).existsSync(), isFalse);
    });

    test('复制不拿导出锁：上传卡住时还原 / 导出照样拿得到锁，本机点被钉住', () async {
      final Completer<void> gate = Completer<void>();
      platform
        ..uploadGate = gate.future
        ..uploadStarted = Completer<void>();
      final Future<AutoBackupOutcome> run = controller.checkNow();
      await platform.uploadStarted!.future;
      expect(host.exportActive, isFalse);
      final Object? token = host.beginBackupExport();
      expect(token, isNotNull, reason: '卡住的复制不能挡住手动导出 / 还原');
      host.endBackupExport(token!);
      final RestorePoint local = controller.scheduledPoints().single;
      expect(RestorePointStore.isHeld(local.directory), isTrue);
      expect(controller.mirroring, isTrue);
      gate.complete();
      expect(await run, AutoBackupOutcome.created);
      expect(RestorePointStore.isHeld(local.directory), isFalse);
      expect(controller.mirroring, isFalse);
    });

    test('定时还原点带写入设备；取回本机的点之后不会被修剪', () async {
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final RestorePoint first = controller.scheduledPoints().single;
      expect(first.deviceId, 'device-1');
      // 本机那份没了、从文件夹取回：记 copiedBackAtMs。
      Directory(first.directory).deleteSync(recursive: true);
      final MirroredRestorePoint copy =
          (await controller.listMirrorCopies())!.points.single;
      final RestorePoint back = await controller.copyMirrorCopyToDevice(copy);
      expect(back.copiedBackAtMs, isNotNull);
      // 很久之后的新备份：按保留规则取回的旧点早该被删，但取回的从不自动删。
      now = now.add(const Duration(days: 400));
      await addStat('changed');
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      expect(Directory(back.directory).existsSync(), isTrue);
    });
  });

  group('云端副本（D8–D11）', () {
    late FakeAssetStore store;
    late int cloudOpens;

    setUp(() {
      store = FakeAssetStore(reportNullSizes: true);
      cloudOpens = 0;
      host.cloud = AutoBackupMirrorTarget(
        kind: AutoBackupMirrorKind.cloud,
        key: 'cloud-test',
        label: 'Test cloud',
        policy: kCloudBackupRetention,
        open: () async {
          cloudOpens++;
          return BackupFolderSession(
            mirror: SyncAssetStoreBackupMirror(
              store: store,
              namespace: () => store.ensureNamespace(kCloudBackupNamespace),
              deviceFolder: 'device-1',
            ),
          );
        },
      );
      host.settings = host.settings.copyWith(cloudCopies: true);
    });

    Future<List<MirroredRestorePoint>> cloudCopies() async =>
        (await controller.listCloudCopies())!.points;

    test('云端配置了却登录不上：记 cloud_auth、定时那次提示一次，补复制不再提示；登录好了照常补传', () async {
      host.cloudError = const BackupMirrorException(
        kBackupMirrorErrorCloudAuth,
      );
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      expect(controller.status.value.cloud.error, kBackupMirrorErrorCloudAuth);
      expect(host.mirrorFailures, <String>[
        'cloud:$kBackupMirrorErrorCloudAuth',
      ]);
      await expectLater(
        controller.listCloudCopies(),
        throwsA(
          isA<BackupMirrorException>().having(
            (BackupMirrorException e) => e.code,
            'code',
            kBackupMirrorErrorCloudAuth,
          ),
        ),
      );
      // 没到期的补复制：同一个错误，不再提示。
      now = now.add(const Duration(hours: 1));
      expect(await controller.checkNow(), AutoBackupOutcome.notDue);
      expect(host.mirrorFailures, hasLength(1));
      // 重新登录好了：没到期也补传，错误清掉，不提示。
      host.cloudError = null;
      now = now.add(const Duration(hours: 1));
      expect(await controller.checkNow(), AutoBackupOutcome.notDue);
      final String id = controller.status.value.lastSuccessPointId!;
      expect(controller.status.value.cloud.holds('cloud-test', id), isTrue);
      expect(controller.status.value.cloud.error, isNull);
      expect(host.mirrorFailures, hasLength(1));
    });

    test('宿主漏掉没归类的错误：归成 cloud_failed，原文（可能带服务器地址）不外传', () async {
      host.cloudError = StateError('https://user:secret@dav.example/');
      await expectLater(
        controller.listCloudCopies(),
        throwsA(
          isA<BackupMirrorException>()
              .having(
                (BackupMirrorException e) => e.code,
                'code',
                kBackupMirrorErrorCloudFailed,
              )
              .having(
                (BackupMirrorException e) => '$e',
                'text',
                isNot(contains('secret')),
              ),
        ),
      );
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      expect(
        controller.status.value.cloud.error,
        kBackupMirrorErrorCloudFailed,
      );
    });

    test('两次补复制同时跑：同一个目标只复制一次（查网络之前就占住）', () async {
      host.unmetered = false;
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      expect(cloudOpens, 0);
      host.unmetered = true;
      final Completer<void> gate = Completer<void>();
      host.unmeteredGate = gate.future;
      now = now.add(const Duration(hours: 1));
      final Future<AutoBackupOutcome> first = controller.checkNow();
      final Future<AutoBackupOutcome> second = controller.checkNow();
      await pumpEventQueue();
      gate.complete();
      expect(await first, AutoBackupOutcome.notDue);
      expect(await second, AutoBackupOutcome.notDue);
      expect(cloudOpens, 1);
      expect(controller.mirroring, isFalse);
      expect(await cloudCopies(), hasLength(1));
    });

    test('写好的定时还原点传到云端（设备子目录），状态单独记', () async {
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final String id = controller.status.value.lastSuccessPointId!;
      final List<MirroredRestorePoint> copies = await cloudCopies();
      expect(copies.single.id, id);
      expect(copies.single.point.deviceId, 'device-1');
      expect(controller.status.value.cloud.holds('cloud-test', id), isTrue);
      expect(controller.status.value.mirror.target, isNull);
    });

    test('只在不计流量的网络上传（缺省）；允许移动数据就照传；没到期时补上', () async {
      host.unmetered = false;
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      expect(await cloudCopies(), isEmpty);
      expect(
        controller.status.value.cloud.error,
        isNull,
        reason: '等 Wi-Fi 不算失败',
      );
      // 回到 Wi-Fi：没到期的检查补传。
      host.unmetered = true;
      now = now.add(const Duration(hours: 1));
      expect(await controller.checkNow(), AutoBackupOutcome.notDue);
      expect(await cloudCopies(), hasLength(1));
      // 允许移动数据：计流量也传。
      host
        ..unmetered = false
        ..settings = host.settings.copyWith(cloudAllowMetered: true);
      now = now.add(const Duration(days: 1));
      expect(await controller.backUpNow(), AutoBackupOutcome.created);
      expect(await cloudCopies(), hasLength(2));
    });

    test('云端保留更少（7 天 + 4 周），只动本机写的副本', () async {
      // 预先放一份别的设备的很旧的副本和一份本机的很旧的副本。
      Future<void> seed(String device, String id, DateTime at) async {
        final String ns = await store.ensureNamespace(kCloudBackupNamespace);
        final String dev = await store.ensureFolder(ns, device);
        final String dir = await store.ensureFolder(dev, id);
        final File zip = File(p.join(root.path, 'seed.zip'))
          ..writeAsStringSync('zip');
        await store.putAsset(dir, kRestorePointArchiveFileName, zip);
        final RestorePoint point = RestorePoint(
          id: id,
          directory: dir,
          kind: RestorePointKind.scheduled,
          database: RestorePointDatabase.fushi,
          createdAtMs: at.millisecondsSinceEpoch,
          fromSchema: kFushiDbSchemaVersion,
          toSchema: kFushiDbSchemaVersion,
          files: const <RestorePointFile>[
            RestorePointFile(name: kRestorePointArchiveFileName, size: 3),
          ],
          deviceId: device,
        );
        await store.putBytesAsset(
          dir,
          kRestorePointMetaFileName,
          Uint8List.fromList(utf8.encode(jsonEncode(point.toJson()))),
        );
      }

      // 40 天前：本机的超出 7 天 + 4 周（28 天）该删；别人的不动。
      final DateTime old = now.toUtc().subtract(const Duration(days: 40));
      await seed('device-1', '20261016-000000-000-fushi-scheduled', old);
      await seed('device-2', '20261016-000000-001-fushi-scheduled', old);
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final Set<String> ids = <String>{
        for (final MirroredRestorePoint c in await cloudCopies()) c.id,
      };
      expect(ids, isNot(contains('20261016-000000-000-fushi-scheduled')));
      expect(ids, contains('20261016-000000-001-fushi-scheduled'));
      expect(ids, contains(controller.status.value.lastSuccessPointId));
    });

    test('云端副本取回本机、删除；没有可用后端时报 cloud_no_service', () async {
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final String id = controller.status.value.lastSuccessPointId!;
      Directory(
        p.join(dbDir, kRestorePointsDirName, id),
      ).deleteSync(recursive: true);
      final MirroredRestorePoint copy = (await cloudCopies()).single;
      final RestorePoint back = await controller.copyMirrorCopyToDevice(
        copy,
        kind: AutoBackupMirrorKind.cloud,
      );
      expect(File(back.archivePath!).existsSync(), isTrue);
      expect(back.copiedBackAtMs, isNotNull);
      await controller.deleteMirrorCopy(copy, kind: AutoBackupMirrorKind.cloud);
      expect(await cloudCopies(), isEmpty);

      host.cloud = null;
      await expectLater(
        controller.deleteMirrorCopy(copy, kind: AutoBackupMirrorKind.cloud),
        throwsA(
          isA<BackupMirrorException>().having(
            (BackupMirrorException e) => e.code,
            'code',
            kBackupMirrorErrorCloudNoService,
          ),
        ),
      );
    });

    test('上传失败：半截副本删掉，记错误码并提示一次（云端文案）', () async {
      store.failPutAsset = true;
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      expect(
        controller.status.value.cloud.error,
        kBackupMirrorErrorCloudFailed,
      );
      expect(host.mirrorFailures, <String>[
        'cloud:$kBackupMirrorErrorCloudFailed',
      ]);
      final String ns = await store.ensureNamespace(kCloudBackupNamespace);
      final String dev = await store.ensureFolder(ns, 'device-1');
      expect(await store.listChildren(dev), isEmpty);
    });
  });

  group('服务器副本（第四期 D12–D13）', () {
    late FakeAssetStore serverStore;
    late FakeAssetStore cloudStore;

    AutoBackupMirrorTarget targetOn(
      FakeAssetStore store,
      AutoBackupMirrorKind kind,
      String key,
      BackupRetentionPolicy policy,
    ) => AutoBackupMirrorTarget(
      kind: kind,
      key: key,
      label: kind == AutoBackupMirrorKind.server ? 'Desk PC' : 'Test cloud',
      policy: policy,
      open: () async => BackupFolderSession(
        mirror: SyncAssetStoreBackupMirror(
          store: store,
          namespace: () => store.ensureNamespace(kCloudBackupNamespace),
          deviceFolder: 'device-1',
        ),
      ),
    );

    setUp(() {
      serverStore = FakeAssetStore(reportNullSizes: true);
      cloudStore = FakeAssetStore(reportNullSizes: true);
      host.server = targetOn(
        serverStore,
        AutoBackupMirrorKind.server,
        serverBackupTargetKey('host-id'),
        kServerBackupRetention,
      );
      host.settings = host.settings.copyWith(serverCopies: true);
    });

    Future<List<MirroredRestorePoint>> serverCopies() async =>
        (await controller.listServerCopies())!.points;

    Future<void> seed(String device, String id, DateTime at) async {
      final String ns = await serverStore.ensureNamespace(
        kCloudBackupNamespace,
      );
      final String dev = await serverStore.ensureFolder(ns, device);
      final String dir = await serverStore.ensureFolder(dev, id);
      final File zip = File(p.join(root.path, 'seed.zip'))
        ..writeAsStringSync('zip');
      await serverStore.putAsset(dir, kRestorePointArchiveFileName, zip);
      final RestorePoint point = RestorePoint(
        id: id,
        directory: dir,
        kind: RestorePointKind.scheduled,
        database: RestorePointDatabase.fushi,
        createdAtMs: at.millisecondsSinceEpoch,
        fromSchema: kFushiDbSchemaVersion,
        toSchema: kFushiDbSchemaVersion,
        files: const <RestorePointFile>[
          RestorePointFile(name: kRestorePointArchiveFileName, size: 3),
        ],
        deviceId: device,
      );
      await serverStore.putBytesAsset(
        dir,
        kRestorePointMetaFileName,
        Uint8List.fromList(utf8.encode(jsonEncode(point.toJson()))),
      );
    }

    test('服务器键带主机身份的哈希，原文不进键；保留规则就是本机那套', () {
      final String key = serverBackupTargetKey('host-id');
      expect(key, startsWith('server-'));
      expect(key, hasLength('server-'.length + 12));
      expect(key, isNot(contains('host-id')));
      expect(serverBackupTargetKey('other-host'), isNot(key));
      expect(serverBackupTargetKey(null), 'server');
      expect(kServerBackupRetention, same(kRestorePointScheduledRetention));
    });

    test('与云端互不相干：两个都开就各传一份，状态各记各的', () async {
      host
        ..cloud = targetOn(
          cloudStore,
          AutoBackupMirrorKind.cloud,
          'cloud-test',
          kCloudBackupRetention,
        )
        ..settings = host.settings.copyWith(cloudCopies: true);
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final String id = controller.status.value.lastSuccessPointId!;
      expect((await serverCopies()).single.id, id);
      expect((await controller.listCloudCopies())!.points.single.id, id);
      final AutoBackupStatus status = controller.status.value;
      expect(status.server.holds(serverBackupTargetKey('host-id'), id), isTrue);
      expect(status.cloud.holds('cloud-test', id), isTrue);
      // 状态文件往返：服务器那份单独记在 `server` 下。
      final AutoBackupStatus reread = readAutoBackupStatus(dbDir);
      expect(reread.server.pointId, id);
      expect(reread.cloud.pointId, id);
    });

    test('服务器关着：不传，列表返回 null', () async {
      host.settings = host.settings.copyWith(serverCopies: false);
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      expect(await controller.listServerCopies(), isNull);
      expect(controller.status.value.server.target, isNull);
    });

    test('保留按本机规则（D13）：本机 60 天前那份在月度桶里留着，200 天前的删；别的设备的不动', () async {
      final DateTime utc = now.toUtc();
      await seed(
        'device-1',
        '20260926-000000-000-fushi-scheduled',
        utc.subtract(const Duration(days: 60)),
      );
      await seed(
        'device-1',
        '20260509-000000-000-fushi-scheduled',
        utc.subtract(const Duration(days: 200)),
      );
      await seed(
        'device-2',
        '20260509-000000-001-fushi-scheduled',
        utc.subtract(const Duration(days: 200)),
      );
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final Set<String> ids = <String>{
        for (final MirroredRestorePoint c in await serverCopies()) c.id,
      };
      expect(ids, contains('20260926-000000-000-fushi-scheduled'));
      expect(ids, isNot(contains('20260509-000000-000-fushi-scheduled')));
      expect(ids, contains('20260509-000000-001-fushi-scheduled'));
      expect(ids, contains(controller.status.value.lastSuccessPointId));
    });

    test('连不上服务器：记进服务器状态、定时那次提示一次（服务器文案），云端不受影响；连上后补传', () async {
      host.serverError = const BackupMirrorException(
        kBackupMirrorErrorCloudUnreachable,
      );
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      expect(
        controller.status.value.server.error,
        kBackupMirrorErrorCloudUnreachable,
      );
      expect(controller.status.value.cloud.error, isNull);
      expect(host.mirrorFailures, <String>[
        'server:$kBackupMirrorErrorCloudUnreachable',
      ]);
      // 补复制不再提示。
      now = now.add(const Duration(hours: 1));
      expect(await controller.checkNow(), AutoBackupOutcome.notDue);
      expect(host.mirrorFailures, hasLength(1));
      // 连上了：下个时段补传，错误清掉。
      host.serverError = null;
      now = now.add(const Duration(days: 1));
      expect(await controller.backUpNow(), AutoBackupOutcome.created);
      expect(controller.status.value.server.error, isNull);
      // 失败那一期的点不补传（等下个时段 / 立即备份），新点照传。
      expect(
        (await serverCopies()).single.id,
        controller.status.value.lastSuccessPointId,
      );
    });

    test('宿主漏掉没归类的错误：归成 cloud_failed，原文不外传', () async {
      host.serverError = StateError('https://192.0.2.5:8443/?token=secret');
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      expect(
        controller.status.value.server.error,
        kBackupMirrorErrorCloudFailed,
      );
      expect(
        jsonEncode(controller.status.value.toJson()),
        isNot(contains('secret')),
      );
    });

    test('计流量的网络上与云端同一个设置：缺省等 Wi-Fi，允许移动数据就照传', () async {
      host.unmetered = false;
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      expect(await serverCopies(), isEmpty);
      expect(controller.status.value.server.error, isNull);
      host.settings = host.settings.copyWith(cloudAllowMetered: true);
      now = now.add(const Duration(hours: 1));
      expect(await controller.checkNow(), AutoBackupOutcome.notDue);
      expect(await serverCopies(), hasLength(1));
    });

    test('服务器副本取回本机、删除；没有互联服务器时报 server_no_server', () async {
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final String id = controller.status.value.lastSuccessPointId!;
      Directory(
        p.join(dbDir, kRestorePointsDirName, id),
      ).deleteSync(recursive: true);
      final MirroredRestorePoint copy = (await serverCopies()).single;
      final RestorePoint back = await controller.copyMirrorCopyToDevice(
        copy,
        kind: AutoBackupMirrorKind.server,
      );
      expect(back.copiedBackAtMs, isNotNull);
      await controller.deleteMirrorCopy(
        copy,
        kind: AutoBackupMirrorKind.server,
      );
      expect(await serverCopies(), isEmpty);
      host.server = null;
      await expectLater(
        controller.deleteMirrorCopy(copy, kind: AutoBackupMirrorKind.server),
        throwsA(
          isA<BackupMirrorException>().having(
            (BackupMirrorException e) => e.code,
            'code',
            kBackupMirrorErrorServerNoServer,
          ),
        ),
      );
    });

    test('开着却没有服务（云端只剩互联 / 没设互联服务器）：记进那个目标的状态、只提示一次，开关不替用户关', () async {
      host
        ..server = null
        ..settings = host.settings.copyWith(cloudCopies: true);
      expect(host.cloud, isNull);
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      AutoBackupStatus status = controller.status.value;
      expect(status.cloud.error, kBackupMirrorErrorCloudNoService);
      expect(status.server.error, kBackupMirrorErrorServerNoServer);
      expect(host.mirrorFailures, <String>[
        'cloud:$kBackupMirrorErrorCloudNoService',
        'server:$kBackupMirrorErrorServerNoServer',
      ]);
      expect(
        autoBackupErrorText(status.cloud.error),
        t.auto_backup_cloud_no_service,
      );
      expect(
        autoBackupErrorText(status.server.error),
        t.auto_backup_server_no_server,
      );
      // 下一个时段、立即备份：原因没变，不再提示。
      now = now.add(const Duration(days: 1));
      await addStat('no-service-1');
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      expect(await controller.backUpNow(), isNot(AutoBackupOutcome.failed));
      expect(host.mirrorFailures, hasLength(2));
      expect(host.settings.cloudCopies, isTrue);
      expect(host.settings.serverCopies, isTrue);
      // 设好了服务器：补传，原因清掉。
      host.server = targetOn(
        serverStore,
        AutoBackupMirrorKind.server,
        serverBackupTargetKey('host-id'),
        kServerBackupRetention,
      );
      now = now.add(const Duration(days: 1));
      await addStat('no-service-2');
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      status = controller.status.value;
      expect(status.server.error, isNull);
      expect(status.cloud.error, kBackupMirrorErrorCloudNoService);
      expect((await serverCopies()).single.id, status.lastSuccessPointId);
    });

    test('别的设备碰巧有同 id 的副本：本机照传进自己的目录，自动删除只动本机目录', () async {
      host.settings = host.settings.copyWith(serverCopies: false);
      expect(await controller.checkNow(), AutoBackupOutcome.created);
      final String id = controller.status.value.lastSuccessPointId!;
      // 另一台设备同一毫秒写出了同一个 id（完整的副本）。
      await seed('device-2', id, now.toUtc());
      host.settings = host.settings.copyWith(serverCopies: true);
      now = now.add(const Duration(hours: 1));
      expect(await controller.checkNow(), AutoBackupOutcome.notDue);
      List<MirroredRestorePoint> copies = await serverCopies();
      expect(
        copies
            .map((MirroredRestorePoint c) => '${c.point.deviceId}/${c.id}')
            .toSet(),
        <String>{'device-1/$id', 'device-2/$id'},
        reason: '对方那份不算「本机已经传过」',
      );
      expect(
        copies
            .where((MirroredRestorePoint c) => c.inOwnSlot)
            .single
            .point
            .deviceId,
        'device-1',
      );

      // 自动路径的删除（按 id）只在本机目录里找：删两次，对方那份都还在。
      final AutoBackupMirrorTarget target = host.server!;
      final BackupFolderSession session = await target.open();
      await session.mirror.delete(id);
      await session.mirror.delete(id);
      copies = await serverCopies();
      expect(copies.single.point.deviceId, 'device-2');
      expect(copies.single.inOwnSlot, isFalse);

      // 还原点页删对方那份：按列出来的那一份删。
      await controller.deleteMirrorCopy(
        copies.single,
        kind: AutoBackupMirrorKind.server,
      );
      expect(await serverCopies(), isEmpty);
    });
  });
}
