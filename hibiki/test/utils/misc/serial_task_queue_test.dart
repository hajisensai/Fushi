import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/serial_task_queue.dart';

void main() {
  group('SerialTaskQueue', () {
    test('serializes tasks: second starts only after first completes',
        () async {
      final SerialTaskQueue queue = SerialTaskQueue();
      final List<String> events = <String>[];
      final Completer<void> firstGate = Completer<void>();

      // 第一个任务悬挂在 firstGate 上（模拟 extractAudioSegment 的 await）。
      final Future<String> first = queue.enqueue<String>(() async {
        events.add('first:start');
        await firstGate.future;
        events.add('first:end');
        return 'first';
      });

      // 第二个任务紧接着入队（模拟快速连制第二张卡）。
      final Future<String> second = queue.enqueue<String>(() async {
        events.add('second:start');
        return 'second';
      });

      // 让微任务跑一圈：此时第一个已 start 但被 gate 挡住，第二个绝不能已 start。
      await Future<void>.delayed(Duration.zero);
      expect(events, <String>['first:start'], reason: '第二个任务在第一个完成前不得启动（串行化）。');

      // 放行第一个 → 第二个才被调度。
      firstGate.complete();
      expect(await first, 'first');
      expect(await second, 'second');
      expect(events, <String>['first:start', 'first:end', 'second:start']);
    });

    test('each task observes its own captured value (no interleave)', () async {
      final SerialTaskQueue queue = SerialTaskQueue();
      final Completer<void> firstStarted = Completer<void>();
      final Completer<void> firstGate = Completer<void>();

      // 共享可变状态：模拟 currentCueSentence / _cachedSentenceOffset。
      String shared = 'word-1';

      // 第一张卡：任务真正开始时在第一个 await 之前快照共享值成局部，这正是
      // _prepareMiningContext 在 extractAudioSegment await 之前快照的等价物。
      final Future<String> first = queue.enqueue<String>(() async {
        final String snapshot = shared; // await 前快照
        firstStarted.complete();
        await firstGate.future; // 模拟 extractAudioSegment 悬挂
        return snapshot; // await 后只用快照
      });

      // 等第一张卡真正启动并完成快照后，才模拟「悬挂期间第二次查词改写共享状态」。
      await firstStarted.future;
      shared = 'word-2';

      final Future<String> second = queue.enqueue<String>(() async {
        return shared;
      });

      firstGate.complete();
      // 第一张卡仍拿到 word-1（快照），第二张拿到 word-2 —— 两张都正确，不交错。
      expect(await first, 'word-1');
      expect(await second, 'word-2');
    });

    test('a failing task does not block subsequent tasks', () async {
      final SerialTaskQueue queue = SerialTaskQueue();
      final List<String> ran = <String>[];

      final Future<void> failing = queue.enqueue<void>(() async {
        ran.add('failing');
        throw StateError('boom');
      });

      final Future<String> next = queue.enqueue<String>(() async {
        ran.add('next');
        return 'ok';
      });

      // 失败任务的 future 仍 rethrow 给调用方（各自记日志/弹 toast）。
      await expectLater(failing, throwsStateError);
      // 队列尾不被前一次异常卡死。
      expect(await next, 'ok');
      expect(ran, <String>['failing', 'next']);
    });

    test('reproduces the race when work is NOT serialized (control)', () async {
      // 对照组：不经队列时两任务交错——证明本测试确实在检验串行语义。
      final List<String> events = <String>[];
      final Completer<void> firstGate = Completer<void>();

      final Future<void> first = () async {
        events.add('first:start');
        await firstGate.future;
        events.add('first:end');
      }();

      final Future<void> second = () async {
        events.add('second:start');
      }();

      await Future<void>.delayed(Duration.zero);
      // 未串行化时第二个在第一个悬挂期间（first:end 尚未发生）就已 start（交错）。
      expect(events, contains('second:start'));
      expect(events, isNot(contains('first:end')),
          reason: '此刻第一个仍悬挂在 gate 上，尚未结束。');

      firstGate.complete();
      await first;
      await second;
      // 收尾确认交错：second:start 排在 first:end 之前。
      expect(
          events.indexOf('second:start') < events.indexOf('first:end'), isTrue,
          reason: '未串行化 → 第二个任务在第一个结束前就跑（race）。');
    });
  });
}
