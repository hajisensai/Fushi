import 'dart:io';

import 'package:test/test.dart';

/// BUG-772 Task 3 源码守卫：DB probe-open 的 busy 超时必须先于 `journal_mode=WAL`。
///
/// BUG-4241 起 busy 超时由 `installWallClockBusyTimeout(db)`（按墙钟计时）提供，
/// `applyPragmas` 里不许再出现 `PRAGMA busy_timeout`——它会覆盖该 handler，退回
/// 按次数计时、在 Linux debug / 测试里被 SIGPROF 压成几十毫秒的内置实现。
///
/// 与主 raster 根因并存的独立同步冻结隐患：视频硬崩（native UAF）留脏 `-wal`/`-shm`
/// 时，`_openWithRecovery` Layer 0 的同步 probe-open（`sqlite3.open` + PRAGMA）里
/// `journal_mode=WAL` 切换可能因锁争用在 UI isolate 上长阻塞。把 `busy_timeout` 提到
/// **第一条**，让 WAL 切换本身也受 5s busy 超时约束，避免无限同步阻塞。
///
/// `applyPragmas` 是 `_openWithRecovery` 内的局部函数，无法直接单测，故源码层钉死顺序。
void main() {
  test('applyPragmas 把 busy 超时置于 journal_mode=WAL 之前', () {
    final String src = File(
      '../packages/fushi_core/lib/src/database/database.dart',
    ).readAsStringSync();
    final RegExpMatch? body = RegExp(
      r'void applyPragmas\(CommonDatabase db\) \{(.*?)\n  \}',
      dotAll: true,
    ).firstMatch(src);
    expect(body, isNotNull, reason: '找不到 applyPragmas 方法体');
    final String b = body!.group(1)!;
    final int busyAt = b.indexOf('installWallClockBusyTimeout(db)');
    // 只认真正执行的语句，注释里提到的 journal_mode=WAL 不算。
    final int walAt = b.indexOf("db.execute('PRAGMA journal_mode=WAL')");
    expect(busyAt, greaterThanOrEqualTo(0), reason: '必须装按墙钟计时的 busy 超时');
    expect(
      b.contains('PRAGMA busy_timeout'),
      isFalse,
      reason: 'PRAGMA busy_timeout 会覆盖按墙钟计时的 busy handler（BUG-4241）',
    );
    expect(walAt, greaterThanOrEqualTo(0), reason: '必须设 journal_mode=WAL');
    expect(
      busyAt,
      lessThan(walAt),
      reason: 'busy_timeout 须先于 WAL 切换，否则脏 sidecar 上 WAL 切换不受 busy 超时约束',
    );
  });
}
