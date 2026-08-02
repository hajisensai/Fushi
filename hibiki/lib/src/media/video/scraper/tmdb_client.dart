/// TMDB（The Movie Database）在线搜索客户端 —— 电影 / 日剧的**补充源**（需用户 API key）。
///
/// 端点 `GET /3/search/multi`，用 `language=zh-CN` 拿本地化中文标题；结果只保留
/// `media_type` 为 `tv` / `movie`（滤掉 person）。映射为共享契约 [ScrapeCandidate]。
///
/// 网络异常复用 bangumi_client 定义的 [ScrapeNetworkException]（不重复定义）。
///
/// 代理：`package:http` 默认走 `dart:io` `HttpClient`，尊重进程环境的系统代理设置，
/// 无需自实现代理。**TMDB 在部分地区（含中国大陆）需代理才能访问**——由用户在系统 /
/// 环境层配置代理后本客户端自动继承，本层不做额外处理。
library;

import 'dart:async';
import 'dart:convert';

import 'package:hibiki/src/media/metadata/credential_redaction.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart'
    show ScrapeNetworkException;
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:http/http.dart' as http;

/// TMDB 搜索客户端。构造注入 `apiKey` 与可选 [http.Client]（默认自建）。
class TmdbClient {
  TmdbClient({required String apiKey, http.Client? client})
      : _apiKey = apiKey,
        _client = client ?? http.Client();

