// 内核命令 isolate 池：调用方的 zone 不再跑微任务时（widget 测试结束后的 FakeAsync、页面 dispose 时发后不理
// 的关闭命令）worker 也照常归还，池子不会耗尽。
import 'dart:async';

import 'package:fushi_engine/srs/srs_core_workers.dart';
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
}
