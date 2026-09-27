/// AI 联网资料：app **自己**去固定来源抓条目正文，再交给 AI 当上下文。
///
/// 为什么不让 AI 提供商自己联网：大多数用户自配的端点（OpenAI 兼容 / 本地模型）
/// 根本没有联网工具，有的也各家开关不同；让 app 抓、AI 只读抓回来的文本，行为就
/// 与提供商无关，且 AI 能引用的内容边界是确定的（列出的作品下游还会逐部核对）。
///
/// 来源是 MediaWiki API（无需 key）：先 `list=search` 拿标题，再逐条
/// `prop=extracts&explaintext=1` 拿纯文本正文。
///
/// 中文站**不传 `variant`**：TextExtracts 是否按 `variant` 做繁简转换没有可靠依据，
/// 不猜——正文可能繁简混排，交给 AI 读不影响理解。
///
/// 出站一律经 `createAppHttpIoClient()`（应用代理 + 连接超时，裸 client 会被
/// `outbound_http_discipline_guard_test` 判红）；UA 走 `fushiUserAgent`，维基百科
/// 要求描述性 UA，缺了会被限流/拒绝。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';
import 'package:http/http.dart' as http;

/// 单个 API 响应体的字节上限。extracts 全文最长的条目也就几百 KB；超过它说明
/// 对端返回了异常内容，直接放弃这一条，不把整块读进内存。
const int kWebKnowledgeMaxResponseBytes = 4 * 1024 * 1024;

/// 内置联网资料来源。
enum WebKnowledgeSource {
  wikipediaZh('wikipedia_zh', 'zh'),
  wikipediaJa('wikipedia_ja', 'ja'),
  wikipediaEn('wikipedia_en', 'en');

  const WebKnowledgeSource(this.storageKey, this.languageCode);

  /// 持久化用的稳定键（偏好里逗号分隔存这些）。
  final String storageKey;

  /// 维基百科子站语言码，也是 host 前缀。
  final String languageCode;

  String get _host => '$languageCode.wikipedia.org';

  static WebKnowledgeSource? fromStorageKey(String? raw) {
    if (raw == null) return null;
    final String key = raw.trim();
    for (final WebKnowledgeSource source in values) {
      if (source.storageKey == key) return source;
    }
    return null;
  }
}

/// 解析偏好值 `ai_web_knowledge_sources`。
///
/// [raw] 为 null = 从未写过 → 默认全开；`''` = 用户全关。未知键静默丢弃
/// （旧版本 / 新版本来源增删时跨设备同步过来的值不能让读取失败）。
Set<WebKnowledgeSource> parseWebKnowledgeSources(String? raw) {
  if (raw == null) return WebKnowledgeSource.values.toSet();
  return raw
      .split(',')
      .map(WebKnowledgeSource.fromStorageKey)
      .whereType<WebKnowledgeSource>()
      .toSet();
}

/// [parseWebKnowledgeSources] 的逆：按枚举声明顺序输出，写出的值稳定可比较。
String encodeWebKnowledgeSources(Set<WebKnowledgeSource> sources) =>
    WebKnowledgeSource.values
        .where(sources.contains)
        .map((WebKnowledgeSource s) => s.storageKey)
        .join(',');

class WebKnowledgePage {
  const WebKnowledgePage({
    required this.source,
    required this.title,
    required this.url,
    required this.text,
  });

  final WebKnowledgeSource source;
  final String title;
  final Uri url;

  /// 纯文本正文（已截断）。
  final String text;

  @override
  String toString() => 'WebKnowledgePage(${source.storageKey}, $title)';
}

