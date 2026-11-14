import 'dart:async';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/live_transcode.dart';
import 'package:test/test.dart';

/// 转码闸门按 key 取消与存活判定（BUG：播放会话结束 / 换档换集后旧 token 的转码
/// 分段照样转完，占满转码名额拖慢新流起播）。闸门是进程全局状态，每条用例结束时
/// 都必须把名额排空、登记表清零，否则会串到下一条。
void main() {
  tearDown(() {
    setTranscodeSegmentRunnerForTesting(null);
    expect(liveTranscodeCount, 0, reason: '用例结束时名额必须排空');
    expect(pendingTranscodeWorkKeys, 0, reason: '用例结束时登记表必须清空');
  });

  /// 占满全部名额，返回放行用的 gate 与这些工作的 future。
  ({List<Completer<void>> gates, List<Future<void>> runs}) fillSlots() {
    final List<Completer<void>> gates = <Completer<void>>[];
    final List<Future<void>> runs = <Future<void>>[];
    for (int i = 0; i < kMaxConcurrentTranscodes; i++) {
      final Completer<void> gate = Completer<void>();
      gates.add(gate);
      runs.add(runGuardedTranscodeForTesting<void>(() => gate.future));
    }
    return (gates: gates, runs: runs);
  }

  Future<void> drain(
    ({List<Completer<void>> gates, List<Future<void>> runs}) held,
  ) async {
    for (final Completer<void> gate in held.gates) {
      gate.complete();
    }
    await Future.wait(held.runs);
  }

  test('排队者被取消：立即以 TranscodeCancelled 离队，不占名额、不交棒', () async {
    final held = fillSlots();
    await Future<void>.delayed(Duration.zero);
    expect(liveTranscodeCount, kMaxConcurrentTranscodes);

    bool bodyRan = false;
    final Future<void> queued = runGuardedTranscodeForTesting<void>(
      () async => bodyRan = true,
      workKey: 'k',
    );
    await Future<void>.delayed(Duration.zero);
    expect(pendingTranscodeWorkKeys, 1, reason: '排队中的工作已按 key 登记');

    cancelTranscodeWork('k');
    await expectLater(queued, throwsA(isA<TranscodeCancelled>()));
    expect(bodyRan, isFalse);
    expect(liveTranscodeCount, kMaxConcurrentTranscodes);
    expect(pendingTranscodeWorkKeys, 0);

    await drain(held);
    expect(liveTranscodeCount, 0, reason: '被取消的排队者不能吃掉交棒的名额');
  });

  test('已作废才到：isAlive 为 false 立即放弃，不占名额', () async {
    bool bodyRan = false;
    await expectLater(
      runGuardedTranscodeForTesting<void>(
        () async => bodyRan = true,
        workKey: 'dead',
        isAlive: () => false,
      ),
      throwsA(isA<TranscodeCancelled>()),
    );
    expect(bodyRan, isFalse);
    expect(liveTranscodeCount, 0);
    expect(pendingTranscodeWorkKeys, 0);
  });

  test('排队中作废：拿到名额后再判一次存活，放弃并立刻交还名额', () async {
    final held = fillSlots();
    await Future<void>.delayed(Duration.zero);

    bool alive = true;
    bool bodyRan = false;
    final Future<void> queued = runGuardedTranscodeForTesting<void>(
      () async => bodyRan = true,
      workKey: 'k',
      isAlive: () => alive,
    );
    await Future<void>.delayed(Duration.zero);
    alive = false;

    // 放行一个名额：交棒给排队者，排队者判出作废后必须把名额交还。
    held.gates.first.complete();
    await expectLater(queued, throwsA(isA<TranscodeCancelled>()));
    expect(bodyRan, isFalse);
    await held.runs.first;
    expect(
      liveTranscodeCount,
      kMaxConcurrentTranscodes - 1,
      reason: '作废的排队者交还了名额，没有占着',
    );

    for (final Completer<void> gate in held.gates.skip(1)) {
      gate.complete();
    }
    await Future.wait(held.runs);
  });

  test('取消在跑的分段：结果是 TranscodeCancelled，runner 只被调一次（不触发回退重跑）', () async {
    int calls = 0;
    final Completer<void> runnerGate = Completer<void>();
    final Completer<void> entered = Completer<void>();
    setTranscodeSegmentRunnerForTesting((List<String> args) async {
      calls++;
      if (!entered.isCompleted) entered.complete();
      await runnerGate.future;
      return Uint8List(0);
    });

    final Future<Object?> segment = transcodeSegment(
      inputPath: '/v.mkv',
      profile: const VideoTranscodeProfile(maxWidth: 1280, maxBitrate: 3000000),
      index: 0,
      durationMs: 60000,
      workKey: 'tok',
      isAlive: () => true,
    );
    // 蓝光输入改写在调 runner 前有若干 await，等 runner 真正进入再取消。
    await entered.future.timeout(const Duration(seconds: 5));
    expect(calls, 1);
    expect(pendingTranscodeWorkKeys, 1);

    cancelTranscodeWork('tok');
    await expectLater(segment, throwsA(isA<TranscodeCancelled>()));
    runnerGate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1, reason: '被取消的分段不得再起一次');
    expect(pendingTranscodeWorkKeys, 0);
  });

  test('取消只作用于该 key：别的 key 与不带 key 的工作照常完成', () async {
    final Completer<void> gateA = Completer<void>();
    final Completer<void> gateB = Completer<void>();
    final Future<void> a = runGuardedTranscodeForTesting<void>(
      () => gateA.future,
      workKey: 'a',
    );
    final Future<void> b = runGuardedTranscodeForTesting<void>(
      () => gateB.future,
      workKey: 'b',
    );
    await Future<void>.delayed(Duration.zero);
    cancelTranscodeWork('a');
    await expectLater(a, throwsA(isA<TranscodeCancelled>()));
    gateA.complete();
    gateB.complete();
    await b;
    // 对当前没有工作的 key 取消是空操作，不留记录。
    cancelTranscodeWork('nobody');
    expect(pendingTranscodeWorkKeys, 0);
    // 取消过的 key 再来新工作，不被旧的取消误伤。
    await runGuardedTranscodeForTesting<void>(() async {}, workKey: 'a');
  });
}
