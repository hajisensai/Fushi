import 'dart:async';
import 'dart:io' show InternetAddress, InternetAddressType;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_p2p/fushi_p2p.dart';

export 'package:fushi_p2p/fushi_p2p.dart'
    show FushiP2pConnStatus, FushiP2pPathKind;

/// 互联 P2P 隧道（iroh，dumbpipe 形态）的进程级运行时
/// （docs/specs/2026-09-28-interconnect-remote-reach.md §5 / §6）。
///
/// 一个进程一个 iroh 端点：host 用它接受入站隧道，client 用它开本地转发口。
/// 原生库缺失（该平台没随包 / 开发机没编）时整个能力判不可用，其余互联照常。

/// host 侧「允许经 P2P 隧道远程连接」（默认关：开启后会连 iroh 公共中继与发现
/// 服务，对端 / 中继能看到本机 IP，属于隐私选择）。app 与无头服务端同一个键。
const String kInterconnectP2pEnabledPref = 'interconnect_p2p_enabled';

/// 本机 iroh 私钥（hex）。**设备本地**：随备份外带会让两台设备同一个 NodeId。
const String kInterconnectP2pSecretPref = 'interconnect_p2p_secret_key';

/// 自建 iroh-relay 地址（JSON 字符串数组）；空 = iroh 默认公共中继。
const String kInterconnectP2pRelayUrlsPref = 'interconnect_p2p_relay_urls';

/// 地址集里的 P2P 地址：`p2p://<nodeId>`，host 开着 TLS 时带 `tls=1`（隧道里
/// 跑的仍是自签 TLS，client 据此用 https + 钉扎指纹访问本地转发口）。
///
/// 另捎 host 的 home relay（`relay=`）与当前直连地址（`addr=`，可多个）作拨号
/// 提示：client 按提示直接拨，不依赖 n0 DNS / DHT 发现——发现服务在某些网络里
/// 解析不了时隧道照样建得起来。提示随地址集刷新，旧的会被 learned 更新替换。
String interconnectP2pUrl(
  String nodeId, {
  required bool tls,
  String? relayUrl,
  List<String> directAddrs = const <String>[],
}) {
  final List<String> q = <String>[
    if (tls) 'tls=1',
    if (relayUrl != null && relayUrl.isNotEmpty)
      'relay=${Uri.encodeQueryComponent(relayUrl)}',
    for (final String a in directAddrs) 'addr=${Uri.encodeQueryComponent(a)}',
  ];
  return 'p2p://$nodeId${q.isEmpty ? '' : '?${q.join('&')}'}';
}

/// 解析 [interconnectP2pUrl]；不是 P2P 地址 → null。
({String nodeId, bool tls, String? relayUrl, List<String> directAddrs})?
parseInterconnectP2pUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'p2p' || uri.host.isEmpty) return null;
  final Map<String, List<String>> q = uri.queryParametersAll;
  final String? relay = q['relay']?.first;
  return (
    nodeId: uri.host,
    tls: q['tls']?.first == '1',
    relayUrl: (relay == null || relay.isEmpty) ? null : relay,
    directAddrs: q['addr'] ?? const <String>[],
  );
}

/// iroh 建连总是先走中继、几秒内打洞成功再升级直连；持续这么久仍只有中继路径，
/// 才算「打洞失败」。
const Duration kInterconnectRelayOnlyAfter = Duration(seconds: 20);

/// 跟踪到某个对端的路径，判断是否「一直走中继」。最常见的原因是任一端开着
/// Clash TUN / 全局 VPN 等改写 UDP 源端口的工具（对称 NAT 化），打洞必败——
/// 连得上但慢，用户完全不知道为什么，所以要在界面上说出来。
class InterconnectP2pPathTracker {
  DateTime? _relaySince;

  /// 喂一次状态，返回此刻是否已持续走中继满 [kInterconnectRelayOnlyAfter]。
  /// 断开 / 直连 / 混合路径都会重新计时。
  bool observe(FushiP2pConnStatus status, DateTime now) {
    if (!status.connected || status.path != FushiP2pPathKind.relay) {
      _relaySince = null;
      return false;
    }
    final DateTime since = _relaySince ??= now;
    return now.difference(since) >= kInterconnectRelayOnlyAfter;
  }
}

