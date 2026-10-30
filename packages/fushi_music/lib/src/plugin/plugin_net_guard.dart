import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 插件 HTTP 请求失败（网络 / 超时 / 授权 / 超限）；[message] 原样交给插件。
final class MusicPluginHttpException implements Exception {
  const MusicPluginHttpException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 主机名解析（测试注入假解析；缺省走系统 DNS）。
typedef MusicPluginResolver =
    Future<List<InternetAddress>> Function(String host);

/// 地址是否禁止插件连接（缺省 [isMusicPluginPrivateAddress]；测试可放行回环）。
typedef MusicPluginAddressBlocker = bool Function(InternetAddress address);

/// 媒体地址的单跳探测：返回重定向目标（Location 原文），不是重定向返回 null。缺省
/// [MusicPluginGuardedHttp.probeRedirect]；测试注入假探测免得打真网络。
typedef MusicPluginMediaProbe =
    Future<String?> Function(Uri uri, Map<String, String> headers);

Future<List<InternetAddress>> _systemResolve(String host) =>
    InternetAddress.lookup(host);

/// 判断地址是否落在本机 / 局域网 / 保留段（与 Rust `policy::check_ip` 同一判据）。
///
/// 内嵌 IPv4 的 IPv6 形态（IPv4-mapped `::ffff:0:0/96`、IPv4-compatible `::/96`、NAT64
/// `64:ff9b::/96` 与 `64:ff9b:1::/48`、6to4 `2002::/16`）按内嵌的 IPv4 判。
///
/// **不含 `198.18.0.0/15`**：本地 DNS 在代理软件的 fake-ip / TUN 模式下把**所有**公网域名都解析到
/// 这一段（真实解析由代理在远端做），拦它等于让这类用户的插件全部断网；而经 fake-ip 地址连出去的
/// 流量由代理决定最终去向，本机这层判据本来就管不到（见 [MusicPluginGuardedHttp] 的代理说明）。
/// IP 字面量形式的 198.18/15 仍由 Rust 授权核对拒绝。
bool isMusicPluginPrivateAddress(InternetAddress a) {
  final Uint8List b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) return _privateV4(b);
  if (a.type != InternetAddressType.IPv6) return true;
  bool zeros(int from, int to) {
    for (int i = from; i < to; i++) {
      if (b[i] != 0) return false;
    }
    return true;
  }

  Uint8List v4(int at) => Uint8List.fromList(b.sublist(at, at + 4));
  // ::/128、::1、IPv4-compatible ::a.b.c.d（已废弃，按内嵌地址判）。
  if (zeros(0, 12)) {
    if (zeros(12, 15) && b[15] <= 1) return true;
    return _privateV4(v4(12));
  }
  // IPv4-mapped ::ffff:a.b.c.d
  if (zeros(0, 10) && b[10] == 0xff && b[11] == 0xff) return _privateV4(v4(12));
  // NAT64 64:ff9b::/96（众所周知前缀）与 64:ff9b:1::/48（本地使用前缀，整段按私网）。
  if (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b) {
    if (zeros(4, 12)) return _privateV4(v4(12));
    if (b[4] == 0x00 && b[5] == 0x01) return true;
  }
  // 6to4 2002:a.b.c.d::/48
  if (b[0] == 0x20 && b[1] == 0x02) return _privateV4(v4(2));
  return (b[0] & 0xfe) == 0xfc || // ULA fc00::/7
      (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) || // 链路本地 fe80::/10
      (b[0] == 0xfe && (b[1] & 0xc0) == 0xc0) || // 站点本地 fec0::/10（已废弃）
      b[0] == 0xff; // 组播 ff00::/8
}

bool _privateV4(Uint8List b) =>
    b[0] == 0 || // 0.0.0.0/8
    b[0] == 10 ||
    b[0] == 127 ||
    (b[0] == 100 && (b[1] & 0xc0) == 64) || // CGNAT 100.64/10
    (b[0] == 169 && b[1] == 254) ||
    (b[0] == 172 && (b[1] & 0xf0) == 16) ||
    (b[0] == 192 && b[1] == 168) ||
    (b[0] == 192 && b[1] == 0 && b[2] == 0) || // IETF 协议分配 192.0.0/24
    b[0] >= 224; // 组播 224/4、保留 240/4、广播

/// 解析 [host] 一次并核对：解析失败、没有地址、或**任一**地址落在私网段都拒绝（不放行），
/// 返回第一条地址供连接钉住。IP 字面量直接核对。
Future<InternetAddress> resolveMusicPluginPublicAddress(
  String host, {
  MusicPluginResolver resolve = _systemResolve,
  MusicPluginAddressBlocker isBlocked = isMusicPluginPrivateAddress,
}) async {
  final InternetAddress? literal = InternetAddress.tryParse(host);
  List<InternetAddress> addresses;
  if (literal != null) {
    addresses = <InternetAddress>[literal];
  } else {
    try {
      addresses = await resolve(host);
    } on SocketException catch (e) {
      throw MusicPluginHttpException('无法解析 $host：${e.message}');
    }
  }
  if (addresses.isEmpty) throw MusicPluginHttpException('无法解析 $host');
  for (final InternetAddress a in addresses) {
    if (isBlocked(a)) {
      throw MusicPluginHttpException('$host 解析到本机 / 局域网地址，已拒绝');
    }
  }
  return addresses.first;
}

