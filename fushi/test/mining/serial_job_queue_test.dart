import 'dart:async';

import 'package:test/test.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart'
    show resolveImmersionExtractionConcurrency;
import 'package:fushi/src/mining/serial_job_queue.dart';

/// BUG-956 守卫：串行队列在任意任务/错误处理路径抛异常后都不得毒化，后续任务照常完成。
void main() {
  test('正常任务按入队顺序串行执行，各自返回结果', () async {
    final SerialJobQueue queue = SerialJobQueue();
    final List<int> order = <int>[];
    final Future<String> a = queue.enqueue<String>(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      order.add(1);
      return 'a';
    }, buildFailure: (_, __) => 'fail');
    final Future<String> b = queue.enqueue<String>(() async {
      order.add(2);
      return 'b';
    }, buildFailure: (_, __) => 'fail');
    expect(await a, 'a');
    expect(await b, 'b');
    expect(order, <int>[1, 2], reason: '必须严格串行，b 等 a 完成后才跑');
  });

  test('任务抛异常 → 返回降级结果，且不阻塞后续任务', () async {
    final SerialJobQueue queue = SerialJobQueue();
    final String r1 = await queue.enqueue<String>(
      () async => throw StateError('job boom'),
      buildFailure: (Object e, StackTrace s) => 'failed',
    );
    expect(r1, 'failed', reason: '任务抛异常应完成为降级结果，不得挂起');

    final String r2 = await queue.enqueue<String>(
      () async => 'ok',
      buildFailure: (_, __) => 'x',
    );
    expect(r2, 'ok', reason: '前一个任务抛异常不得毒化队列');
  });

  test('任务抛 + onError 副作用自身也抛 → 仍不毒化队列（BUG-956 核心）', () async {
    final SerialJobQueue queue = SerialJobQueue();
    // 这正是 PR#295 原代码会永久挂死的场景：错误处理路径（日志/事件记录）自身抛异常，
    // 旧写法下 _tail 变 rejected，后续所有制卡的 .then 永不触发。
    final String r1 = await queue
        .enqueue<String>(
          () async => throw StateError('job boom'),
          buildFailure: (Object e, StackTrace s) => 'failed',
          onError: (Object e, StackTrace s) =>
              throw StateError('handler boom too'),
        )
        .timeout(const Duration(seconds: 2), onTimeout: () => 'TIMEOUT-挂起了');
    expect(r1, 'failed', reason: 'onError 自身抛也应被吞，completer 仍以降级结果完成');

    final String r2 = await queue
        .enqueue<String>(() async => 'recovered', buildFailure: (_, __) => 'x')
        .timeout(const Duration(seconds: 2), onTimeout: () => 'TIMEOUT-队列被毒化');
    expect(r2, 'recovered', reason: '错误处理器抛异常后，后续任务仍必须执行（队列未毒化）');
  });

  test('buildFailure 自身也抛 → 退化为 completeError，仍不挂起、不毒化', () async {
    final SerialJobQueue queue = SerialJobQueue();
    Object? caught;
    await queue
        .enqueue<String>(
          () async => throw StateError('job boom'),
          buildFailure: (Object e, StackTrace s) =>
              throw StateError('build boom'),
        )
        .catchError((Object e) {
          caught = e;
          return 'caught';
        })
        .timeout(const Duration(seconds: 2), onTimeout: () => 'TIMEOUT');
    expect(
      caught,
      isA<StateError>(),
      reason: 'buildFailure 抛时把原始错误抛给调用方，而非永久挂起',
    );

    final String r2 = await queue
        .enqueue<String>(() async => 'still-ok', buildFailure: (_, __) => 'x')
        .timeout(const Duration(seconds: 2), onTimeout: () => 'TIMEOUT-毒化');
    expect(r2, 'still-ok');
  });

  test('enqueueRethrowing 保留原始异常且后续任务继续', () async {
    final SerialJobQueue queue = SerialJobQueue();

    await expectLater(
      queue.enqueueRethrowing<String>(
        () async => throw StateError('original failure'),
      ),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          'original failure',
        ),
      ),
    );

    expect(await queue.enqueueRethrowing<String>(() async => 'next'), 'next');
  });

  group('BoundedJobLimiter（video-30 抽取并发闸）', () {
    test('同时最多 maxConcurrent 个在跑，多出来的按调用顺序接替', () async {
      final BoundedJobLimiter limiter = BoundedJobLimiter(2);
      final List<Completer<void>> gates = List<Completer<void>>.generate(
        4,
        (_) => Completer<void>(),
      );
      final List<int> started = <int>[];
      final List<Future<int>> results = <Future<int>>[
        for (int i = 0; i < 4; i++)
          limiter.run<int>(() async {
            started.add(i);
            await gates[i].future;
            return i;
          }),
      ];
      await pumpEventQueue();
      expect(started, <int>[0, 1]);
      expect(limiter.running, 2);
      expect(limiter.waiting, 2);

      // 第二个先结束：名额交给排在最前的 2，而不是 3。
      gates[1].complete();
      await pumpEventQueue();
      expect(started, <int>[0, 1, 2]);
      expect(limiter.running, 2);

      gates[0].complete();
      await pumpEventQueue();
      expect(started, <int>[0, 1, 2, 3]);

      gates[2].complete();
      gates[3].complete();
      expect(await Future.wait(results), <int>[0, 1, 2, 3]);
      expect(limiter.running, 0);
      expect(limiter.waiting, 0);
    });

    test('任务抛错原样交还调用方，名额照样归还', () async {
      final BoundedJobLimiter limiter = BoundedJobLimiter(1);
      await expectLater(
        limiter.run<void>(() async => throw StateError('extract boom')),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        limiter.run<void>(() => throw StateError('sync boom')),
        throwsA(isA<StateError>()),
      );
      expect(limiter.running, 0);
      expect(await limiter.run<String>(() async => 'next'), 'next');
    });

    test('动态上限：调小不打断在跑的、调大立刻放行排队的', () async {
      int limit = 2;
      final BoundedJobLimiter limiter = BoundedJobLimiter.dynamic(() => limit);
      final List<Completer<void>> gates = List<Completer<void>>.generate(
        5,
        (_) => Completer<void>(),
      );
      final List<int> started = <int>[];
      final List<Future<int>> results = <Future<int>>[
        for (int i = 0; i < 5; i++)
          limiter.run<int>(() async {
            started.add(i);
            await gates[i].future;
            return i;
          }),
      ];
      await pumpEventQueue();
      expect(started, <int>[0, 1]);

      // 调到 1：0 结束后在跑数 1 = 上限，不再转交。
      limit = 1;
      gates[0].complete();
      await pumpEventQueue();
      expect(started, <int>[0, 1]);
      expect(limiter.running, 1);

      // 1 结束：在跑 0 < 1，放行 2。
      gates[1].complete();
      await pumpEventQueue();
      expect(started, <int>[0, 1, 2]);

      // 调到 3：2 结束时一次放行 3、4 两个。
      limit = 3;
      gates[2].complete();
      await pumpEventQueue();
      expect(started, <int>[0, 1, 2, 3, 4]);
      expect(limiter.running, 2);

      gates[3].complete();
      gates[4].complete();
      expect(await Future.wait(results), <int>[0, 1, 2, 3, 4]);
      expect(limiter.running, 0);
      expect(limiter.waiting, 0);
    });

    test('上限 < 1 按 1 算', () async {
      final BoundedJobLimiter limiter = BoundedJobLimiter.dynamic(() => 0);
      expect(limiter.maxConcurrent, 1);
      expect(await limiter.run<int>(() async => 7), 7);
    });
  });

  group('resolveImmersionExtractionConcurrency（抽取并发按设备）', () {
    test('低内存模式恒 1', () {
      expect(
        resolveImmersionExtractionConcurrency(
          isMobile: false,
          lowMemoryMode: true,
          processors: 32,
        ),
        1,
      );
    });

    test('移动端：8 核及以上 2，其余 1', () {
      expect(
        resolveImmersionExtractionConcurrency(
          isMobile: true,
          lowMemoryMode: false,
          processors: 8,
        ),
        2,
      );
      expect(
        resolveImmersionExtractionConcurrency(
          isMobile: true,
          lowMemoryMode: false,
          processors: 6,
        ),
        1,
      );
    });

    test('桌面：12 核及以上 3，其余 2', () {
      expect(
        resolveImmersionExtractionConcurrency(
          isMobile: false,
          lowMemoryMode: false,
          processors: 16,
        ),
        3,
      );
      expect(
        resolveImmersionExtractionConcurrency(
          isMobile: false,
          lowMemoryMode: false,
          processors: 4,
        ),
        2,
      );
    });
  });
}
