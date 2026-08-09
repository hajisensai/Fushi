import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// TODO-1204 后续：统计页长按删除某本书/视频的统计 + 防同步复活墓碑。
Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('deleteReadingStatisticsForTitle', () {
    test(
        'clears reading + lookup/mining (book) rows for the title only, and '
        'writes a book tombstone', () async {
      final FushiDatabase db = await _openDb();
      // Two books; delete only "A".
      await db.addReadingStatistic(
          title: 'A', dateKey: '2026-07-05', charsRead: 100, timeMs: 6000);
      await db.addReadingStatistic(
          title: 'B', dateKey: '2026-07-05', charsRead: 50, timeMs: 3000);
      await db.addLookupCount(
          bookKey: 'book/A',
          title: 'A',
          sourceType: 'book',
          dateKey: '2026-07-05');
      await db.addMineCountPerBook(
          bookKey: 'book/A',
          title: 'A',
          sourceType: 'book',
          dateKey: '2026-07-05');
      await db.addLookupCount(
          bookKey: 'book/B',
          title: 'B',
          sourceType: 'book',
          dateKey: '2026-07-05');
      // A same-title VIDEO counter must survive (different sourceType bucket).
      await db.addLookupCount(
          title: 'A', sourceType: 'video', dateKey: '2026-07-05');

      await db.deleteReadingStatisticsForTitle('A');

      final List<ReadingStatisticRow> reading =
          await db.getAllReadingStatistics();
      expect(reading.map((ReadingStatisticRow r) => r.title), <String>['B']);

      final List<LookupMiningCounterRow> bookCounters =
          await db.getLookupMiningCountersBySource('book');
      expect(bookCounters.map((LookupMiningCounterRow r) => r.title),
          <String>['B'],
          reason: 'book counters for A gone, B kept');
      final List<LookupMiningCounterRow> videoCounters =
          await db.getLookupMiningCountersBySource('video');
      expect(videoCounters.single.title, 'A',
          reason: 'same-title video counter is a different bucket, survives');

      final Set<(String, String)> tombstones =
          await db.getStatisticsTombstoneKeys();
      expect(tombstones, contains(('A', 'book')));
      expect(tombstones, isNot(contains(('A', 'video'))));
    });

    test(
        'does NOT delete mined sentences or favorite words (content, not '
        'statistics)', () async {
      final FushiDatabase db = await _openDb();
      await db.addReadingStatistic(
          title: 'A', dateKey: '2026-07-05', charsRead: 100, timeMs: 6000);
      await db.addMinedSentence(
          source: 'book',
          dateKey: '2026-07-05',
          expression: '猫',
          documentTitle: 'A',
          bookKey: 'book/A');
      await db.addFavoriteWord(
          expression: '猫',
          reading: 'ねこ',
          glossary: 'cat',
          sourceType: 'book',
          dateKey: '2026-07-05');

      await db.deleteReadingStatisticsForTitle('A');

      expect((await db.getAllMinedSentences()).length, 1,
          reason: 'mined card history is user content, not a statistic');
      expect((await db.getAllFavoriteWords()).length, 1,
          reason: 'favorites are user content, not a statistic');
    });
  });

  group('deleteVideoStatisticsForIdentity', () {
    test(
        'clears video watch + lookup/mining (video) rows and writes a video '
        'tombstone; a same-title book stays', () async {
      final FushiDatabase db = await _openDb();
      await db.addVideoWatchStatistic(
          title: 'A', dateKey: '2026-07-05', subtitleChars: 10, watchTimeMs: 5);
      await db.addReadingStatistic(
          title: 'A', dateKey: '2026-07-05', charsRead: 1, timeMs: 1);
      await db.addLookupCount(
          title: 'A', sourceType: 'video', dateKey: '2026-07-05');

      await db.deleteVideoStatisticsForIdentity(title: 'A');

      expect(await db.getAllVideoWatchStatistics(), isEmpty);
      expect(await db.getLookupMiningCountersBySource('video'), isEmpty);
      expect((await db.getAllReadingStatistics()).single.title, 'A',
          reason: 'same-title book reading stat is a different source, kept');

      final Set<(String, String)> tombstones =
          await db.getStatisticsTombstoneKeys();
      expect(tombstones, contains(('A', 'video')));
    });

    test(
        'v76: uid-scoped delete leaves a same-title sibling video untouched '
        '(no more collateral title delete)', () async {
      final FushiDatabase db = await _openDb();
      // Same title, two identities (v39 storage model).
      await db.addVideoWatchStatistic(
          title: 'A',
          bookUid: 'uid-1',
          dateKey: '2026-07-05',
          subtitleChars: 10,
          watchTimeMs: 5);
      await db.addVideoWatchStatistic(
          title: 'A',
          bookUid: 'uid-2',
          dateKey: '2026-07-05',
          subtitleChars: 20,
          watchTimeMs: 7);
      await db.addLookupCount(
          bookKey: 'uid-1',
          title: 'A',
          sourceType: 'video',
          dateKey: '2026-07-05');
      await db.addLookupCount(
          bookKey: 'uid-2',
          title: 'A',
          sourceType: 'video',
          dateKey: '2026-07-05');

      // Ambiguous title → tile absorbs nothing; delete uid-1 only.
      await db.deleteVideoStatisticsForIdentity(
          title: 'A', bookUid: 'uid-1', includeUnattributed: false);

      final List<VideoWatchStatisticRow> watch =
          await db.getAllVideoWatchStatistics();
      expect(watch.single.bookUid, 'uid-2',
          reason: 'sibling same-title video keeps its per-uid rows');
      final List<LookupMiningCounterRow> counters =
          await db.getLookupMiningCountersBySource('video');
      expect(counters.single.bookKey, 'uid-2');
    });

    test(
        'review2-6 回归：改名视频按 uid 删除时，墓碑覆盖被删行的全部历史 title'
        '（否则旧 title 行从旧备份复活）', () async {
      final FushiDatabase db = await _openDb();
      await db.addVideoWatchStatistic(
          title: '旧名',
          bookUid: 'uid-x',
          dateKey: '2026-07-01',
          subtitleChars: 1,
          watchTimeMs: 1);
      await db.addVideoWatchStatistic(
          title: '新名',
          bookUid: 'uid-x',
          dateKey: '2026-07-05',
          subtitleChars: 2,
          watchTimeMs: 2);
      await db.addLookupCount(
          bookKey: 'uid-x',
          title: '旧名',
          sourceType: 'video',
          dateKey: '2026-07-01');

      await db.deleteVideoStatisticsForIdentity(
          title: '新名', bookUid: 'uid-x', includeUnattributed: true);

      expect(await db.getAllVideoWatchStatistics(), isEmpty);
      final Set<(String, String)> tombstones =
          await db.getStatisticsTombstoneKeys();
      expect(
          tombstones,
          containsAll(<(String, String)>[
            ('新名', 'video'),
            ('旧名', 'video'),
          ]));
    });

    test(
        'review2-10 回归：bookUid 存成空串（而非 NULL）的行也算无身份，'
        '删得掉不复活', () async {
      final FushiDatabase db = await _openDb();
      await db.setVideoWatchStatistic(VideoWatchStatisticsCompanion(
        title: const Value('T'),
        bookUid: const Value(''),
        dateKey: const Value('2026-07-05'),
        subtitleChars: const Value(3),
        watchTimeMs: const Value(4),
        lastModified: const Value(1),
      ));

      await db.deleteVideoStatisticsForIdentity(title: 'T');

      expect(await db.getAllVideoWatchStatistics(), isEmpty,
          reason: '删除谓词与展示层同判据（NULL 与 空串 都算无身份），'
              '不留「显示得出、删不掉」的行');
    });

    test(
        'v76: includeUnattributed sweeps legacy NULL/empty-identity rows of '
        'the same title along with the uid rows', () async {
      final FushiDatabase db = await _openDb();
      await db.addVideoWatchStatistic(
          title: 'A',
          bookUid: 'uid-1',
          dateKey: '2026-07-05',
          subtitleChars: 10,
          watchTimeMs: 5);
      // Legacy row (no identity) of the same title.
      await db.addVideoWatchStatistic(
          title: 'A', dateKey: '2026-07-04', subtitleChars: 3, watchTimeMs: 2);
      await db.addLookupCount(
          title: 'A', sourceType: 'video', dateKey: '2026-07-04');

      await db.deleteVideoStatisticsForIdentity(
          title: 'A', bookUid: 'uid-1', includeUnattributed: true);

      expect(await db.getAllVideoWatchStatistics(), isEmpty);
      expect(await db.getLookupMiningCountersBySource('video'), isEmpty);
    });
  });

  group('tombstone lifecycle', () {
    test('new reading activity clears a prior book tombstone', () async {
      final FushiDatabase db = await _openDb();
      await db.addReadingStatistic(
          title: 'A', dateKey: '2026-07-05', charsRead: 100, timeMs: 6000);
      await db.deleteReadingStatisticsForTitle('A');
      expect(await db.getStatisticsTombstoneKeys(), contains(('A', 'book')));

      // Reading A again (creating a fresh daily row) revives it.
      await db.addReadingStatistic(
          title: 'A', dateKey: '2026-07-06', charsRead: 10, timeMs: 600);
      expect(await db.getStatisticsTombstoneKeys(),
          isNot(contains(('A', 'book'))));
    });

    test('new video activity clears a prior video tombstone', () async {
      final FushiDatabase db = await _openDb();
      await db.addVideoWatchStatistic(
          title: 'V', dateKey: '2026-07-05', subtitleChars: 1, watchTimeMs: 1);
      await db.deleteVideoStatisticsForIdentity(title: 'V');
      expect(await db.getStatisticsTombstoneKeys(), contains(('V', 'video')));

      await db.addVideoWatchStatistic(
          title: 'V', dateKey: '2026-07-06', subtitleChars: 1, watchTimeMs: 1);
      expect(await db.getStatisticsTombstoneKeys(),
          isNot(contains(('V', 'video'))));
    });

    test('new lookup activity clears the matching tombstone (per sourceType)',
        () async {
      final FushiDatabase db = await _openDb();
      await db.insertStatisticsTombstone('A', 'book');
      // A no-book lookup (title empty) must not touch any tombstone.
      await db.addLookupCount(sourceType: 'book', dateKey: '2026-07-06');
      expect(await db.getStatisticsTombstoneKeys(), contains(('A', 'book')));
      // A lookup naming book A clears it.
      await db.addLookupCount(
          bookKey: 'book/A',
          title: 'A',
          sourceType: 'book',
          dateKey: '2026-07-06');
      expect(await db.getStatisticsTombstoneKeys(),
          isNot(contains(('A', 'book'))));
    });
  });
}
