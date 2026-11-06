import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/utils/net/app_http.dart' show createAppHttpClient;

import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/web_browser/data/web_browser_store.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';

/// 地址栏联想一条的来源。
enum WebBrowserSuggestionKind { bookmark, history, search }

/// 地址栏联想的一条。`bookmark` / `history` 有 [url]（点了直接打开）；
/// `search` 只有 [query]（点了交给当前搜索引擎）。
@immutable
class WebBrowserSuggestion {
  const WebBrowserSuggestion.page({
    required this.kind,
    required this.title,
    required Uri this.url,
  }) : query = null;

  const WebBrowserSuggestion.search(String this.query)
    : kind = WebBrowserSuggestionKind.search,
      title = query,
      url = null;

  final WebBrowserSuggestionKind kind;
  final String title;
  final Uri? url;
  final String? query;

  @override
  bool operator ==(Object other) =>
      other is WebBrowserSuggestion &&
      other.kind == kind &&
      other.title == title &&
      other.url == url &&
      other.query == query;

  @override
  int get hashCode => Object.hash(kind, title, url, query);

  @override
  String toString() => 'WebBrowserSuggestion($kind, $title, ${url ?? query})';
}

/// 网址去掉协议与 `www.` 后再归一化：输入 `github.com/f` 能前缀命中
/// `https://www.github.com/foo`。
String _normalizedUrlText(Uri url) {
  String text = url.toString();
  text = text.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
  text = text.replaceFirst(RegExp(r'^www\.', caseSensitive: false), '');
  return normalizeMediaSearchText(text);
}

/// 本地联想排序（纯函数）：在书签与历史里按标题 / 网址做前缀或包含匹配。
///
/// 排序键依次：书签优先 → 前缀命中优先于包含 → 访问次数多 → 最近访问 →
/// 标题字典序。同一网址只出一条（书签那条胜出，访问次数取历史里的）。
/// 空输入返回空表。
List<WebBrowserSuggestion> rankWebBrowserLocalSuggestions({
  required String input,
  required List<WebBrowserBookmark> bookmarks,
  required List<WebBrowserHistoryEntry> history,
  int limit = 6,
}) {
  final String needle = normalizeMediaSearchText(
    input.trim().replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), ''),
  ).replaceFirst(RegExp('^www'), '');
  if (needle.isEmpty || limit <= 0) return const <WebBrowserSuggestion>[];

  final Map<String, WebBrowserHistoryEntry> historyByUrl =
      <String, WebBrowserHistoryEntry>{
        for (final WebBrowserHistoryEntry e in history) e.url.toString(): e,
      };

  final Map<String, _Candidate> byUrl = <String, _Candidate>{};

  int? matchRank(String title, Uri url) {
    final String t = normalizeMediaSearchText(title);
    final String u = _normalizedUrlText(url);
    if (t.startsWith(needle) || u.startsWith(needle)) return 0;
    if (t.contains(needle) || u.contains(needle)) return 1;
    return null;
  }

  for (final WebBrowserBookmark b in bookmarks) {
    final Uri? url = b.url;
    if (url == null) continue;
    final int? rank = matchRank(b.title, url);
    if (rank == null) continue;
    final WebBrowserHistoryEntry? h = historyByUrl[url.toString()];
    final _Candidate candidate = _Candidate(
      kind: WebBrowserSuggestionKind.bookmark,
      title: b.title.trim().isEmpty ? (h?.title ?? url.host) : b.title,
      url: url,
      matchRank: rank,
      visitCount: h?.visitCount ?? 0,
      lastVisitedAt: h?.lastVisitedAt,
    );
    final _Candidate? existing = byUrl[url.toString()];
    if (existing == null || candidate.compareTo(existing) < 0) {
      byUrl[url.toString()] = candidate;
    }
  }
  for (final WebBrowserHistoryEntry h in history) {
    final String key = h.url.toString();
    if (byUrl.containsKey(key)) continue;
    final int? rank = matchRank(h.title, h.url);
    if (rank == null) continue;
    byUrl[key] = _Candidate(
      kind: WebBrowserSuggestionKind.history,
      title: h.title.trim().isEmpty ? h.url.host : h.title,
      url: h.url,
      matchRank: rank,
      visitCount: h.visitCount,
      lastVisitedAt: h.lastVisitedAt,
    );
  }
  final List<_Candidate> sorted = byUrl.values.toList()..sort();
  return List<WebBrowserSuggestion>.unmodifiable(<WebBrowserSuggestion>[
    for (final _Candidate c in sorted.take(limit))
      WebBrowserSuggestion.page(kind: c.kind, title: c.title, url: c.url),
  ]);
}

