import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_period_detail_sheet.dart';
import 'package:fushi/src/pages/implementations/stat_range_bar.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/stats/stat_range.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:material_ui/material_ui.dart';

/// 2026-10-09 统计中心精简删掉「时段明细」卡后，按时段 / 按作品的明细在统计
/// 中心补回一个入口：范围条行尾齿轮旁的「明细」按钮（[StatRangeActions]）。
///  * 两颗按钮同在范围条行尾，齿轮位置不动；
///  * 打开的是原来那张 sheet，时段 = 范围条当前所选区间（四个 tab 都传
///    `range.contains` + `formatStatRange(range)`，见 statistics_center_static_test）；
///  * 「周」是自然周（周一起）：上周日的行不进，滚动 7 天窗口会把它算进来。
StatFact _fact(String dateKey, String title, {int ms = 600000}) => StatFact(
  mediaKind: kActivityMediaBook,
  mediaKey: 'k-$title',
  title: title,
  format: '',
  dateKey: dateKey,
  hour: -1,
  ms: ms,
  chars: 100,
  pages: 0,
  lastActiveMs: 0,
);

// 2026-10-07 是周三：自然周 = 10-05（周一）~ 今日。
const String _today = '2026-10-07';
final List<StatFact> _facts = <StatFact>[
  _fact('2026-10-04', '上周日的书'),
  _fact('2026-10-05', '周一的书'),
  _fact('2026-10-07', '今天的书'),
  _fact('2026-09-30', '上月的书'),
];

Future<void> _pumpBar(
  WidgetTester tester,
  StatRangeSelection selection, {
  double width = 390,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                final StatRange range = StatRange.resolve(
                  selection,
                  todayKey: _today,
                  earliestKey: '2026-09-01',
                );
                // 与四个统计 tab 的 `_showRangeDetail(range)` 同一组入参。
                return StatRangeBar(
                  range: range,
                  onChanged: (_) {},
                  trailing: StatRangeActions(
                    onOpenDetail: () => unawaited(
                      showStatPeriodDetailSheet(
                        context,
                        periodLabel: formatStatRange(range),
                        contains: range.contains,
                        facts: _facts,
                        resolvers: StatPeriodDetailResolvers(
                          titleOf: (StatFact f) => f.title,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('恢复页头后仍保留范围明细入口，手机宽不溢出', (WidgetTester tester) async {
    await _pumpBar(tester, const StatRangeSelection(mode: StatRangeMode.week));
    final Finder detail = find.byKey(
      const ValueKey<String>('stat-range-detail-button'),
    );
    final Finder gear = find.byKey(
      const ValueKey<String>('stat-settings-button'),
    );
    expect(detail, findsOneWidget);
    expect(gear, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('周：打开所选自然周的明细，上周日 / 上月的行不进', (WidgetTester tester) async {
    await _pumpBar(tester, const StatRangeSelection(mode: StatRangeMode.week));
    await tester.tap(
      find.byKey(const ValueKey<String>('stat-range-detail-button')),
    );
    await tester.pumpAndSettle();
    final StatRange week = StatRange.resolve(
      const StatRangeSelection(mode: StatRangeMode.week),
      todayKey: _today,
    );
    expect(week.fromKey, '2026-10-05');
    expect(find.text(formatStatRange(week)), findsWidgets);
    expect(find.text('周一的书'), findsOneWidget);
    expect(find.text('今天的书'), findsOneWidget);
    expect(find.text('上周日的书'), findsNothing, reason: '自然周从周一算起');
    expect(find.text('上月的书'), findsNothing);
  });

  testWidgets('日：明细跟着范围条当前所选那一天', (WidgetTester tester) async {
    await _pumpBar(
      tester,
      const StatRangeSelection(
        mode: StatRangeMode.day,
        anchorKey: '2026-10-04',
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('stat-range-detail-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('上周日的书'), findsOneWidget);
    expect(find.text('周一的书'), findsNothing);
  });

  testWidgets('月：明细是整个自然月（到今日为止）', (WidgetTester tester) async {
    await _pumpBar(tester, const StatRangeSelection(mode: StatRangeMode.month));
    await tester.tap(
      find.byKey(const ValueKey<String>('stat-range-detail-button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('上周日的书'), findsOneWidget);
    expect(find.text('周一的书'), findsOneWidget);
    expect(find.text('今天的书'), findsOneWidget);
    expect(find.text('上月的书'), findsNothing);
  });
}
