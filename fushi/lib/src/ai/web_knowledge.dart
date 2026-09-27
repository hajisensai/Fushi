/// AI 联网资料：app **自己**去用户启用的资料站抓条目正文，再交给 AI 当上下文。
///
/// 为什么不让 AI 提供商自己联网：大多数用户自配的端点（OpenAI 兼容 / 本地模型）
/// 根本没有联网工具，有的也各家开关不同；让 app 抓、AI 只读抓回来的文本，行为就
/// 与提供商无关，且 AI 能引用的内容边界是确定的（列出的作品下游还会逐部核对）。
///
/// 站点按 [WebKnowledgeSiteKind] 分三种抓法，每种一个私有 fetcher，[WebKnowledgeClient]
/// 只按 kind 分派一次：
/// * MediaWiki（维基百科 / 萌娘百科 / 用户自加的 Fandom 等）：`action=opensearch`
///   拿标题 → `prop=extracts&explaintext=1` 拿纯文本；站点没装 TextExtracts
///   （页面在但没有 `extract`）时退到 `action=parse` 取 HTML 再剥成文本。
///   不用 `list=search`：萌娘百科对它返回 `action-notallowed`，opensearch 两边都通。
/// * Anime News Network 百科：`api.xml?anime=~<名>` 一次返回全部同名作品，拼成**一页**
///   逐行清单（类型 / 标题 / 年份 / ANN id）。ANN 要求每 IP ≤1 请求/秒，进程内串行
///   并保持 1 秒间隔。
/// * TVmaze：`/search/shows?q=` 同样拼成一页清单。
///
/// 中文维基**不传 `variant`**：TextExtracts 是否按 `variant` 做繁简转换没有可靠依据，
/// 不猜——正文可能繁简混排，交给 AI 读不影响理解。
///
/// 出站一律经 `createAppHttpIoClient()`（应用代理 + 连接超时，裸 client 会被
/// `outbound_http_discipline_guard_test` 判红）；UA 走 `fushiUserAgent`，维基百科
/// 要求描述性 UA，缺了会被限流/拒绝。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// 单个 API 响应体的字节上限。extracts 全文最长的条目也就几百 KB；超过它说明
/// 对端返回了异常内容，直接放弃这一条，不把整块读进内存。
const int kWebKnowledgeMaxResponseBytes = 4 * 1024 * 1024;

/// 清单页（ANN / TVmaze）最多列几部、前几部附简介：长寿系列上百条，全列只会
/// 把正文截断在中间，简介也只对排在前面的有意义。
const int kWebKnowledgeListMaxEntries = 60;
const int kWebKnowledgeListSummaryEntries = 5;
const int kWebKnowledgeListSummaryChars = 300;

/// 站点的抓取方式。
enum WebKnowledgeSiteKind { mediaWiki, animeNewsNetwork, tvMaze }

/// 一个资料站。内置站 id 固定（也是偏好里存的值）；自定义站 id 形如 `custom:<…>`，
/// 只允许 MediaWiki。
class WebKnowledgeSite {
  const WebKnowledgeSite({
    required this.id,
    required this.kind,
    required this.label,
    this.endpoint,
    this.builtin = false,
  });

  /// 自定义 MediaWiki 站点；[endpoint] 不合规（见 [validateWebKnowledgeEndpoint]）、
  /// id 不是 `custom:` 前缀时返回 null。label 空则用 host。
  static WebKnowledgeSite? custom({
    required String id,
    required String label,
    required String endpoint,
  }) {
    final Uri? uri = validateWebKnowledgeEndpoint(endpoint);
    if (uri == null || !_customIdPattern.hasMatch(id)) return null;
    final String name = label.trim();
    return WebKnowledgeSite(
      id: id,
      kind: WebKnowledgeSiteKind.mediaWiki,
      label: name.isEmpty ? uri.host : name,
      endpoint: uri,
    );
  }

  final String id;
  final WebKnowledgeSiteKind kind;

  /// 内置站的界面文案走 i18n（按 id 取）；这里是稳定的英文兜底。
  final String label;

