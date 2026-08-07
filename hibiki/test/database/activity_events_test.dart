import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// activity_events 表（schema v49）的 CRUD 守卫：写入 / 倒序读取 / limit / 类别过滤 /
/// 按标题删除 / 清空。fresh DB 走 onCreate.createAll 建表，验证迁移与查询契约。

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('activity_events', () {
    test('addActivityEvent 落一行，getRecentActivityEvents 读回', () async {
      final db = await _openDb();
      await db.addActivityEvent(
        eventType: kActivityRead,
        mediaType: kActivityMediaBook,
        title: '吾輩は猫である',
        mediaKey: 'book-1',
        dateKey: '2026-07-18',
        timestampMs: 1000,
        durationMs: 60000,
        charsDelta: 300,
      );
      final List<ActivityEventRow> rows = await db.getRecentActivityEvents();
      expect(rows, hasLength(1));
      expect(rows.single.eventType, kActivityRead);
      expect(rows.single.mediaType, kActivityMediaBook);
      expect(rows.single.title, '吾輩は猫である');
      expect(rows.single.mediaKey, 'book-1');
      expect(rows.single.durationMs, 60000);
      expect(rows.single.charsDelta, 300);
    });

    test('按 timestampMs 倒序返回', () async {
      final db = await _openDb();
      for (final int ts in <int>[100, 300, 200]) {
        await db.addActivityEvent(
          eventType: kActivityRead,
          mediaType: kActivityMediaBook,
          title: 'T$ts',
          dateKey: '2026-07-18',
          timestampMs: ts,
        );
      }
      final List<ActivityEventRow> rows = await db.getRecentActivityEvents();
      expect(rows.map((ActivityEventRow r) => r.timestampMs).toList(),
          <int>[300, 200, 100]);
    });

    test('limit 截断最近 N 条', () async {
      final db = await _openDb();
      for (int i = 0; i < 5; i++) {
        await db.addActivityEvent(
          eventType: kActivityWatch,
          mediaType: kActivityMediaVideo,
          title: 'V$i',
          dateKey: '2026-07-18',
          timestampMs: i,
        );
      }
      final List<ActivityEventRow> rows =
          await db.getRecentActivityEvents(limit: 2);
      expect(rows, hasLength(2));
      // 最近两条 = timestamp 4, 3
      expect(rows.map((ActivityEventRow r) => r.timestampMs).toList(),
          <int>[4, 3]);
    });

    test('eventTypes 过滤只取指定类别', () async {
      final db = await _openDb();
      await db.addActivityEvent(
        eventType: kActivityRead,
        mediaType: kActivityMediaBook,
        title: 'R',
        dateKey: '2026-07-18',
        timestampMs: 1,
      );
      await db.addActivityEvent(
        eventType: kActivityWatch,
        mediaType: kActivityMediaVideo,
        title: 'W',
        dateKey: '2026-07-18',
        timestampMs: 2,
      );
      await db.addActivityEvent(
        eventType: kActivityAdded,
        mediaType: kActivityMediaBook,
        title: 'A',
        dateKey: '2026-07-18',
        timestampMs: 3,
      );
      final List<ActivityEventRow> onlyWatch = await db
          .getRecentActivityEvents(eventTypes: <String>[kActivityWatch]);
      expect(onlyWatch.map((ActivityEventRow r) => r.title).toList(),
          <String>['W']);
      final List<ActivityEventRow> readOrAdded = await db
          .getRecentActivityEvents(
              eventTypes: <String>[kActivityRead, kActivityAdded]);
      expect(readOrAdded.map((ActivityEventRow r) => r.title).toSet(),
          <String>{'R', 'A'});
    });

    test('deleteActivityEventsForTitle / clearAllActivityEvents', () async {
      final db = await _openDb();
      await db.addActivityEvent(
        eventType: kActivityRead,
        mediaType: kActivityMediaBook,
        title: 'Keep',
        dateKey: '2026-07-18',
        timestampMs: 1,
      );
      await db.addActivityEvent(
        eventType: kActivityRead,
        mediaType: kActivityMediaBook,
        title: 'Drop',
        dateKey: '2026-07-18',
        timestampMs: 2,
      );
      final int deleted = await db.deleteActivityEventsForTitle('Drop');
      expect(deleted, 1);
      expect((await db.getRecentActivityEvents()).single.title, 'Keep');

      await db.clearAllActivityEvents();
      expect(await db.getRecentActivityEvents(), isEmpty);
    });

    test('getActivityDailyTotals 按日聚合字符/时长，类别过滤，null 记 0', () async {
      final db = await _openDb();
      // game 同日两行（应合并），跨日一行；另有一条 read 不应混入。
      await db.addActivityEvent(
        eventType: kActivityGame,
        mediaType: kActivityMediaGame,
        title: 'GameA',
        dateKey: '2026-07-18',
        timestampMs: 1,
        durationMs: 60000,
        charsDelta: 300,
      );
      await db.addActivityEvent(
        eventType: kActivityGame,
        mediaType: kActivityMediaGame,
        title: 'GameB',
        dateKey: '2026-07-18',
        timestampMs: 2,
        durationMs: 30000,
        charsDelta: 200,
      );
      await db.addActivityEvent(
        eventType: kActivityGame,
        mediaType: kActivityMediaGame,
        title: 'GameA',
        dateKey: '2026-07-19',
        // null charsDelta / durationMs → COALESCE 记 0。
        timestampMs: 3,
      );
      await db.addActivityEvent(
        eventType: kActivityRead,
        mediaType: kActivityMediaBook,
        title: 'Book',
        dateKey: '2026-07-18',
        timestampMs: 4,
        durationMs: 99999,
        charsDelta: 9999,
      );
      final List<(String, int, int)> totals =
          await db.getActivityDailyTotals(kActivityGame);
      final Map<String, (int, int)> byDay = <String, (int, int)>{
        for (final (String dateKey, int chars, int durationMs) in totals)
          dateKey: (chars, durationMs),
      };
      expect(byDay.keys.toSet(), <String>{'2026-07-18', '2026-07-19'});
      // 2026-07-18: 两行合并 → 字符 500 / 时长 90000（read 行不混入）。
      expect(byDay['2026-07-18'], (500, 90000));
      // 2026-07-19: null 字段记 0。
      expect(byDay['2026-07-19'], (0, 0));
    });

    test('getActivityTitleTotalsForDay 按标题聚合，按时长降序，null 记 0', () async {
      final db = await _openDb();
      // 同日三行：Short 两行合并（时长 5000）、Long 一行（时长 40000）。
      await db.addActivityEvent(
        eventType: kActivityGame,
        mediaType: kActivityMediaGame,
        title: 'Short',
        dateKey: '2026-07-18',
        timestampMs: 1,
        durationMs: 3000,
        charsDelta: 10,
      );
      await db.addActivityEvent(
        eventType: kActivityGame,
        mediaType: kActivityMediaGame,
        title: 'Short',
        dateKey: '2026-07-18',
        timestampMs: 2,
        durationMs: 2000,
        // null charsDelta → 只累加另一行的 10。
      );
      await db.addActivityEvent(
        eventType: kActivityGame,
        mediaType: kActivityMediaGame,
        title: 'Long',
        dateKey: '2026-07-18',
        timestampMs: 3,
        durationMs: 40000,
        charsDelta: 500,
      );
      // 异日同标题不应混入。
      await db.addActivityEvent(
        eventType: kActivityGame,
        mediaType: kActivityMediaGame,
        title: 'Long',
        dateKey: '2026-07-19',
        timestampMs: 4,
        durationMs: 111,
        charsDelta: 111,
      );
      final List<(String, int, int)> totals =
          await db.getActivityTitleTotalsForDay(kActivityGame, '2026-07-18');
      // 时长降序：Long(40000) 先于 Short(5000)。
      expect(totals.map((r) => r.$1).toList(), <String>['Long', 'Short']);
      expect(totals[0], ('Long', 500, 40000));
      expect(totals[1], ('Short', 10, 5000));
    });

    test('watchDashboardDataChanges 在写入活动事件时 emit（首页自动刷新信号）', () async {
      final db = await _openDb();
      // .first 订阅后即挂上 tableUpdates；写入活动事件触发表变更 → 流 emit → 完成。
      final Future<void> emitted = db.watchDashboardDataChanges().first.timeout(
            const Duration(seconds: 3),
          );
      await db.addActivityEvent(
        eventType: kActivityRead,
        mediaType: kActivityMediaBook,
        title: 'X',
        dateKey: '2026-07-20',
        timestampMs: 1,
      );
      // 不抛 = 收到 emit（.first 自行取消订阅，onCancel 收敛不挂测试）。
      await emitted;
    });

    test('watchDashboardDataChanges 在写入阅读统计时也 emit', () async {
      final db = await _openDb();
      final Future<void> emitted = db.watchDashboardDataChanges().first.timeout(
            const Duration(seconds: 3),
          );
      await db.addReadingStatistic(
        title: 'Y',
        dateKey: '2026-07-20',
        charsRead: 10,
        timeMs: 1000,
      );
      await emitted;
    });

    test(
        'watchDashboardDataChanges 在视频改名（updateVideoBookTitle）时也 emit '
        '（P4：别页改名后首页 _videos 缓存自动失效重载的根通道）', () async {
      final db = await _openDb();
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'v-rename',
          title: '旧名',
          videoPath: '/tmp/v.mp4',
        ),
      );
      // 先插行再订阅：只验证「改名写穿 videoBooks 表 → 表级信号」这一步。
      final Future<void> emitted = db.watchDashboardDataChanges().first.timeout(
            const Duration(seconds: 3),
          );
      await db.updateVideoBookTitle('v-rename', '新名');
      await emitted;
      expect((await db.getVideoBookByBookUid('v-rename'))!.title, '新名');
    });
  });
}
