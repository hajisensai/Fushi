import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteVideoPlayedMark, RemoteVideoSource;

/// 多个远端视频来源**并存**时的合并与归属（反馈 k5Ey2AglAf）。
///
/// 远端视频来源（互联 host live 库 / Jellyfin·Emby 媒体服务器 / 云盘目录）此前是
/// 「三选一」：开了 Jellyfin 混排，云盘清单就不再读，云盘视频从首页 / 剧集 / 全部
/// 视频里整批消失——而开关的说明写的是「混入」。现在所有可用来源一起列，每条远端
/// 视频记住**产出它的那个来源**：开播 / 下载 / 取封面 / 标记已看 / 删除都按条目
/// 找回它自己的来源，不再有「页面当前只有一个来源」这个假设。
///
/// 同一条视频出现在多个来源（同一个 id：互联 host 与云盘目录都按 bookUid 出 id）时
/// 只留优先级最高的那一条——优先级就是 [sources] 的顺序（互联 > 媒体服务器 > 云盘，
/// 互联能流播 / 续传 / 跨端断点，云盘只能整片下载）。
class RemoteVideoSourceListing {
  const RemoteVideoSourceListing({required this.source, required this.videos});

  final RemoteVideoSource source;
  final List<RemoteVideoInfo> videos;
}

/// [mergeRemoteVideoListings] 的结果：合并后的清单 + 每条的归属来源。
class MergedRemoteVideos {
  const MergedRemoteVideos({required this.videos, required this.owners});

  static const MergedRemoteVideos empty = MergedRemoteVideos(
    videos: <RemoteVideoInfo>[],
    owners: <String, RemoteVideoSource>{},
  );

  /// 按来源优先级、来源内原顺序排列；id 不重复。
  final List<RemoteVideoInfo> videos;

  /// 远端视频 id → 产出它的来源。
  final Map<String, RemoteVideoSource> owners;
}

/// 把各来源的清单按 [listings] 的顺序（= 来源优先级）合并：同一 id 只留第一个来源
/// 的那一条。纯函数。
MergedRemoteVideos mergeRemoteVideoListings(
  List<RemoteVideoSourceListing> listings,
) {
  final List<RemoteVideoInfo> videos = <RemoteVideoInfo>[];
  final Map<String, RemoteVideoSource> owners = <String, RemoteVideoSource>{};
  for (final RemoteVideoSourceListing listing in listings) {
    for (final RemoteVideoInfo video in listing.videos) {
      if (owners.containsKey(video.id)) continue;
      owners[video.id] = listing.source;
      videos.add(video);
    }
  }
  return MergedRemoteVideos(videos: videos, owners: owners);
}

/// [videos] 按归属来源分组（组内保持原顺序；组的顺序 = 来源首次出现的顺序）。
/// 找不到归属的条目略去。
Map<RemoteVideoSource, List<RemoteVideoInfo>> groupRemoteVideosBySource(
  Iterable<RemoteVideoInfo> videos,
  RemoteVideoSource? Function(String id) ownerOf,
) {
  final Map<RemoteVideoSource, List<RemoteVideoInfo>> groups =
      <RemoteVideoSource, List<RemoteVideoInfo>>{};
  for (final RemoteVideoInfo video in videos) {
    final RemoteVideoSource? owner = ownerOf(video.id);
    if (owner == null) continue;
    (groups[owner] ??= <RemoteVideoInfo>[]).add(video);
  }
  return groups;
}

/// 这条远端视频的归属来源若有「已播放」协议（媒体服务器）就给出它，否则 null。
RemoteVideoPlayedMark? remoteVideoPlayedMarkOf(Object? owner) =>
    owner is RemoteVideoPlayedMark ? owner : null;

/// 多源下的「已播放」协议：按 id 把标记派给产出这条视频的来源。
///
/// 只有媒体服务器实现 [RemoteVideoPlayedMark]；调用方先用 [supports] 挑出能标的
/// id 再交给 `setVideosWatched`。对不支持的 id 调 [setRemoteVideoPlayed] 抛
/// [UnsupportedError]（由 `setVideosWatched` 记成该条失败，不静默吞掉）。
class RoutedRemoteVideoPlayedMark implements RemoteVideoPlayedMark {
  const RoutedRemoteVideoPlayedMark(this.markerFor);

  /// 远端视频 id → 它所在来源的「已播放」协议；来源不支持时 null。
  final RemoteVideoPlayedMark? Function(String id) markerFor;

  /// 这条远端视频的来源能不能回写「已播放」。
  bool supports(String id) => markerFor(id) != null;

  @override
  Future<void> setRemoteVideoPlayed(String id, {required bool played}) {
    final RemoteVideoPlayedMark? marker = markerFor(id);
    if (marker == null) {
      throw UnsupportedError('remote video $id: source has no played mark');
    }
    return marker.setRemoteVideoPlayed(id, played: played);
  }
}
