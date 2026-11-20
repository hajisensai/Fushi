import 'dart:math' as math;

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/ai/web_search.dart';

import 'package:fushi/src/ai/ai_agent_web_search_policy.dart';
import 'package:fushi/src/models/preference_keys.dart'
    show kAiAgentWebSearchAllow;
import 'package:fushi/src/ops/op_context.dart';

/// AI 助手的通用联网搜索（操作 `web.search` / `web.read`，所有者 2026-11-20「ai 可以
/// 自主搜索」「第一次要确认吧」；spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §5.2「首次确认」）。
///
/// 后端就是「设置 › AI › 联网搜索」配的那个（[WebSearchClient]：SearXNG / Brave），
/// 与字幕生成找歌词同一个客户端、同一套 SSRF 防护（只抓公网地址、逐跳校验重定向、
/// 按已校验 IP 建连），这里不另写出站逻辑。
///
/// - `web.search`：搜索词发给后端，结果按条发一个**结果 id**（随机、30 分钟过期），
///   只回 {id, 标题, 摘要, 站点}；
/// - `web.read`：只收 `web.search` 给的结果 id，不收任意地址——模型拼的地址路径 /
///   query 能夹带它看到的任何东西发给任意主机，撤销收不回；限定成刚才的搜索结果后，
///   目的地址由搜索后端决定。正文剥成纯文本，按 [kWebReadChunkChars] 分段，`offset`
///   取后续段，不整页塞回去。
///
/// 门：没配后端 → 拒绝、不发任何请求；用户在设置里关了 → 拒绝；还没同意 → 要表态
/// 参数 `confirm`（AI 助手的确认卡点了同意 / CLI `--yes`），这一次顺带记下同意
/// （设备本地偏好），之后不再要。
///
/// CLI 侧是 `fushi_cli web search` / `web read`
/// （`packages/fushi_cli/lib/src/commands/web_commands.dart`）。
List<CtlRoute> buildWebSearchCtlRoutes(OpContext context) =>
    buildWebSearchCtlRoutesFor(
      config: () => context.appModel.prefsRepo.aiWebSearchConfig,
      consent: () => context.appModel.prefsRepo.aiAgentWebSearchConsent,
      grantConsent: () => context.appModel.prefsRepo.grantAiAgentWebSearch(),
      client: (WebSearchConfig config) => WebSearchClient(config: config),
      cache: sharedWebSearchResultCache,
    );

/// 搜索路由。
const String kWebSearchCtlSearch = '/api/admin/web/search';

/// 读结果页路由。
const String kWebSearchCtlRead = '/api/admin/web/read';

/// 一次搜索默认 / 最多回几条。
const int kWebSearchDefaultLimit = 5;
const int kWebSearchMaxLimit = 10;

/// 摘要最多留几个字（摘要是搜索引擎给的，长的截掉省 token）。
const int kWebSearchSnippetChars = 300;

/// `web.read` 一段回多少字。
const int kWebReadChunkChars = 4000;

/// 一页正文最多留多少字（再长的后半截不给）。
const int kWebReadMaxPageChars = 200000;

/// 结果 id 多久过期、最多记多少条、最多缓存几页正文。
const Duration kWebSearchResultTtl = Duration(minutes: 30);
const int kWebSearchMaxCachedResults = 200;
const int kWebReadMaxCachedPages = 8;

/// 一条记下的搜索结果。
class WebSearchResultEntry {
  WebSearchResultEntry({
    required this.id,
    required this.hit,
    required this.createdAt,
  });

  final String id;
  final WebSearchHit hit;
  final DateTime createdAt;
}

/// 搜索结果 id → 地址（以及读过的正文）。进程内存，不落盘：id 只在这次运行里有效。
class WebSearchResultCache {
  WebSearchResultCache({DateTime Function()? clock, math.Random? random})
    : _clock = clock ?? DateTime.now,
      _random = random ?? math.Random.secure();

  final DateTime Function() _clock;
  final math.Random _random;
  final Map<String, WebSearchResultEntry> _results =
      <String, WebSearchResultEntry>{};
  final Map<String, WebSearchPage> _pages = <String, WebSearchPage>{};

  /// 记下一条结果，返回新 id（`r` + 12 位十六进制，猜不中）。
  String put(WebSearchHit hit) {
    _evictExpired();
    String id;
    do {
      id =
          'r${List<String>.generate(12, (_) => _random.nextInt(16).toRadixString(16)).join()}';
    } while (_results.containsKey(id));
    _results[id] = WebSearchResultEntry(id: id, hit: hit, createdAt: _clock());
    while (_results.length > kWebSearchMaxCachedResults) {
      final String oldest = _results.keys.first;
      _results.remove(oldest);
      _pages.remove(oldest);
    }
    return id;
  }

  /// 按 id 取结果；不存在或过期 → null。
  WebSearchResultEntry? lookup(String id) {
    _evictExpired();
    return _results[id];
  }

  WebSearchPage? page(String id) => _pages[id];

  void putPage(String id, WebSearchPage page) {
    _pages.remove(id);
    _pages[id] = page;
    while (_pages.length > kWebReadMaxCachedPages) {
      _pages.remove(_pages.keys.first);
    }
  }

  void _evictExpired() {
    final DateTime now = _clock();
    _results.removeWhere((String id, WebSearchResultEntry e) {
      final bool expired = now.difference(e.createdAt) > kWebSearchResultTtl;
      if (expired) _pages.remove(id);
      return expired;
    });
  }
}

