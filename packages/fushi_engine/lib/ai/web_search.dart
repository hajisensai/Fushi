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
/// 出站一律经 `createAppHttpIoClient()`（应用代理 + 连接超时）。抓结果页时只接受
/// http / https、拒绝本机与内网地址（搜索结果是不可信输入，不能让它把请求引到局域网）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show InternetAddress, InternetAddressType;

import 'package:fushi_engine/ai/web_knowledge.dart' show webKnowledgeHtmlToText;
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';
import 'package:http/http.dart' as http;

/// 单个响应体（搜索 JSON / 结果页 HTML）的字节上限。
const int kWebSearchMaxResponseBytes = 4 * 1024 * 1024;

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

  /// 偏好 / 配置文件里的 JSON（`{"kind":"searxng","endpoint":"…","apiKey":"…"}`）。
  /// 坏 JSON / 未知后端 → null。
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

  static WebSearchConfig? fromJson(Map<String, Object?> json) {
    final WebSearchKind? kind = WebSearchKind.fromName(json['kind']);
    if (kind == null) return null;
    final Object? endpoint = json['endpoint'];
    final Object? apiKey = json['apiKey'];
    return WebSearchConfig(
      kind: kind,
      endpoint: endpoint is String && endpoint.trim().isNotEmpty
          ? endpoint.trim()
          : null,
      apiKey: apiKey is String && apiKey.trim().isNotEmpty
          ? apiKey.trim()
          : null,
    );
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

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    if (endpoint != null) 'endpoint': endpoint,
    if (apiKey != null) 'apiKey': apiKey,
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
  WebSearchClient({
    required this.config,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null;

  final WebSearchConfig config;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;

  bool get isEnabled => config.isUsable;

  void close() {
    if (_ownsClient) _client.close();
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

  /// 取 [url] 的正文（HTML 剥成文本，截到 [maxChars]）。不安全的地址 / 失败 → null。
  Future<WebSearchPage?> fetchPage(
    Uri url, {
    String title = '',
    int maxChars = 20000,
  }) async {
    if (!isFetchableWebSearchUrl(url)) return null;
    try {
      final String body = await _get(
        url,
        accept: 'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5',
        followRedirects: true,
      );
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
    bool followRedirects = false,
  }) => _read(uri, accept, headers, followRedirects).timeout(requestTimeout);

  Future<String> _read(
    Uri uri,
    String accept,
    Map<String, String> headers,
    bool followRedirects,
  ) async {
    final http.Request request = http.Request('GET', uri)
      ..followRedirects = followRedirects
      ..maxRedirects = 5
      ..headers['User-Agent'] = fushiUserAgent('web-search')
      ..headers['Accept'] = accept
      ..headers.addAll(headers);
    final http.StreamedResponse response = await _client.send(request);
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

/// 搜索结果页能不能抓：只要 http / https，拒绝 localhost 与内网 / 链路本地 IP 字面量。
bool isFetchableWebSearchUrl(Uri url) {
  if (url.scheme != 'https' && url.scheme != 'http') return false;
  final String host = url.host.toLowerCase();
  if (host.isEmpty || host == 'localhost' || host.endsWith('.localhost')) {
    return false;
  }
  if (host.endsWith('.local') || host.endsWith('.internal')) return false;
  final InternetAddress? ip = InternetAddress.tryParse(
    host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host,
  );
  if (ip == null) return true;
  if (ip.isLoopback || ip.isLinkLocal) return false;
  final List<int> b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return !(b[0] == 10 ||
        b[0] == 0 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127));
  }
  // IPv6 唯一本地地址 fc00::/7。
  return (b[0] & 0xfe) != 0xfc;
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
