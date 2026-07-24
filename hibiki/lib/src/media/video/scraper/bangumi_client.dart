/// Bangumi（番组计划）在线搜索客户端 —— 视频海报刮削匹配层的**主源**（免 API key）。
///
/// 端点 `POST /v0/search/subjects`，只搜动画（`filter.type = [2]`）。响应条目映射为
/// 共享契约 [ScrapeCandidate]（见 `scraper_types.dart`，本文件**只 import 不修改**）。
///
/// 本文件同时定义跨刮削层共享的网络异常 [ScrapeNetworkException]（tmdb_client /
/// offline_db_downloader / poster_downloader 均从这里 import，不重复定义）。
///
/// 代理：`package:http` 默认走 `dart:io` 的 `HttpClient`，会尊重进程环境里的系统代理
/// 设置（`HTTP_PROXY` / `HTTPS_PROXY` / 平台系统代理），无需自实现代理配置。Bangumi
/// 在中国大陆一般可直连；若用户所在网络不通，交由外层代理生效即可。
library;

import 'dart:async';
import 'dart:convert';

import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:http/http.dart' as http;

/// 刮削层统一网络异常：网络失败 / 非 2xx / JSON 解析异常时抛出，**绝不吞异常**，
/// 由上层 service 负责降级（换源或保留抽帧）。
class ScrapeNetworkException implements Exception {
  const ScrapeNetworkException(this.message, {this.statusCode});

  /// 英文技术描述（本层不含用户可见 UI 字符串）。
  final String message;

  /// HTTP 状态码（非 2xx 时带上），网络/解析异常时为 null。
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'ScrapeNetworkException: $message'
      : 'ScrapeNetworkException($statusCode): $message';
}

/// Bangumi 搜索客户端。构造函数注入 [http.Client]（默认自建），测试用 mock client。
class BangumiClient {
  BangumiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Bangumi API 要求可识别的 User-Agent（否则可能被限流/拒绝）。
  static const String _userAgent =
      'hibiki-reader/scraper (https://github.com/hajisensai)';

  static const Duration _timeout = Duration(seconds: 15);

  /// 搜索关键词 [keyword]，返回动画候选（最多 [limit] 条）。
  ///
  /// 网络失败 / 非 2xx / JSON 异常 → 抛 [ScrapeNetworkException]。
  Future<List<ScrapeCandidate>> search(String keyword, {int limit = 10}) async {
    final Uri uri = Uri.parse('https://api.bgm.tv/v0/search/subjects')
        .replace(queryParameters: <String, String>{'limit': '$limit'});
    final String requestBody = jsonEncode(<String, Object?>{
      'keyword': keyword,
      'filter': <String, Object?>{
        'type': <int>[2], // 2 = 动画
      },
    });

    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: const <String, String>{
              'User-Agent': _userAgent,
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: requestBody,
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const ScrapeNetworkException('Bangumi search timed out');
    } catch (e) {
      throw ScrapeNetworkException('Bangumi request failed: $e');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ScrapeNetworkException(
        'Bangumi search HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    // 服务器返回的是 utf8 原始字节；用 bodyBytes 走 utf8 解码，避免 http.Response.body
    // 在缺 charset 时按 latin1 解码毁掉中日文。
    return parseBangumiSearchResponse(utf8.decode(response.bodyBytes));
  }

  /// 关闭内部 client（若为默认自建）。测试注入的 mock client 由调用方自行管理。
  void close() => _client.close();
}

/// 纯函数：把 Bangumi `/v0/search/subjects` 响应体解析为候选列表。
///
/// 抽出为顶层纯函数便于单测（无需 mock 网络）。JSON 结构异常 → 抛
/// [ScrapeNetworkException]（与网络失败同类，交上层降级）。
List<ScrapeCandidate> parseBangumiSearchResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    throw ScrapeNetworkException('Bangumi JSON decode failed: $e');
  }
  if (decoded is! Map<String, Object?>) {
    throw const ScrapeNetworkException('Bangumi response not a JSON object');
  }
  final Object? data = decoded['data'];
  if (data is! List<Object?>) {
    // 无 data 数组（如错误负载）当作空结果，而非异常：搜索无命中是正常情况。
    return const <ScrapeCandidate>[];
  }

  final List<ScrapeCandidate> candidates = <ScrapeCandidate>[];
  for (final Object? item in data) {
    if (item is! Map<String, Object?>) continue;
    final ScrapeCandidate? candidate = _mapBangumiSubject(item);
    if (candidate != null) candidates.add(candidate);
  }
  return candidates;
}

/// 把单个 Bangumi subject 映射为 [ScrapeCandidate]；缺海报（large/common 皆无）返回 null。
ScrapeCandidate? _mapBangumiSubject(Map<String, Object?> subject) {
  final Object? images = subject['images'];
  String? posterUrl;
  if (images is Map<String, Object?>) {
    posterUrl =
        _nonEmptyString(images['large']) ?? _nonEmptyString(images['common']);
  }
  if (posterUrl == null) return null; // 无海报的条目对封面刮削无用，跳过。

  final String? nameCn = _nonEmptyString(subject['name_cn']);
  final String? name = _nonEmptyString(subject['name']);
  // title 优先 name_cn，非空否则 name；两者皆空则跳过（无可展示标题）。
  final String? title = nameCn ?? name;
  if (title == null) return null;

  // aliases 收「另一个名字」：title 用了 name_cn 就收 name，反之收 name_cn。
  final List<String> aliases = <String>[];
  final String? other = identical(title, nameCn) ? name : nameCn;
  if (other != null && other != title) aliases.add(other);

  final int? year = _yearFromDate(_nonEmptyString(subject['date']));
  final ScrapeEntryType type = _typeFromPlatform(subject['platform']);

  final int rawEps = _asInt(subject['eps']) ?? 0;
  final int? episodeCount = rawEps > 0 ? rawEps : null;

  final double score = _asDouble(subject['score']) ?? 0.0;
  final String? ratingText = score > 0 ? 'Bangumi $score' : null;

  final String entryId = '${subject['id']}';

  return ScrapeCandidate(
    source: ScrapeSource.bangumi,
    entryId: entryId,
    title: title,
    aliases: aliases,
    year: year,
    type: type,
    episodeCount: episodeCount,
    posterUrl: posterUrl,
    detailUrl: 'https://bgm.tv/subject/$entryId',
    ratingText: ratingText,
  );
}

/// 由 Bangumi `platform` 字段推断条目类型。
ScrapeEntryType _typeFromPlatform(Object? platform) {
  if (platform is! String) return ScrapeEntryType.unknown;
  final String p = platform.trim();
  if (p.contains('剧场版') || p.toLowerCase().contains('movie')) {
    return ScrapeEntryType.movie;
  }
  if (p == 'TV') return ScrapeEntryType.tv;
  if (p.toUpperCase().contains('OVA')) return ScrapeEntryType.ova;
  return ScrapeEntryType.unknown;
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

/// 容错取 int（接受 int 或数字字符串）。
int? _asInt(Object? value) {
  if (value is int) return value;
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