  final String _apiKey;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 15);

  /// TMDB 海报基址：`original` = 满分辨率原图（用户要求默认满分辨率，BUG-1082）。
  ///
  /// 旧值 `w500`（500px 宽缩略档）落盘后放大到高 dpr 大格子会发糊。Bangumi(large) /
  /// 离线库(picture) 本就取各源最高档，唯 TMDB 之前钉在缩略档，是刮削海报发糊的根因。
  /// 落盘无损（[CoverDownloader] 原样写字节），渲染层 `resizedFileImage` 解码上限自会
  /// 按需降采样，不会因原图更大而变慢展示。
  static const String posterBase = 'https://image.tmdb.org/t/p/original';

  /// TMDB 横版背景基址（详情页宽幅 hero 用，BUG-1298）。
  ///
  /// 与海报同取 `original`：hero 跨整屏宽，桌面 4K 下物理宽可达 3840px，缩略档
  /// 放上去就是一片糊。落盘无损，渲染层 `resizedFileImage` 自会按需降采样。
  static const String backdropBase = 'https://image.tmdb.org/t/p/original';

  /// 搜索关键词 [keyword]（[year] 仅用于占位/未来精确化，multi 端点本身不接受 year）。
  ///
  /// 网络失败 / 非 2xx / JSON 异常 → 抛 [ScrapeNetworkException]。
  Future<List<ScrapeCandidate>> search(String keyword, {int? year}) async {
    final Uri uri = Uri.parse('https://api.themoviedb.org/3/search/multi')
        .replace(queryParameters: <String, String>{
      'query': keyword,
      'language': 'zh-CN',
      'api_key': _apiKey,
    });

    final http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: const <String, String>{'Accept': 'application/json'},
      ).timeout(_timeout);
    } on TimeoutException {
      throw const ScrapeNetworkException('TMDB search timed out');
    } catch (e) {
      // 🔴 必须脱敏：TMDB 是 key-in-query，而 package:http 的 ClientException
      // 把整个请求 URL（含 api_key）拼进 toString()。这条 message 会同时流向弹窗
      // 失败态（可选中 + 一键复制）、错误日志文件、以及日志上传 —— 三条路都不脱敏。
      // 收口在这里，抛出去的东西本身就不含凭据（BUG-1219 审查发现）。
      throw ScrapeNetworkException(
        redactCredentialsInText('TMDB request failed: $e'),
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ScrapeNetworkException(
        'TMDB search HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    return parseTmdbMultiResponse(utf8.decode(response.bodyBytes));
  }

  /// 拉取 tv 条目详情 `GET /3/tv/{id}`（TODO-2484：季列表作合集「相关作品」；
  /// TODO-2491：确认条目是 tv）。404（条目不存在）→ null。
  ///
  /// 其余网络失败 / 非 2xx / JSON 异常 → 抛 [ScrapeNetworkException]。
  Future<TmdbTvDetail?> fetchTvDetail(String tvId) async {
    final String? body = await _getJsonOrNullOn404('/tv/$tvId', 'TMDB tv');
    return body == null ? null : parseTmdbTvDetail(body);
  }

  /// 拉取 tv 某一季的分集列表 `GET /3/tv/{id}/season/{n}`（TODO-2491 集级
  /// 刮削）。404（该季不存在）→ 空列表（调用方按「源无此季」计未匹配）。
  Future<List<TmdbEpisodeInfo>> fetchSeasonEpisodes(
    String tvId,
    int seasonNumber,
  ) async {
    final String? body = await _getJsonOrNullOn404(
        '/tv/$tvId/season/$seasonNumber', 'TMDB season');
    return body == null
        ? const <TmdbEpisodeInfo>[]
        : parseTmdbSeasonEpisodes(body);
  }

  /// 拉取 movie 条目的所属系列引用 `GET /3/movie/{id}` 的
  /// `belongs_to_collection`（TODO-2484）。条目 404 或不属于任何系列 → null。
  Future<TmdbMovieCollectionRef?> fetchMovieCollectionRef(
    String movieId,
  ) async {
    final String? body =
        await _getJsonOrNullOn404('/movie/$movieId', 'TMDB movie');
    return body == null ? null : parseTmdbMovieCollectionRef(body);
  }

  /// 拉取 TMDB 系列（collection）的成员列表 `GET /3/collection/{id}`
  /// （TODO-2484：movie 合集的「相关作品」）。404 → 空列表。
  Future<List<TmdbCollectionPart>> fetchCollectionParts(
    String tmdbCollectionId,
  ) async {
    final String? body = await _getJsonOrNullOn404(
        '/collection/$tmdbCollectionId', 'TMDB collection');
    return body == null
        ? const <TmdbCollectionPart>[]
        : parseTmdbCollectionParts(body);
  }

  /// 拉取条目图组 `GET /3/{tv|movie}/{id}/images`（Jellyfin 图组对齐）：多张
  /// 无字 backdrop + 带字横图（titleCard）+ 标题 logo。404 / 全空 → 空图组。
  ///
  /// `include_image_language` 必须显式给：`/images` 端点不受 `language` 参数的
  /// 兜底逻辑保护，只传 `language=zh-CN` 会把无语言字段的无字横图全部滤掉。
  Future<TmdbImageSet> fetchImageSet({
    required String entryId,
    required bool isTv,
  }) async {
    final String kind = isTv ? 'tv' : 'movie';
    final Uri uri =
        Uri.parse('https://api.themoviedb.org/3/$kind/$entryId/images')
            .replace(queryParameters: <String, String>{
      'include_image_language': 'zh,ja,en,null',
      'api_key': _apiKey,
    });
    final http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: const <String, String>{'Accept': 'application/json'},
      ).timeout(_timeout);
    } on TimeoutException {
      throw const ScrapeNetworkException('TMDB images timed out');
    } catch (e) {
      throw ScrapeNetworkException(
        redactCredentialsInText('TMDB images request failed: $e'),
      );
    }
    if (response.statusCode == 404) return const TmdbImageSet();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ScrapeNetworkException(
        'TMDB images HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    return parseTmdbImageSet(utf8.decode(response.bodyBytes));
  }

  /// 共享 GET：`https://api.themoviedb.org/3<path>?language=zh-CN&api_key=…`。
  /// 404 返回 null（各端点自定语义）；其余非 2xx / 网络失败抛
  /// [ScrapeNetworkException]。异常 message 统一 [redactCredentialsInText]
  /// 脱敏——TMDB 是 key-in-query，`http.ClientException.toString()` 会带完整
  /// URL（BUG-1219 红线，与 [search] 同源收口）。
  Future<String?> _getJsonOrNullOn404(String path, String what) async {
    final Uri uri = Uri.parse('https://api.themoviedb.org/3$path')
        .replace(queryParameters: <String, String>{
      'language': 'zh-CN',
      'api_key': _apiKey,
    });
    final http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: const <String, String>{'Accept': 'application/json'},
      ).timeout(_timeout);
    } on TimeoutException {
      throw ScrapeNetworkException('$what timed out');
    } catch (e) {
      throw ScrapeNetworkException(
        redactCredentialsInText('$what request failed: $e'),
      );
    }
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ScrapeNetworkException(
        '$what HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    return utf8.decode(response.bodyBytes);
  }

  /// 关闭内部 client（若为默认自建）。
  void close() => _client.close();
}

