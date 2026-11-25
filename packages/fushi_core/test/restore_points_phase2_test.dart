import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';

/// 第二期：定时 / 操作前还原点的写入、修剪与按库替换。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_restore_points_p2_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 写一个只有一张表、一行 [marker] 的 sqlite 库。
  void writeDb(String path, String marker, {int userVersion = 0}) {
    final sqlite3.Database db = sqlite3.sqlite3.open(path);
    try {
      db.execute('CREATE TABLE IF NOT EXISTS t (v TEXT)');
      db.execute('DELETE FROM t');
      db.execute('INSERT INTO t VALUES (?)', <Object?>[marker]);
      db.execute('PRAGMA user_version = $userVersion');
    } finally {
      db.close();
    }
  }

  String readMarker(String path) {
    final sqlite3.Database db = sqlite3.sqlite3.open(
      path,
      mode: sqlite3.OpenMode.readOnly,
    );
    try {
      return db.select('SELECT v FROM t').first.columnAt(0) as String;
    } finally {
      db.close();
    }
  }

  RestorePoint scheduledAt(RestorePointStore store, DateTime at, int bytes) {
    final RestorePointDraft draft = store.begin(
      kind: RestorePointKind.scheduled,
      nowMs: at.millisecondsSinceEpoch,
    );
    File(
      p.join(draft.directory, kRestorePointArchiveFileName),
    ).writeAsBytesSync(List<int>.filled(bytes, 1));
    return store.commit(
      draft,
      fromSchema: kFushiDbSchemaVersion,
      toSchema: kFushiDbSchemaVersion,
      categories: const <String>['settings', 'srs'],
      excludedCategories: const <String>['books'],
      includesSrsMedia: false,
    );
  }

  test('定时还原点：元数据带类别与媒体开关，重读一致', () {
    final RestorePointStore store = RestorePointStore(tmp.path);
    final RestorePoint written = scheduledAt(store, DateTime.utc(2026), 10);
    final RestorePoint read = store.list().single;
    expect(read.id, written.id);
    expect(read.kind, RestorePointKind.scheduled);
    expect(read.categories, <String>['settings', 'srs']);
    expect(read.excludedCategories, <String>['books']);
    expect(read.includesSrsMedia, isFalse);
    expect(read.archivePath, p.join(read.directory, 'backup.zip'));
    expect(read.rawDatabasePath(RestorePointDatabase.fushi), isNull);
    expect(read.totalBytes, 10);
  });

  test('写到一半的点不会被并发的 prune 当残留删掉；放弃后目录删除', () {
    final RestorePointStore store = RestorePointStore(tmp.path);
    final RestorePointDraft draft = store.begin(
      kind: RestorePointKind.scheduled,
    );
    store.prune(RestorePointDatabase.fushi);
    expect(Directory(draft.directory).existsSync(), isTrue);
    store.discard(draft);
    expect(Directory(draft.directory).existsSync(), isFalse);
  });

  test('自定义根：定时还原点写进那个文件夹，默认目录不受影响', () {
    final String custom = p.join(tmp.path, 'elsewhere');
    final RestorePointStore store = RestorePointStore(
      tmp.path,
      rootDirectory: custom,
    );
    final RestorePoint point = scheduledAt(store, DateTime.utc(2026), 3);
    expect(p.isWithin(custom, point.directory), isTrue);
    expect(RestorePointStore(tmp.path).list(), isEmpty);
  });

  test('定时修剪：分层 + 刚写好的那份永不删', () {
    final RestorePointStore store = RestorePointStore(tmp.path);
    final DateTime now = DateTime.utc(2026, 6, 1, 12);
    // 两份同一天（第 3 天）的旧点：只留较新的那份。
    final RestorePoint older = scheduledAt(
      store,
      now.subtract(const Duration(days: 3, hours: 5)),
      1,
    );
    final RestorePoint newer = scheduledAt(
      store,
      now.subtract(const Duration(days: 3, hours: 1)),
      1,
    );
    // 一份 200 天前的点，按保留规则早该删——但它是刚写好的（受保护）。
    final RestorePoint ancient = scheduledAt(
      store,
      now.subtract(const Duration(days: 200)),
      1,
    );
    final List<RestorePoint> gone = store.pruneScheduled(
      deviceId: null,
      protectId: ancient.id,
      now: now,
    );
    expect(gone.map((RestorePoint e) => e.id), <String>[older.id]);
    expect(store.list().map((RestorePoint e) => e.id).toSet(), <String>{
      newer.id,
      ancient.id,
    });
  });

  test('操作前还原点：主库 VACUUM INTO + 复习库回调，留最新 5 份', () async {
    final String live = p.join(tmp.path, 'fushi.db');
    writeDb(live, 'main-v1', userVersion: kFushiDbSchemaVersion);
    final RestorePointStore store = RestorePointStore(tmp.path);
    RestorePoint? first;
    for (int i = 0; i < 6; i++) {
      final RestorePoint point = await store.createPreOperationPoint(
        reason: 'replace',
        fushiDbPath: live,
        snapshotSrs: (String dest) async => writeDb(dest, 'srs-$i'),
      );
      first ??= point;
    }
    final List<RestorePoint> points = store.list();
    expect(points.length, kRestorePointKeepPreOperation);
    expect(points.any((RestorePoint e) => e.id == first!.id), isFalse);
    final RestorePoint newest = points.first;
    expect(newest.kind, RestorePointKind.preOperation);
    expect(newest.reason, 'replace');
    expect(newest.fromSchema, kFushiDbSchemaVersion);
    expect(
      readMarker(newest.rawDatabasePath(RestorePointDatabase.fushi)!),
      'main-v1',
    );
    expect(
      readMarker(newest.rawDatabasePath(RestorePointDatabase.srs)!),
      'srs-5',
    );
  });

  test('操作前还原点失败（复习库快照抛错）：不留半截目录、原样抛出', () async {
    final String live = p.join(tmp.path, 'fushi.db');
    writeDb(live, 'main');
    final RestorePointStore store = RestorePointStore(tmp.path);
    await expectLater(
      store.createPreOperationPoint(
        reason: 'replace',
        fushiDbPath: live,
        snapshotSrs: (String dest) async =>
            throw const FileSystemException('disk full'),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(Directory(store.root).listSync().whereType<Directory>(), isEmpty);
  });

  test('从操作前还原点同时换回主库与复习库（按库点名）', () async {
    final String liveMain = p.join(tmp.path, 'fushi.db');
    final String liveSrs = p.join(tmp.path, 'srs4.db');
    writeDb(liveMain, 'main-old', userVersion: kFushiDbSchemaVersion);
    writeDb(liveSrs, 'srs-old');
    final RestorePointStore store = RestorePointStore(tmp.path);
    final RestorePoint point = await store.createPreOperationPoint(
      reason: 'srs_migration',
      fushiDbPath: liveMain,
      snapshotSrs: (String dest) async => File(liveSrs).copySync(dest),
    );
    writeDb(liveMain, 'main-new', userVersion: kFushiDbSchemaVersion);
    writeDb(liveSrs, 'srs-new');
    final List<RestorePoint> backups = await store
        .rollback(<RestorePointRollbackPlan>[
          RestorePointRollbackPlan(
            target: point,
            database: RestorePointDatabase.fushi,
          ),
          RestorePointRollbackPlan(
            target: point,
            database: RestorePointDatabase.srs,
          ),
        ]);
    expect(readMarker(liveMain), 'main-old');
    expect(readMarker(liveSrs), 'srs-old');
    expect(backups.length, 2);
    expect(
      backups.map((RestorePoint e) => e.database).toSet(),
      RestorePointDatabase.values.toSet(),
    );
  });
  test('操作前还原点按 reason 各自留份：同步对比跑多次挤不掉 Anki 迁移前那份', () async {
    final String live = p.join(tmp.path, 'fushi.db');
    writeDb(live, 'main', userVersion: kFushiDbSchemaVersion);
    final RestorePointStore store = RestorePointStore(tmp.path);
    final RestorePoint migration = await store.createPreOperationPoint(
      reason: 'srs_migration',
      fushiDbPath: live,
    );
    for (int i = 0; i < kRestorePointKeepPreOperation + 2; i++) {
      await store.createPreOperationPoint(
        reason: 'sync_download',
        fushiDbPath: live,
      );
    }
    final List<RestorePoint> points = store.list();
    expect(points.any((RestorePoint e) => e.id == migration.id), isTrue);
    expect(
      points.where((RestorePoint e) => e.reason == 'sync_download').length,
      kRestorePointKeepPreOperation,
    );
  });

  test('替换的目标点受保护：从最旧那份替换时，拍操作前还原点不会先把它删掉', () async {
    final String live = p.join(tmp.path, 'fushi.db');
    writeDb(live, 'main', userVersion: kFushiDbSchemaVersion);
    final RestorePointStore store = RestorePointStore(tmp.path);
    final List<RestorePoint> made = <RestorePoint>[
      for (int i = 0; i < kRestorePointKeepPreOperation; i++)
        await store.createPreOperationPoint(
          reason: 'replace',
          fushiDbPath: live,
        ),
    ];
    final RestorePoint target = made.first;
    await store.createPreOperationPoint(
      reason: 'replace',
      fushiDbPath: live,
      protectIds: <String>{target.id},
    );
    expect(Directory(target.directory).existsSync(), isTrue);
    expect(store.list().length, kRestorePointKeepPreOperation + 1);
  });

  test('正被还原的点（hold）不被任何修剪删掉，放开后照常修剪', () async {
    final String live = p.join(tmp.path, 'fushi.db');
    writeDb(live, 'main', userVersion: kFushiDbSchemaVersion);
    final RestorePointStore store = RestorePointStore(tmp.path);
    final RestorePoint oldest = await store.createPreOperationPoint(
      reason: 'replace',
      fushiDbPath: live,
    );
    final void Function() release = RestorePointStore.hold(oldest.directory);
    for (int i = 0; i < kRestorePointKeepPreOperation; i++) {
      await store.createPreOperationPoint(reason: 'replace', fushiDbPath: live);
    }
    expect(Directory(oldest.directory).existsSync(), isTrue);
    release();
    release(); // 重复放开无害
    expect(RestorePointStore.isHeld(oldest.directory), isFalse);
    store.prune(RestorePointDatabase.fushi);
    expect(Directory(oldest.directory).existsSync(), isFalse);

    // 定时还原点同理：被钉住的旧点不进删除名单。
    final DateTime now = DateTime.utc(2026, 6, 1, 12);
    final RestorePoint ancient = scheduledAt(
      store,
      now.subtract(const Duration(days: 300)),
      1,
    );
    scheduledAt(store, now, 1);
    final void Function() releaseScheduled = RestorePointStore.hold(
      ancient.directory,
    );
    expect(store.pruneScheduled(deviceId: null, now: now), isEmpty);
    releaseScheduled();
    expect(
      store
          .pruneScheduled(deviceId: null, now: now)
          .map((RestorePoint e) => e.id),
      <String>[ancient.id],
    );
  });

  test('自定义文件夹里写到一半的定时点在修剪时清掉，正在写的不碰', () {
    final String custom = p.join(tmp.path, 'elsewhere');
    final RestorePointStore store = RestorePointStore(
      tmp.path,
      rootDirectory: custom,
    );
    final Directory stale = Directory(
      p.join(custom, '20260101-000000-000-fushi-scheduled'),
    )..createSync(recursive: true);
    File(
      p.join(stale.path, kRestorePointArchiveFileName),
    ).writeAsStringSync('half');
    final Directory foreign = Directory(p.join(custom, 'my-own-folder'))
      ..createSync();
    final RestorePointDraft writing = store.begin(
      kind: RestorePointKind.scheduled,
    );
    store.pruneScheduled(deviceId: null, now: DateTime.utc(2026, 6));
    expect(stale.existsSync(), isFalse);
    expect(foreign.existsSync(), isTrue);
    expect(Directory(writing.directory).existsSync(), isTrue);
    store.discard(writing);
  });

  test('整库定时点：fullDatabase 写进元数据、重读一致；老点为 null', () {
    final RestorePointStore store = RestorePointStore(tmp.path);
    final RestorePointDraft draft = store.begin(
      kind: RestorePointKind.scheduled,
    );
    File(
      p.join(draft.directory, kRestorePointArchiveFileName),
    ).writeAsStringSync('zip');
    store.commit(
      draft,
      fromSchema: kFushiDbSchemaVersion,
      toSchema: kFushiDbSchemaVersion,
      categories: const <String>['fonts'],
      excludedCategories: const <String>['books'],
      includesSrsMedia: false,
      fullDatabase: true,
    );
    expect(store.list().single.fullDatabase, isTrue);
    scheduledAt(store, DateTime.utc(2025), 1);
    expect(
      store
          .list()
          .firstWhere((RestorePoint e) => e.id != draft.id)
          .fullDatabase,
      isNull,
    );
  });
}
