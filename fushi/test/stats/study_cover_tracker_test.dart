import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/stats/study_cover_tracker.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptiveModalSheet;
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// BUG-3993：学习页之上压着任何未豁免的模态路由（整页 / 对话框 / 弹出菜单 / 侧板）
/// 都算「被盖住」；路由构造时带 [StudyClockTransparentSettings] 的弹层不算。
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

  testWidgets('构造时声明豁免的弹层不算盖住，且推上去当帧就不停表（无停 / 起抖动）', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    unawaited(
      showAppDialog<void>(
        context: studyContext,
        studyClockTransparent: true,
        builder: (_) => const Text('mining'),
      ),
    );
    await tester.pump();
    expect(watch.covered, isFalse);
    unawaited(
      adaptiveModalSheet<void>(
        context: studyContext,
        studyClockTransparent: true,
        builder: (_) => const Text('advanced mining'),
      ),
    );
    await tester.pump();
    expect(watch.covered, isFalse);
    expect(
      changes,
      isEmpty,
      reason: '豁免要在 didPush 当帧可见：先判盖住停表、建好后再起表 = 多封一段多写一次库',
    );

    // 豁免弹层之上再压一个普通对话框：照样算盖住。
    unawaited(
      showAppDialog<void>(
        context: studyContext,
        builder: (_) => const Text('confirm'),
      ),
    );
    await tester.pump();
    expect(watch.covered, isTrue);
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(watch.covered, isFalse);
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(watch.covered, isFalse);
    expect(changes, <bool>[true, false]);
    expect(tracker.debugStack.length, 2);
  });

  testWidgets('豁免随开关切换（统计侧板）：开关在事件里改，出栈后退订', (WidgetTester tester) async {
    await pumpApp(tester);
    final ValueNotifier<bool> statisticsShown = ValueNotifier<bool>(true);
    addTearDown(statisticsShown.dispose);
    unawaited(
      showGeneralDialog<void>(
        context: studyContext,
        routeSettings: studyClockRouteSettings(
          transparentWhen: statisticsShown,
        ),
        pageBuilder: (_, _, _) => const Text('panel'),
      ),
    );
    await tester.pump();
    expect(watch.covered, isFalse, reason: '打开时初值由路由构造参数给出');
    expect(changes, isEmpty);
    statisticsShown.value = false;
    expect(watch.covered, isTrue, reason: '切走统计页同步停表，不必等下一帧 build');
    statisticsShown.value = true;
    expect(watch.covered, isFalse);
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(changes, <bool>[true, false]);
    // 出栈后观察器已退订：再拨开关不再通知。
    int notified = 0;
    void count() => notified++;
    tracker.addListener(count);
    addTearDown(() => tracker.removeListener(count));
    statisticsShown.value = false;
    expect(notified, 0);
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