/// TMDB 条目种类（tv / movie）。合集绑定的 subjectId 是纯数字，两个 id 空间
/// 独立且会撞号，必须由 [tmdbKindFromDetailUrl]（detailUrl 里带 `/tv/` 或
/// `/movie/`）或调用方上下文判定，不能按 id 猜。
enum TmdbSubjectKind { tv, movie }

/// 纯函数：从 TMDB detailUrl（`https://www.themoviedb.org/tv/123` 式）解析
/// 条目种类；不是 TMDB 详情 URL → null。
TmdbSubjectKind? tmdbKindFromDetailUrl(String? detailUrl) {
  if (detailUrl == null) return null;
  final Uri? uri = Uri.tryParse(detailUrl.trim());
  if (uri == null || !uri.host.endsWith('themoviedb.org')) return null;
  final List<String> segments = uri.pathSegments;
  if (segments.isEmpty) return null;
  return switch (segments.first) {
    'tv' => TmdbSubjectKind.tv,
    'movie' => TmdbSubjectKind.movie,
    _ => null,
  };
}

/// TMDB tv 详情投影：季列表（TODO-2484 相关作品用）。
class TmdbTvDetail {
  const TmdbTvDetail({required this.name, required this.seasons});

  final String? name;
  final List<TmdbSeasonRef> seasons;
}

/// TMDB tv 的一季。
class TmdbSeasonRef {
  const TmdbSeasonRef({
    required this.seasonId,
    required this.seasonNumber,
    required this.name,
    this.airDate,
    this.posterPath,
  });

  /// 季自身的 TMDB id（全局唯一，与 tv id 不同空间），字符串化。
  final String seasonId;

  /// 季号（0 = 特别篇）。
  final int seasonNumber;

  final String name;
  final String? airDate;
  final String? posterPath;
}

/// TMDB 分集（`/3/tv/{id}/season/{n}` 的 `episodes[]` 投影）。
class TmdbEpisodeInfo {
  const TmdbEpisodeInfo({
    required this.episodeNumber,
    this.title,
    this.summary,
    this.airDate,
    this.stillPath,
  });

  final int episodeNumber;
  final String? title;
  final String? summary;
  final String? airDate;

  /// 剧照相对路径（`/xxx.jpg`），完整 URL = [TmdbClient.posterBase] + 本值。
  final String? stillPath;
}

/// TMDB movie 的所属系列引用（`belongs_to_collection`）。
class TmdbMovieCollectionRef {
  const TmdbMovieCollectionRef({required this.collectionId, this.name});

  /// TMDB collection id，字符串化。
  final String collectionId;
  final String? name;
}

/// TMDB 系列成员（`/3/collection/{id}` 的 `parts[]` 投影）。
class TmdbCollectionPart {
  const TmdbCollectionPart({
    required this.movieId,
    required this.title,
    this.releaseDate,
    this.posterPath,
  });

  /// 成员 movie id，字符串化。
  final String movieId;
  final String title;
  final String? releaseDate;
  final String? posterPath;
}

