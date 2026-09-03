import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/lookup_dismiss_barrier.dart';

/// BUG-1757：[LookupDismissBarrier] —— 查词弹窗全屏 dismiss barrier 的唯一构造入口。
///
/// 此前四个表面（base_source_page = 阅读器/有声书、video、home_dictionary、
/// texthooker）各自手拼 `GestureDetector(onTapUp + onHorizontalDrag*)` + 透明填充盒。
/// 本 widget 把它收成一个原语，并把横拖从**手势竞技场**换成不入场的 raw [Listener]
/// 轨迹观察 + 自主判轴。
///
/// 关于「barrier 会不会堵住下层滚动」的一个**实测事实**（别再照直觉推）：barrier 的
/// 透明填充盒（`ColoredBox` / `Container(color:)`）在 hit test 上是**实心**的，下层
/// 平台视图根本不进 hit test 结果、也就不进竞技场。实测：上层只放一个不带任何手势的
/// `ColoredBox`，下层 [PlatformViewSurface] 收到 0 个指针事件；把 `ColoredBox` 去掉、
/// 只留 tap 手势，下层收到全部 14 个。所以「弹窗开着时正文收不到触摸」是 barrier
/// 实心遮挡的**既有设计**（点它是要关窗），与横拖识别器无关——不要再用竞技场模型去
/// 解释它，也不要写「下层应收到事件」这类必然失败的断言。
///
/// 本测试锁的是 barrier 自身的手势契约：
///   - 纵向滑动不关层（判轴：只有横向主导才是滑关）；
///   - 横向过阈关一层、未过阈不关（TODO-716/1052 never-break）；
///   - 鼠标横拖同样能关（TODO-716 的桌面初衷）；
///   - 开关关闭时横拖惰性（旧桌面行为）；
///   - tap 带全局坐标回调；多指不算滑关。
class _RecordingPlatformViewController extends PlatformViewController {
  _RecordingPlatformViewController(this.viewId);

  @override
  final int viewId;

  final List<PointerEvent> events = <PointerEvent>[];

  bool get sawMove => events.whereType<PointerMoveEvent>().isNotEmpty;

  int get moveCount => events.whereType<PointerMoveEvent>().length;

  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async {
    events.add(event);
  }

  @override
  Future<void> clearFocus() async {}

  @override
  Future<void> dispose() async {}
}

/// A stand-in for the reader/video content: the same [PlatformViewSurface] that
/// backs InAppWebView / media_kit on Android, with the same empty
/// `gestureRecognizers` those call sites use (verified: neither
/// reader_fushi/webview.part.dart nor manga_fushi_page.dart passes any).
Widget _platformViewContent(_RecordingPlatformViewController controller) {
  return PlatformViewSurface(
    controller: controller,
    hitTestBehavior: PlatformViewHitTestBehavior.opaque,
    gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
  );
}

Future<void> _dragVertically(WidgetTester tester, Offset start) async {
  final TestGesture gesture = await tester.startGesture(start);
  for (int i = 0; i < 12; i++) {
    await gesture.moveBy(const Offset(0, -20)); // 240px scroll up
    await tester.pump();
  }
  await gesture.up();
  await tester.pump();
}

Future<void> _dragHorizontally(WidgetTester tester, Offset start) async {
  final TestGesture gesture = await tester.startGesture(start);
  for (int i = 0; i < 12; i++) {
    await gesture.moveBy(const Offset(20, 0)); // 240px sideways
    await tester.pump();
  }
  await gesture.up();
  await tester.pump();
}

Widget _harness({
  required _RecordingPlatformViewController controller,
  required Widget barrier,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Stack(
      children: <Widget>[
        Positioned.fill(child: _platformViewContent(controller)),
        Positioned.fill(child: barrier),
      ],
    ),
  );
}

