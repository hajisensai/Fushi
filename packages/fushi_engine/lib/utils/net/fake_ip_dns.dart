/// BUG-2950：fake-ip DNS（Clash / mihomo / FlClash 的 TUN + fake-ip 模式）下给内置
/// torrent 引擎找回真实 IP。
///
/// ## 为什么需要它
///
/// fake-ip 模式把**所有**域名解析成 `198.18.0.0/15` 里的假地址，再按假地址把流量截进
/// 代理内核。TCP 经代理照常可达，但很多代理节点不转发 UDP——于是 BT 里只能走 UDP 的
/// 两条找 peer 途径同时断掉：
///  - DHT 引导点（`router.bittorrent.com` 等）被解析成假地址，路由表冷启动永远 0 节点；
///  - `udp://` tracker（nyaa 种子五条里四条是 UDP）同理全部超时。
/// 任务表现为永远 0 peer，且没有任何报错。
///
/// 实测（2026-10-04，本机 Clash Verge TUN）：同一进程里 DHT 引导点走域名 0 节点，
/// 改成 DoH 拿到的真实 IP 后 35 秒内路由表涨到数十～数百节点——假地址才是瓶颈，
/// 出站 UDP 本身并非全断。
///
/// ## 做法
///
/// 1. [isFakeIpDnsActive]：系统解析器把已知公网域名解析进 `198.18.0.0/15` 即判定 fake-ip；
/// 2. [DohResolver]：经 HTTPS（TCP，走应用代理出口，fake-ip 下照样可达）向公共 DoH
///    问真实 A 记录；
/// 3. [resolveFakeIpTorrentBypass]：把 DHT 引导点与 `udp://` tracker 换成真实 IP 形式，
///    交给引擎（`addDhtNodes` / 追加 tracker）。HTTP(S) tracker 不改写——按 IP 访问会丢
///    `Host` 头，虚拟主机直接拒；它们走 TCP，经代理本来就通。
///
/// 本文件不 import `app_proxy.dart` / `app_http.dart`（torrent 层守卫
/// `download_http_client_proxy_test.dart` 禁止那几处碰代理装配）：出站 client 由调用方
/// （AppModel / 服务端）用 `createAppHttpIoClient()` 建好注入。
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// fake-ip 地址段 `198.18.0.0/15`（RFC 2544 基准测试段，Clash 系默认 fake-ip-range）。
bool isFakeIpAddress(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final List<int> b = address.rawAddress;
  return b[0] == 198 && (b[1] == 18 || b[1] == 19);
}

/// 与 native `ht_session_create` 的 `dht_bootstrap_nodes` 同一份清单（`host:port`）。
/// 改那边要同步改这里。
const List<String> kDhtBootstrapHostPorts = <String>[
  'dht.libtorrent.org:25401',
  'router.bittorrent.com:6881',
  'router.utorrent.com:6881',
  'dht.transmissionbt.com:6881',
  'dht.aelitis.com:6881',
];

/// 系统解析器签名（测试注入）。
typedef SystemHostLookup = Future<List<InternetAddress>> Function(String host);

Future<List<InternetAddress>> _defaultLookup(String host) =>
    InternetAddress.lookup(host, type: InternetAddressType.IPv4);

/// 系统 DNS 是否处在 fake-ip 模式：探测的公网域名里任一解析进 `198.18.0.0/15` 即是。
/// 解析失败的域名不计票；全部失败返回 false（那是断网，不是 fake-ip）。
Future<bool> isFakeIpDnsActive({
  List<String> probeHosts = const <String>[
    'router.bittorrent.com',
    'dht.transmissionbt.com',
  ],
  SystemHostLookup lookup = _defaultLookup,
}) async {
  for (final String host in probeHosts) {
    try {
      final List<InternetAddress> addresses =
          await lookup(host).timeout(const Duration(seconds: 5));
      if (addresses.any(isFakeIpAddress)) return true;
    } catch (_) {
      // 单个域名解析失败不代表什么，继续问下一个。
    }
  }
  return false;
}

/// DNS-over-HTTPS（JSON API）解析器。按 [endpoints] 顺序逐个试，第一个给出真实 A 记录的
/// 生效。两个默认端点：国内可直连的 AliDNS 与 Cloudflare。
class DohResolver {
  DohResolver({
    required http.Client client,
    this.endpoints = const <String>[
      'https://dns.alidns.com/resolve',
      'https://cloudflare-dns.com/dns-query',
    ],
    this.timeout = const Duration(seconds: 8),
  }) : _client = client;

  final http.Client _client;
  final List<String> endpoints;
  final Duration timeout;

