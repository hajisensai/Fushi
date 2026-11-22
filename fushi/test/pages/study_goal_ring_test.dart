// 学习目标环的完成状态（[StudyGoalRing]，设置行 / 首页「今日」格 / 「语言目标」格 /
// 统计页共用）：没开始、进行中、已完成（对勾）、超出（只画满一圈 + 对勾）、休息日
// （淡色 + 月亮）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_ring.dart';
import 'package:fushi/src/pages/implementations/study_goal_visuals.dart';
import 'package:fushi/src/platform/widget_snapshot.dart'
    show StudyGoalProgress, StudyGoalState;
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

StudyGoalProgress _progress(int value, int target, {bool restDay = false}) {
  final StudyGoal goal = StudyGoal(
    id: 'g',
    metric: StudyGoalId.chars,
    period: StudyGoalPeriod.daily,
    target: target,
  );
  return StudyGoalProgress(
    goal: goal,
    value: value,
    target: target,
    restDay: restDay,
  );
}

Future<void> _pump(WidgetTester tester, Widget ring) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(body: Center(child: ring)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _icon(IconData icon) =>
    find.byWidgetPredicate((Widget w) => w is FushiIcon && w.icon == icon);

double _painted(WidgetTester tester) {
  final CustomPaint paint = tester.widget<CustomPaint>(
    find.byWidgetPredicate(
      (Widget w) => w is CustomPaint && w.painter is StatRingPainter,
    ),
  );
  return (paint.painter! as StatRingPainter).fraction;
}

void main() {
  const Color color = Color(0xFF2E7D32);
  const Color track = Color(0xFFC8E6C9);

  test('state follows value / target / rest day', () {
    expect(_progress(0, 100).state, StudyGoalState.notStarted);
    expect(_progress(37, 100).state, StudyGoalState.inProgress);
    expect(_progress(100, 100).state, StudyGoalState.completed);
    expect(_progress(148, 100).state, StudyGoalState.exceeded);
    expect(_progress(0, 100, restDay: true).state, StudyGoalState.restDay);
    // 休息日做到了照样算达成（不是「休息」）。
    expect(_progress(120, 100, restDay: true).state, StudyGoalState.exceeded);
  });

  testWidgets('in progress: arc = progress, percent in the middle', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      StudyGoalRing.progress(_progress(37, 100), color: color, track: track),
    );
    expect(find.text('37%'), findsOneWidget);
    expect(_icon(FushiIcons.check), findsNothing);
    expect(_painted(tester), closeTo(0.37, 0.001));
  });

  testWidgets('not started: empty arc and 0%', (WidgetTester tester) async {
    await _pump(
      tester,
      StudyGoalRing.progress(_progress(0, 100), color: color, track: track),
    );
    expect(find.text('0%'), findsOneWidget);
    expect(_painted(tester), 0);
  });

  testWidgets('completed: full ring with a check mark, no percent', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      StudyGoalRing.progress(_progress(100, 100), color: color, track: track),
    );
    expect(_icon(FushiIcons.check), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(_painted(tester), 1);
  });

  testWidgets('exceeded: capped at one full turn, check mark', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      StudyGoalRing.progress(_progress(148, 100), color: color, track: track),
    );
    expect(_icon(FushiIcons.check), findsOneWidget);
    expect(_painted(tester), 1);
  });

  testWidgets('small completed ring still shows the check (no percent)', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      StudyGoalRing.progress(
        _progress(100, 100),
        color: color,
        track: track,
        size: 24,
        showPercent: false,
      ),
    );
    expect(_icon(FushiIcons.check), findsOneWidget);
  });

  testWidgets('rest day: muted colours and a moon, no failure colour', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      StudyGoalRing.progress(
        _progress(0, 100, restDay: true),
        color: color,
        track: track,
      ),
    );
    expect(_icon(FushiIcons.darkMode), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    final StatRingPainter painter =
        tester
                .widget<CustomPaint>(
                  find.byWidgetPredicate(
                    (Widget w) =>
                        w is CustomPaint && w.painter is StatRingPainter,
                  ),
                )
                .painter!
            as StatRingPainter;
    expect(painter.color.a, lessThan(color.a));
    expect(painter.trackColor.a, lessThan(track.a));
  });

  testWidgets('no state (visual only): 100% stays a percent, no check', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const StudyGoalRing(fraction: 1, color: color, track: track),
    );
    expect(find.text('100%'), findsOneWidget);
    expect(_icon(FushiIcons.check), findsNothing);
  });

  testWidgets('big ring writes the detail line under the check', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      StudyGoalRing.progress(
        _progress(14800, 10000),
        color: color,
        track: track,
        size: 96,
        detail: '14800/10000',
      ),
    );
    expect(_icon(FushiIcons.check), findsOneWidget);
    expect(find.text('14800/10000'), findsOneWidget);
  });

  testWidgets('progress bar: capped at full width when exceeded', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      SizedBox(
        width: 200,
        child: StudyGoalProgressBar(
          progress: _progress(148, 100),
          color: color,
          track: track,
        ),
      ),
    );
    expect(
      tester
          .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .widthFactor,
      1,
    );
  });
}
