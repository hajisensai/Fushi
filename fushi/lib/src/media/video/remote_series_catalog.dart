// 媒体服务器目录的剧名临时分组输入（BUG-5601，懒收养）。
//
// 视频库页每拿到一份**派生剧归属**来源（[DerivedSeriesGroupingSource]：Jellyfin /
// Emby / 飞牛 / Plex）的清单就记到这里，不再收养进库；[loadVideoLibraryMembership]
// 默认读这里的列式快照，在后台 isolate 里叠加出临时分组，视频库页、首页速览、伴屏
// 三个消费方因此同一口径。互联 / 云盘的归属是 host 上真实存在的合集，照旧收养，
// 不进这里。
import 'package:fushi_engine/media/collections/remote_series_overlay.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

/// 进程内单例：各派生来源最近一份清单的列式快照。
class RemoteSeriesCatalog {
  RemoteSeriesCatalog();

  static final RemoteSeriesCatalog instance = RemoteSeriesCatalog();

  final Map<String, ({List<RemoteVideoInfo> videos, RemoteSeriesColumns cols})>
  _bySource =
      <String, ({List<RemoteVideoInfo> videos, RemoteSeriesColumns cols})>{};
  RemoteSeriesColumns? _merged;

  /// 全部来源首尾相接的快照（来源按登记先后；同 id 先到者胜）。
  RemoteSeriesColumns get columns =>
      _merged ??= RemoteSeriesColumns.concat(<RemoteSeriesColumns>[
        for (final ({List<RemoteVideoInfo> videos, RemoteSeriesColumns cols}) e
            in _bySource.values)
          e.cols,
      ]);

  /// 记下 [sourceId] 的最新清单；清单对象没变（缓存 TTL 内回的同一份）返回 false。
  bool update(String sourceId, List<RemoteVideoInfo> videos) {
    final ({List<RemoteVideoInfo> videos, RemoteSeriesColumns cols})? prev =
        _bySource[sourceId];
    if (prev != null && identical(prev.videos, videos)) return false;
    _bySource[sourceId] = (
      videos: videos,
      cols: RemoteSeriesColumns.fromVideos(videos),
    );
    _merged = null;
    return true;
  }

  /// 来源不在了（关掉 / 换服务器）：撤掉它的分组输入。返回是否真的撤了。
  bool remove(String sourceId) {
    if (_bySource.remove(sourceId) == null) return false;
    _merged = null;
    return true;
  }

  /// 只保留 [sourceIds] 这些来源；返回是否撤了任何来源。
  bool retainOnly(Set<String> sourceIds) {
    final int before = _bySource.length;
    _bySource.removeWhere((String id, _) => !sourceIds.contains(id));
    if (_bySource.length == before) return false;
    _merged = null;
    return true;
  }

  /// 只给测试。
  void debugReset() {
    _bySource.clear();
    _merged = null;
  }
}
