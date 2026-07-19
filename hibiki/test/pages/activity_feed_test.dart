import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/pages/implementations/activity_feed.dart';

/// 首页 Activity 时间轴纯数据层的守卫：聚合分组 / session 归并 / 相对时间 / 时长窗口。
/// 全纯函数，无 sqlite3 依赖。

ActivityEventRow _ev({
  required String eventType,
  required String title,
  required String dateKey,
  required int timestampMs,
  String mediaType = 'book',
  String? mediaKey,
  int? durationMs,
  int? charsDelta,
}) =>
    ActivityEventRow(
      id: timestampMs, // 测试里用时间戳当 id 保证唯一即可
      eventType: eventType,
      mediaType: mediaType,
      title: title,
      mediaKey: mediaKey,
      dateKey: dateKey,
      timestampMs: timestampMs,
      durationMs: durationMs,
      charsDelta: charsDelta,
    );

void main() {
  group('activityRelativeTime', () {
    final DateTime now = DateTime(2026, 7, 19, 12, 0, 0);

    test('不足 1 分钟 = justNow', () {
      final rel = activityRelativeTime(
          now.subtract(const Duration(seconds: 30)).millisecondsSinceEpoch,
          now);
      expect(rel.unit, ActivityRelativeUnit.justNow);
    });

    test('分钟级', () {
      final rel = activityRelativeTime(
          now.subtract(const Duration(minutes: 45)).millisecondsSinceEpoch,
          now);
      expect(rel.unit, ActivityRelativeUnit.minutesAgo);
      expect(rel.value, 45);
    });

    test('小时级', () {
      final rel = activityRelativeTime(
          now.subtract(const Duration(hours: 8)).millisecondsSinceEpoch, now);
      expect(rel.unit, ActivityRelativeUnit.hoursAgo);
      expect(rel.value, 8);
    });

    test('天级', () {
      final rel = activityRelativeTime(
          now.subtract(const Duration(days: 3)).millisecondsSinceEpoch, now);
      expect(rel.unit, ActivityRelativeUnit.daysAgo);
      expect(rel.value, 3);
    });
  });

  group('aggregateActivityEvents', () {
    test('同天同书同类型合并成一条：时长/字数求和，最近时刻取最大', () {
      final int base = DateTime(2026, 7, 18, 9).millisecondsSinceEpoch;
      final List<ActivityEventRow> events = <ActivityEventRow>[
        _ev(
            eventType: kActivityRead,
            title: 'A',
            dateKey: '2026-07-18',
            timestampMs: base,
            durationMs: 60000,
            charsDelta: 100),
        _ev(
            eventType: kActivityRead,
            title: 'A',
            dateKey: '2026-07-18',
            timestampMs: base + 5 * 60000,
            durationMs: 120000,
            charsDelta: 200),
      ];
      final List<ActivityDateGroup> groups = aggregateActivityEvents(events);
      expect(groups.length, 1);
      expect(groups.first.entries.length, 1);
      final ActivityEntry e = groups.first.entries.first;
      expect(e.title, 'A');
      expect(e.totalDurationMs, 180000);
      expect(e.totalChars, 300);
      expect(e.latestTimestampMs, base + 5 * 60000);
    });

    test('间隔在 gap 内归并成 1 个 session，超过 gap 记 2 个', () {
      final int base = DateTime(2026, 7, 18, 9).millisecondsSinceEpoch;
      // 两次相隔 5 分钟（< 30min gap）→ 1 session
      final List<ActivityDateGroup> near =
          aggregateActivityEvents(<ActivityEventRow>[
        _ev(
            eventType: kActivityRead,
            title: 'A',
            dateKey: '2026-07-18',
            timestampMs: base,
            durationMs: 1),
        _ev(
            eventType: kActivityRead,
            title: 'A',
            dateKey: '2026-07-18',
            timestampMs: base + 5 * 60000,
            durationMs: 1),
      ]);
      expect(near.first.entries.first.sessionCount, 1);

      // 两次相隔 2 小时（> gap）→ 2 sessions
      final List<ActivityDateGroup> far =
          aggregateActivityEvents(<ActivityEventRow>[
        _ev(
            eventType: kActivityRead,
            title: 'A',
            dateKey: '2026-07-18',
            timestampMs: base,
            durationMs: 1),
        _ev(
            eventType: kActivityRead,
            title: 'A',
            dateKey: '2026-07-18',
            timestampMs: base + const Duration(hours: 2).inMilliseconds,
            durationMs: 1),
      ]);
      expect(far.first.entries.first.sessionCount, 2);
    });

    test('不同类型/不同书不合并；日期分组倒序、组内条目按最近时刻倒序', () {
      final int d18 = DateTime(2026, 7, 18, 9).millisecondsSinceEpoch;
      final int d19a = DateTime(2026, 7, 19, 8).millisecondsSinceEpoch;
      final int d19b = DateTime(2026, 7, 19, 20).millisecondsSinceEpoch;
      final List<ActivityDateGroup> groups =
          aggregateActivityEvents(<ActivityEventRow>[
        _ev(
            eventType: kActivityRead,
            title: 'A',
            dateKey: '2026-07-18',
            timestampMs: d18),
        _ev(
            eventType: kActivityWatch,
            mediaType: 'video',
            title: 'B',
            dateKey: '2026-07-19',
            timestampMs: d19a),
        _ev(
            eventType: kActivityAdded,
            title: 'C',
            dateKey: '2026-07-19',
            timestampMs: d19b),
      ]);
      // 两个日期组，19 在前（倒序）。
      expect(groups.map((g) => g.dateKey).toList(),
          <String>['2026-07-19', '2026-07-18']);
      // 19 号组内两条不合并（类型不同），按最近时刻倒序 → C(20:00) 在 B(08:00) 前。
      expect(groups.first.entries.map((e) => e.title).toList(),
          <String>['C', 'B']);
    });

    test('空输入返回空列表', () {
      expect(aggregateActivityEvents(const <ActivityEventRow>[]), isEmpty);
    });
  });

  group('sumTimeWindowsByDateKey', () {
    final DateTime now = DateTime(2026, 7, 19, 12);
    String key(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    test('今日/近7天/近30天/全部窗口正确求和', () {
      final Iterable<(String, int)> rows = <(String, int)>[
        (key(now), 1000), // 今日
        (key(now.subtract(const Duration(days: 3))), 2000), // 本周内
        (key(now.subtract(const Duration(days: 20))), 4000), // 本月内非本周
        (key(now.subtract(const Duration(days: 60))), 8000), // 仅全部
      ];
      final DashboardTimeStats s = sumTimeWindowsByDateKey(rows, now);
      expect(s.today, 1000);
      expect(s.week, 1000 + 2000);
      expect(s.month, 1000 + 2000 + 4000);
      expect(s.all, 1000 + 2000 + 4000 + 8000);
    });

    test('非正时长跳过', () {
      final DashboardTimeStats s = sumTimeWindowsByDateKey(
        <(String, int)>[(key(now), 0), (key(now), -5)],
        now,
      );
      expect(s.all, 0);
    });
  });
}
