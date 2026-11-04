/// 通用联网搜索：给 AI 功能用的「搜关键词 → 取结果页正文」接口。
///
/// [WebKnowledgeClient]（`web_knowledge.dart`）只查固定的资料站（MediaWiki / ANN /
/// TVmaze）；歌词、主题曲名这类东西散在任意网站上，需要真正的搜索引擎。和资料站一样
/// **由 app 自己去搜、去抓**，AI 只读抓回来的文本——行为与 AI 提供商有没有联网工具无关。
///
/// 后端（[WebSearchKind]）：
/// * SearXNG（自建或公共实例）：`GET <endpoint>/search?q=&format=json`，实例需在
///   `settings.yml` 的 `search.formats` 里打开 `json`；
/// * Brave Search API：`GET https://api.search.brave.com/res/v1/web/search?q=`，
///   `X-Subscription-Token` 头带 API key。
///
/// 出站一律经 `createAppHttpClient()`（应用代理 + 连接超时）。
///
/// 抓结果页的 SSRF 防护（搜索结果是不可信输入，不能让它把请求引到本机 / 局域网）：
/// * 只接受 http / https；本机 / 内网的主机名与 IP 字面量直接拒（[isFetchableWebSearchUrl]）；
/// * 域名先解析，解析出的**每个**地址都要是公网地址（[isPublicWebSearchAddress]，
///   IPv4-mapped IPv6 还原成 IPv4 再判，`0.0.0.0` / `::` 一律拒）；
/// * 重定向不交给 HTTP 栈自动跟：手动逐跳跟（最多 [kWebSearchMaxRedirects] 跳），每一跳都
///   重新过上面两道；
/// * 建连时按已校验的地址连（[webSearchPinnedConnectionFactory]），解析与建连之间被
///   DNS rebinding 换成内网地址也连不过去。走应用代理时同样钉死：抓页客户端不让 HTTP 栈
///   去问代理（那样代理拿到的是主机名，会在它那头重新解析），而是自己向代理发
///   `CONNECT <已校验的 IP>:<端口>`，https 再在隧道上按原主机名做 TLS（SNI 与证书校验
///   不变）。代理收到的只有校验过的公网 IP，没有可以被重新解析的名字。
///
/// SearXNG 实例地址是用户自己配的（常是局域网自建），搜索请求不受这套限制。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/ai/web_knowledge.dart' show webKnowledgeHtmlToText;
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart'
    show appManualProxyBasicCredentials, resolveAppProxyDirective;
import 'package:fushi_engine/utils/net/app_user_agent.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 单个响应体（搜索 JSON / 结果页 HTML）的字节上限。
const int kWebSearchMaxResponseBytes = 4 * 1024 * 1024;

/// 抓结果页时最多跟几跳重定向。
const int kWebSearchMaxRedirects = 5;

/// 代理隧道响应头（`HTTP/1.1 200 …` 到空行）的字节上限。
const int kWebSearchMaxProxyResponseHeaderBytes = 8 * 1024;

/// 某个 URL 此刻该走的出口，`HttpClient.findProxy` 指令格式（`DIRECT` /
/// `PROXY host:port` / `PROXY user:pass@host:port`，`;` 分隔取第一条）。生产用
/// [resolveAppProxyDirective]（应用代理设置），测试注入。
typedef WebSearchProxyDirective = String Function(Uri url);

/// 主机名 → 地址（生产用 [InternetAddress.lookup]；测试注入）。
typedef WebSearchHostResolver =
    Future<List<InternetAddress>> Function(String host);

Future<List<InternetAddress>> _systemLookup(String host) =>
    InternetAddress.lookup(host);

/// 搜索后端。
enum WebSearchKind {
  searxng,
  brave;

  static WebSearchKind? fromName(Object? name) {
    for (final WebSearchKind k in values) {
      if (k.name == name) return k;
    }
    return null;
  }
}

/// 用户配置的搜索后端。[isUsable] 为假时视为没配（调用方当作「不联网搜索」）。
class WebSearchConfig {
  const WebSearchConfig({required this.kind, this.endpoint, this.apiKey});

