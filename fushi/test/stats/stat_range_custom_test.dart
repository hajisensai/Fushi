import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_range_bar.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/stats/stat_range.dart';
import 'package:fushi_core/fushi_core.dart';

// 统计中心「自定义区间」：用户任选起止日（都含），范围区块（图表 / 所选范围卡 /
// 按媒体等）全部跟随。区间仍由 [StatRange] 一处解析，不另造取数路径。

const String _today = '2026-09-28';
const String _earliest = '2025-03-10';

StatRange _custom(String from, String to, {String today = _today}) =>
    StatRange.resolve(
      StatRangeSelection.custom(fromKey: from, toKey: to),
      todayKey: today,
      earliestKey: _earliest,
    );

StatRange _resolve(StatRangeSelection s) =>
    StatRange.resolve(s, todayKey: _today, earliestKey: _earliest);

void main() {
  group('StatRange 自定义区间', () {
    test('起止都含；contains 是闭区间', () {
      final StatRange r = _custom('2026-05-03', '2026-05-12');
      expect(r.mode, StatRangeMode.custom);
      expect(r.fromKey, '2026-05-03');
      expect(r.toKey, '2026-05-12');
      expect(r.dayCount, 10);
      expect(r.contains('2026-05-03'), isTrue, reason: '起点当天含');
      expect(r.contains('2026-05-12'), isTrue, reason: '终点当天含');
      expect(r.contains('2026-05-02'), isFalse);
      expect(r.contains('2026-05-13'), isFalse);
      expect(r.dayKeys.first, '2026-05-03');
      expect(r.dayKeys.last, '2026-05-12');
    });

    test('单日区间 = 那一天', () {
      final StatRange r = _custom('2026-06-01', '2026-06-01');
      expect(r.dayCount, 1);
      expect(formatStatRange(r), '2026-06-01');
    });

    test('起止颠倒时摆正；越过今日的部分夹回今日', () {
      final StatRange swapped = _custom('2026-05-12', '2026-05-03');
      expect(swapped.fromKey, '2026-05-03');
      expect(swapped.toKey, '2026-05-12');

      final StatRange future = _custom('2026-09-20', '2026-12-31');
      expect(future.fromKey, '2026-09-20');
      expect(future.toKey, _today);
      expect(future.canGoNext, isFalse);

      final StatRange allFuture = _custom('2027-01-01', '2027-02-01');
      expect(allFuture.fromKey, _today);
      expect(allFuture.toKey, _today);
    });

    test('可早于该域最早数据日（不夹到 earliest），但不能再往前翻', () {
      final StatRange r = _custom('2024-01-01', '2024-12-31');
      expect(r.fromKey, '2024-01-01');
      expect(r.canGoPrevious, isFalse);
      expect(r.canGoNext, isTrue);
    });

    test('前后翻段按自身天数整段平移，往后越过今日时贴住今日、天数不变', () {
      final StatRange r = _custom('2026-05-03', '2026-05-12');
      final StatRange prev = _resolve(r.shifted(-1));
      expect(prev.mode, StatRangeMode.custom);
      expect(prev.fromKey, '2026-04-23');
      expect(prev.toKey, '2026-05-02');
      final StatRange next = _resolve(r.shifted(1));
      expect(next.fromKey, '2026-05-13');
      expect(next.toKey, '2026-05-22');

      final StatRange nearToday = _custom('2026-09-15', '2026-09-24');
      final StatRange clamped = _resolve(nearToday.shifted(1));
      expect(clamped.toKey, _today);
      expect(clamped.fromKey, '2026-09-19');
      expect(clamped.dayCount, 10);
    });

    test('切回日 / 周 / 月时锚点 = 自定义区间的终点', () {
      final StatRange r = _custom('2026-03-01', '2026-05-12');
      expect(r.anchorKey, '2026-05-12');
    });

    test('大区间图表自动聚合：≤ 62 天逐日、≤ 400 天按周、数年按月', () {
      Map<String, StatDayData> days(Map<String, int> ms) =>
          <String, StatDayData>{
            for (final MapEntry<String, int> e in ms.entries)
              e.key: StatDayData(dateKey: e.key)..ms = e.value,
          };
      final StatRange twoMonths = _custom('2026-07-01', '2026-08-31');
      expect(twoMonths.chartGrain, StatRangeChartGrain.day);
      final StatRange halfYear = _custom('2026-01-01', '2026-06-30');
      expect(halfYear.chartGrain, StatRangeChartGrain.week);
      // 2026-01-01 是周四：首个周桶键是上周一，标签夹到区间起点。
      final List<StatDayData> weekly = buildStatRangeChartData(
        days(<String, int>{'2026-01-02': 5}),
        halfYear,
      );
      expect(weekly.first.dateKey, '2025-12-29');
      expect(weekly.first.label, '01-01');
      expect(weekly.first.ms, 5);

      final StatRange years = _custom('2023-01-15', '2026-09-28');
      expect(years.chartGrain, StatRangeChartGrain.month);
      final List<StatDayData> monthly = buildStatRangeChartData(
        days(<String, int>{
          '2023-01-14': 999, // 区间外，不计
          '2023-01-15': 1,
          '2023-01-31': 2,
          '2026-09-28': 3,
        }),
        years,
      );
      expect(monthly.first.dateKey, '2023-01');
      expect(monthly.first.ms, 3);
      expect(monthly.last.dateKey, '2026-09');
      expect(monthly.last.ms, 3);
      expect(monthly.length, 45);
    });

    test('跨午夜按写入时的统计日取舍：重置 = 4 时，凌晨 2 点的段算前一天', () {
      final int saved = FushiDatabase.statDayResetHour;
      addTearDown(() => FushiDatabase.statDayResetHour = saved);
      FushiDatabase.statDayResetHour = 4;
      // 9 月 10 日凌晨 2 点读的书记在 09-09。
      final String lateNight = FushiDatabase.statDateKeyOf(
        DateTime(2026, 9, 10, 2),
      );
      final String morning = FushiDatabase.statDateKeyOf(
        DateTime(2026, 9, 10, 5),
      );
      expect(lateNight, '2026-09-09');
      expect(morning, '2026-09-10');

      final StatRange upTo9 = _custom('2026-09-01', '2026-09-09');
      expect(upTo9.contains(lateNight), isTrue, reason: '终点当天的跨午夜尾巴含');
      expect(upTo9.contains(morning), isFalse);
      final StatRange from10 = _custom('2026-09-10', '2026-09-20');
      expect(from10.contains(lateNight), isFalse);
      expect(from10.contains(morning), isTrue);
    });

    test('formatStatRange：自定义区间显示完整起止', () {
      expect(
        formatStatRange(_custom('2026-05-03', '2026-05-12')),
        '2026-05-03 ~ 2026-05-12',
      );
    });

    test('选择值相等性带上起止', () {
      expect(
        const StatRangeSelection.custom(fromKey: 'a', toKey: 'b'),
        const StatRangeSelection.custom(fromKey: 'a', toKey: 'b'),
      );
      expect(
        const StatRangeSelection.custom(fromKey: 'a', toKey: 'b') ==
            const StatRangeSelection.custom(fromKey: 'a', toKey: 'c'),
        isFalse,
      );
    });
  });

  group('范围条「自定义」', () {
    setUp(() => LocaleSettings.setLocale(AppLocale.en));

    // 与三个域 tab / 总览同一组合：范围条 → 范围时长图 → 所选范围卡，都吃同一个
    // 解析后的 [StatRange] 与同一份日面汇总。
    final Map<String, StatDayData> byDay = <String, StatDayData>{
      '2026-05-02': StatDayData(dateKey: '2026-05-02')
        ..ms = 7 * 3600000
        ..chars = 7000,
      '2026-05-03': StatDayData(dateKey: '2026-05-03')
        ..ms = 3600000
        ..chars = 1000,
      '2026-05-10': StatDayData(dateKey: '2026-05-10')
        ..ms = 2 * 3600000
        ..chars = 2000,
      '2026-05-11': StatDayData(dateKey: '2026-05-11')
        ..ms = 5 * 3600000
        ..chars = 5000,
      '2026-09-28': StatDayData(dateKey: '2026-09-28')
        ..ms = 11 * 3600000
        ..chars = 11000,
    };

    Future<ValueGetter<StatRangeSelection>> pumpBar(
      WidgetTester tester,
      StatRangeSelection initial, {
      Size size = const Size(900, 1400),
      double textScale = 1,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      StatRangeSelection selection = initial;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  final StatRange range = _resolve(selection);
                  return ListView(
                    children: <Widget>[
                      StatRangeBar(
                        range: range,
                        onChanged: (StatRangeSelection s) =>
                            setState(() => selection = s),
                      ),
                      buildStatRangeChartSection(context, range, byDay),
                      buildStatRangeSummary(context, range, byDay),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return () => selection;
    }

    Future<void> pickInDialog(
      WidgetTester tester,
      String start,
      String end,
    ) async {
      // 切到输入模式，按 en-US 的 MM/dd/yyyy 填起止。
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      final Finder fields = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), start);
      await tester.enterText(fields.at(1), end);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
    }

    testWidgets('选「自定义」弹日期区间选择器，确认后图表与所选范围卡切到该区间', (WidgetTester tester) async {
      final ValueGetter<StatRangeSelection> current = await pumpBar(
        tester,
        const StatRangeSelection(),
      );
      // 本月（09-01 ~ 09-28）：只有 09-28 的 11 小时。
      expect(find.text('2026-09'), findsWidgets);
      expect(find.text(formatStatTime(11 * 3600000)), findsWidgets);

      await tester.tap(find.byTooltip(t.stat_range_mode_custom));
      await tester.pumpAndSettle();
      expect(find.text(t.stat_range_custom_pick), findsOneWidget);

      await pickInDialog(tester, '05/03/2026', '05/10/2026');

      final StatRangeSelection s = current();
      expect(s.mode, StatRangeMode.custom);
      expect(s.customFromKey, '2026-05-03');
      expect(s.customToKey, '2026-05-10');
      // 区间显示在范围条、图表副标题与所选范围卡上。
      expect(find.text('2026-05-03 ~ 2026-05-10'), findsWidgets);
      // 起止都含：05-03 的 1h + 05-10 的 2h = 3h；05-02 / 05-11 / 09-28 不计。
      expect(find.text(formatStatTime(3 * 3600000)), findsWidgets);
      expect(find.text(formatStatTime(11 * 3600000)), findsNothing);
      expect(find.text(t.stat_format_days(n: 2)), findsOneWidget);
      // 自定义态给出改区间入口。
      expect(
        find.byKey(const ValueKey<String>('stat-range-custom-edit')),
        findsOneWidget,
      );
    });

    testWidgets('编辑跨域共享的旧区间不受当前域最早数据日限制', (WidgetTester tester) async {
      final ValueGetter<StatRangeSelection> current = await pumpBar(
        tester,
        const StatRangeSelection.custom(
          fromKey: '2010-05-03',
          toKey: '2010-05-10',
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('stat-range-custom-edit')),
      );
      await tester.pumpAndSettle();
      final DateRangePickerDialog picker = tester.widget<DateRangePickerDialog>(
        find.byType(DateRangePickerDialog),
      );
      expect(picker.initialDateRange!.start, DateTime(2010, 5, 3));
      expect(picker.initialDateRange!.end, DateTime(2010, 5, 10));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(current().customFromKey, '2010-05-03');
      expect(current().customToKey, '2010-05-10');
    });

    for (final double scale in <double>[1, 1.5]) {
      testWidgets('320dp 窄屏自定义范围无溢出（文字倍率 $scale）', (WidgetTester tester) async {
        await pumpBar(
          tester,
          const StatRangeSelection.custom(
            fromKey: '2026-05-03',
            toKey: '2026-05-10',
          ),
          size: const Size(320, 900),
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        expect(find.byTooltip(t.stat_range_mode_custom), findsOneWidget);
      });
    }

    testWidgets('自定义态点「修改日期区间」或区间文字可重选；取消不改范围', (WidgetTester tester) async {
      final ValueGetter<StatRangeSelection> current = await pumpBar(
        tester,
        const StatRangeSelection.custom(
          fromKey: '2026-05-03',
          toKey: '2026-05-10',
        ),
      );
      expect(find.text(formatStatTime(3 * 3600000)), findsWidgets);

      // 取消：范围不变。
      await tester.tap(
        find.byKey(const ValueKey<String>('stat-range-custom-edit')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close').last);
      await tester.pumpAndSettle();
      expect(current().customFromKey, '2026-05-03');
      expect(current().customToKey, '2026-05-10');

      // 点区间文字重选 05-10 ~ 05-11。
      await tester.tap(
        find.byKey(const ValueKey<String>('stat-range-custom-label')),
      );
      await tester.pumpAndSettle();
      await pickInDialog(tester, '05/10/2026', '05/11/2026');
      expect(current().customFromKey, '2026-05-10');
      expect(current().customToKey, '2026-05-11');
      expect(find.text(formatStatTime(7 * 3600000)), findsWidgets);

      // 上一段：整段平移 2 天 → 05-08 ~ 05-09（无数据）。
      await tester.tap(find.byTooltip(t.stat_range_previous));
      await tester.pumpAndSettle();
      expect(find.text('2026-05-08 ~ 2026-05-09'), findsWidgets);

      // 切回「月」：落在区间终点所在的 5 月。
      await tester.tap(find.text(t.stat_range_mode_month));
      await tester.pumpAndSettle();
      expect(current().mode, StatRangeMode.month);
      expect(find.text('2026-05'), findsWidgets);
      expect(
        find.byKey(const ValueKey<String>('stat-range-custom-edit')),
        findsNothing,
      );
    });
  });
}