class _Candidate implements Comparable<_Candidate> {
  _Candidate({
    required this.kind,
    required this.title,
    required this.url,
    required this.matchRank,
    required this.visitCount,
    required this.lastVisitedAt,
  });

  final WebBrowserSuggestionKind kind;
  final String title;
  final Uri url;
  final int matchRank;
  final int visitCount;
  final DateTime? lastVisitedAt;

  @override
  int compareTo(_Candidate other) {
    final int byKind =
        (kind == WebBrowserSuggestionKind.bookmark ? 0 : 1) -
        (other.kind == WebBrowserSuggestionKind.bookmark ? 0 : 1);
    if (byKind != 0) return byKind;
    final int byMatch = matchRank - other.matchRank;
    if (byMatch != 0) return byMatch;
    final int byVisits = other.visitCount - visitCount;
    if (byVisits != 0) return byVisits;
    final int a = lastVisitedAt?.millisecondsSinceEpoch ?? 0;
    final int b = other.lastVisitedAt?.millisecondsSinceEpoch ?? 0;
    if (a != b) return b.compareTo(a);
    return title.compareTo(other.title);
  }
}

/// 解析 OpenSearch 联想 JSON `["q", ["s1", "s2"], ...]`；格式不对返回空表。
List<String> parseOpenSearchSuggestions(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return const <String>[];
  }
  if (decoded is! List || decoded.length < 2 || decoded[1] is! List) {
    return const <String>[];
  }
  return List<String>.unmodifiable(<String>[
    for (final Object? item in decoded[1] as List<Object?>)
      if (item is String && item.trim().isNotEmpty) item.trim(),
  ]);
}

/// 合并本地联想与在线联想（纯函数）：本地在前；在线去掉与输入相同的词和重复词，
/// 最多 [remoteLimit] 条。
List<WebBrowserSuggestion> mergeWebBrowserSuggestions({
  required String input,
  required List<WebBrowserSuggestion> local,
  required List<String> remote,
  int remoteLimit = 6,
}) {
  final String typed = input.trim();
  final Set<String> seen = <String>{typed};
  final List<WebBrowserSuggestion> searches = <WebBrowserSuggestion>[];
  for (final String q in remote) {
    if (searches.length >= remoteLimit) break;
    if (seen.add(q)) searches.add(WebBrowserSuggestion.search(q));
  }
  return List<WebBrowserSuggestion>.unmodifiable(<WebBrowserSuggestion>[
    ...local,
    ...searches,
  ]);
}

/// 拉一次在线联想：返回联想词列表。失败由调用方吞掉。
typedef WebBrowserSuggestFetcher = Future<List<String>> Function(Uri url);

