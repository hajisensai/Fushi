import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw;

/// BUG-2119：一条写语句拿到 `SQLITE_BUSY` 之后，整条连接不得被它毒化。
///
/// 真机现场：另一个进程短暂持有写锁 → 本连接的一条 UPDATE 在 busy_timeout 后
/// 抛 `SqliteException(5)` → sqlite3 3.3.3 抛错前**不 reset** 语句，drift 又把
/// 预编译语句缓存起来不再碰 → 那条被挂起的写 VM 一直「活着」（`nVdbeWrite>0`）
/// → 之后本连接每一次 COMMIT 都抛「cannot commit transaction - SQL statements
/// in progress」、autocommit 写入永不落盘（WAL 冻结一小时），读却一切正常。
/// 视频页退出前 `setPref` 事务提交失败 → 用户被锁在视频页里。
///
/// 上游 sqlite3 3.4.0 起「Reset statements after `execute` and `select`」
/// 修掉了这一条；本仓把 sqlite3 抬到 ≥3.4.0。本测试用真库 + 真第二连接复现
/// 那段时序：3.3.3 下 `setPref` 抛 SqliteException（红），≥3.4.0 绿。
///
/// 用真实磁盘临时目录：被测对象就是 WAL 文件上的跨连接锁语义，`NativeDatabase.memory`
/// 造不出第二个连接。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_bug2119_');
  });
  tearDown(() async {
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {
        /* Windows 上偶发句柄延迟释放，不影响断言 */
      }
    }
  });

  test(
    '写语句撞 SQLITE_BUSY 之后，同连接后续事务仍能 COMMIT 并跨连接可见',
    () async {
      final String path = p.join(tmp.path, 'fushi.db');
      final FushiDatabase db = FushiDatabase.atFile(path);
      // 先真正开库（schema 建好、WAL 生效），再让外部连接抢写锁。
      await db.setPref('bug2119.warmup', '1');

      final raw.Database outsider = raw.sqlite3.open(path);
      outsider.execute('BEGIN IMMEDIATE');
      try {
        // busy_timeout=5000 到期后必须以 SqliteException 收场——这一步就是真机上
        // 「另一个进程持锁」的复刻。故意选一条**之后不会再被执行**的 SQL：drift 只在
        // 同一 SQL 再次执行时才 reset 缓存语句，真机上被毒化的续期 UPDATE 正是如此。
        // drift 的后台 isolate 执行器把远端异常包成 DriftRemoteException
        // （`drift/remote.dart` 是实验 API，不导入类型，按异常文本认）。
        await expectLater(
          db.updateVideoBookPosition('bug2119/never-again', 1, playedAt: 1),
          throwsA(
            isA<Exception>().having(
              (Exception e) => e.toString(),
              'toString',
              contains('SqliteException'),
            ),
          ),
        );
      } finally {
        outsider.execute('ROLLBACK');
        outsider.close();
      }

      // 3.3.3：这里抛「cannot commit transaction - SQL statements in progress」。
      await db.setPref('bug2119.after-busy', 'committed');

      // 跨连接读到 = 真的 COMMIT 进了 WAL，而不是留在本连接的隐式事务里。
      final raw.Database verifier = raw.sqlite3.open(path);
      try {
        final raw.ResultSet rows = verifier.select(
          'SELECT value FROM preferences WHERE key = ?',
          <Object>['bug2119.after-busy'],
        );
        expect(rows, hasLength(1));
        expect(rows.first['value'], 'committed');
      } finally {
        verifier.close();
      }
      await db.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
