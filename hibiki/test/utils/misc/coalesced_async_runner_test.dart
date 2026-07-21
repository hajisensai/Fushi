import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/coalesced_async_runner.dart';

void main() {
  group('CoalescedAsyncRunner (BUG-969)', () {
    test('空闲触发立即跑一趟', () async {
      int runs = 0;
      final CoalescedAsyncRunner runner =
          CoalescedAsyncRunner(() async => runs++);
      await runner.trigger();
      expect(runs, 1);
    });

    test('在飞期间的 N 次触发只合并成一趟补跑', () async {
      int runs = 0;
      final Completer<void> gate = Completer<void>();
      bool first = true;
      final CoalescedAsyncRunner runner = CoalescedAsyncRunner(() async {
        runs++;
        if (first) {
          first = false;
          await gate.future; // 第一趟挂起，模拟慢 WebView 往返。
        }
      });
      final Future<void> inFlight = runner.trigger();
      expect(runner.isRunning, isTrue);
      // 拖动风暴：在飞期间连触发 10 次。
      for (int i = 0; i < 10; i++) {
        unawaited(runner.trigger());
      }
      gate.complete();
      await inFlight;
      // 第一趟 + 合并后的一趟补跑，绝不是 11 趟。
      expect(runs, 2);
      expect(runner.isRunning, isFalse);
    });

    test('补跑期间再触发会继续补跑（最终状态不丢）', () async {
      final List<Completer<void>> gates = <Completer<void>>[];
      int runs = 0;
      late CoalescedAsyncRunner runner;
      runner = CoalescedAsyncRunner(() async {
        runs++;
        final Completer<void> gate = Completer<void>();
        gates.add(gate);
        await gate.future;
      });
      final Future<void> chain = runner.trigger();
      unawaited(runner.trigger()); // 置脏 → 会有第二趟。
      gates[0].complete();
      // 等第二趟真正启动后，在第二趟在飞期间再触发 → 第三趟。
      await Future<void>.delayed(Duration.zero);
      expect(runs, 2);
      unawaited(runner.trigger());
      gates[1].complete();
      await Future<void>.delayed(Duration.zero);
      expect(runs, 3);
      gates[2].complete();
      await chain;
      expect(runner.isRunning, isFalse);
    });

    test('动作抛异常后不卡死，后续触发仍可跑', () async {
      int runs = 0;
      final CoalescedAsyncRunner runner = CoalescedAsyncRunner(() async {
        runs++;
        if (runs == 1) throw StateError('boom');
      });
      await expectLater(runner.trigger(), throwsStateError);
      expect(runner.isRunning, isFalse);
      await runner.trigger();
      expect(runs, 2);
    });
  });
}
