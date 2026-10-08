import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_range_bar.dart';
import 'package:fushi/src/stats/stat_range.dart';

// 统计中心的范围（对齐 Niratan 年 / 月 / 周 / 日 + 全部）：此前每个统计 tab 的
// 图表都写死 `lastDayKeys(30)`，数据其实是全量历史、只是展示层截成近 30 天。
// 这里锁定区间解析、翻段、夹到今日、图表按跨度换粒度这几条契约。

StatRange _resolve(
  StatRangeMode mode, {
  String? anchor,
  String today = '2026-09-28',
  String? earliest = '2025-03-10',
}) => StatRange.resolve(
  StatRangeSelection(mode: mode, anchorKey: anchor),
  todayKey: today,
  earliestKey: earliest,
);

void main() {
  group('StatRange.resolve', () {
    test('日：锚点那一天；缺省锚点 = 今日', () {
      final StatRange r = _resolve(StatRangeMode.day);
      expect(r.fromKey, '2026-09-28');
      expect(r.toKey, '2026-09-28');
      expect(r.dayCount, 1);
    });

    test('周：周一起，本周只算到今日（不含未来日）', () {
      // 2026-09-28 是周一。
      final StatRange r = _resolve(StatRangeMode.week, anchor: '2026-09-24');
      expect(r.fromKey, '2026-09-21');
      expect(r.toKey, '2026-09-27');
      final StatRange cur = _resolve(StatRangeMode.week);
      expect(cur.fromKey, '2026-09-28');
      expect(cur.toKey, '2026-09-28');
    });

    test('月 / 年：自然月 / 自然年，当期夹到今日', () {
      final StatRange feb = _resolve(StatRangeMode.month, anchor: '2024-02-10');
      expect(feb.fromKey, '2024-02-01');
      expect(feb.toKey, '2024-02-29');
      final StatRange month = _resolve(StatRangeMode.month);
      expect(month.fromKey, '2026-09-01');
      expect(month.toKey, '2026-09-28');
      final StatRange year = _resolve(StatRangeMode.year, anchor: '2025-06-01');
      expect(year.fromKey, '2025-01-01');
      expect(year.toKey, '2025-12-31');
      expect(_resolve(StatRangeMode.year).toKey, '2026-09-28');
    });

    test('全部：该域最早有数据的一天 ~ 今日；无数据退化成今日', () {
      final StatRange all = _resolve(StatRangeMode.all);
      expect(all.fromKey, '2025-03-10');
      expect(all.toKey, '2026-09-28');
      final StatRange empty = _resolve(StatRangeMode.all, earliest: null);
      expect(empty.fromKey, '2026-09-28');
      expect(all.canGoPrevious, isFalse);
      expect(all.canGoNext, isFalse);
    });

    test('未来锚点夹回今日', () {
      final StatRange r = _resolve(StatRangeMode.day, anchor: '2027-01-01');
      expect(r.fromKey, '2026-09-28');
    });

    test('contains 是闭区间', () {
      final StatRange r = _resolve(StatRangeMode.month, anchor: '2026-08-15');
      expect(r.contains('2026-08-01'), isTrue);
      expect(r.contains('2026-08-31'), isTrue);
      expect(r.contains('2026-07-31'), isFalse);
      expect(r.contains('2026-09-01'), isFalse);
    });
  });

  group('StatRange.shifted', () {
    test('上一段 / 下一段：月跨年、翻回当期恢复「跟随今日」', () {
      final StatRange jan = _resolve(StatRangeMode.month, anchor: '2026-01-20');
      final StatRange dec = StatRange.resolve(
        jan.shifted(-1),
        todayKey: '2026-09-28',
        earliestKey: '2025-03-10',
      );
      expect(dec.fromKey, '2025-12-01');
      expect(dec.toKey, '2025-12-31');

      final StatRange aug = _resolve(StatRangeMode.month, anchor: '2026-08-03');
      final StatRangeSelection next = aug.shifted(1);
      expect(next.anchorKey, isNull, reason: '回到含今日的当期 = 跟随今日');
      expect(next.mode, StatRangeMode.month);
    });

    test('当期不能再往后；早于最早数据不能再往前', () {
      expect(_resolve(StatRangeMode.week).canGoNext, isFalse);
      expect(
        _resolve(StatRangeMode.week, anchor: '2026-09-01').canGoNext,
        isTrue,
      );
      expect(
        _resolve(StatRangeMode.month, anchor: '2025-03-20').canGoPrevious,
        isFalse,
      );
      expect(
        _resolve(StatRangeMode.month, anchor: '2025-04-20').canGoPrevious,
        isTrue,
      );
    });

    test('周翻段按 7 天走', () {
      final StatRange w = _resolve(StatRangeMode.week, anchor: '2026-09-24');
      final StatRange prev = StatRange.resolve(
        w.shifted(-1),
        todayKey: '2026-09-28',
        earliestKey: '2025-03-10',
      );
      expect(prev.fromKey, '2026-09-14');
      expect(prev.toKey, '2026-09-20');
    });
  });

  group('buildStatRangeChartData', () {
    Map<String, StatDayData> days(Map<String, int> msByDay) =>
        <String, StatDayData>{
          for (final MapEntry<String, int> e in msByDay.entries)
            e.key: StatDayData(dateKey: e.key)..ms = e.value,
        };

    test('≤ 62 天逐日，空日补 0', () {
      final StatRange r = _resolve(StatRangeMode.month, anchor: '2026-08-10');
      final List<StatDayData> data = buildStatRangeChartData(
        days(<String, int>{'2026-08-02': 60000, '2026-07-31': 99}),
        r,
      );
      expect(data.length, 31);
      expect(data.first.dateKey, '2026-08-01');
      expect(data[1].ms, 60000);
      expect(data.fold<int>(0, (int s, StatDayData d) => s + d.ms), 60000);
    });

    test('一年按周（周一为桶键），全部历史按月', () {
      final StatRange year = _resolve(StatRangeMode.year, anchor: '2025-05-01');
      final List<StatDayData> weekly = buildStatRangeChartData(
        days(<String, int>{'2025-05-05': 1000, '2025-05-11': 2000}),
        year,
      );
      expect(year.chartGrain, StatRangeChartGrain.week);
      final StatDayData bucket = weekly.firstWhere(
        (StatDayData d) => d.dateKey == '2025-05-05',
      );
      expect(bucket.ms, 3000, reason: '周一与周日同一桶');
      expect(bucket.label, '05-05');

      final StatRange all = _resolve(StatRangeMode.all);
      final List<StatDayData> monthly = buildStatRangeChartData(
        days(<String, int>{'2025-03-10': 5, '2025-03-31': 6, '2026-09-28': 7}),
        all,
      );
      expect(all.chartGrain, StatRangeChartGrain.month);
      expect(monthly.first.dateKey, '2025-03');
      expect(monthly.first.ms, 11);
      expect(monthly.last.dateKey, '2026-09');
      expect(monthly.length, 19);
    });
  });

  test('sumStatEventsInRange 只算范围内的事件', () {
    final StatRange r = _resolve(StatRangeMode.week, anchor: '2026-09-24');
    expect(
      sumStatEventsInRange(<(String, int)>[
        ('2026-09-20', 1),
        ('2026-09-21', 2),
        ('2026-09-27', 3),
        ('2026-09-28', 4),
      ], r),
      5,
    );
  });

  testWidgets('范围条：切粒度保留锚点、上一段翻页、当期「下一段」禁用', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.en);
    StatRangeSelection selection = const StatRangeSelection(
      mode: StatRangeMode.month,
      anchorKey: '2026-05-12',
    );
    Future<void> pump() => tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) =>
                  StatRangeBar(
                    range: StatRange.resolve(
                      selection,
                      todayKey: '2026-09-28',
                      earliestKey: '2025-03-10',
                    ),
                    onChanged: (StatRangeSelection s) =>
                        setState(() => selection = s),
                  ),
            ),
          ),
        ),
      ),
    );
    await pump();
    expect(find.text('2026-05'), findsOneWidget);

    await tester.tap(find.text(t.stat_range_mode_week));
    await tester.pumpAndSettle();
    expect(selection.mode, StatRangeMode.week);
    expect(selection.anchorKey, '2026-05-12', reason: '换粒度落在同一段时间里');
    expect(find.text('05-11 ~ 05-17'), findsOneWidget);

    await tester.tap(find.byTooltip(t.stat_range_previous));
    await tester.pumpAndSettle();
    expect(find.text('05-04 ~ 05-10'), findsOneWidget);

    selection = const StatRangeSelection(mode: StatRangeMode.year);
    await pump();
    await tester.pumpAndSettle();
    expect(find.text('2026'), findsOneWidget);
    await tester.tap(find.byTooltip(t.stat_range_next));
    await tester.pumpAndSettle();
    expect(find.text('2026'), findsOneWidget, reason: '当期不能翻到未来');
  });

  // 2026-10 体验优化：学习日历点某天会把范围切到单日，范围条要给一个显眼的
  // 「本月」快捷入口一步回到当月（此前要先点「月」再连按箭头）。
  testWidgets('范围条：单日态给出「本月」快捷入口，点了回到当月', (
    WidgetTester tester,
  ) async {
    LocaleSettings.setLocale(AppLocale.en);
    StatRangeSelection selection = const StatRangeSelection(
      mode: StatRangeMode.day,
      anchorKey: '2026-05-12',
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) =>
                  StatRangeBar(
                    range: StatRange.resolve(
                      selection,
                      todayKey: '2026-09-28',
                      earliestKey: '2025-03-10',
                    ),
                    onChanged: (StatRangeSelection s) =>
                        setState(() => selection = s),
                  ),
            ),
          ),
        ),
      ),
    );
    final Finder back =
        find.byKey(const ValueKey<String>('stat-range-back-to-month'));
    expect(back, findsOneWidget);
    expect(find.text(t.stat_this_month), findsOneWidget);

    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(selection.mode, StatRangeMode.month);
    expect(selection.anchorKey, isNull, reason: '回到「本月」= 锚点跟随今日');
    expect(find.text('2026-09'), findsOneWidget);
    // 非单日态不出现该入口。
    expect(back, findsNothing);
  });

  test('formatStatRange 各粒度文字', () {
    expect(formatStatRange(_resolve(StatRangeMode.day)), '2026-09-28');
    expect(
      formatStatRange(_resolve(StatRangeMode.week, anchor: '2026-09-24')),
      '09-21 ~ 09-27',
    );
    expect(formatStatRange(_resolve(StatRangeMode.month)), '2026-09');
    expect(formatStatRange(_resolve(StatRangeMode.year)), '2026');
    expect(
      formatStatRange(_resolve(StatRangeMode.all)),
      '2025-03-10 ~ 2026-09-28',
    );
  });

  // BUG-2777：周翻段曾给本地午夜加 `Duration(days: 7 * step)`，dayCount 曾用两个
  // 本地午夜相减取 `inDays`。DST 切换周不是 168 小时：秋季回拨周「下一段」落回
  // 本周六 23:00（翻不动），春季拨快周「上一段」落到前前周周日 23:00（多跳一周），
  // 含春季切换日的区间 dayCount 少一天。下面的日期覆盖欧盟 / 美国 2026 年四个切换
  // 周：在有 DST 的宿主时区上直接复现旧行为；UTC 宿主上旧代码不出错，所以另加
  // 纯键算术断言与源码守卫，保证任何宿主时区都能拦住同类回归。
  group('BUG-2777 DST 切换周翻段 / 日数', () {
    StatRange week(String anchor) => StatRange.resolve(
      StatRangeSelection(mode: StatRangeMode.week, anchorKey: anchor),
      todayKey: '2026-12-31',
      earliestKey: '2020-01-01',
    );

    StatRange resolveSel(StatRangeSelection sel) => StatRange.resolve(
      sel,
      todayKey: '2026-12-31',
      earliestKey: '2020-01-01',
    );

    test('秋季回拨周（EU 10-25 / US 11-01）「下一段」进到下一周', () {
      final StatRange eu = week('2026-10-21');
      expect(eu.fromKey, '2026-10-19');
      expect(eu.toKey, '2026-10-25');
      final StatRange euNext = resolveSel(eu.shifted(1));
      expect(euNext.fromKey, '2026-10-26');
      expect(euNext.toKey, '2026-11-01');

      final StatRange us = week('2026-10-28');
      expect(us.toKey, '2026-11-01');
      final StatRange usNext = resolveSel(us.shifted(1));
      expect(usNext.fromKey, '2026-11-02');
      expect(usNext.toKey, '2026-11-08');
    });

    test('春季拨快周（EU 03-29 / US 03-08）「上一段」只退一周', () {
      final StatRange euPrev = resolveSel(week('2026-03-31').shifted(-1));
      expect(euPrev.fromKey, '2026-03-23');
      expect(euPrev.toKey, '2026-03-29');
      final StatRange euPrev2 = resolveSel(euPrev.shifted(-1));
      expect(euPrev2.fromKey, '2026-03-16');

      final StatRange usPrev = resolveSel(week('2026-03-10').shifted(-1));
      expect(usPrev.fromKey, '2026-03-02');
      expect(usPrev.toKey, '2026-03-08');
      final StatRange usPrev2 = resolveSel(usPrev.shifted(-1));
      expect(usPrev2.fromKey, '2026-02-23');
    });

    test('含切换日的区间 dayCount / dayKeys 不少一天', () {
      final StatRange springWeek = week('2026-03-25');
      expect(springWeek.dayCount, 7);
      expect(springWeek.dayKeys.last, '2026-03-29');
      final StatRange fallWeek = week('2026-10-21');
      expect(fallWeek.dayCount, 7);
      final StatRange march = resolveSel(
        const StatRangeSelection(
          mode: StatRangeMode.month,
          anchorKey: '2026-03-15',
        ),
      );
      expect(march.dayCount, 31);
      expect(march.dayKeys.last, '2026-03-31');
      final StatRange year = resolveSel(
        const StatRangeSelection(
          mode: StatRangeMode.year,
          anchorKey: '2025-06-01',
        ),
      );
      expect(year.dayCount, 365);
    });

    test('statDateKeyDaysBetween 只看日历日（跨 DST / 闰年 / 反向）', () {
      expect(statDateKeyDaysBetween('2026-03-23', '2026-03-30'), 7);
      expect(statDateKeyDaysBetween('2026-03-01', '2026-03-31'), 30);
      expect(statDateKeyDaysBetween('2026-10-19', '2026-10-26'), 7);
      expect(statDateKeyDaysBetween('2024-02-28', '2024-03-01'), 2);
      expect(statDateKeyDaysBetween('2026-11-02', '2026-10-26'), -7);
      expect(statDateKeyDaysBetween('2026-09-28', '2026-09-28'), 0);
    });

    test('源码守卫：stat_range.dart 不给本地时刻加减 Duration 做日期算术', () {
      final String src = File(
        'lib/src/stats/stat_range.dart',
      ).readAsStringSync();
      expect(
        RegExp(r'Duration\(\s*days').hasMatch(src),
        isFalse,
        reason: '日期翻段必须走 dateKey 日历算术（statDateKeyPlusDays）',
      );
      // `.inDays` 只允许出现在 UTC 日历差 helper 里。
      expect(RegExp(r'\.inDays').allMatches(src).length, 1);
      final int helper = src.indexOf('int statDateKeyDaysBetween(');
      expect(helper, isNonNegative);
      final String helperBody = src.substring(
        helper,
        src.indexOf('\n}', helper),
      );
      expect(helperBody, contains('DateTime.utc('));
      expect(helperBody, contains('.inDays'));
    });
  });
}
