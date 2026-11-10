import 'dart:async';
import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:test/test.dart';

/// BUG-4279：另一个进程（`:second_screen` 副屏面板写查词历史、`:popup` 浮窗）
/// 正持有写锁时，主进程的查词 / 制卡计数不得丢。
///
/// 旧实现是 deferred 事务里先 SELECT 再 UPDATE / INSERT：SELECT 开了读事务，
/// 之后升级写锁撞上别的进程的写锁，SQLite 不调 busy handler（已持读事务的连接
/// 等锁可能死锁），立刻 `SqliteException(5) database is locked`。修复后事务第一条
/// 语句就是写，等锁走 busy_timeout，外部连接提交后照常累加。
///
/// 用真实磁盘临时库 + 真第二连接：被测的就是 WAL 跨连接锁语义，内存库造不出来。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late String path;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_bug4279_');
    path = p.join(tmp.path, 'fushi.db');
    db = FushiDatabase.atFile(path);
  });
  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {
        /* Windows 上偶发句柄延迟释放，不影响断言 */
      }
    }
  });

  /// 外部连接拿写锁并写一条（模拟面板进程落查词历史），[hold] 后提交。
  Future<void> holdWriteLock(Duration hold) async {
    final raw.Database outsider = raw.sqlite3.open(path);
    outsider.execute('BEGIN IMMEDIATE');
    outsider.execute(
      'INSERT OR REPLACE INTO preferences (key, value, updated_at) '
      "VALUES ('bug4279.outsider', '1', 0)",
    );
    await Future<void>.delayed(hold);
    outsider.execute('COMMIT');
    outsider.close();
  }

  int counter(String column, String title) {
    final raw.Database verifier = raw.sqlite3.open(path);
    try {
      final raw.ResultSet rows = verifier.select(
        'SELECT $column AS c FROM lookup_mining_counters '
        "WHERE title = ? AND source_type = 'book' AND date_key = '2026-11-08'",
        <Object>[title],
      );
      return rows.isEmpty ? 0 : rows.first['c'] as int;
    } finally {
      verifier.close();
    }
  }

  test('addLookupCount 在别的连接持写锁期间等锁而不是 database is locked', () async {
    // 已有当日行（UPDATE 分支）。
    await db.addLookupCount(
      bookKey: 'book/A',
      title: 'BookA',
      sourceType: 'book',
      dateKey: '2026-11-08',
    );
    final Future<void> outsider = holdWriteLock(
      const Duration(milliseconds: 400),
    );
    await db.addLookupCount(
      bookKey: 'book/A',
      title: 'BookA',
      sourceType: 'book',
      dateKey: '2026-11-08',
    );
    // 新行（INSERT 分支）也要等锁。
    final Future<void> outsider2 = holdWriteLock(
      const Duration(milliseconds: 400),
    );
    await db.addLookupCount(
      bookKey: 'book/B',
      title: 'BookB',
      sourceType: 'book',
      dateKey: '2026-11-08',
    );
    await outsider;
    await outsider2;
    expect(counter('lookup_count', 'BookA'), 2);
    expect(counter('lookup_count', 'BookB'), 1);
  });

  test('recordMiningEvent（全局 + per-book 制卡计数）同样等锁', () async {
    await db.recordMiningEvent(
      bookKey: 'book/A',
      title: 'BookA',
      sourceType: 'book',
      at: DateTime(2026, 11, 8, 12),
    );
    final Future<void> outsider = holdWriteLock(
      const Duration(milliseconds: 400),
    );
    await db.recordMiningEvent(
      bookKey: 'book/A',
      title: 'BookA',
      sourceType: 'book',
      at: DateTime(2026, 11, 8, 13),
    );
    await outsider;
    expect(counter('mine_count', 'BookA'), 2);
    final List<MiningStatisticRow> global = await db
        .getMiningStatisticsBySource('book');
    expect(global.single.count, 2);
  });

  test('累加不覆盖 book_key、两列互不干扰', () async {
    await db.addMineCountPerBook(
      bookKey: 'book/A',
      title: 'BookA',
      sourceType: 'book',
      dateKey: '2026-11-08',
    );
    await db.addLookupCount(
      bookKey: 'book/A',
      title: 'BookA',
      sourceType: 'book',
      dateKey: '2026-11-08',
      delta: 3,
    );
    final List<LookupMiningCounterRow> rows = await db
        .getLookupMiningCountersBySource('book');
    expect(rows, hasLength(1));
    expect(rows.single.lookupCount, 3);
    expect(rows.single.mineCount, 1);
    expect(rows.single.bookKey, 'book/A');
  });
}
