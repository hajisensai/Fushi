/// AniList 在线搜索客户端 —— 动画/剧场版的**补充源**（GraphQL，零 key 门槛）。
///
/// 端点 `POST https://graphql.anilist.co`，公开 API 无需注册、无需 key，这正是它被
/// 选作补充源的原因：不给用户增加任何配置负担（对比 TMDB 要内置 key、TVDB 要申请）。
///
/// 标题策略：本 app 面向日语学习，**主标题取 `native`（日文原题）**，romaji / english /
/// synonyms 全部进 [ScrapeCandidate.aliases] 参与打分。这与 Bangumi（中文优先）互补：
/// 同一部作品在两源各出一条候选，用户看到的是不同语言的同一部片，不是重复项。
///
/// 网络异常复用 bangumi_client 定义的 [ScrapeNetworkException]（不重复定义）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/media/video/scraper/bangumi_client.dart'
    show ScrapeNetworkException;
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:http/http.dart' as http;

/// AniList GraphQL 搜索客户端。构造可注入 [http.Client]（默认自建）。
class AniListClient {
  AniListClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 15);

  static const String endpoint = 'https://graphql.anilist.co';

  /// 单次搜索返回条数上限。15 与 Bangumi/TMDB 量级对齐：聚合视图里每源都吐 50 条会
  /// 把列表淹掉，而打分层真正会被用户看的只有头部若干条。
  static const int _perPage = 15;

  /// 搜索查询。`sort: SEARCH_MATCH` 让 AniList 自己按匹配度排（我们再用
  /// [MatchScorer] 统一重排，但源侧先排能保证 15 条窗口里装的是最相关的）。
  static const String _query = r'''
query ($search: String, $perPage: Int) {
  Page(perPage: $perPage) {
    media(search: $search, type: ANIME, sort: SEARCH_MATCH) {
      id
      title { romaji english native }
      synonyms
      startDate { year }
      format
      episodes
      averageScore
      description(asHtml: false)
      coverImage { extraLarge large }
      bannerImage
      siteUrl
    }
  }
}
''';

  /// 搜索关键词 [keyword]（[year] 当前不参与查询，保留与其他源同形的签名）。
  ///
  /// 网络失败 / 非 2xx / JSON 异常 → 抛 [ScrapeNetworkException]。
  Future<List<ScrapeCandidate>> search(String keyword, {int? year}) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse(endpoint),
            headers: const <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, Object?>{
              'query': _query,
              'variables': <String, Object?>{
                'search': keyword,
                'perPage': _perPage,
              },
            }),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const ScrapeNetworkException('AniList search timed out');
    } catch (e) {
      // AniList 无 key，URL 里不含凭据，无需脱敏（对比 tmdb_client 的 key-in-query）。
      throw ScrapeNetworkException('AniList request failed: $e');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ScrapeNetworkException(
        'AniList search HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    return parseAniListResponse(utf8.decode(response.bodyBytes));
  }

  /// 关闭内部 client（若为默认自建）。
  void close() => _client.close();
}

/// 纯函数：解析 AniList GraphQL 响应。缺封面的条目跳过（对封面刮削无用）。
///
/// GraphQL 的错误是 **200 + body.errors**，不是 HTTP 非 2xx —— 只看 statusCode 会把
/// 「查询被拒」当成「零结果」，故此处显式检查 `errors`。
List<ScrapeCandidate> parseAniListResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    throw ScrapeNetworkException('AniList JSON decode failed: $e');
  }
  if (decoded is! Map<String, Object?>) {
    throw const ScrapeNetworkException('AniList response not a JSON object');
  }

  final Object? errors = decoded['errors'];
  if (errors is List<Object?> && errors.isNotEmpty) {
    final Object? first = errors.first;
    final String message = first is Map<String, Object?>
        ? '${first['message'] ?? first}'
        : '$first';
    throw ScrapeNetworkException('AniList GraphQL error: $message');
  }

  final Object? data = decoded['data'];
  if (data is! Map<String, Object?>) return const <ScrapeCandidate>[];
  final Object? page = data['Page'];
  if (page is! Map<String, Object?>) return const <ScrapeCandidate>[];
  final Object? media = page['media'];
  if (media is! List<Object?>) return const <ScrapeCandidate>[];

  final List<ScrapeCandidate> candidates = <ScrapeCandidate>[];
  for (final Object? item in media) {
    if (item is! Map<String, Object?>) continue;
    final ScrapeCandidate? candidate = _mapAniListMedia(item);
    if (candidate != null) candidates.add(candidate);
  }
  return candidates;
}

