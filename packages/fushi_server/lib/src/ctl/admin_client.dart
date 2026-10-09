/// 运行中 `fushi_server serve` 的 admin API 客户端（`fushi_server ctl` 用）。
///
/// 只走 WebUI 已有的 `/api/admin/*` JSON 面与 `Authorization: Bearer <admin_token>`
/// 通道，不另开协议：CLI 能做的事与 WebUI 一一对应，鉴权、限流、错误码都复用
/// [AdminServer] 那一份。
///
/// `tls: true` 时服务端用的是自签证书，这里**按指纹钉扎**接受它（与互联 client
/// 同一判据 [certificateMatchesFingerprint]），绝不无条件放行证书错误。
///
/// 另一种模式 [AdminClient.forInterconnect]：不经 fushi_server 的 admin 面，直接连
/// 一台**互联 host**（正在运行的 Fushi app 或 fushi_server 的互联端口），用 Basic
/// 鉴权（密码 = host token），admin 路径按 [interconnectPathFor] 翻成互联路径。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/credential_http_proxy.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:path/path.dart' as p;

/// admin API 返回了非 2xx。[status] 为 0 表示根本没连上（服务没起 / 端口不对）。
class AdminApiException implements Exception {
  const AdminApiException(this.status, this.message, {this.body});

  final int status;
  final String message;

  /// 服务端回的 JSON（若能解析）；409 之类的响应里常带有用的上下文。
  final Object? body;

  @override
  String toString() => status <= 0 ? message : 'HTTP $status: $message';
}

/// 一个已经确定了地址与凭据的 admin API 客户端。
class AdminClient {
  AdminClient({
    required this.baseUri,
    required this.token,
    HttpClient? httpClient,
    this.timeout = const Duration(seconds: 30),
  })  : interconnect = false,
        _authorization = 'Bearer $token',
        _http = withCredentialProxyPolicy(httpClient ?? HttpClient());
  // 每个请求都带 admin_token：回环 / 明文目标恒直连，绝不交给环境代理
  // （见 credential_http_proxy.dart）。

  /// 直连互联 host 的客户端：Basic 鉴权（用户名随意，密码 = host token），
  /// 路径经 [interconnectPathFor] 改写。
  AdminClient.interconnect({
    required this.baseUri,
    required String password,
    HttpClient? httpClient,
    this.timeout = const Duration(seconds: 60),
  })  : interconnect = true,
        token = password,
        _authorization = 'Basic ${base64Encode(utf8.encode('fushi:$password'))}',
        _http = withCredentialProxyPolicy(httpClient ?? HttpClient());

  /// 连 [url] 上的互联 host。
  ///
  /// https 时 host 用的是自签证书：给了 [fingerprint] 就按指纹钉扎；没给就**只对
  /// 这一个显式指定的 host:port** 放行证书校验失败（用户在命令行上点名了它，
  /// 等价于互联 client 首次连接时的 TOFU）。其它主机名 / 端口的坏证书照样拒绝。
  /// 走不可信网络时请用 `--fingerprint` 钉死（host 的「互联」设置页 / 配对时可见）。
  static AdminClient forInterconnect({required String url, required String password, String? fingerprint}) {
    final Uri baseUri = Uri.parse(url.trim());
    if (!baseUri.hasScheme || baseUri.host.isEmpty || !<String>{'http', 'https'}.contains(baseUri.scheme)) {
      throw AdminApiException(0, '无效的 --interconnect: $url（要写成 http(s)://host:port）');
    }
    if (password.isEmpty) {
      throw const AdminApiException(0, '缺 host 密码：用 --password 或环境变量 FUSHI_HOST_PASSWORD');
    }
    final HttpClient http = HttpClient();
    if (baseUri.scheme == 'https') {
      final String? pin = _nonEmpty(fingerprint);
      http.badCertificateCallback = (X509Certificate cert, String host, int port) => pin != null
          ? certificateMatchesFingerprint(cert, pin)
          : host == baseUri.host && port == baseUri.port;
    }
    return AdminClient.interconnect(baseUri: baseUri, password: password, httpClient: http);
  }