  /// MediaWiki 的 `api.php` 地址；另两种 kind 的端点是固定的，不需要。
  final Uri? endpoint;
  final bool builtin;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    'endpoint': endpoint?.toString(),
  };

  @override
  bool operator ==(Object other) =>
      other is WebKnowledgeSite &&
      other.id == id &&
      other.kind == kind &&
      other.label == label &&
      other.endpoint == endpoint &&
      other.builtin == builtin;

  @override
  int get hashCode => Object.hash(id, kind, label, endpoint, builtin);

  @override
  String toString() => 'WebKnowledgeSite($id)';
}

const String kWebKnowledgeCustomIdPrefix = 'custom:';

/// 自定义站 id 的合法形态：`custom:` + 字母数字 `_-`。id 进启用 / 关闭列表的
/// CSV，带 `,` 的 id（同步来的或手改的 JSON）会把那份 CSV 拆坏。
final RegExp _customIdPattern = RegExp(r'^custom:[A-Za-z0-9_-]+$');

/// 只有三个维基时的旧偏好里可能出现的 id（迁移用）。
const Set<String> kLegacyWebKnowledgeSiteIds = <String>{
  'wikipedia_zh',
  'wikipedia_ja',
  'wikipedia_en',
};

/// 内置站。顺序即默认检索 / 结果排列顺序；id 与旧版 `WebKnowledgeSource.storageKey`
/// 逐字相同，已存的偏好值不用迁移。
final List<WebKnowledgeSite> kBuiltinWebKnowledgeSites = <WebKnowledgeSite>[
  WebKnowledgeSite(
    id: 'wikipedia_zh',
    kind: WebKnowledgeSiteKind.mediaWiki,
    label: 'Wikipedia (中文)',
    endpoint: Uri.parse('https://zh.wikipedia.org/w/api.php'),
    builtin: true,
  ),
  WebKnowledgeSite(
    id: 'wikipedia_ja',
    kind: WebKnowledgeSiteKind.mediaWiki,
    label: 'Wikipedia (日本語)',
    endpoint: Uri.parse('https://ja.wikipedia.org/w/api.php'),
    builtin: true,
  ),
  WebKnowledgeSite(
    id: 'wikipedia_en',
    kind: WebKnowledgeSiteKind.mediaWiki,
    label: 'Wikipedia (English)',
    endpoint: Uri.parse('https://en.wikipedia.org/w/api.php'),
    builtin: true,
  ),
  WebKnowledgeSite(
    id: 'moegirl',
    kind: WebKnowledgeSiteKind.mediaWiki,
    label: 'Moegirlpedia',
    endpoint: Uri.parse('https://zh.moegirl.org.cn/api.php'),
    builtin: true,
  ),
  const WebKnowledgeSite(
    id: 'ann',
    kind: WebKnowledgeSiteKind.animeNewsNetwork,
    label: 'Anime News Network',
    builtin: true,
  ),
  const WebKnowledgeSite(
    id: 'tvmaze',
    kind: WebKnowledgeSiteKind.tvMaze,
    label: 'TVmaze',
    builtin: true,
  ),
];

/// 自定义 MediaWiki 端点的唯一判据（设置页输入校验与偏好读取共用）：https、host
/// 非空、路径以 `api.php` 结尾。不合规返回 null。
Uri? validateWebKnowledgeEndpoint(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  if (!uri.path.endsWith('api.php')) return null;
  // query / fragment 会和我们拼的参数混在一起，一律去掉。
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  );
}

/// 解析偏好 `ai_web_knowledge_custom_sites`（JSON 数组）。坏条目 / 重复 id 丢弃，
/// 整体坏掉 → 空：跨设备同步过来的旧值或手改值不能让读取失败。
List<WebKnowledgeSite> parseWebKnowledgeCustomSites(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <WebKnowledgeSite>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <WebKnowledgeSite>[];
  }
  if (decoded is! List) return const <WebKnowledgeSite>[];
  final Set<String> seen = <String>{};
  final List<WebKnowledgeSite> sites = <WebKnowledgeSite>[];
  for (final Object? node in decoded) {
    if (node is! Map) continue;
    final Object? id = node['id'];
    final Object? endpoint = node['endpoint'];
    if (id is! String || endpoint is! String) continue;
    final Object? label = node['label'];
    final WebKnowledgeSite? site = WebKnowledgeSite.custom(
      id: id,
      label: label is String ? label : '',
      endpoint: endpoint,
    );
    if (site != null && seen.add(site.id)) sites.add(site);
  }
  return sites;
}

