/// 统一合集 UI v2 Phase B：视频库「继续观看 hero + 媒体库概览」纯推导（widget-free）。
///
/// 数据边界（诚实外显，不造假）：
/// * `VideoBooks` 无总时长列 → 不推导百分比，hero 只给「已看至 mm:ss」。
/// * `VideoBooks` 无 lastWatchedAt 列 → 「上次观看」从 `VideoWatchStatistics`
///   推导（v39 起按 bookUid 键控；迁移前遗留 NULL-uid 行由页面按 title 回退合并
///   后传入）；无统计行的视频退回 importedAt 排序，且不显示「上次观看」。
///
/// BUG-848：hero 选集**合集感知**（复用 [continueMemberIndex] 的 Jellyfin Next-Up 语义）。
/// 旧逻辑逐集独立、排除所有已完成集：看完某集后 hero 反被踢出候选、回退到更旧的在读集。
/// 现按「合集为单元」——组内跑 [continueMemberIndex]（看完最后有痕迹的一集 → 前进下一集），
/// 单元活跃时间取成员观看时间戳最大值，再跨单元挑最近活跃者。散卡视频各自成单元（仅
/// 在读时可续）。本地视频的**远端同步进度**已由 sync 写进 `lastPositionMs`，故「远端进度
/// 也算」对有本地行的视频天然成立（纯流播/无本地行的远端占位视频不在候选，属独立特性）。
library;

import 'package:fushi/src/media/collections/collection_continue.dart';
import 'package:fushi/src/utils/misc/hibiki_time_format.dart';

/// 一条视频行参与概览推导的最小投影（页面从 `VideoBookRow` 映射；测试直接构造）。
class VideoOverviewEntry {
  const VideoOverviewEntry({
    required this.bookUid,
    required this.title,
    required this.lastPositionMs,
    required this.completed,
    this.importedAt,
  });

  final String bookUid;
  final String title;
  final int lastPositionMs;
  final bool completed;

  /// 导入毫秒戳（`VideoBooks.importedAt`，v57 起 int 毫秒）；null = 无导入时间。
  final int? importedAt;
}

/// 概览推导结果：三格统计 + 可空 hero（继续观看候选）。
class VideoLibraryOverview {
  const VideoLibraryOverview({
    required this.total,
    required this.unfinished,
    required this.recentImports,
    this.heroUid,
    this.heroLastWatched,
  });

  /// 库内视频总数。
  final int total;

  /// 未看完数（completedAt 为空）。
  final int unfinished;

  /// 近 7 天导入数（importedAt 距 now < 7 天；importedAt 为空不计）。
  final int recentImports;

  /// 继续观看续播目标 uid（Next-Up，BUG-848）：把库拆成「单元」（合集 / 散卡），每个
  /// 单元推一个续播目标（合集走 [continueMemberIndex]：看完最后有痕迹一集 → 下一集；散卡
  /// 仅在读时），再跨单元挑「最近活跃」者。全无候选 = null（hero 区整体隐藏）。
  final String? heroUid;

  /// hero 的上次观看时间（其所属单元成员观看时间戳最大值；单元无统计行时为 null，UI
  /// 不显示该行）。合集单元取整组最近活跃时间——修正「hero 前进到下一集却显示旧集时间戳」。
  final DateTime? heroLastWatched;
}

/// 从全量行 + 每 uid 最近观看时间 + 合集分组映射推导概览。
///
/// [collectionByUid] / [sortIndexByUid]：uid → 其主折叠合集 id / 组内 sortIndex（页面从
/// `_primaryCollectionByEntry` / `_memberSortIndex` 投影，键去掉 `video|` 前缀）。都留空 →
/// 全部视为散卡（退化为旧的逐集选集，向后兼容既有单测）。
VideoLibraryOverview computeVideoLibraryOverview({
  required List<VideoOverviewEntry> entries,
  required Map<String, DateTime> lastWatchedByUid,
  required DateTime now,
  Map<String, int> collectionByUid = const <String, int>{},
  Map<String, int> sortIndexByUid = const <String, int>{},
}) {
  int unfinished = 0;
  int recentImports = 0;
  // 单元化：合集成员按 collectionId 归组，散卡各自成单元（用 null 分支）。
  final Map<int, List<VideoOverviewEntry>> byCollection =
      <int, List<VideoOverviewEntry>>{};
  final List<VideoOverviewEntry> standalone = <VideoOverviewEntry>[];
  for (final VideoOverviewEntry e in entries) {
    if (!e.completed) unfinished++;
    final int? imported = e.importedAt;
    if (imported != null &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(imported)).inDays <
            7) {
      recentImports++;
    }
    final int? cid = collectionByUid[e.bookUid];
    if (cid == null) {
      standalone.add(e);
    } else {
      (byCollection[cid] ??= <VideoOverviewEntry>[]).add(e);
    }
  }

  VideoOverviewEntry? hero;
  DateTime? heroWatched;
  void consider(VideoOverviewEntry resume, DateTime? activity) {
    if (hero == null || _heroRank(resume, activity, hero!, heroWatched) > 0) {
      hero = resume;
      heroWatched = activity;
    }
  }

  // 散卡单元：仅「有断点且未看完」可续（与旧逻辑同口径）。
  for (final VideoOverviewEntry e in standalone) {
    if (e.completed || e.lastPositionMs <= 0) continue;
    consider(e, lastWatchedByUid[e.bookUid]);
  }

  // 合集单元：组内按 sortIndex 排序后跑 continueMemberIndex（Jellyfin Next-Up）。
  for (final MapEntry<int, List<VideoOverviewEntry>> ce
      in byCollection.entries) {
    final List<VideoOverviewEntry> members = ce.value
      ..sort((VideoOverviewEntry a, VideoOverviewEntry b) {
        final int ai = sortIndexByUid[a.bookUid] ?? 1 << 30;
        final int bi = sortIndexByUid[b.bookUid] ?? 1 << 30;
        if (ai != bi) return ai.compareTo(bi);
        return a.bookUid.compareTo(b.bookUid);
      });
    // 整组无痕迹（从没看过这个系列）→ 不进「继续观看」（不劝人从头开始）。
    final bool anyTrace = members.any(
      (VideoOverviewEntry m) => m.completed || m.lastPositionMs > 0,
    );
    if (!anyTrace) continue;
    final int idx = continueMemberIndex(<CollectionMemberProgress>[
      for (final VideoOverviewEntry m in members)
        CollectionMemberProgress(
          positionMs: m.lastPositionMs,
          completed: m.completed,
        ),
    ]);
    final VideoOverviewEntry resume = members[idx];
    // 续播目标仍是已完成集 = 整季看完、无下一集可续 → 该单元不产 hero。
    if (resume.completed) continue;
    // 单元活跃时间 = 成员观看时间戳最大值（最近看过该系列的时间，也是 hero「上次观看」外显）。
    DateTime? activity;
    for (final VideoOverviewEntry m in members) {
      final DateTime? w = lastWatchedByUid[m.bookUid];
      if (w != null && (activity == null || w.isAfter(activity))) {
        activity = w;
      }
    }
    consider(resume, activity);
  }

  return VideoLibraryOverview(
    total: entries.length,
    unfinished: unfinished,
    recentImports: recentImports,
    heroUid: hero?.bookUid,
    heroLastWatched: heroWatched,
  );
}

