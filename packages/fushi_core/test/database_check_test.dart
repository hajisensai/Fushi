import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:test/test.dart';

/// 反馈 s2fdTTmLyh「检查数据库」：integrity_check → 备份 → 修复 → 压缩 → 复检。
///
/// 用真实文件库（WAL + 与生产同一套自定义 SQL 函数），因为备份是 `VACUUM INTO`
/// 写文件、回滚走 SQLite backup API、报告里的大小读的是磁盘文件。

String _garble(final String s) => latin1.decode(utf8.encode(s));

void _setup(final CommonDatabase db) {
  db.execute('PRAGMA journal_mode=WAL');
  db.execute('PRAGMA foreign_keys = ON');
  registerFushiSqlFunctions(db);
}

Future<void> _insertReading(
  final FushiDatabase db, {
  required final String title,
  required final String dateKey,
  required final int chars,
  required final int timeMs,
  final int pages = 0,
  final int modified = 1,
}) => db.customStatement(
  'INSERT INTO reading_statistics (title, date_key, characters_read, '
  'reading_time_ms, pages_read, last_statistic_modified) '
  'VALUES (?, ?, ?, ?, ?, ?)',
  <Object?>[title, dateKey, chars, timeMs, pages, modified],
);

Future<void> _insertLookup(
  final FushiDatabase db, {
  required final String bookKey,
  required final String title,
  required final String dateKey,
  required final int lookups,
  required final int mines,
}) => db.customStatement(
  'INSERT INTO lookup_mining_counters (book_key, title, source_type, '
  'date_key, lookup_count, mine_count) VALUES (?, ?, ?, ?, ?, ?)',
  <Object?>[bookKey, title, 'book', dateKey, lookups, mines],
);

Future<List<Map<String, Object?>>> _rows(
  final FushiDatabase db,
  final String sql,
) async => <Map<String, Object?>>[
  for (final QueryRow r in await db.customSelect(sql).get()) r.data,
];

