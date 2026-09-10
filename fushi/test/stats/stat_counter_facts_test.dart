import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/stats/stat_facts.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 统计中心「总览」tab 的查词 / 制卡 / 收藏数字（此前总览只有时长与字数，这四个
/// 每天都在动的数字一个都看不到，只能逐个域 tab 翻）。
///
/// 口径的硬约束：总览是跨域视图，它的每个数字必须**恰好**等于阅读 tab + 视频 tab
/// + 游戏 tab 之和——所以四处只许有一份取数与一份切分判据（[StatCounterFacts]）。
/// game 域自 [kStatSourceGame] 起加入（此前 galgame hook 会话里的查词 / 制卡 /
/// 收藏全被记成 book，数字堆在阅读域、游戏 tab 只剩游玩次数一行）。
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
      _mining(kStatSourceGame, today, 4),
    ],
    lookupCounters: <LookupMiningCounterRow>[
      _counter(kStatSourceBook, today, lookups: 10, mines: 3, title: '本'),
      _counter(kStatSourceVideo, today, lookups: 7, mines: 5),
      _counter(kStatSourceVideo, yesterday, lookups: 1),
      _counter(kStatSourceGame, today, lookups: 6, mines: 4),
    ],
    favoriteWords: <FavoriteWordRow>[
      _word(kStatSourceBook, today),
      _word(kStatSourceVideo, today),
      _word(kStatSourceVideo, yesterday),
      _word(kStatSourceGame, today),
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
      FavoriteSentence(
        text: 'g',
        bookTitle: 'G',
        createdAt: DateTime(2026, 7, 18, 9),
        source: kFavoriteSentenceSourceGame,
      ),
      // 有声书来源仍归阅读域（书域是「其余全部」，不是「等于 book」）。
      FavoriteSentence(
        text: 'a',
        bookTitle: 'A',
        createdAt: DateTime(2026, 7, 18, 9),
        source: kFavoriteSentenceSourceAudiobook,
      ),
    ],
  );

  group('按来源切片', () {
    test('查词只算本域，不传 source 则跨域求和', () {
      expect(_sum(facts.lookupEvents(source: StatSourceKind.book)), 10);
      expect(_sum(facts.lookupEvents(source: StatSourceKind.video)), 8);
      expect(_sum(facts.lookupEvents(source: StatSourceKind.game)), 6);
      expect(_sum(facts.lookupEvents()), 24);
    });

    test('制卡走 mining_statistics，不是 per-book 的 mineCount', () {
      // 两张表在「无书制卡能不能归到书上」这点上不等价：本例 counters 的 mineCount
      // 合计 12，全局计数 14——总览必须与域页取同一张表，否则跨域和对不上。
      expect(_sum(facts.minedEvents(source: StatSourceKind.book)), 5);
      expect(_sum(facts.minedEvents(source: StatSourceKind.video)), 5);
      expect(_sum(facts.minedEvents(source: StatSourceKind.game)), 4);
      expect(_sum(facts.minedEvents()), 14);
    });

    test('收藏词按行计 1', () {
      expect(_sum(facts.favoriteWordEvents(source: StatSourceKind.book)), 1);
      expect(_sum(facts.favoriteWordEvents(source: StatSourceKind.video)), 2);
      expect(_sum(facts.favoriteWordEvents(source: StatSourceKind.game)), 1);
      expect(_sum(facts.favoriteWordEvents()), 4);
    });

    test('收藏句三域分流：video/game 各取自己，book 取「其余全部」', () {
      // 收藏句的 source 是另一个值域（book/video/audiobook/lyrics/game），阅读域
      // 必须同时排除 video 与 game——漏排哪个，那条就在两个域各计一次。
      expect(
          _sum(facts.favoriteSentenceEvents(source: StatSourceKind.video)), 1);
      expect(
          _sum(facts.favoriteSentenceEvents(source: StatSourceKind.game)), 1);
      expect(_sum(facts.favoriteSentenceEvents(source: StatSourceKind.book)), 2,
          reason: '书内那条 + 有声书那条（有声书/歌词都算阅读）');
      expect(_sum(facts.favoriteSentenceEvents()), 4);
    });

    test('per-book 计数行切片给 tile 用（阅读页按 title 聚合）', () {
      expect(facts.lookupCountersFor(StatSourceKind.book).single.title, '本');
      expect(facts.lookupCountersFor(StatSourceKind.video), hasLength(2));
      expect(facts.lookupCountersFor(StatSourceKind.game), hasLength(1));
      expect(facts.lookupCountersFor(null), hasLength(4));
    });
  });

  group('跨域 = 三域之和（总览与三个域 tab 对得上）', () {
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
      test('$name 跨域合计 = book + video + game', () {
        final StatActivityBuckets all = bucketActivityByDateKey(of(null), now);
        final StatActivityBuckets book =
            bucketActivityByDateKey(of(StatSourceKind.book), now);
        final StatActivityBuckets video =
            bucketActivityByDateKey(of(StatSourceKind.video), now);
        final StatActivityBuckets game =
            bucketActivityByDateKey(of(StatSourceKind.game), now);
        expect(all.all, book.all + video.all + game.all, reason: '全部');
        expect(all.today, book.today + video.today + game.today, reason: '今日');
        expect(all.week, book.week + video.week + game.week, reason: '本周');
        expect(all.month, book.month + video.month + game.month, reason: '本月');
      });
    });
  });

  test('分桶按 dateKey 落窗口（今日只算今天那几行）', () {
    final StatActivityBuckets lookups =
        bucketActivityByDateKey(facts.lookupEvents(), now);
    expect(lookups.today, 23, reason: '10 + 7 + 6，昨天那 1 次不算');
    expect(lookups.all, 24);
    final StatActivityBuckets mined =
        bucketActivityByDateKey(facts.minedEvents(), now);
    expect(mined.today, 12, reason: '3 + 5 + 4');
    expect(mined.all, 14);
  });

  test('空计数面（loadStatFacts 不带 includeCounters）四个流都空', () {
    expect(StatCounterFacts.empty.lookupEvents(), isEmpty);
    expect(StatCounterFacts.empty.minedEvents(), isEmpty);
    expect(StatCounterFacts.empty.favoriteWordEvents(), isEmpty);
    expect(StatCounterFacts.empty.favoriteSentenceEvents(), isEmpty);
  });
}