/// 映射单条 AniList media；缺封面返回 null。
ScrapeCandidate? _mapAniListMedia(Map<String, Object?> media) {
  final Object? coverImage = media['coverImage'];
  final String? posterUrl = coverImage is Map<String, Object?>
      ? _nonEmptyString(coverImage['extraLarge']) ??
          _nonEmptyString(coverImage['large'])
      : null;
  if (posterUrl == null) return null;

  final Object? titleNode = media['title'];
  final String? native = titleNode is Map<String, Object?>
      ? _nonEmptyString(titleNode['native'])
      : null;
  final String? romaji = titleNode is Map<String, Object?>
      ? _nonEmptyString(titleNode['romaji'])
      : null;
  final String? english = titleNode is Map<String, Object?>
      ? _nonEmptyString(titleNode['english'])
      : null;

  // 日文原题优先（本 app 的用户看的是日文原片）；缺则退 romaji → english。
  final String? title = native ?? romaji ?? english;
  if (title == null) return null;

  // 其余标题与 synonyms 全进别名：打分层靠它们跨语言命中文件名里的任意一种写法。
  final List<String> aliases = <String>[];
  for (final String? alt in <String?>[native, romaji, english]) {
    if (alt != null && alt != title && !aliases.contains(alt)) aliases.add(alt);
  }
  final Object? synonyms = media['synonyms'];
  if (synonyms is List<Object?>) {
    for (final Object? synonym in synonyms) {
      final String? value = _nonEmptyString(synonym);
      if (value != null && value != title && !aliases.contains(value)) {
        aliases.add(value);
      }
    }
  }

  final Object? startDate = media['startDate'];
  final int? year =
      startDate is Map<String, Object?> ? _asInt(startDate['year']) : null;

  final int? episodes = _asInt(media['episodes']);

  // averageScore 是 0~100 整数，与其余源的 0~10 不同量纲，必须换算后再展示/存储，
  // 否则同一列表里 AniList 条目会显示成「85 分」而 Bangumi 是「8.1 分」。
  final int? averageScore = _asInt(media['averageScore']);
  final double? rating =
      averageScore != null && averageScore > 0 ? averageScore / 10.0 : null;

  final String entryId = '${media['id']}';

  return ScrapeCandidate(
    source: ScrapeSource.anilist,
    entryId: entryId,
    title: title,
    aliases: aliases,
    year: year,
    type: _mapFormat(_nonEmptyString(media['format'])),
    episodeCount: episodes != null && episodes > 0 ? episodes : null,
    posterUrl: posterUrl,
    // bannerImage 是超宽横幅（约 1900x400），比 2:3 海报更适合详情页 hero 宽槽；
    // 冷门条目常无 banner，故 nullable 而非跳过该候选（BUG-1298 同理）。
    backdropUrl: _nonEmptyString(media['bannerImage']),
    summary: _stripHtml(_nonEmptyString(media['description'])),
    rating: rating,
    detailUrl: _nonEmptyString(media['siteUrl']) ??
        'https://anilist.co/anime/$entryId',
    ratingText: rating != null ? 'AniList ${rating.toStringAsFixed(1)}' : null,
  );
}

/// AniList `format` → 共享条目类型。
///
/// ONA/MUSIC 刻意归 unknown 而非硬塞进某一类：打分层对 unknown 是「不参与类型校验」，
/// 而错误分类会**主动扣分**——宁可不判，不可判错。
ScrapeEntryType _mapFormat(String? format) {
  switch (format) {
    case 'TV':
    case 'TV_SHORT':
      return ScrapeEntryType.tv;
    case 'MOVIE':
      return ScrapeEntryType.movie;
    case 'OVA':
      return ScrapeEntryType.ova;
    case 'SPECIAL':
      return ScrapeEntryType.special;
    default:
      return ScrapeEntryType.unknown;
  }
}

/// 去掉 AniList 简介里的 HTML 标签。
///
/// `description(asHtml: false)` 仍会保留 `<br>` / `<i>` 等内联标签（AniList 的
/// asHtml=false 只是不做 markdown→html 转换，不等于纯文本），直接展示会看到裸标签。
String? _stripHtml(String? value) {
  if (value == null) return null;
  final String text = value
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .trim();
  return text.isEmpty ? null : text;
}

/// 取非空去空白字符串，空/非 String 返回 null。
String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 容错取 int（接受 num 或数字字符串）。
int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}
