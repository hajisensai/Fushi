import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// TODO-1322: 统计页顶栏「清空全部统计」——只清纯统计数字（阅读 / 观看时长、字数、
/// 时段日志、查词 / 制卡计数），保留收藏词 / 制卡历史 / 书籍等用户内容，且阅读域与
/// 视频域互不牵连。
///
/// v90 起累加 DAO 已删（legacy 四表只剩同步落地的 OVERWRITE 版 set*），本文件用
/// set* 造 legacy 行；clearAll* 现在连带清本域的 `study_segments` 事实（新事实表
/// 语义见 study_segments_test.dart）。
Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// 播下阅读域纯统计（4 张统计表 book 行）。
Future<void> _seedReadingStats(FushiDatabase db) async {
  await db.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'A',
      dateKey: '2026-07-05',
      charactersRead: 100,
      readingTimeMs: 6000,
      lastStatisticModified: 1));
  await db.setReadingStatistic(ReadingStatisticsCompanion.insert(
      title: 'B',
      dateKey: '2026-07-06',
      charactersRead: 50,
      readingTimeMs: 3000,
      lastStatisticModified: 1));
  await db.setReadingHourlyLog(
      dateKey: '2026-07-05',
      hour: 10,
      readingTimeMs: 6000,
      format: BookFormat.epub.dbValue);
  await db.addLookupCount(
      bookKey: 'book/A', title: 'A', sourceType: 'book', dateKey: '2026-07-05');
  await db.addMineCountPerBook(
      bookKey: 'book/A', title: 'A', sourceType: 'book', dateKey: '2026-07-05');
  await db.addMiningCount(sourceType: 'book', dateKey: '2026-07-05');
}

/// 播下视频域纯统计（4 张统计表 video 行）。
Future<void> _seedVideoStats(FushiDatabase db) async {
  await db.setVideoWatchStatistic(VideoWatchStatisticsCompanion.insert(
      title: 'V',
      dateKey: '2026-07-05',
      subtitleChars: 10,
      watchTimeMs: 5000,
      lastModified: 1));
  await db.setVideoHourlyLog(dateKey: '2026-07-05', hour: 11, watchTimeMs: 5000);
  await db.addLookupCount(
      title: 'V', sourceType: 'video', dateKey: '2026-07-05');
  await db.addMiningCount(sourceType: 'video', dateKey: '2026-07-05');
}

/// 一段 study_segments 事实（v90）。
Future<void> _seedSegment(
  FushiDatabase db, {
  required String mediaKind,
  required String mediaKey,
}) =>
    db.upsertStudySegment(StudySegmentsCompanion.insert(
      uid: FushiDatabase.newStudySegmentUid(),
      deviceId: 'dev-test',
      mediaKind: mediaKind,
      mediaKey: mediaKey,
      title: mediaKey,
      startAt: 1000,
      endAt: 61000,
      dateKey: '2026-07-05',
      hour: 10,
      updatedAt: 61000,
    ));

void main() {
  group('clearAllReadingStatistics', () {
    test(
        'wipes every book-domain statistic but keeps user content and all '
        'video-domain statistics', () async {
      final FushiDatabase db = await _openDb();
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
      final FushiDatabase db = await _openDb();
      await db.clearAllReadingStatistics();
      await db.clearAllReadingStatistics();
      expect(await db.getAllReadingStatistics(), isEmpty);
    });

    test(
        'v90: also wipes book study_segments, keeps video segments, and writes '
        'no per-media tombstone (整体重置不立碑)', () async {
      final FushiDatabase db = await _openDb();
      await _seedSegment(db, mediaKind: kActivityMediaBook, mediaKey: 'book/A');
      await _seedSegment(db, mediaKind: kActivityMediaVideo, mediaKey: 'vid-1');

      await db.clearAllReadingStatistics();

      expect(
          await db.getStudySegmentsForMedia(
              mediaKind: kActivityMediaBook, mediaKey: 'book/A'),
          isEmpty);
      expect(
          await db.getStudySegmentsForMedia(
              mediaKind: kActivityMediaVideo, mediaKey: 'vid-1'),
          hasLength(1),
          reason: '清空阅读域不牵连视频域事实');
      expect(await db.getStudySegmentTombstones(), isEmpty,
          reason: '全量重置逐媒体立碑会永久毒化身份空间');
    });
  });

  group('clearAllVideoStatistics', () {
    test(
        'wipes every video-domain statistic but keeps user content and all '
        'reading-domain statistics', () async {
      final FushiDatabase db = await _openDb();
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

    test(
        'v90: also wipes video study_segments, keeps book segments, and writes '
        'no per-media tombstone', () async {
      final FushiDatabase db = await _openDb();
      await _seedSegment(db, mediaKind: kActivityMediaBook, mediaKey: 'book/A');
      await _seedSegment(db, mediaKind: kActivityMediaVideo, mediaKey: 'vid-1');

      await db.clearAllVideoStatistics();

      expect(
          await db.getStudySegmentsForMedia(
              mediaKind: kActivityMediaVideo, mediaKey: 'vid-1'),
          isEmpty);
      expect(
          await db.getStudySegmentsForMedia(
              mediaKind: kActivityMediaBook, mediaKey: 'book/A'),
          hasLength(1),
          reason: '清空视频域不牵连阅读域事实');
      expect(await db.getStudySegmentTombstones(), isEmpty);
    });
  });
}
