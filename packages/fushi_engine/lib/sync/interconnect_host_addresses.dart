import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';

/// host 侧「公网 / 反代 / DDNS 地址」偏好键（app 与无头服务端同一张
/// `preferences` 表、同一个键）。值为 JSON 字符串数组。
const String kInterconnectPublicUrlsPref = 'interconnect_public_urls';

/// 解码 [kInterconnectPublicUrlsPref] 的存储值：JSON 字符串数组（或已解出的
/// List）；空白项丢弃。坏数据按「没配」处理并留痕——这是可选的附加地址，不该让
/// capabilities 整体失败。
List<String> decodeInterconnectPublicUrls(Object? raw) {
  Object? decoded = raw;
  if (raw is String) {
    if (raw.trim().isEmpty) return const <String>[];
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      engineLog.logDiagnostic('InterconnectHostAddresses', 'public urls: $e');
      return const <String>[];
    }
  }
  if (decoded is! List) return const <String>[];
  return <String>[
    for (final Object? e in decoded)
      if (e is String && e.trim().isNotEmpty) e.trim(),
  ];
}

/// 互联主机对外公布的一条可达地址的种类。顺序即优先级（[interconnectAddressRank]）：
/// 越靠前越「近」——同网段直连最快，P2P 隧道最后兜底。
///
/// 设计见 docs/specs/2026-09-28-interconnect-remote-reach.md §1。
enum InterconnectAddressKind {
  /// 私网 IPv4（10/8、172.16/12、192.168/16）。
  lan,

  /// IPv6 唯一本地地址（fc00::/7）。
  lanV6,

  /// 全局单播 IPv6（2000::/3）——国内家宽最常见的「无公网 v4 也能直连」路径。
  ipv6,

  /// 虚拟组网（Tailscale / ZeroTier / EasyTier / WireGuard）网卡上的地址。
  overlay,

  /// 用户在主机上填的公网 / 反代 / DDNS 地址。
  public,

  /// P2P 隧道节点（`p2p://<nodeId>`），直连全失败才走。
  p2p,
}

/// 一条地址能否被自动学习 / 公布：**只收带密码学身份的传输**——`https://`
/// （自签证书走指纹钉扎，公网反代走 CA 校验）与 `p2p://`（iroh 按 NodeId 公钥
/// 认证对端）。
///
/// 明文 `http://` 一律不学：学到的 LAN 地址换个网络可能指向别人的机器，hostId
/// 是公开值（LAN 广播 TXT、/api/ping 都有）挡不住冒名，Basic token 会被发过去；
/// 公布全局 IPv6 的明文地址则等于让 token 与数据在公网上裸奔。用户手输的明文
/// 地址不受影响（那是用户自己的决定，行为与升级前一致）
/// （docs/specs/2026-09-28-interconnect-remote-reach.md §9，审查问题 1 / 2）。
bool isInterconnectLearnableUrl(String url) {
  final String lower = url.trim().toLowerCase();
  return lower.startsWith('https://') || lower.startsWith('p2p://');
}

/// 同一台主机多条地址之间的优先级（小者优先）。LAN 两种同级。
int interconnectAddressRank(InterconnectAddressKind kind) {
  switch (kind) {
    case InterconnectAddressKind.lan:
    case InterconnectAddressKind.lanV6:
      return 0;
    case InterconnectAddressKind.ipv6:
      return 1;
    case InterconnectAddressKind.overlay:
      return 2;
    case InterconnectAddressKind.public:
      return 3;
    case InterconnectAddressKind.p2p:
      return 4;
  }
}

/// 主机公布的一条地址：[url] 是 client 可以直接当候选基址用的完整 URL。
class InterconnectHostAddress {
  const InterconnectHostAddress({required this.url, required this.kind});

  final String url;
  final InterconnectAddressKind kind;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'kind': kind.name,
  };

  /// 解析一条 wire 记录；缺字段 / 未知 kind（更新的 host 加了新种类）返回 null，
  /// 由调用方跳过——老 client 不因新 host 多报一种地址而整批失败。
  static InterconnectHostAddress? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? url = json['url'];
    final Object? kind = json['kind'];
    if (url is! String || url.isEmpty || kind is! String) return null;
    for (final InterconnectAddressKind k in InterconnectAddressKind.values) {
      if (k.name == kind) return InterconnectHostAddress(url: url, kind: k);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is InterconnectHostAddress &&
      other.url == url &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(url, kind);

  @override
  String toString() => 'InterconnectHostAddress(${kind.name} $url)';
}

/// 虚拟组网网卡名特征（小写子串）。这些网卡上的私网段地址（ZeroTier 默认就发
/// 10.x / 172.2x）按 IP 会被误判成 LAN——对端不在同一个物理网里时那是另一回事。
const List<String> _overlayInterfaceHints = <String>[
  'tailscale',
  'zerotier',
  'easytier',
  'wireguard',
  'utun',
];

/// 本机虚拟机 / 容器网桥（小写子串）：它们的地址对别的设备不可达，公布出去只会让
/// 每次选路多探一个死地址。
const List<String> _hostOnlyInterfaceHints = <String>[
  'docker',
  'veth',
  'br-',
  'vethernet',
  'vmnet',
  'virtualbox',
  'vboxnet',
  'hyper-v',
];

