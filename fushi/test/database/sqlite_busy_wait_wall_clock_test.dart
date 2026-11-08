import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../sync/temp_dir_cleanup.dart';

/// BUG：Linux 上 `flutter test`（以及 debug / profile 构建）里，Fushi 库连接的
/// 5 s busy 超时实际只撑几十毫秒——另一连接持写锁稍久，写入就抛
/// `SqliteException(5) database is locked`（CI 偶发红：
/// `anki_settings_drift_store_test.dart` 两连接并发迁移）。
///
/// 这里用**确定时序**钉住：外部连接持写锁 1 s（远小于 5 s 超时）再提交，等锁的
/// 写入必须成功。不是靠循环碰概率：1 s 与 5 s 之间的余量是确定的，坏实现在 Linux
/// 上必然失败（每次 busy 睡眠被 VM profiler 的 SIGPROF 打断，按次数算的超时几十
/// 毫秒就耗尽），好实现在任何平台都必然成功。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('另一连接持写锁 1s（远小于 busy 超时）：写入等到锁释放后成功', () async {
    final Directory dir = await Directory.systemTemp.createTemp(
      'busy_wall_clock_',
    );
    addTearDown(() => cleanupTempDir(dir));
    final FushiDatabase db = FushiDatabase(dir.path);
    addTearDown(db.close);
    // 先开库（建表 / PRAGMA），让下面的等待只落在写锁上。
    expect(await db.getPref('k'), isNull);

    // 模拟另一进程（主进程 / :popup）正持有写事务。
    final sqlite3.Database holder = sqlite3.sqlite3.open(
      '${dir.path}/$fushiDatabaseFileName',
    );
    addTearDown(holder.close);
    holder.execute('BEGIN IMMEDIATE');

    final Stopwatch waited = Stopwatch()..start();
    final Future<bool> write = db.insertPrefIfAbsent('k', 's:v');
    await Future<void>.delayed(const Duration(seconds: 1));
    holder.execute('COMMIT');

    expect(await write, isTrue);
    expect(
      waited.elapsed,
      greaterThanOrEqualTo(const Duration(seconds: 1)),
      reason: '写入必须真的等到外部写锁释放',
    );
    expect(await db.getPref('k'), 's:v');
  });

  test('installWallClockBusyTimeout：锁一直不放时，等满墙钟超时才报 BUSY', () async {
    final Directory dir = await Directory.systemTemp.createTemp(
      'busy_wall_clock_raw_',
    );
    addTearDown(() => cleanupTempDir(dir));
    final String path = '${dir.path}/raw.db';
    final sqlite3.Database holder = sqlite3.sqlite3.open(path);
    addTearDown(holder.close);
    holder.execute('PRAGMA journal_mode=WAL');
    holder.execute('CREATE TABLE t (x INTEGER)');
    final sqlite3.Database waiter = sqlite3.sqlite3.open(path);
    addTearDown(waiter.close);
    installWallClockBusyTimeout(
      waiter,
      timeout: const Duration(milliseconds: 300),
    );

    holder.execute('BEGIN IMMEDIATE');
    final Stopwatch waited = Stopwatch()..start();
    Object? error;
    try {
      waiter.execute('INSERT INTO t VALUES (1)');
    } on sqlite3.SqliteException catch (e) {
      error = e;
    }
    waited.stop();
    holder.execute('COMMIT');

    expect(error, isA<sqlite3.SqliteException>());
    expect((error! as sqlite3.SqliteException).resultCode, 5);
    // 按次数计时的内置实现在 Linux 测试进程里几十毫秒就放弃；这里必须等满。
    expect(
      waited.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 300)),
    );
  });
}
