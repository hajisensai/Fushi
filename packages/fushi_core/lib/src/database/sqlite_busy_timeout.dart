import 'dart:io' show sleep;

import 'package:sqlite3/common.dart' show CommonDatabase;

/// Fushi 库连接等别人写锁的上限（墙钟时间）。
const Duration kFushiDbBusyTimeout = Duration(seconds: 5);

/// 每次撞锁后的退避间隔（毫秒），与 SQLite 默认 busy handler 的节奏一致；
/// 超出表长后一律按最后一档。
const List<int> _backoffMs = <int>[
  1,
  2,
  5,
  10,
  15,
  20,
  25,
  25,
  25,
  50,
  50,
  100,
];

/// 给 [db] 装一个**按墙钟计时**的 busy handler，取代 `PRAGMA busy_timeout`。
///
/// SQLite 内置的 busy_timeout 是**按调用次数**累计「名义睡眠时长」判超时的
/// （`sqliteDefaultBusyCallback` 只看 count，不看实际过去了多久），它假设
/// `nanosleep` 每次都睡满。Linux 上 Dart VM 的采样 profiler（`flutter test`、
/// debug 与 profile 构建都开着，周期 1 ms）用 SIGPROF 打断所有进入了 isolate 的
/// 线程——包括正卡在 sqlite3_step 里等锁的后台 isolate 线程——`nanosleep` 每次
/// 不到 1 ms 就 EINTR 返回。结果 5 s 的超时实际几十毫秒就耗尽，另一连接（主进程
/// / `:popup` / 另一个 isolate）的写事务只要稍长，写入就抛
/// `SqliteException(5) database is locked`。
///
/// 这里按 [Stopwatch] 的真实流逝判超时，睡眠用 `dart:io` 的 [sleep]（遇 EINTR
/// 会续睡剩余时长）。`count == 0` 表示一次新的等锁事件（SQLite 每条语句开始执行
/// 时清零计数），据此重置计时。
///
/// 注意：`PRAGMA busy_timeout` 会覆盖这个 handler，连接上不要再设它。
void installWallClockBusyTimeout(
  CommonDatabase db, {
  Duration timeout = kFushiDbBusyTimeout,
}) {
  final Stopwatch waited = Stopwatch();
  db.busyHandler = (int count) {
    if (count == 0) {
      waited
        ..reset()
        ..start();
    }
    final Duration remaining = timeout - waited.elapsed;
    if (remaining <= Duration.zero) return false;
    final Duration step = Duration(
      milliseconds:
          _backoffMs[count < _backoffMs.length ? count : _backoffMs.length - 1],
    );
    sleep(step < remaining ? step : remaining);
    return true;
  };
}
