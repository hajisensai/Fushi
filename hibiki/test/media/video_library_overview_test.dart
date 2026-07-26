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
      // v57：VideoBooks.importedAt 统一 int 毫秒；测试助手仍收 DateTime 便于表达。
      importedAt: importedAt?.millisecondsSinceEpoch,
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

  // ---- BUG-848：hero 合集感知 Next-Up ----

  test('合集 Next-Up：最近活动是已完成集时 hero 前进到下一集（复现截图 S01E06→S01E10）', () {
    final DateTime d715 = DateTime(2026, 7, 15);
    final DateTime d716 = DateTime(2026, 7, 16);
    final DateTime d623 = DateTime(2026, 6, 23);
    final VideoLibraryOverview o = computeVideoLibraryOverview(
      entries: <VideoOverviewEntry>[
        entry(uid: 'e06', positionMs: 31 * 60 * 1000), // 在读 31:00，7-15
        entry(uid: 'e09', completed: true), // 已完成，7-16（最近活动）
        entry(uid: 'e10', positionMs: 5 * 1000), // 在读 0:05，6-23
      ],
      lastWatchedByUid: <String, DateTime>{
        'e06': d715,
        'e09': d716,
        'e10': d623,
      },
      collectionByUid: const <String, int>{'e06': 1, 'e09': 1, 'e10': 1},
      sortIndexByUid: const <String, int>{'e06': 6, 'e09': 9, 'e10': 10},
      now: DateTime(2026, 7, 17),
    );
    // 旧逻辑会停在更旧的在读集 e06；新逻辑前进到最靠后的有痕迹集 e10。
    expect(o.heroUid, 'e10');
    // 「上次观看」显示整组最近活动 7-16，而非 e10 自身的 6-23（修正观感）。
    expect(o.heroLastWatched, d716);
  });

  test('合集 Next-Up：看完最后有痕迹集后前进到全新下一集', () {
    final VideoLibraryOverview o = computeVideoLibraryOverview(
      entries: <VideoOverviewEntry>[
        entry(uid: 'a1', completed: true), // 已完成
        entry(uid: 'a2'), // 全新（无痕迹）
      ],
      lastWatchedByUid: <String, DateTime>{'a1': DateTime(2026, 7, 16)},
      collectionByUid: const <String, int>{'a1': 1, 'a2': 1},
      sortIndexByUid: const <String, int>{'a1': 1, 'a2': 2},
      now: DateTime(2026, 7, 17),
    );
    expect(o.heroUid, 'a2');
    expect(o.heroLastWatched, DateTime(2026, 7, 16));
  });

  test('合集：整季看完（续播目标仍已完成）→ 该合集不产 hero', () {
    final VideoLibraryOverview o = computeVideoLibraryOverview(
      entries: <VideoOverviewEntry>[
        entry(uid: 'b1', completed: true),
        entry(uid: 'b2', completed: true),
      ],
      lastWatchedByUid: <String, DateTime>{
        'b1': DateTime(2026, 7, 10),
        'b2': DateTime(2026, 7, 16),
      },
      collectionByUid: const <String, int>{'b1': 1, 'b2': 1},
      sortIndexByUid: const <String, int>{'b1': 1, 'b2': 2},
      now: DateTime(2026, 7, 17),
    );
    expect(o.heroUid, isNull);
  });

  test('合集：整季无任何观看痕迹 → 不进继续观看（不劝从头开始）', () {
    final VideoLibraryOverview o = computeVideoLibraryOverview(
      entries: <VideoOverviewEntry>[entry(uid: 'c1'), entry(uid: 'c2')],
      lastWatchedByUid: const <String, DateTime>{},
      collectionByUid: const <String, int>{'c1': 1, 'c2': 1},
      sortIndexByUid: const <String, int>{'c1': 1, 'c2': 2},
      now: DateTime(2026, 7, 17),
    );
    expect(o.heroUid, isNull);
  });

  test('合集单元 vs 散卡：按各自最近活跃时间跨单元择优', () {
    final VideoLibraryOverview o = computeVideoLibraryOverview(
      entries: <VideoOverviewEntry>[
        entry(uid: 'solo', positionMs: 1000), // 散卡在读，活跃 7-10
        entry(uid: 'e09', completed: true), // 合集：完成 7-16（更近）
        entry(uid: 'e10', positionMs: 5000), // 下一集在读
      ],
      lastWatchedByUid: <String, DateTime>{
        'solo': DateTime(2026, 7, 10),
        'e09': DateTime(2026, 7, 16),
        'e10': DateTime(2026, 6, 23),
      },
      collectionByUid: const <String, int>{'e09': 1, 'e10': 1},
      sortIndexByUid: const <String, int>{'e09': 9, 'e10': 10},
      now: DateTime(2026, 7, 17),
    );
    expect(o.heroUid, 'e10'); // 合集活跃 7-16 胜过散卡 7-10
  });

  test('远端同步进度（sync 已写入 lastPositionMs）照常参选 hero（BUG-848 #2 本地部分）', () {
    // sync 对有本地行的视频把远端胜者写进 lastPositionMs；此处等价于 positionMs>0。
    final VideoLibraryOverview o = computeVideoLibraryOverview(
      entries: <VideoOverviewEntry>[entry(uid: 'synced', positionMs: 42000)],
      lastWatchedByUid: const <String, DateTime>{},
      now: DateTime(2026, 7, 17),
    );
    expect(o.heroUid, 'synced');
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

  group('pickRemoteContinueEntry (#3 远端继续观看)', () {
    RemoteContinueEntry rc(
      String id, {
      int positionMs = 0,
      bool completed = false,
      int updatedAtMs = 0,
    }) =>
        RemoteContinueEntry(
          id: id,
          positionMs: positionMs,
          completed: completed,
          updatedAtMs: updatedAtMs,
        );

    test('空列表 → null', () {
      expect(pickRemoteContinueEntry(const <RemoteContinueEntry>[]), isNull);
    });

    test('无断点 / 已看完的都排除', () {
      expect(
        pickRemoteContinueEntry(<RemoteContinueEntry>[
          rc('a', positionMs: 0, updatedAtMs: 100), // 无断点
          rc('b', positionMs: 500, completed: true, updatedAtMs: 200), // 已看完
        ]),
        isNull,
      );
    });

    test('有断点未看完中取 updatedAtMs 最新者', () {
      final RemoteContinueEntry? best = pickRemoteContinueEntry(
        <RemoteContinueEntry>[
          rc('old', positionMs: 100, updatedAtMs: 1000),
          rc('newest', positionMs: 200, updatedAtMs: 3000),
          rc('mid', positionMs: 300, updatedAtMs: 2000),
        ],
      );
      expect(best?.id, 'newest');
    });

    test('updatedAtMs 全 0（host 未记时间戳）仍取第一个有断点未看完的', () {
      final RemoteContinueEntry? best = pickRemoteContinueEntry(
        <RemoteContinueEntry>[
          rc('a', positionMs: 100),
          rc('b', positionMs: 200),
        ],
      );
      expect(best?.id, 'a');
    });
  });
}
