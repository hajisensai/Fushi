import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/stats/study_clock_run_gate.dart';
import 'package:fushi/src/stats/study_cover_tracker.dart';

/// BUG-3993：漫画 / PDF 共用的学习计时门（生命周期 + 被路由盖住）。真 Navigator 驱动
/// 「被盖住」，`apply` 回调记下每次结论。
void main() {
  test('判据：前台且没被盖住才可跑', () {
    expect(
      studyClockGateMayRun(lifecycleStopped: false, covered: false),
      isTrue,
    );
    expect(
      studyClockGateMayRun(lifecycleStopped: true, covered: false),
      isFalse,
    );
    expect(
      studyClockGateMayRun(lifecycleStopped: false, covered: true),
      isFalse,
    );
    expect(
      studyClockGateMayRun(lifecycleStopped: true, covered: true),
      isFalse,
    );
  });

  late StudyCoverTracker tracker;
  late GlobalKey<NavigatorState> navKey;
  late List<bool> applied;
  late StudyClockRunGate gate;
  late BuildContext studyContext;

  Future<void> pumpStudyPage(WidgetTester tester) async {
    tracker = StudyCoverTracker();
    navKey = GlobalKey<NavigatorState>();
    applied = <bool>[];
    gate = StudyClockRunGate(tracker: tracker, apply: applied.add);
    addTearDown(gate.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: <NavigatorObserver>[tracker],
        home: Builder(
          builder: (BuildContext context) {
            studyContext = context;
            return const Text('study');
          },
        ),
      ),
    );
    gate.attach(ModalRoute.of(studyContext));
  }

  Future<void> cover(WidgetTester tester) async {
    unawaited(
      navKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('srs')),
      ),
    );
    await tester.pump();
  }

  testWidgets('被盖住时切后台再回前台：不续表', (WidgetTester tester) async {
    await pumpStudyPage(tester);
    await cover(tester);
    expect(applied, <bool>[false], reason: '被盖住即停表');
    gate.setLifecycleStopped(true);
    gate.setLifecycleStopped(false);
    expect(applied.last, isFalse, reason: '回前台时仍被盖住，resumed 不得续表');
    expect(applied, isNot(contains(true)));
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(applied.last, isTrue, reason: '露出后才续表');
  });

  testWidgets('建表时页面已被盖住：不起表；露出才起', (WidgetTester tester) async {
    await pumpStudyPage(tester);
    await cover(tester);
    applied.clear();
    // 时钟在被盖住期间才建好（异步加载回来时用户已经开了别的页）。
    gate.sync();
    expect(applied, <bool>[false]);
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(applied.last, isTrue);
  });

  testWidgets('建表时在后台：不起表；回前台才起', (WidgetTester tester) async {
    await pumpStudyPage(tester);
    gate.setLifecycleStopped(true);
    applied.clear();
    gate.sync();
    expect(applied, <bool>[false]);
    gate.setLifecycleStopped(false);
    expect(applied.last, isTrue);
  });

  testWidgets('构造时声明豁免的弹层不停表', (WidgetTester tester) async {
    await pumpStudyPage(tester);
    unawaited(
      showDialog<void>(
        context: studyContext,
        routeSettings: studyClockRouteSettings(transparent: true),
        builder: (_) => const Text('mining'),
      ),
    );
    await tester.pump();
    expect(applied, isEmpty);
    expect(gate.mayRun, isTrue);
  });

  testWidgets('dispose 之后不再回调', (WidgetTester tester) async {
    await pumpStudyPage(tester);
    gate.dispose();
    gate.setLifecycleStopped(true);
    expect(applied, isEmpty);
  });
}
