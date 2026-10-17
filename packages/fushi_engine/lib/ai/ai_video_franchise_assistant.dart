/// 「整套下载」的联网补全：app 抓资料站（维基百科 / ANN / TVmaze …）条目正文 → AI 从正文里列出系列作品 →
/// 逐部回资料源（TMDB / MAL 发现搜索）核对 → 核对上的并进清单。
///
/// 边界与其它 AI 功能一致：**AI 只出候选，不决定下什么**。
/// * 正文是 app 抓的（`web_knowledge.dart`），不要求 AI 提供商支持联网；
/// * AI 只能列正文里出现的作品，输出是结构化 JSON（标题 / 原名 / 年份 / 类型），
///   本地逐字段校验；
/// * 每一部都要在资料源里搜到**同类型、年份 ±1、标题一致**的作品才收——AI 编造
///   或记错的片名核对不上，进不了清单，更进不了下载队列。
/// * 只核对 TMDB / MAL 清单里还没有的那些：已知的不重复搜，省时间也省限流。
library;

import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart' show mergeSort;
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_engine/ai/ai_video_acquisition_assistant.dart'
    show resolveVideoAcquireAiProvider;
import 'package:fushi_engine/ai/ai_video_search_assistant.dart'
    show AiClientFactory;
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/video/discovery/video_franchise.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';

/// AI 从正文里列出的一部作品（已本地校验）。
class AiFranchiseWork {
  const AiFranchiseWork({
    required this.title,
    required this.kind,
    this.originalTitle,
    this.year,
  });

  final String title;
  final String? originalTitle;
  final int? year;
  final VideoMetadataMediaKind kind;

  List<String> get names => <String>[
    title,
    if (originalTitle != null) originalTitle!,
  ];
}

/// 一次最多收几部（长寿系列 40+ 剧场版 + 几部剧集）。
const int kAiFranchiseMaxWorks = 80;

/// 给 AI 的正文最多几页、每页多少字。
const int kAiFranchiseMaxPages = 3;
const int kAiFranchiseMaxCharsPerPage = 10000;

String buildAiFranchiseListSystemPrompt() =>
    '''
You extract the list of works that belong to one anime / TV / film franchise
from encyclopedia excerpts. You only report works that are explicitly named in
the excerpts. Never add works from memory, never guess titles or years.

Answer with a single JSON object and nothing else:
{"works": [{"title": "...", "originalTitle": "... or null", "year": <number or null>, "kind": "movie" | "tv"}]}

Rules:
- "movie" = theatrical film; "tv" = TV series (each separately titled TV
  series / season that the excerpts list as its own work).
- Skip OVAs, specials, shorts shown with films, video games, manga, novels,
  stage plays, music and live events.
- "title" is the title as written in the excerpt; "originalTitle" the original
  (usually Japanese) title when the excerpt gives it.
- "year" is the release / first-air year stated in the excerpt, else null.
- At most $kAiFranchiseMaxWorks works, in release order.
''';

String buildAiFranchiseListUserPrompt({
  required String franchise,
  required List<WebKnowledgePage> pages,
}) => const JsonEncoder.withIndent('  ').convert(<String, Object?>{
  'franchise': franchise,
  'excerpts': <Map<String, Object?>>[
    for (final WebKnowledgePage page in pages)
      <String, Object?>{
        'source': page.url.toString(),
        'title': page.title,
        'text': page.text,
      },
  ],
});

/// 解析 AI 回复：字段逐个校验，坏一条丢一条；抠不出 JSON → 空。
List<AiFranchiseWork> parseAiFranchiseList(String reply) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  final Object? works = decoded?['works'];
  if (works is! List) return const <AiFranchiseWork>[];
  final List<AiFranchiseWork> result = <AiFranchiseWork>[];
  for (final Object? node in works) {
    if (result.length >= kAiFranchiseMaxWorks) break;
    if (node is! Map) continue;
    final String title = _cleanTitle(node['title']);
    if (title.isEmpty) continue;
    final VideoMetadataMediaKind? kind = switch (node['kind']) {
      'movie' => VideoMetadataMediaKind.movie,
      'tv' => VideoMetadataMediaKind.tv,
      _ => null,
    };
    if (kind == null) continue;
    final String original = _cleanTitle(node['originalTitle']);
    final Object? rawYear = node['year'];
    final int? year = rawYear is num && rawYear == rawYear.roundToDouble()
        ? rawYear.toInt()
        : null;
    result.add(
      AiFranchiseWork(
        title: title,
        originalTitle: original.isEmpty || original == title ? null : original,
        year: year != null && year >= 1900 && year <= 2100 ? year : null,
        kind: kind,
      ),
    );
  }
  return result;
}

