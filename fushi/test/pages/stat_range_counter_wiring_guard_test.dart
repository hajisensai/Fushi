import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';
import 'package:fushi/src/pages/implementations/stat_range_bar.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/stats/stat_range.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/source_guard.dart';

/// UI 恢复不能只恢复固定时段卡、却丢掉所选历史 / 自定义范围的收藏计数。
/// 除真实页面接线外，也验证历史自定义范围的四项计数和手机宽渲染。
void main() {
  const Map<String, String> pages = <String, String>{
    'statistics_center_page.dart': 'source',
    'reading_statistics_page.dart': 'StatSourceKind.book',
    'video_statistics_page.dart': 'StatSourceKind.video',
    'game_statistics_page.dart': 'StatSourceKind.game',
  };

  for (final MapEntry<String, String> page in pages.entries) {
    test('${page.key}：所选范围接四项事件并按当前媒体域过滤', () {
      final String source = maskCommentsAndStrings(
        File('lib/src/pages/implementations/${page.key}').readAsStringSync(),
      );
      // 必须是范围卡里的实际调用，不接受字段声明 / 注释 / 固定时段卡代替。
      expect(
        source,
        matches(
          RegExp(
            r'buildStatRangeSummary\(\s*context,\s*range,\s*_byDay,\s*'
            r'extraLines:\s*(?:<StatSummaryLine>\[[\s\S]*?\.\.\.)?'
            r'buildStatRangeCounterLines\('
            r'\s*range,\s*lookups:\s*_lookupEvents,\s*'
            r'mined:\s*_minedEvents,\s*favorited:\s*_favoritedEvents,\s*'
            r'favoritedSentences:\s*_favoritedSentenceEvents,?\s*\)',
          ),
        ),
        reason: '所选范围必须把同一 range 和四个事件流传入共享计数 helper',
      );
      for (final (String field, String getter) in <(String, String)>[
        ('_lookupEvents', 'lookupEvents'),
        ('_minedEvents', 'minedEvents'),
        ('_favoritedEvents', 'favoriteWordEvents'),
        ('_favoritedSentenceEvents', 'favoriteSentenceEvents'),
      ]) {
        expect(
          source,
          matches(
            RegExp(
              '${RegExp.escape(field)}\\s*=\\s*'
              '(?:counterFacts|_counters)\\s*\\.\\s*'
              '${RegExp.escape(getter)}\\(\\s*source:\\s*'
              '${RegExp.escape(page.value)}\\s*,?\\s*\\)'
              '\\s*\\.\\s*toList\\(\\s*\\)',
            ),
          ),
          reason: '$field 必须来自同一份 StatCounterFacts，且不能混入其他域',
        );
      }
      expect(source, contains('includeCounters: true'));
      expect(source, contains('facts.counters'));
      if (page.value == 'source') {
        expect(
          source,
          matches(
            RegExp(
              r'final\s+StatSourceKind\?\s+source\s*=\s*_filter\.source\s*;',
            ),
          ),
          reason: '总览的事件流必须跟随媒体筛选；全部档 source 为 null',
        );
      }
      for (final String dao in <String>[
        'getMiningStatisticsBySource(',
        'getLookupMiningCountersBySource(',
        'getFavoriteWordsBySource(',
        'FavoriteSentenceRepository(',
      ]) {
        expect(source, isNot(contains(dao)), reason: '不能为范围卡新增独立计数读取');
      }
    });
  }

  testWidgets('历史自定义范围：四项计数包含起止日、排除边界外，390 宽不溢出', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.en);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);
    final StatRange range = StatRange.resolve(
      const StatRangeSelection.custom(
        fromKey: '2026-05-03',
        toKey: '2026-05-12',
      ),
      todayKey: '2026-10-10',
      earliestKey: '2026-01-01',
    );
    // 两端的超大计数会让任何边界回归立即可见；四个事件流用不同数值防串线。
    List<(String, int)> events(int first, int last) => <(String, int)>[
      ('2026-05-02', 10000),
      ('2026-05-03', first),
      ('2026-05-12', last),
      ('2026-05-13', 20000),
      ('2026-10-10', 30000),
    ];
    final List<StatSummaryLine> lines = buildStatRangeCounterLines(
      range,
      lookups: events(5, 6),
      mined: events(10, 12),
      favorited: events(15, 18),
      favoritedSentences: events(20, 24),
    );
    expect(lines.map((StatSummaryLine line) => line.value), <String>[
      '11',
      '22',
      '33',
      '44',
    ]);
    expect(lines.map((StatSummaryLine line) => line.label), <String>[
      t.stat_lookup,
      t.stat_mined,
      t.stat_favorited,
      t.stat_favorited_sentence,
    ]);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ListView(
                children: <Widget>[
                  buildStatRangeSummary(
                    context,
                    range,
                    const <String, StatDayData>{},
                    extraLines: lines,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final StatSummaryLine line in lines) {
      expect(find.text(line.label!), findsOneWidget);
      expect(find.text(line.value), findsOneWidget);
    }
    expect(find.text(formatStatRange(range)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