/// 当前进程开着的本地转发口（`127.0.0.1:<port>`）。这些口在字面上是回环地址，
/// 但背后是跨公网的隧道——按「局域网」给原画直传会把中继带宽打爆。画质判断等
/// 「是不是局域网」的判据必须先问这里。
final Set<int> _tunnelPorts = <int>{};

/// [host]:[port] 是否是本进程的 P2P 本地转发口。
bool isInterconnectTunnelOrigin(String host, int port) =>
    (host == '127.0.0.1' || host == 'localhost') && _tunnelPorts.contains(port);

/// 本进程的 iroh 端点。
class InterconnectP2pNode {
  InterconnectP2pNode._(this._endpoint, this.nodeId);

  final FushiP2pEndpoint _endpoint;

  /// 本机 NodeId（公钥）。
  final String nodeId;

  /// nodeId → 本地转发口（按对端缓存，一台 host 一个口，所有连接复用）。
  final Map<String, int> _forwards = <String, int>{};

  /// nodeId → 建口时用的拨号提示。提示变了（host 换了 home relay / 重启换了
  /// UDP 口）就重建：在发现服务解析不了的网络里，旧提示意味着隧道永远不通
  /// （审查问题 11）。
  final Map<String, String> _forwardHints = <String, String>{};

  bool _closed = false;

  /// 作为 host：入站隧道 → `127.0.0.1:[loopbackPort]`（信任区监听口，见
  /// `FushiSyncServer.startP2pListener`）。
  void hostListen(int loopbackPort) => _endpoint.hostListen(loopbackPort);

  void hostStop() => _endpoint.hostStop();

  /// 作为 host：信任区监听口上对端端口 [remotePort] 对应的隧道对端 NodeId
  /// （装配成 `FushiSyncServer.p2pPeerResolver`）。已关闭 → null。
  String? hostPeer(int remotePort) =>
      _closed ? null : _endpoint.hostPeer(remotePort);

  /// 本端点当前信息（home relay / 直连地址，供地址集捎带拨号提示）。
  FushiP2pInfo info() => _endpoint.info();

  /// 作为 client：确保到 [remoteNodeId] 的本地转发口并返回端口。[relayUrl] /
  /// [directAddrs] 是拨号提示（见 [interconnectP2pUrl]）。
  int forwardTo(
    String remoteNodeId, {
    String? relayUrl,
    List<String> directAddrs = const <String>[],
  }) {
    final String hints = '${relayUrl ?? ''}|${directAddrs.join(',')}';
    final int? existing = _forwards[remoteNodeId];
    if (existing != null) {
      if (_forwardHints[remoteNodeId] == hints) return existing;
      _endpoint.stopForward(existing);
      _tunnelPorts.remove(existing);
      _forwards.remove(remoteNodeId);
    }
    final int port = _endpoint.clientForward(
      remoteNodeId,
      relayUrl: relayUrl,
      directAddrs: directAddrs,
    );
    _forwards[remoteNodeId] = port;
    _forwardHints[remoteNodeId] = hints;
    _tunnelPorts.add(port);
    return port;
  }

  /// 到 [remoteNodeId] 的路径状态（direct / relay / mixed / none）。
  FushiP2pConnStatus status(String remoteNodeId) =>
      _endpoint.status(remoteNodeId);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _forwards.values.forEach(_tunnelPorts.remove);
    _forwards.clear();
    await _endpoint.closeAsync();
  }
}

/// 端点的单例 + 生命周期（单飞启动，配置变更后 [restart]）。
class InterconnectP2pRuntime {
  InterconnectP2pRuntime({
    required this.loadSecret,
    required this.saveSecret,
    required this.loadRelayUrls,
  });

  final Future<String?> Function() loadSecret;
  final Future<void> Function(String secretKeyHex) saveSecret;
  final Future<List<String>> Function() loadRelayUrls;

  InterconnectP2pNode? _node;
  Future<InterconnectP2pNode?>? _starting;

  /// 原生库是否可用（不可用时 [ensure] 恒 null）。
  static bool get isAvailable => FushiP2p.isAvailable;

  /// 已启动的端点（未启动 → null，不触发启动）。
  InterconnectP2pNode? get current => _node;

