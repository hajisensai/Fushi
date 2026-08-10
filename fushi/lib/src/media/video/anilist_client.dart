import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:fushi/src/utils/net/app_http.dart';

/// AniList 媒体（番剧）搜索结果的最小模型。
class AniListMedia {
  const AniListMedia({
    required this.id,
    this.romaji,
    this.english,
    this.native,
    this.coverUrl,
    this.episodes,
    this.seasonYear,
  });

  /// AniList 媒体 id（用于到 Jimaku 按 anilist_id 查字幕）。
  final int id;
  final String? romaji;
  final String? english;
  final String? native;

  /// 封面图 URL（`coverImage.large`）；旧响应/缺字段为 null。
  final String? coverUrl;

  /// 总集数（连载中/未知为 null）。
  final int? episodes;

  /// 放送年份（未知为 null），搜番消歧显示用。
  final int? seasonYear;

  /// 菜单显示用标题：优先罗马字 → 英文 → 日文 → id。
  String get displayTitle => (romaji?.isNotEmpty ?? false)
      ? romaji!
      : (english?.isNotEmpty ?? false)
          ? english!
          : (native?.isNotEmpty ?? false)
              ? native!
              : 'AniList #$id';
}

/// 罗马字长音符（macron）→ **双元音** 展开（修正 Hepburn）。番剧官方 romaji
/// 常用 macron 转写（ū ō ā ī ē，如「Chūnibyō」），但 AniList 的 search 索引
/// 用双元音拼法（如「Chuunibyou」）且**不做 macron 归一化匹配**——用户直接
/// 打/复制带 macron 的标题会 0 结果。
///
/// 实测（live AniList）：`Chūnibyō Demo Koi ga Shitai!` → 0；简单去 macron 的
/// `Chunibyo Demo…`（单元音）→ 仍 0（太短）；双元音 `Chuunibyou Demo…` → 命中。
/// 故按修正 Hepburn 展开长音：ā→aa ī→ii ū→uu ē→ee ō→ou（ō 取最常见的 おう；
/// 少数 おお 词靠 AniList 模糊匹配兜底）。
const Map<int, String> _macronExpand = <int, String>{
  0x0100: 'Aa', 0x0101: 'aa', // Ā ā
  0x0112: 'Ee', 0x0113: 'ee', // Ē ē
  0x012A: 'Ii', 0x012B: 'ii', // Ī ī
  0x014C: 'Ou', 0x014D: 'ou', // Ō ō
  0x016A: 'Uu', 0x016B: 'uu', // Ū ū
};

/// 归一化搜索关键词：把 macron 长音符展开成双元音，让带官方 romaji 长音的
/// 输入也能命中 AniList。预组合字母（ū…）按 [_macronExpand] 展开；分解形式的
/// combining macron U+0304 把前一个元音再写一遍（双写）。纯函数：无 macron 的
/// 输入原样返回（no-op），不会降低正常命中。
String normalizeAniListSearch(String query) {
  final StringBuffer sb = StringBuffer();
  int? prevRune; // 供 combining macron 双写前一元音
  for (final int rune in query.runes) {
    if (rune == 0x0304) {
      // combining macron：分解形式（如 'u' + U+0304）→ 双写前一个字母。
      if (prevRune != null) sb.writeCharCode(prevRune);
      continue;
    }
    final String? expanded = _macronExpand[rune];
    if (expanded != null) {
      sb.write(expanded);
      prevRune = null;
    } else {
      sb.writeCharCode(rune);
      prevRune = rune;
    }
  }
  return sb.toString();
}

/// Produces conservative AniList fallbacks for punctuation-separated titles.
///
/// AniList can find `Watashi wo Tabetai, Hitodenashi`, but returns no result
/// for the common alternate segmentation `Watashi o Tabetai, Hito de Nashi`.
/// Retrying the leading title segment keeps the user's intent while avoiding a
/// language-specific alias table.
List<String> aniListSearchQueries(String raw) {
  final List<String> queries = <String>[];
  void add(String value) {
    final String normalized = normalizeAniListSearch(value.trim());
    if (normalized.isNotEmpty && !queries.contains(normalized)) {
      queries.add(normalized);
    }
  }

  add(raw);
  final int separator = raw.indexOf(RegExp(r'[,，、]'));
  if (separator > 0) {
    add(raw.substring(0, separator));
  }
  return queries;
}

