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
/// * 直连时按已校验的地址建连（[webSearchPinnedConnectionFactory]），解析与建连之间被
///   DNS rebinding 换成内网地址也连不过去。走应用代理时 DNS 在代理那头解析，本机只能做
///   解析前置校验。
///
/// SearXNG 实例地址是用户自己配的（常是局域网自建），搜索请求不受这套限制。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/ai/web_knowledge.dart' show webKnowledgeHtmlToText;
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 单个响应体（搜索 JSON / 结果页 HTML）的字节上限。
const int kWebSearchMaxResponseBytes = 4 * 1024 * 1024;

/// 抓结果页时最多跟几跳重定向。
const int kWebSearchMaxRedirects = 5;

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
  /// 另建一个按已校验地址建连的客户端（见库注释）。[resolveHost] 是抓页前校验主机名
  /// 用的解析器。
  WebSearchClient({
    required this.config,
    http.Client? client,
    http.Client? pageClient,
    WebSearchHostResolver? resolveHost,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null,
       _resolveHost = resolveHost ?? _systemLookup,
       _pageClient =
           pageClient ??
           client ??
           IOClient(
             createAppHttpClient()
               ..connectionFactory = webSearchPinnedConnectionFactory(
                 resolveHost ?? _systemLookup,
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

/// 抓页客户端的建连函数：直连时自己解析主机名、要求全部地址是公网地址，再**按校验过
/// 的地址**建连（https 用 [SecureSocket]，证书仍按原主机名校验），解析与建连之间被
/// DNS rebinding 换地址也连不到内网。走代理（`proxyHost` 非 null）时连代理本身。
Future<ConnectionTask<Socket>> Function(
  Uri url,
  String? proxyHost,
  int? proxyPort,
)
webSearchPinnedConnectionFactory(WebSearchHostResolver resolve) =>
    (Uri url, String? proxyHost, int? proxyPort) async {
      if (proxyHost != null && proxyPort != null) {
        return Socket.startConnect(proxyHost, proxyPort);
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
      return url.scheme == 'https'
          ? SecureSocket.startConnect(target, url.port)
          : Socket.startConnect(target, url.port);
    };

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