  /// [host] 的真实 IPv4 列表；全部端点失败返回空表。IP 字面量原样返回。
  /// 结果里的 fake-ip 地址（DoH 被代理劫持时可能出现）一律剔除。
  Future<List<String>> resolveA(String host) async {
    final InternetAddress? literal = InternetAddress.tryParse(host);
    if (literal != null) {
      return literal.type == InternetAddressType.IPv4
          ? <String>[literal.address]
          : const <String>[];
    }
    for (final String endpoint in endpoints) {
      try {
        final Uri uri = Uri.parse(endpoint).replace(
            queryParameters: <String, String>{'name': host, 'type': 'A'});
        final http.Response response = await _client.get(
          uri,
          headers: const <String, String>{'accept': 'application/dns-json'},
        ).timeout(timeout);
        if (response.statusCode != 200) continue;
        final List<String> ips = parseDohJsonARecords(response.body);
        if (ips.isNotEmpty) return ips;
      } catch (_) {
        // 换下一个端点。
      }
    }
    return const <String>[];
  }
}

/// 解析 DoH JSON 应答（Google / Cloudflare / AliDNS 同一形状）里的 A 记录，
/// 剔除 fake-ip 段与非法值。纯函数。
List<String> parseDohJsonARecords(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const <String>[];
  }
  if (decoded is! Map) return const <String>[];
  final Object? answers = decoded['Answer'];
  if (answers is! List) return const <String>[];
  final List<String> out = <String>[];
  for (final Object? answer in answers) {
    if (answer is! Map || answer['type'] != 1) continue;
    final Object? data = answer['data'];
    if (data is! String) continue;
    final InternetAddress? ip = InternetAddress.tryParse(data.trim());
    if (ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        isFakeIpAddress(ip)) {
      continue;
    }
    if (!out.contains(ip.address)) out.add(ip.address);
  }
  return out;
}

/// 解析 `host:port`（IPv4 / 域名；不处理 IPv6 字面量）。非法返回 null。
({String host, int port})? splitHostPort(String hostPort) {
  final int colon = hostPort.lastIndexOf(':');
  if (colon <= 0 || colon == hostPort.length - 1) return null;
  final int? port = int.tryParse(hostPort.substring(colon + 1));
  if (port == null || port <= 0 || port > 65535) return null;
  return (host: hostPort.substring(0, colon), port: port);
}

/// 把 `udp://host:port/path` 里的 host 换成 [ip]。非 `udp://` 或解析失败返回 null。
String? rewriteUdpTrackerHost(String tracker, String ip) {
  final Uri? uri = Uri.tryParse(tracker);
  if (uri == null || uri.scheme != 'udp' || uri.host.isEmpty || !uri.hasPort) {
    return null;
  }
  return uri.replace(host: ip).toString();
}

/// fake-ip 绕行结果：要灌进 DHT 路由表的真实 `ip:port`，以及真实 IP 形式的 UDP tracker。
class FakeIpTorrentBypass {
  const FakeIpTorrentBypass({required this.dhtNodes, required this.trackers});

  static const FakeIpTorrentBypass empty = FakeIpTorrentBypass(
    dhtNodes: <String>[],
    trackers: <String>[],
  );

  final List<String> dhtNodes;
  final List<String> trackers;

  bool get isEmpty => dhtNodes.isEmpty && trackers.isEmpty;
}

/// 用 [doh] 把 [bootstrapHostPorts] 与 [udpTrackers] 解析成真实 IP 形式。
/// 每个域名最多取 [maxIpsPerHost] 个地址；解析失败的条目直接略过。
Future<FakeIpTorrentBypass> resolveFakeIpTorrentBypass({
  required DohResolver doh,
  List<String> bootstrapHostPorts = kDhtBootstrapHostPorts,
  required List<String> udpTrackers,
  int maxIpsPerHost = 2,
}) async {
  final Map<String, Future<List<String>>> cache =
      <String, Future<List<String>>>{};
  Future<List<String>> resolve(String host) =>
      cache.putIfAbsent(host, () => doh.resolveA(host));

  final List<String> nodes = <String>[];
  for (final String hostPort in bootstrapHostPorts) {
    final ({String host, int port})? hp = splitHostPort(hostPort);
    if (hp == null) continue;
    for (final String ip in (await resolve(hp.host)).take(maxIpsPerHost)) {
      final String node = '$ip:${hp.port}';
      if (!nodes.contains(node)) nodes.add(node);
    }
  }

  final List<String> trackers = <String>[];
  for (final String tracker in udpTrackers) {
    final Uri? uri = Uri.tryParse(tracker);
    if (uri == null || uri.scheme != 'udp' || uri.host.isEmpty) continue;
    for (final String ip in (await resolve(uri.host)).take(maxIpsPerHost)) {
      final String? rewritten = rewriteUdpTrackerHost(tracker, ip);
      if (rewritten != null && !trackers.contains(rewritten)) {
        trackers.add(rewritten);
      }
    }
  }
  return FakeIpTorrentBypass(dhtNodes: nodes, trackers: trackers);
}
