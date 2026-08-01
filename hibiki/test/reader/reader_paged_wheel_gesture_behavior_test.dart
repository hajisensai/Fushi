import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

const Duration _kSettle = Duration(milliseconds: 450);

/// 复刻 `onWheelPaginate` handler（webview.part.dart）的真实判定顺序：
///   ① 横向 tick 先过 [ReaderWheelGestureGate]；闸门判「属于已认领手势」→ 早退。
///   ② 放行的 tick 进 `_paginate`；`_paginationInFlight` 为真时被直接丢弃
///      （chrome.part.dart 的入口守卫），不产生任何用户可见反馈。
/// 返回这一段惯性最终让用户看到的翻页次数。
int _burstPageTurns({
  required ReaderWheelGestureGate gate,
  required int totalMs,
  required int tickIntervalMs,
  required bool Function(int elapsedMs) paginationInFlight,
}) {
  final DateTime start = DateTime(2026, 8, 2);
  int pageTurns = 0;
  for (int elapsed = 0; elapsed <= totalMs; elapsed += tickIntervalMs) {
    final DateTime now = start.add(Duration(milliseconds: elapsed));
    final bool inFlight = paginationInFlight(elapsed);
    if (!gate.shouldStartNewGesture(
      now: now,
      settleInterval: _kSettle,
      canTurnPage: !inFlight,
    )) {
      continue;
    }
    // _paginate 入口：换章加载 / restore 在飞 → 丢弃，用户看不到任何翻页。
    if (inFlight) continue;
    pageTurns += 1;
  }
  return pageTurns;
}

/// BUG-1342：macOS 横向触控板滑动会被拆成持续一秒以上的 wheel 惯性流。
/// 手势闸门必须活在跨章节持久的 reader Dart State，而不是随 WebView document 重建；
/// 因此这里真执行生产闸门，模拟惯性跨过一次章节导航后仍只放行一页。
///
/// BUG-1380：闸门的 token 消费不得早于「这一 tick 真能翻页」的确认。
void main() {
  test('1.5s horizontal momentum burst starts exactly one gesture', () {
    final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
    // The same gate object intentionally survives the simulated chapter
    // navigation halfway through the burst; a JS-document-local gate would
    // reset here and incorrectly accept a second page turn.
    expect(
      _burstPageTurns(
        gate: gate,
        totalMs: 1500,
        tickIntervalMs: 60,
        paginationInFlight: (_) => false,
      ),
      1,
    );
  });

  test('only a full quiet interval unlocks the next horizontal gesture', () {
    final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
    final DateTime first = DateTime(2026, 8, 1);
    expect(
      gate.shouldStartNewGesture(
        now: first,
        settleInterval: _kSettle,
        canTurnPage: true,
      ),
      isTrue,
    );
    expect(
      gate.shouldStartNewGesture(
        now: first.add(const Duration(milliseconds: 449)),
        settleInterval: _kSettle,
        canTurnPage: true,
      ),
      isFalse,
    );
    expect(
      gate.shouldStartNewGesture(
        now: first.add(const Duration(milliseconds: 899)),
        settleInterval: _kSettle,
        canTurnPage: true,
      ),
      isTrue,
    );
  });

  // ── BUG-1380 ───────────────────────────────────────────────────────
  // 换章加载（_paginationInFlight）覆盖惯性流的开头几百毫秒：首个 tick 落不了地。
  // 旧实现无条件写 _lastTickAt，token 被这个翻不动的 tick 吃掉 ⇒ 加载落定后的所有
  // 后续 tick 都在闸门早退 ⇒ 用户这一次滑动**完全没有反馈**。
  test('burst that opens during chapter loading still turns exactly one page',
      () {
    final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
    final int pageTurns = _burstPageTurns(
      gate: gate,
      totalMs: 1500,
      tickIntervalMs: 60,
      // 前 300ms 换章加载在飞，之后落定。
      paginationInFlight: (int elapsedMs) => elapsedMs <= 300,
    );
    expect(pageTurns, isNonZero,
        reason: '换章加载期消费掉的 token 会吞掉整段惯性 → 用户零反馈（BUG-1380 根因）');
    expect(pageTurns, 1, reason: '恢复后只放行一页，不得因补翻而连翻');
  });

  test('a whole burst swallowed by an in-flight navigation leaves no token',
      () {
    final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
    // 整段惯性都撞在换章加载里：一次翻页都不产生。
    expect(
      _burstPageTurns(
        gate: gate,
        totalMs: 600,
        tickIntervalMs: 60,
        paginationInFlight: (_) => true,
      ),
      0,
    );
    // 闸门必须仍是「未认领」状态——紧接着（远小于 settleInterval）到来的第一个可
    // 落地 tick 就该翻页，而不是等一个完整静默窗。
    expect(
      gate.shouldStartNewGesture(
        now: DateTime(2026, 8, 2).add(const Duration(milliseconds: 660)),
        settleInterval: _kSettle,
        canTurnPage: true,
      ),
      isTrue,
    );
  });

  test('ticks inside an already-claimed gesture keep sliding the trailing edge',
      () {
    final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
    final DateTime start = DateTime(2026, 8, 2);
    // 认领手势。
    expect(
      gate.shouldStartNewGesture(
        now: start,
        settleInterval: _kSettle,
        canTurnPage: true,
      ),
      isTrue,
    );
    // 手势内的 tick 即使 canTurnPage=false（换章加载在飞）也必须续 trailing edge，
    // 否则同一段惯性会在加载落定后再翻一页（BUG-1342 的原始症状）。
    for (int elapsed = 300; elapsed <= 1200; elapsed += 300) {
      expect(
        gate.shouldStartNewGesture(
          now: start.add(Duration(milliseconds: elapsed)),
          settleInterval: _kSettle,
          canTurnPage: false,
        ),
        isFalse,
        reason: '$elapsed ms 处仍属同一手势',
      );
    }
  });
}
