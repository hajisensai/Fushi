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

import 'dart:convert';

import 'package:hibiki/src/media/metadata/bangumi_api_client.dart';
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
///
/// 传输层（URL / 请求头 / 超时 / utf8 解码 / 传输异常边界）现由跨媒体共享的
/// [BangumiApiClient] 承担；本类只保留「动画（type=2）」语义 + `ScrapeCandidate` /
/// `ScrapeMetadata` 领域映射 + `ScrapeNetworkException` 异常契约。
class BangumiClient {
  BangumiClient({http.Client? client})
      : _api = BangumiApiClient(client: client, userAgent: _userAgent);

  final BangumiApiClient _api;

  /// Bangumi API 要求可识别的 User-Agent（否则可能被限流/拒绝）。
  static const String _userAgent =
      'hibiki-reader/scraper (https://github.com/hajisensai)';

  /// 搜索关键词 [keyword]，返回动画候选（最多 [limit] 条）。
  ///
  /// 网络失败 / 非 2xx / JSON 异常 → 抛 [ScrapeNetworkException]。
  Future<List<ScrapeCandidate>> search(String keyword, {int limit = 10}) async {
    final BangumiRawResponse response;
    try {
      response = await _api.searchSubjects(
        keyword,
        subjectType: kBangumiSubjectTypeAnime,
        limit: limit,
      );
    } on BangumiTransportException catch (e) {
      throw ScrapeNetworkException('Bangumi search ${e.message}');
    }

    if (!response.isOk) {
      throw ScrapeNetworkException(
        'Bangumi search HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    return parseBangumiSearchResponse(response.body);
  }

  /// 拉取条目详情 `GET /v0/subjects/{id}`，返回条目级资料（简介/评分/放送/话数/
  /// 标签/infobox）。
  ///
  /// 为什么要第二次请求：搜索端点 `/v0/search/subjects` **不返回** summary / tags /
  /// infobox / rating.total，只有详情端点有。匹配定案后才对**唯一**一个 id 拉详情，
  /// 而不是对每条搜索候选都拉（那会把 1 次请求放大成 10 次）。
  ///
  /// 网络失败 / 非 2xx / JSON 异常 → 抛 [ScrapeNetworkException]；404（条目不存在
  /// 或被删）同样走异常，由上层降级为「只有封面没有资料」。
  Future<ScrapeMetadata> fetchSubject(String subjectId) async {
    final BangumiRawResponse response;
    try {
      response = await _api.fetchSubject(subjectId);
    } on BangumiTransportException catch (e) {
      throw ScrapeNetworkException('Bangumi subject ${e.message}');
    }

    if (!response.isOk) {
      throw ScrapeNetworkException(
        'Bangumi subject HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    return parseBangumiSubjectResponse(response.body);
  }

  /// 关闭内部 client（若为默认自建）。测试注入的 mock client 由调用方自行管理。
  void close() => _api.close();
}

/// 纯函数：把 Bangumi `/v0/subjects/{id}` 响应体解析为 [ScrapeMetadata]。
///
/// 抽为顶层纯函数便于单测（无需 mock 网络）。JSON 结构异常 / 缺标题 → 抛
/// [ScrapeNetworkException]（与网络失败同类，交上层降级）。
ScrapeMetadata parseBangumiSubjectResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    throw ScrapeNetworkException('Bangumi subject JSON decode failed: $e');
  }
  if (decoded is! Map<String, Object?>) {
    throw const ScrapeNetworkException('Bangumi subject not a JSON object');
  }

  final String? nameCn = _nonEmptyString(decoded['name_cn']);
  final String? name = _nonEmptyString(decoded['name']);
  final String? title = nameCn ?? name;
  if (title == null) {
    throw const ScrapeNetworkException('Bangumi subject has no usable title');
  }
  // 原名只在与主标题不同时才留（主标题已用了 name 时留 null，不自我重复）。
  final String? originalTitle = (name != null && name != title) ? name : null;

  // 评分：`rating.score` / `rating.total`（total = 评分人数，非 count 直方图）。
  double? rating;
  int? ratingCount;
  final Object? ratingNode = decoded['rating'];
  if (ratingNode is Map<String, Object?>) {
    final double? score = _asDouble(ratingNode['score']);
    // 0 分 = 「暂无评分」，不是真的 0 分，按缺失处理。
    if (score != null && score > 0) rating = score;
    final int? total = _asInt(ratingNode['total']);
    if (total != null && total > 0) ratingCount = total;
  }

  // 话数：`total_episodes` 优先（含 SP 的完整集数），回退 `eps`。
  final int totalEps = _asInt(decoded['total_episodes']) ?? 0;
  final int rawEps = _asInt(decoded['eps']) ?? 0;
  final int episodes = totalEps > 0 ? totalEps : rawEps;

  final List<ScrapeTag> tags = <ScrapeTag>[];
  final Object? tagsNode = decoded['tags'];
  if (tagsNode is List<Object?>) {
    for (final Object? item in tagsNode) {
      final ScrapeTag? tag = ScrapeTag.fromJson(item);
      if (tag != null) tags.add(tag);
    }
  }

  final List<ScrapeInfoboxEntry> infobox = <ScrapeInfoboxEntry>[];
  final Object? infoboxNode = decoded['infobox'];
  if (infoboxNode is List<Object?>) {
    for (final Object? item in infoboxNode) {
      if (item is! Map<String, Object?>) continue;
      final String? key = _nonEmptyString(item['key']);
      if (key == null) continue;
      final String? value = _flattenInfoboxValue(item['value']);
      if (value == null) continue;
      infobox.add(ScrapeInfoboxEntry(key: key, value: value));
    }
  }

  final String entryId = '${decoded['id']}';
  return ScrapeMetadata(
    source: ScrapeSource.bangumi,
    subjectId: entryId,
    title: title,
    originalTitle: originalTitle,
    summary: _nonEmptyString(decoded['summary']),
    airDate: _nonEmptyString(decoded['date']),
    rating: rating,
    ratingCount: ratingCount,
    episodeCount: episodes > 0 ? episodes : null,
    tags: tags,
    infobox: infobox,
    detailUrl: 'https://bgm.tv/subject/$entryId',
  );
}

/// 摊平 infobox 的 `value`：字符串直取；`[{k?,v},…]` 数组取每项 `v`（有 `k` 时
/// 前缀 `k:`）后以 ` / ` 连接。其余类型 → null（该行丢弃）。
String? _flattenInfoboxValue(Object? value) {
  if (value is String) {
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is! List<Object?>) return null;
  final List<String> parts = <String>[];
  for (final Object? item in value) {
    if (item is String) {
      final String trimmed = item.trim();
      if (trimmed.isNotEmpty) parts.add(trimmed);
      continue;
    }
    if (item is! Map<String, Object?>) continue;
    final String? v = _nonEmptyString(item['v']);
    if (v == null) continue;
    final String? k = _nonEmptyString(item['k']);
    parts.add(k == null ? v : '$k: $v');
  }
  return parts.isEmpty ? null : parts.join(' / ');
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