/// 全应用共用的一份：CLI 服务端与进程内调用器各自组路由表，结果 id 在哪张表里搜到
/// 都能在另一张表里读（id 随机，不会串）。
final WebSearchResultCache sharedWebSearchResultCache = WebSearchResultCache();

/// 可注入依赖的路由表（测试换掉后端客户端与偏好）。
List<CtlRoute> buildWebSearchCtlRoutesFor({
  required WebSearchConfig? Function() config,
  required String Function() consent,
  required Future<void> Function() grantConsent,
  required WebSearchClient Function(WebSearchConfig config) client,
  required WebSearchResultCache cache,
}) {
  final _WebSearchCtl ctl = _WebSearchCtl(
    config: config,
    consent: consent,
    grantConsent: grantConsent,
    client: client,
    cache: cache,
  );
  return <CtlRoute>[
    CtlRoute.post(kWebSearchCtlSearch, ctl.search),
    CtlRoute.post(kWebSearchCtlRead, ctl.read),
  ];
}

class _WebSearchCtl {
  _WebSearchCtl({
    required this.config,
    required this.consent,
    required this.grantConsent,
    required this.client,
    required this.cache,
  });

  final WebSearchConfig? Function() config;
  final String Function() consent;
  final Future<void> Function() grantConsent;
  final WebSearchClient Function(WebSearchConfig config) client;
  final WebSearchResultCache cache;

  /// 过门：后端配好、没被关掉、已同意（或这次带了表态参数 → 记下同意）。返回要用的
  /// 后端配置。任何一道不过都在发请求之前拒绝。
  Future<WebSearchConfig> _gate(CtlCall call) async {
    final WebSearchConfig? cfg = config();
    final String state = consent();
    final OpAvailability availability = agentWebSearchAvailability(cfg, state);
    if (!availability.isAvailable) {
      throw CtlFailure(
        422,
        availability.code!,
        availability.code == 'no_search_backend'
            ? '没配置联网搜索后端（设置 › AI › 联网搜索）'
            : 'AI 助手联网搜索已在设置里关闭（设置 › AI › 联网搜索）',
      );
    }
    if (state != kAiAgentWebSearchAllow) {
      if (call.optBool('confirm') != true) {
        throw CtlFailure(
          400,
          'consent_required',
          '首次联网搜索需要用户确认：搜索词与要读的网页地址会发给 '
              '${webSearchBackendLabel(cfg!)}（confirm=true）',
        );
      }
      await grantConsent();
    }
    return cfg!;
  }

  /// `web search <搜索词>`：发给用户配置的后端，每条结果发一个结果 id。
  Future<Object?> search(CtlCall call) async {
    final String query = call.requireString('query').trim();
    if (query.isEmpty) throw const CtlFailure.badRequest('query 不能为空');
    final int limit = call.optInt('limit') ?? kWebSearchDefaultLimit;
    if (limit <= 0) throw const CtlFailure.badRequest('limit 必须为正');
    final WebSearchConfig cfg = await _gate(call);
    final WebSearchClient searcher = client(cfg);
    final List<WebSearchHit> hits;
    try {
      hits = await searcher.search(
        query,
        limit: math.min(limit, kWebSearchMaxLimit),
      );
    } finally {
      searcher.close();
    }
    return <String, Object?>{
      'query': query,
      'backend': cfg.kind.name,
      'results': <Map<String, Object?>>[
        for (final WebSearchHit hit in hits)
          // 本机 / 内网地址的结果读不了（SSRF 防护），干脆不给。
          if (isFetchableWebSearchUrl(hit.url))
            <String, Object?>{
              'id': cache.put(hit),
              'title': hit.title,
              'snippet': hit.snippet.length > kWebSearchSnippetChars
                  ? '${hit.snippet.substring(0, kWebSearchSnippetChars)}…'
                  : hit.snippet,
              'site': hit.url.host,
            },
      ],
    };
  }

  /// `web read <结果 id> [--offset N]`：抓这条结果的页面正文（纯文本），一段
  /// [kWebReadChunkChars] 字；`nextOffset` 非空时还有下一段。
  Future<Object?> read(CtlCall call) async {
    final String id = call.requireString('id').trim();
    final int offset = call.optInt('offset') ?? 0;
    if (offset < 0) throw const CtlFailure.badRequest('offset 不能为负');
    final WebSearchConfig cfg = await _gate(call);
    final WebSearchResultEntry? entry = cache.lookup(id);
    if (entry == null) {
      throw CtlFailure.notFound(
        '没有这条搜索结果：$id（只收 web.search 刚给的结果 id，30 分钟后过期）',
      );
    }
    WebSearchPage? page = cache.page(id);
    if (page == null) {
      final WebSearchClient fetcher = client(cfg);
      try {
        page = await fetcher.fetchPage(
          entry.hit.url,
          title: entry.hit.title,
          maxChars: kWebReadMaxPageChars,
        );
      } finally {
        fetcher.close();
      }
      if (page == null) {
        throw const CtlFailure(502, 'fetch_failed', '这一页抓不到（地址不是公网地址、请求失败或超时）');
      }
      cache.putPage(id, page);
    }
    final String text = page.text;
    final int start = math.min(offset, text.length);
    final int end = math.min(start + kWebReadChunkChars, text.length);
    return <String, Object?>{
      'id': id,
      'title': page.title,
      'url': page.url.toString(),
      'site': page.url.host,
      'offset': start,
      'text': text.substring(start, end),
      'totalChars': text.length,
      'nextOffset': end < text.length ? end : null,
    };
  }
}
