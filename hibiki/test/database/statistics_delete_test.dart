import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-1204 后续：统计页长按删除某本书/视频的统计 + 防同步复活墓碑。
Future<HibikiDatabase> _openDb() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('deleteReadingStatisticsForTitle', () {
    test(
        'clears reading + lookup/mining (book) rows for the title only, and '
        'writes a book tombstone', () async {
      final HibikiDatabase db = await _openDb();
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
      final HibikiDatabase db = await _openDb();
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

  group('deleteVideoStatisticsForTitle', () {
    test(
        'clears video watch + lookup/mining (video) rows and writes a video '
        'tombstone; a same-title book stays', () async {
      final HibikiDatabase db = await _openDb();
      await db.addVideoWatchStatistic(
          title: 'A', dateKey: '2026-07-05', subtitleChars: 10, watchTimeMs: 5);
      await db.addReadingStatistic(
          title: 'A', dateKey: '2026-07-05', charsRead: 1, timeMs: 1);
      await db.addLookupCount(
          title: 'A', sourceType: 'video', dateKey: '2026-07-05');

      await db.deleteVideoStatisticsForTitle('A');

      expect(await db.getAllVideoWatchStatistics(), isEmpty);
      expect(await db.getLookupMiningCountersBySource('video'), isEmpty);
      expect((await db.getAllReadingStatistics()).single.title, 'A',
          reason: 'same-title book reading stat is a different source, kept');

      final Set<(String, String)> tombstones =
          await db.getStatisticsTombstoneKeys();
      expect(tombstones, contains(('A', 'video')));
    });
  });

  group('tombstone lifecycle', () {
    test('new reading activity clears a prior book tombstone', () async {
      final HibikiDatabase db = await _openDb();
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
      final HibikiDatabase db = await _openDb();
      await db.addVideoWatchStatistic(
          title: 'V', dateKey: '2026-07-05', subtitleChars: 1, watchTimeMs: 1);
      await db.deleteVideoStatisticsForTitle('V');
      expect(await db.getStatisticsTombstoneKeys(), contains(('V', 'video')));

      await db.addVideoWatchStatistic(
          title: 'V', dateKey: '2026-07-06', subtitleChars: 1, watchTimeMs: 1);
      expect(await db.getStatisticsTombstoneKeys(),
          isNot(contains(('V', 'video'))));
    });

    test('new lookup activity clears the matching tombstone (per sourceType)',
        () async {
      final HibikiDatabase db = await _openDb();
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
