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

    LookupMiningCounterRow counterU(
            String title, String key, int lookups, int mines) =>
        LookupMiningCounterRow(
          id: 0,
          bookKey: key,
          title: title,
          sourceType: 'video',
          dateKey: '2026-06-06',
          lookupCount: lookups,
          mineCount: mines,
        );

    FavoriteWordRow favU(String title, String? key, int i) => FavoriteWordRow(
          id: i,
          expression: 'e$i',
          reading: 'r$i',
          glossary: '',
          sourceType: 'video',
          bookKey: key,
          title: title,
          dateKey: '2026-06-06',
          createdAt: 0,
        );

    test('review-2 回归：sync 塌 空 的 watch 行经并集分组仍解析回 uid tile，计数不丢显', () {
      // sync applySnapshotToLocal 把 watch 行塌成 NULL-uid 权威行，但 counter
      // 行仍带 uid——并集分组下 owners('T')={uid-1} 唯一 → watch 遗留行归并进
      // uid-1 组，tile 带身份、计数命中，不再显示 0。
      final agg = computeVideoStats(
        stats: [rowU('T', null, '2026-06-06', 10, 1000)],
        counters: [counterU('T', 'uid-1', 6, 2)],
        completed: const [],
        now: now,
      );
      final tile = agg.byVideo.single;
      expect(tile.bookUid, 'uid-1', reason: '身份从 counter 宇宙解析回来');
      expect(tile.ms, 1000);
      expect(tile.lookups, 6, reason: '计数挂上，不再因两套判据错位显示 0');
      expect(tile.mines, 2);
      expect(tile.absorbedUnattributed, isTrue, reason: '删除连带判据同源');
    });

    test('review-3 回归：歧义 空 计数行不吸进任何 uid tile，也绝不游走', () {
      final agg = computeVideoStats(
        stats: [
          rowU('同名', 'uid-1', '2026-06-06', 10, 1000),
          rowU('同名', 'uid-2', '2026-06-06', 20, 2000),
        ],
        counters: [
          counterU('同名', 'uid-1', 5, 0),
          counterU('同名', '', 9, 3), // 迁移歧义遗留，内含 A/B 混合旧计数
        ],
        completed: const [],
        now: now,
      );
      expect(agg.byVideo.length, 2);
      final a = agg.byVideo.singleWhere((v) => v.bookUid == 'uid-1');
      final b = agg.byVideo.singleWhere((v) => v.bookUid == 'uid-2');
      expect(a.lookups, 5, reason: '只算自己身份桶，不吸混合遗留');
      expect(b.lookups, 0);
      expect(a.absorbedUnattributed || b.absorbedUnattributed, isFalse,
          reason: '谁也没吸收 → 删除不连带，计数不会在 tile 间游走');
    });

    test('review-4 回归：收藏按身份挂 tile，同名双 tile 不再各显全量', () {
      final agg = computeVideoStats(
        stats: [
          rowU('同名', 'uid-1', '2026-06-06', 10, 1000),
          rowU('同名', 'uid-2', '2026-06-06', 20, 2000),
        ],
        favorites: [
          favU('同名', 'uid-1', 1),
          favU('同名', 'uid-1', 2),
          favU('同名', 'uid-2', 3),
        ],
        completed: const [],
        now: now,
      );
      final a = agg.byVideo.singleWhere((v) => v.bookUid == 'uid-1');
      final b = agg.byVideo.singleWhere((v) => v.bookUid == 'uid-2');
      expect(a.favorites, 2);
      expect(b.favorites, 1, reason: '各算各的，不再两张 tile 都显示 3');
    });

    test('只有计数/收藏、没有 watch 行的身份不成 tile（tile 由观看行驱动）', () {
      final agg = computeVideoStats(
        stats: [rowU('A', 'uid-1', '2026-06-06', 10, 1000)],
        counters: [counterU('B', 'uid-9', 5, 0)],
        completed: const [],
        now: now,
      );
      expect(agg.byVideo.single.bookUid, 'uid-1',
          reason: 'uid-9 只有计数 → 不出 tile，数字只进汇总面板');
    });

    test('review2-2 回归：库表判同名歧义时，行宇宙唯一身份也不许吸收混合遗留', () {
      // 同名双视频都只有 v39 前的 NULL 遗留观看行（混着两者时长），用户只在
      // 其中一个查过一次词——行宇宙里唯一的身份组不得把混合遗留整体吸走。
      final agg = computeVideoStats(
        stats: [
          rowU('同名', null, '2026-06-01', 5, 500),
          rowU('同名', null, '2026-06-02', 7, 700),
        ],
        counters: [counterU('同名', 'uid-a', 1, 0)],
        completed: const [],
        now: now,
        ambiguousTitles: const <String>{'同名'},
      );
      expect(agg.byVideo, hasLength(1));
      final orphan = agg.byVideo.single;
      expect(orphan.bookUid, isNull,
          reason: '库表说同名有两个视频 → 遗留行保持无身份 tile，不归 uid-a');
      expect(orphan.ms, 1200);
      expect(orphan.lookups, 0, reason: 'uid-a 的查词不混进遗留 tile');
    });

    test('review2-9 回归：改名视频（一 uid 跨多 title 快照）的新 title 遗留行仍归并', () {
      final agg = computeVideoStats(
        stats: [
          rowU('旧名', 'uid-x', '2026-06-01', 10, 1000),
          rowU('新名', 'uid-x', '2026-06-05', 20, 2000),
          rowU('新名', null, '2026-06-02', 5, 500), // 新 title 的无身份遗留
        ],
        completed: const [],
        now: now,
      );
      expect(agg.byVideo, hasLength(1),
          reason: '组按全部 title 快照注册 owner，新 title 遗留不落孤儿 tile');
      expect(agg.byVideo.single.bookUid, 'uid-x');
      expect(agg.byVideo.single.ms, 3500);
    });
  });
}
