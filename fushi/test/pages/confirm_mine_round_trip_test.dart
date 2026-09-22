// BUG-2634 第二轮守卫：「确认制卡」往返的竞态与超时策略。
//
// 这条链路两轮都栽在同一个地方——用**一个**信号同时管「解除超时」与「可以关窗」：
//   * 第一轮（BUG-2627 第二轮）等到整条制卡落地才关窗，45 秒盖住 ffmpeg + Anki，
//     超时报「查词弹窗已经关掉了」；
//   * 第二轮（本 PR 首版）把信号提前到「宿主接手」，可 `minedCardAction` 那条会弹
//     无限等用户的模态操作单、信号却放在 await 之后，原症状原样保留；而若放到 await
//     之前，阅读器（制卡经串行队列）又会在草稿被读走之前就关窗、让弹窗关栈清掉它。
//
// 真往返要 WebView2 + 真弹窗 + 真对话框，只有 -Visible 的 Windows runner 跑得动，
// 所以策略抽成 [ConfirmMineRoundTrip] 由这里驱动。超时取 60 ms、等待窗口取它的数倍，
// 整组测试几百毫秒跑完。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/confirm_mine_round_trip.dart';

void main() {
  // 真实超时是 45 s；这里只验判据，取值不影响语义。
  const Duration timeout = Duration(milliseconds: 60);
  // 「宿主在跑」期间的观察窗口：远大于 timeout，旧实现在这里早就误报了。
  const Duration wellPastTimeout = Duration(milliseconds: 400);

  ConfirmMineRoundTrip newTrip() =>
      ConfirmMineRoundTrip(preHostTimeout: timeout);

  /// 起一次往返并把结局记在返回的 holder 里（未结束时为 null）。
  ({Future<ConfirmMineOutcome> future, ConfirmMineOutcome? Function() peek})
  start(ConfirmMineRoundTrip trip, Future<bool> landed) {
    ConfirmMineOutcome? seen;
    final Future<ConfirmMineOutcome> future = trip.run(landed).then((
      ConfirmMineOutcome o,
    ) {
      seen = o;
      return o;
    });
    return (future: future, peek: () => seen);
  }

  test('桥半死不回：宿主一直没接手 → bridgeTimedOut，且与「没点到」分得开', () async {
    final ConfirmMineOutcome outcome = await newTrip().run(
      Completer<bool>().future,
    );
    expect(outcome, ConfirmMineOutcome.bridgeTimedOut);
    expect(outcome.clickedOrAccepted, isFalse);
    // 必须与 notClicked 分得开——BUG-2634 正是把「宿主慢」说成了「弹窗已经关掉了」。
    expect(outcome, isNot(ConfirmMineOutcome.notClicked));
  });

  test('popup.js 明确拒点 → notClicked，不等超时', () async {
    final Stopwatch sw = Stopwatch()..start();
    final ConfirmMineOutcome outcome = await newTrip().run(
      Future<bool>.value(false),
    );
    sw.stop();
    expect(outcome, ConfirmMineOutcome.notClicked);
    expect(outcome.clickedOrAccepted, isFalse);
    expect(sw.elapsed, lessThan(timeout), reason: '拒点是同步结论，不该等满超时');
  });

  test('宿主接手后**没有**上限：等人等再久也不许超时（minedCardAction 那条路）', () async {
    final Completer<bool> landed = Completer<bool>();
    final ConfirmMineRoundTrip trip = newTrip();
    final run = start(trip, landed.future);

    // 宿主接手 = 弹出「覆写 / 新增重复 / 取消」操作单，只解除超时、不关窗。
    trip.markHostEntered();
    await Future<void>.delayed(wellPastTimeout);
    expect(run.peek(), isNull, reason: '用户还在那张模态单里选，旧实现此刻已报假失败并把它 pop 掉了');

    landed.complete(true);
    expect(await run.future, ConfirmMineOutcome.clicked);
  });

  test('只解除超时不等于可以关窗：markHostEntered 单独不会提前返回', () async {
    final Completer<bool> landed = Completer<bool>();
    final ConfirmMineRoundTrip trip = newTrip();
    final run = start(trip, landed.future);

    trip.markHostEntered();
    await Future<void>.delayed(wellPastTimeout);
    expect(run.peek(), isNull, reason: '草稿还没被读走就关窗，弹窗关栈会把它清掉（阅读器串行队列那条路）');

    landed.complete(true);
    await run.future;
  });

  test('宿主读走草稿 → 提前关窗，不等 ffmpeg / Anki 落地', () async {
    final Completer<bool> landed = Completer<bool>();
    final ConfirmMineRoundTrip trip = newTrip();
    final run = start(trip, landed.future);

    trip.markPayloadConsumed();
    final ConfirmMineOutcome outcome = await run.future;

    expect(outcome, ConfirmMineOutcome.releasedEarly);
    expect(
      outcome.clickedOrAccepted,
      isTrue,
      reason: '提前关窗对调用方等同于「点到了」，制卡的成功/失败 toast 由宿主自己出',
    );
    expect(landed.isCompleted, isFalse, reason: '不等落地');
  });

  test('markPayloadConsumed 隐含解除超时；重复发信号是 no-op', () async {
    final ConfirmMineRoundTrip trip = newTrip();
    final run = start(trip, Completer<bool>().future);

    trip.markPayloadConsumed();
    trip.markPayloadConsumed();
    trip.markHostEntered();

    expect(await run.future, ConfirmMineOutcome.releasedEarly);
  });

  test('通道异常折成「没点到」，不漏成未捕获异步错误', () async {
    final ConfirmMineOutcome outcome = await newTrip().run(
      Future<bool>.error(StateError('MissingPluginException')),
    );
    expect(outcome, ConfirmMineOutcome.notClicked);
  });

  test('接手与落地几乎同时：以落地的真实结果为准，不被「接手」盖成成功', () async {
    final Completer<bool> landed = Completer<bool>();
    final ConfirmMineRoundTrip trip = newTrip();
    final run = start(trip, landed.future);

    trip.markHostEntered();
    landed.complete(false);

    expect(await run.future, ConfirmMineOutcome.notClicked);
  });

  test('落地先于宿主接手（宿主同步跑完）：以落地为准', () async {
    final ConfirmMineRoundTrip trip = newTrip();
    final Future<ConfirmMineOutcome> future = trip.run(
      Future<bool>.value(true),
    );
    trip.markPayloadConsumed();
    expect(await future, ConfirmMineOutcome.clicked);
  });
}
