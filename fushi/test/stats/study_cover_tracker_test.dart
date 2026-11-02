import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/stats/study_cover_tracker.dart';

/// BUG-3959：学习页之上压着任何未豁免的模态路由（整页 / 对话框 / 弹出菜单 / 侧板）
/// 都算「被盖住」；[StudyClockTransparentRoute] 声明的弹层不算。
void main() {
  late StudyCoverTracker tracker;
  late GlobalKey<NavigatorState> navKey;
  late List<bool> changes;
  late StudyCoverWatch watch;
  late BuildContext studyContext;

  Future<void> pumpApp(WidgetTester tester) async {
    tracker = StudyCoverTracker();
    navKey = GlobalKey<NavigatorState>();
    changes = <bool>[];
    watch = StudyCoverWatch(
      tracker: tracker,
      onChanged: () => changes.add(watch.covered),
    );
    addTearDown(watch.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: <NavigatorObserver>[tracker],
        home: const Text('home'),
      ),
    );
    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) {
          studyContext = context;
          return const Text('study');
        },
      ),
    );
    await tester.pumpAndSettle();
    watch.attach(ModalRoute.of(studyContext));
  }

  testWidgets('学习页在栈顶不算盖住；下面的首页路由不影响', (WidgetTester tester) async {
    await pumpApp(tester);
    expect(watch.covered, isFalse);
    expect(changes, isEmpty);
  });

  testWidgets('整页路由盖住 → 停；返回 → 续', (WidgetTester tester) async {
    await pumpApp(tester);
    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('srs')),
    );
    await tester.pump();
    expect(watch.covered, isTrue);
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(watch.covered, isFalse);
    expect(changes, <bool>[true, false]);
  });

  testWidgets('对话框 / 弹出路由（非 PageRoute）同样算盖住', (WidgetTester tester) async {
    await pumpApp(tester);
    showDialog<void>(
      context: studyContext,
      builder: (_) => const Text('dialog'),
    );
    await tester.pump();
    expect(watch.covered, isTrue);
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(watch.covered, isFalse);

    showGeneralDialog<void>(
      context: studyContext,
      pageBuilder: (_, _, _) => const Text('side panel'),
    );
    await tester.pump();
    expect(watch.covered, isTrue);
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(watch.covered, isFalse);
  });

  testWidgets('声明豁免的弹层不算盖住；豁免可随状态切换', (WidgetTester tester) async {
    await pumpApp(tester);
    final ValueNotifier<bool> exempt = ValueNotifier<bool>(true);
    addTearDown(exempt.dispose);
    showDialog<void>(
      context: studyContext,
      builder: (_) => ValueListenableBuilder<bool>(
        valueListenable: exempt,
        builder: (_, bool value, _) => StudyClockTransparentRoute(
          enabled: value,
          tracker: tracker,
          child: const Text('mining'),
        ),
      ),
    );
    await tester.pump();
    expect(watch.covered, isFalse, reason: '首帧建好后豁免生效');
    exempt.value = false;
    await tester.pump();
    expect(watch.covered, isTrue);
    exempt.value = true;
    await tester.pump();
    expect(watch.covered, isFalse);

    // 豁免弹层之上再压一个普通对话框：照样算盖住。
    showDialog<void>(
      context: studyContext,
      builder: (_) => const Text('confirm'),
    );
    await tester.pump();
    expect(watch.covered, isTrue);
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(watch.covered, isFalse);
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(watch.covered, isFalse);
    expect(tracker.debugStack.length, 2);
  });

  testWidgets('盖在上面的路由被 replace / remove 也跟得上', (WidgetTester tester) async {
    await pumpApp(tester);
    final MaterialPageRoute<void> top = MaterialPageRoute<void>(
      builder: (_) => const Text('a'),
    );
    navKey.currentState!.push(top);
    await tester.pumpAndSettle();
    expect(watch.covered, isTrue);
    navKey.currentState!.replace(
      oldRoute: top,
      newRoute: MaterialPageRoute<void>(builder: (_) => const Text('b')),
    );
    await tester.pumpAndSettle();
    expect(watch.covered, isTrue);
    final Route<dynamic> b = tracker.debugStack.last;
    navKey.currentState!.removeRoute(b);
    await tester.pumpAndSettle();
    expect(watch.covered, isFalse);
  });

  testWidgets('学习页不在根栈里（未登记 / 已出栈）不判盖住', (WidgetTester tester) async {
    await pumpApp(tester);
    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('srs')),
    );
    await tester.pump();
    expect(tracker.covers(null), isFalse);
    expect(
      tracker.covers(MaterialPageRoute<void>(builder: (_) => const SizedBox())),
      isFalse,
    );
  });
}
