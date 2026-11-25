import 'dart:convert';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';

/// 更新前还原点（设计 docs/specs/2026-11-25-auto-backup-restore-points.md 第一层）：
/// 迁移前快照、不该建的场景、失败不挡开库、保留策略、离线回滚与崩溃补完、合并导入不建点。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_restore_points_');
  });

  tearDown(() {
    debugRestorePointSnapshotFailureForTesting = null;
    debugRestorePointRollbackStepForTesting = null;
    RestorePointStore.appVersion = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String dbPath() => p.join(tmp.path, fushiDatabaseFileName);

  /// 建一个当前 schema 的真库，带一行标记数据，再把 user_version 改成 [version]。
  Future<void> seedDatabase({
    required int version,
    String marker = 'old',
  }) async {
    final FushiDatabase db = FushiDatabase(tmp.path);
    await db.customSelect('SELECT 1').get();
    await db.close();
    final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath());
    raw.execute('CREATE TABLE IF NOT EXISTS rp_marker (v TEXT NOT NULL)');
    raw.execute('DELETE FROM rp_marker');
    raw.execute('INSERT INTO rp_marker (v) VALUES (?)', <Object?>[marker]);
    raw.execute('PRAGMA user_version = $version');
    raw.close();
  }

  String markerIn(String path) {
    final sqlite3.Database raw = sqlite3.sqlite3.open(
      path,
      mode: sqlite3.OpenMode.readOnly,
    );
    try {
      return raw.select('SELECT v FROM rp_marker').first.columnAt(0) as String;
    } finally {
      raw.close();
    }
  }

  Future<void> openAndQuery() async {
    final FushiDatabase db = FushiDatabase(tmp.path);
    try {
      await db.customSelect('SELECT 1').get();
    } finally {
      await db.close();
    }
  }

  RestorePointStore store() => RestorePointStore(tmp.path);

  group('迁移前快照', () {
    test('从 v(N-1) 升级：建点，快照停在旧 schema、带着旧数据，活库升到 N', () async {
      await seedDatabase(version: kFushiDbSchemaVersion - 1);
      RestorePointStore.appVersion = '9.9.9';
      await openAndQuery();

      final List<RestorePoint> points = store().list();
      expect(points, hasLength(1));
      final RestorePoint point = points.single;
      expect(point.kind, RestorePointKind.preUpdate);
      expect(point.database, RestorePointDatabase.fushi);
      expect(point.fromSchema, kFushiDbSchemaVersion - 1);
      expect(point.toSchema, kFushiDbSchemaVersion);
      expect(point.appVersion, '9.9.9');
      expect(point.id, endsWith('-fushi-pre_update'));
      expect(point.files.single.name, fushiDatabaseFileName);
      expect(point.files.single.size, File(point.snapshotPath).lengthSync());

      expect(
        readSqliteUserVersionSync(point.snapshotPath),
        kFushiDbSchemaVersion - 1,
      );
      expect(markerIn(point.snapshotPath), 'old');
      expect(readSqliteUserVersionSync(dbPath()), kFushiDbSchemaVersion);

      final RestorePointSnapshotStatus status = store().readLastStatus(
        RestorePointDatabase.fushi,
      )!;
      expect(status.ok, isTrue);
      expect(status.pointId, point.id);
      expect(status.needsNotice, isFalse);

      // 元数据的线上格式与 Rust 写的同一份（键名逐个钉住）。
      final Map<String, Object?> meta =
          jsonDecode(
                File(
                  p.join(point.directory, kRestorePointMetaFileName),
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(meta.keys, <String>{
        'format',
        'kind',
        'database',
        'createdAtMs',
        'fromSchema',
        'toSchema',
        'appVersion',
        'files',
      });
    });

    test('全新库、同版本、降级都不建点', () async {
      // 全新库：文件还不存在。
      await openAndQuery();
      expect(store().list(), isEmpty);
      // 同版本：再开一次。
      await openAndQuery();
      expect(store().list(), isEmpty);
      // 降级：库比本版本新，开库被拒，什么都不建。
      final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath());
      raw.execute('PRAGMA user_version = ${kFushiDbSchemaVersion + 1}');
      raw.close();
      await expectLater(
        openAndQuery(),
        throwsA(isA<FushiDatabaseDowngradeException>()),
      );
      expect(store().list(), isEmpty);
      expect(Directory(store().root).existsSync(), isFalse);
    });

    test('快照失败：删掉半截目录、记失败状态，迁移照常', () async {
      await seedDatabase(version: kFushiDbSchemaVersion - 1);
      debugRestorePointSnapshotFailureForTesting = () => true;
      await openAndQuery();

      expect(readSqliteUserVersionSync(dbPath()), kFushiDbSchemaVersion);
      expect(store().list(), isEmpty);
      final List<FileSystemEntity> leftovers = Directory(
        store().root,
      ).listSync().whereType<Directory>().toList();
      expect(leftovers, isEmpty);
      final RestorePointSnapshotStatus status = store().readLastStatus(
        RestorePointDatabase.fushi,
      )!;
      expect(status.ok, isFalse);
      expect(status.error, contains('simulated'));
      expect(status.needsNotice, isTrue);
      expect(store().unacknowledgedFailures(), hasLength(1));

      store().acknowledgeLastStatus(RestorePointDatabase.fushi);
      expect(store().unacknowledgedFailures(), isEmpty);
    });

    test('还原点目录建不出来（被同名文件占住）：不抛，库照常升级', () async {
      await seedDatabase(version: kFushiDbSchemaVersion - 1);
      File(p.join(tmp.path, kRestorePointsDirName)).writeAsStringSync('x');
      await openAndQuery();
      expect(readSqliteUserVersionSync(dbPath()), kFushiDbSchemaVersion);
      expect(
        FileSystemEntity.typeSync(p.join(tmp.path, kRestorePointsDirName)),
        FileSystemEntityType.file,
      );
    });

    test('合并导入走的 atFile 开库不建点', () async {
      await seedDatabase(version: kFushiDbSchemaVersion - 1);
      final Directory extracted = Directory(p.join(tmp.path, 'extracted'))
        ..createSync();
      final String copy = p.join(extracted.path, 'backup.db');
      File(dbPath()).copySync(copy);
      final FushiDatabase db = FushiDatabase.atFile(copy);
      await db.customSelect('SELECT 1').get();
      await db.close();
      expect(readSqliteUserVersionSync(copy), kFushiDbSchemaVersion);
      expect(
        Directory(p.join(extracted.path, kRestorePointsDirName)).existsSync(),
        isFalse,
      );
      expect(Directory(store().root).existsSync(), isFalse);
    });
  });

  group('保留策略', () {
    test('每库只留最新 3 个更新前还原点；别的库、不认识的目录不碰，本库残留清掉', () async {
      await seedDatabase(version: kFushiDbSchemaVersion - 1);
      final Directory root = Directory(store().root)..createSync();
      final Directory srs = Directory(
        p.join(root.path, '20200101-000000-000-srs-pre_update'),
      )..createSync();
      File(p.join(srs.path, kRestorePointMetaFileName)).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'format': 1,
          'kind': 'pre_update',
          'database': 'srs',
          'createdAtMs': 1,
          'fromSchema': 40026,
          'toSchema': 40027,
          'appVersion': null,
          'files': <Object?>[],
        }),
      );
      final Directory unknown = Directory(p.join(root.path, 'user-notes'))
        ..createSync();
      final Directory partial = Directory(
        p.join(root.path, '20200101-000000-000-fushi-pre_update'),
      )..createSync();

      final List<String> created = <String>[];
      for (int i = 0; i < 5; i++) {
        final RestorePoint? point = await store().createPreUpdatePoint(
          dbFilePath: dbPath(),
          database: RestorePointDatabase.fushi,
          fromSchema: kFushiDbSchemaVersion - 1,
          toSchema: kFushiDbSchemaVersion,
        );
        created.add(point!.id);
      }
      final List<RestorePoint> kept = store().list(
        database: RestorePointDatabase.fushi,
      );
      expect(kept.map((RestorePoint e) => e.id), created.reversed.take(3));
      expect(srs.existsSync(), isTrue);
      expect(unknown.existsSync(), isTrue);
      expect(partial.existsSync(), isFalse);
    });

    test('id 时间戳是 UTC、定宽、按字典序即按时间', () {
      expect(restorePointTimestamp(0), '19700101-000000-000');
      expect(
        restorePointTimestamp(
          DateTime.utc(2026, 11, 25, 14, 25, 30, 123).millisecondsSinceEpoch,
        ),
        '20261125-142530-123',
      );
    });
  });

  group('回滚', () {
    /// 造一个「旧版本快照」还原点 + 一份「新版本」活库（带 -wal）。
    Future<RestorePoint> seedRollbackScene() async {
      await seedDatabase(version: kFushiDbSchemaVersion - 1, marker: 'old');
      final RestorePoint point = (await store().createPreUpdatePoint(
        dbFilePath: dbPath(),
        database: RestorePointDatabase.fushi,
        fromSchema: kFushiDbSchemaVersion - 1,
        toSchema: kFushiDbSchemaVersion,
      ))!;
      final sqlite3.Database raw = sqlite3.sqlite3.open(dbPath());
      raw.execute('PRAGMA journal_mode=WAL');
      raw.execute('PRAGMA wal_autocheckpoint=0');
      raw.execute("UPDATE rp_marker SET v = 'new'");
      raw.execute('PRAGMA user_version = ${kFushiDbSchemaVersion + 1}');
      // 关连接会检查点并删掉 -wal；放一个残留 -wal，验证回滚把侧车一起挪走。
      raw.close();
      File('${dbPath()}-wal').writeAsStringSync('stale-wal');
      return point;
    }

    test('换回快照；当前库连同侧车进回滚前还原点；之后能正常开库', () async {
      final RestorePoint target = await seedRollbackScene();
      expect(
        store().compatibleMainDatabasePoints().map((RestorePoint e) => e.id),
        <String>[target.id],
      );

      final List<RestorePoint> backups = await store().rollback(
        <RestorePointRollbackPlan>[RestorePointRollbackPlan(target: target)],
      );

      expect(markerIn(dbPath()), 'old');
      expect(File('${dbPath()}-wal').existsSync(), isFalse);
      expect(backups, hasLength(1));
      final RestorePoint backup = backups.single;
      expect(backup.kind, RestorePointKind.preRollback);
      expect(backup.fromSchema, kFushiDbSchemaVersion + 1);
      expect(
        backup.files.map((RestorePointFile f) => f.name),
        containsAll(<String>[
          fushiDatabaseFileName,
          '$fushiDatabaseFileName-wal',
        ]),
      );
      expect(store().hasPendingRollback, isFalse);
      // 目标还原点还在（复制，不是挪走），可以再回滚一次。
      expect(File(target.snapshotPath).existsSync(), isTrue);

      // 换回来的库按普通升级路径打开（会再建一个更新前还原点）。
      await openAndQuery();
      expect(readSqliteUserVersionSync(dbPath()), kFushiDbSchemaVersion);
      expect(markerIn(dbPath()), 'old');
    });

    for (final String crashAfter in <String>['moved', 'copied']) {
      test('崩在「$crashAfter」之后：下次开库前补完', () async {
        final RestorePoint target = await seedRollbackScene();
        debugRestorePointRollbackStepForTesting = (String step) {
          if (step == crashAfter) throw StateError('crash after $step');
        };
        await expectLater(
          store().rollback(<RestorePointRollbackPlan>[
            RestorePointRollbackPlan(target: target),
          ]),
          throwsStateError,
        );
        debugRestorePointRollbackStepForTesting = null;
        expect(store().hasPendingRollback, isTrue);

        // 下次启动：_openDb 先补完回滚，再按普通升级路径开库。
        await openAndQuery();

        expect(store().hasPendingRollback, isFalse);
        expect(markerIn(dbPath()), 'old');
        final List<RestorePoint> backups = store()
            .list(database: RestorePointDatabase.fushi)
            .where((RestorePoint e) => e.kind == RestorePointKind.preRollback)
            .toList();
        expect(backups, hasLength(1));
        expect(markerIn(backups.single.snapshotPath), 'new');
      });
    }

    test('目标快照坏了：什么都不动', () async {
      final RestorePoint target = await seedRollbackScene();
      File(target.snapshotPath).writeAsStringSync('not a database');
      await expectLater(
        store().rollback(<RestorePointRollbackPlan>[
          RestorePointRollbackPlan(target: target),
        ]),
        throwsA(anything),
      );
      expect(markerIn(dbPath()), 'new');
      expect(store().hasPendingRollback, isFalse);
    });

    test('复习库配对：同一次更新建的点、且复习库还停在那次升到的 schema 才配对', () async {
      final RestorePoint main = await seedRollbackScene();
      final Directory srsPoint = Directory(
        p.join(store().root, '29990101-000000-000-srs-pre_update'),
      )..createSync();
      final String srsSnap = p.join(srsPoint.path, 'srs4.db');
      sqlite3.sqlite3.open(srsSnap)
        ..execute('CREATE TABLE srs_meta (key TEXT PRIMARY KEY, value TEXT)')
        ..execute("INSERT INTO srs_meta VALUES ('schema', '40026')")
        ..close();
      File(p.join(srsPoint.path, kRestorePointMetaFileName)).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'format': 1,
          'kind': 'pre_update',
          'database': 'srs',
          'createdAtMs': main.createdAtMs + 1000,
          'fromSchema': 40026,
          'toSchema': 40027,
          'appVersion': null,
          'files': <Object?>[
            <String, Object?>{'name': 'srs4.db', 'size': 1},
          ],
        }),
      );
      // 没有活的复习库：不配对。
      expect(store().companionSrsPoint(main), isNull);
      final String live = p.join(tmp.path, 'srs4.db');
      sqlite3.sqlite3.open(live)
        ..execute('CREATE TABLE srs_meta (key TEXT PRIMARY KEY, value TEXT)')
        ..execute("INSERT INTO srs_meta VALUES ('schema', '40027')")
        ..close();
      expect(
        store().companionSrsPoint(main)?.database,
        RestorePointDatabase.srs,
      );
      // 不是「更新前」点（例如回滚前点）：不配对。
      final RestorePoint notPreUpdate = RestorePoint(
        id: main.id,
        directory: main.directory,
        kind: RestorePointKind.preRollback,
        database: main.database,
        createdAtMs: main.createdAtMs,
        fromSchema: main.fromSchema,
        toSchema: main.toSchema,
        files: main.files,
      );
      expect(store().companionSrsPoint(notPreUpdate), isNull);
      // 复习库之后又被升过：不配对。
      sqlite3.sqlite3.open(live)
        ..execute("UPDATE srs_meta SET value = '40028'")
        ..close();
      expect(store().companionSrsPoint(main), isNull);
    });
  });
}