String encodeWebKnowledgeCustomSites(List<WebKnowledgeSite> sites) =>
    jsonEncode(<Map<String, Object?>>[
      for (final WebKnowledgeSite site in sites)
        if (!site.builtin) site.toJson(),
    ]);

/// 解析偏好 `ai_web_knowledge_sources`（启用的站点 id，逗号分隔）。null = 从未写过；
/// 调用方据此决定「全开」。不认识的 id 原样保留在集合里无害（取站点时只按已知站点
/// 过滤），所以这里不做过滤。
Set<String>? parseWebKnowledgeEnabledIds(String? raw) => raw == null
    ? null
    : <String>{
        for (final String part in raw.split(','))
          if (part.trim().isNotEmpty) part.trim(),
      };

class WebKnowledgePage {
  const WebKnowledgePage({
    required this.site,
    required this.title,
    required this.url,
    required this.text,
    this.isList = false,
  });

  final WebKnowledgeSite site;
  final String title;
  final Uri url;

  /// 纯文本正文（已截断）。
  final String text;

  /// 这一页本身就是「同名作品清单」（ANN / TVmaze），列系列作品时优先喂给 AI。
  final bool isList;

  @override
  String toString() => 'WebKnowledgePage(${site.id}, $title)';
}

/// 按启用站点抓资料的客户端。[client] 可注入，测试用 MockClient 不打真网；
/// [now] / [delay] 可注入，测试 ANN 限速间隔不用真等。
class WebKnowledgeClient {
  WebKnowledgeClient({
    required List<WebKnowledgeSite> sites,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 20),
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  }) : _now = now ?? DateTime.now,
       _delay = delay ?? _realDelay,
       _sites = List<WebKnowledgeSite>.unmodifiable(sites),
       _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null;

  final List<WebKnowledgeSite> _sites;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;
  final http.Client _client;
  final bool _ownsClient;

  /// 单个请求（连接 + 读完响应体）的总时限。app client 只管连接超时；连上后对方
  /// 迟迟不发完，没有这一道就会把作品识别 / 整套下载一起挂住。超时按这个站点失败
  /// 处理（记诊断、跳过），与其它失败同一条路。
  final Duration requestTimeout;

  /// 一个站点失败（连不上 / 超时 / 坏响应）后本进程停用它多久。
  ///
  /// 客户端是按调用新建的，失败若不跨实例记住，后台刮削会对每个歧义作品都去撞
  /// 一次注定失败的站点（直连被墙时每次白等 20~40 秒，100 部就是半小时以上）。
  static const Duration failureCooldown = Duration(minutes: 10);
  static final Map<String, DateTime> _cooldownUntil = <String, DateTime>{};

  /// ANN 要求每 IP ≤1 请求/秒：进程级闸门，跨客户端实例共享。
  static const Duration annRequestSpacing = Duration(seconds: 1);
  static final _SpacingGate _annGate = _SpacingGate(annRequestSpacing);

  /// 清掉进程级状态（失败冷却 + ANN 限速闸门）。
  @visibleForTesting
  static void resetFailureCooldowns() {
    _cooldownUntil.clear();
    _annGate.reset();
  }

  List<WebKnowledgeSite> get sites => _sites;

  bool get isEnabled => _sites.isNotEmpty;

  /// 在每个启用的站点里搜 [query]，取前 [pagesPerSource] 个条目的纯文本正文，每页截断到 [maxCharsPerPage]。
  /// 任何站点失败只记诊断日志（ErrorLogService.instance.logDiagnostic）并跳过，不抛。
  ///
  /// 站点之间并行、站点内逐页串行（对单站点保持礼貌的并发度）；结果按 [sites]
  /// 顺序排列，与网络返回先后无关。清单型站点（ANN / TVmaze）每个查询恒为一页。
  Future<List<WebKnowledgePage>> search(
    String query, {
    int pagesPerSource = 1,
    int maxCharsPerPage = 12000,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty || pagesPerSource <= 0 || maxCharsPerPage <= 0) {
      return const <WebKnowledgePage>[];
    }
    final DateTime now = _now();
    final List<WebKnowledgeSite> active = _sites
        .where(
          (WebKnowledgeSite site) =>
              !(_cooldownUntil[site.id]?.isAfter(now) ?? false),
        )
        .toList();
    final List<List<WebKnowledgePage>> perSite =
        await Future.wait<List<WebKnowledgePage>>(
          <Future<List<WebKnowledgePage>>>[
            for (final WebKnowledgeSite site in active)
              _searchSite(site, trimmed, pagesPerSource, maxCharsPerPage),
          ],
        );
    return <WebKnowledgePage>[
      for (final List<WebKnowledgePage> pages in perSite) ...pages,
    ];
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<List<WebKnowledgePage>> _searchSite(
    WebKnowledgeSite site,
    String query,
    int limit,
    int maxChars,
  ) async {
    final List<WebKnowledgePage> pages = <WebKnowledgePage>[];
    try {
      final Stream<WebKnowledgePage> fetched = switch (site.kind) {
        WebKnowledgeSiteKind.mediaWiki => _mediaWiki(site, query, limit),
        WebKnowledgeSiteKind.animeNewsNetwork => _animeNewsNetwork(site, query),
        WebKnowledgeSiteKind.tvMaze => _tvMaze(site, query),
      };
      await for (final WebKnowledgePage page in fetched) {
        pages.add(
          WebKnowledgePage(
            site: page.site,
            title: page.title,
            url: page.url,
            text: _truncate(page.text, maxChars),
            isList: page.isList,
          ),
        );
      }
    } catch (error, stack) {
      // 已抓到的页照样返回：一条正文失败不该连累同站点前面成功的。
      _cooldownUntil[site.id] = _now().add(failureCooldown);
      ErrorLogService.instance.logDiagnostic(
        'WebKnowledgeClient.${site.id}',
        '$query: $error\n$stack',
      );
    }
    return pages;
  }

  // ---------------------------------------------------------------------------
  // MediaWiki
  // ---------------------------------------------------------------------------

  Stream<WebKnowledgePage> _mediaWiki(
    WebKnowledgeSite site,
    String query,
    int limit,
  ) async* {
    final Uri api = site.endpoint!;
    final Object? search = jsonDecode(
      await _get(
        _withQuery(api, <String, String>{
          'action': 'opensearch',
          'format': 'json',
          'namespace': '0',
          'search': query,
          'limit': '$limit',
        }),
      ),
    );
    // opensearch 形如 [query, [标题…], [描述…], [URL…]]。
    if (search is! List || search.length < 2 || search[1] is! List) return;
    final List<Object?> titles = search[1] as List<Object?>;
    final List<Object?> urls = search.length > 3 && search[3] is List
        ? search[3] as List<Object?>
        : const <Object?>[];
    for (int i = 0; i < titles.length && i < limit; i++) {
      final Object? title = titles[i];
      if (title is! String || title.isEmpty) continue;
      final Object? rawUrl = i < urls.length ? urls[i] : null;
      final WebKnowledgePage? page = await _mediaWikiPage(
        site,
        title,
        rawUrl is String ? Uri.tryParse(rawUrl) : null,
      );
      if (page != null) yield page;
    }
  }

  Future<WebKnowledgePage?> _mediaWikiPage(
    WebKnowledgeSite site,
    String title,
    Uri? searchUrl,
  ) async {
    final Uri api = site.endpoint!;
    final Object? json = jsonDecode(
      await _get(
        _withQuery(api, <String, String>{
          'action': 'query',
          'format': 'json',
          'formatversion': '2',
          'prop': 'extracts',
          'explaintext': '1',
          'redirects': '1',
          'titles': title,
        }),
      ),
    );
    final Object? pages = _path(json, <String>['query', 'pages']);
    if (pages is! List || pages.isEmpty || pages.first is! Map) return null;
    final Map<Object?, Object?> page = pages.first as Map<Object?, Object?>;
    if (page['missing'] == true || page['invalid'] == true) return null;
    // redirects=1 时返回的是目标页标题。
    final String resolved = page['title'] is String
        ? page['title'] as String
        : title;
    final Object? extract = page['extract'];
    final String text = extract is String
        ? extract.trim()
        : await _mediaWikiParsedText(api, resolved);
    if (text.isEmpty) return null;
    return WebKnowledgePage(
      site: site,
      title: resolved,
      // 标题没被重定向改写时用 opensearch 给的 URL（站点自己的条目路径，Fandom /
      // 萌娘百科都不是 /wiki/）；改写了就按 index.php?title= 拼，任何 MediaWiki 都认。
      url: resolved == title && searchUrl != null
          ? searchUrl
          : webKnowledgeMediaWikiPageUrl(api, resolved),
      text: text,
    );
  }

  /// 站点没装 TextExtracts（页面在但无 `extract` 字段）：取渲染后的 HTML 剥成文本。
  Future<String> _mediaWikiParsedText(Uri api, String title) async {
    final Object? json = jsonDecode(
      await _get(
        _withQuery(api, <String, String>{
          'action': 'parse',
          'format': 'json',
          'formatversion': '2',
          'prop': 'text',
          'redirects': '1',
          'page': title,
        }),
      ),
    );
    final Object? htmlText = _path(json, <String>['parse', 'text']);
    return htmlText is String ? webKnowledgeHtmlToText(htmlText) : '';
  }

  // ---------------------------------------------------------------------------
  // Anime News Network
  // ---------------------------------------------------------------------------

  Stream<WebKnowledgePage> _animeNewsNetwork(
    WebKnowledgeSite site,
    String query,
  ) async* {
    final String body = await _annGate.run<String>(
      () => _get(
        Uri.https(
          'cdn.animenewsnetwork.com',
          '/encyclopedia/api.xml',
          <String, String>{'anime': '~$query'},
        ),
        accept: 'application/xml',
      ),
      now: _now,
      delay: _delay,
    );
    final WebKnowledgePage? page = buildAnnListPage(site, query, body);
    if (page != null) yield page;
  }

  // ---------------------------------------------------------------------------
  // TVmaze
  // ---------------------------------------------------------------------------

  Stream<WebKnowledgePage> _tvMaze(WebKnowledgeSite site, String query) async* {
    final String body = await _get(
      Uri.https('api.tvmaze.com', '/search/shows', <String, String>{
        'q': query,
      }),
    );
    final WebKnowledgePage? page = buildTvMazeListPage(site, query, body);
    if (page != null) yield page;
  }

  // ---------------------------------------------------------------------------
  // 传输
  // ---------------------------------------------------------------------------

  Future<String> _get(Uri uri, {String accept = 'application/json'}) =>
      _read(uri, accept).timeout(requestTimeout);

  Future<String> _read(Uri uri, String accept) async {
    // 不跟重定向：自定义站只允许 https，被 302 到 http:// 就绕过了这条校验；
    // 几个内置接口本身也不重定向。3xx 按非 200 失败处理。
    final http.Request request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['User-Agent'] = fushiUserAgent('web-knowledge')
      ..headers['Accept'] = accept;
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
    return utf8.decode(bytes, allowMalformed: true);
  }
}

