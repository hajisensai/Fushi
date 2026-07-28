import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_source_totals.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 守卫统计口径的来源拆分（用户要求「把游戏、漫画等加上支持」）：阅读统计页此前
/// 只读 `reading_statistics`，视频字幕字数与游戏文本字数根本没进来，漫画又混在
/// 「阅读」里且没有页数维度。这里锁定四来源的拆分、窗口求和与活跃日并集。
ReadingStatisticRow _reading(
  String title,
  String dateKey, {
  int chars = 0,
  int ms = 0,
  int pages = 0,
}) =>
    ReadingStatisticRow(
      id: 0,
      title: title,
      dateKey: dateKey,
      charactersRead: chars,
      readingTimeMs: ms,
      pagesRead: pages,
      lastStatisticModified: 0,
    );

VideoWatchStatisticRow _video(String dateKey, {int chars = 0, int ms = 0}) =>
    VideoWatchStatisticRow(
      id: 0,
      title: 'v',
      dateKey: dateKey,
      subtitleChars: chars,
      watchTimeMs: ms,
      lastModified: 0,
    );

void main() {
  final List<ReadingStatisticRow> reading = <ReadingStatisticRow>[
    _reading('小説', '2026-07-27', chars: 1000, ms: 600000),
    _reading('漫画A', '2026-07-27', chars: 300, ms: 300000, pages: 20),
    _reading('漫画A', '2026-07-28', chars: 150, ms: 120000, pages: 9),
  ];
  final Map<String, String> formats = <String, String>{
    '小説': 'epub',
    '漫画A': 'manga',
  };
  final List<VideoWatchStatisticRow> video = <VideoWatchStatisticRow>[
    _video('2026-07-28', chars: 500, ms: 1800000),
  ];
  final List<(String, int, int)> games = <(String, int, int)>[
    ('2026-07-26', 2000, 3600000),
  ];

  group('aggregateStatSourceDaily', () {
    test('漫画按 epub_books.format 从阅读里拆出来，页数只落在漫画', () {
      final Map<StatBreakdownSource, Map<String, StatSourceTotals>> daily =
          aggregateStatSourceDaily(
        reading: reading,
        formatByTitle: formats,
        video: video,
        gameDaily: games,
      );

      expect(daily[StatBreakdownSource.book]!['2026-07-27']!.chars, 1000);
      expect(daily[StatBreakdownSource.book]!['2026-07-27']!.pages, 0);
      expect(daily[StatBreakdownSource.manga]!['2026-07-27']!.chars, 300);
      expect(daily[StatBreakdownSource.manga]!['2026-07-27']!.pages, 20);
      expect(daily[StatBreakdownSource.book].toString(),
          isNot(contains('漫画')));
    });

    test('视频带字幕字数与观看时长；游戏带文本字数与游玩时长', () {
      final Map<StatBreakdownSource, Map<String, StatSourceTotals>> daily =
          aggregateStatSourceDaily(
        reading: reading,
        formatByTitle: formats,
        video: video,
        gameDaily: games,
      );

      final StatSourceTotals v =
          daily[StatBreakdownSource.video]!['2026-07-28']!;
      expect(v.chars, 500);
      expect(v.timeMs, 1800000);

      final StatSourceTotals g =
          daily[StatBreakdownSource.game]!['2026-07-26']!;
      expect(g.chars, 2000);
      expect(g.timeMs, 3600000);
    });

    test('未知 title（书已删、统计还在）归阅读，不靠 pagesRead 猜身份', () {
      final Map<StatBreakdownSource, Map<String, StatSourceTotals>> daily =
          aggregateStatSourceDaily(
        reading: <ReadingStatisticRow>[
          _reading('已删的书', '2026-07-28', chars: 42, pages: 3),
        ],
        formatByTitle: const <String, String>{},
        video: const <VideoWatchStatisticRow>[],
        gameDaily: const <(String, int, int)>[],
      );

      expect(daily[StatBreakdownSource.book]!['2026-07-28']!.chars, 42);
      expect(daily[StatBreakdownSource.manga], isEmpty);
    });
  });

  group('窗口合计与活跃日', () {
    final Map<StatBreakdownSource, Map<String, StatSourceTotals>> daily =
        aggregateStatSourceDaily(
      reading: reading,
      formatByTitle: formats,
      video: video,
      gameDaily: games,
    );

    test('全部来源合计 = 首页每日目标同一口径分子', () {
      final StatSourceTotals all =
          sumAllStatSources(daily, (String _) => true);
      expect(all.chars, 1000 + 300 + 150 + 500 + 2000);
      expect(all.timeMs, 600000 + 300000 + 120000 + 1800000 + 3600000);
      expect(all.pages, 29);
    });

    test('单日窗口只算当天', () {
      final StatSourceTotals today =
          sumAllStatSources(daily, (String d) => d == '2026-07-28');
      expect(today.chars, 150 + 500);
      expect(today.pages, 9);
    });

    test('活跃日是四来源并集：只看视频/只玩游戏的那天也算', () {
      expect(
        allStatSourceDateKeys(daily),
        <String>{'2026-07-26', '2026-07-27', '2026-07-28'},
      );
    });

    test('全零行不算活跃日', () {
      final Map<StatBreakdownSource, Map<String, StatSourceTotals>> empty =
          aggregateStatSourceDaily(
        reading: <ReadingStatisticRow>[_reading('书', '2026-01-01')],
        formatByTitle: const <String, String>{},
        video: const <VideoWatchStatisticRow>[],
        gameDaily: const <(String, int, int)>[],
      );
      expect(allStatSourceDateKeys(empty), isEmpty);
    });
  });
}
