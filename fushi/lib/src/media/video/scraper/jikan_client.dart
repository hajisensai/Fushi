/// Jikan（MyAnimeList 非官方 API）搜索客户端 —— 动画的**补充源**（零 key 门槛）。
///
/// 端点 `GET https://api.jikan.moe/v4/anime`，无需注册、无需 key。与 AniList 的关系
/// 是互补而非重复：MAL 的条目粒度、别名（`titles[]` 含 Synonym/Japanese/English）和
/// 收录范围与 AniList 不完全一致，冷门作品常一方有一方无。
///
/// 限流：Jikan 公开限速约 3 req/s、60 req/min。本客户端**不自实现限流**——聚合搜索
/// 每次只发 1 个请求，批量刮削已由上层逐层兜底（命中 high 就不会走到这一源）。
///
/// 网络异常复用 bangumi_client 定义的 [ScrapeNetworkException]（不重复定义）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/media/video/scraper/bangumi_client.dart'
    show ScrapeNetworkException;
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:http/http.dart' as http;

/// Jikan 搜索客户端。构造可注入 [http.Client]（默认自建）。
class JikanClient {
  JikanClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 15);

  /// 单次搜索返回条数上限，与 AniList/Bangumi 量级对齐。
  static const int _limit = 15;

  /// 搜索关键词 [keyword]（[year] 当前不参与查询，保留与其他源同形的签名）。
  ///
  /// 网络失败 / 非 2xx / JSON 异常 → 抛 [ScrapeNetworkException]。
  Future<List<ScrapeCandidate>> search(String keyword, {int? year}) async {
    final Uri uri = Uri.parse('https://api.jikan.moe/v4/anime')
        .replace(queryParameters: <String, String>{
      'q': keyword,
      'limit': '$_limit',
      // sfw：滤掉成人向条目。刮削是给用户的媒体库配图，默认不该往里塞 R18 海报。
      'sfw': 'true',
    });

    final http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: const <String, String>{'Accept': 'application/json'},
      ).timeout(_timeout);
    } on TimeoutException {
      throw const ScrapeNetworkException('Jikan search timed out');
    } catch (e) {
      // Jikan 无 key，URL 里不含凭据，无需脱敏（对比 tmdb_client 的 key-in-query）。
      throw ScrapeNetworkException('Jikan request failed: $e');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ScrapeNetworkException(
        'Jikan search HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    return parseJikanResponse(utf8.decode(response.bodyBytes));
  }

  /// 关闭内部 client（若为默认自建）。
  void close() => _client.close();
}

/// 纯函数：解析 Jikan `/v4/anime` 响应。缺封面的条目跳过（对封面刮削无用）。
List<ScrapeCandidate> parseJikanResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    throw ScrapeNetworkException('Jikan JSON decode failed: $e');
  }
  if (decoded is! Map<String, Object?>) {
    throw const ScrapeNetworkException('Jikan response not a JSON object');
  }
  final Object? data = decoded['data'];
  if (data is! List<Object?>) return const <ScrapeCandidate>[];

  final List<ScrapeCandidate> candidates = <ScrapeCandidate>[];
  for (final Object? item in data) {
    if (item is! Map<String, Object?>) continue;
    final ScrapeCandidate? candidate = _mapJikanAnime(item);
    if (candidate != null) candidates.add(candidate);
  }
  return candidates;
}

/// 映射单条 Jikan anime；缺封面返回 null。
ScrapeCandidate? _mapJikanAnime(Map<String, Object?> anime) {
  final String? posterUrl = _posterFrom(anime['images']);
  if (posterUrl == null) return null;

  // 日文原题优先（本 app 的用户看的是日文原片）；缺则退默认 title（罗马音）。
  final String? japanese = _nonEmptyString(anime['title_japanese']);
  final String? romaji = _nonEmptyString(anime['title']);
  final String? english = _nonEmptyString(anime['title_english']);
  final String? title = japanese ?? romaji ?? english;
  if (title == null) return null;

  final List<String> aliases = <String>[];
  void addAlias(String? value) {
    if (value == null || value == title || aliases.contains(value)) return;
    aliases.add(value);
  }

  addAlias(japanese);
  addAlias(romaji);
  addAlias(english);
  // `titles[]` 是 MAL 的全量标题表（Default / Japanese / English / Synonym），别名
  // 命中率主要靠它——文件名里常见的是 Synonym 而不是任何一个主标题。
  final Object? titles = anime['titles'];
  if (titles is List<Object?>) {
    for (final Object? entry in titles) {
      if (entry is! Map<String, Object?>) continue;
      addAlias(_nonEmptyString(entry['title']));
    }
  }

  final int? episodes = _asInt(anime['episodes']);
  final double? score = _asDouble(anime['score']);
  final int? scoredBy = _asInt(anime['scored_by']);
  final int malId = _asInt(anime['mal_id']) ?? 0;
  if (malId <= 0) return null;

  return ScrapeCandidate(
    source: ScrapeSource.jikan,
    entryId: '$malId',
    title: title,
    aliases: aliases,
    year: _yearFrom(anime['aired']),
    type: _mapType(_nonEmptyString(anime['type'])),
    episodeCount: episodes != null && episodes > 0 ? episodes : null,
    posterUrl: posterUrl,
    // MAL 没有横版背景图，backdropUrl 恒 null：详情页 hero 会回落到其它源/抽帧，
    // 不编造一张不存在的图（BUG-1298 的教训是宁可没有也不要塞 2:3 海报进宽槽）。
    summary: _nonEmptyString(anime['synopsis']),
    rating: score != null && score > 0 ? score : null,
    ratingCount: scoredBy != null && scoredBy > 0 ? scoredBy : null,
    detailUrl:
        _nonEmptyString(anime['url']) ?? 'https://myanimelist.net/anime/$malId',
    ratingText:
        score != null && score > 0 ? 'MAL ${score.toStringAsFixed(1)}' : null,
  );
}

/// 从 `images` 取最高档海报：`jpg.large_image_url` → `jpg.image_url` → webp 同名。
String? _posterFrom(Object? images) {
  if (images is! Map<String, Object?>) return null;
  for (final String format in <String>['jpg', 'webp']) {
    final Object? node = images[format];
    if (node is! Map<String, Object?>) continue;
    final String? url = _nonEmptyString(node['large_image_url']) ??
        _nonEmptyString(node['image_url']);
    if (url != null) return url;
  }
  return null;
}

/// 从 `aired.from`（ISO8601）取年份。
int? _yearFrom(Object? aired) {
  if (aired is! Map<String, Object?>) return null;
  final String? from = _nonEmptyString(aired['from']);
  if (from == null || from.length < 4) return null;
  return int.tryParse(from.substring(0, 4));
}

/// MAL `type` → 共享条目类型。
///
/// ONA/Music 归 unknown 而非硬塞：打分层对 unknown 是「不参与类型校验」，错误分类会
/// **主动扣分**——宁可不判，不可判错（与 anilist_client 同一取舍）。
ScrapeEntryType _mapType(String? type) {
  switch (type) {
    case 'TV':
      return ScrapeEntryType.tv;
    case 'Movie':
      return ScrapeEntryType.movie;
    case 'OVA':
      return ScrapeEntryType.ova;
    case 'Special':
      return ScrapeEntryType.special;
    default:
      return ScrapeEntryType.unknown;
  }
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

/// 容错取 double（接受 num 或数字字符串）。
double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}
