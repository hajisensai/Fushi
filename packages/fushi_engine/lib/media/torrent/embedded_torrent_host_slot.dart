import 'dart:async';

import 'package:fushi_engine/media/torrent/embedded_torrent_host_client.dart';

/// 常驻内置宿主客户端的懒建槽位（app 的 AppModel 与无头服务端共用）。
///
/// 管三件事，三件都曾各写一份、各漏一块：
/// - **懒建去重**：同一时刻只起一个工作 isolate（两个 session 抢同一个监听
///   端口，后起的那个必然绑不上）。
/// - **释放与懒建竞发**：[take] 撤下在途懒建时，由 [take] 的调用方负责关掉它
///   落地的客户端，懒建那一侧不得再把它挂回来、也不再跑 [ensure] 的
///   `onOpened`。
/// - **工作 isolate 意外退出**：客户端 [EmbeddedTorrentHostClient.closed]
///   时若仍挂在槽位里，就把它摘下来（并回调 `onLost`），下一次 [ensure] 重建。
///   不摘的话槽位永远交出一个已关的客户端，每条命令都以
///   `EmbeddedTorrentWorkerClosed` 失败，直到进程重启内置引擎都不可用。
class EmbeddedTorrentHostSlot {
  EmbeddedTorrentHostClient? _current;
  Future<EmbeddedTorrentHostClient?>? _opening;

  /// 当前可用的客户端（未建 / 在建 / 已失效被摘下时为 null）。
  EmbeddedTorrentHostClient? get current => _current;

  /// 是否有一次懒建在途。
  bool get isOpening => _opening != null;

  /// 已有客户端直接交出；有在途懒建就复用它；否则调用 [open] 起一个。
  ///
  /// [open] 返回 null = 此刻建不了（平台 / 路径 / DLL 不满足），不登记，下次
  /// 再判；返回的 future 落地为 null（session 打不开）或抛错时同样不登记。
  ///
  /// [onOpened] 在客户端挂进槽位后**同步**调用（铺用户配置、起监视）：它之后
  /// 再经本槽位拿到客户端的调用方，发出的命令一定排在这些配置之后执行。
  /// [onLost] 在挂着的客户端意外失效、被摘下时调用。两者都只对仍归本槽位的
  /// 客户端调用（被 [take] 撤下的一律不回调）。
  Future<EmbeddedTorrentHostClient?> ensure(
    Future<EmbeddedTorrentHostClient?>? Function() open, {
    void Function(EmbeddedTorrentHostClient client)? onOpened,
    void Function(EmbeddedTorrentHostClient client)? onLost,
  }) {
    final EmbeddedTorrentHostClient? existing = _current;
    if (existing != null) {
      return Future<EmbeddedTorrentHostClient?>.value(existing);
    }
    final Future<EmbeddedTorrentHostClient?>? opening = _opening;
    if (opening != null) return opening;
    final Future<EmbeddedTorrentHostClient?>? started = open();
    if (started == null) return Future<EmbeddedTorrentHostClient?>.value();
    final Completer<EmbeddedTorrentHostClient?> registered =
        Completer<EmbeddedTorrentHostClient?>();
    _opening = registered.future;
    registered.complete(
      _settle(registered.future, started, onOpened: onOpened, onLost: onLost),
    );
    return registered.future;
  }

  Future<EmbeddedTorrentHostClient?> _settle(
    Future<EmbeddedTorrentHostClient?> self,
    Future<EmbeddedTorrentHostClient?> started, {
    void Function(EmbeddedTorrentHostClient client)? onOpened,
    void Function(EmbeddedTorrentHostClient client)? onLost,
  }) async {
    final EmbeddedTorrentHostClient? client;
    try {
      client = await started;
    } on Object {
      // 打开失败（抛错）：清掉在途标记，下次需要时再试。被 take 撤下的
      // 不归这里管。
      if (identical(self, _opening)) _opening = null;
      rethrow;
    }
    // 起 isolate 期间被 [take] 撤下了：take 的调用方会 await 同一个 future
    // 并负责关掉这个客户端，这里不得再把它挂回来。
    if (!identical(self, _opening)) return client;
    _opening = null;
    if (client == null) return null; // 打不开：下次需要时再试。
    final EmbeddedTorrentHostClient attached = client;
    _current = attached;
    unawaited(attached.closed.then((_) => _onClosed(attached, onLost)));
    onOpened?.call(attached);
    return attached;
  }

  void _onClosed(
    EmbeddedTorrentHostClient client,
    void Function(EmbeddedTorrentHostClient client)? onLost,
  ) {
    // 主动释放路径（[take]）已经先把它撤下了：不是「丢失」。
    if (!identical(client, _current)) return;
    _current = null;
    onLost?.call(client);
  }

  /// 撤下槽位里的客户端（含在途懒建），交给调用方关闭；之后槽位为空，可再
  /// [ensure]。返回的 future 落地为要关的客户端，没有则为 null。
  ///
  /// 在途懒建失败（抛错）时这里落地为 null：错误已经交给了等那次 [ensure] 的
  /// 调用方，释放这一侧只关心「有没有要关的东西」。
  Future<EmbeddedTorrentHostClient?> take() {
    final EmbeddedTorrentHostClient? current = _current;
    final Future<EmbeddedTorrentHostClient?>? opening = _opening;
    _current = null;
    _opening = null;
    if (current != null) {
      return Future<EmbeddedTorrentHostClient?>.value(current);
    }
    if (opening == null) return Future<EmbeddedTorrentHostClient?>.value();
    return opening.then(
      (EmbeddedTorrentHostClient? client) => client,
      onError: (Object _) => null,
    );
  }
}
