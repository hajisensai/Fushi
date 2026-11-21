import 'dart:async';

import 'package:fushi/src/media/video/online/anime_source_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';

/// 关掉一只播放页自建的远端客户端：持有连接的（[RemoteVideoClientConnections]）`close`，
/// 在线视频源客户端 `dispose`；什么都不持有的（测试替身等）忽略。
void closeOwnedRemoteVideoClient(RemoteVideoClient client) {
  // 能力接口与 RemoteVideoClient 不在同一继承链上，按 Object 判才能提升类型。
  final Object owned = client;
  if (owned is RemoteVideoClientConnections) {
    owned.close();
  } else if (owned is AnimeSourceVideoClient) {
    owned.dispose();
  }
}

/// 播放页自建远端客户端的「收尾后关闭」（BUG-5012）。
///
/// 流媒体书（粘贴 URL / 来源库网络视频 / 媒体服务器入库条目）的客户端由播放页现建，
/// 持有 http 连接、来源直链解析器（AList 登录态、SFTP 的 SSH 连接）。此前页面从不关它们：
/// SFTP 来源每开一次片就在后台留一条 SSH 连接。
///
/// 不能在 `dispose` 里立刻关：退出路径的断点落库与停止上报是发起后不等的
/// （`exitAfterPersist`，BUG-2119），它们在路由弹出、页面卸载**之后**才用这只客户端把
/// 最后一次断点 / Stopped 发出去。所以每个会用到客户端的收尾操作都经 [track] 登记，
/// [closeAfterInFlight] 等登记过的全部结束（成功或失败都算）再关。
class RemoteClientTeardown {
  final Set<Future<void>> _inFlight = <Future<void>>{};

  /// 当前登记着、还没结束的收尾操作数（测试用）。
  int get inFlightCount => _inFlight.length;

  /// 登记并启动一个会用到远端客户端的收尾操作；返回它自己的 future（错误照常传给
  /// 调用方，登记只看它何时结束）。
  Future<T> track<T>(Future<T> Function() operation) {
    final Future<T> result = operation();
    late final Future<void> settled;
    settled = result
        .then<void>((T _) {}, onError: (Object _) {})
        .whenComplete(() => _inFlight.remove(settled));
    _inFlight.add(settled);
    return result;
  }

  /// 等此刻登记着的收尾操作全部结束后执行 [close]。[close] 抛出的异常向返回的 future 传。
  Future<void> closeAfterInFlight(void Function() close) async {
    final List<Future<void>> pending = _inFlight.toList();
    if (pending.isNotEmpty) await Future.wait(pending);
    close();
  }
}
