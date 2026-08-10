import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
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

  group('recordWatchFlush（P4 写侧收敛：桶粒度两表单入口）', () {
    test('同一份桶同事务落小时账本与日聚合，两表数字同源', () async {
      await db.recordWatchFlush(
        title: 'A',
        bookUid: 'u1',
        buckets: <(String, int, int)>[('2026-08-10', 9, 30000)],
      );

      final hourly = await db.getVideoHourlyLogsForDate('2026-08-10');
      expect(hourly.single.hour, 9);
      expect(hourly.single.watchTimeMs, 30000);

      final daily = (await db.getAllVideoWatchStatistics()).single;
      expect(daily.bookUid, 'u1');
      expect(daily.dateKey, '2026-08-10');
      expect(daily.watchTimeMs, 30000);
      expect(daily.subtitleChars, 0);
    });

    test('跨午夜桶各归各日（splitWatchTime 的桶归属零改动）', () async {
      // 23:59:50 → 00:00:10 的一次 flush：splitWatchTime 拆成两桶两天。
      await db.recordWatchFlush(
        title: 'A',
        bookUid: 'u1',
        buckets: <(String, int, int)>[
          ('2026-08-10', 23, 10000),
          ('2026-08-11', 0, 20000),
        ],
      );

      final day1 = await db.getVideoHourlyLogsForDate('2026-08-10');
      final day2 = await db.getVideoHourlyLogsForDate('2026-08-11');
      expect(day1.single.hour, 23);
      expect(day1.single.watchTimeMs, 10000);
      expect(day2.single.hour, 0);
      expect(day2.single.watchTimeMs, 20000);

      final rows = await db.getAllVideoWatchStatistics();
      expect(rows, hasLength(2));
      expect(rows.singleWhere((r) => r.dateKey == '2026-08-10').watchTimeMs,
          10000);
      expect(rows.singleWhere((r) => r.dateKey == '2026-08-11').watchTimeMs,
          20000);
    });

    test('字幕字数路径：按 cue 时刻 dateKey 进日聚合，不进小时账本', () async {
      await db.recordWatchFlush(
        title: 'A',
        bookUid: 'u1',
        subtitleChars: 12,
        subtitleCharsDateKey: '2026-08-10',
      );

      final daily = (await db.getAllVideoWatchStatistics()).single;
      expect(daily.subtitleChars, 12);
      expect(daily.watchTimeMs, 0);
      expect(await db.getVideoHourlyLogsForDate('2026-08-10'), isEmpty,
          reason: '小时账本只记观看时长，字幕字数不得写入');
    });

    test('subtitleChars > 0 而缺 subtitleCharsDateKey 是编程错误（快抛）', () {
      expect(
        () => db.recordWatchFlush(title: 'A', bookUid: 'u1', subtitleChars: 3),
        throwsArgumentError,
      );
    });

    test('recordWatchFlush 不产 activity 行（刻意差异：activity 是 stop 时刻 session 事件）',
        () async {
      // 防「顺手统一」：activity 行由 tracker.stop() 以 stop 时刻另写（跨午夜时
      // 全额归 stop 日），桶各归各日——两边 dateKey 口径差是故意的（ed2f36443f）。
      // 复合入口若开始派生 activity 行，本断言转红。
      await db.recordWatchFlush(
        title: 'A',
        bookUid: 'u1',
        buckets: <(String, int, int)>[
          ('2026-08-10', 23, 10000),
          ('2026-08-11', 0, 20000),
        ],
        subtitleChars: 5,
        subtitleCharsDateKey: '2026-08-11',
      );
      expect(await db.getRecentActivityEvents(limit: 5), isEmpty);
    });
  });
}