  /// 从散字段建（服务端 yaml 等手写配置）：去首尾空白，空串当没填；未知后端 → null。
  static WebSearchConfig? fromFields({
    required Object? kind,
    Object? endpoint,
    Object? apiKey,
  }) {
    final WebSearchKind? k = WebSearchKind.fromName(kind);
    if (k == null) return null;
    return WebSearchConfig(
      kind: k,
      endpoint: _nonBlank(endpoint),
      apiKey: _nonBlank(apiKey),
    );
  }

  /// 偏好里的 JSON（`{"kind":"brave","apiKeyB64":"…"}`）。坏 JSON / 未知后端 → null。
  static WebSearchConfig? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    return decoded is Map ? fromJson(decoded.cast<String, Object?>()) : null;
  }

  /// 读 [toJson] 的形状。API key 与 `ai_providers` 同一存法：`apiKeyB64`（base64）；
  /// 没有它时读旧版明文 `apiKey`（本功能最早一版这样写），下次写回即迁成 base64
  /// （[needsStorageMigration]）。
  static WebSearchConfig? fromJson(Map<String, Object?> json) {
    final String? encoded = _nonBlank(json['apiKeyB64']);
    return fromFields(
      kind: json['kind'],
      endpoint: json['endpoint'],
      apiKey: encoded != null ? _unb64(encoded) : json['apiKey'],
    );
  }

  /// 偏好原串还是旧版明文 key 的形状（有 `apiKey`）→ 该按 [encode] 重写一遍。
  static bool needsStorageMigration(String? raw) {
    if (raw == null || raw.trim().isEmpty) return false;
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is Map && decoded.containsKey('apiKey');
    } on FormatException {
      return false;
    }
  }

  final WebSearchKind kind;

  /// SearXNG 实例根地址（如 `https://searx.example.org`）。Brave 不用。
  final String? endpoint;

  /// Brave 的订阅 token；SearXNG 不用（实例自带鉴权的可放进 [endpoint] 的 query）。
  final String? apiKey;

  /// 配全了没有：SearXNG 要一个 http(s) 根地址，Brave 要 key。
  bool get isUsable => switch (kind) {
    WebSearchKind.searxng => searxngBase != null,
    WebSearchKind.brave => apiKey != null,
  };

  /// 规范化后的 SearXNG 根地址；不是合法的 http(s) 地址 → null。
  Uri? get searxngBase {
    final String? raw = endpoint;
    if (raw == null) return null;
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasAuthority) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    return uri;
  }

  /// API key 在 JSON 里 base64 存放，与 `AiProviderConfig.toJson` 的 `apiKeyB64` 同一
  /// 口径：**遮蔽不是加密**，真正的纪律是隔离——`ai_web_search` 登记在
  /// `kCredentialPreferenceKeys`、`PrefRedactionPolicy.sensitiveKeys` 与设备本地清单。
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    if (endpoint != null) 'endpoint': endpoint,
    if (apiKey != null) 'apiKeyB64': base64Encode(utf8.encode(apiKey!)),
  };

  String encode() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is WebSearchConfig &&
      other.kind == kind &&
      other.endpoint == endpoint &&
      other.apiKey == apiKey;

  @override
  int get hashCode => Object.hash(kind, endpoint, apiKey);
}

String? _nonBlank(Object? v) =>
    v is String && v.trim().isNotEmpty ? v.trim() : null;

/// base64 → 文本；坏值当没填（与 `ai_provider_config.dart` 的 `_unb64` 同口径）。
String? _unb64(String raw) {
  try {
    return utf8.decode(base64Decode(raw));
  } on FormatException {
    return null;
  }
}

/// 一条搜索结果。
class WebSearchHit {
  const WebSearchHit({
    required this.title,
    required this.url,
    this.snippet = '',
  });

  final String title;
  final Uri url;

  /// 搜索引擎给的摘要（纯文本）。
  final String snippet;

  @override
  String toString() => 'WebSearchHit($title, $url)';
}

/// 抓回来的一页正文。
class WebSearchPage {
  const WebSearchPage({
    required this.url,
    required this.title,
    required this.text,
  });

  final Uri url;
  final String title;

  /// 剥掉标签后的纯文本（已截断）。
  final String text;
}

