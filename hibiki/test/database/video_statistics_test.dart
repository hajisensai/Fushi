import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late HibikiDatabase db;
  setUp(() => db = HibikiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('addVideoWatchStatistic accumulates by (title, dateKey)', () async {
    await db.addVideoWatchStatistic(
        title: 'A',
        dateKey: '2026-06-06',
        subtitleChars: 10,
        watchTimeMs: 1000);
    await db.addVideoWatchStatistic(
        title: 'A', dateKey: '2026-06-06', subtitleChars: 5, watchTimeMs: 500);
    final rows = await db.getAllVideoWatchStatistics();
    expect(rows.length, 1);
    expect(rows.first.subtitleChars, 15);
    expect(rows.first.watchTimeMs, 1500);
  });

  test('addVideoWatchStatistic separate rows for different dateKey', () async {
    await db.addVideoWatchStatistic(
        title: 'A',
        dateKey: '2026-06-06',
        subtitleChars: 10,
        watchTimeMs: 1000);
    await db.addVideoWatchStatistic(
        title: 'A', dateKey: '2026-06-07', subtitleChars: 7, watchTimeMs: 700);
    final rows = await db.getAllVideoWatchStatistics();
    expect(rows.length, 2);
  });

  test('addVideoHourlyWatchTime accumulates by (dateKey, hour)', () async {
    await db.addVideoHourlyWatchTime(
        dateKey: '2026-06-06', hour: 9, deltaMs: 100);
    await db.addVideoHourlyWatchTime(
        dateKey: '2026-06-06', hour: 9, deltaMs: 200);
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
