import 'dart:async';

/// 媒体服务器上**用户数据**（已播放标记 / 断点）变了的进程内信号，按服务器身份
/// （`MediaServerBrowser.serverId` = `RemoteLibrarySource.remoteLibrarySourceId`）
/// 派发。
///
/// 为什么要有它：媒体服务器的首页行 / 库网格 / 详情集清单各自持有一份条目快照
/// （`MediaServerItem.played` / `positionMs`），以前只有详情页在「自己标记 / 自己的
/// 播放页退回」后重拉自己，退回网格看到的仍是旧角标，要等整页重建才对（用户报：
/// 标记未看后剧卡仍是「已看」，过一阵才消失）。写者互不相识（视频库卡菜单、合集
/// 详情、媒体服务器详情、CLI / AI 操作、播放页），靠每个写者记得通知每个视图必漏，
/// 所以收口到两处真正改服务器状态的地方：
///
/// - 协议客户端「标记已播放」成功之后（`JellyfinVideoClient.setRemoteVideoPlayed`
///   ——所有标记入口最终都走它）；
/// - 浏览会话的播放页退回之后（`MediaServerSession.playItem`：播放期间上报了
///   断点 / 播完标记）。
///
/// 读者：`MediaServerUserDataRefresh`（`pages/implementations/media_server/
/// media_server_user_data_refresh.dart`）混入的视图原地重拉已加载条目；远端清单缓存
/// 失效该服务器的槽（`remoteLibraryCacheProvider`）。同步派发：通知返回时缓存已经
/// 失效，紧接着的读不会拿到旧清单。
abstract final class MediaServerUserDataChanges {
  static final StreamController<String> _changes =
      StreamController<String>.broadcast(sync: true);

  /// 用户数据变了的服务器身份。
  static Stream<String> get stream => _changes.stream;

  /// [serverId] 那台服务器上的用户数据刚被改过。
  static void notify(String serverId) => _changes.add(serverId);
}
