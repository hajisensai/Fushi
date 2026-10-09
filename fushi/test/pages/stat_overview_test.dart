import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_dashboard.dart';
import 'package:fushi/src/pages/implementations/stat_range_bar.dart';
import 'package:fushi/src/stats/stat_range.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/utils/components/stat_contribution_heatmap.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';

/// 统计中心重设计（2026-10，2026-10-09 精简）的契约：
///  * 宽屏趋势 / 明细两栏并排、窄屏单栏自上而下；空数据态取代趋势与明细；
///  * 「过去一周」火苗按活跃天数分三档大小，与学习日历同一张卡（火苗行在上）；
///  * 时间窗口分段控件切粒度，非当前段时给「回到当前」入口；
///  * 两套设计系统（MD3 / Apple）都能渲染。
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
  bool settle = true,
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
  // M3 Expressive 的波浪进度条（周目标条）相位常动，等不到 settle：只推过进场。
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(seconds: 2));
  }
}

StatDashboardBody _body({bool empty = false}) => StatDashboardBody(
  header: const Text('FILTER'),
  hero: const SizedBox(height: 40, child: Text('HERO')),
  tail: const SliverToBoxAdapter(child: SizedBox(height: 8)),
  emptyState: empty ? StatDashboardEmpty(message: t.stat_overview_empty) : null,
  trend: const <Widget>[
    SizedBox(height: 60, child: Text('TREND-A')),
    SizedBox(height: 60, child: Text('TREND-B')),
  ],
  details: const <Widget>[
    SizedBox(height: 60, child: Text('DETAIL-A')),
    SizedBox(height: 60, child: Text('DETAIL-B')),
  ],
  detailSlivers: <Widget>[
    SliverList(
      delegate: SliverChildListDelegate(const <Widget>[
        SizedBox(height: 40, child: Text('ROW-1')),
        SizedBox(height: 40, child: Text('ROW-2')),
      ]),
    ),
  ],
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('排布', () {
    testWidgets('宽屏：趋势与明细左右两栏并排', (WidgetTester tester) async {
      await _pump(tester, _body(), size: const Size(1600, 900));
      expect(
        find.byKey(const ValueKey<String>('stat-dashboard-wide-columns')),
        findsOneWidget,
      );
      final Offset trend = tester.getTopLeft(find.text('TREND-A'));
      final Offset detail = tester.getTopLeft(find.text('DETAIL-A'));
      expect(detail.dx, greaterThan(trend.dx), reason: '明细在右栏');
      expect(detail.dy, trend.dy, reason: '两栏顶对齐');
      final Offset row = tester.getTopLeft(find.text('ROW-1'));
      expect(row.dx, detail.dx, reason: '按作品长列表接在明细栏');
      expect(row.dy, greaterThan(tester.getTopLeft(find.text('DETAIL-B')).dy));
    });

    testWidgets('窄屏：单栏，趋势在前、明细在后', (WidgetTester tester) async {
      await _pump(tester, _body());
      expect(
        find.byKey(const ValueKey<String>('stat-dashboard-wide-columns')),
        findsNothing,
      );
      final List<double> ys = <String>[
        'FILTER',
        'HERO',
        'TREND-A',
        'TREND-B',
        'DETAIL-A',
        'DETAIL-B',
        'ROW-1',
        'ROW-2',
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
        expect(find.text('ROW-1'), findsNothing);
      }
    });
  });

  test('「过去一周」火苗档位：0 / 1–2 / 3–5 / 6–7 天', () {
    expect(<int>[for (int d = 0; d <= 7; d++) statWeekFlameTier(d)],
        <int>[0, 1, 1, 2, 2, 2, 3, 3]);
    expect(statWeekFlameSize(3), greaterThan(statWeekFlameSize(2)));
    expect(statWeekFlameSize(2), greaterThan(statWeekFlameSize(1)));
  });

  group('学习日历 + 过去一周', () {
    final StatWindow w = StatWindow(DateTime(2026, 10, 7, 12));
    final List<String> week = w.lastDayKeys(7);
    Map<String, StatDayData> byDay(int activeDays) => <String, StatDayData>{
          for (int i = 0; i < activeDays; i++)
            week[6 - i]: StatDayData(dateKey: week[6 - i])..ms = 600000,
        };

    Widget section(int activeDays, ValueChanged<String> onDay) => Builder(
          builder: (BuildContext context) => SingleChildScrollView(
            child: buildStatRangeCalendarSection(
              context,
              byDay: byDay(activeDays),
              now: w.now,
              weekKeys: week,
              onDaySelected: onDay,
            ),
          ),
        );

    testWidgets('火苗行在日历之上；7 个日格；档位随天数变；点日格回调那一天', (
      WidgetTester tester,
    ) async {
      final List<String> picked = <String>[];
      for (final (int days, int tier) in <(int, int)>[
        (0, 0),
        (2, 1),
        (4, 2),
        (7, 3),
      ]) {
        await _pump(tester, section(days, picked.add));
        expect(
          find.byKey(ValueKey<String>('stat-week-flame-tier-$tier')),
          findsOneWidget,
          reason: '$days 天 → $tier 档',
        );
        expect(
          find.textContaining(t.stat_format_days(n: days), findRichText: true),
          findsOneWidget,
        );
      }
      for (final String key in week) {
        expect(find.byKey(ValueKey<String>('stat-week-day-$key')), findsOne);
      }
      expect(
        tester
            .getTopLeft(find.textContaining(t.stat_week_past, findRichText: true))
            .dy,
        lessThan(tester.getTopLeft(find.byType(StatContributionHeatmap)).dy),
        reason: '过去一周在上、日历在下',
      );
      await tester.tap(find.byKey(ValueKey<String>('stat-week-day-${week[2]}')));
      await tester.pumpAndSettle();
      expect(picked, <String>[week[2]]);
    });

    testWidgets('手机宽 / 桌面宽、两套设计系统都不溢出', (WidgetTester tester) async {
      for (final bool apple in <bool>[false, true]) {
        for (final Size size in const <Size>[Size(360, 900), Size(1600, 900)]) {
          await _pump(tester, section(5, (_) {}),
              size: size, theme: _theme(apple: apple));
          expect(tester.takeException(), isNull,
              reason: 'apple=$apple ${size.width}');
        }
      }
    });
  });

  testWidgets('时间窗口分段控件：切粒度回调新模式；翻到过去给「回到当前」入口', (
    WidgetTester tester,
  ) async {
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
    final Finder back =
        find.byKey(const ValueKey<String>('stat-range-back-to-current'));
    expect(
      find.byKey(const ValueKey<String>('stat-range-modes')),
      findsOneWidget,
    );
    expect(back, findsNothing, reason: '本月即当前段');
    await tester.tap(find.text(statRangeModeLabel(StatRangeMode.week)));
    await tester.pumpAndSettle();
    expect(last?.mode, StatRangeMode.week);
    expect(find.text(formatStatRange(range)), findsOneWidget);
    expect(back, findsNothing);

    await tester.tap(find.byTooltip(t.stat_range_previous));
    await tester.pumpAndSettle();
    expect(back, findsOneWidget);
    expect(find.text(t.stat_this_week), findsOneWidget);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(range.mode, StatRangeMode.week);
    expect(range.contains('2026-10-05'), isTrue);
    expect(back, findsNothing);
  });
}