/// 按网卡名 + IP 给一个地址分类；返回 null 表示不公布（回环 / 链路本地 / 本机网桥
/// / 其它不可路由段）。纯函数，可单测。
InterconnectAddressKind? classifyInterconnectAddress(
  String interfaceName,
  InternetAddress address,
) {
  final String name = interfaceName.toLowerCase();
  if (_hostOnlyInterfaceHints.any(name.contains)) return null;
  if (address.isLoopback || address.isLinkLocal) return null;
  final List<int> raw = address.rawAddress;
  final bool overlayName =
      _overlayInterfaceHints.any(name.contains) ||
      RegExp(r'^zt[0-9a-z]').hasMatch(name);

  if (address.type == InternetAddressType.IPv4) {
    final int a = raw[0];
    final int b = raw[1];
    // 100.64.0.0/10：Tailscale 等组网的常用段；出现在本机网卡上即组网地址。
    if (a == 100 && b >= 64 && b <= 127) return InterconnectAddressKind.overlay;
    final bool private =
        a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
    if (private) {
      return overlayName
          ? InterconnectAddressKind.overlay
          : InterconnectAddressKind.lan;
    }
    // 网卡上直接挂着的公网 v4（少见：拨号在本机 / VPS）也能直连。
    return overlayName
        ? InterconnectAddressKind.overlay
        : InterconnectAddressKind.public;
  }

  if (address.type == InternetAddressType.IPv6) {
    final int first = raw[0];
    if ((first & 0xfe) == 0xfc) {
      return overlayName
          ? InterconnectAddressKind.overlay
          : InterconnectAddressKind.lanV6;
    }
    // 2000::/3 全局单播。
    if ((first & 0xe0) == 0x20) {
      return overlayName
          ? InterconnectAddressKind.overlay
          : InterconnectAddressKind.ipv6;
    }
  }
  return null;
}

/// 把一个 IP 与端口拼成 client 可用的基址（IPv6 字面量加方括号）。
String interconnectAddressUrl(
  InternetAddress address,
  int port, {
  required bool tls,
}) {
  final String scheme = tls ? 'https' : 'http';
  final String host = address.type == InternetAddressType.IPv6
      ? '[${address.address}]'
      : address.address;
  return '$scheme://$host:$port';
}

/// 由网卡快照 + 用户配置的公网地址组装主机地址集：去重、按优先级稳定排序。
/// 纯函数（网卡由调用方给），可单测。
List<InterconnectHostAddress> collectInterconnectHostAddresses({
  required List<NetworkInterface> interfaces,
  required int port,
  required bool tls,
  List<String> publicUrls = const <String>[],
  List<InterconnectHostAddress> extra = const <InterconnectHostAddress>[],
}) {
  final List<InterconnectHostAddress> out = <InterconnectHostAddress>[];
  final Set<String> seen = <String>{};
  void add(InterconnectHostAddress a) {
    // 只公布可学习的地址：未开 TLS 的 host 只剩 P2P（见 [isInterconnectLearnableUrl]）。
    if (!isInterconnectLearnableUrl(a.url)) return;
    if (seen.add(a.url)) out.add(a);
  }

  for (final NetworkInterface nic in interfaces) {
    for (final InternetAddress address in nic.addresses) {
      final InterconnectAddressKind? kind = classifyInterconnectAddress(
        nic.name,
        address,
      );
      if (kind == null) continue;
      add(
        InterconnectHostAddress(
          url: interconnectAddressUrl(address, port, tls: tls),
          kind: kind,
        ),
      );
    }
  }
  for (final String raw in publicUrls) {
    final String url = raw.trim();
    if (url.isEmpty) continue;
    add(
      InterconnectHostAddress(url: url, kind: InterconnectAddressKind.public),
    );
  }
  extra.forEach(add);

  // 稳定排序：同 rank 保持网卡枚举顺序。
  final List<(int, InterconnectHostAddress)> indexed =
      <(int, InterconnectHostAddress)>[
        for (int i = 0; i < out.length; i++) (i, out[i]),
      ];
  indexed.sort((
    (int, InterconnectHostAddress) x,
    (int, InterconnectHostAddress) y,
  ) {
    final int byRank =
        interconnectAddressRank(x.$2.kind) - interconnectAddressRank(y.$2.kind);
    return byRank != 0 ? byRank : x.$1 - y.$1;
  });
  return <InterconnectHostAddress>[
    for (final (int, InterconnectHostAddress) e in indexed) e.$2,
  ];
}

/// 读取本机网卡并组装地址集。枚举失败（沙箱 / 权限）时只剩用户配置的地址——
/// 地址集是锦上添花，拿不到网卡不该让 capabilities 整体失败。
Future<List<InterconnectHostAddress>> listInterconnectHostAddresses({
  required int port,
  required bool tls,
  List<String> publicUrls = const <String>[],
  List<InterconnectHostAddress> extra = const <InterconnectHostAddress>[],
  Future<List<NetworkInterface>> Function()? interfaceLister,
}) async {
  List<NetworkInterface> interfaces;
  try {
    interfaces =
        await (interfaceLister ??
            () => NetworkInterface.list(includeLinkLocal: false))();
  } on SocketException catch (e) {
    engineLog.logDiagnostic('InterconnectHostAddresses', 'list nics: $e');
    interfaces = const <NetworkInterface>[];
  }
  return collectInterconnectHostAddresses(
    interfaces: interfaces,
    port: port,
    tls: tls,
    publicUrls: publicUrls,
    extra: extra,
  );
}