Future<void> _realDelay(Duration duration) => Future<void>.delayed(duration);

/// 按到达顺序串行执行任务，且相邻两次**开始**之间至少隔 [spacing]。
class _SpacingGate {
  _SpacingGate(this.spacing);

  final Duration spacing;
  Future<void> _tail = Future<void>.value();
  DateTime? _lastStart;

  void reset() {
    _tail = Future<void>.value();
    _lastStart = null;
  }

  Future<T> run<T>(
    Future<T> Function() task, {
    required DateTime Function() now,
    required Future<void> Function(Duration) delay,
  }) {
    final Future<void> previous = _tail;
    final Completer<void> done = Completer<void>();
    _tail = done.future;
    Future<T> body() async {
      try {
        await previous;
        final DateTime? last = _lastStart;
        if (last != null) {
          final Duration wait = last.add(spacing).difference(now());
          if (wait > Duration.zero) await delay(wait);
        }
        _lastStart = now();
        return await task();
      } finally {
        done.complete();
      }
    }

    return body();
  }
}

/// ANN `api.xml` → 一页逐行清单。没有任何 `<anime>` → null。
WebKnowledgePage? buildAnnListPage(
  WebKnowledgeSite site,
  String query,
  String xmlBody,
) {
  final XmlDocument doc = XmlDocument.parse(xmlBody);
  final List<XmlElement> entries = doc
      .findAllElements('anime')
      .take(kWebKnowledgeListMaxEntries)
      .toList();
  if (entries.isEmpty) return null;
  final StringBuffer text = StringBuffer();
  for (int i = 0; i < entries.length; i++) {
    final XmlElement anime = entries[i];
    final String id = anime.getAttribute('id') ?? '';
    final String type = anime.getAttribute('type') ?? '?';
    String? mainTitle;
    final List<String> alternatives = <String>[];
    String? vintage;
    String? plot;
    for (final XmlElement info in anime.findElements('info')) {
      final String value = info.innerText.trim();
      if (value.isEmpty) continue;
      final String? lang = info.getAttribute('lang');
      switch (info.getAttribute('type')) {
        case 'Main title':
          mainTitle ??= value;
        case 'Alternative title':
          alternatives.add(lang == null ? value : '$value ($lang)');
        case 'Vintage':
          vintage ??= value;
        case 'Plot Summary':
          plot ??= value;
      }
    }
    final String title = mainTitle ?? anime.getAttribute('name') ?? '?';
    text.write(
      <String>[
        '[$type] ${<String>[title, ...alternatives].join(' / ')}',
        if (vintage != null) vintage,
        'ANN $id',
      ].join(' — '),
    );
    text.writeln();
    if (plot != null && i < kWebKnowledgeListSummaryEntries) {
      text.writeln('  ${_truncate(plot, kWebKnowledgeListSummaryChars)}');
    }
  }
  final String? singleId = entries.length == 1
      ? entries.single.getAttribute('id')
      : null;
  return WebKnowledgePage(
    site: site,
    title: 'Anime News Network: $query',
    url: singleId != null
        ? Uri.https(
            'www.animenewsnetwork.com',
            '/encyclopedia/anime.php',
            <String, String>{'id': singleId},
          )
        : Uri.https(
            'www.animenewsnetwork.com',
            '/encyclopedia/search/name',
            <String, String>{'only': 'anime', 'q': query},
          ),
    text: text.toString().trim(),
    isList: true,
  );
}

