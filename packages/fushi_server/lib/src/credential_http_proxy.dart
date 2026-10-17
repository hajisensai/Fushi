/// 带凭据（admin_token / 互联 host token）出站的 CLI 客户端的代理策略。
///
/// dart:io 的 [HttpClient] **默认就读 `HTTP_PROXY` / `HTTPS_PROXY`**
/// （`findProxy` 缺省是 [HttpClient.findProxyFromEnvironment]），而且不给回环地址
/// 开例外：`fushi_server ctl` 打 `127.0.0.1` 的 admin API 时，`Authorization:
/// Bearer <admin_token>` 会被原样交给代理。
///
/// 判据（只看目标 URL，不看当前有没有设代理）：
/// - **回环目标**（`localhost` / `127.0.0.0/8` / `::1`）恒直连：本机请求经代理没有
///   任何收益，只会多一个能看到凭据的中间方；
/// - **明文 http 目标**恒直连：经代理就是把明文凭据交给代理；
/// - **https 非回环目标**跟随环境代理：代理只看到 CONNECT 隧道，TLS 由调用方按证书
///   指纹钉扎，代理读不到凭据；远端 host 可能确实要经代理才连得上。
library;

import 'dart:io';

/// 带凭据的请求打到 [uri] 时该走的 `findProxy` 指令（`DIRECT` / `PROXY host:port`）。
String credentialProxyFor(Uri uri) {
  if (uri.scheme != 'https' || isLoopbackHost(uri.host)) return 'DIRECT';
  return HttpClient.findProxyFromEnvironment(uri);
}

/// 给一个将要携带凭据的 [client] 装上 [credentialProxyFor] 策略，返回同一个 client。
HttpClient withCredentialProxyPolicy(HttpClient client) =>
    client..findProxy = credentialProxyFor;

/// [host]（URI 里的 host，IPv6 不带方括号）是否本机回环。
bool isLoopbackHost(String host) {
  final String h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  return InternetAddress.tryParse(h)?.isLoopback ?? false;
}
