// 内核命令 isolate 池：调用方的 zone 不再跑微任务时（widget 测试结束后的 FakeAsync、页面 dispose 时发后不理
// 的关闭命令）worker 也照常归还，池子不会耗尽。
import 'dart:async';
import 'dart:io' show sleep;

import 'package:fushi_engine/srs/srs_core_workers.dart';
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsDbStore;
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsCore;
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

int _ping(SrsCore core) => 7;

int _boom(SrsCore core) => throw StateError('boom');

void main() {
  test('调用方 zone 不跑微任务：命令照常执行、worker 照常归还', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final int address = storage.core.address;
    final SrsCoreWorkers pool = SrsCoreWorkers.of(storage.core.libraryPath);
    expect(await pool.run(address, _ping), 7);

    // 一个吞掉全部微任务的 zone：在里面发出的命令，调用方永远等不到结果。
    final Zone dead = Zone.current.fork(
      specification: ZoneSpecification(
        scheduleMicrotask: (Zone self, ZoneDelegate parent, Zone zone, _) {},
      ),
    );
    for (int i = 0; i < SrsCoreWorkers.maxWorkers * 2; i++) {
      dead.run(() => unawaited(pool.run(address, _ping)));
    }

    // 池子没被占满：后面的命令都能拿到 worker。
    final List<int> after = await Future.wait(<Future<int>>[
      for (int i = 0; i < SrsCoreWorkers.maxWorkers + 1; i++)
        pool.run(address, _ping),
    ]).timeout(const Duration(seconds: 20));
    expect(after, everyElement(7));

    // 命令报错照常交回调用方（在调用方自己的 error zone 里，不变成根 zone 的未捕获错误）。
    await expectLater(pool.run(address, _boom), throwsA(isA<StateError>()));
    expect(await pool.run(address, _ping), 7);
  });

  // 集成审查【中】：以前单一 FIFO 池（上限 4），同步时成批的媒体文件加解密（6 路并发）把 worker 占满，复习页的
  // 作答 / 排队 / 预览排在几 MB 文件后面。现在分道：默认道与文件道都被慢命令占满时，交互道照样立刻执行。
  test('默认道 / 文件道被慢命令占满：交互命令仍立刻执行', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final int address = storage.core.address;
    final SrsCoreWorkers pool = SrsCoreWorkers.debugFresh(
      storage.core.libraryPath,
    );
    int slowDone = 0;
    final List<Future<int>> slow = <Future<int>>[
      for (final SrsCoreLane lane in <SrsCoreLane>[
        SrsCoreLane.bulk,
        SrsCoreLane.file,
      ])
        for (int i = 0; i < SrsCoreWorkers.maxWorkersOf(lane) * 2; i++)
          pool.run(address, _slow, lane: lane).then((int v) {
            slowDone++;
            return v;
          }),
    ];
    final Stopwatch sw = Stopwatch()..start();
    expect(await pool.run(address, _ping, lane: SrsCoreLane.interactive), 7);
    expect(
      slowDone,
      0,
      reason: 'the interactive command did not queue behind the slow ones',
    );
    expect(sw.elapsed, lessThan(const Duration(milliseconds: 1500)));
    expect(await Future.wait(slow), everyElement(1));
    // 分类：复习页的三条命令走交互道，媒体文件命令走文件道。
    for (final String op in <String>['apply', 'study', 'preview']) {
      expect(SrsDbStore.srsCoreLaneOf(op), SrsCoreLane.interactive);
    }
    for (final String op in <String>['seal_file', 'open_file', 'media_hash']) {
      expect(SrsDbStore.srsCoreLaneOf(op), SrsCoreLane.file);
    }
    expect(SrsDbStore.srsCoreLaneOf('ingest_commit'), SrsCoreLane.bulk);
  });

  // 集成审查【低】：起 worker 失败时以前只 `_live--`，排着的命令再也没人发，全部失败时永远挂着。
  test('起 worker 全部失败：排队的命令逐条报错，不挂住；恢复后照常执行', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final int address = storage.core.address;
    final SrsCoreWorkers pool = SrsCoreWorkers.debugFresh(
      storage.core.libraryPath,
    )..debugFailSpawns = true;
    final List<Future<Object?>> runs = <Future<Object?>>[
      for (int i = 0; i < SrsCoreWorkers.maxWorkers * 3; i++)
        pool
            .run(address, _ping)
            .then<Object?>((int v) => v, onError: (Object e) => e),
    ];
    final List<Object?> results = await Future.wait(
      runs,
    ).timeout(const Duration(seconds: 10));
    expect(results, everyElement(isA<StateError>()));
    pool.debugFailSpawns = false;
    expect(await pool.run(address, _ping), 7);
  });

  // 集成审查【低】：worker 按句柄地址缓存的 SrsCore 包装以前从不清理（换 profile / 覆盖恢复反复开关库就越攒越多）。
  test('句柄关闭后 forget：worker 丢掉它的包装', () async {
    final SrsStorage a = await openTestSrsStorage();
    final SrsStorage b = await openTestSrsStorage();
    final SrsCoreWorkers pool = SrsCoreWorkers.debugFresh(a.core.libraryPath);
    // 顺序执行：只起一个 worker，两个句柄都包在它里面。
    expect(await pool.run(a.core.address, _ping), 7);
    expect(await pool.run(b.core.address, srsCoreWorkerCachedCores), 2);
    pool.forget(a.core.address);
    expect(await pool.run(b.core.address, srsCoreWorkerCachedCores), 1);
    expect(pool.debugSpawned, 1);
  });

  // BUG-3961：查询道的 worker 上限从打开的库上读（内核只读连接池的上限），不另写常量；一阵并发查询之后多起的
  // worker 空闲满保留时长就收掉，至少留一个。
  test('查询道：上限取库的读并发上限，空闲多起的 worker 回收到一个', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final int address = storage.core.address;
    final int cap = storage.core.readConcurrency;
    expect(cap, greaterThanOrEqualTo(2));
    final SrsCoreWorkers pool = SrsCoreWorkers.debugFresh(
      storage.core.libraryPath,
      queryIdleTtl: const Duration(milliseconds: 300),
    );
    expect(
      pool.debugMax(SrsCoreLane.query),
      1,
      reason: 'before the limit is read',
    );
    pool.setQueryConcurrency(cap);
    expect(pool.debugMax(SrsCoreLane.query), cap);
    // 比上限多发一倍：活着的 worker 不超过上限，全部做完。
    final List<Future<int>> burst = <Future<int>>[
      for (int i = 0; i < cap * 2; i++)
        pool.run(address, _slowShort, lane: SrsCoreLane.query),
    ];
    // 提交即按需起到上限（多出的排队），不会多起。
    expect(pool.debugLive(SrsCoreLane.query), cap);
    expect(await Future.wait(burst), everyElement(1));
    expect(pool.debugLive(SrsCoreLane.query), cap);
    // 空闲满 300 ms：回收到一个（等定时器，最多 5 秒）。
    final Stopwatch sw = Stopwatch()..start();
    while (pool.debugLive(SrsCoreLane.query) > 1 &&
        sw.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(pool.debugLive(SrsCoreLane.query), 1);
    // 留下的那个照常执行，不必重起。
    final int spawned = pool.debugSpawned;
    expect(await pool.run(address, _ping, lane: SrsCoreLane.query), 7);
    expect(pool.debugSpawned, spawned);
    // 再来一阵并发：按需重新起到上限。
    expect(
      await Future.wait(<Future<int>>[
        for (int i = 0; i < cap; i++)
          pool.run(address, _slowShort, lane: SrsCoreLane.query),
      ]),
      everyElement(1),
    );
    expect(pool.debugLive(SrsCoreLane.query), cap);
  });
}

int _slowShort(SrsCore core) {
  sleep(const Duration(milliseconds: 400));
  return 1;
}

int _slow(SrsCore core) {
  sleep(const Duration(seconds: 2));
  return 1;
}
