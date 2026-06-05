import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/video_stat_aggregates.dart';
import 'package:hibiki_core/hibiki_core.dart';

VideoWatchStatisticRow _row(String title, String dateKey, int chars, int ms) =>
    VideoWatchStatisticRow(
      id: 0,
      title: title,
      dateKey: dateKey,
      subtitleChars: chars,
      watchTimeMs: ms,
      lastModified: 0,
    );

void main() {
  final now = DateTime(2026, 6, 6, 12);

  test('today/week/month/all buckets accumulate', () {
    final stats = [
      _row('A', '2026-06-06', 100, 1000), // today
      _row('A', '2026-06-01', 50, 500), // within week & month
      _row('B', '2026-05-10', 30, 300), // within month only
      _row('B', '2026-01-01', 10, 100), // all only
    ];
    final agg = computeVideoStats(stats: stats, completed: const [], now: now);
    expect(agg.todayChars, 100);
    expect(agg.todayMs, 1000);
    expect(agg.weekChars, 150);
    expect(agg.monthChars, 180);
    expect(agg.allChars, 190);
    expect(agg.allMs, 1900);
  });

  test('by-video sorted by chars desc', () {
    final stats = [
      _row('A', '2026-06-06', 10, 0),
      _row('B', '2026-06-06', 99, 0),
    ];
    final agg = computeVideoStats(stats: stats, completed: const [], now: now);
    expect(agg.byVideo.first.title, 'B');
    expect(agg.byVideo.length, 2);
  });

  test('daily has 30 entries ending today', () {
    final agg = computeVideoStats(
      stats: [_row('A', '2026-06-06', 5, 0)],
      completed: const [],
      now: now,
    );
    expect(agg.daily.length, 30);
    expect(agg.daily.last.dateKey, '2026-06-06');
    expect(agg.daily.last.chars, 5);
  });

  test('completed counts by timestamp bucket (dedup via single timestamp)', () {
    final agg = computeVideoStats(
      stats: const [],
      // 6-06 今日; 5-20 在 30 天月窗口内但超出 7 天周窗口; 1-01 仅在全部内。
      completed: [
        DateTime(2026, 6, 6, 9),
        DateTime(2026, 5, 20),
        DateTime(2026, 1, 1),
      ],
      now: now,
    );
    expect(agg.todayCompleted, 1);
    expect(agg.weekCompleted, 1);
    expect(agg.monthCompleted, 2);
    expect(agg.allCompleted, 3);
  });

  test('empty inputs yield zeroed aggregate with 30 empty daily bars', () {
    final agg =
        computeVideoStats(stats: const [], completed: const [], now: now);
    expect(agg.allChars, 0);
    expect(agg.allCompleted, 0);
    expect(agg.byVideo, isEmpty);
    expect(agg.daily.length, 30);
    expect(agg.daily.every((d) => d.chars == 0), isTrue);
  });
}
