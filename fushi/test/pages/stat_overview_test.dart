import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_overview.dart';
import 'package:fushi/src/pages/implementations/stat_range_bar.dart';
import 'package:fushi/src/stats/stat_range.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';

/// 统计中心总览重设计（2026-10）的契约：
///  * 媒体类型筛选的切片判据（日面 / 会话按 mediaKind，与三个域 tab 同口径）；
///  * 关键指标按本轮唯一窗口（[StatWindow]）取今日 / 本周 / 上周 / 近 7 日；
///  * 宽屏趋势 / 明细两栏并排、窄屏单栏自上而下；空数据态取代趋势与明细；
///  * 时间窗口分段控件切粒度、媒体 chip 可被焦点遍历并 Enter 选中；
///  * 两套设计系统（MD3 / Apple）都能渲染。
StatFact _fact(String kind, String dateKey, {int ms = 0, int chars = 0}) =>
    StatFact(
      mediaKind: kind,
      mediaKey: '$kind-key',
      title: '$kind-title',
      format: '',
      dateKey: dateKey,
      hour: -1,
      ms: ms,
      chars: chars,
      pages: 0,
      lastActiveMs: 0,
    );

StudySession _session(String kind) => StudySession(
  mediaKind: kind,
  mediaKey: '$kind-key',
  title: '$kind-title',
  format: '',
  deviceId: 'd',
  startAt: 0,
  endAt: 1,
  durationMs: 60000,
  chars: 0,
  pages: 0,
  segmentUids: const <String>['u'],
);

ThemeData _theme({bool apple = false, Brightness b = Brightness.light}) =>
    ThemeData(
      brightness: b,
      extensions: <ThemeExtension<dynamic>>[
        FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
      ],
    );

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(420, 900),
  ThemeData? theme,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: theme ?? _theme(),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