String _cleanTitle(Object? raw) {
  if (raw is! String) return '';
  final String value = raw.trim();
  return value.length > 160 ? '' : value;
}

/// 挑喂给 AI 的正文，按「像作品清单」的程度排序后去重取前 [kAiFranchiseMaxPages] 页：
/// 清单型站点的整页清单（ANN / TVmaze，[WebKnowledgePage.isList]）最前；其次是
/// 标题像「作品列表」的百科条目（`List of … films` / `…剧场版` / `…一覧`）；最后
/// 是普通条目。
List<WebKnowledgePage> pickFranchisePages(List<WebKnowledgePage> pages) {
  final Map<String, WebKnowledgePage> unique = <String, WebKnowledgePage>{
    for (final WebKnowledgePage page in pages) page.url.toString(): page,
  };
  final RegExp listLike = RegExp(
    r'(list of|films|filmography|作品列表|列表|剧场版|劇場版|映画|一覧|シリーズ)',
    caseSensitive: false,
  );
  // 百科的「作品列表」条目与 ANN 清单同档最优先；TVmaze 只收剧集、且是模糊搜索，
  // 对剧场版系列帮不上，降一档——否则它会把维基的 `List of … films` 挤出名额。
  int rank(WebKnowledgePage page) {
    if (page.site.kind == WebKnowledgeSiteKind.tvMaze) return 1;
    if (page.isList || listLike.hasMatch(page.title)) return 2;
    return 0;
  }

  // 稳定排序：同档内保持站点顺序（用户启用的站点顺序即优先级）。
  final List<WebKnowledgePage> ordered = unique.values.toList();
  mergeSort(
    ordered,
    compare: (WebKnowledgePage a, WebKnowledgePage b) => rank(b) - rank(a),
  );
  // 每个站最多一页：两次查询（系列名 + 原名）会让同一个站出两页清单，名额被
  // 一个站吃掉。
  final Set<String> seenSites = <String>{};
  final List<WebKnowledgePage> picked = <WebKnowledgePage>[
    for (final WebKnowledgePage page in ordered)
      if (seenSites.add(page.site.id)) page,
  ];
  return <WebKnowledgePage>[
    for (final WebKnowledgePage page in picked.take(kAiFranchiseMaxPages))
      WebKnowledgePage(
        site: page.site,
        title: page.title,
        url: page.url,
        text: truncateWebKnowledgeText(page.text, kAiFranchiseMaxCharsPerPage),
        isList: page.isList,
      ),
  ];
}

/// 跑一次「从正文列作品」。失败原样抛 [AiChatFailure]。
Future<List<AiFranchiseWork>> requestAiFranchiseList({
  required AiChatClient client,
  required AiProviderConfig provider,
  required String franchise,
  required List<WebKnowledgePage> pages,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(buildAiFranchiseListSystemPrompt()),
      AiChatMessage.user(
        buildAiFranchiseListUserPrompt(franchise: franchise, pages: pages),
      ),
    ],
    // 几十部作品的 JSON 列表：每部 ~40 token。
    maxTokens: 6000,
  );
  return parseAiFranchiseList(reply);
}

/// AI 列出的一部是否就是资料源搜到的这一部：类型一致、年份 ±1（两边都有时）、
/// 标题归一化后有一对相等。
bool aiFranchiseWorkMatches(AiFranchiseWork work, VideoDiscoveryItem item) {
  final VideoMediaReference reference = item.reference;
  if (reference.mediaKind != work.kind) return false;
  final int? year = reference.year;
  if (work.year != null && year != null && (work.year! - year).abs() > 1) {
    return false;
  }
  final Set<String> wanted = <String>{
    for (final String name in work.names) TitleNormalizer.normalize(name),
  };
  return <String?>[
    reference.title,
    reference.originalTitle,
    ...reference.aliases,
  ].any(
    (String? value) =>
        value != null && wanted.contains(TitleNormalizer.normalize(value)),
  );
}