  /// 由服务端配置推出地址与凭据。
  ///
  /// * [url] 覆盖地址（如 `https://nas.local:38780`）；缺省按配置的
  ///   `admin_bind` / `admin_port` / `tls` 推本机地址（通配 bind 换成回环）。
  /// * [token] 覆盖 `admin_token`。
  /// * [fingerprint] 覆盖 TLS 钉扎指纹；缺省读数据目录里服务端自己的证书。
  ///
  /// 配置缺凭据 / admin 端口被关 / TLS 证书读不到时抛 [AdminApiException]（status 0）。
  static Future<AdminClient> fromConfig(ServerConfig config, {String? url, String? token, String? fingerprint}) async {
    final String? resolvedToken = _nonEmpty(token) ?? _nonEmpty(config.adminToken);
    if (resolvedToken == null) {
      throw const AdminApiException(0, '配置里没有 admin_token；先跑 fushi_server admin reset-token');
    }
    final Uri baseUri;
    if (_nonEmpty(url) != null) {
      baseUri = Uri.parse(url!.trim());
      if (!baseUri.hasScheme || baseUri.host.isEmpty) {
        throw AdminApiException(0, '无效的 --url: $url（要写成 http(s)://host:port）');
      }
    } else {
      if (config.adminPort <= 0) {
        throw const AdminApiException(0, '配置里 admin_port 为 0（WebUI / admin API 已关闭），ctl 无处可连');
      }
      baseUri = Uri(
        scheme: config.tls ? 'https' : 'http',
        host: adminLoopbackHost(config.adminBind),
        port: config.adminPort,
      );
    }
    final HttpClient http = HttpClient();
    if (baseUri.scheme == 'https') {
      final String pin = _nonEmpty(fingerprint) ?? await _localFingerprint(config);
      http.badCertificateCallback = (X509Certificate cert, String host, int port) =>
          certificateMatchesFingerprint(cert, pin);
    }
    return AdminClient(baseUri: baseUri, token: resolvedToken, httpClient: http);
  }

  final Uri baseUri;

  /// admin 模式是 admin_token；互联模式是 host 密码。
  final String token;
  final Duration timeout;

  /// true = 直连互联 host（[AdminClient.forInterconnect]）。
  final bool interconnect;
  final String _authorization;
  final HttpClient _http;

  Future<Object?> get(String path, {Map<String, String>? query}) => send('GET', path, query: query);

  Future<Object?> post(String path, {Object? body, Map<String, String>? query}) =>
      send('POST', path, body: body, query: query);

  Future<Object?> put(String path, {Object? body}) => send('PUT', path, body: body);

  Future<Object?> delete(String path, {Map<String, String>? query}) => send('DELETE', path, query: query);

  /// 发一个请求，返回解析后的 JSON（空响应体返回 null）。
  ///
  /// [path] 是 `/api/admin/...` 形式的绝对路径；路径里的 id 由调用方用
  /// [adminPathSegment] 编码。非 2xx 抛 [AdminApiException]。
  Future<Object?> send(String method, String path, {Object? body, Map<String, String>? query}) => _send(
    method,
    path,
    query: query,
    write: (HttpClientRequest request) async {
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
    },
  );

  /// 发一段原始字节（分块上传用）：[headers] 原样带上，[bytes] 作请求体。
  Future<Object?> sendBytes(
    String method,
    String path, {
    required List<int> bytes,
    Map<String, String>? query,
    Map<String, String> headers = const <String, String>{},
  }) => _send(
    method,
    path,
    query: query,
    write: (HttpClientRequest request) async {
      headers.forEach(request.headers.set);
      request.headers.contentType = ContentType.binary;
      request.contentLength = bytes.length;
      request.add(bytes);
    },
  );

