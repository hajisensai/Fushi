import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/desktop_mihon_runtime.dart';

void main() {
  test('source image timeout is extended beyond the old fixed 45 seconds', () {
    expect(
      kMihonSourceImageHeaderTimeout,
      greaterThan(const Duration(seconds: 45)),
    );
    expect(
      kMihonSourceImageIdleTimeout,
      greaterThan(const Duration(seconds: 45)),
    );
  });

  test('each received image chunk refreshes the idle timeout', () async {
    // 虚拟时间驱动 Stream.timeout 的计时器：块间隔 400ms < 500ms 超时，但三段
    // 累计 1200ms 远超一个超时窗口——只有「每块重置计时」才能读完。真实
    // sleep 在 CI 并发负载下会被拉长到超过超时，所以这里不用真实时间。
    const Duration idleTimeout = Duration(milliseconds: 500);
    const Duration gap = Duration(milliseconds: 400);
    final FakeAsync fake = FakeAsync();
    final StreamController<List<int>> controller =
        StreamController<List<int>>();
    Uint8List? result;
    Object? error;
    fake.run((FakeAsync async) {
      readMihonSourceImageBytes(
        controller.stream,
        idleTimeout: idleTimeout,
      ).then(
        (Uint8List bytes) => result = bytes,
        onError: (Object e) {
          error = e;
        },
      );

      controller.add(<int>[1]);
      async.elapse(gap);
      controller.add(<int>[2]);
      async.elapse(gap);
      controller.add(<int>[3]);
      async.elapse(gap);
      expect(error, isNull);
      controller.close();
    });
    await _drainUntil(fake, () => result != null || error != null);

    expect(fake.elapsed, gap * 3);
    expect(error, isNull);
    expect(result, Uint8List.fromList(<int>[1, 2, 3]));
  });

  test(
    'a gap longer than the idle timeout fails even after earlier chunks',
    () async {
      const Duration idleTimeout = Duration(milliseconds: 500);
      final FakeAsync fake = FakeAsync();
      final StreamController<List<int>> controller =
          StreamController<List<int>>();
      addTearDown(controller.close);
      Object? error;
      fake.run((FakeAsync async) {
        readMihonSourceImageBytes(
          controller.stream,
          idleTimeout: idleTimeout,
        ).then(
          (_) {},
          onError: (Object e) {
            error = e;
          },
        );
        controller.add(<int>[1]);
        async.elapse(const Duration(milliseconds: 400));
        controller.add(<int>[2]);
        async.elapse(idleTimeout - const Duration(milliseconds: 1));
      });
      await _drainUntil(fake, () => error != null);
      expect(error, isNull, reason: '上一块之后还没满一个超时窗口');

      fake.run((FakeAsync async) {
        async.elapse(const Duration(milliseconds: 1));
      });
      await _drainUntil(fake, () => error != null);
      expect(error, isA<TimeoutException>());
    },
  );

  test(
    'source image still fails after a real interval without progress',
    () async {
      final StreamController<List<int>> controller =
          StreamController<List<int>>();
      addTearDown(controller.close);
      final Future<Uint8List> reading = readMihonSourceImageBytes(
        controller.stream,
        idleTimeout: const Duration(milliseconds: 80),
      );
      controller.add(<int>[1]);

      await expectLater(reading, throwsA(isA<TimeoutException>()));
    },
  );
}

/// 把 fake-async 下已经能进行的异步收尾全部跑完（不推进虚拟时间）。
///
/// [Stream.timeout] 取消上游订阅时拿到的是根 zone 的已完成 Future，`await for`
/// 退出时的 done / cancel 续体因此排进**真实**微任务队列，[FakeAsync.flushMicrotasks]
/// 冲不到；续体回到 fake zone 后又会排进 fake 队列。所以交替让出真实事件循环、
/// 冲 fake 队列，直到 [done] 成立；轮数上限只防死循环，与墙钟无关。
Future<void> _drainUntil(FakeAsync fake, bool Function() done) async {
  for (int round = 0; round < 10 && !done(); round++) {
    await pumpEventQueue();
    fake.flushMicrotasks();
  }
}