/// 联网补全最多发几个查询（每个查询每站各抓一页）。
const int kAiFranchiseMaxWebQueries = 3;

/// 联网补全的查询词，按「最像系列名」排序、按归一化标题去重，最多
/// [kAiFranchiseMaxWebQueries] 个；首个即交给 AI 的系列名。
///
/// 资料源给出的系列名最可信；其次是用户说的作品名（AI 补的原名 / 罗马字）。锚点
/// 自己的标题垫底：锚点是单部剧场版时，它只搜得到那一部的条目，列不出系列
/// （BUG-2960：「全部哆啦A梦剧场版」拿《のび太の月面探査記》去搜，三站都只回
/// 那一部的页面；用 `Doraemon` 搜到的 ANN 条目才列着全部剧场版）。
///
/// 与锚点同名的「系列名」不带任何系列信息（MAL 关联链走不动时就拿锚点标题当系列
/// 名），一律按锚点标题算、排到最后。
List<String> aiFranchiseWebQueries({
  required VideoMediaReference anchor,
  required List<String> seriesNames,
  String? knownName,
}) {
  final Map<String, String> byKey = <String, String>{};
  void add(String? raw) {
    final String name = raw?.trim() ?? '';
    if (name.isEmpty) return;
    byKey.putIfAbsent(TitleNormalizer.normalize(name), () => name);
  }

  final Set<String> anchorKeys = <String>{
    for (final String? title in <String?>[anchor.title, anchor.originalTitle])
      if (title != null) TitleNormalizer.normalize(title),
  };
  for (final String? name in <String?>[knownName, ...seriesNames]) {
    if (name != null && !anchorKeys.contains(TitleNormalizer.normalize(name))) {
      add(name);
    }
  }
  add(anchor.title);
  add(anchor.originalTitle);
  return byKey.values.take(kAiFranchiseMaxWebQueries).toList();
}

/// 联网补全：抓正文 → AI 列作品 → 只核对 [known] 里还没有的 → 核对上的并进去。
///
/// 任何一步失败都退回 [known]（记诊断）：联网补全是加法，不能让已有的清单失效。
Future<VideoFranchise?> expandVideoFranchiseFromWeb({
  required VideoDiscoveryItem anchor,
  List<String> seriesNames = const <String>[],
  required VideoFranchise? known,
  required WebKnowledgeClient web,
  required Future<List<AiFranchiseWork>> Function(
    String franchise,
    List<WebKnowledgePage> pages,
  )
  listWorks,
  required Future<List<VideoDiscoveryItem>> Function(AiFranchiseWork work)
  findCandidates,
}) async {
  if (!web.isEnabled) return known;
  final VideoMediaReference reference = anchor.reference;
  final List<String> queries = aiFranchiseWebQueries(
    anchor: reference,
    seriesNames: seriesNames,
    knownName: known?.name,
  );
  final String franchise = queries.first;
  try {
    final List<WebKnowledgePage> fetched = <WebKnowledgePage>[];
    // 每个查询每站一页：只用得上 3 页，别抓十几页。
    for (final String query in queries) {
      fetched.addAll(
        await web.search(query, maxCharsPerPage: kAiFranchiseMaxCharsPerPage),
      );
    }
    final List<WebKnowledgePage> pages = pickFranchisePages(fetched);
    if (pages.isEmpty) return known;
    final List<AiFranchiseWork> works = await listWorks(franchise, pages);
    final List<VideoDiscoveryItem> knownItems = <VideoDiscoveryItem>[
      anchor,
      ...?known?.series,
      ...?known?.movies,
    ];
    final List<VideoDiscoveryItem> series = <VideoDiscoveryItem>[];
    final List<VideoDiscoveryItem> movies = <VideoDiscoveryItem>[];
    for (final AiFranchiseWork work in works) {
      if (knownItems.any(
        (VideoDiscoveryItem item) => aiFranchiseWorkMatches(work, item),
      )) {
        continue;
      }
      // 补进来的作品必须带年份：没有年份就只剩「类型 + 标题」可比，泛名（`Air`）
      // 会把同名的别的作品带进清单。
      if (work.year == null) continue;
      for (final VideoDiscoveryItem candidate in await findCandidates(work)) {
        if (aiFranchiseWorkMatches(work, candidate)) {
          (work.kind == VideoMetadataMediaKind.movie ? movies : series).add(
            candidate,
          );
          break;
        }
      }
    }
    // 锚点本就是系列成员：资料源走不动时（MAL 关联链 0 部）它不一定在 [known]
    // 里，上面又把它当「已知」跳过——两头都不收，清单里就没有用户选的那一部
    // （BUG-2960）。
    (reference.mediaKind == VideoMetadataMediaKind.movie ? movies : series)
        .insert(0, anchor);
    // 联网这份排前面：合并结果的名字取它，即最像系列名的那个查询词。
    return mergeVideoFranchises(<VideoFranchise?>[
      VideoFranchise(name: franchise, series: series, movies: movies),
      known ??
          // 资料源整个不可用：清单只有联网补全核对上的那部分（BUG-2936）。
          VideoFranchise(
            name: franchise,
            series: const <VideoDiscoveryItem>[],
            movies: const <VideoDiscoveryItem>[],
            truncated: true,
          ),
    ]);
  } on Object catch (error, stack) {
    engineLog.logDiagnostic(
      'VideoAcquisition.franchiseWeb',
      '$franchise: $error\n$stack',
    );
    return known;
  }
}

