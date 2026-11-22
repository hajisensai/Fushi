import 'dart:async';

import 'package:flutter/widgets.dart';

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
/// 读者：[MediaServerUserDataRefresh] 混入的视图原地重拉已加载条目；远端清单缓存
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

/// 订阅 [MediaServerUserDataChanges]：本视图那台服务器的用户数据一变就调
/// [refreshUserDataInPlace]（原地重拉已加载条目，不出加载态、不动滚动位置）。
///
/// 合并突发：批量标记一整季会按集各通知一次，刷新在途时到达的通知只记一笔，
/// 在途那次结束后**再刷一次**——既不并发打一串相同请求，也不会漏掉最后一次写入
/// 之后的状态。
mixin MediaServerUserDataRefresh<T extends StatefulWidget> on State<T> {
  StreamSubscription<String>? _userDataSub;
  bool _userDataRefreshing = false;
  bool _userDataRefreshQueued = false;

  /// 本视图展示的服务器身份。
  String get userDataServerId;

  /// 原地重拉已加载条目；失败自行吞掉并保留旧数据。
  Future<void> refreshUserDataInPlace();

  @override
  void initState() {
    super.initState();
    _userDataSub = MediaServerUserDataChanges.stream.listen(_onUserDataChanged);
  }

  @override
  void dispose() {
    unawaited(_userDataSub?.cancel());
    super.dispose();
  }

  void _onUserDataChanged(String serverId) {
    if (serverId != userDataServerId || !mounted) return;
    if (_userDataRefreshing) {
      _userDataRefreshQueued = true;
      return;
    }
    unawaited(_runUserDataRefresh());
  }

  Future<void> _runUserDataRefresh() async {
    _userDataRefreshing = true;
    try {
      do {
        _userDataRefreshQueued = false;
        await refreshUserDataInPlace();
      } while (_userDataRefreshQueued && mounted);
    } finally {
      _userDataRefreshing = false;
    }
  }
}
