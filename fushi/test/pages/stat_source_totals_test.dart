import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_source_totals.dart';
import 'package:fushi/src/stats/stat_facts.dart';

/// 守卫统计口径的来源拆分（用户要求「把游戏、漫画等加上支持」）：阅读统计页此前
/// 只读 `reading_statistics`，视频字幕字数与游戏文本字数根本没进来，漫画又混在
/// 「阅读」里且没有页数维度。这里锁定四来源的拆分、窗口求和与活跃日并集。
///
/// v92：输入是统一事实面 [StatFact]（legacy 行与 study_segments 同形），来源按
/// mediaKind / format 判定，不再靠 title→format 反查表。
StatFact _fact(
  String kind,
  String dateKey, {
  String key = 'k',
  String title = '',
  String format = '',
  int chars = 0,
  int ms = 0,
  int pages = 0,
}) => StatFact(
  mediaKind: kind,
  mediaKey: key,
  title: title,
  format: format,
  dateKey: dateKey,
  hour: -1,
  ms: ms,
  chars: chars,
  pages: pages,
  lastActiveMs: 0,
);

void main() {
  final List<StatFact> daily = <StatFact>[
    _fact(
      'book',
      '2026-07-27',
      title: '小説',
      format: 'epub',
      chars: 1000,
      ms: 600000,
    ),
    _fact(
      'book',
      '2026-07-27',
      title: '漫画A',
      format: 'manga',
      chars: 300,
      ms: 300000,
      pages: 20,
    ),
    _fact(
      'book',
      '2026-07-28',
      title: '漫画A',
      format: 'manga',
      chars: 150,
      ms: 120000,
      pages: 9,
    ),
    _fact('video', '2026-07-28', chars: 500, ms: 1800000),
    _fact('game', '2026-07-26', chars: 2000),
    _fact('game', '2026-07-26', ms: 3600000),
  ];

  group('aggregateStatSourceDaily', () {
    test('漫画按 format 从阅读里拆出来，页数只落在漫画', () {
      final Map<StatBreakdownSource, Map<String, StatSourceTotals>> out =
          aggregateStatSourceDaily(daily);

      expect(out[StatBreakdownSource.book]!['2026-07-27']!.chars, 1000);
      expect(out[StatBreakdownSource.book]!['2026-07-27']!.pages, 0);
      expect(out[StatBreakdownSource.manga]!['2026-07-27']!.chars, 300);
      expect(out[StatBreakdownSource.manga]!['2026-07-27']!.pages, 20);
    });

    test('视频带字幕字数与观看时长；游戏的字数行与时长行各自累加、互不双计', () {
      final Map<StatBreakdownSource, Map<String, StatSourceTotals>> out =
          aggregateStatSourceDaily(daily);

      final StatSourceTotals v = out[StatBreakdownSource.video]!['2026-07-28']!;
      expect(v.chars, 500);
      expect(v.timeMs, 1800000);

      final StatSourceTotals g = out[StatBreakdownSource.game]!['2026-07-26']!;
      expect(g.chars, 2000);
      expect(g.timeMs, 3600000);
    });

    test('legacy 行反查不到书（format 空）归阅读，不靠 pages 猜身份', () {
      final Map<StatBreakdownSource, Map<String, StatSourceTotals>> out =
          aggregateStatSourceDaily(<StatFact>[
            _fact(
              'book',
              '2026-07-28',
              key: '',
              title: '已删的书',
              chars: 42,
              pages: 3,
            ),
          ]);

      expect(out[StatBreakdownSource.book]!['2026-07-28']!.chars, 42);
      expect(out[StatBreakdownSource.manga], isEmpty);
    });
  });

  group('窗口合计与活跃日', () {
    final Map<StatBreakdownSource, Map<String, StatSourceTotals>> out =
        aggregateStatSourceDaily(daily);

    test('全部来源合计', () {
      final StatSourceTotals all = sumAllStatSources(out, (String _) => true);
      expect(all.chars, 1000 + 300 + 150 + 500 + 2000);
      expect(all.timeMs, 600000 + 300000 + 120000 + 1800000 + 3600000);
      expect(all.pages, 29);
    });

    test('单日窗口只算当天', () {
      final StatSourceTotals today = sumAllStatSources(
        out,
        (String d) => d == '2026-07-28',
      );
      expect(today.chars, 150 + 500);
      expect(today.pages, 9);
    });

    test('活跃日是四来源并集：只看视频/只玩游戏的那天也算', () {
      expect(allStatSourceDateKeys(out), <String>{
        '2026-07-26',
        '2026-07-27',
        '2026-07-28',
      });
    });

    test('全零行不算活跃日', () {
      final Map<StatBreakdownSource, Map<String, StatSourceTotals>> empty =
          aggregateStatSourceDaily(<StatFact>[
            _fact('book', '2026-01-01', title: '书'),
          ]);
      expect(allStatSourceDateKeys(empty), isEmpty);
    });
  });

  group('readingGoalCharsForDay（首页目标与阅读统计页同源）', () {
    test('只算阅读域（普通书 + 漫画）当日字数，字幕字 / hook 字不进分子', () {
      expect(readingGoalCharsForDay(daily, '2026-07-27'), 1000 + 300);
      expect(
        readingGoalCharsForDay(daily, '2026-07-28'),
        150,
        reason: '同日 500 字幕字不计',
      );
      expect(
        readingGoalCharsForDay(daily, '2026-07-26'),
        0,
        reason: '只有游戏 hook 字的日子 = 0',
      );
    });
  });
}
