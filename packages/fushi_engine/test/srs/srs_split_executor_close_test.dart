// SrsSplitExecutor.close 等在途的事务外查询，但这份「在途」簿记不经调用方的 zone（PR 2771 审查）：以前登记的是
// 调用方 zone 里 `result.then(...)` 的 Future，页面在 FakeAsync zone 里发的流查询回执的微任务永远不被冲刷，
// close 永久挂起（unit-tests 分片跑满 60 分钟被取消）。这里用一个吞掉全部微任务的 zone 模拟「调用方 zone 不再
// 跑微任务」，查询在里面发出，close 在真实 zone 里调，必须等那几条查询在 worker 上跑完后返回。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart' show SrsDatabase;
import 'package:fushi_engine/srs/srs_database_executor.dart';
import 'package:fushi_engine/srs/srs_storage.dart' show kSrsDatabaseFileName;
import 'package:fushi_srs/fushi_srs.dart' show SrsCore;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 在内核里跑几百毫秒的查询（不碰任何表）。
const String _kSlowQuery =
    'WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n '
    'WHERE i < 5000000) SELECT SUM(i) AS s FROM n';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('调用方 zone 不跑微任务：close 照样等在途查询跑完后返回', () async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'srs_split_close_',
    );
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄滞后；临时目录留给系统清理。
      }
    });
    final SrsCore core = SrsCore.open(p.join(dir.path, kSrsDatabaseFileName));
    addTearDown(core.close);
    final DatabaseConnection conn = srsDatabaseConnection(core);
    final SrsSplitExecutor executor = conn.executor as SrsSplitExecutor;
    final SrsDatabase db = SrsDatabase(conn);
    // 打开写那一路（与 app 一样经 Drift 打开），并确认查询道可用。
    expect(
      (await db.customSelect('SELECT 1 AS one').getSingle()).read<int>('one'),
      1,
    );

    // 一个吞掉全部微任务的 zone（FakeAsync 测试结束后 / runAsync 外不再冲刷的 fake zone 的形态）。
    final Zone dead = Zone.current.fork(
      specification: ZoneSpecification(
        scheduleMicrotask: (Zone self, ZoneDelegate parent, Zone zone, _) {},
      ),
    );
    for (int i = 0; i < 3; i++) {
      dead.run(() => unawaited(executor.runSelect(_kSlowQuery, <Object?>[])));
    }
    expect(executor.debugInFlight, 3);

    // close 在真实 zone 里调：等那三条在 worker 上跑完（计数在根 zone 里归零）后关写那一路，而不是永远挂着。
    // 这里的 timeout 只是把「挂起」变成失败的断言，不是修法的一部分。
    await db.close().timeout(const Duration(seconds: 60));
    expect(executor.debugInFlight, 0);
    // 关闭后再发的查询直接报已关闭，不进 worker。
    await expectLater(
      executor.runSelect('SELECT 1', <Object?>[]),
      throwsA(isA<StateError>()),
    );
    expect(executor.debugInFlight, 0);
  });

  test('没有在途查询时 close 立即关写那一路', () async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'srs_split_close_idle_',
    );
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 同上。
      }
    });
    final SrsCore core = SrsCore.open(p.join(dir.path, kSrsDatabaseFileName));
    addTearDown(core.close);
    final DatabaseConnection conn = srsDatabaseConnection(core);
    final SrsSplitExecutor executor = conn.executor as SrsSplitExecutor;
    final SrsDatabase db = SrsDatabase(conn);
    await db.customSelect('SELECT 1 AS one').get();
    expect(executor.debugInFlight, 0);
    await db.close().timeout(const Duration(seconds: 60));
  });
}
