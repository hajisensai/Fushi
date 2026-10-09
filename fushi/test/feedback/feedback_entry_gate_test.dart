// BUG-3097：反馈自动截图截到页面转场中途（反馈中心半透明叠在视频页上）。
//
// 入口闸的两条契约：①有转场在跑时等它走完、这一帧画完再截；②反馈中心开着时重复
// 点击（悬浮球随时点得到）不再截第二张、不再压第二个反馈中心。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_entry_gate.dart';
import 'package:material_ui/material_ui.dart';

class _Capture {
  int calls = 0;
  final List<bool> animatingAtCapture = <bool>[];
  final List<bool> pageBVisibleAtCapture = <bool>[];
  final List<bool> centerVisibleAtCapture = <bool>[];
}

void main() {
  late RouteTransitionTracker tracker;
  late _Capture capture;
  late FeedbackEntryGate gate;
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

  setUp(() {
    tracker = RouteTransitionTracker();
    capture = _Capture();
    gate = FeedbackEntryGate(
      transitions: tracker,
      capture: () async {
        capture.calls++;
        capture.animatingAtCapture.add(tracker.isAnimating);
        capture.pageBVisibleAtCapture.add(
          find.text('page B').evaluate().isNotEmpty,
        );
        capture.centerVisibleAtCapture.add(
          find.text('feedback center').evaluate().isNotEmpty,
        );
        return Uint8List.fromList(<int>[1]);
      },
    );
  });

  Route<void> fade(String label) => PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 300),
    reverseTransitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (_, _, _) => Scaffold(body: Center(child: Text(label))),
    transitionsBuilder: (_, Animation<double> a, _, Widget child) =>
        FadeTransition(opacity: a, child: child),
  );

  Route<void> center(Uint8List? _) => fade('feedback center');

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: <NavigatorObserver>[tracker],
        home: const Scaffold(body: Center(child: Text('video page'))),
      ),
    );
  }

  testWidgets('BUG-3097 上一页退场动画还在跑时打开：等退场走完再截，不截叠画', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    navKey.currentState!.push(fade('page B'));
    await tester.pumpAndSettle();

    navKey.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tracker.isAnimating, isTrue, reason: '退场动画进行中');

    final Future<void> opening = gate.open(
      navKey.currentContext!,
      captureScreen: true,
      route: center,
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(capture.calls, 0, reason: '转场没走完不能截');

    await tester.pumpAndSettle();
    expect(capture.calls, 1);
    expect(capture.animatingAtCapture.single, isFalse);
    expect(
      capture.pageBVisibleAtCapture.single,
      isFalse,
      reason: '截图那一帧里退场的页面已经摘掉',
    );
    expect(find.text('feedback center'), findsOneWidget);

    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    await opening;
  });

  testWidgets('BUG-3097 反馈中心开着（含正在淡入）时重复点击：只截一张、只压一个', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    final BuildContext ctx = navKey.currentContext!;
    final Future<void> first = gate.open(
      ctx,
      captureScreen: true,
      route: center,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tracker.isAnimating, isTrue, reason: '反馈中心正在淡入');
    // 悬浮球浮在导航之上，淡入中途还点得到。
    await gate.open(ctx, captureScreen: true, route: center);
    await tester.pumpAndSettle();

    expect(capture.calls, 1);
    expect(capture.centerVisibleAtCapture.single, isFalse);
    expect(find.text('feedback center'), findsOneWidget);

    // 弹出后入口闸放开：退场途中再点，等退场走完、截到干净的视频页。
    navKey.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 100));
    await first;
    final Future<void> second = gate.open(
      ctx,
      captureScreen: true,
      route: center,
    );
    await tester.pumpAndSettle();
    expect(capture.calls, 2);
    expect(capture.animatingAtCapture.last, isFalse);
    expect(capture.centerVisibleAtCapture.last, isFalse);
    expect(find.text('feedback center'), findsOneWidget);
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    await second;
  });

  testWidgets('静止时打开：push 之前就截（截的是打开前的页面）', (WidgetTester tester) async {
    await pumpApp(tester);
    final Future<void> opening = gate.open(
      navKey.currentContext!,
      captureScreen: true,
      route: center,
    );
    await tester.pump();
    expect(capture.calls, 1);
    expect(capture.centerVisibleAtCapture.single, isFalse);
    await tester.pumpAndSettle();
    expect(find.text('feedback center'), findsOneWidget);
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    await opening;
  });

  test('BUG-3097 两个入口都经入口闸、根导航挂着转场跟踪', () {
    final String common = File(
      'lib/src/pages/implementations/feedback/feedback_common.dart',
    ).readAsStringSync();
    expect(common, contains('feedbackEntryGate.open('));
    expect(common, isNot(contains('await captureFeedbackScreenshot()')));
    final String mainSrc = File('lib/main.dart').readAsStringSync();
    final int observers = mainSrc.indexOf('navigatorObservers:');
    expect(observers, greaterThan(0));
    expect(
      mainSrc.substring(observers, mainSrc.indexOf(']', observers)),
      contains('feedbackRouteTransitions'),
    );
    final String ball = File(
      'lib/src/floating_ball/app_floating_ball_host.dart',
    ).readAsStringSync();
    expect(ball, contains('openFeedbackCenter('));
  });
}