void main() {
  const Offset bare = Offset(400, 300);

  testWidgets('vertical drag over the barrier does NOT close a layer',
      (WidgetTester tester) async {
    final controller = _RecordingPlatformViewController(1);
    int dismissed = 0;
    await tester.pumpWidget(_harness(
      controller: controller,
      barrier: LookupDismissBarrier(
        onTapDismiss: (_) {},
        onSwipeDismiss: () => dismissed++,
        swipeEnabled: true,
        sensitivity: 0.6,
      ),
    ));

    await _dragVertically(tester, bare);

    expect(dismissed, 0, reason: 'a vertical scroll must not close a layer');
  });

  testWidgets(
      'the barrier fill is opaque to hit-testing (documents the real reason '
      'content under it gets no touches)', (WidgetTester tester) async {
    // Measured fact, kept as an executable note so nobody re-derives the wrong
    // gesture-arena model: it is the transparent FILL that blocks the platform
    // view, not any recognizer. Same harness, barrier replaced by a bare
    // ColoredBox with no gestures at all.
    final controller = _RecordingPlatformViewController(2);
    await tester.pumpWidget(_harness(
      controller: controller,
      barrier: const ColoredBox(color: Colors.transparent),
    ));

    await _dragVertically(tester, bare);

    expect(controller.sawMove, isFalse,
        reason: 'a plain transparent ColoredBox already withholds every touch '
            'from the platform view underneath — no gesture involved');
  });

  testWidgets('horizontal drag past threshold still closes one layer',
      (WidgetTester tester) async {
    final controller = _RecordingPlatformViewController(3);
    int dismissed = 0;
    await tester.pumpWidget(_harness(
      controller: controller,
      barrier: LookupDismissBarrier(
        onTapDismiss: (_) {},
        onSwipeDismiss: () => dismissed++,
        swipeEnabled: true,
        sensitivity: 0.6,
      ),
    ));

    await _dragHorizontally(tester, bare);

    expect(dismissed, 1,
        reason: 'TODO-716/1052 swipe-to-close must keep working');
  });

  testWidgets('below-threshold horizontal drag does not close',
      (WidgetTester tester) async {
    final controller = _RecordingPlatformViewController(4);
    int dismissed = 0;
    await tester.pumpWidget(_harness(
      controller: controller,
      barrier: LookupDismissBarrier(
        onTapDismiss: (_) {},
        onSwipeDismiss: () => dismissed++,
        swipeEnabled: true,
        sensitivity: 0.6,
      ),
    ));

    final TestGesture gesture = await tester.startGesture(bare);
    for (int i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(20, 0)); // 60px < ~94px threshold
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();

    expect(dismissed, 0);
  });

  testWidgets('swipe switch OFF: horizontal drag is inert (never-break)',
      (WidgetTester tester) async {
    final controller = _RecordingPlatformViewController(5);
    int dismissed = 0;
    await tester.pumpWidget(_harness(
      controller: controller,
      barrier: LookupDismissBarrier(
        onTapDismiss: (_) {},
        onSwipeDismiss: () => dismissed++,
        swipeEnabled: false,
        sensitivity: 0.6,
      ),
    ));

    await _dragHorizontally(tester, bare);

    expect(dismissed, 0,
        reason: 'with the switch off the barrier only taps (old desktop)');
  });

  testWidgets('mouse horizontal drag closes a layer too (TODO-716 desktop)',
      (WidgetTester tester) async {
    final controller = _RecordingPlatformViewController(6);
    int dismissed = 0;
    await tester.pumpWidget(_harness(
      controller: controller,
      barrier: LookupDismissBarrier(
        onTapDismiss: (_) {},
        onSwipeDismiss: () => dismissed++,
        swipeEnabled: true,
        sensitivity: 0.6,
      ),
    ));

    final TestGesture gesture =
        await tester.startGesture(bare, kind: PointerDeviceKind.mouse);
    for (int i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();

    expect(dismissed, 1,
        reason: 'TODO-716 exists precisely so DESKTOP (mouse) can swipe the '
            'barrier to close; barrier is blank so drag has no other meaning');
  });

  testWidgets('tap on the barrier still dismisses with the global position',
      (WidgetTester tester) async {
    final controller = _RecordingPlatformViewController(7);
    Offset? tapped;
    await tester.pumpWidget(_harness(
      controller: controller,
      barrier: LookupDismissBarrier(
        onTapDismiss: (Offset p) => tapped = p,
        onSwipeDismiss: () {},
        swipeEnabled: true,
        sensitivity: 0.6,
      ),
    ));

    await tester.tapAt(bare);
    await tester.pump();

    expect(tapped, bare);
  });

  testWidgets('second finger cancels the swipe (multi-touch is not a swipe)',
      (WidgetTester tester) async {
    final controller = _RecordingPlatformViewController(8);
    int dismissed = 0;
    await tester.pumpWidget(_harness(
      controller: controller,
      barrier: LookupDismissBarrier(
        onTapDismiss: (_) {},
        onSwipeDismiss: () => dismissed++,
        swipeEnabled: true,
        sensitivity: 0.6,
      ),
    ));

    final TestGesture first = await tester.startGesture(bare, pointer: 11);
    final TestGesture second =
        await tester.startGesture(const Offset(200, 300), pointer: 12);
    for (int i = 0; i < 12; i++) {
      await first.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pump();

    expect(dismissed, 0,
        reason: 'a pinch/two-finger gesture must not be read as a swipe-close');
  });
}
