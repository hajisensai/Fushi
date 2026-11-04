import 'package:fushi/media.dart' show MediaItem, ReaderFushiSource;
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show ShelfReadStatus, classifyShelfReadStatus;
import 'package:fushi_engine/media/video/m3u8_playlist.dart'
    show videoWatchFraction;

// 从 home_dashboard_page.dart 抽出的「继续」区纯判据：首页卡片与 Android 桌面
// 小组件快照（`widget_snapshot_source.dart`）共用同一份，数字不会各算一套。
// 首页文件 re-export 本文件，既有测试的 import 路径不变。

/// 首页「继续」区是否收这本书：与书架读完筛选 / hero 计数同一判据
/// [classifyShelfReadStatus]（`EpubBooks.completedAt` 优先于进度）。
///
/// BUG-2918：阅读器落库的位置是末页**首个可见字符**，读到最后一页 position 也
/// 永远 < duration；旧判据只看 `0 < position < duration`，读完（含阅读器自动
/// 写入的 completedAt）的书仍以四舍五入出的 100% 留在「继续」区。
/// [completedBookKeys] 的键是 bookKey（standalone SRT 等无 bookKey 的条目回退
/// mediaIdentifier，查不到即按进度判，与旧行为一致）。
bool isDashboardContinueBook(MediaItem item, Set<String> completedBookKeys) {
  final String bookKey =
      ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
      item.mediaIdentifier;
  return classifyShelfReadStatus(
        completed: completedBookKeys.contains(bookKey),
        position: item.position,
        duration: item.duration,
      ) ==
      ShelfReadStatus.reading;
}

/// 「继续」视频竖卡的封面路径：按「作品海报（合集主封面）→ 这一集自己的封面 →
/// 同合集其它集的封面」顺序取**第一张磁盘上真存在**的（与视频页合集卡
/// `_collectionRowCoverProvider` 同口径：自有封面不在就借成员的）。
///
/// 反馈 5CTpiVJ7-v：此前只认 `海报 ?? 这一集封面` 一个候选，合集主封面指向的
/// 文件不在（换盘 / 清缓存 / 刮削改过路径）或这一集还没抽帧时，主角卡与横滑卡
/// 直接掉成「图标 + 名字」占位，而视频页同一部作品照样有封面。全部候选都不存在
/// 返回 null（调用方画占位）。
///
/// [exists] 是 async：候选可能落在网络盘（rclone / SMB 挂载）上，挂载端目录缓存
/// 过期时一次 stat 要逐级重列目录、单次数秒。旧实现在 build 里同步 `existsSync`，
/// 读有声书时统计表每几秒一写就触发首页重建 → 主 isolate 冻结数秒，同 isolate 上
/// 的互联 host 端点（含 `/api/ping`）与 UI 一起卡死（BUG-3756）。
///
/// [collectionCovers] 是合集自有层的候选（自有封面 → 原盘竖版盘面图，按
/// `collectionOwnCoverCandidates` 的顺序），取第一张存在的。
Future<String?> dashboardVideoCoverPath({
  required Iterable<String?> collectionCovers,
  required String? ownCover,
  Iterable<String?> memberCovers = const <String?>[],
  required Future<bool> Function(String path) exists,
}) async {
  Future<bool> usable(String? path) async =>
      path != null && path.isNotEmpty && await exists(path);
  for (final String? path in collectionCovers) {
    if (await usable(path)) return path;
  }
  if (await usable(ownCover)) return ownCover;
  // 逐个惰性取：找到第一张存在的就停。
  for (final String? path in memberCovers) {
    if (await usable(path)) return path;
  }
  return null;
}

/// 「继续」视频卡的进度（[dashboardVideoContinueProgress] 的结果）。
///
/// - [fraction]：封面底部进度条（0..1）；null = 不画。
/// - [episode]：集数角标「第 N 集」（1 起）；null = 不是多集。
/// - [percent]：单视频百分比角标（知道总时长时）。
/// - [positionMs]：前两者都给不出时退回「看到的时间点」角标。
typedef DashboardVideoProgress = ({
  double? fraction,
  int? episode,
  int? percent,
  int? positionMs,
});

/// 首页「继续」视频卡的进度口径（反馈「小说有进度显示，视频缺了进度显示」）。
///
/// 此前只有单行多集播放列表画进度（[videoWatchFraction]：看到第几集），合集里的
/// 某一集与单视频一律不画——`VideoBooks` 不存总时长，算不出百分比。现在：
/// - 单行多集播放列表（[playlistEpisodeCount] ≥ 2）：角标「第 N 集」，进度条仍是
///   集粒度（`currentEpisode / 集数`）；
/// - 合集里的一集（[collectionEpisode] 非空）：角标「第 N 集」，进度条是这一集
///   看到哪（[durationMs] 已知时）；
/// - 单视频：[durationMs] 已知 → 进度条 + 百分比角标，否则角标退回看到的时间点。
///
/// [durationMs] 来自视频规格探测缓存（`VideoFileSpecs`），流媒体 / 没探测过的
/// 文件为 null。纯函数，单测直接覆盖各分支。
DashboardVideoProgress dashboardVideoContinueProgress({
  required bool completed,
  required int positionMs,
  required int? durationMs,
  required int currentEpisode,
  required int playlistEpisodeCount,
  int? collectionEpisode,
  int collectionEpisodeCount = 0,
}) {
  final int? total = durationMs;
  final double? inEpisode = total != null && total > 0 && positionMs > 0
      ? (positionMs / total).clamp(0.0, 1.0)
      : null;
  if (playlistEpisodeCount >= 2) {
    return (
      fraction: videoWatchFraction(
        completed: completed,
        currentEpisode: currentEpisode,
        episodeCount: playlistEpisodeCount,
      ),
      episode: currentEpisode.clamp(0, playlistEpisodeCount - 1) + 1,
      percent: null,
      positionMs: null,
    );
  }
  if (collectionEpisode != null && collectionEpisodeCount >= 2) {
    return (
      fraction: inEpisode,
      episode: collectionEpisode,
      percent: null,
      positionMs: null,
    );
  }
  if (inEpisode != null) {
    return (
      fraction: inEpisode,
      episode: null,
      percent: (inEpisode * 100).round(),
      positionMs: null,
    );
  }
  return (
    fraction: null,
    episode: null,
    percent: null,
    positionMs: positionMs > 0 ? positionMs : null,
  );
}
