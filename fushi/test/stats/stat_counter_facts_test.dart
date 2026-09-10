import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/stats/stat_facts.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 统计中心「总览」tab 的查词 / 制卡 / 收藏数字（此前总览只有时长与字数，这四个
/// 每天都在动的数字一个都看不到，只能逐个域 tab 翻）。
///
/// 口径的硬约束：总览是跨域视图，它的每个数字必须**恰好**等于阅读 tab 与视频 tab
/// 之和——所以三处只许有一份取数与一份切分判据（[StatCounterFacts]）。
MiningStatisticRow _mining(String source, String dateKey, int count) =>
    MiningStatisticRow(
        id: 0, sourceType: source, dateKey: dateKey, count: count);

LookupMiningCounterRow _counter(
  String source,
  String dateKey, {
  int lookups = 0,
  int mines = 0,
  String title = '',
}) =>
    LookupMiningCounterRow(
      id: 0,
      bookKey: '',
      title: title,
      sourceType: source,
      dateKey: dateKey,
      lookupCount: lookups,
      mineCount: mines,
    );

FavoriteWordRow _word(String source, String dateKey) => FavoriteWordRow(
      id: 0,
      expression: 'あ',
      reading: 'あ',
      glossary: '',
      sourceType: source,
      title: '',
      dateKey: dateKey,
      createdAt: 0,
    );

int _sum(Iterable<(String, int)> events) =>
    events.fold<int>(0, (int a, (String, int) e) => a + e.$2);

void main() {
  const String today = '2026-07-18';
  const String yesterday = '2026-07-17';
  final DateTime now = DateTime(2026, 7, 18, 20);

  final StatCounterFacts facts = StatCounterFacts(
    mining: <MiningStatisticRow>[
      _mining(kStatSourceBook, today, 3),
      _mining(kStatSourceBook, yesterday, 2),
      _mining(kStatSourceVideo, today, 5),
    ],
    lookupCounters: <LookupMiningCounterRow>[
      _counter(kStatSourceBook, today, lookups: 10, mines: 3, title: '本'),
      _counter(kStatSourceVideo, today, lookups: 7, mines: 5),
      _counter(kStatSourceVideo, yesterday, lookups: 1),
    ],
    favoriteWords: <FavoriteWordRow>[
      _word(kStatSourceBook, today),
      _word(kStatSourceVideo, today),
      _word(kStatSourceVideo, yesterday),
    ],
    favoriteSentences: <FavoriteSentence>[
      FavoriteSentence(
          text: 'b', bookTitle: 'B', createdAt: DateTime(2026, 7, 18, 9)),
      FavoriteSentence(
        text: 'v',
        bookTitle: 'V',
        createdAt: DateTime(2026, 7, 18, 9),
        source: kFavoriteSentenceSourceVideo,
      ),
    ],
  );

  group('按来源切片', () {
    test('查词只算本域，不传 source 则跨域求和', () {
      expect(_sum(facts.lookupEvents(source: StatSourceKind.book)), 10);
      expect(_sum(facts.lookupEvents(source: StatSourceKind.video)), 8);
      expect(_sum(facts.lookupEvents()), 18);
    });

    test('制卡走 mining_statistics，不是 per-book 的 mineCount', () {
      // 两张表在「无书制卡能不能归到书上」这点上不等价：本例 counters 的 mineCount
      // 合计 8，全局计数 10——总览必须与域页取同一张表，否则跨域和对不上。
      expect(_sum(facts.minedEvents(source: StatSourceKind.book)), 5);
      expect(_sum(facts.minedEvents(source: StatSourceKind.video)), 5);
      expect(_sum(facts.minedEvents()), 10);
    });

    test('收藏词按行计 1', () {
      expect(_sum(facts.favoriteWordEvents(source: StatSourceKind.book)), 1);
      expect(_sum(facts.favoriteWordEvents(source: StatSourceKind.video)), 2);
      expect(_sum(facts.favoriteWordEvents()), 3);
    });

    test('per-book 计数行切片给 tile 用（阅读页按 title 聚合）', () {
      expect(facts.lookupCountersFor(StatSourceKind.book).single.title, '本');
      expect(facts.lookupCountersFor(StatSourceKind.video), hasLength(2));
      expect(facts.lookupCountersFor(null), hasLength(3));
    });
  });

  group('跨域 = 两域之和（总览与两个域 tab 对得上）', () {
    final Map<String, Iterable<(String, int)> Function(StatSourceKind?)> flows =
        <String, Iterable<(String, int)> Function(StatSourceKind?)>{
      '查词': (StatSourceKind? s) => facts.lookupEvents(source: s),
      '制卡': (StatSourceKind? s) => facts.minedEvents(source: s),
      '收藏词': (StatSourceKind? s) => facts.favoriteWordEvents(source: s),
      '收藏句': (StatSourceKind? s) => facts.favoriteSentenceEvents(source: s),
    };
    flows.forEach((
      String name,
      Iterable<(String, int)> Function(StatSourceKind?) of,
    ) {
      test('$name 跨域合计 = book + video', () {
        final StatActivityBuckets all = bucketActivityByDateKey(of(null), now);
        final StatActivityBuckets book =
            bucketActivityByDateKey(of(StatSourceKind.book), now);
        final StatActivityBuckets video =
            bucketActivityByDateKey(of(StatSourceKind.video), now);
        expect(all.all, book.all + video.all, reason: '全部');
        expect(all.today, book.today + video.today, reason: '今日');
        expect(all.week, book.week + video.week, reason: '本周');
        expect(all.month, book.month + video.month, reason: '本月');
      });
    });
  });

  test('分桶按 dateKey 落窗口（今日只算今天那几行）', () {
    final StatActivityBuckets lookups =
        bucketActivityByDateKey(facts.lookupEvents(), now);
    expect(lookups.today, 17, reason: '10 + 7，昨天那 1 次不算');
    expect(lookups.all, 18);
    final StatActivityBuckets mined =
        bucketActivityByDateKey(facts.minedEvents(), now);
    expect(mined.today, 8, reason: '3 + 5');
    expect(mined.all, 10);
  });

  test('空计数面（loadStatFacts 不带 includeCounters）四个流都空', () {
    expect(StatCounterFacts.empty.lookupEvents(), isEmpty);
    expect(StatCounterFacts.empty.minedEvents(), isEmpty);
    expect(StatCounterFacts.empty.favoriteWordEvents(), isEmpty);
    expect(StatCounterFacts.empty.favoriteSentenceEvents(), isEmpty);
  });
}
