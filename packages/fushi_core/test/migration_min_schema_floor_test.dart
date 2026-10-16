import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';

/// 最低 schema 门槛（[kMinSupportedSchemaVersion]）守卫。
///
/// 低于门槛的迁移阶梯（Hibiki 时代的改名 / 存量改写，v2–v75）已删除。遇到这类库
/// 必须**拒绝打开**并抛 [UnsupportedLegacySchemaException]，库文件原样保留；绝不
/// 能退化成「跑剩下的阶梯」或「建一个空库顶替」。改名前只有 `hibiki.db` 的目录
/// 同理：不改名、不建 `fushi.db`，直接拒绝。
///
/// 各用例都走真实文件（[FushiDatabase] 按目录开库的生产路径），以便断言主库字节
/// 未被改动、旁边没有多出空库。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_min_schema_floor_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 句柄延迟释放：残留临时目录无害。
    }
  });

  /// 写一个真实的老库：WAL 模式（与生产库一致，开库时设 WAL 不改文件头）、
  /// 一张表一行数据、指定的 user_version；写完 checkpoint 并关闭，主文件即全部内容。
  void writeLegacyDb(String path, int userVersion) {
    final sqlite3.Database raw = sqlite3.sqlite3.open(path);
    try {
      raw.execute('PRAGMA journal_mode=WAL');
      raw.execute(
        'CREATE TABLE preferences (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)',
      );
      raw.execute(
        "INSERT INTO preferences (key, value) VALUES ('sentinel', 'kept')",
      );
      raw.execute('PRAGMA user_version = $userVersion');
      raw.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      raw.close();
    }
  }

  ({int userVersion, String sentinel}) readBack(String path) {
    final sqlite3.Database raw = sqlite3.sqlite3.open(
      path,
      mode: sqlite3.OpenMode.readOnly,
    );
    try {
      final int v =
          raw.select('PRAGMA user_version').first.values.first! as int;
      final String s =
          raw
                  .select(
                    "SELECT value FROM preferences WHERE key = 'sentinel'",
                  )
                  .first['value']
              as String;
      return (userVersion: v, sentinel: s);
    } finally {
      raw.close();
    }
  }

  test('门槛与桥接版本常量自洽', () {
    final FushiDatabase probe = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(probe.close);
    expect(
      kMinSupportedSchemaVersion,
      75,
      reason: '最后一条改写 Hibiki 时代旧字面量的台阶是 v74',
    );
    expect(probe.schemaVersion, greaterThan(kMinSupportedSchemaVersion));
    expect(kLegacySchemaBridgeAppVersion, '2.9.1');
  });

  test('user_version 低于门槛的库被拒绝打开，主库字节与数据原样保留', () async {
    final String dbPath = p.join(tmp.path, fushiDatabaseFileName);
    const int legacyVersion = kMinSupportedSchemaVersion - 1;
    writeLegacyDb(dbPath, legacyVersion);
    final Uint8List before = File(dbPath).readAsBytesSync();

    final FushiDatabase db = FushiDatabase(tmp.path);
    await expectLater(
      db.customSelect('PRAGMA user_version').getSingle(),
      throwsA(
        isA<UnsupportedLegacySchemaException>()
            .having(
              (UnsupportedLegacySchemaException e) => e.dbVersion,
              'dbVersion',
              legacyVersion,
            )
            .having(
              (UnsupportedLegacySchemaException e) => e.minSupportedVersion,
              'minSupportedVersion',
              kMinSupportedSchemaVersion,
            ),
      ),
    );
    await db.close();

    expect(
      File(dbPath).readAsBytesSync(),
      before,
      reason: '拒绝必须发生在任何迁移语句之前：主库一个字节都不能变',
    );
    final ({int userVersion, String sentinel}) after = readBack(dbPath);
    expect(
      after.userVersion,
      legacyVersion,
      reason: 'user_version 不得被推进（否则下次启动会跳过门槛判定）',
    );
    expect(after.sentinel, 'kept');
  });

  // 生产开库走后台 isolate 的 drift 连接，迁移钩子里抛的异常会被包成
  // DriftRemoteException 送回来；app 层按类型分派专屏，所以开库路径必须把它还原。
  // 此前降级保护的测试全用同步 NativeDatabase，从没走过这条路径。
  test('生产开库路径（后台 isolate）抛出的是类型化异常，不是 DriftRemoteException', () async {
    final String dbPath = p.join(tmp.path, fushiDatabaseFileName);
    final FushiDatabase probe = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    final int future = probe.schemaVersion + 1;
    await probe.close();
    writeLegacyDb(dbPath, future);

    final FushiDatabase db = FushiDatabase(tmp.path);
    await expectLater(
      db.customSelect('SELECT 1').get(),
      throwsA(
        isA<FushiDatabaseDowngradeException>().having(
          (FushiDatabaseDowngradeException e) => e.dbVersion,
          'dbVersion',
          future,
        ),
      ),
    );
    await db.close();
    expect(readBack(dbPath).userVersion, future);
  });

  test('极老的库（v1）同样被拒绝，而不是跑残余阶梯或建空库', () async {
    final String dbPath = p.join(tmp.path, fushiDatabaseFileName);
    writeLegacyDb(dbPath, 1);

    final FushiDatabase db = FushiDatabase(tmp.path);
    await expectLater(
      db.customSelect('SELECT 1').get(),
      throwsA(
        isA<UnsupportedLegacySchemaException>().having(
          (UnsupportedLegacySchemaException e) => e.dbVersion,
          'dbVersion',
          1,
        ),
      ),
    );
    await db.close();
    expect(readBack(dbPath).userVersion, 1);
  });

  test('只有改名前 hibiki.db 的目录：拒绝打开，不改名、不建 fushi.db', () async {
    final String oldPath = p.join(tmp.path, legacyHibikiDatabaseFileName);
    writeLegacyDb(oldPath, 68);
    final Uint8List before = File(oldPath).readAsBytesSync();

    final FushiDatabase db = FushiDatabase(tmp.path);
    await expectLater(
      db.customSelect('SELECT 1').get(),
      throwsA(
        isA<UnsupportedLegacySchemaException>()
            .having(
              (UnsupportedLegacySchemaException e) => e.dbVersion,
              'dbVersion',
              isNull,
            )
            .having(
              (UnsupportedLegacySchemaException e) => e.dbPath,
              'dbPath',
              oldPath,
            ),
      ),
    );
    // 开库回调本身就抛了（还没拿到 executor），LazyDatabase.close 会把同一个
    // 异常再抛一次；这里只关心它不留连接，异常已在上面断言过。
    await db.close().catchError((Object _) {});

    final File newDb = File(p.join(tmp.path, fushiDatabaseFileName));
    expect(
      newDb.existsSync(),
      isFalse,
      reason:
          '绝不能在旁边建一个空 fushi.db：那会让用户看到数据全没了，'
          '且下次启动「只有旧库」的判据不再命中',
    );
    expect(File('${newDb.path}-wal').existsSync(), isFalse);
    expect(File(oldPath).readAsBytesSync(), before, reason: '旧库原样保留，留给桥接版本去升级');
  });

  test('fushi.db 与遗留 hibiki.db 并存时照常打开 fushi.db（旧文件不影响判定）', () async {
    // 已经升级过的安装：fushi.db 在（这里用一个空文件 = 全新空库），旁边还躺着
    // 改名前的遗留 hibiki.db。只要 fushi.db 存在，就照常打开它。
    File(p.join(tmp.path, fushiDatabaseFileName)).writeAsBytesSync(<int>[]);
    writeLegacyDb(p.join(tmp.path, legacyHibikiDatabaseFileName), 68);
    final FushiDatabase fresh = FushiDatabase(tmp.path);
    await fresh.setPref('k', 'v');
    expect(await fresh.getPref('k'), 'v');
    await fresh.close();
  });

  group('checkSupportedSchemaVersion / sqliteUserVersionFromHeader', () {
    test('门槛以下抛，门槛及以上与 0（非 drift 库）放行', () {
      expect(
        () => checkSupportedSchemaVersion(kMinSupportedSchemaVersion - 1),
        throwsA(isA<UnsupportedLegacySchemaException>()),
      );
      expect(
        () => checkSupportedSchemaVersion(1),
        throwsA(isA<UnsupportedLegacySchemaException>()),
      );
      checkSupportedSchemaVersion(0);
      checkSupportedSchemaVersion(kMinSupportedSchemaVersion);
      checkSupportedSchemaVersion(kMinSupportedSchemaVersion + 40);
    });

    test('从真实 SQLite 文件头读出 user_version；非 SQLite / 过短返回 null', () {
      final String dbPath = p.join(tmp.path, 'probe.db');
      writeLegacyDb(dbPath, 70);
      final Uint8List bytes = File(dbPath).readAsBytesSync();
      expect(sqliteUserVersionFromHeader(bytes.sublist(0, 100)), 70);
      expect(sqliteUserVersionFromHeader(Uint8List(100)), isNull);
      expect(sqliteUserVersionFromHeader(bytes.sublist(0, 32)), isNull);
    });
  });
}
