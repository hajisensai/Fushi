import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../helpers/source_guard.dart';
import 'temp_dir_cleanup.dart';

/// 推荐包导入后 Windows 启动 `FormatException: Invalid radix-10 number`（反馈
/// zxzKphM20J）。覆盖恢复用 `INSERT INTO t SELECT * FROM bak.t` 按**位置**回灌本机
/// 设置层；推荐包里的库是旧 schema 迁移上来的（v117 `addColumn` 把 profiles.uid 补在
/// 表尾），本机新装库由 onCreate 建表（uid 在中间）——按位置复制把 UUID 写进了
/// created_at，drift 读 ProfileRow 时 `int.parse` 抛，库写坏、每次启动都炸。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bk_colorder_');
  });
  tearDown(() async {
    try {
      if (tmp.existsSync()) await cleanupTempDir(tmp);
    } on PathNotFoundException {
      // Windows recursive temp cleanup can race.
    }
  });

  /// 把 [db] 的 profiles 表重建成「v117 addColumn」形态：uid 在表尾。
  Future<void> moveProfilesUidToTail(FushiDatabase db) async {
    await db.customStatement('PRAGMA foreign_keys = OFF');
    await db.customStatement(
      'CREATE TABLE profiles_tail ('
      'id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
      'name TEXT NOT NULL UNIQUE, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'uid TEXT NULL)',
    );
    await db.customStatement(
      'INSERT INTO profiles_tail (id, name, created_at, updated_at, uid) '
      'SELECT id, name, created_at, updated_at, uid FROM profiles',
    );
    await db.customStatement('DROP TABLE profiles');
    await db.customStatement('ALTER TABLE profiles_tail RENAME TO profiles');
    await db.customStatement('PRAGMA foreign_keys = ON');
  }

  List<String> columnsOf(String dbPath, String table) {
    final sqlite.Database raw = sqlite.sqlite3.open(dbPath);
    try {
      return <String>[
        for (final sqlite.Row r in raw.select('PRAGMA table_info($table)'))
          r['name'] as String,
      ];
    } finally {
      raw.close();
    }
  }

  test('保留本机设置的覆盖恢复按列名回灌 profiles：列序不同也不串列', () async {
    // 推荐包（备份）：旧库形态，uid 在表尾。
    final String srcDir = p.join(tmp.path, 'src');
    Directory(srcDir).createSync(recursive: true);
    final FushiDatabase src = FushiDatabase(srcDir);
    await src.getAllProfiles();
    await moveProfilesUidToTail(src);
    final String zip = p.join(tmp.path, 'pack.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDir,
      appVersion: '1.0.0',
    ).createBackup(zip);
    await src.close();
    expect(
      columnsOf(p.join(srcDir, 'fushi.db'), 'profiles').last,
      'uid',
      reason: '前置：备份库的 uid 必须在表尾',
    );

    // 本机：新装库（onCreate，uid 在中间），带一个已知 uid / 时刻的 Profile。
    final String dstDir = p.join(tmp.path, 'dst');
    Directory(dstDir).createSync(recursive: true);
    const String localUid = '01a199bf-1234-7abc-8def-0123456789ab';
    const int createdAt = 1762044853000;
    const int updatedAt = 1762044999000;
    final FushiDatabase local = FushiDatabase(dstDir);
    await local.insertProfile(
      ProfilesCompanion.insert(
        name: 'local-profile',
        uid: const Value<String?>(localUid),
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    );
    await local.close();
    expect(
      columnsOf(p.join(dstDir, 'fushi.db'), 'profiles'),
      isNot(equals(columnsOf(p.join(srcDir, 'fushi.db'), 'profiles'))),
      reason: '前置：两边物理列序不同',
    );

    await BackupRestoreService.restoreBackup(
      dbDirectory: dstDir,
      zipPath: zip,
      importSettings: false,
    );

    // 先用裸 sqlite 看落盘值（FushiDatabase 开库时的修复步骤会掩盖回灌错误）。
    final sqlite.Database raw = sqlite.sqlite3.open(p.join(dstDir, 'fushi.db'));
    try {
      final sqlite.ResultSet rows = raw.select(
        'SELECT uid, created_at, updated_at, typeof(created_at) AS t '
        "FROM profiles WHERE name = 'local-profile'",
      );
      expect(rows, hasLength(1));
      expect(rows.single['t'], 'integer');
      expect(rows.single['uid'], localUid);
      expect(rows.single['created_at'], createdAt);
      expect(rows.single['updated_at'], updatedAt);
    } finally {
      raw.close();
    }

    final FushiDatabase after = FushiDatabase(dstDir);
    addTearDown(after.close);
    final List<ProfileRow> profiles = await after.getAllProfiles();
    final ProfileRow mine = profiles.singleWhere(
      (ProfileRow r) => r.name == 'local-profile',
    );
    expect(mine.uid, localUid);
    expect(mine.createdAt, createdAt);
  });

  test('开库时还原已被按位置复制写坏的 profiles 行（两种错位方向）', () async {
    final String dir = p.join(tmp.path, 'broken');
    Directory(dir).createSync(recursive: true);
    final FushiDatabase seed = FushiDatabase(dir);
    await seed.getAllProfiles();
    await moveProfilesUidToTail(seed);
    await seed.close();

    const String uidA = '01a199bf-aaaa-7abc-8def-0123456789ab';
    const String uidB = '01a199bf-bbbb-7abc-8def-0123456789ab';
    final sqlite.Database raw = sqlite.sqlite3.open(p.join(dir, 'fushi.db'));
    try {
      raw.execute('DELETE FROM profiles');
      // 方向一（反馈现场）：目标 uid 在尾、源 uid 在中 →
      // created_at = UUID，updated_at = 源 created_at，uid = 源 updated_at。
      raw.execute(
        'INSERT INTO profiles (id, name, created_at, updated_at, uid) '
        "VALUES (1, 'a', '$uidA', 1000, '2000')",
      );
      // 方向二：目标 uid 在中、源 uid 在尾 →
      // uid = 源 created_at，created_at = 源 updated_at，updated_at = UUID。
      raw.execute(
        'INSERT INTO profiles (id, name, created_at, updated_at, uid) '
        "VALUES (2, 'b', 4000, '$uidB', '3000')",
      );
      // 正常行不受影响。
      raw.execute(
        'INSERT INTO profiles (id, name, created_at, updated_at, uid) '
        "VALUES (3, 'c', 5000, 6000, '01a199bf-cccc-7abc-8def-0123456789ab')",
      );
    } finally {
      raw.close();
    }

    final FushiDatabase db = FushiDatabase(dir);
    addTearDown(db.close);
    final Map<String, ProfileRow> byName = <String, ProfileRow>{
      for (final ProfileRow r in await db.getAllProfiles()) r.name: r,
    };
    expect(byName['a']!.uid, uidA);
    expect(byName['a']!.createdAt, 1000);
    expect(byName['a']!.updatedAt, 2000);
    expect(byName['b']!.uid, uidB);
    expect(byName['b']!.createdAt, 3000);
    expect(byName['b']!.updatedAt, 4000);
    expect(byName['c']!.createdAt, 5000);
    expect(byName['c']!.updatedAt, 6000);
  });

  test('备份恢复源码里不再有按位置的 INSERT … SELECT *', () {
    final Directory dir = Directory('lib/src/sync/backup_service');
    final RegExp positional = RegExp(
      r'INSERT\s+INTO\s+\S+\s+(?:\x27\s*\x27\s*)?SELECT\s+\*\s+FROM',
      caseSensitive: false,
    );
    final List<String> offenders = <String>[];
    for (final FileSystemEntity e in dir.listSync()) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final List<String> lines = maskComments(e.readAsStringSync()).split('\n');
      for (int i = 0; i < lines.length; i++) {
        if (positional.hasMatch(lines[i])) offenders.add('${e.path}:${i + 1}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '按位置复制会跨列序差异串列；用 _copyTableByColumnNames',
    );
  });
}