/// 解析 AniList GraphQL 搜索响应为 [AniListMedia] 列表。纯函数，容错（结构不符 →
/// 空列表），便于单测。
List<AniListMedia> parseAniListSearchResponse(String body) {
  try {
    final dynamic json = jsonDecode(body);
    if (json is! Map) return const <AniListMedia>[];
    final dynamic data = json['data'];
    if (data is! Map) return const <AniListMedia>[];
    final dynamic page = data['Page'];
    if (page is! Map) return const <AniListMedia>[];
    final dynamic media = page['media'];
    if (media is! List) return const <AniListMedia>[];
    final List<AniListMedia> out = <AniListMedia>[];
    for (final dynamic m in media) {
      if (m is! Map) continue;
      final dynamic id = m['id'];
      if (id is! int) continue;
      final dynamic title = m['title'];
      final dynamic cover = m['coverImage'];
      out.add(AniListMedia(
        id: id,
        romaji: title is Map ? title['romaji'] as String? : null,
        english: title is Map ? title['english'] as String? : null,
        native: title is Map ? title['native'] as String? : null,
        coverUrl: cover is Map ? cover['large'] as String? : null,
        episodes: m['episodes'] is int ? m['episodes'] as int : null,
        seasonYear: m['seasonYear'] is int ? m['seasonYear'] as int : null,
      ));
    }
    return out;
  } catch (_) {
    return const <AniListMedia>[];
  }
}

/// AniList 放送时间表条目：某番剧某一集的放送时刻（epoch 秒，UTC 基准）。
class AniListAiringEpisode {
  const AniListAiringEpisode({
    required this.mediaId,
    required this.episode,
    required this.airingAtSeconds,
    required this.media,
  });

  /// AniList 媒体 id（与合集 anilistId / 下载订阅 anilistId 同一 id 空间）。
  final int mediaId;

  /// 集号（AniList 从 1 起）。
  final int episode;

  /// 放送时刻（Unix epoch 秒）；本地展示用 `airingAtToLocal`（airing_week.dart）。
  final int airingAtSeconds;

  /// 该集所属番剧的标题/封面等元数据（airingSchedules.media 内联对象）。
  final AniListMedia media;
}

/// airingSchedules 的一页结果（Page.pageInfo.hasNextPage 决定是否继续翻页）。
class AniListAiringPage {
  const AniListAiringPage({required this.episodes, required this.hasNextPage});

  final List<AniListAiringEpisode> episodes;
  final bool hasNextPage;
}

/// AniList HTTP 层失败（非 200，含 429 rate limit）。放送日历要求错误如实
/// 上抛展示（与 [AniListClient.searchAnime] 的吞错语义**有意不同**：搜索是
/// 尽力而为的辅助路径，日历页必须让用户看到失败原因并可重试）。
class AniListRequestException implements Exception {
  const AniListRequestException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'AniList HTTP $statusCode: $message';
}

/// 解析 airingSchedules GraphQL 响应。纯函数，结构不符 → 空页（HTTP 层错误
/// 由 [AniListClient.fetchAiringSchedulePage] 以 [AniListRequestException] 上抛）。
AniListAiringPage parseAniListAiringResponse(String body) {
  const AniListAiringPage empty = AniListAiringPage(
    episodes: <AniListAiringEpisode>[],
    hasNextPage: false,
  );
  try {
    final dynamic json = jsonDecode(body);
    if (json is! Map) return empty;
    final dynamic data = json['data'];
    if (data is! Map) return empty;
    final dynamic page = data['Page'];
    if (page is! Map) return empty;
    final dynamic pageInfo = page['pageInfo'];
    final bool hasNextPage = pageInfo is Map && pageInfo['hasNextPage'] == true;
    final dynamic schedules = page['airingSchedules'];
    if (schedules is! List) return empty;
    final List<AniListAiringEpisode> out = <AniListAiringEpisode>[];
    for (final dynamic s in schedules) {
      if (s is! Map) continue;
      final dynamic mediaId = s['mediaId'];
      final dynamic episode = s['episode'];
      final dynamic airingAt = s['airingAt'];
      if (mediaId is! int || episode is! int || airingAt is! int) continue;
      final dynamic m = s['media'];
      final dynamic title = m is Map ? m['title'] : null;
      final dynamic cover = m is Map ? m['coverImage'] : null;
      out.add(AniListAiringEpisode(
        mediaId: mediaId,
        episode: episode,
        airingAtSeconds: airingAt,
        media: AniListMedia(
          id: mediaId,
          romaji: title is Map ? title['romaji'] as String? : null,
          english: title is Map ? title['english'] as String? : null,
          native: title is Map ? title['native'] as String? : null,
          coverUrl: cover is Map ? cover['large'] as String? : null,
          episodes:
              m is Map && m['episodes'] is int ? m['episodes'] as int : null,
          seasonYear: m is Map && m['seasonYear'] is int
              ? m['seasonYear'] as int
              : null,
        ),
      ));
    }
    return AniListAiringPage(episodes: out, hasNextPage: hasNextPage);
  } catch (_) {
    return empty;
  }
}