/// TVmaze `/search/shows` → 一页逐行清单。空结果 → null。
WebKnowledgePage? buildTvMazeListPage(
  WebKnowledgeSite site,
  String query,
  String jsonBody,
) {
  final Object? decoded = jsonDecode(jsonBody);
  if (decoded is! List) return null;
  final List<Map<Object?, Object?>> shows = <Map<Object?, Object?>>[
    for (final Object? hit in decoded)
      if (hit is Map && hit['show'] is Map)
        hit['show'] as Map<Object?, Object?>,
  ].take(kWebKnowledgeListMaxEntries).toList();
  if (shows.isEmpty) return null;
  String? str(Map<Object?, Object?> show, String key) {
    final Object? value = show[key];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  final StringBuffer text = StringBuffer();
  for (int i = 0; i < shows.length; i++) {
    final Map<Object?, Object?> show = shows[i];
    final String? premiered = str(show, 'premiered');
    final String? ended = str(show, 'ended');
    final String? status = str(show, 'status');
    text.writeln(
      <String>[
        '[${str(show, 'type') ?? '?'}] ${str(show, 'name') ?? '?'}',
        if (str(show, 'language') case final String language) language,
        if (premiered != null)
          '$premiered ~ ${ended ?? ''}${status == null ? '' : ' ($status)'}',
        if (str(show, 'url') case final String url) url,
      ].join(' — '),
    );
    final String? summary = str(show, 'summary');
    if (summary != null && i < kWebKnowledgeListSummaryEntries) {
      final String plain = webKnowledgeHtmlToText(summary);
      if (plain.isNotEmpty) {
        text.writeln('  ${_truncate(plain, kWebKnowledgeListSummaryChars)}');
      }
    }
  }
  final String? singleUrl = shows.length == 1 ? str(shows.single, 'url') : null;
  return WebKnowledgePage(
    site: site,
    title: 'TVmaze: $query',
    url: singleUrl != null
        ? Uri.parse(singleUrl)
        : Uri.https('www.tvmaze.com', '/search', <String, String>{'q': query}),
    text: text.toString().trim(),
    isList: true,
  );
}

/// MediaWiki 条目 URL 的通用形：`<api.php 同目录>/index.php?title=<标题>`。
/// 各站条目路径不一（`/wiki/…`、根路径…），但 index.php 是 MediaWiki 本体固定入口。
Uri webKnowledgeMediaWikiPageUrl(Uri api, String title) {
  final String path = api.path;
  final String dir = path.substring(0, path.length - 'api.php'.length);
  return Uri(
    scheme: api.scheme,
    host: api.host,
    port: api.hasPort ? api.port : null,
    path: '${dir}index.php',
    queryParameters: <String, String>{'title': title.replaceAll(' ', '_')},
  );
}

/// 选择器命中的节点整个丢掉：脚本样式、导航框、目录、脚注标号、编辑链接——它们
/// 不是正文，却能占掉大半篇幅。信息框（infobox）保留：年份、话数都在里面。
const String _kHtmlNoiseSelector =
    'script, style, noscript, .navbox, .vertical-navbox, .toc, #toc, '
    '.mw-editsection, sup.reference, .reference, .mw-references-wrap, '
    '.references, .metadata, .noprint';

const Set<String> _kHtmlBlockTags = <String>{
  'p',
  'div',
  'li',
  'tr',
  'br',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'dt',
  'dd',
  'blockquote',
  'pre',
  'table',
  'ul',
  'ol',
  'dl',
  'section',
};

/// HTML → 纯文本：剔除 [_kHtmlNoiseSelector]，块级元素后断行，单元格间空格，
/// 合并空白。只求「AI 读得懂」，不追求排版还原。
String webKnowledgeHtmlToText(String html) {
  final html_dom.DocumentFragment fragment = html_parser.parseFragment(html);
  for (final html_dom.Element noise in fragment.querySelectorAll(
    _kHtmlNoiseSelector,
  )) {
    noise.remove();
  }
  for (final html_dom.Element element in fragment.querySelectorAll('*')) {
    final String tag = element.localName ?? '';
    if (_kHtmlBlockTags.contains(tag)) {
      element.append(html_dom.Text('\n'));
    } else if (tag == 'td' || tag == 'th') {
      element.append(html_dom.Text(' '));
    }
  }
  return (fragment.text ?? '')
      .replaceAll(RegExp(r'[ \t ]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

Uri _withQuery(Uri base, Map<String, String> query) =>
    base.replace(queryParameters: query);

Object? _path(Object? json, List<String> keys) {
  Object? node = json;
  for (final String key in keys) {
    if (node is! Map) return null;
    node = node[key];
  }
  return node;
}

/// 按 UTF-16 码元截断，但不把代理对劈成两半（劈开的孤儿码元进 JSON 会变乱码）。
String truncateWebKnowledgeText(String text, int maxChars) =>
    _truncate(text, maxChars);

String _truncate(String text, int maxChars) {
  if (text.length <= maxChars) return text;
  int end = maxChars;
  final int last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return text.substring(0, end);
}