/// 按启用来源抓资料的客户端。[client] 可注入，测试用 MockClient 不打真网。
class WebKnowledgeClient {
  WebKnowledgeClient({
    required Set<WebKnowledgeSource> sources,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _sources = Set<WebKnowledgeSource>.unmodifiable(sources),
       _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null;

  final Set<WebKnowledgeSource> _sources;
  final http.Client _client;
  final bool _ownsClient;

  Set<WebKnowledgeSource> get sources => _sources;

  bool get isEnabled => _sources.isNotEmpty;

  /// 在每个启用的来源里搜 [query]，取前 [pagesPerSource] 个条目的纯文本正文，每页截断到 [maxCharsPerPage]。
  /// 任何来源失败只记诊断日志（ErrorLogService.instance.logDiagnostic）并跳过，不抛。
  ///
  /// 来源之间并行、来源内逐页串行（对单站点保持礼貌的并发度）；结果按枚举声明
  /// 顺序排列，与网络返回先后无关。
  Future<List<WebKnowledgePage>> search(
    String query, {
    int pagesPerSource = 1,
    int maxCharsPerPage = 12000,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty || pagesPerSource <= 0 || maxCharsPerPage <= 0) {
      return const <WebKnowledgePage>[];
    }
    final List<WebKnowledgeSource> ordered = WebKnowledgeSource.values
        .where(_sources.contains)
        .toList();
    final List<List<WebKnowledgePage>> perSource =
        await Future.wait<List<WebKnowledgePage>>(
          <Future<List<WebKnowledgePage>>>[
            for (final WebKnowledgeSource source in ordered)
              _searchSource(source, trimmed, pagesPerSource, maxCharsPerPage),
          ],
        );
    return <WebKnowledgePage>[
      for (final List<WebKnowledgePage> pages in perSource) ...pages,
    ];
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<List<WebKnowledgePage>> _searchSource(
    WebKnowledgeSource source,
    String query,
    int limit,
    int maxChars,
  ) async {
    final List<WebKnowledgePage> pages = <WebKnowledgePage>[];
    try {
      final List<String> titles = await _searchTitles(source, query, limit);
      for (final String title in titles) {
        final WebKnowledgePage? page = await _fetchPage(
          source,
          title,
          maxChars,
        );
        if (page != null) pages.add(page);
      }
    } catch (error, stack) {
      // 已抓到的页照样返回：一条正文失败不该连累同来源前面成功的。
      ErrorLogService.instance.logDiagnostic(
        'WebKnowledgeClient.${source.storageKey}',
        '$query: $error\n$stack',
      );
    }
    return pages;
  }

  Future<List<String>> _searchTitles(
    WebKnowledgeSource source,
    String query,
    int limit,
  ) async {
    final Object? json = await _getJson(
      Uri.https(source._host, '/w/api.php', <String, String>{
        'action': 'query',
        'format': 'json',
        'formatversion': '2',
        'list': 'search',
        'srsearch': query,
        'srlimit': '$limit',
        // 只要标题：片段/字数等字段不用，省流量。
        'srprop': '',
      }),
    );
    final Object? hits = _path(json, <String>['query', 'search']);
    if (hits is! List) return const <String>[];
    return <String>[
      for (final Object? hit in hits)
        if (hit is Map && hit['title'] is String) hit['title'] as String,
    ].take(limit).toList();
  }

  Future<WebKnowledgePage?> _fetchPage(
    WebKnowledgeSource source,
    String title,
    int maxChars,
  ) async {
    final Object? json = await _getJson(
      Uri.https(source._host, '/w/api.php', <String, String>{
        'action': 'query',
        'format': 'json',
        'formatversion': '2',
        'prop': 'extracts',
        'explaintext': '1',
        'redirects': '1',
        'titles': title,
      }),
    );
    final Object? pages = _path(json, <String>['query', 'pages']);
    if (pages is! List || pages.isEmpty) return null;
    final Object? page = pages.first;
    if (page is! Map) return null;
    final Object? extract = page['extract'];
    if (extract is! String || extract.trim().isEmpty) return null;
    // redirects=1 时返回的是目标页标题，URL 也以它为准。
    final String resolved = page['title'] is String
        ? page['title'] as String
        : title;
    return WebKnowledgePage(
      source: source,
      title: resolved,
      url: webKnowledgePageUrl(source, resolved),
      text: _truncate(extract.trim(), maxChars),
    );
  }

  /// 单个请求（连接 + 读完响应体）的总时限。app client 只管连接超时；连上后对方
  /// 迟迟不发完，没有这一道就会把作品识别 / 整套下载一起挂住。超时按这个来源失败
  /// 处理（记诊断、跳过），与其它失败同一条路。
  final Duration requestTimeout;

  Future<Object?> _getJson(Uri uri) => _readJson(uri).timeout(requestTimeout);

  Future<Object?> _readJson(Uri uri) async {
    final http.Request request = http.Request('GET', uri)
      ..headers['User-Agent'] = fushiUserAgent('web-knowledge')
      ..headers['Accept'] = 'application/json';
    final http.StreamedResponse response = await _client.send(request);
    if (response.statusCode != 200) {
      // 排空连接，别让 keep-alive 连接挂着一个没读完的响应体。
      unawaited(response.stream.drain<void>().catchError((Object _) {}));
      throw StateError('HTTP ${response.statusCode} for ${uri.host}');
    }
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in response.stream) {
      bytes.addAll(chunk);
      if (bytes.length > kWebKnowledgeMaxResponseBytes) {
        throw StateError('response from ${uri.host} exceeds size cap');
      }
    }
    return jsonDecode(utf8.decode(bytes));
  }
}

/// 条目页面 URL：`https://{lang}.wikipedia.org/wiki/<标题>`，空格按维基惯例写成 `_`。
Uri webKnowledgePageUrl(WebKnowledgeSource source, String title) =>
    Uri.https(source._host, '/wiki/${title.replaceAll(' ', '_')}');

Object? _path(Object? json, List<String> keys) {
  Object? node = json;
  for (final String key in keys) {
    if (node is! Map) return null;
    node = node[key];
  }
  return node;
}

/// 按 UTF-16 码元截断，但不把代理对劈成两半（劈开的孤儿码元进 JSON 会变乱码）。
String _truncate(String text, int maxChars) {
  if (text.length <= maxChars) return text;
  int end = maxChars;
  final int last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return text.substring(0, end);
}