/// AniList GraphQL 客户端：按标题搜番拿 anilist id（Jimaku 按 anilist_id 查字幕的前置）。
class AniListClient {
  AniListClient({http.Client? client})
      : _client = client ?? createAppHttpIoClient();

  final http.Client _client;

  static const String _endpoint = 'https://graphql.anilist.co';
  static const String _searchQuery = r'''
query ($search: String) {
  Page(perPage: 10) {
    media(search: $search, type: ANIME) {
      id
      title { romaji english native }
      coverImage { large }
      episodes
      seasonYear
    }
  }
}''';

  /// 按 [title] 搜索番剧。网络/解析失败返回空列表（不抛，调用方按空处理）。
  /// 搜索词先做 macron 归一化（见 [normalizeAniListSearch]），让带官方 romaji
  /// 长音（ū ō…）的输入也能命中 AniList；全标题无结果时再尝试逗号前的主标题，
  /// 兼容罗马字连写/分写别名差异。
  Future<List<AniListMedia>> searchAnime(String title) async {
    for (final String query in aniListSearchQueries(title)) {
      try {
        final http.Response res = await _client.post(
          Uri.parse(_endpoint),
          headers: const <String, String>{
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(<String, dynamic>{
            'query': _searchQuery,
            'variables': <String, dynamic>{'search': query},
          }),
        );
        if (res.statusCode != 200) continue;
        // 显式 UTF-8 解码（res.body 无 charset 时按 latin1 → 日文/罗马音乱码）。
        final List<AniListMedia> matches = parseAniListSearchResponse(
          utf8.decode(res.bodyBytes, allowMalformed: true),
        );
        if (matches.isNotEmpty) return matches;
      } catch (_) {
        // Try the next conservative fallback; callers still receive [].
      }
    }
    return const <AniListMedia>[];
  }

  static const String _airingQuery = r'''
query ($from: Int, $to: Int, $ids: [Int], $page: Int) {
  Page(page: $page, perPage: 50) {
    pageInfo { hasNextPage }
    airingSchedules(airingAt_greater: $from, airingAt_lesser: $to, mediaId_in: $ids, sort: TIME) {
      mediaId
      episode
      airingAt
      media {
        title { romaji english native }
        coverImage { large }
        episodes
        seasonYear
      }
    }
  }
}''';

  /// 拉取 ([airingAtGreater], [airingAtLesser]) 开区间（epoch 秒）窗口内的
  /// 放送时间表一页。[mediaIds] 非空时只查这些番剧（合集绑定 + 订阅）；null =
  /// 不过滤（「显示本季全部」）。**变量缺省 ≠ null**：GraphQL 规范里未提供的
  /// 变量使对应实参视同未写，故 [mediaIds] 为 null 时直接不放进 variables，
  /// AniList 才不会按「mediaId_in: null」过滤出 0 结果。
  ///
  /// 与 [searchAnime] 不同，本方法**不吞错**：非 200（含 429 rate limit）抛
  /// [AniListRequestException]，网络异常原样上抛，调用方如实展示并提供重试。
  Future<AniListAiringPage> fetchAiringSchedulePage({
    required int airingAtGreater,
    required int airingAtLesser,
    List<int>? mediaIds,
    int page = 1,
  }) async {
    final http.Response res = await _client.post(
      Uri.parse(_endpoint),
      headers: const <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'query': _airingQuery,
        'variables': <String, dynamic>{
          'from': airingAtGreater,
          'to': airingAtLesser,
          'page': page,
          if (mediaIds != null) 'ids': mediaIds,
        },
      }),
    );
    if (res.statusCode != 200) {
      final String body = utf8.decode(res.bodyBytes, allowMalformed: true);
      final String snippet =
          body.length > 200 ? '${body.substring(0, 200)}…' : body;
      throw AniListRequestException(res.statusCode, snippet);
    }
    return parseAniListAiringResponse(
      utf8.decode(res.bodyBytes, allowMalformed: true),
    );
  }

  void close() => _client.close();
}