/// 纯函数：解析 `/3/tv/{id}` 响应为 [TmdbTvDetail]。JSON 结构异常 → 抛
/// [ScrapeNetworkException]。
TmdbTvDetail parseTmdbTvDetail(String body) {
  final Map<String, Object?> decoded = _decodeObject(body, 'TMDB tv');
  final List<TmdbSeasonRef> seasons = <TmdbSeasonRef>[];
  final Object? seasonsNode = decoded['seasons'];
  if (seasonsNode is List<Object?>) {
    for (final Object? item in seasonsNode) {
      if (item is! Map<String, Object?>) continue;
      final Object? id = item['id'];
      final Object? number = item['season_number'];
      final String? name = _nonEmptyString(item['name']);
      if (id is! int || number is! int || name == null) continue;
      seasons.add(TmdbSeasonRef(
        seasonId: '$id',
        seasonNumber: number,
        name: name,
        airDate: _nonEmptyString(item['air_date']),
        posterPath: _nonEmptyString(item['poster_path']),
      ));
    }
  }
  return TmdbTvDetail(name: _nonEmptyString(decoded['name']), seasons: seasons);
}

/// 纯函数：解析 `/3/tv/{id}/season/{n}` 响应的分集列表。缺 `episode_number`
/// 的项跳过。JSON 结构异常 → 抛 [ScrapeNetworkException]。
List<TmdbEpisodeInfo> parseTmdbSeasonEpisodes(String body) {
  final Map<String, Object?> decoded = _decodeObject(body, 'TMDB season');
  final Object? episodesNode = decoded['episodes'];
  final List<TmdbEpisodeInfo> episodes = <TmdbEpisodeInfo>[];
  if (episodesNode is List<Object?>) {
    for (final Object? item in episodesNode) {
      if (item is! Map<String, Object?>) continue;
      final Object? number = item['episode_number'];
      if (number is! int || number <= 0) continue;
      episodes.add(TmdbEpisodeInfo(
        episodeNumber: number,
        title: _nonEmptyString(item['name']),
        summary: _nonEmptyString(item['overview']),
        airDate: _nonEmptyString(item['air_date']),
        stillPath: _nonEmptyString(item['still_path']),
      ));
    }
  }
  return episodes;
}

/// 纯函数：从 `/3/movie/{id}` 响应取 `belongs_to_collection`；不属于任何系列
/// → null。JSON 结构异常 → 抛 [ScrapeNetworkException]。
TmdbMovieCollectionRef? parseTmdbMovieCollectionRef(String body) {
  final Map<String, Object?> decoded = _decodeObject(body, 'TMDB movie');
  final Object? node = decoded['belongs_to_collection'];
  if (node is! Map<String, Object?>) return null;
  final Object? id = node['id'];
  if (id is! int) return null;
  return TmdbMovieCollectionRef(
    collectionId: '$id',
    name: _nonEmptyString(node['name']),
  );
}

/// 纯函数：解析 `/3/collection/{id}` 响应的成员电影列表。缺 id/标题的项跳过。
/// JSON 结构异常 → 抛 [ScrapeNetworkException]。
List<TmdbCollectionPart> parseTmdbCollectionParts(String body) {
  final Map<String, Object?> decoded = _decodeObject(body, 'TMDB collection');
  final Object? partsNode = decoded['parts'];
  final List<TmdbCollectionPart> parts = <TmdbCollectionPart>[];
  if (partsNode is List<Object?>) {
    for (final Object? item in partsNode) {
      if (item is! Map<String, Object?>) continue;
      final Object? id = item['id'];
      final String? title = _nonEmptyString(item['title']);
      if (id is! int || title == null) continue;
      parts.add(TmdbCollectionPart(
        movieId: '$id',
        title: title,
        releaseDate: _nonEmptyString(item['release_date']),
        posterPath: _nonEmptyString(item['poster_path']),
      ));
    }
  }
  return parts;
}

