import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
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

/// 启动时调一次：原生库可用才让 client 收 `p2p://` 地址并装上选路里的隧道解析。
void installInterconnectP2pClient(SyncRepository repo) {
  if (!InterconnectP2pRuntime.isAvailable) return;
  bindInterconnectP2pClient(appInterconnectP2pRuntime(repo));
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

/// 测试装置：撤掉 [bindInterconnectP2pClient] 装上的一切。
@visibleForTesting
void debugResetAppInterconnectP2p() {
  _runtime = null;
  setInterconnectP2pResolver(null);
  setInterconnectAcceptsP2pAddresses(false);
}
