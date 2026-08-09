import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/video_stat_aggregates.dart';
import 'package:fushi_core/fushi_core.dart';

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

  test('by-video sorted by watch time desc (删字数后按 ms 排行)', () {
    final stats = [
      _row('A', '2026-06-06', 99, 1000),
      _row('B', '2026-06-06', 10, 5000),
    ];
    final agg = computeVideoStats(stats: stats, completed: const [], now: now);
    // 字数 A 多但观看时长 B 多 → B 排第一。
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

  group('v76 身份分组（v39 展示层收尾）', () {
    VideoWatchStatisticRow rowU(
            String title, String? uid, String dateKey, int chars, int ms) =>
        VideoWatchStatisticRow(
          id: 0,
          title: title,
          bookUid: uid,
          dateKey: dateKey,
          subtitleChars: chars,
          watchTimeMs: ms,
          lastModified: 0,
        );

    test('同名双视频各自一张 tile，不再合并（互串的另一半根治）', () {
      final agg = computeVideoStats(
        stats: [
          rowU('同名', 'uid-1', '2026-06-06', 10, 1000),
          rowU('同名', 'uid-2', '2026-06-06', 20, 2000),
        ],
        completed: const [],
        now: now,
      );
      expect(agg.byVideo.length, 2);
      expect(agg.byVideo.map((v) => v.bookUid).toSet(), {'uid-1', 'uid-2'});
      expect(agg.byVideo.every((v) => v.title == '同名'), isTrue);
    });

    test('unique-title 遗留 NULL 行并入唯一 uid tile（主流场景仍单 tile）', () {
      final agg = computeVideoStats(
        stats: [
          rowU('A', 'uid-1', '2026-06-06', 10, 1000),
          rowU('A', null, '2026-06-01', 5, 500), // v39 前遗留
        ],
        completed: const [],
        now: now,
      );
      expect(agg.byVideo.length, 1, reason: '一个视频跨新旧数据仍是单 tile');
      final v = agg.byVideo.single;
      expect(v.bookUid, 'uid-1');
      expect(v.ms, 1500, reason: '遗留行时长并入');
      expect(v.absorbedUnattributed, isTrue, reason: '删除连带判据');
    });

    test('歧义遗留行（同名多 uid）独立成无身份 tile，不瞎归属', () {
      final agg = computeVideoStats(
        stats: [
          rowU('同名', 'uid-1', '2026-06-06', 10, 1000),
          rowU('同名', 'uid-2', '2026-06-06', 20, 2000),
          rowU('同名', null, '2026-06-01', 5, 500),
        ],
        completed: const [],
        now: now,
      );
      expect(agg.byVideo.length, 3);
      final orphan = agg.byVideo.singleWhere((v) => v.bookUid == null);
      expect(orphan.ms, 500);
      expect(
          agg.byVideo
              .where((v) => v.bookUid != null)
              .every((v) => !v.absorbedUnattributed),
          isTrue,
          reason: '歧义时谁也不吸收，删除不连带');
    });
  });
}
