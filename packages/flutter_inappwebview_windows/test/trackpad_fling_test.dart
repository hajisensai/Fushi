import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview_windows/src/in_app_webview/custom_platform_view.dart';
import 'package:flutter_inappwebview_windows/src/in_app_webview/trackpad_gesture_router.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 2026-10-19：Windows 笔记本触控板在查词弹窗里滚动「卡卡的」，浏览器扩展里的
/// 同一份弹窗就不卡。引擎在惯性阶段不发 PanZoomUpdate，WebView 侧此前也不续惯性，
/// 松手即急停；Chromium 在浏览器里会把惯性继续作为滚轮发给页面。
void main() {
  group('TrackpadFling（纯逻辑）', () {
    test('慢速抬手不起惯性', () {
      expect(TrackpadFling.fromVelocity(const Offset(0, 10)), isNull);
      expect(TrackpadFling.fromVelocity(Offset.zero), isNull);
    });

    test('惯性增量与平移同号、逐帧递减、有限时间内结束', () {
      final TrackpadFling fling = TrackpadFling.fromVelocity(
        const Offset(0, -1500),
      )!;
      final List<double> deltas = <double>[];
      Duration t = Duration.zero;
      while (true) {
        t += const Duration(milliseconds: 16);
        final Offset? d = fling.step(t);
        if (d == null) break;
        deltas.add(d.dy);
        expect(t, lessThan(const Duration(seconds: 10)), reason: '惯性必须会停');
      }
      expect(deltas.length, greaterThan(10), reason: '松手后持续若干帧');
      expect(deltas.every((double d) => d <= 0), isTrue, reason: '方向与手指平移一致');
      expect(deltas.first.abs(), greaterThan(deltas.last.abs()), reason: '减速');
      final double total = deltas.fold(0, (double a, double b) => a + b);
      expect(total, lessThan(-50), reason: '惯性要带出可感知的距离');
    });

    test('超大速度按 kMaxFlingVelocity 截断', () {
      final TrackpadFling capped = TrackpadFling.fromVelocity(
        const Offset(0, 1e6),
      )!;
      final TrackpadFling max = TrackpadFling.fromVelocity(
        const Offset(0, kMaxFlingVelocity),
      )!;
      const Duration t = Duration(milliseconds: 16);
      expect(capped.step(t)!.dy, closeTo(max.step(t)!.dy, 1e-6));
    });
  });

  group('CustomPlatformView 接线', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const MethodChannel manager = MethodChannel(
      'com.pichillilorenzo/flutter_inappwebview_manager',
    );
    const MethodChannel view = MethodChannel(
      'com.pichillilorenzo/custom_platform_view_7',
    );
    final List<List<double>> scrolls = <List<double>>[];

    setUp(() {
      scrolls.clear();
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(manager, (MethodCall call) async {
        if (call.method == 'createInAppWebView') return 7;
        return null;
      });
      messenger.setMockMethodCallHandler(view, (MethodCall call) async {
        if (call.method == 'setScrollDelta') {
          final List<Object?> args = call.arguments as List<Object?>;
          scrolls.add(<double>[args[0]! as double, args[1]! as double]);
        }
        return null;
      });
    });

    tearDown(() {
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(manager, null);
      messenger.setMockMethodCallHandler(view, null);
    });

    Future<void> pumpView(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 300,
              child: CustomPlatformView(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    /// 两指快速上滑 10 帧后抬手（与引擎一样：抬手后不再有 PanZoomUpdate）。
    Future<void> swipe(WidgetTester tester, TestPointer p) async {
      const Offset at = Offset(150, 150);
      tester.binding.handlePointerEvent(p.panZoomStart(at));
      for (int i = 1; i <= 10; i++) {
        tester.binding.handlePointerEvent(
          p.panZoomUpdate(
            at,
            pan: Offset(0, -20.0 * i),
            timeStamp: Duration(milliseconds: 8 * i),
          ),
        );
      }
      tester.binding.handlePointerEvent(
        p.panZoomEnd(timeStamp: const Duration(milliseconds: 88)),
      );
    }

    testWidgets('两指快滑抬手后继续向页面补发同向滚动', (WidgetTester tester) async {
      await pumpView(tester);
      final TestPointer p = TestPointer(1, PointerDeviceKind.trackpad);
      await swipe(tester, p);
      final int duringGesture = scrolls.length;
      expect(duringGesture, 10);

      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final List<List<double>> inertia = scrolls.sublist(duringGesture);
      expect(inertia, isNotEmpty, reason: '修前抬手即停，这里一条都没有');
      expect(
        inertia.every((List<double> d) => d[1] < 0),
        isTrue,
        reason: '惯性方向与手指平移一致',
      );

      await tester.pumpAndSettle();
    });

    testWidgets('惯性中再次放上两指立即停下', (WidgetTester tester) async {
      await pumpView(tester);
      final TestPointer p = TestPointer(1, PointerDeviceKind.trackpad);
      await swipe(tester, p);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));

      tester.binding.handlePointerEvent(p.panZoomStart(const Offset(150, 150)));
      final int afterStop = scrolls.length;
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scrolls.length, afterStop, reason: '新手势开始，惯性不能继续推页面');
      tester.binding.handlePointerEvent(p.panZoomEnd());
      await tester.pumpAndSettle();
    });

    testWidgets('系统惯性取消事件也立即停下', (WidgetTester tester) async {
      await pumpView(tester);
      final TestPointer p = TestPointer(1, PointerDeviceKind.trackpad);
      await swipe(tester, p);
      await tester.pump(const Duration(milliseconds: 16));

      tester.binding.handlePointerEvent(
        const PointerScrollInertiaCancelEvent(
          kind: PointerDeviceKind.trackpad,
          position: Offset(150, 150),
        ),
      );
      final int afterStop = scrolls.length;
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scrolls.length, afterStop);
    });

    testWidgets('捏合抬手不续惯性', (WidgetTester tester) async {
      await pumpView(tester);
      final TestPointer p = TestPointer(1, PointerDeviceKind.trackpad);
      const Offset at = Offset(150, 150);
      tester.binding.handlePointerEvent(p.panZoomStart(at));
      for (int i = 1; i <= 10; i++) {
        tester.binding.handlePointerEvent(
          p.panZoomUpdate(
            at,
            pan: Offset(0, -20.0 * i),
            scale: 1 + 0.05 * i,
            timeStamp: Duration(milliseconds: 8 * i),
          ),
        );
      }
      tester.binding.handlePointerEvent(
        p.panZoomEnd(timeStamp: const Duration(milliseconds: 88)),
      );
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scrolls, isEmpty, reason: '捏合全程只发缩放、抬手也不滚动');
    });
  });
}