void main() {
  late Directory dir;
  late String dbPath;
  late FushiDatabase db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fushi_db_check_');
    dbPath = p.join(dir.path, fushiDatabaseFileName);
    db = FushiDatabase.forTesting(NativeDatabase(File(dbPath), setup: _setup));
    // 触发建表。
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  String backupPathAt(final int stamp) =>
      p.join(dir.path, databaseCheckBackupFileName(stamp));

  test('乱码统计行按 MAX 并回原桶，先备份，阶段按顺序回调', () async {
    const String title = '薬屋のひとりごと';
    final String g1 = _garble(title);
    final String g2 = _garble(g1);
    await _insertReading(
      db,
      title: title,
      dateKey: '2026-11-01',
      chars: 100,
      timeMs: 50000,
      modified: 5,
    );
    // 乱码副本：同一桶的拷贝，其中一份带着更大的值（另一端后来读得更多）。
    await _insertReading(
      db,
      title: g1,
      dateKey: '2026-11-01',
      chars: 100,
      timeMs: 57000,
      modified: 9,
    );
    await _insertReading(
      db,
      title: g2,
      dateKey: '2026-11-01',
      chars: 80,
      timeMs: 57000,
      modified: 7,
    );
    // 只有乱码、没有原桶的日期：剥层后新建原桶。
    await _insertReading(
      db,
      title: g2,
      dateKey: '2026-11-02',
      chars: 30,
      timeMs: 4000,
    );
    // 正常的拉丁字母书名不动。
    await _insertReading(
      db,
      title: 'Café',
      dateKey: '2026-11-01',
      chars: 7,
      timeMs: 1000,
    );

    final List<DatabaseCheckPhase> phases = <DatabaseCheckPhase>[];
    final String backupPath = backupPathAt(1001);
    final DatabaseCheckReport report = await runDatabaseCheck(
      db,
      dbPath: dbPath,
      backupPath: backupPath,
      onPhase: phases.add,
    );

    expect(phases, DatabaseCheckPhase.values);
    expect(report.failure, isNull);
    expect(report.healthy, isTrue);
    expect(report.problemsFound, isEmpty);
    expect(report.rolledBack, isFalse);
    expect(report.repairedReadingStatRows, 3);
    expect(report.backupPath, backupPath);
    expect(File(backupPath).existsSync(), isTrue);
    expect(report.backupBytes, greaterThan(0));
    expect(report.sizeBeforeBytes, greaterThan(0));
    expect(report.sizeAfterBytes, greaterThan(0));

    final List<Map<String, Object?>> rows = await _rows(
      db,
      'SELECT title, date_key, characters_read, reading_time_ms, '
      'last_statistic_modified FROM reading_statistics '
      'ORDER BY title, date_key',
    );
    expect(rows, <Map<String, Object?>>[
      <String, Object?>{
        'title': 'Café',
        'date_key': '2026-11-01',
        'characters_read': 7,
        'reading_time_ms': 1000,
        'last_statistic_modified': 1,
      },
      <String, Object?>{
        'title': title,
        'date_key': '2026-11-01',
        'characters_read': 100,
        'reading_time_ms': 57000,
        'last_statistic_modified': 9,
      },
      <String, Object?>{
        'title': title,
        'date_key': '2026-11-02',
        'characters_read': 30,
        'reading_time_ms': 4000,
        'last_statistic_modified': 1,
      },
    ]);

    // 备份是检查前的原样（5 行，含乱码行），可用来回滚。
    final FushiDatabase backup = FushiDatabase.forTesting(
      NativeDatabase(File(backupPath), setup: _setup),
    );
    addTearDown(backup.close);
    expect(
      await _rows(backup, 'SELECT COUNT(*) AS n FROM reading_statistics'),
      <Map<String, Object?>>[
        <String, Object?>{'n': 5},
      ],
    );
  });

  test('查词 / 制卡计数：书名与 bookKey 都剥层，按 MAX 并回', () async {
    const String title = '本好きの下剋上';
    const String key = 'epub:本好き';
    await _insertLookup(
      db,
      bookKey: key,
      title: title,
      dateKey: '2026-11-01',
      lookups: 10,
      mines: 2,
    );
    await _insertLookup(
      db,
      bookKey: _garble(key),
      title: _garble(title),
      dateKey: '2026-11-01',
      lookups: 12,
      mines: 1,
    );

    final DatabaseCheckReport report = await runDatabaseCheck(
      db,
      dbPath: dbPath,
      backupPath: backupPathAt(1002),
    );

    expect(report.healthy, isTrue);
    expect(report.repairedLookupCounterRows, 1);
    expect(
      await _rows(
        db,
        'SELECT book_key, title, lookup_count, mine_count '
        'FROM lookup_mining_counters',
      ),
      <Map<String, Object?>>[
        <String, Object?>{
          'book_key': key,
          'title': title,
          'lookup_count': 12,
          'mine_count': 2,
        },
      ],
    );
  });

  test('没有坏数据也照样备份、压缩，并只保留最近一份检查备份', () async {
    final File older = File(backupPathAt(1));
    await older.writeAsString('old backup');
    final File unrelated = File(p.join(dir.path, 'fushi.db.pre-restore.bak'));
    await unrelated.writeAsString('restore input');

    final DatabaseCheckReport report = await runDatabaseCheck(
      db,
      dbPath: dbPath,
      backupPath: backupPathAt(1003),
    );

    expect(report.healthy, isTrue);
    expect(report.repairedRows, 0);
    expect(report.backupPath, backupPathAt(1003));
    expect(older.existsSync(), isFalse, reason: '更早的检查备份应被清掉');
    expect(unrelated.existsSync(), isTrue, reason: '别的快照不归它管');
  });

  test('备份失败：库一个字节都不动，报告带阶段与原因', () async {
    await _insertReading(
      db,
      title: _garble('日本語'),
      dateKey: '2026-11-01',
      chars: 1,
      timeMs: 1,
    );
    final String badBackup = p.join(
      dir.path,
      'missing-dir',
      databaseCheckBackupFileName(1004),
    );

    final DatabaseCheckReport report = await runDatabaseCheck(
      db,
      dbPath: dbPath,
      backupPath: badBackup,
    );

    expect(report.failedPhase, DatabaseCheckPhase.backup);
    expect(report.failure, isNotNull);
    expect(report.healthy, isFalse);
    expect(report.backupPath, isNull);
    expect(report.repairedRows, 0);
    expect(
      await _rows(db, 'SELECT title FROM reading_statistics'),
      <Map<String, Object?>>[
        <String, Object?>{'title': _garble('日本語')},
      ],
      reason: '没有备份就不许修',
    );
  });

  test('复检发现库坏了：从备份整库回滚，报告带 verify 阶段', () async {
    await _insertReading(
      db,
      title: _garble('日本語'),
      dateKey: '2026-11-01',
      chars: 1,
      timeMs: 1,
    );
    final String backupPath = backupPathAt(1005);
    final List<String> restoreCalls = <String>[];
    int checks = 0;
    final DatabaseCheckReport report = await runDatabaseCheck(
      db,
      dbPath: dbPath,
      backupPath: backupPath,
      // 第 1 次（检查前）ok、第 2 次（复检）坏、第 3 次（回滚后）ok。
      integrityCheck: (FushiDatabase _) async =>
          ++checks == 2 ? <String>['row 1 missing from index x'] : <String>[],
      restoreFromBackup:
          ({required String backupPath, required String dbPath}) async {
            restoreCalls.add(backupPath);
            await restoreDatabaseFromBackup(
              backupPath: backupPath,
              dbPath: dbPath,
            );
          },
    );

    expect(restoreCalls, <String>[backupPath]);
    expect(report.rolledBack, isTrue);
    expect(report.failedPhase, DatabaseCheckPhase.verify);
    expect(report.healthy, isFalse);
    expect(report.backupPath, backupPath, reason: '回滚后备份仍保留');
    // 回滚后乱码行回来了（修复被整体撤销）。
    expect(
      await _rows(db, 'SELECT title FROM reading_statistics'),
      <Map<String, Object?>>[
        <String, Object?>{'title': _garble('日本語')},
      ],
    );
  });

  test('原本就有结构问题且 REINDEX 修不好：不再改写 / 压缩，留备份', () async {
    await _insertReading(
      db,
      title: _garble('日本語'),
      dateKey: '2026-11-01',
      chars: 1,
      timeMs: 1,
    );
    final List<DatabaseCheckPhase> phases = <DatabaseCheckPhase>[];
    final DatabaseCheckReport report = await runDatabaseCheck(
      db,
      dbPath: dbPath,
      backupPath: backupPathAt(1007),
      onPhase: phases.add,
      integrityCheck: (FushiDatabase _) async => <String>['page 3 corrupt'],
    );

    expect(phases, <DatabaseCheckPhase>[
      DatabaseCheckPhase.integrity,
      DatabaseCheckPhase.backup,
      DatabaseCheckPhase.repair,
    ]);
    expect(report.reindexed, isTrue);
    expect(report.problemsFound, <String>['page 3 corrupt']);
    expect(report.problemsRemaining, <String>['page 3 corrupt']);
    expect(report.healthy, isFalse);
    expect(report.repairedRows, 0);
    expect(report.backupPath, backupPathAt(1007));
    expect(
      await _rows(db, 'SELECT title FROM reading_statistics'),
      <Map<String, Object?>>[
        <String, Object?>{'title': _garble('日本語')},
      ],
    );
  });

  test('restoreDatabaseFromBackup 在线把整库换回备份内容', () async {
    await _insertReading(
      db,
      title: 'before',
      dateKey: '2026-11-01',
      chars: 1,
      timeMs: 1,
    );
    final String backupPath = backupPathAt(1006);
    await db.customStatement('VACUUM INTO ?', <Object?>[backupPath]);
    await db.customStatement('DELETE FROM reading_statistics');
    await _insertReading(
      db,
      title: 'after',
      dateKey: '2026-11-01',
      chars: 2,
      timeMs: 2,
    );

    await restoreDatabaseFromBackup(backupPath: backupPath, dbPath: dbPath);

    // drift 连接没关，直接看到写回后的内容。
    expect(
      await _rows(db, 'SELECT title FROM reading_statistics'),
      <Map<String, Object?>>[
        <String, Object?>{'title': 'before'},
      ],
    );
    expect(await databaseIntegrityProblems(db), isEmpty);
  });

  test('检查备份命名命中快照白名单（存储页可列出 / 删除）', () {
    final String name = databaseCheckBackupFileName(1780735422000);
    expect(name, 'fushi.db.check-bak-1780735422000.db');
    expect(isDatabaseCheckBackupFileName(name), isTrue);
    expect(isDatabaseSnapshotFileName(name), isTrue);
    expect(isDatabaseCheckBackupFileName('$name-wal'), isFalse);
    expect(isDatabaseCheckBackupFileName('fushi.db.check-bak-.db'), isFalse);
  });
}