StatOverviewBody _body({bool empty = false}) => StatOverviewBody(
  filterBar: const Text('FILTER'),
  hero: const SizedBox(height: 40, child: Text('HERO')),
  tail: const SliverToBoxAdapter(child: SizedBox(height: 8)),
  emptyState: empty ? const StatOverviewEmpty() : null,
  trend: const <Widget>[
    SizedBox(height: 60, child: Text('TREND-A')),
    SizedBox(height: 60, child: Text('TREND-B')),
  ],
  details: const <Widget>[
    SizedBox(height: 60, child: Text('DETAIL-A')),
    SizedBox(height: 60, child: Text('DETAIL-B')),
  ],
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('筛选切片', () {
    final List<StatFact> daily = <StatFact>[
      _fact(kActivityMediaBook, '2026-10-05', ms: 1000),
      _fact(kActivityMediaVideo, '2026-10-05', ms: 2000),
      _fact(kActivityMediaGame, '2026-10-04', ms: 3000),
    ];

    test('全部 = 原样；单域只留本域行（与域 tab 同一个 mediaKind 判据）', () {
      expect(filterStatFacts(daily, StatMediaFilter.all), hasLength(3));
      for (final (StatMediaFilter f, String kind)
          in <(StatMediaFilter, String)>[
            (StatMediaFilter.book, kActivityMediaBook),
            (StatMediaFilter.video, kActivityMediaVideo),
            (StatMediaFilter.game, kActivityMediaGame),
          ]) {
        final List<StatFact> out = filterStatFacts(daily, f);
        expect(out, hasLength(1), reason: f.name);
        expect(out.single.mediaKind, kind);
      }
    });

    test('会话流按同一判据切、保持原序', () {
      final List<StudySession> sessions = <StudySession>[
        _session(kActivityMediaVideo),
        _session(kActivityMediaBook),
        _session(kActivityMediaVideo),
      ];
      expect(
        filterStudySessions(
          sessions,
          StatMediaFilter.video,
        ).map((StudySession s) => s.mediaKind),
        <String>[kActivityMediaVideo, kActivityMediaVideo],
      );
      expect(filterStudySessions(sessions, StatMediaFilter.game), isEmpty);
    });

    test('计数面来源与域 tab 一致：全部 = 不分来源', () {
      expect(StatMediaFilter.all.source, isNull);
      expect(StatMediaFilter.book.source, StatSourceKind.book);
      expect(StatMediaFilter.video.source, StatSourceKind.video);
      expect(StatMediaFilter.game.source, StatSourceKind.game);
    });
  });

  test('关键指标按唯一窗口取今日 / 本周 / 上周 / 近 7 日活跃', () {
    // 2026-10-05 是周一。
    final StatWindow w = StatWindow(DateTime(2026, 10, 5, 12));
    final StatOverviewKpis k = computeStatOverviewKpis(<StatFact>[
      _fact(kActivityMediaBook, w.todayKey, ms: 600000, chars: 500),
      _fact(kActivityMediaVideo, w.todayKey, ms: 300000),
      _fact(kActivityMediaBook, w.lastDayKeys(7)[3], ms: 60000, chars: 10),
      _fact(kActivityMediaBook, w.prevWeekFromKey, ms: 120000),
      // 零值行不算活跃日。
      _fact(kActivityMediaGame, w.lastDayKeys(7)[1]),
    ], w);
    expect(k.todayMs, 900000);
    expect(k.todayChars, 500);
    expect(k.weekMs, greaterThanOrEqualTo(900000));
    expect(k.prevWeekMs, greaterThanOrEqualTo(120000));
    expect(k.activeDaysLast7, 2);
    expect(k.streak, 1);
  });

  group('排布', () {
    testWidgets('宽屏：趋势与明细左右两栏并排', (WidgetTester tester) async {
      await _pump(tester, _body(), size: const Size(1600, 900));
      expect(
        find.byKey(const ValueKey<String>('stat-overview-wide-columns')),
        findsOneWidget,
      );
      final Offset trend = tester.getTopLeft(find.text('TREND-A'));
      final Offset detail = tester.getTopLeft(find.text('DETAIL-A'));
      expect(detail.dx, greaterThan(trend.dx), reason: '明细在右栏');
      expect(detail.dy, trend.dy, reason: '两栏顶对齐');
    });

    testWidgets('窄屏：单栏，趋势在前、明细在后', (WidgetTester tester) async {
      await _pump(tester, _body());
      expect(
        find.byKey(const ValueKey<String>('stat-overview-wide-columns')),
        findsNothing,
      );
      final List<double> ys = <String>[
        'FILTER',
        'HERO',
        'TREND-A',
        'TREND-B',
        'DETAIL-A',
        'DETAIL-B',
      ].map((String s) => tester.getTopLeft(find.text(s)).dy).toList();
      for (int i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]), reason: '第 $i 块');
      }
    });

    testWidgets('空数据：空态取代趋势与明细，筛选与指标区仍在', (WidgetTester tester) async {
      for (final Size size in const <Size>[Size(420, 900), Size(1600, 900)]) {
        await _pump(tester, _body(empty: true), size: size);
        expect(find.text('FILTER'), findsOneWidget);
        expect(find.text('HERO'), findsOneWidget);
        expect(find.text(t.stat_overview_empty), findsOneWidget);
        expect(find.text('TREND-A'), findsNothing);
        expect(find.text('DETAIL-A'), findsNothing);
      }
    });
  });

  group('关键指标区', () {
    const StatOverviewKpis kpis = StatOverviewKpis(
      todayMs: 3600000,
      weekMs: 7200000,
      prevWeekMs: 3600000,
      todayChars: 1200,
      weekChars: 5000,
      streak: 4,
      activeDaysLast7: 5,
    );

    testWidgets('未设目标显示引导、可点进目标编辑；设了显示进度', (WidgetTester tester) async {
      int edits = 0;
      await _pump(
        tester,
        StatOverviewHero(
          kpis: kpis,
          goalChars: 0,
          goalProgressChars: 0,
          onEditGoal: () => edits++,
        ),
      );
      expect(find.text(t.stat_overview_goal_unset), findsOneWidget);
      await tester.tap(find.text(t.stat_overview_goal_unset));
      await tester.pumpAndSettle();
      expect(edits, 1);

      await _pump(
        tester,
        const StatOverviewHero(
          kpis: kpis,
          goalChars: 2000,
          goalProgressChars: 1200,
        ),
      );
      expect(find.text(t.stat_overview_goal_unset), findsNothing);
      expect(find.text(t.stat_goal_progress(read: 1200, goal: 2000)), findsOne);
      expect(find.text('60%'), findsOneWidget, reason: '进场动画结束后环停在真实比例');
    });

    testWidgets('宽屏目标与指标卡并排，窄屏上下叠；两套设计系统都能渲染', (WidgetTester tester) async {
      for (final bool apple in <bool>[false, true]) {
        for (final Brightness b in Brightness.values) {
          await _pump(
            tester,
            const SingleChildScrollView(
              child: StatOverviewHero(
                kpis: kpis,
                goalChars: 2000,
                goalProgressChars: 1200,
              ),
            ),
            size: const Size(1600, 900),
            theme: _theme(apple: apple, b: b),
          );
          final Finder goal = find.byKey(
            const ValueKey<String>('stat-overview-goal'),
          );
          final Finder today = find.byKey(
            const ValueKey<String>('stat-kpi-today-time'),
          );
          expect(
            tester.getTopLeft(today).dx,
            greaterThan(tester.getTopRight(goal).dx - 1),
            reason: 'apple=$apple $b 宽屏并排',
          );

          await _pump(
            tester,
            const SingleChildScrollView(
              child: StatOverviewHero(
                kpis: kpis,
                goalChars: 2000,
                goalProgressChars: 1200,
              ),
            ),
            theme: _theme(apple: apple, b: b),
          );
          expect(
            tester.getTopLeft(today).dy,
            greaterThan(tester.getBottomLeft(goal).dy - 1),
            reason: 'apple=$apple $b 窄屏上下叠',
          );
          expect(tester.takeException(), isNull);
        }
      }
    });
  });

  testWidgets('媒体类型 chip：点选回调；焦点遍历 + Enter 选中', (WidgetTester tester) async {
    StatMediaFilter selected = StatMediaFilter.all;
    await _pump(
      tester,
      StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) =>
            StatMediaFilterBar(
              selected: selected,
              onChanged: (StatMediaFilter f) => setState(() => selected = f),
            ),
      ),
    );
    await tester.tap(find.text(StatMediaFilter.video.label));
    await tester.pumpAndSettle();
    expect(selected, StatMediaFilter.video);

    // 焦点驱动：Tab 依次走过四个 chip，第 4 下停在「游戏」，Enter 选中。
    for (int i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, StatMediaFilter.game);
  });

  testWidgets('时间窗口分段控件：切粒度回调新模式，单日态给「本月」快捷入口', (WidgetTester tester) async {
    StatRangeSelection? last;
    StatRange range = StatRange.resolve(
      const StatRangeSelection(),
      todayKey: '2026-10-05',
      earliestKey: '2025-01-01',
    );
    await _pump(
      tester,
      StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => StatRangeBar(
          range: range,
          onChanged: (StatRangeSelection s) => setState(() {
            last = s;
            range = StatRange.resolve(
              s,
              todayKey: '2026-10-05',
              earliestKey: '2025-01-01',
            );
          }),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('stat-range-modes')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('stat-range-back-to-month')),
      findsNothing,
    );
    await tester.tap(find.text(statRangeModeLabel(StatRangeMode.week)));
    await tester.pumpAndSettle();
    expect(last?.mode, StatRangeMode.week);
    expect(find.text(formatStatRange(range)), findsOneWidget);

    await tester.tap(find.text(statRangeModeLabel(StatRangeMode.day)));
    await tester.pumpAndSettle();
    expect(last?.mode, StatRangeMode.day);
    await tester.tap(
      find.byKey(const ValueKey<String>('stat-range-back-to-month')),
    );
    await tester.pumpAndSettle();
    expect(range.mode, StatRangeMode.month);
  });
}