/// 地址栏联想数据源。A1 的地址栏用法：
///
/// ```dart
/// final c = WebBrowserSuggestionsController(
///   store: store,
///   provider: () => readWebBrowserSearchProvider(prefs),
/// );
/// c.suggestions.listen(render); // 每次 update 后先推本地，再推本地+在线
/// c.update(text);               // 每次输入变化调用；空串 = 清空
/// c.dispose();
/// ```
///
/// - 本地联想（历史 + 书签）随输入立即推出；
/// - 在线联想防抖 [debounce] 后才发请求，新输入会作废旧请求（旧结果不再推送，
///   在途请求被 abort）；
/// - 在线失败 / 超时 / 解析失败静默，只保留本地结果；
/// - [onlineEnabled] 返回 false（如无痕标签页或用户关了联想）时不发任何请求。
class WebBrowserSuggestionsController {
  WebBrowserSuggestionsController({
    required WebBrowserStore store,
    required WebBrowserSearchProvider Function() provider,
    bool Function()? onlineEnabled,
    WebBrowserSuggestFetcher? fetcher,
    this.debounce = const Duration(milliseconds: 250),
    this.localLimit = 6,
    this.remoteLimit = 6,
  }) : _store = store,
       _provider = provider,
       _onlineEnabled = onlineEnabled ?? _always,
       _fetcher = fetcher;

  static bool _always() => true;

  final WebBrowserStore _store;
  final WebBrowserSearchProvider Function() _provider;
  final bool Function() _onlineEnabled;
  final WebBrowserSuggestFetcher? _fetcher;
  final Duration debounce;
  final int localLimit;
  final int remoteLimit;

  final StreamController<List<WebBrowserSuggestion>> _controller =
      StreamController<List<WebBrowserSuggestion>>.broadcast();
  Timer? _debounceTimer;
  HttpClient? _http;
  HttpClientRequest? _inflight;
  int _generation = 0;
  bool _disposed = false;
  List<WebBrowserSuggestion> _current = const <WebBrowserSuggestion>[];

  Stream<List<WebBrowserSuggestion>> get suggestions => _controller.stream;

  /// 最近一次推送的结果。
  List<WebBrowserSuggestion> get current => _current;

  void _emit(int generation, List<WebBrowserSuggestion> value) {
    if (_disposed || generation != _generation) return;
    _current = value;
    _controller.add(value);
  }

  /// 输入变化。返回的 Future 在本地结果推出后完成（测试用；UI 可忽略）。
  Future<void> update(String input) async {
    final int generation = ++_generation;
    _debounceTimer?.cancel();
    _abortInflight();
    final String text = input.trim();
    if (text.isEmpty) {
      _emit(generation, const <WebBrowserSuggestion>[]);
      return;
    }
    final List<WebBrowserSuggestion> local = await _local(text);
    _emit(generation, local);
    if (generation != _generation || !_onlineEnabled()) return;
    final Uri? url = _provider().suggestUrl(text);
    if (url == null) return;
    _debounceTimer = Timer(debounce, () async {
      if (generation != _generation) return;
      List<String> remote;
      try {
        remote = await (_fetcher ?? _fetchOpenSearch)(url);
      } on Object {
        return;
      }
      _emit(
        generation,
        mergeWebBrowserSuggestions(
          input: text,
          local: local,
          remote: remote,
          remoteLimit: remoteLimit,
        ),
      );
    });
  }

  Future<List<WebBrowserSuggestion>> _local(String text) async {
    try {
      final List<WebBrowserBookmark> bookmarks = await _store.allBookmarks();
      final List<WebBrowserHistoryEntry> history = await _store.history(
        query: text,
        limit: 100,
      );
      return rankWebBrowserLocalSuggestions(
        input: text,
        bookmarks: bookmarks,
        history: history,
        limit: localLimit,
      );
    } on Object {
      return const <WebBrowserSuggestion>[];
    }
  }

  Future<List<String>> _fetchOpenSearch(Uri url) async {
    final HttpClient http = _http ??= createAppHttpClient(
      connectionTimeout: const Duration(seconds: 5),
    );
    final HttpClientRequest request = await http.getUrl(url);
    _inflight = request;
    try {
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return const <String>[];
      }
      final String body = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 5));
      return parseOpenSearchSuggestions(body);
    } finally {
      if (identical(_inflight, request)) _inflight = null;
    }
  }

  void _abortInflight() {
    final HttpClientRequest? request = _inflight;
    _inflight = null;
    request?.abort();
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _debounceTimer?.cancel();
    _abortInflight();
    _http?.close(force: true);
    _http = null;
    unawaited(_controller.close());
  }
}
