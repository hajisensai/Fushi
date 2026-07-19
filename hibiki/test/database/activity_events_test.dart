import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

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
  });
}