/// TMDB `/images` 端点的分类产物（完整 URL）。
///
/// 分类规则抄 Jellyfin（`TmdbClientManager.ConvertToRemoteImageInfo`）：
/// * `backdrops[]` 里 **`iso_639_1` 为空**的 → 无字横版背景 [backdropUrls]
///   （全屏背景/轮换槽，永远不该有烧死的片名文字）；
/// * `backdrops[]` 里 **带语言**的 → 带字横图 [titleCardUrl]（Jellyfin 把它降级
///   归类为 Thumb——横版卡片槽用它，与全屏背景分开）；
/// * `logos[]` → [logoUrl]，跳过 SVG（Flutter Image 不解码矢量）。
class TmdbImageSet {
  const TmdbImageSet({
    this.backdropUrls = const <String>[],
    this.titleCardUrl,
    this.logoUrl,
  });

  final List<String> backdropUrls;
  final String? titleCardUrl;
  final String? logoUrl;

  bool get isEmpty =>
      backdropUrls.isEmpty && titleCardUrl == null && logoUrl == null;
}

/// 无字 backdrop 最多取几张（详情页 10 秒轮换用；TMDB 响应按 vote 降序，取前 N
/// 即最受认可的 N 张。上限防冷门条目也把几十张全下到用户磁盘上）。
const int kTmdbMaxBackdrops = 3;

/// 语言偏好序（logo / 带字横图挑选用）：中文界面标题优先，其次日文原题、英文。
const List<String> _kTmdbImageLanguagePreference = <String>['zh', 'ja', 'en'];

/// 纯函数：解析 `/3/{tv|movie}/{id}/images` 响应并按 Jellyfin 规则分类。
/// JSON 结构异常 → 抛 [ScrapeNetworkException]。
TmdbImageSet parseTmdbImageSet(String body) {
  final Map<String, Object?> decoded = _decodeObject(body, 'TMDB images');

  List<Map<String, Object?>> itemsOf(String key) {
    final Object? node = decoded[key];
    if (node is! List<Object?>) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final Object? item in node)
        if (item is Map<String, Object?> &&
            _nonEmptyString(item['file_path']) != null)
          item,
    ];
  }

  // 带语言序号的挑选：偏好序里最靠前的语言组第一张（组内沿用响应的 vote 降序）。
  String? pickByLanguage(List<Map<String, Object?>> items) {
    for (final String lang in _kTmdbImageLanguagePreference) {
      for (final Map<String, Object?> item in items) {
        if (_nonEmptyString(item['iso_639_1']) == lang) {
          return _nonEmptyString(item['file_path']);
        }
      }
    }
    return items.isEmpty ? null : _nonEmptyString(items.first['file_path']);
  }

  final List<String> backdrops = <String>[];
  final List<Map<String, Object?>> titled = <Map<String, Object?>>[];
  for (final Map<String, Object?> item in itemsOf('backdrops')) {
    if (_nonEmptyString(item['iso_639_1']) == null) {
      if (backdrops.length < kTmdbMaxBackdrops) {
        backdrops.add('${TmdbClient.backdropBase}${item['file_path']}');
      }
    } else {
      titled.add(item);
    }
  }
  final String? titleCardPath = pickByLanguage(titled);

  final List<Map<String, Object?>> logos = <Map<String, Object?>>[
    for (final Map<String, Object?> item in itemsOf('logos'))
      // SVG 跳过：Flutter Image 不解码矢量；TMDB logo 常见 png/svg 混排。
      if (!(_nonEmptyString(item['file_path']) ?? '')
          .toLowerCase()
          .endsWith('.svg'))
        item,
  ];
  final String? logoPath = pickByLanguage(logos);

  return TmdbImageSet(
    backdropUrls: backdrops,
    titleCardUrl: titleCardPath == null
        ? null
        : '${TmdbClient.backdropBase}$titleCardPath',
    logoUrl: logoPath == null ? null : '${TmdbClient.posterBase}$logoPath',
  );
}

/// 解 JSON 顶层对象；非对象/解码失败 → 抛 [ScrapeNetworkException]。
Map<String, Object?> _decodeObject(String body, String what) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    throw ScrapeNetworkException('$what JSON decode failed: $e');
  }
  if (decoded is! Map<String, Object?>) {
    throw ScrapeNetworkException('$what response not a JSON object');
  }
  return decoded;
}

