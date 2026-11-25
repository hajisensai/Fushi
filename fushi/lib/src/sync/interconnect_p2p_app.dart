import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState;
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_engine/sync/interconnect_p2p.dart';
import 'package:meta/meta.dart';

/// app 侧 P2P 隧道运行时的装配点（docs/specs/2026-09-28-interconnect-remote-reach.md §5）。
///
/// 一个进程一个 iroh 端点：host 控制器用它接受入站隧道，client 选路用它开本地
/// 转发口。原生库缺失的平台 / 开发机上 [InterconnectP2pRuntime.isAvailable] 为
/// false，client 不收 `p2p://` 地址，host 不公布，其余互联照常。
InterconnectP2pRuntime? _runtime;

/// 已建的运行时（没建过 → null，不触发创建）。
InterconnectP2pRuntime? get currentAppInterconnectP2pRuntime => _runtime;

/// 取（必要时建）本进程的 P2P 运行时。
InterconnectP2pRuntime appInterconnectP2pRuntime(SyncRepository repo) {
  final InterconnectP2pRuntime? existing = _runtime;
  if (existing != null) return existing;
  final InterconnectP2pRuntime created = InterconnectP2pRuntime(
    loadSecret: repo.getInterconnectP2pSecret,
    saveSecret: repo.setInterconnectP2pSecret,
    loadRelayUrls: repo.getInterconnectP2pRelayUrls,
  );
  _runtime = created;
  return created;
}

/// 启动时调一次：原生库可用才让 client 收 `p2p://` 地址、装上选路里的隧道解析，
/// 并把系统网络变化接到端点（[installInterconnectP2pNetworkWatch]）。
void installInterconnectP2pClient(SyncRepository repo) {
  if (!InterconnectP2pRuntime.isAvailable) return;
  final InterconnectP2pRuntime runtime = appInterconnectP2pRuntime(repo);
  bindInterconnectP2pClient(runtime);
  installInterconnectP2pNetworkWatch(runtime);
}

/// 把 [runtime] 装成本进程的 P2P 运行时，并装上选路里的隧道解析（不查原生库
/// 是否可用，测试直接用假端点装配）。
///
/// 转发口 → `p2p://` 的反查映射由 engine 随转发口一起持有与回收
/// （[interconnectTunnelOriginUrl]），这里只把持久地址作为 `originUrl` 交给它。
@visibleForTesting
void bindInterconnectP2pClient(InterconnectP2pRuntime runtime) {
  _runtime = runtime;
  setInterconnectAcceptsP2pAddresses(true);
  setInterconnectP2pResolver((FushiClientUrl candidate) async {
    final ({
      String nodeId,
      bool tls,
      String? relayUrl,
      List<String> directAddrs,
    })?
    p2p = parseInterconnectP2pUrl(candidate.url);
    if (p2p == null) return null;
    final InterconnectP2pNode? node = await runtime.ensure();
    if (node == null) return null;
    final int port = node.forwardTo(
      p2p.nodeId,
      relayUrl: p2p.relayUrl,
      directAddrs: p2p.directAddrs,
      originUrl: candidate.url,
    );
    return candidate.copyWith(
      url: '${p2p.tls ? 'https' : 'http'}://127.0.0.1:$port',
    );
  });
}

/// [installInterconnectP2pNetworkWatch] 挂着的订阅（重复装配先撤旧的）。
final List<StreamSubscription<void>> _networkWatch =
    <StreamSubscription<void>>[];

/// 把「系统默认网络变了」接到 [runtime]（iroh 端点）：每次变化通知一次
/// `fp2p_network_change`，让隧道在连接没断、路径已失效时也能及时换路。
///
/// - [changes]：平台信号，默认取 [FushiChannels.networkChange]（只在 Android /
///   iOS 订阅——Android 上 netwatch 不做路由监视、移动端睡眠检测一小时才轮询
///   一次；桌面与无头服务端由 iroh 自己检测，用空流）。
/// - [lifecycle]：回到前台（`resumed`）也算一次信号，补 iOS 唤醒后的缺口；默认
///   同样只在 Android / iOS 上订阅 [AppLifecycleListener]。
///
/// 重复调用会先撤掉上一份订阅。端点没启动时信号什么也不做（不为此建端点）。
void installInterconnectP2pNetworkWatch(
  InterconnectP2pRuntime runtime, {
  Stream<void>? changes,
  Stream<AppLifecycleState>? lifecycle,
}) {
  _cancelNetworkWatch();
  final bool mobile = Platform.isAndroid || Platform.isIOS;
  final Stream<void> platformChanges =
      changes ??
      (mobile
          ? FushiChannels.networkChange.receiveBroadcastStream().map(
              (Object? _) {},
            )
          : const Stream<void>.empty());
  final Stream<AppLifecycleState> states =
      lifecycle ??
      (mobile
          ? _appLifecycleStates()
          : const Stream<AppLifecycleState>.empty());
  _networkWatch
    ..add(bindInterconnectP2pNetworkSignals(runtime, platformChanges))
    ..add(
      bindInterconnectP2pNetworkSignals(
        runtime,
        states
            .where((AppLifecycleState s) => s == AppLifecycleState.resumed)
            .map((AppLifecycleState _) {}),
      ),
    );
}

/// app 生命周期状态流：有人订阅时才挂 [AppLifecycleListener]，取消即撤。
Stream<AppLifecycleState> _appLifecycleStates() {
  AppLifecycleListener? listener;
  late final StreamController<AppLifecycleState> controller;
  controller = StreamController<AppLifecycleState>(
    onListen: () {
      listener = AppLifecycleListener(onStateChange: controller.add);
    },
    onCancel: () {
      listener?.dispose();
      listener = null;
    },
  );
  return controller.stream;
}

void _cancelNetworkWatch() {
  for (final StreamSubscription<void> sub in _networkWatch) {
    unawaited(sub.cancel());
  }
  _networkWatch.clear();
}

/// 测试装置：撤掉 [bindInterconnectP2pClient] 与
/// [installInterconnectP2pNetworkWatch] 装上的一切。
@visibleForTesting
void debugResetAppInterconnectP2p() {
  _cancelNetworkWatch();
  _runtime = null;
  setInterconnectP2pResolver(null);
  setInterconnectAcceptsP2pAddresses(false);
}
