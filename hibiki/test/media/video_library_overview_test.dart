import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_library_overview.dart';

/// 统一合集 UI v2 Phase B：视频库概览纯推导单测。
void main() {
  final DateTime now = DateTime(2026, 7, 11, 12);

  VideoOverviewEntry entry({
    required String uid,
    String? title,
    int positionMs = 0,
    bool completed = false,
    DateTime? importedAt,
  }) {
    return VideoOverviewEntry(
      bookUid: uid,
      title: title ?? uid,
      lastPositionMs: positionMs,
      completed: completed,
      importedAt: importedAt,
    );
  }

  test('空库：全 0 + 无 hero', () {
    final VideoLibraryOverview o = computeVideoLibraryOverview(
      entries: const <VideoOverviewEntry>[],
      lastWatchedByUid: const <String, DateTime>{},
      now: now,
    );
    expect(o.total, 0);
    expect(o.unfinished, 0);
    expect(o.recentImports, 0);
    expect(o.heroUid, isNull);
  });

  test('统计三格：总数 / 未完成 / 近7天导入（边界：恰好第7天不计）', () {
    final VideoLibraryOverview o = computeVideoLibraryOverview(
      entries: <VideoOverviewEntry>[
        entry(uid: 'a', importedAt: now.subtract(const Duration(days: 1))),
        entry(
          uid: 'b',
          completed: true,
          importedAt: now.subtract(const Duration(days: 7)),
        ),
        entry(uid: 'c', importedAt: now.subtract(const Duration(days: 30))),
        entry(uid: 'd'), // importedAt null：不计近7天。
      ],
      lastWatchedByUid: const <String, DateTime>{},
      now: now,
    );
    expect(o.total, 4);
    expect(o.unfinished, 3);
    expect(o.recentImports, 1);
  });

  test('hero：只有「有痕迹且未看完」参选；看完的不选', () {
    final VideoLibraryOverview o = computeVideoLibraryOverview(
      entries: <VideoOverviewEntry>[
        entry(uid: 'done', positionMs: 999, completed: true),
        entry(uid: 'fresh'), // 无痕迹。
        entry(uid: 'watching', positionMs: 1200),
      ],
      lastWatchedByUid: const <String, DateTime>{},
      now: now,
    );
    expect(o.heroUid, 'watching');
    expect(o.heroLastWatched, isNull);
  });

  test('hero 排序：watch-stats（按 uid 键控）最新者胜；无统计行回退 importedAt', () {
    final VideoLibraryOverview o = computeVideoLibraryOverview(
      entries: <VideoOverviewEntry>[
        entry(
          uid: 'older-watch',
          title: 'A',
          positionMs: 1,
          importedAt: now.subtract(const Duration(days: 1)),
        ),
        entry(
          uid: 'newer-watch',
          title: 'B',
          positionMs: 1,
          importedAt: now.subtract(const Duration(days: 30)),
        ),
        entry(
          uid: 'no-stats-new-import',
          title: 'C',
          positionMs: 1,
          importedAt: now,
        ),
      ],
      // v39：映射按 bookUid 键控（页面已把遗留 title 行按 uid 合并后传入）。
      lastWatchedByUid: <String, DateTime>{
        'older-watch': now.subtract(const Duration(days: 3)),
        'newer-watch': now.subtract(const Duration(days: 2)),
      },
      now: now,
    );
    // 有统计行的优先于纯 importedAt；统计里 B 更新。
    expect(o.heroUid, 'newer-watch');
    expect(o.heroLastWatched, now.subtract(const Duration(days: 2)));
  });

  test('hero 全无统计行：importedAt 最新者胜；再兜底 uid 字典序（确定性）', () {
    final VideoLibraryOverview byImport = computeVideoLibraryOverview(
      entries: <VideoOverviewEntry>[
        entry(
            uid: 'x',
            positionMs: 1,
            importedAt: now.subtract(const Duration(days: 2))),
        entry(
            uid: 'y',
            positionMs: 1,
            importedAt: now.subtract(const Duration(days: 1))),
      ],
      lastWatchedByUid: const <String, DateTime>{},
      now: now,
    );
    expect(byImport.heroUid, 'y');

    final VideoLibraryOverview byUid = computeVideoLibraryOverview(
      entries: <VideoOverviewEntry>[
        entry(uid: 'b', positionMs: 1),
        entry(uid: 'a', positionMs: 1),
      ],
      lastWatchedByUid: const <String, DateTime>{},
      now: now,
    );
    expect(byUid.heroUid, 'a');
  });

  test('formatVideoPosition：m:ss 与 h:mm:ss', () {
    expect(formatVideoPosition(0), '0:00');
    expect(formatVideoPosition(59 * 1000), '0:59');
    expect(formatVideoPosition(754 * 1000), '12:34');
    expect(formatVideoPosition((3600 + 62) * 1000), '1:01:02');
  });

  test('latestWatchAtByKey：同键取最大 lastModified，非正毫秒丢弃', () {
    final Map<String, DateTime> m = latestWatchAtByKey(<(String, int)>[
      ('A', DateTime(2026, 1, 1).millisecondsSinceEpoch),
      ('A', DateTime(2026, 3, 1).millisecondsSinceEpoch),
      ('A', DateTime(2026, 2, 1).millisecondsSinceEpoch),
      ('B', 0),
    ]);
    expect(m['A'], DateTime(2026, 3, 1));
    expect(m.containsKey('B'), isFalse);
  });
}
