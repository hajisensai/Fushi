import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/stats/study_clock_run_gate.dart';
import 'package:fushi/src/stats/study_cover_tracker.dart';

/// BUG-3994：漫画 / PDF 共用的学习计时门（生命周期 + 被路由盖住）。真 Navigator 驱动
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

  test('判据：手动暂停 / 页内遮挡一票否决', () {
    expect(
      studyClockGateMayRun(
        lifecycleStopped: false,
        covered: false,
        manualPause: true,
      ),
      isFalse,
    );
    expect(
      studyClockGateMayRun(
        lifecycleStopped: false,
        covered: false,
        locallyCovered: true,
      ),
      isFalse,
    );
  });

  test('判据：失焦时只有仍在播放才可跑（视频面「切走仍在播照常计时」）', () {
    expect(
      studyClockGateMayRun(
        lifecycleStopped: false,
        covered: false,
        unfocused: true,
      ),
      isFalse,
    );
    expect(
      studyClockGateMayRun(
        lifecycleStopped: false,
        covered: false,
        unfocused: true,
        playing: true,
      ),
      isTrue,
    );
    expect(
      studyClockGateMayRun(
        lifecycleStopped: true,
        covered: false,
        playing: true,
      ),
      isFalse,
      reason: '真后台 / 最小化不因在播放而豁免',
    );
  });

  test('门：手动暂停、页内遮挡、失焦 + 播放态各自驱动起停', () {
    final List<bool> log = <bool>[];
    final StudyClockRunGate g = StudyClockRunGate(
      tracker: StudyCoverTracker(),
      apply: log.add,
    );
    addTearDown(g.dispose);
    g.toggleManualPause();
    expect(g.manualPause, isTrue);
    expect(log.last, isFalse);
    g.toggleManualPause();
    expect(log.last, isTrue);
    g.setLocallyCovered(true);
    expect(log.last, isFalse);
    g.setLocallyCovered(false);
    expect(log.last, isTrue);
    g.setUnfocused(true);
    expect(log.last, isFalse, reason: '失焦且没在播：停表');
    g.setPlaying(true);
    expect(log.last, isTrue, reason: '失焦期间开始播放：续表');
    g.setPlaying(false);
    expect(log.last, isFalse);
    log.clear();
    g.setUnfocused(false);
    expect(log, <bool>[true]);
    g.setPlaying(true);
    expect(log, <bool>[true], reason: '聚焦时播放态翻转不触发 sync');
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