/// 纯函数：解析 TMDB `/search/multi` 响应，滤掉非 tv/movie，缺 poster_path 跳过。
///
/// JSON 结构异常 → 抛 [ScrapeNetworkException]。
List<ScrapeCandidate> parseTmdbMultiResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    throw ScrapeNetworkException('TMDB JSON decode failed: $e');
  }
  if (decoded is! Map<String, Object?>) {
    throw const ScrapeNetworkException('TMDB response not a JSON object');
  }
  final Object? results = decoded['results'];
  if (results is! List<Object?>) return const <ScrapeCandidate>[];

  final List<ScrapeCandidate> candidates = <ScrapeCandidate>[];
  for (final Object? item in results) {
    if (item is! Map<String, Object?>) continue;
    final ScrapeCandidate? candidate = _mapTmdbResult(item);
    if (candidate != null) candidates.add(candidate);
  }
  return candidates;
}

/// 映射单条 TMDB multi 结果；非 tv/movie 或缺 poster_path 返回 null。
ScrapeCandidate? _mapTmdbResult(Map<String, Object?> result) {
  final String? mediaType = _nonEmptyString(result['media_type']);
  if (mediaType != 'tv' && mediaType != 'movie') return null; // 滤掉 person 等

  final String? posterPath = _nonEmptyString(result['poster_path']);
  if (posterPath == null) return null; // 无海报对封面刮削无用，跳过。

  // tv 用 name / original_name；movie 用 title / original_title。
  final bool isTv = mediaType == 'tv';
  final String? title =
      isTv ? _nonEmptyString(result['name']) : _nonEmptyString(result['title']);
  if (title == null) return null;

  final String? original = isTv
      ? _nonEmptyString(result['original_name'])
      : _nonEmptyString(result['original_title']);
  final List<String> aliases = <String>[];
  if (original != null && original != title) aliases.add(original);

  final int? year = _yearFromDate(isTv
      ? _nonEmptyString(result['first_air_date'])
      : _nonEmptyString(result['release_date']));

  final ScrapeEntryType type =
      isTv ? ScrapeEntryType.tv : ScrapeEntryType.movie;

  final double vote = _asDouble(result['vote_average']) ?? 0.0;
  final String? ratingText =
      vote > 0 ? 'TMDB ${vote.toStringAsFixed(1)}' : null;
  final Object? voteCount = result['vote_count'];

  // 横版背景：TMDB 搜索响应本就带 `backdrop_path`，此前整条被丢弃 —— 详情页宽幅
  // hero 于是只能拿 2:3 海报硬撑，被裁成中间一条（BUG-1298）。缺失是常态（冷门
  // 条目常无背景图），故 nullable 而非跳过该候选：海报才是刮削的必需品。
  final String? backdropPath = _nonEmptyString(result['backdrop_path']);

  final String entryId = '${result['id']}';

  return ScrapeCandidate(
    source: ScrapeSource.tmdb,
    entryId: entryId,
    title: title,
    aliases: aliases,
    year: year,
    type: type,
    posterUrl: '${TmdbClient.posterBase}$posterPath',
    backdropUrl:
        backdropPath == null ? null : '${TmdbClient.backdropBase}$backdropPath',
    // TMDB 没有独立详情端点接入本流水线，搜索响应里的 overview 是它简介的唯一
    // 来源；丢在这里就等于 TMDB 刮出来的条目永远没有简介。
    summary: _nonEmptyString(result['overview']),
    rating: vote > 0 ? vote : null,
    ratingCount: voteCount is num && voteCount > 0 ? voteCount.toInt() : null,
    detailUrl: 'https://www.themoviedb.org/$mediaType/$entryId',
    ratingText: ratingText,
  );
}

/// 从 `YYYY-MM-DD` 取年份，非法返回 null。
int? _yearFromDate(String? date) {
  if (date == null || date.length < 4) return null;
  return int.tryParse(date.substring(0, 4));
}

/// 取非空去空白字符串，空/非 String 返回 null。
String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 容错取 double（接受 num 或数字字符串）。
double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}
