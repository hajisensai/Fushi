import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/video/media_server/media_server_user_data_changes.dart';
import 'package:fushi/src/utils/state_resource_scope.dart';

/// 订阅 [MediaServerUserDataChanges]：本视图那台服务器的用户数据一变就调
/// [refreshUserDataInPlace]（原地重拉已加载条目，不出加载态、不动滚动位置）。
///
/// 合并突发：批量标记一整季会按集各通知一次，刷新在途时到达的通知只记一笔，
/// 在途那次结束后**再刷一次**——既不并发打一串相同请求，也不会漏掉最后一次写入
/// 之后的状态。
mixin MediaServerUserDataRefresh<T extends StatefulWidget>
    on State<T>, StateResourceScope<T> {
  bool _userDataRefreshing = false;
  bool _userDataRefreshQueued = false;

  /// 本视图展示的服务器身份。
  String get userDataServerId;

  /// 原地重拉已加载条目；失败自行吞掉并保留旧数据。
  Future<void> refreshUserDataInPlace();

  @override
  void initState() {
    super.initState();
    // 经 StateResourceScope 登记：dispose 与 initState 半途失败共用取消（BUG-5604）。
    ownSubscription(
      MediaServerUserDataChanges.stream.listen(_onUserDataChanged),
    );
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