  /// 确保端点已启动；原生库不可用或启动失败 → null（已留痕）。
  Future<InterconnectP2pNode?> ensure() {
    final InterconnectP2pNode? node = _node;
    if (node != null) return Future<InterconnectP2pNode?>.value(node);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<InterconnectP2pNode?> _start() async {
    if (!isAvailable) return null;
    try {
      final String? secret = await loadSecret();
      final FushiP2pEndpoint endpoint = FushiP2pEndpoint.create(
        secretKeyHex: (secret != null && secret.isNotEmpty) ? secret : null,
        relayUrls: await loadRelayUrls(),
      );
      final FushiP2pInfo info = endpoint.info();
      if (secret == null || secret.isEmpty) {
        await saveSecret(info.secretKeyHex);
      }
      final InterconnectP2pNode node = InterconnectP2pNode._(
        endpoint,
        info.nodeId,
      );
      _node = node;
      return node;
    } on Object catch (e, st) {
      engineLog.log('InterconnectP2p.start', e, st);
      return null;
    }
  }

  /// 中继配置变了：关掉旧端点，下次 [ensure] 按新配置重建。在飞的启动先落地
  /// 再关——否则它随后把按旧配置建的端点写回 [_node]（审查问题 11）。旧端点
  /// 关完（含等对端确认，最长数秒）才返回，新端点不会与它同 NodeId 双开。
  Future<void> restart() async {
    final Future<InterconnectP2pNode?>? starting = _starting;
    if (starting != null) await starting;
    final InterconnectP2pNode? node = _node;
    _node = null;
    await node?.close();
  }

  Future<void> dispose() => restart();

  /// host 地址集里本机的 P2P 地址（端点未启动 / 还没有任何可用拨号提示 → 空）。
  List<InterconnectHostAddress> hostAddresses({required bool tls}) {
    final InterconnectP2pNode? node = _node;
    if (node == null) return const <InterconnectHostAddress>[];
    FushiP2pInfo? info;
    try {
      info = node.info();
    } on Object catch (e) {
      engineLog.logDiagnostic('InterconnectP2p.info', e);
    }
    final String? url = interconnectP2pPublishableUrl(
      node.nodeId,
      tls: tls,
      relayUrl: info?.relayUrl,
      directAddrs: info?.directAddrs ?? const <String>[],
    );
    if (url == null) return const <InterconnectHostAddress>[];
    return <InterconnectHostAddress>[
      InterconnectHostAddress(url: url, kind: InterconnectAddressKind.p2p),
    ];
  }
}

/// host 该不该公布、公布成什么样的 `p2p://` 地址（纯函数，便于单测）。
///
/// 实测（docs/specs/2026-09-28-interconnect-remote-reach.md §9）：新上线的 host 要
/// 10–50 秒才能被 n0 DNS 发现，这段时间只凭 NodeId 拨号约一半失败；而端点连上
/// home relay 前（最长约 15 秒）`relayUrl` 为空。client 学到的地址要到下次学习才
/// 刷新，所以**只公布不经发现就能拨通的地址**：带中继，或至少一个可路由的直连
/// 地址。两样都没有 → null（先不公布，下次地址集请求时再算）。
String? interconnectP2pPublishableUrl(
  String nodeId, {
  required bool tls,
  required String? relayUrl,
  required List<String> directAddrs,
}) {
  final List<String> dialable =
      directAddrs.where(isInterconnectP2pDialableAddr).toList(growable: false);
  final bool hasRelay = relayUrl != null && relayUrl.isNotEmpty;
  if (!hasRelay && dialable.isEmpty) return null;
  return interconnectP2pUrl(
    nodeId,
    tls: tls,
    relayUrl: relayUrl,
    directAddrs: dialable,
  );
}

/// iroh 报出的直连地址（`ip:port` / `[v6]:port`）对远端是否有拨号价值。
///
/// 剔除：`198.18.0.0/15`（RFC 2544 基准网段，Clash / FlClash 等 TUN 与 fake-ip
/// 恰好用它——实测 iroh 会把 TUN 网卡地址 198.18.0.1 当本机地址报出来）、回环、
/// 链路本地、未指定地址。这些发给对端只会白白多拨几次。
bool isInterconnectP2pDialableAddr(String hostPort) {
  final int colon = hostPort.lastIndexOf(':');
  if (colon <= 0) return false;
  String host = hostPort.substring(0, colon);
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  final InternetAddress? ip = InternetAddress.tryParse(host);
  if (ip == null || ip.isLoopback || ip.isLinkLocal) return false;
  final List<int> b = ip.rawAddress;
  if (b.every((int x) => x == 0)) return false;
  if (ip.type == InternetAddressType.IPv4) {
    if (b[0] == 198 && (b[1] == 18 || b[1] == 19)) return false;
  }
  return true;
}