/// 插件出站连接的守卫：每次请求前 [pin] 解析并核对目标主机，**实际建连只连核对过的那个 IP**
/// （自定义 `connectionFactory`；HTTPS 用原主机名做 SNI 与证书校验），DNS rebinding 无法在
/// 「核对」与「连接」之间换地址。
///
/// 走代理（app 代理装配给了 `findProxy`）时连接由代理建立、目标由代理解析，本机钉不住 IP：
/// 仍要求本机能解析且结果不在私网（插件不能把私网目标交给代理），代理端的二次解析是已知边界
/// ——代理是用户自己配置的出口，它把请求送到哪里由代理规则决定。
class MusicPluginGuardedHttp {
  MusicPluginGuardedHttp(
    this.client, {
    MusicPluginResolver resolve = _systemResolve,
    MusicPluginAddressBlocker isBlocked = isMusicPluginPrivateAddress,
  }) : _resolve = resolve,
       _isBlocked = isBlocked {
    client.connectionFactory = _connect;
  }

  final HttpClient client;
  final MusicPluginResolver _resolve;
  final MusicPluginAddressBlocker _isBlocked;
  final Map<String, InternetAddress> _pins = <String, InternetAddress>{};

  /// 解析并核对 [uri] 的主机，之后对它的新连接都钉在这个地址上。
  Future<void> pin(Uri uri) async {
    _pins[uri.host] = await resolveMusicPluginPublicAddress(
      uri.host,
      resolve: _resolve,
      isBlocked: _isBlocked,
    );
  }

  Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) {
    // 不论直连还是走代理，目标主机都必须先经 [pin] 核对过（解析成功且不在私网）。
    final InternetAddress? ip = _pins[uri.host];
    if (ip == null) {
      return Future<ConnectionTask<Socket>>.error(
        SocketException('未经核对的主机 ${uri.host}'),
      );
    }
    if (proxyHost != null && proxyPort != null) {
      return Socket.startConnect(proxyHost, proxyPort);
    }
    if (uri.scheme == 'https') {
      return Socket.startConnect(ip, uri.port).then(
        (ConnectionTask<Socket> t) => ConnectionTask.fromSocket<Socket>(
          t.socket.then<Socket>(
            (Socket s) => SecureSocket.secure(s, host: uri.host),
          ),
          t.cancel,
        ),
      );
    }
    return Socket.startConnect(ip, uri.port);
  }

  /// 媒体地址单跳探测：[pin] 核对后 `GET`（`Range: bytes=0-0`、不自动跟随重定向），只看
  /// 状态与 Location，不读响应体。返回 Location 原文；不是重定向返回 null。
  Future<String?> probeRedirect(Uri uri, Map<String, String> headers) async {
    await pin(uri);
    try {
      final HttpClientRequest req = await client
          .openUrl('GET', uri)
          .timeout(const Duration(seconds: 20));
      req.followRedirects = false;
      headers.forEach(req.headers.set);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final HttpClientResponse res = await req.close().timeout(
        const Duration(seconds: 20),
      );
      final String? location = res.headers.value(HttpHeaders.locationHeader);
      await res.listen(null).cancel();
      return res.isRedirect ? location : null;
    } on TimeoutException {
      throw const MusicPluginHttpException('媒体地址探测超时');
    } on SocketException catch (e) {
      throw MusicPluginHttpException('媒体地址网络错误：${e.message}');
    } on HttpException catch (e) {
      throw MusicPluginHttpException('媒体地址 HTTP 错误：${e.message}');
    } on HandshakeException catch (e) {
      throw MusicPluginHttpException('媒体地址 TLS 握手失败：${e.message}');
    }
  }

  void close({bool force = false}) => client.close(force: force);
}

/// 交给播放器的媒体请求头白名单（小写）：其余头一律拒绝，免得插件借播放器发任意请求头。
const Set<String> kMusicPluginMediaHeaderAllowlist = <String>{
  'user-agent',
  'referer',
  'origin',
  'cookie',
  'authorization',
  'accept',
  'accept-language',
};

/// 核对插件给的媒体请求头：名字在白名单里、值不含 CR / LF / NUL、数量与长度有上限。
/// 不合规抛 [MusicPluginHttpException]（不静默丢弃）。
Map<String, String> checkMusicPluginMediaHeaders(Map<String, String> headers) {
  if (headers.length > 16) {
    throw const MusicPluginHttpException('媒体请求头过多');
  }
  for (final MapEntry<String, String> e in headers.entries) {
    if (!kMusicPluginMediaHeaderAllowlist.contains(e.key.toLowerCase())) {
      throw MusicPluginHttpException('不允许的媒体请求头 ${e.key}');
    }
    if (e.value.length > 8 * 1024 ||
        e.value.contains('\r') ||
        e.value.contains('\n') ||
        e.value.contains('\u0000')) {
      throw MusicPluginHttpException('媒体请求头 ${e.key} 的值不合法');
    }
  }
  return Map<String, String>.unmodifiable(headers);
}