/// 通用搜索客户端。所有失败只记诊断日志、返回空，不抛：联网搜索是锦上添花，
/// 不能让调用它的 AI 流程（字幕生成等）整体失败。
class WebSearchClient {
  /// [client] 发搜索请求；抓结果页用 [pageClient]，没给就用 [client]；两个都没给时
  /// 另建一个按已校验地址建连的客户端（[createWebSearchPageHttpClient]，见库注释）。
  /// [resolveHost] 是抓页前校验主机名用的解析器，[proxyDirective] 是抓页出口
  /// （默认应用代理设置）。
  WebSearchClient({
    required this.config,
    http.Client? client,
    http.Client? pageClient,
    WebSearchHostResolver? resolveHost,
    WebSearchProxyDirective? proxyDirective,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null,
       _resolveHost = resolveHost ?? _systemLookup,
       _pageClient =
           pageClient ??
           client ??
           IOClient(
             createWebSearchPageHttpClient(
               resolveHost: resolveHost ?? _systemLookup,
               proxyDirective: proxyDirective ?? _appProxyDirective,
             ),
           ),
       _ownsPageClient = pageClient == null && client == null;

  final WebSearchConfig config;
  final http.Client _client;
  final bool _ownsClient;
  final http.Client _pageClient;
  final bool _ownsPageClient;
  final WebSearchHostResolver _resolveHost;
  final Duration requestTimeout;

  bool get isEnabled => config.isUsable;

  void close() {
    if (_ownsClient) _client.close();
    if (_ownsPageClient) _pageClient.close();
  }

  /// 搜 [query]，最多 [limit] 条。
  Future<List<WebSearchHit>> search(String query, {int limit = 8}) async {
    final String q = query.trim();
    if (q.isEmpty || limit <= 0 || !config.isUsable) {
      return const <WebSearchHit>[];
    }
    try {
      final List<WebSearchHit> hits = switch (config.kind) {
        WebSearchKind.searxng => parseSearxngResults(
          await _get(_searxngUri(q), accept: 'application/json'),
        ),
        WebSearchKind.brave => parseBraveResults(
          await _get(
            Uri.https('api.search.brave.com', '/res/v1/web/search', {
              'q': q,
              'count': '${limit.clamp(1, 20)}',
            }),
            accept: 'application/json',
            headers: <String, String>{
              'X-Subscription-Token': config.apiKey ?? '',
            },
          ),
        ),
      };
      return hits.take(limit).toList();
    } catch (e) {
      engineLog.logDiagnostic(
        'webSearch.search',
        '${config.kind.name} "$q" failed: $e',
      );
      return const <WebSearchHit>[];
    }
  }

  /// 取 [url] 的正文（HTML 剥成文本，截到 [maxChars]）。不安全的地址（含重定向途经的
  /// 任一跳）/ 失败 → null。
  Future<WebSearchPage?> fetchPage(
    Uri url, {
    String title = '',
    int maxChars = 20000,
  }) async {
    try {
      final String? body = await _fetchFollowingRedirects(
        url,
      ).timeout(requestTimeout);
      if (body == null) return null;
      final String text = webKnowledgeHtmlToText(body);
      return WebSearchPage(
        url: url,
        title: title,
        text: text.length > maxChars ? text.substring(0, maxChars) : text,
      );
    } catch (e) {
      engineLog.logDiagnostic('webSearch.fetch', '$url failed: $e');
      return null;
    }
  }

  /// 手动跟重定向：每一跳先过 [isFetchableWebSearchTarget] 再发请求。哪一跳不安全 /
  /// 跳数超限 → null（记诊断日志）。
  Future<String?> _fetchFollowingRedirects(Uri url) async {
    Uri current = url;
    for (int hop = 0; hop <= kWebSearchMaxRedirects; hop++) {
      if (!await isFetchableWebSearchTarget(current, resolve: _resolveHost)) {
        engineLog.logDiagnostic(
          'webSearch.fetch',
          'refused non-public target $current (from $url)',
        );
        return null;
      }
      final http.StreamedResponse response = await _send(
        _pageClient,
        current,
        accept: 'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5',
      );
      if (_isRedirectStatus(response.statusCode)) {
        final String? location = response.headers['location'];
        unawaited(response.stream.drain<void>().catchError((Object _) {}));
        if (location == null || location.trim().isEmpty) {
          throw StateError(
            'HTTP ${response.statusCode} without Location for ${current.host}',
          );
        }
        current = current.resolve(location.trim());
        continue;
      }
      return _readBody(response, current);
    }
    engineLog.logDiagnostic(
      'webSearch.fetch',
      'too many redirects from $url (> $kWebSearchMaxRedirects)',
    );
    return null;
  }

  Uri _searxngUri(String q) {
    final Uri base = config.searxngBase!;
    final String path = base.path.endsWith('/')
        ? '${base.path}search'
        : '${base.path}/search';
    return base.replace(
      path: path,
      queryParameters: <String, String>{
        ...base.queryParameters,
        'q': q,
        'format': 'json',
      },
    );
  }

  Future<String> _get(
    Uri uri, {
    required String accept,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final http.StreamedResponse response = await _send(
      _client,
      uri,
      accept: accept,
      headers: headers,
    ).timeout(requestTimeout);
    return _readBody(response, uri).timeout(requestTimeout);
  }

  /// 发一个 GET，**不**自动跟重定向（抓页的重定向由 [_fetchFollowingRedirects] 逐跳校验）。
  Future<http.StreamedResponse> _send(
    http.Client client,
    Uri uri, {
    required String accept,
    Map<String, String> headers = const <String, String>{},
  }) {
    final http.Request request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['User-Agent'] = fushiUserAgent('web-search')
      ..headers['Accept'] = accept
      ..headers.addAll(headers);
    return client.send(request);
  }

  static bool _isRedirectStatus(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  Future<String> _readBody(http.StreamedResponse response, Uri uri) async {
    if (response.statusCode != 200) {
      unawaited(response.stream.drain<void>().catchError((Object _) {}));
      throw StateError('HTTP ${response.statusCode} for ${uri.host}');
    }
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in response.stream) {
      bytes.addAll(chunk);
      if (bytes.length > kWebSearchMaxResponseBytes) {
        throw StateError('response from ${uri.host} exceeds size cap');
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// 搜索结果页能不能抓（只看 URL 本身，不解析域名）：只要 http / https，拒绝 localhost /
/// `.local` / `.internal` 与非公网 IP 字面量（[isPublicWebSearchAddress]）。
bool isFetchableWebSearchUrl(Uri url) {
  if (url.scheme != 'https' && url.scheme != 'http') return false;
  final String host = url.host.toLowerCase();
  if (host.isEmpty || host == 'localhost' || host.endsWith('.localhost')) {
    return false;
  }
  if (host.endsWith('.local') || host.endsWith('.internal')) return false;
  final InternetAddress? ip = _ipLiteral(host);
  return ip == null || isPublicWebSearchAddress(ip);
}

/// [isFetchableWebSearchUrl] 再加域名解析：解析出的每个地址都得是公网地址（解析失败 /
/// 没有地址也拒）。抓页的每一跳都过它。
Future<bool> isFetchableWebSearchTarget(
  Uri url, {
  required WebSearchHostResolver resolve,
}) async {
  if (!isFetchableWebSearchUrl(url)) return false;
  if (_ipLiteral(url.host) != null) return true;
  final List<InternetAddress> addresses;
  try {
    addresses = await resolve(url.host);
  } on SocketException {
    return false;
  }
  return addresses.isNotEmpty && addresses.every(isPublicWebSearchAddress);
}

InternetAddress? _ipLiteral(String host) => InternetAddress.tryParse(
  host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host,
);

/// 地址是不是可以让不可信 URL 去连的公网单播地址。拒绝：未指定（`0.0.0.0/8`、`::`）、
/// 回环、私网（10/8、172.16/12、192.168/16）、CGNAT 100.64/10、链路本地、组播 /
/// 保留（≥ 224.0.0.0、`ff00::/8`）、IPv6 唯一本地 `fc00::/7`；IPv4-mapped IPv6
/// （`::ffff:a.b.c.d`）按其中的 IPv4 判，`::/96` 其余形式（`::`、`::1`、已废弃的
/// IPv4-compatible）一律拒。
bool isPublicWebSearchAddress(InternetAddress address) {
  final List<int> b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) return _isPublicIpv4(b);
  if (address.type != InternetAddressType.IPv6 || b.length != 16) return false;
  final bool zeroPrefix = b.sublist(0, 10).every((int x) => x == 0);
  if (zeroPrefix && b[10] == 0xff && b[11] == 0xff) {
    return _isPublicIpv4(b.sublist(12));
  }
  if (zeroPrefix && b[10] == 0 && b[11] == 0) return false;
  if (b[0] == 0xff) return false; // 组播
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return false; // fe80::/10
  if ((b[0] & 0xfe) == 0xfc) return false; // fc00::/7
  return true;
}

bool _isPublicIpv4(List<int> b) =>
    !(b[0] == 0 ||
        b[0] == 10 ||
        b[0] == 127 ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
        b[0] >= 224);

String _appProxyDirective(Uri url) => resolveAppProxyDirective(url);

/// 抓结果页用的 [HttpClient]：连接超时同 [createAppHttpClient]，但 `findProxy` 恒为
/// `DIRECT`——走不走代理由 [webSearchPinnedConnectionFactory] 自己按 [proxyDirective]
/// 决定并自己建隧道。交给 HTTP 栈去连代理的话，它会把**主机名**发给代理
/// （`CONNECT host:443` / `GET http://host/…`），代理那头重新解析，本机的地址校验就成了
/// 只管一次的前置检查。
HttpClient createWebSearchPageHttpClient({
  required WebSearchHostResolver resolveHost,
  required WebSearchProxyDirective proxyDirective,
}) => createAppHttpClient()
  ..findProxy = ((Uri _) => 'DIRECT')
  ..connectionFactory = webSearchPinnedConnectionFactory(
    resolveHost,
    proxyDirective: proxyDirective,
  );

/// 抓页客户端的建连函数：自己解析主机名、要求全部地址是公网地址，再**按校验过的地址**
/// 建连，解析与建连之间被 DNS rebinding 换地址也连不到内网。
///
/// * [proxyDirective] 给 `DIRECT`：直连那个 IP（https 用 [SecureSocket]，证书仍按原
///   主机名校验——lookup 出来的 [InternetAddress] 带着原主机名）；
/// * 给 `PROXY host:port`：连代理，发 `CONNECT <IP>:<端口>`（手填代理的 Basic 凭据照
///   应用代理设置带上），2xx 后 https 在隧道上按原主机名做 TLS，http 直接在隧道上发
///   请求。代理只拿到校验过的 IP。
///
/// 只能装在 `findProxy` 恒为 `DIRECT` 的客户端上（[createWebSearchPageHttpClient]）：
/// HTTP 栈要是自己选了代理（`proxyHost` 非 null），隧道会用主机名去建，这里直接拒。
Future<ConnectionTask<Socket>> Function(
  Uri url,
  String? proxyHost,
  int? proxyPort,
)
webSearchPinnedConnectionFactory(
  WebSearchHostResolver resolve, {
  WebSearchProxyDirective proxyDirective = _appProxyDirective,
}) => (Uri url, String? proxyHost, int? proxyPort) async {
  if (proxyHost != null) {
    throw StateError(
      'web search page client must use findProxy DIRECT; '
      'proxying is done by the pinned connection factory',
    );
  }
  final InternetAddress? literal = _ipLiteral(url.host);
  final List<InternetAddress> addresses = literal != null
      ? <InternetAddress>[literal]
      : await resolve(url.host);
  if (!isFetchableWebSearchUrl(url) ||
      addresses.isEmpty ||
      !addresses.every(isPublicWebSearchAddress)) {
    throw SocketException(
      'web search: refused connection to non-public address',
      address: addresses.isEmpty ? null : addresses.first,
    );
  }
  final InternetAddress target = addresses.first;
  final _WebSearchProxy? proxy = _parseProxyDirective(proxyDirective(url));
  if (proxy == null) {
    return url.scheme == 'https'
        ? SecureSocket.startConnect(target, url.port)
        : Socket.startConnect(target, url.port);
  }
  Socket? opened;
  bool cancelled = false;
  final Future<Socket> socket = _openPinnedProxyTunnel(
    proxy: proxy,
    target: target,
    url: url,
    onConnected: (Socket s) {
      opened = s;
      if (cancelled) s.destroy();
    },
  );
  return ConnectionTask.fromSocket(socket, () {
    cancelled = true;
    opened?.destroy();
  });
};

/// findProxy 指令里的一个代理。
class _WebSearchProxy {
  const _WebSearchProxy(this.host, this.port, this.credentials);

  final String host;
  final int port;
  final ({String username, String password})? credentials;
}

/// 指令 → 代理；第一条是 `DIRECT` → null。认不出的指令抛 [SocketException]（不悄悄
/// 改成直连：那会绕过用户的代理设置）。
_WebSearchProxy? _parseProxyDirective(String directive) {
  final String first = directive.split(';').first.trim();
  if (first.toUpperCase() == 'DIRECT') return null;
  if (!first.toUpperCase().startsWith('PROXY ')) {
    throw SocketException('web search: unsupported proxy directive "$first"');
  }
  String spec = first.substring('PROXY '.length).trim();
  ({String username, String password})? credentials;
  final int at = spec.lastIndexOf('@');
  if (at >= 0) {
    final String userInfo = spec.substring(0, at);
    spec = spec.substring(at + 1);
    final int sep = userInfo.indexOf(':');
    credentials = sep < 0
        ? (username: userInfo, password: '')
        : (
            username: userInfo.substring(0, sep),
            password: userInfo.substring(sep + 1),
          );
  }
  final int colon = spec.lastIndexOf(':');
  final int? port = colon < 0 ? null : int.tryParse(spec.substring(colon + 1));
  String host = colon < 0 ? spec : spec.substring(0, colon);
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  if (host.isEmpty || port == null || port < 1 || port > 65535) {
    throw SocketException('web search: bad proxy directive "$first"');
  }
  return _WebSearchProxy(
    host,
    port,
    credentials ?? appManualProxyBasicCredentials(host, port),
  );
}

/// 连 [proxy]，建一条到 [target]（已校验的 IP）的 `CONNECT` 隧道；https 在隧道上按
/// [url] 的主机名做 TLS（与 `dart:_http` 自己建代理隧道的做法一致）。
Future<Socket> _openPinnedProxyTunnel({
  required _WebSearchProxy proxy,
  required InternetAddress target,
  required Uri url,
  required void Function(Socket socket) onConnected,
}) async {
  final Socket socket = await Socket.connect(proxy.host, proxy.port);
  onConnected(socket);
  try {
    final String authority = target.type == InternetAddressType.IPv6
        ? '[${target.address}]:${url.port}'
        : '${target.address}:${url.port}';
    final StringBuffer request = StringBuffer()
      ..write('CONNECT $authority HTTP/1.1\r\n')
      ..write('Host: $authority\r\n');
    final ({String username, String password})? credentials = proxy.credentials;
    if (credentials != null) {
      final String token = base64Encode(
        utf8.encode('${credentials.username}:${credentials.password}'),
      );
      request.write('Proxy-Authorization: Basic $token\r\n');
    }
    request.write('\r\n');
    socket.add(utf8.encode(request.toString()));
    // 这条（已暂停的）订阅交给上层接着读隧道（[_TunneledSocket]；https 由 TLS 接管原
    // 连接），不能在这里 cancel：cancel 会关掉连接的读方向。连接由 HTTP 栈关。
    // ignore: cancel_subscriptions
    final StreamSubscription<Uint8List> subscription = await _awaitProxyTunnel(
      socket,
    );
    if (url.scheme == 'https') {
      return await SecureSocket.secure(socket, host: url.host);
    }
    return _TunneledSocket(socket, subscription);
  } catch (_) {
    socket.destroy();
    rethrow;
  }
}

/// 读代理对 `CONNECT` 的响应头：2xx → 暂停读并交回订阅（隧道里此后的字节归上层）；
/// 别的状态 / 头太长 / 头后面跟了多余字节（隧道没开就送数据，协议错）/ 连接断开 →
/// 抛 [SocketException]。
Future<StreamSubscription<Uint8List>> _awaitProxyTunnel(Socket socket) {
  final Completer<StreamSubscription<Uint8List>> done =
      Completer<StreamSubscription<Uint8List>>();
  final BytesBuilder header = BytesBuilder(copy: false);
  late final StreamSubscription<Uint8List> subscription;
  void fail(String message) {
    // 隧道没建成：这条连接作废（调用方随后 destroy），订阅不再交给任何人。
    unawaited(subscription.cancel());
    if (!done.isCompleted) done.completeError(SocketException(message));
  }

  subscription = socket.listen(
    (Uint8List chunk) {
      if (done.isCompleted) return;
      header.add(chunk);
      final Uint8List bytes = header.toBytes();
      final int end = _headerEnd(bytes);
      if (end < 0) {
        if (bytes.length > kWebSearchMaxProxyResponseHeaderBytes) {
          fail('web search: proxy tunnel response header too large');
        }
        return;
      }
      if (end != bytes.length) {
        fail('web search: proxy sent data before the tunnel was established');
        return;
      }
      final String text = latin1.decode(bytes);
      final String statusLine = text.substring(0, text.indexOf('\r\n'));
      final RegExpMatch? m = RegExp(
        r'^HTTP/1\.[01] (\d{3})',
      ).firstMatch(statusLine);
      final int status = m == null ? 0 : int.parse(m.group(1)!);
      if (status < 200 || status > 299) {
        fail('web search: proxy refused tunnel ($statusLine)');
        return;
      }
      subscription.pause();
      done.complete(subscription);
    },
    onError: (Object error, StackTrace stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    },
    onDone: () {
      if (!done.isCompleted) {
        done.completeError(
          const SocketException(
            'web search: proxy closed the connection before the tunnel opened',
          ),
        );
      }
    },
  );
  return done.future;
}

/// 响应头结束（`\r\n\r\n` 之后）的下标；没有 → -1。
int _headerEnd(Uint8List bytes) {
  for (int i = 3; i < bytes.length; i++) {
    if (bytes[i] == 10 &&
        bytes[i - 1] == 13 &&
        bytes[i - 2] == 10 &&
        bytes[i - 3] == 13) {
      return i + 1;
    }
  }
  return -1;
}

/// 明文 http 走代理隧道时交给 HTTP 栈的 [Socket]：读侧接着用读隧道响应时那个（已暂停
/// 的）订阅——[Socket] 是单订阅流，读过响应头就不能再 `listen` 一次；写侧与选项原样
/// 委托给底下的连接。（https 不需要它：[SecureSocket.secure] 直接接管原连接。）
final class _TunneledSocket extends Stream<Uint8List> implements Socket {
  _TunneledSocket(this._inner, this._subscription);

  final Socket _inner;
  StreamSubscription<Uint8List>? _subscription;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final StreamSubscription<Uint8List>? subscription = _subscription;
    if (subscription == null) {
      throw StateError('Stream has already been listened to.');
    }
    _subscription = null;
    subscription
      ..onData(onData)
      ..onError((Object error, StackTrace stack) {
        if (cancelOnError ?? false) unawaited(subscription.cancel());
        if (onError is void Function(Object, StackTrace)) {
          onError(error, stack);
        } else if (onError is void Function(Object)) {
          onError(error);
        } else {
          Zone.current.handleUncaughtError(error, stack);
        }
      })
      ..onDone(onDone)
      ..resume();
    return subscription;
  }

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> flush() => _inner.flush();

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);

  @override
  InternetAddress get address => _inner.address;

  @override
  int get port => _inner.port;

  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;

  @override
  int get remotePort => _inner.remotePort;

  @override
  void destroy() => _inner.destroy();

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);
}

/// SearXNG `format=json` → 结果。坏 JSON 抛 [FormatException]。
List<WebSearchHit> parseSearxngResults(String body) {
  final Object? decoded = jsonDecode(body);
  final Object? results = decoded is Map ? decoded['results'] : null;
  if (results is! List) return const <WebSearchHit>[];
  return <WebSearchHit>[
    for (final Object? r in results)
      if (r is Map) ?_hit(r['title'], r['url'], r['content']),
  ];
}

/// Brave `web/search` → 结果。坏 JSON 抛 [FormatException]。
List<WebSearchHit> parseBraveResults(String body) {
  final Object? decoded = jsonDecode(body);
  final Object? web = decoded is Map ? decoded['web'] : null;
  final Object? results = web is Map ? web['results'] : null;
  if (results is! List) return const <WebSearchHit>[];
  return <WebSearchHit>[
    for (final Object? r in results)
      if (r is Map) ?_hit(r['title'], r['url'], r['description']),
  ];
}

WebSearchHit? _hit(Object? title, Object? url, Object? snippet) {
  if (url is! String) return null;
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  return WebSearchHit(
    title: title is String ? webKnowledgeHtmlToText(title).trim() : '',
    url: uri,
    snippet: snippet is String ? webKnowledgeHtmlToText(snippet).trim() : '',
  );
}
