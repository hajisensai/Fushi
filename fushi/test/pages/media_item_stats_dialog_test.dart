import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/media_item_stats_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';

StatFact _fact({
  required String kind,
  required String key,
  required String dateKey,
  String title = '',
  int ms = 0,
  int chars = 0,
}) => StatFact(
  mediaKind: kind,
  mediaKey: key,
  title: title,
  format: '',
  dateKey: dateKey,
  hour: -1,
  ms: ms,
  chars: chars,
  pages: 0,
  lastActiveMs: 0,
);

StatFacts _facts(
  List<StatFact> daily, {
  List<LookupMiningCounterRow> counters = const <LookupMiningCounterRow>[],
}) => StatFacts(
  daily: daily,
  hourly: const <StatFact>[],
  segments: const <StudySegmentRow>[],
  legacyActivity: const <ActivityEventRow>[],
  epubRows: const <EpubBookMeta>[],
  counters: StatCounterFacts(lookupCounters: counters),
);

void main() {
  final DateTime now = DateTime(2026, 9, 28, 12);
  final String today = FushiDatabase.statDateKeyOf(now);
  final String fiveDaysAgo = FushiDatabase.statDateKeyOf(
    now.subtract(const Duration(days: 5)),
  );
  final String longAgo = FushiDatabase.statDateKeyOf(DateTime(2025, 1, 2, 12));

  test('单条目：按种类 + 身份切片，今日 / 近 7 天 / 近 30 天 / 累计各自成立', () {
    final MediaItemStatsSummary s = summarizeMediaItemStats(
      _facts(<StatFact>[
        _fact(kind: 'book', key: 'bk1', dateKey: today, ms: 60000, chars: 100),
        _fact(kind: 'book', key: 'bk1', dateKey: fiveDaysAgo, ms: 120000),
        _fact(kind: 'book', key: 'bk1', dateKey: longAgo, chars: 50),
        // 别的书、同身份但别的域：都不算。
        _fact(kind: 'book', key: 'bk2', dateKey: today, ms: 999999),
        _fact(kind: 'video', key: 'bk1', dateKey: today, ms: 999999),
      ]),
      MediaItemStatsTarget(
        mediaKind: kActivityMediaBook,
        mediaKeys: <String>{'bk1'},
        title: 'Book',
      ),
      now: now,
    );
    expect(s.totalMs, 180000);
    expect(s.totalChars, 150);
    expect(s.todayMs, 60000);
    expect(s.weekMs, 180000);
    expect(s.monthChars, 100);
    expect(s.activeDays, 3);
    expect(s.firstDateKey, longAgo);
    expect(s.lastDateKey, today);
    expect(s.isEmpty, isFalse);
  });

  test('legacy 无身份行按标题回退；合集不做标题回退', () {
    final StatFacts facts = _facts(<StatFact>[
      _fact(kind: 'book', key: '', title: 'Same', dateKey: today, ms: 1000),
      _fact(kind: 'video', key: 'v1', dateKey: today, ms: 2000),
      _fact(kind: 'game', key: 'g1', dateKey: today, ms: 4000),
    ]);
    expect(
      summarizeMediaItemStats(
        facts,
        MediaItemStatsTarget(
          mediaKind: kActivityMediaBook,
          mediaKeys: <String>{'bk'},
          title: 'Same',
        ),
        now: now,
      ).totalMs,
      1000,
    );
    final MediaItemStatsSummary collection = summarizeMediaItemStats(
      facts,
      MediaItemStatsTarget.collection(
        title: 'Same',
        members: const <MediaCollectionItemRow>[
          MediaCollectionItemRow(
            collectionId: 1,
            mediaType: 'video',
            entryKey: 'v1',
            sortIndex: 0,
          ),
          MediaCollectionItemRow(
            collectionId: 1,
            mediaType: 'game',
            entryKey: 'g1',
            sortIndex: 1,
          ),
        ],
      ),
      now: now,
    );
    // 视频 + 游戏成员之和；同名的 legacy 书行不被合集名吸进来。
    expect(collection.totalMs, 6000);
  });

  test('查词 / 制卡计数按来源种类 + 身份归属', () {
    final MediaItemStatsSummary s = summarizeMediaItemStats(
      _facts(
        const <StatFact>[],
        counters: <LookupMiningCounterRow>[
          LookupMiningCounterRow(
            id: 1,
            bookKey: 'v1',
            title: 'V',
            sourceType: 'video',
            dateKey: today,
            lookupCount: 3,
            mineCount: 1,
          ),
          LookupMiningCounterRow(
            id: 2,
            bookKey: 'v1',
            title: 'V',
            sourceType: 'book',
            dateKey: today,
            lookupCount: 100,
            mineCount: 100,
          ),
        ],
      ),
      MediaItemStatsTarget(
        mediaKind: kActivityMediaVideo,
        mediaKeys: <String>{'v1'},
        title: 'V',
      ),
      now: now,
    );
    expect(s.lookups, 3);
    expect(s.cards, 1);
    expect(s.isEmpty, isFalse, reason: '只有查词 / 制卡也要显示，不能落空态');
  });
}
