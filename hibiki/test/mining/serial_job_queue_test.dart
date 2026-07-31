import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/serial_job_queue.dart';

/// BUG-956 守卫：串行队列在任意任务/错误处理路径抛异常后都不得毒化，后续任务照常完成。
void main() {
  test('正常任务按入队顺序串行执行，各自返回结果', () async {
    final SerialJobQueue queue = SerialJobQueue();
    final List<int> order = <int>[];
    final Future<String> a = queue.enqueue<String>(
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        order.add(1);
        return 'a';
      },
      buildFailure: (_, __) => 'fail',
    );
    final Future<String> b = queue.enqueue<String>(
      () async {
        order.add(2);
        return 'b';
      },
      buildFailure: (_, __) => 'fail',
    );
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
        .timeout(
          const Duration(seconds: 2),
          onTimeout: () => 'TIMEOUT-挂起了',
        );
    expect(r1, 'failed', reason: 'onError 自身抛也应被吞，completer 仍以降级结果完成');

    final String r2 = await queue
        .enqueue<String>(
          () async => 'recovered',
          buildFailure: (_, __) => 'x',
        )
        .timeout(
          const Duration(seconds: 2),
          onTimeout: () => 'TIMEOUT-队列被毒化',
        );
    expect(r2, 'recovered', reason: '错误处理器抛异常后，后续任务仍必须执行（队列未毒化）');
  });

  test('buildFailure 自身也抛 → 退化为 completeError，仍不挂起、不毒化', () async {
    final SerialJobQueue queue = SerialJobQueue();
    Object? caught;
    await queue
        .enqueue<String>(
      () async => throw StateError('job boom'),
      buildFailure: (Object e, StackTrace s) => throw StateError('build boom'),
    )
        .catchError((Object e) {
      caught = e;
      return 'caught';
    }).timeout(
      const Duration(seconds: 2),
      onTimeout: () => 'TIMEOUT',
    );
    expect(caught, isA<StateError>(),
        reason: 'buildFailure 抛时把原始错误抛给调用方，而非永久挂起');

    final String r2 = await queue
        .enqueue<String>(
          () async => 'still-ok',
          buildFailure: (_, __) => 'x',
        )
        .timeout(
          const Duration(seconds: 2),
          onTimeout: () => 'TIMEOUT-毒化',
        );
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

    expect(
      await queue.enqueueRethrowing<String>(() async => 'next'),
      'next',
    );
  });
}