/// 生产装配：「整套下载」的系列加载 = 资料源（TMDB collection + MAL 关联）+ 联网
/// 补全。AI 下视频未指派提供商时只走资料源（不发 AI 请求）；联网资料来源全关时
/// [expandVideoFranchiseFromWeb] 直接返回资料源结果。
Future<VideoFranchise?> Function(VideoFranchiseQuery query)
createPreferencesVideoFranchiseLoader(
  AiSettingsSource prefs, {
  required Future<VideoFranchise?> Function(VideoDiscoveryItem item) base,
  required Future<ProviderBatchResult<VideoDiscoveryPage>> Function(
    VideoDiscoveryRequest request,
  )
  searchWorks,
  AiClientFactory? clientFactory,
  WebKnowledgeClient Function()? webFactory,
}) => (VideoFranchiseQuery query) async {
  final VideoDiscoveryItem item = query.item;
  final VideoFranchise? known = await base(item);
  final AiProviderConfig? provider = resolveVideoAcquireAiProvider(prefs);
  if (provider == null) return known;
  final AiChatClient client = clientFactory?.call() ?? AiChatClient();
  final WebKnowledgeClient web =
      webFactory?.call() ??
      WebKnowledgeClient(sites: prefs.aiWebKnowledgeSites);
  final bool anime =
      item.reference.discoveryCategory == VideoDiscoveryCategory.anime;
  try {
    return await expandVideoFranchiseFromWeb(
      anchor: item,
      seriesNames: query.seriesNames,
      known: known,
      web: web,
      listWorks: (String franchise, List<WebKnowledgePage> pages) =>
          requestAiFranchiseList(
            client: client,
            provider: provider,
            franchise: franchise,
            pages: pages,
          ),
      // 回资料源核对：先原名再标题；动画走 anime 类（MAL / AniList），其它按类型。
      findCandidates: (AiFranchiseWork work) async {
        final List<VideoDiscoveryItem> found = <VideoDiscoveryItem>[];
        for (final String query in work.names.reversed) {
          final ProviderBatchResult<VideoDiscoveryPage> result =
              await searchWorks(
                VideoDiscoveryRequest(
                  query: query,
                  category: anime
                      ? VideoDiscoveryCategory.anime
                      : work.kind == VideoMetadataMediaKind.movie
                      ? VideoDiscoveryCategory.movie
                      : VideoDiscoveryCategory.tv,
                  pageSize: 10,
                  sort: VideoDiscoverySort.relevance,
                ),
              );
          for (final VideoDiscoveryPage page in result.items) {
            found.addAll(page.items);
          }
          if (found.any(
            (VideoDiscoveryItem candidate) =>
                aiFranchiseWorkMatches(work, candidate),
          )) {
            break;
          }
        }
        return found;
      },
    );
  } finally {
    client.close();
    web.close();
  }
};
