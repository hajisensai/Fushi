/// AnkiConnect 兼容层的媒体入口（storeMediaFile / addNote 的 audio·video·picture）。
///
/// 第六轮审查第 19 条：
/// - `data`（base64）默认允许；
/// - `path` 能读本机任意文件 → 默认禁用，[SrsAnkiMediaPolicy.allowPath] 显式打开；
/// - `url` 是 SSRF → 默认禁用，[SrsAnkiMediaPolicy.allowUrl] 显式打开；打开时也只接受
///   http(s)，且解析出的每个地址都必须是公网地址（拒绝回环 / 私网 / 链路本地 / CGNAT /
///   组播 / 保留段），下载由宿主注入的 fetcher 只连已核验过的那个地址（防 DNS 重绑定），
///   重定向逐跳重新核验；没注入 fetcher 时 url 一律不可用。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 媒体字节交给宿主落盘（宿主按内容哈希存），返回实际文件名。
typedef SrsAnkiMediaSink =
    Future<String> Function(String filename, Uint8List bytes);

/// 域名解析（测试可注入）。
typedef SrsAnkiHostResolver =
    Future<List<InternetAddress>> Function(String host);

/// 已核验地址上的下载（测试可注入）：[address] 是核验过的公网地址，[uri] 是原 URL。
typedef SrsAnkiUrlFetcher =
    Future<SrsAnkiFetchResult> Function(Uri uri, InternetAddress address);

/// 一次下载的结果：200 带字节；3xx 带 Location（由调用方核验后再跟）。
class SrsAnkiFetchResult {
  const SrsAnkiFetchResult.ok(Uint8List this.bytes) : redirect = null;
  const SrsAnkiFetchResult.redirect(Uri this.redirect) : bytes = null;

  final Uint8List? bytes;
  final Uri? redirect;
}

/// 媒体参数开关。默认只允许 base64 `data`。
class SrsAnkiMediaPolicy {
  const SrsAnkiMediaPolicy({this.allowPath = false, this.allowUrl = false});

  final bool allowPath;
  final bool allowUrl;
}

/// 媒体被策略拒绝 / 下载失败。消息是 AnkiConnect 风格的英文错误串。
class SrsAnkiMediaException implements Exception {
  const SrsAnkiMediaException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 地址是否可以作为 `url` 下载的目标：只放行全球单播公网地址。
bool srsAnkiAddressIsPublic(InternetAddress address) {
  final List<int> b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && b.length == 4) {
    return _ipv4IsPublic(b);
  }
  if (address.type == InternetAddressType.IPv6 && b.length == 16) {
    // IPv4 映射 / 兼容地址（::ffff:a.b.c.d、::a.b.c.d）与 NAT64（64:ff9b::/96）按内层 IPv4 判。
    final bool zeros10 = b.sublist(0, 10).every((int x) => x == 0);
    if (zeros10 && b[10] == 0xff && b[11] == 0xff) {
      return _ipv4IsPublic(b.sublist(12));
    }
    if (zeros10 && b[10] == 0 && b[11] == 0) {
      return false; // ::、::1 与已废弃的 IPv4 兼容地址一律拒绝。
    }
    if (b[0] == 0x00 &&
        b[1] == 0x64 &&
        b[2] == 0xff &&
        b[3] == 0x9b &&
        b.sublist(4, 12).every((int x) => x == 0)) {
      return _ipv4IsPublic(b.sublist(12));
    }
    if ((b[0] & 0xfe) == 0xfc) return false; // fc00::/7 唯一本地
    if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return false; // fe80::/10 链路本地
    // fec0::/10 站点本地（废弃）
    if (b[0] == 0xfe && (b[1] & 0xc0) == 0xc0) return false;
    if (b[0] == 0xff) return false; // ff00::/8 组播
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) {
      return false; // 2001:db8::/32 文档
    }
    // 只放行全球单播 2000::/3。
    return (b[0] & 0xe0) == 0x20;
  }
  return false;
}

bool _ipv4IsPublic(List<int> b) {
  final int a = b[0], c = b[1];
  if (a == 0) return false; // 0.0.0.0/8
  if (a == 10) return false; // 10/8
  if (a == 127) return false; // 回环
  if (a == 100 && c >= 64 && c <= 127) return false; // 100.64/10 CGNAT
  if (a == 169 && c == 254) return false; // 链路本地
  if (a == 172 && c >= 16 && c <= 31) return false; // 172.16/12
  if (a == 192 && c == 168) return false; // 192.168/16
  if (a == 192 && c == 0 && (b[2] == 0 || b[2] == 2)) return false;
  if (a == 198 && (c == 18 || c == 19)) return false; // 198.18/15（含代理 fake-ip）
  if (a == 198 && c == 51 && b[2] == 100) return false;
  if (a == 203 && c == 0 && b[2] == 113) return false;
  if (a >= 224) return false; // 组播 / 保留 / 广播
  return true;
}

/// 把 URL 核验到一个可连接的公网地址；不合格抛 [SrsAnkiMediaException]。
Future<InternetAddress> srsAnkiVetUrl(
  Uri uri, {
  SrsAnkiHostResolver? resolve,
}) async {
  final String scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    throw SrsAnkiMediaException(
      'url scheme "${uri.scheme}" is not allowed (only http/https)',
    );
  }
  final String host = uri.host;
  if (host.isEmpty) throw const SrsAnkiMediaException('url has no host');
  final InternetAddress? literal = InternetAddress.tryParse(
    host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host,
  );
  final List<InternetAddress> addresses = literal != null
      ? <InternetAddress>[literal]
      : await (resolve ?? InternetAddress.lookup)(host);
  if (addresses.isEmpty) {
    throw SrsAnkiMediaException('url host "$host" did not resolve');
  }
  for (final InternetAddress a in addresses) {
    if (!srsAnkiAddressIsPublic(a)) {
      throw SrsAnkiMediaException(
        'url host "$host" resolves to a non-public address (${a.address}); '
        'loopback / private / link-local targets are refused',
      );
    }
  }
  return addresses.first;
}

/// 按策略下载 `url`：每一跳都重新核验，最多 3 次重定向。
///
/// 真正的网络请求由宿主注入的 [fetch] 做（引擎里不建裸 HttpClient：出站要经 app 的装配点，
/// 见 fushi/test/tools/outbound_http_discipline_guard_test.dart）。[fetch] 必须只连交给它的
/// 已核验地址、不自动跟重定向（重定向交回这里重新核验），否则 DNS 重绑定会绕过地址检查。
Future<Uint8List> srsAnkiDownload(
  Uri uri, {
  SrsAnkiHostResolver? resolve,
  required SrsAnkiUrlFetcher fetch,
}) async {
  Uri current = uri;
  for (int hop = 0; hop <= 3; hop++) {
    final InternetAddress address = await srsAnkiVetUrl(
      current,
      resolve: resolve,
    );
    final SrsAnkiFetchResult r = await fetch(current, address);
    if (r.bytes != null) return r.bytes!;
    current = r.redirect!;
  }
  throw const SrsAnkiMediaException('too many redirects');
}

/// 只取文件名本身（去掉任何目录部分），拒绝空名与 `.` / `..`。
String srsAnkiSanitizeFilename(String raw) {
  final String base = raw.split(RegExp(r'[\\/]')).last.trim();
  if (base.isEmpty || base == '.' || base == '..' || base.contains('\x00')) {
    throw SrsAnkiMediaException('invalid media filename "$raw"');
  }
  return base;
}
