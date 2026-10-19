/// 手动跟随 HTTP 重定向时的**凭据 origin 边界**。
///
/// ## 为什么平台的自动跟随不够
///
/// `dart:io` 的 `HttpClient.followRedirects` 跨 origin 时只剥一张写死的清单
/// （`authorization` / `www-authenticate` / `proxy-authorization` /
/// `proxy-authenticate` / `cookie` / `cookie2`，见 SDK `http_impl.dart`
/// 的 `shouldCopyHeaderOnRedirect`），其余请求头一律原样转发。而自建服务端的
/// 非标准凭据头不在那张清单里——Komga 只认 `X-API-Key`（实测 `?apikey=`、
/// Basic 里塞 key、路径带 key 全部 401）。交给自动跟随的话，服务端一个
/// 302 指向对象存储 / CDN，用户的 API key 就被原样送给了第三方主机。
///
/// 所以带这类头的请求必须 `followRedirects = false`，自己逐跳跟随，并在
/// 每一跳用 [headersForRedirectHop] 重算要发的头。
library;

/// 只能发给**原 origin** 的请求头（小写）。跨 origin 的重定向一律剥掉。
///
/// 前六个与 SDK 自动跟随剥的清单逐字一致（手动跟随后平台不再替我们剥），
/// 末尾是平台清单之外、实测在用的凭据头。
const Set<String> kOriginBoundHeaderNames = <String>{
  'authorization',
  'www-authenticate',
  'proxy-authorization',
  'proxy-authenticate',
  'cookie',
  'cookie2',
  'x-api-key',
};

/// 手动跟随时最多跟几跳（与下载队列原先给 `HttpClient.maxRedirects` 的值一致）。
const int kMaxManualRedirects = 8;

/// 是否是带 `Location` 的重定向状态码。
bool isFollowableRedirectStatus(int status) =>
    status == 301 ||
    status == 302 ||
    status == 303 ||
    status == 307 ||
    status == 308;

/// 同源判据：scheme + host + 端口（含默认端口归一）全等（RFC 6454）。
bool isSameHttpOrigin(Uri a, Uri b) =>
    a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
    a.host.toLowerCase() == b.host.toLowerCase() &&
    _effectivePort(a) == _effectivePort(b);

int _effectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return switch (uri.scheme.toLowerCase()) {
    'https' => 443,
    'http' => 80,
    _ => 0,
  };
}

/// 从 [from] 重定向到 [to] 时下一跳该带的头：同源原样保留；跨源剥掉
/// [kOriginBoundHeaderNames] 里的凭据头，其余（`Referer` / `User-Agent` /
/// `Range` 这类防盗链与续传头）照常转发。
Map<String, String> headersForRedirectHop(
  Map<String, String> headers, {
  required Uri from,
  required Uri to,
}) {
  if (isSameHttpOrigin(from, to)) return headers;
  return <String, String>{
    for (final MapEntry<String, String> entry in headers.entries)
      if (!kOriginBoundHeaderNames.contains(entry.key.toLowerCase()))
        entry.key: entry.value,
  };
}
