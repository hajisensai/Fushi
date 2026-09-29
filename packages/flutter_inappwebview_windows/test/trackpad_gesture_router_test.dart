import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview_windows/src/in_app_webview/trackpad_gesture_router.dart';

/// BUG-2758：触控板两指捏合（PointerPanZoom 的 scale）此前被整个丢掉、只把
/// 指尖中点的平移当滚动转给 WebView2——漫画条漫里「捏合变成上下滑」。
void main() {
  test('两指滚动（scale 恒 1）只转发平移', () {
    final TrackpadGestureRouter router = TrackpadGestureRouter()..start();
    final TrackpadGestureOutput out = router.update(
      panDelta: const Offset(0, -12),
      scale: 1.0,
    );
    expect(out.kind, TrackpadGestureKind.scroll);
    expect(out.scrollDelta, const Offset(0, -12));
    expect(router.isPinching, isFalse);
  });

  test('scale 越过阈值即判捏合，此后到手势结束不再滚动', () {
    final TrackpadGestureRouter router = TrackpadGestureRouter()..start();
    // 抖动在阈值内：仍是滚动。
    expect(
      router.update(panDelta: const Offset(0, 3), scale: 1.01).kind,
      TrackpadGestureKind.scroll,
    );
    // 越过阈值：交出从手势开始累计的整段比例，起手不丢。
    final TrackpadGestureOutput first = router.update(
      panDelta: const Offset(0, 8),
      scale: 1.05,
    );
    expect(first.kind, TrackpadGestureKind.pinch);
    expect(first.pinchWheelDelta, closeTo(-100 * math.log(1.05), 1e-9));
    // 捏合中的平移（指尖中点移动）一律不转发。
    final TrackpadGestureOutput next = router.update(
      panDelta: const Offset(0, 40),
      scale: 1.05 * 1.1,
    );
    expect(next.kind, TrackpadGestureKind.pinch);
    expect(next.scrollDelta, Offset.zero);
    expect(next.pinchWheelDelta, closeTo(-100 * math.log(1.1), 1e-9));
    // 回到 scale≈1 也仍是捏合（缩回去），不是滚动。
    expect(
      router.update(panDelta: Offset.zero, scale: 1.0).kind,
      TrackpadGestureKind.pinch,
    );
  });

  test('缩小的捏合给正 deltaY（Chromium：exp(-deltaY/100) 即比例）', () {
    final TrackpadGestureRouter router = TrackpadGestureRouter()..start();
    final TrackpadGestureOutput out = router.update(
      panDelta: Offset.zero,
      scale: 0.9,
    );
    expect(out.kind, TrackpadGestureKind.pinch);
    expect(out.pinchWheelDelta, greaterThan(0));
    expect(math.exp(-out.pinchWheelDelta / 100), closeTo(0.9, 1e-9));
  });

  test('新手势重新分类：上一手势的捏合不延续到下一次两指滚动', () {
    final TrackpadGestureRouter router = TrackpadGestureRouter()..start();
    router.update(panDelta: Offset.zero, scale: 1.2);
    expect(router.isPinching, isTrue);
    router.start();
    expect(
      router.update(panDelta: const Offset(0, -5), scale: 1.0).kind,
      TrackpadGestureKind.scroll,
    );
  });
}
