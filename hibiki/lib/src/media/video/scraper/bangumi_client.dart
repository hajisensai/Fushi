/// Bangumi（番组计划）在线搜索客户端 —— 视频海报刮削匹配层的**主源**（免 API key）。
///
/// 端点 `POST /v0/search/subjects`，只搜动画（`filter.type = [2]`）。响应条目映射为
/// 共享契约 [ScrapeCandidate]（见 `scraper_types.dart`，本文件**只 import 不修改**）。
///
/// 本文件同时定义跨刮削层共享的网络异常 [ScrapeNetworkException]（tmdb_client /
/// offline_db_downloader / cover_downloader 均从这里 import，不重复定义）。
///
/// 代理：`package:http` 默认走 `dart:io` 的 `HttpClient`，会尊重进程环境里的系统代理
/// 设置（`HTTP_PROXY` / `HTTPS_PROXY` / 平台系统代理），无需自实现代理配置。Bangumi
/// 在中国大陆一般可直连；若用户所在网络不通，交由外层代理生效即可。
library;

import 'dart:convert';

import 'package:hibiki/src/media/metadata/bangumi_api_client.dart';
import 'package:hibiki/src/media/metadata/bangumi_cover_url.dart';
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

  /// 按 subject id 直取条目并映射为**候选**（添加/修改 Bangumi 映射：用户在匹配
  /// 弹窗贴 ID/URL 直连改绑，不走关键词搜索）。
  ///
  /// 404（条目不存在/被删）或条目无海报 → null（UI 按空结果处理）；其余非 2xx /
  /// 网络失败 → 抛 [ScrapeNetworkException]。
  Future<ScrapeCandidate?> fetchSubjectCandidate(String subjectId) async {
    final BangumiRawResponse response;
    try {
      response = await _api.fetchSubject(subjectId);
    } on BangumiTransportException catch (e) {
      throw ScrapeNetworkException('Bangumi subject ${e.message}');
    }
    if (response.statusCode == 404) return null;
    if (!response.isOk) {
      throw ScrapeNetworkException(
        'Bangumi subject HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    return parseBangumiSubjectDetailAsCandidate(response.body);
  }

  /// 拉取条目的关联条目列表 `GET /v0/subjects/{id}/subjects`（TODO-2484 合集
  /// 「相关作品」）。只保留动画（type 2）与三次元（type 6）条目——关联列表里的
  /// 原声集/广播剧/书籍对视频合集无用，在解析层滤掉。
  ///
  /// 网络失败 / 非 2xx / JSON 异常 → 抛 [ScrapeNetworkException]。
  Future<List<BangumiRelatedSubject>> fetchSubjectRelations(
    String subjectId,
  ) async {
    final BangumiRawResponse response;
    try {
      response = await _api.fetchSubjectRelations(subjectId);
    } on BangumiTransportException catch (e) {
      throw ScrapeNetworkException('Bangumi relations ${e.message}');
    }
    if (!response.isOk) {
      throw ScrapeNetworkException(
        'Bangumi relations HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    return parseBangumiRelatedSubjects(response.body);
  }

  /// 拉取条目的**正篇**分集列表 `GET /v0/episodes?subject_id=&type=0`（TODO-2491
  /// 集级刮削），内部按响应 `total` 分页拉全。
  ///
  /// 网络失败 / 非 2xx / JSON 异常 → 抛 [ScrapeNetworkException]。
  Future<List<BangumiEpisodeInfo>> fetchSubjectEpisodes(
    String subjectId,
  ) async {
    final List<BangumiEpisodeInfo> all = <BangumiEpisodeInfo>[];
    int offset = 0;
    while (true) {
      final BangumiRawResponse response;
      try {
        response = await _api.fetchSubjectEpisodes(subjectId, offset: offset);
      } on BangumiTransportException catch (e) {
        throw ScrapeNetworkException('Bangumi episodes ${e.message}');
      }
      if (!response.isOk) {
        throw ScrapeNetworkException(
          'Bangumi episodes HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
      final ({
        List<BangumiEpisodeInfo> episodes,
        int rawCount,
        int total
      }) page = parseBangumiEpisodesResponse(response.body);
      all.addAll(page.episodes);
      // offset 必须按**源返回的原始条数**推进，不能按过滤后的 episodes 长度：
      // 一页若全被过滤（非整数 sort 的脏数据页），按过滤后长度推进会原地踏步
      // 或提前 break，把后面还没拉的正常页整段丢掉。
      offset += page.rawCount;
      // 空页兜底：错误负载/total 虚高时防死循环。
      if (page.rawCount == 0 || offset >= page.total) break;
    }
    return all;
  }

  /// 关闭内部 client（若为默认自建）。测试注入的 mock client 由调用方自行管理。
  void close() => _api.close();
}

/// Bangumi 关联条目（`/v0/subjects/{id}/subjects` 单项的领域投影）。
class BangumiRelatedSubject {
  const BangumiRelatedSubject({
    required this.subjectId,
    required this.subjectType,
    required this.relation,
    required this.title,
    this.coverUrl,
  });

  /// 关联条目的 subject id（字符串化）。
  final String subjectId;

  /// Bangumi 条目类型（2=动画 / 6=三次元；解析层已滤掉其余类型）。
  final int subjectType;

  /// 源侧关系词原文（`续集` / `前传` / `番外篇` …），映射到落库枚举由
  /// `collection_relations_scrape.dart` 的 `mapBangumiRelation` 负责。
  final String relation;

  /// 标题（`name_cn` 非空优先，否则 `name`）。
  final String title;

  /// 封面 URL（`images.large` → `common` 逐级回退），可缺失。
  final String? coverUrl;
}

/// Bangumi 分集（`/v0/episodes` 单项的领域投影，只收正篇 type=0）。
class BangumiEpisodeInfo {
  const BangumiEpisodeInfo({
    required this.episodeNumber,
    this.id,
    this.title,
    this.airDate,
    this.summary,
  });

  /// 源侧章节 id（`/v0/episodes` 的 `id`；拼 `bgm.tv/ep/<id>` 外链用）。
  /// 旧调用方不读它，可选参数向后兼容；缺失为 null。
  final int? id;

  /// 正篇集号（源侧 `sort`；非整数的特殊话数在解析层跳过）。
  final int episodeNumber;

  /// 集名（`name_cn` 非空优先，否则 `name`）；两者皆空为 null。
  final String? title;

  /// 放送日期 `YYYY-MM-DD` 原文。
  final String? airDate;

  /// 集简介（`desc`）。
  final String? summary;
}

/// 纯函数：解析 `/v0/subjects/{id}/subjects` 响应（顶层 JSON 数组）。
///
/// 只保留动画（type 2）/三次元（type 6）条目；缺 id/标题/relation 的项跳过。
/// JSON 结构异常 → 抛 [ScrapeNetworkException]。
List<BangumiRelatedSubject> parseBangumiRelatedSubjects(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    throw ScrapeNetworkException('Bangumi relations JSON decode failed: $e');
  }
  if (decoded is! List<Object?>) {
    throw const ScrapeNetworkException('Bangumi relations not a JSON array');
  }
  final List<BangumiRelatedSubject> related = <BangumiRelatedSubject>[];
  for (final Object? item in decoded) {
    if (item is! Map<String, Object?>) continue;
    final int? type = _asInt(item['type']);
    // 原声集/书籍等对视频合集无用，只留动画(2)/三次元(6)。
    if (type == null || (type != 2 && type != 6)) continue;
    final Object? id = item['id'];
    if (id is! int) continue;
    final String? relation = _nonEmptyString(item['relation']);
    if (relation == null) continue;
    final String? title =
        _nonEmptyString(item['name_cn']) ?? _nonEmptyString(item['name']);
    if (title == null) continue;
    String? coverUrl;
    final Object? images = item['images'];
    if (images is Map<String, Object?>) {
      coverUrl =
          _nonEmptyString(images['large']) ?? _nonEmptyString(images['common']);
    }
    related.add(BangumiRelatedSubject(
      subjectId: '$id',
      subjectType: type,
      relation: relation,
      title: title,
      coverUrl: coverUrl,
    ));
  }
  return related;
}

/// 纯函数：解析 `/v0/episodes` 分页响应，返回本页分集 + 源侧 total +
/// **原始条数** [rawCount]（分页 offset 必须按它推进——过滤后的 episodes
/// 长度会在脏数据页上把 offset 卡住）。
///
/// `sort` 非整数（25.5 之类的番外话数混进正篇的历史脏数据）跳过；缺 sort 跳过。
/// JSON 结构异常 → 抛 [ScrapeNetworkException]。
({List<BangumiEpisodeInfo> episodes, int rawCount, int total})
    parseBangumiEpisodesResponse(
  String body,
) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    throw ScrapeNetworkException('Bangumi episodes JSON decode failed: $e');
  }
  if (decoded is! Map<String, Object?>) {
    throw const ScrapeNetworkException('Bangumi episodes not a JSON object');
  }
  final int total = _asInt(decoded['total']) ?? 0;
  final Object? items = decoded['data'];
  final int rawCount = items is List<Object?> ? items.length : 0;
  final List<BangumiEpisodeInfo> episodes = <BangumiEpisodeInfo>[];
  if (items is List<Object?>) {
    for (final Object? item in items) {
      if (item is! Map<String, Object?>) continue;
      final double? sort = _asDouble(item['sort']);
      if (sort == null) continue;
      final int episodeNumber = sort.toInt();
      if (episodeNumber.toDouble() != sort || episodeNumber <= 0) continue;
      episodes.add(BangumiEpisodeInfo(
        episodeNumber: episodeNumber,
        id: _asInt(item['id']),
        title:
            _nonEmptyString(item['name_cn']) ?? _nonEmptyString(item['name']),
        airDate: _nonEmptyString(item['airdate']),
        summary: _nonEmptyString(item['desc']),
      ));
    }
  }
  return (episodes: episodes, rawCount: rawCount, total: total);
}

/// 纯函数：把 Bangumi `/v0/subjects/{id}` **详情**响应体解析为 [ScrapeCandidate]
/// （id 直连改绑映射路径用；与搜索候选同一映射器，保证「使用」后落库路径零分叉）。
///
/// 详情端点与搜索端点字段有两处形态差异，先归一再复用 [_mapBangumiSubject]：
/// 评分在 `rating.score`（搜索是扁平 `score`）；话数补 `total_episodes` 回退。
/// 无海报/无标题 → null；JSON 结构异常 → 抛 [ScrapeNetworkException]。
ScrapeCandidate? parseBangumiSubjectDetailAsCandidate(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    throw ScrapeNetworkException('Bangumi subject JSON decode failed: $e');
  }
  if (decoded is! Map<String, Object?>) {
    throw const ScrapeNetworkException('Bangumi subject not a JSON object');
  }
  final Map<String, Object?> subject = Map<String, Object?>.of(decoded);
  final Object? ratingNode = subject['rating'];
  if (_asDouble(subject['score']) == null &&
      ratingNode is Map<String, Object?>) {
    subject['score'] = ratingNode['score'];
  }
  if ((_asInt(subject['eps']) ?? 0) <= 0) {
    subject['eps'] = subject['total_episodes'];
  }
  return _mapBangumiSubject(subject);
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

/// 把单个 Bangumi subject 映射为 [ScrapeCandidate]；缺封面返回 null。
ScrapeCandidate? _mapBangumiSubject(Map<String, Object?> subject) {
  final String? posterUrl = bangumiOriginalCoverUrl(subject);
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
