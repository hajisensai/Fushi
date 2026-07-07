import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-1322: 统计页顶栏「清空全部统计」——只清纯统计数字（阅读 / 观看时长、字数、
/// 时段日志、查词 / 制卡计数），保留收藏词 / 制卡历史 / 书籍等用户内容，且阅读域与
/// 视频域互不牵连。
Future<HibikiDatabase> _openDb() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// 播下阅读域纯统计（4 张统计表 book 行）。
Future<void> _seedReadingStats(HibikiDatabase db) async {
  await db.addReadingStatistic(
      title: 'A', dateKey: '2026-07-05', charsRead: 100, timeMs: 6000);
  await db.addReadingStatistic(
      title: 'B', dateKey: '2026-07-06', charsRead: 50, timeMs: 3000);
  await db.addHourlyReadingTime(dateKey: '2026-07-05', hour: 10, deltaMs: 6000);
  await db.addLookupCount(
      bookKey: 'book/A', title: 'A', sourceType: 'book', dateKey: '2026-07-05');
  await db.addMineCountPerBook(
      bookKey: 'book/A', title: 'A', sourceType: 'book', dateKey: '2026-07-05');
  await db.addMiningCount(sourceType: 'book', dateKey: '2026-07-05');
}

/// 播下视频域纯统计（4 张统计表 video 行）。
Future<void> _seedVideoStats(HibikiDatabase db) async {
  await db.addVideoWatchStatistic(
      title: 'V', dateKey: '2026-07-05', subtitleChars: 10, watchTimeMs: 5000);
  await db.addVideoHourlyWatchTime(
      dateKey: '2026-07-05', hour: 11, deltaMs: 5000);
  await db.addLookupCount(title: 'V', sourceType: 'video', dateKey: '2026-07-05');
  await db.addMiningCount(sourceType: 'video', dateKey: '2026-07-05');
}

void main() {
  group('clearAllReadingStatistics', () {
    test(
        'wipes every book-domain statistic but keeps user content and all '
        'video-domain statistics', () async {
      final HibikiDatabase db = await _openDb();
      await _seedReadingStats(db);
      await _seedVideoStats(db);
      // 用户内容（绝不该被清）。
      await db.addFavoriteWord(
          expression: '猫',
          reading: 'ねこ',
          glossary: 'cat',
          sourceType: 'book',
          dateKey: '2026-07-05');
      await db.addMinedSentence(
          source: 'book',
          dateKey: '2026-07-05',
          expression: '猫',
          documentTitle: 'A',
          bookKey: 'book/A');

      await db.clearAllReadingStatistics();

      // 阅读域四表清空。
      expect(await db.getAllReadingStatistics(), isEmpty);
      expect(await db.getAllReadingHourlyLogs(), isEmpty);
      expect(await db.getLookupMiningCountersBySource('book'), isEmpty);
      expect(await db.getMiningStatisticsBySource('book'), isEmpty);

      // 视频域四表原封不动。
      expect((await db.getAllVideoWatchStatistics()).length, 1);
      expect((await db.getAllVideoHourlyLogs()).length, 1);
      expect((await db.getLookupMiningCountersBySource('video')).length, 1);
      expect((await db.getMiningStatisticsBySource('video')).length, 1);

      // 用户内容保留。
      expect((await db.getAllFavoriteWords()).length, 1,
          reason: 'favorites are user content, not a statistic');
      expect((await db.getAllMinedSentences()).length, 1,
          reason: 'mined card history is user content, not a statistic');
    });

    test('is a no-op on an empty database (idempotent, no throw)', () async {
      final HibikiDatabase db = await _openDb();
      await db.clearAllReadingStatistics();
      await db.clearAllReadingStatistics();
      expect(await db.getAllReadingStatistics(), isEmpty);
    });
  });

  group('clearAllVideoStatistics', () {
    test(
        'wipes every video-domain statistic but keeps user content and all '
        'reading-domain statistics', () async {
      final HibikiDatabase db = await _openDb();
      await _seedReadingStats(db);
      await _seedVideoStats(db);
      await db.addFavoriteWord(
          expression: '犬',
          reading: 'いぬ',
          glossary: 'dog',
          sourceType: 'video',
          dateKey: '2026-07-05');

      await db.clearAllVideoStatistics();

      // 视频域四表清空。
      expect(await db.getAllVideoWatchStatistics(), isEmpty);
      expect(await db.getAllVideoHourlyLogs(), isEmpty);
      expect(await db.getLookupMiningCountersBySource('video'), isEmpty);
      expect(await db.getMiningStatisticsBySource('video'), isEmpty);

      // 阅读域四表原封不动。
      expect((await db.getAllReadingStatistics()).length, 2);
      expect((await db.getAllReadingHourlyLogs()).length, 1);
      expect((await db.getLookupMiningCountersBySource('book')).length, 1);
      expect((await db.getMiningStatisticsBySource('book')).length, 1);

      // 用户内容保留。
      expect((await db.getAllFavoriteWords()).length, 1);
    });
  });
}