/// 候选 [a] 是否优于当前 hero [b]：>0 = a 胜。排序键：watch-stats 时间戳
/// （非空优先，新者胜）→ importedAt（非空优先，新者胜）→ bookUid 字典序小者胜
/// （纯确定性兜底）。
int _heroRank(
  VideoOverviewEntry a,
  DateTime? aWatched,
  VideoOverviewEntry b,
  DateTime? bWatched,
) {
  if (aWatched != null || bWatched != null) {
    if (aWatched == null) return -1;
    if (bWatched == null) return 1;
    final int c = aWatched.compareTo(bWatched);
    if (c != 0) return c;
  }
  final int? ai = a.importedAt;
  final int? bi = b.importedAt;
  if (ai != null || bi != null) {
    if (ai == null) return -1;
    if (bi == null) return 1;
    final int c = ai.compareTo(bi);
    if (c != 0) return c;
  }
  return b.bookUid.compareTo(a.bookUid);
}

/// 远端「继续观看」候选的最小投影（页面从 `RemoteVideoInfo` 映射；测试直接构造）。
class RemoteContinueEntry {
  const RemoteContinueEntry({
    required this.id,
    required this.positionMs,
    required this.completed,
    required this.updatedAtMs,
  });

  final String id;

  /// host 端记录的断点（毫秒，0=从头）。
  final int positionMs;

  /// 是否看完（页面由 positionMs / durationMs 派生——远端无 completed 列）。
  final bool completed;

  /// host 端断点最后更新时间（epoch 毫秒，0=无记录）。用于跨候选/跨本地排序。
  final int updatedAtMs;
}

/// 纯函数：从远端视频投影里挑「继续观看」候选——有断点（positionMs>0）、未看完，
/// 按 [RemoteContinueEntry.updatedAtMs]（host 端上次播放时间戳）最新者。无则 null。
///
/// 纯流播远端视频无本地进度行，故不进 [computeVideoLibraryOverview] 的本地 hero
/// 推导（其合集 Next-Up 逻辑按本地 uid 键控）；本函数独立挑远端候选，页面层再按
/// 时间戳与本地 hero 比较取胜者，让「继续观看」也覆盖互联远端视频（用户反馈）。
RemoteContinueEntry? pickRemoteContinueEntry(
    List<RemoteContinueEntry> entries) {
  RemoteContinueEntry? best;
  for (final RemoteContinueEntry e in entries) {
    if (e.completed || e.positionMs <= 0) continue;
    if (best == null || e.updatedAtMs > best.updatedAtMs) best = e;
  }
  return best;
}

/// 毫秒 → `m:ss` / `h:mm:ss`（视频「已看至」外显）。委托 [FushiTimeFormat.clock]。
String formatVideoPosition(int positionMs) =>
    FushiTimeFormat.clock(Duration(milliseconds: positionMs));

/// `VideoWatchStatistics` 行投影（键 + lastModified 毫秒）→ 每键最近观看时间
/// 映射。键 = bookUid（v39 新行）或 title（迁移遗留 NULL-uid 行的回退键），
/// 页面各建一张再按 uid 优先合并。
Map<String, DateTime> latestWatchAtByKey(
  Iterable<(String, int)> keyAndLastModifiedMs,
) {
  final Map<String, DateTime> out = <String, DateTime>{};
  for (final (String key, int ms) in keyAndLastModifiedMs) {
    if (ms <= 0) continue;
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(ms);
    final DateTime? prev = out[key];
    if (prev == null || at.isAfter(prev)) out[key] = at;
  }
  return out;
}
