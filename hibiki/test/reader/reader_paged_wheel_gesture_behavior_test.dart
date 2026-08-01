import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// BUG-1342：macOS 横向触控板滑动会被拆成持续一秒以上的 wheel 惯性流。
/// 手势闸门必须活在跨章节持久的 reader Dart State，而不是随 WebView document 重建；
/// 因此这里真执行生产闸门，模拟惯性跨过一次章节导航后仍只放行一页。
void main() {
  test('1.5s horizontal momentum burst starts exactly one gesture', () {
    final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
    DateTime now = DateTime(2026, 8, 1);
    int accepted = 0;
    for (int elapsed = 0; elapsed <= 1500; elapsed += 60) {
      if (gate.shouldStartNewGesture(
        now: now,
        settleInterval: const Duration(milliseconds: 450),
      )) {
        accepted += 1;
      }
      // The same gate object intentionally survives the simulated chapter
      // navigation halfway through the burst; a JS-document-local gate would
      // reset here and incorrectly accept a second page turn.
      now = now.add(const Duration(milliseconds: 60));
    }
    expect(accepted, 1);
  });

  test('only a full quiet interval unlocks the next horizontal gesture', () {
    final ReaderWheelGestureGate gate = ReaderWheelGestureGate();
    final DateTime first = DateTime(2026, 8, 1);
    expect(
      gate.shouldStartNewGesture(
        now: first,
        settleInterval: const Duration(milliseconds: 450),
      ),
      isTrue,
    );
    expect(
      gate.shouldStartNewGesture(
        now: first.add(const Duration(milliseconds: 449)),
        settleInterval: const Duration(milliseconds: 450),
      ),
      isFalse,
    );
    expect(
      gate.shouldStartNewGesture(
        now: first.add(const Duration(milliseconds: 899)),
        settleInterval: const Duration(milliseconds: 450),
      ),
      isTrue,
    );
  });
}
