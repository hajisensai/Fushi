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

  /// 关闭内部 client（若为默认自建）。
  void close() => _client.close();
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
