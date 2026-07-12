/// 统一合集 UI v2 Phase B：视频库「继续观看 hero + 媒体库概览」纯推导（widget-free）。
///
/// 数据边界（诚实外显，不造假）：
/// * `VideoBooks` 无总时长列 → 不推导百分比，hero 只给「已看至 mm:ss」。
/// * `VideoBooks` 无 lastWatchedAt 列 → 「上次观看」从 `VideoWatchStatistics`
///   （title+dateKey 键控，取该 title 的 max(lastModified)）推导；无统计行的视频
///   退回 importedAt 排序，且不显示「上次观看」。
library;

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
  final DateTime? importedAt;
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

  /// 继续观看候选：有观看痕迹（lastPositionMs>0）且未看完的视频中「最近看过」
  /// 的一条（watch-stats lastModified 最新 → 回退 importedAt 最新 → uid 字典序
  /// 兜底保证确定性）。全无候选 = null（hero 区整体隐藏）。
  final String? heroUid;

  /// hero 的上次观看时间（该 title 无统计行时为 null，UI 不显示该行）。
  final DateTime? heroLastWatched;
}

/// 从全量行 + 每 title 最近观看时间推导概览。
VideoLibraryOverview computeVideoLibraryOverview({
  required List<VideoOverviewEntry> entries,
  required Map<String, DateTime> lastWatchedByTitle,
  required DateTime now,
}) {
  int unfinished = 0;
  int recentImports = 0;
  VideoOverviewEntry? hero;
  DateTime? heroWatched;
  for (final VideoOverviewEntry e in entries) {
    if (!e.completed) unfinished++;
    final DateTime? imported = e.importedAt;
    if (imported != null && now.difference(imported).inDays < 7) {
      recentImports++;
    }
    if (e.completed || e.lastPositionMs <= 0) continue;
    final DateTime? watched = lastWatchedByTitle[e.title];
    if (hero == null || _heroRank(e, watched, hero, heroWatched) > 0) {
      hero = e;
      heroWatched = watched;
    }
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
  final DateTime? ai = a.importedAt;
  final DateTime? bi = b.importedAt;
  if (ai != null || bi != null) {
    if (ai == null) return -1;
    if (bi == null) return 1;
    final int c = ai.compareTo(bi);
    if (c != 0) return c;
  }
  return b.bookUid.compareTo(a.bookUid);
}

/// 毫秒 → `m:ss` / `h:mm:ss`（视频「已看至」外显；无共享格式化器，本处即真相源）。
String formatVideoPosition(int positionMs) {
  final int totalSeconds = positionMs ~/ 1000;
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds % 3600) ~/ 60;
  final int seconds = totalSeconds % 60;
  final String ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    final String mm = minutes.toString().padLeft(2, '0');
    return '$hours:$mm:$ss';
  }
  return '$minutes:$ss';
}

/// `VideoWatchStatistics` 行投影（title + lastModified 毫秒）→ 每 title 最近
/// 观看时间映射。页面把 DAO 行映射成 (title, lastModifiedMs) 元组传入。
Map<String, DateTime> latestWatchByTitle(
  Iterable<(String, int)> titleAndLastModifiedMs,
) {
  final Map<String, DateTime> out = <String, DateTime>{};
  for (final (String title, int ms) in titleAndLastModifiedMs) {
    if (ms <= 0) continue;
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(ms);
    final DateTime? prev = out[title];
    if (prev == null || at.isAfter(prev)) out[title] = at;
  }
  return out;
}
