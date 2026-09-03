import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

// v92 起累加 DAO（addVideoWatchStatistic / addVideoHourlyWatchTime / recordWatchFlush）
// 已删：本地写入面只写 study_segments 事实表（新语义见 study_segments_test.dart）。
// video_watch_statistics / video_hourly_logs 冻结为 legacy，只剩同步落地的 OVERWRITE
// 版 set*；本文件只守 legacy 表的键控 / 读取契约与 video_books.completed_at。

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('setVideoWatchStatistic separate rows for different dateKey', () async {
    await db.setVideoWatchStatistic(VideoWatchStatisticsCompanion.insert(
        title: 'A',
        dateKey: '2026-06-06',
        subtitleChars: 10,
        watchTimeMs: 1000,
        lastModified: 1));
    await db.setVideoWatchStatistic(VideoWatchStatisticsCompanion.insert(
        title: 'A',
        dateKey: '2026-06-07',
        subtitleChars: 7,
        watchTimeMs: 700,
        lastModified: 1));
    final rows = await db.getAllVideoWatchStatistics();
    expect(rows.length, 2);
  });

  test('setVideoHourlyLog keyed by (dateKey, hour)', () async {
    await db.setVideoHourlyLog(
        dateKey: '2026-06-06', hour: 9, watchTimeMs: 100);
    await db.setVideoHourlyLog(
        dateKey: '2026-06-06', hour: 9, watchTimeMs: 300);
    final rows = await db.getVideoHourlyLogsForDate('2026-06-06');
    expect(rows.length, 1);
    expect(rows.first.watchTimeMs, 300);
  });

  test('markVideoCompleted is idempotent first-write', () async {
    await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'u1', title: 'A', videoPath: '/v.mp4'));
    final t1 = DateTime(2026, 6, 6, 10);
    final t2 = DateTime(2026, 6, 6, 12);
    await db.markVideoCompleted('u1', t1);
    await db.markVideoCompleted('u1', t2); // 不覆盖
    final row = await db.getVideoBookByBookUid('u1');
    expect(row!.completedAt, t1);
  });

  test('VideoBooks.completedAt defaults to null', () async {
    await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'u2', title: 'B', videoPath: '/v2.mp4'));
    final row = await db.getVideoBookByBookUid('u2');
    expect(row!.completedAt, isNull);
  });
}