  Future<Object?> _send(
    String method,
    String path, {
    required Future<void> Function(HttpClientRequest request) write,
    Map<String, String>? query,
  }) async {
    final Uri uri = baseUri.replace(
      path: _joinPath(baseUri.path, interconnect ? interconnectPathFor(path) : path),
      queryParameters: query == null || query.isEmpty ? null : query,
    );
    final HttpClientResponse response;
    final String text;
    try {
      final HttpClientRequest request = await _http.openUrl(method, uri).timeout(timeout);
      request.headers.set(HttpHeaders.authorizationHeader, _authorization);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      await write(request);
      response = await request.close().timeout(timeout);
      text = await response.transform(utf8.decoder).join().timeout(timeout);
    } on TimeoutException {
      throw AdminApiException(0, '请求超时: $method $uri');
    } on HandshakeException catch (e) {
      throw AdminApiException(0, 'TLS 握手失败（证书指纹不符？）: $uri ${e.message}');
    } on SocketException catch (e) {
      throw AdminApiException(
        0,
        '连不上 $uri（${interconnect ? 'Fushi 的互联服务开着吗？' : 'fushi_server serve 在跑吗？'}）: ${e.message}',
      );
    }
    final Object? decoded = _tryDecode(text);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // admin 面回 `{error}`；互联面的 409 回 `{reason, message}`，400 回纯文本。
      final String message = decoded is Map && decoded['error'] != null
          ? decoded['error'].toString()
          : decoded is Map && decoded['message'] != null
          ? decoded['message'].toString()
          : (text.isEmpty ? response.reasonPhrase : text);
      throw AdminApiException(response.statusCode, message, body: decoded);
    }
    return decoded;
  }

  void close() => _http.close(force: true);
}

/// 通配 bind（`0.0.0.0` / `::` / 空）换成对应的回环地址；具体地址原样用。
String adminLoopbackHost(String bind) {
  final String b = bind.trim();
  if (b.isEmpty || b == '0.0.0.0') return '127.0.0.1';
  if (b == '::' || b == '[::]') return '::1';
  return b;
}

/// [AdminApiException.status] 取这个值 = 本地判定的用法错误（没发请求），ctl 退出码 64。
const int kCtlUsageErrorStatus = -64;

/// 互联模式下 admin 路径 → 互联路径：`/api/admin/host/<x>` → `/api/<x>`（admin 代理
/// 本来就是这么转的），`/api/admin/downloads…` → `/api/downloads…`（同一份
/// `HostDownloadHost`）。其余 admin 接口（状态、库根、模型、Anki…）只有 fushi_server
/// 有，互联 host 上不存在，直接报用法错误而不是发一个注定 404 的请求。
String interconnectPathFor(String adminPath) {
  const String host = '/api/admin/host/';
  const String downloads = '/api/admin/downloads';
  if (adminPath.startsWith(host)) return '/api/${adminPath.substring(host.length)}';
  if (adminPath == downloads || adminPath.startsWith('$downloads/')) {
    return '/api/downloads${adminPath.substring(downloads.length)}';
  }
  throw AdminApiException(
    kCtlUsageErrorStatus,
    '$adminPath 只有 fushi_server 的 admin 面有；--interconnect 模式支持 downloads / videos / books / '
    'audiobooks / manga / dict / metadata / scrape search|identify / collections / tags / host <METHOD> <path>',
  );
}

/// 编码一个路径段（id 里可能有 `/`、空格等）。
String adminPathSegment(String value) => Uri.encodeComponent(value);

Future<String> _localFingerprint(ServerConfig config) async {
  // 只读、不生成：证书不存在说明服务端从没以 tls 起过，生成一张新的只会钉错。
  final File cert = File(p.join(ServerPaths(config.dataDir).syncData.path, 'sync-tls', 'identity-cert.pem'));
  if (!await cert.exists()) {
    throw AdminApiException(0, '找不到服务端 TLS 证书 ${cert.path}；先启动一次 serve，或用 --fingerprint 指定');
  }
  return FushiTlsIdentityStore.fingerprintOf(await cert.readAsString());
}

String _joinPath(String base, String path) {
  final String left = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  final String right = path.startsWith('/') ? path : '/$path';
  return '$left$right';
}

Object? _tryDecode(String text) {
  if (text.isEmpty) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return text;
  }
}

String? _nonEmpty(String? value) {
  final String? v = value?.trim();
  return v == null || v.isEmpty ? null : v;
}
