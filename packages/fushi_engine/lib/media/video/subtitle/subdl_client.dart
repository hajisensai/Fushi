/// SubDL（subdl.com）作为 [VideoSubtitleProvider]（id `subdl`）。
///
/// 站点以英文字幕为主（也有大量其它语种），是 OpenSubtitles 之外第二家按 IMDb /
/// TMDB 身份搜的通用字幕库。接入形状照 OpenSubtitles：
/// - 搜索 `GET https://api.subdl.com/api/v1/subtitles`，**必须** `api_key`（用户在
///   subdl.com → panel → API 免费生成；免费额度 2000 次搜索/天），身份按
///   IMDb → TMDB → 片名三档分层逐个试，先命中先返回（与 OpenSubtitles 同一理由：
///   精确身份查不到不代表放宽查询是安全的，鉴权/限流失败必须原样暴露）；
/// - 下载 `https://dl.subdl.com` + `url`，**不带 key**（匿名 300 次/天/IP），响应是
///   zip（个别老上传是 RAR 伪装成 `.zip`，或直接裸字幕文件），本 provider 自己解包
///   挑出文本字幕再交给下游——下游按扩展名路由 parser，一个 `.zip` 直接落盘等于
///   这条字幕在菜单里根本不出现。
///
/// 响应字段以 2026-09 实测为准：`status:false` + `error` 是业务失败（`Can't find …`
/// 也走这条，按空结果处理）；`language` 是大写码（`EN` / `ZH_BG` / `BR_PT`），
/// `lang` 是小写英文全名；`season`/`episode` 电影或未标注时是 0 / null。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart'
    show parseSubtitleEpisode;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart'
    show kMaximumSubtitleDownloadBytes;
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';

/// provider id（registry 分派 / 候选 `providerId`）。
const String kSubdlSubtitleProviderId = 'subdl';

/// 官方 v1 搜索端点。
final Uri kSubdlApiBaseUrl = Uri.parse('https://api.subdl.com/api/v1');

/// 官方下载域；`subtitles[].url` 是相对路径（`/subtitle/<n>-<m>.zip`）。
final Uri kSubdlDownloadBaseUrl = Uri.parse('https://dl.subdl.com');

/// 服务端允许的每页上限。
const int kSubdlSubtitlesPerPage = 30;

/// 文本字幕扩展名白名单（与 Jimaku / AJATT 的 `isTextSubtitle` 同一集合）。
/// `.sub`（MicroDVD）站上也有，但播放页没有它的 parser，不当候选。
const Set<String> kSubdlTextSubtitleExtensions = <String>{
  'srt',
  'ass',
  'ssa',
  'vtt',
};

/// Hibiki 大类语言码 → SubDL 查询码（大写，逗号分隔）。
///
/// SubDL 的码表基本是 ISO 639-1 大写；特殊的只有中文分 `ZH`（简）/ `ZH_BG`（繁，
/// "Big 5"）和葡语分 `PT` / `BR_PT`。大类码要展开成该族全部码，否则 `zh` 恒定
/// 搜不到繁中（与 OpenSubtitles 的 `zh` → `zh-cn,zh-tw` 同一个坑，BUG-1846）。
/// 其余原样大写透传，交给服务端裁决。
const Map<String, List<String>> kSubdlLanguageExpansions =
    <String, List<String>>{
  'zh': <String>['ZH', 'ZH_BG'],
  'pt': <String>['PT', 'BR_PT'],
};

/// 把语言偏好归一成 SubDL 的查询值域：展开 + 大写 + 去重 + 排序。纯函数，便于单测。
List<String> normalizeSubdlLanguages(Iterable<String> languages) {
  final Set<String> out = <String>{};
  for (final String raw in languages) {
    final String code = raw.trim().toLowerCase();
    if (code.isEmpty) continue;
    final List<String>? expansion = kSubdlLanguageExpansions[code];
    if (expansion == null) {
      out.add(code.toUpperCase());
    } else {
      out.addAll(expansion);
    }
  }
  final List<String> sorted = out.toList()..sort();
  return List<String>.unmodifiable(sorted);
}

/// SubDL 响应里的 `language` 码 → Hibiki 大类小写码。
///
/// `ZH_BG` → `zh`、`BR_PT` → `pt`、双语码（`EN_DE` / `BG_EN`）取第一段；空值回
/// `und`（ISO 639-2「未确定」）——候选 `language` 是 sidecar 后缀的一部分，空串会写成
/// `<base>..srt`。纯函数。
String subdlLanguageToHibiki(String? raw) {
  final String code = (raw ?? '').trim().toLowerCase();
  if (code.isEmpty) return 'und';
  if (code == 'br_pt') return 'pt';
  final int underscore = code.indexOf('_');
  final String head = underscore > 0 ? code.substring(0, underscore) : code;
  return head.isEmpty ? 'und' : head;
}

/// 服务端对 `film_name` 里这些字符直接回 400（「Film name contains potentially
/// unsafe characters」），Bazarr 的做法是替换成空格再查。纯函数。
String sanitizeSubdlFilmName(String raw) => raw
    .replaceAll(RegExp('[\'"<>{}\\[\\];\\\\/]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// `results[0]`：本页字幕所属的作品（`subtitles[]` 只属于第一部命中的作品）。
class SubdlWorkRecord {
  const SubdlWorkRecord({
    required this.sdId,
    required this.name,
    this.type,
    this.imdbId,
    this.tmdbId,
    this.year,
  });

  final int sdId;
  final String name;
  final String? type;
  final String? imdbId;
  final int? tmdbId;
  final int? year;
}

class SubdlSubtitleRecord {
  const SubdlSubtitleRecord({
    required this.url,
    required this.releaseName,
    required this.language,
    this.author,
    this.season,
    this.episode,
    this.episodeFrom,
    this.episodeEnd,
    this.hearingImpaired = false,
    this.fps,
    this.aiTranslated = false,
  });

  /// 下载相对路径（`/subtitle/<n>-<m>.zip`），也是候选的 `remoteId`。
  final String url;
  final String releaseName;

  /// 已归一成 Hibiki 小写大类码。
  final String language;
  final String? author;

  /// 服务端 0 / null 都归一成 null（电影 / 未标注）。
  final int? season;
  final int? episode;

  /// 整季 / 多集包的集号区间（服务端 `episode_from` / `episode_end`，0 归 null）。
  final int? episodeFrom;
  final int? episodeEnd;
  final bool hearingImpaired;
  final double? fps;
  final bool aiTranslated;

  /// 多集包：有区间且区间跨度大于一集。
  bool get isMultiEpisodePack =>
      episodeFrom != null && episodeEnd != null && episodeEnd! > episodeFrom!;

  /// 这条字幕能否服务 [wanted] 集：单集条目按 `episode` 相等；多集包按区间；
  /// 没标集号的（剧场版 / 整季单文件）不排除，留给用户判断（与 AJATT 同语义）。
  bool coversEpisode(int wanted) {
    if (episode != null) return episode == wanted;
    if (episodeFrom != null && episodeEnd != null) {
      return wanted >= episodeFrom! && wanted <= episodeEnd!;
    }
    return true;
  }
}

class SubdlSearchPage {
  const SubdlSearchPage({
    required this.work,
    required this.subtitles,
    this.totalPages,
  });

  final SubdlWorkRecord? work;
  final List<SubdlSubtitleRecord> subtitles;
  final int? totalPages;
}

/// 业务层失败（HTTP 200 但 `status:false`），`error` 是服务端短码 / 文案。
class SubdlApiException implements Exception {
  const SubdlApiException(this.error, {this.statusCode});

  final String error;
  final int? statusCode;

  /// 「查无此片」也是 `status:false`，但语义是空结果，不是失败。
  bool get isNotFound =>
      error.toLowerCase().contains("can't find") ||
      error.toLowerCase().contains('cannot find') ||
      error.toLowerCase().contains('not found');

  @override
  String toString() => 'SubdlApiException($error)';
}

/// 解析 v1 搜索响应。纯函数，便于单测。
///
/// `status:false` 抛 [SubdlApiException]（调用方按 [SubdlApiException.isNotFound]
/// 判空结果）；形状不对抛 [FormatException]。
SubdlSearchPage parseSubdlSearchResponse(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map) {
    throw const FormatException('SubDL response must be an object');
  }
  if (decoded['status'] != true) {
    final String error = _string(decoded['error']) ??
        _string(decoded['message']) ??
        'request failed';
    throw SubdlApiException(error, statusCode: _int(decoded['statusCode']));
  }
  SubdlWorkRecord? work;
  final Object? rawResults = decoded['results'];
  if (rawResults is List && rawResults.isNotEmpty && rawResults.first is Map) {
    final Map<Object?, Object?> first =
        rawResults.first as Map<Object?, Object?>;
    final int? sdId = _int(first['sd_id']);
    final String? name = _string(first['name']);
    if (sdId != null && name != null && name.isNotEmpty) {
      work = SubdlWorkRecord(
        sdId: sdId,
        name: name,
        type: _string(first['type']),
        imdbId: _string(first['imdb_id']),
        tmdbId: _int(first['tmdb_id']),
        year: _int(first['year']),
      );
    }
  }
  final Object? rawSubtitles = decoded['subtitles'];
  if (rawSubtitles is! List) {
    throw const FormatException('SubDL response subtitles must be an array');
  }
  final List<SubdlSubtitleRecord> subtitles = <SubdlSubtitleRecord>[];
  for (final Object? raw in rawSubtitles) {
    if (raw is! Map) continue;
    final String? url = _string(raw['url']);
    if (url == null || url.trim().isEmpty) continue;
    final String releaseName =
        _string(raw['release_name']) ?? _string(raw['name']) ?? url;
    final Object? hi = raw['hi'];
    subtitles.add(
      SubdlSubtitleRecord(
        url: url.trim(),
        releaseName: releaseName,
        language: subdlLanguageToHibiki(_string(raw['language'])),
        author: _string(raw['author']),
        season: _positive(raw['season']),
        episode: _positive(raw['episode']),
        episodeFrom: _positive(raw['episode_from']),
        episodeEnd: _positive(raw['episode_end']),
        hearingImpaired: hi == true || hi == 1,
        fps: _double(raw['fps']),
        aiTranslated: raw['ai_translated'] == true,
      ),
    );
  }
  return SubdlSearchPage(
    work: work,
    subtitles: subtitles,
    totalPages: _int(decoded['totalPages']),
  );
}

/// 下载体内挑出来的一个文本字幕文件。
class SubdlExtractedSubtitle {
  const SubdlExtractedSubtitle({required this.fileName, required this.bytes});

  final String fileName;
  final Uint8List bytes;
}

/// 把下载体（zip / 裸字幕）解成文本字幕文件列表。纯函数，便于单测。
///
/// - `PK\x03\x04` 开头按 zip 解；跳过目录、`__MACOSX/` 与 `._` AppleDouble 残渣，
///   只留 [kSubdlTextSubtitleExtensions]；
/// - `Rar!` 开头是 RAR 伪装成 `.zip` 的老上传：没有解 RAR 的依赖，明确报 unsupported，
///   不要把压缩流当文本落盘；
/// - 其余按裸字幕文件处理（站点偶尔直接回单文件），文件名用 [fallbackFileName]。
List<SubdlExtractedSubtitle> extractSubdlSubtitles(
  Uint8List bytes, {
  required String fallbackFileName,
}) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x61 &&
      bytes[2] == 0x72 &&
      bytes[3] == 0x21) {
    throw const ExternalProviderFailure(
      providerId: kSubdlSubtitleProviderId,
      operation: 'download',
      kind: ExternalProviderFailureKind.unsupported,
      message: 'SubDL returned a RAR archive, which is not supported',
    );
  }
  final bool isZip = bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04;
  if (!isZip) {
    return <SubdlExtractedSubtitle>[
      SubdlExtractedSubtitle(fileName: fallbackFileName, bytes: bytes),
    ];
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: true);
  } on Object {
    throw const ExternalProviderFailure(
      providerId: kSubdlSubtitleProviderId,
      operation: 'download',
      kind: ExternalProviderFailureKind.invalidResponse,
      message: 'SubDL archive could not be decoded',
    );
  }
  final List<SubdlExtractedSubtitle> out = <SubdlExtractedSubtitle>[];
  for (final ArchiveFile file in archive.files) {
    if (!file.isFile) continue;
    final String path = file.name.replaceAll('\\', '/');
    if (path.startsWith('__MACOSX/') || path.contains('/__MACOSX/')) continue;
    final String baseName = path.substring(path.lastIndexOf('/') + 1);
    if (baseName.isEmpty || baseName.startsWith('._')) continue;
    if (!kSubdlTextSubtitleExtensions.contains(_extensionOf(baseName))) {
      continue;
    }
    final Object? content = file.content;
    if (content is! List<int>) continue;
    out.add(
      SubdlExtractedSubtitle(
        fileName: baseName,
        bytes: content is Uint8List ? content : Uint8List.fromList(content),
      ),
    );
  }
  return out;
}

/// 多文件包里挑出要用的那一个。纯函数，便于单测。
///
/// 只有一个直接用；多个时按文件名解析集号（[parseSubtitleEpisode]）匹配 [episode]，
/// 命中唯一的用它；解析不出 / 没给集号时退回第一个（zip 内顺序通常就是集序）。
SubdlExtractedSubtitle? pickSubdlSubtitle(
  List<SubdlExtractedSubtitle> files, {
  int? episode,
}) {
  if (files.isEmpty) return null;
  if (files.length == 1 || episode == null) return files.first;
  final List<SubdlExtractedSubtitle> matching = files
      .where(
        (SubdlExtractedSubtitle file) =>
            parseSubtitleEpisode(file.fileName) == episode,
      )
      .toList();
  return matching.isNotEmpty ? matching.first : files.first;
}

class SubdlClient implements VideoSubtitleProvider {
  SubdlClient({
    required String apiKey,
    http.Client? client,
    Uri? baseUrl,
    Uri? downloadBaseUrl,
    this.priority = 250,
    this.requestTimeout = const Duration(seconds: 20),
    bool closesClient = true,
  })  : _apiKey = apiKey.trim(),
        _baseUrl = baseUrl ?? kSubdlApiBaseUrl,
        _downloadBaseUrl = downloadBaseUrl ?? kSubdlDownloadBaseUrl,
        _client = client ?? createAppHttpIoClient(),
        _closesClient = client == null || closesClient;

  final String _apiKey;
  final Uri _baseUrl;
  final Uri _downloadBaseUrl;
  final http.Client _client;
  final bool _closesClient;
  final Duration requestTimeout;

  @override
  final int priority;

  @override
  String get id => kSubdlSubtitleProviderId;

  /// 下载虽不计 key 配额，但匿名下载按 IP 每天 300 次封顶；且 SubDL 每条候选都带
  /// 明确的 `language`，根本没有「未知语言组」需要探测。不为展示标签白花额度。
  @override
  bool get allowsFreeProbeDownload => false;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    if (_apiKey.isEmpty) {
      return ProviderBatchResult<VideoSubtitleCandidate>.failure(
        const ExternalProviderFailure(
          providerId: kSubdlSubtitleProviderId,
          operation: 'search',
          kind: ExternalProviderFailureKind.unauthorized,
          message: 'SubDL API key is not configured',
        ),
      );
    }
    try {
      final List<Map<String, String>> queries =
          buildSubdlSearchQueries(request);
      if (queries.isEmpty) {
        throw const ExternalProviderFailure(
          providerId: kSubdlSubtitleProviderId,
          operation: 'search',
          kind: ExternalProviderFailureKind.unsupported,
          message: 'a title or external id is required',
        );
      }
      final int? wantedEpisode = request.effectiveEpisode;
      for (final Map<String, String> query in queries) {
        final SubdlSearchPage page = await _requestSearch(query);
        if (page.subtitles.isEmpty) continue;
        final List<VideoSubtitleCandidate> candidates =
            <VideoSubtitleCandidate>[];
        for (final SubdlSubtitleRecord record in page.subtitles) {
          // 服务端的 episode_number 已经筛过一轮，这里再按响应自报的集号 / 区间
          // 复核一次：很多剧集条目 season/episode 是 0，服务端筛不掉的这里也不硬
          // 排除（`coversEpisode` 对没标集号的返回 true）。
          if (wantedEpisode != null && !record.coversEpisode(wantedEpisode)) {
            continue;
          }
          candidates.add(
            _SubdlCandidate(
              record: record,
              work: page.work,
              season: record.season ?? request.effectiveSeason,
              wantedEpisode: wantedEpisode,
              providerPriority: priority,
            ),
          );
        }
        if (candidates.isNotEmpty) {
          return ProviderBatchResult<VideoSubtitleCandidate>.success(
            candidates,
          );
        }
      }
      return ProviderBatchResult<VideoSubtitleCandidate>.success(
        const <VideoSubtitleCandidate>[],
      );
    } on Object catch (error) {
      return ProviderBatchResult<VideoSubtitleCandidate>.failure(
        _failure('search', error),
      );
    }
  }

  Future<SubdlSearchPage> _requestSearch(Map<String, String> query) async {
    final http.Response response = await _client
        .get(
          _apiUri(_baseUrl, 'subtitles').replace(
            queryParameters: <String, String>{'api_key': _apiKey, ...query},
          ),
          headers: _headers(),
        )
        .timeout(requestTimeout);
    _requireSuccess('search', response);
    try {
      return parseSubdlSearchResponse(utf8.decode(response.bodyBytes));
    } on SubdlApiException catch (error) {
      if (error.isNotFound) {
        return const SubdlSearchPage(
          work: null,
          subtitles: <SubdlSubtitleRecord>[],
        );
      }
      rethrow;
    }
  }

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async {
    if (candidate is! _SubdlCandidate) {
      throw const ExternalProviderFailure(
        providerId: kSubdlSubtitleProviderId,
        operation: 'download',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'candidate belongs to another provider',
      );
    }
    try {
      final Uri uri = _downloadBaseUrl.resolve(candidate.record.url);
      if (uri.host != _downloadBaseUrl.host || uri.scheme != 'https') {
        throw const ExternalProviderFailure(
          providerId: kSubdlSubtitleProviderId,
          operation: 'download',
          kind: ExternalProviderFailureKind.invalidResponse,
          message: 'SubDL download path resolved outside the download host',
        );
      }
      final Uint8List body = await _downloadFile(uri);
      if (body.isEmpty) {
        throw const ExternalProviderFailure(
          providerId: kSubdlSubtitleProviderId,
          operation: 'download',
          kind: ExternalProviderFailureKind.unavailable,
          message: 'subtitle download returned no data',
          retryable: true,
        );
      }
      final List<SubdlExtractedSubtitle> files = extractSubdlSubtitles(
        body,
        fallbackFileName: '${candidate.record.releaseName}.srt',
      );
      final SubdlExtractedSubtitle? picked = pickSubdlSubtitle(
        files,
        episode: candidate.wantedEpisode,
      );
      if (picked == null) {
        throw const ExternalProviderFailure(
          providerId: kSubdlSubtitleProviderId,
          operation: 'download',
          kind: ExternalProviderFailureKind.invalidResponse,
          message: 'SubDL archive contained no text subtitle',
        );
      }
      return VideoSubtitleDownload(
        bytes: picked.bytes,
        fileName: picked.fileName,
        language: candidate.language,
      );
    } on Object catch (error) {
      throw _failure('download', error);
    }
  }

  /// 下载请求**不带** API key / cookie：匿名额度按 IP 计，key 额度留给搜索。
  Future<Uint8List> _downloadFile(Uri uri) async {
    final http.Request request = http.Request('GET', uri)
      ..headers['User-Agent'] = fushiUserAgent('subdl')
      ..followRedirects = true
      ..maxRedirects = 5;
    final http.StreamedResponse response =
        await _client.send(request).timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _cancelStream(response.stream);
      _requireSuccess(
        'download',
        http.Response('', response.statusCode, headers: response.headers),
      );
    }
    if ((response.contentLength ?? 0) > kMaximumSubtitleDownloadBytes) {
      await _cancelStream(response.stream);
      throw const ExternalProviderFailure(
        providerId: kSubdlSubtitleProviderId,
        operation: 'download',
        kind: ExternalProviderFailureKind.invalidResponse,
        message: 'subtitle download exceeded the size limit',
      );
    }
    final BytesBuilder body = BytesBuilder(copy: false);
    int length = 0;
    await for (final List<int> chunk
        in response.stream.timeout(requestTimeout)) {
      length += chunk.length;
      if (length > kMaximumSubtitleDownloadBytes) {
        throw const ExternalProviderFailure(
          providerId: kSubdlSubtitleProviderId,
          operation: 'download',
          kind: ExternalProviderFailureKind.invalidResponse,
          message: 'subtitle download exceeded the size limit',
        );
      }
      body.add(chunk);
    }
    return body.takeBytes();
  }

  Future<void> _cancelStream(Stream<List<int>> stream) async {
    final StreamSubscription<List<int>> subscription = stream.listen(
      (_) {},
      onError: (_) {},
    );
    await subscription.cancel();
  }

  Map<String, String> _headers() => <String, String>{
        'User-Agent': fushiUserAgent('subdl'),
        'Accept': 'application/json',
      };

  void _requireSuccess(String operation, http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final int status = response.statusCode;
    final String? error = _errorCode(response.body);
    // 429 的 `error` 区分「今日额度用完」与「请求太密」（Bazarr 观察值）。
    final bool quota = error == 'daily_limit' ||
        error == 'api_download_limit_exceeded' ||
        error == 'quota_exceeded';
    throw ExternalProviderFailure(
      providerId: kSubdlSubtitleProviderId,
      operation: operation,
      kind: switch (status) {
        401 || 403 => ExternalProviderFailureKind.unauthorized,
        402 => ExternalProviderFailureKind.forbidden,
        404 => ExternalProviderFailureKind.notFound,
        429 when quota => ExternalProviderFailureKind.quotaExceeded,
        429 => ExternalProviderFailureKind.rateLimited,
        _ => ExternalProviderFailureKind.unavailable,
      },
      message: switch (status) {
        401 || 403 => 'SubDL authorization failed',
        402 => 'SubDL requires a paid plan for this request',
        429 when quota => 'SubDL daily quota was exhausted',
        429 => 'SubDL request limit was reached',
        _ => 'SubDL returned HTTP $status',
      },
      statusCode: status,
      retryAfter: _retryAfter(response.headers['retry-after']),
      retryable: status == 429 || status >= 500,
    );
  }

  ExternalProviderFailure _failure(String operation, Object error) {
    if (error is SubdlApiException) {
      return ExternalProviderFailure(
        providerId: kSubdlSubtitleProviderId,
        operation: operation,
        kind: error.statusCode == 401 || error.statusCode == 403
            ? ExternalProviderFailureKind.unauthorized
            : ExternalProviderFailureKind.unavailable,
        message: 'SubDL rejected the request',
        statusCode: error.statusCode,
      );
    }
    return ExternalProviderFailure.fromException(
      providerId: kSubdlSubtitleProviderId,
      operation: operation,
      error: error,
    );
  }

  @override
  void close() {
    if (_closesClient) _client.close();
  }
}

/// 身份分层：IMDb → TMDB → 片名，每档一个独立请求。纯函数，便于单测。
///
/// `type` 只在有媒体身份时给（TMDB id 只在类型内唯一，服务端要求带 type）；
/// 季/集号三档都带（服务端筛一轮，响应里再复核一轮）。`page` 与每页上限固定。
List<Map<String, String>> buildSubdlSearchQueries(
  VideoSubtitleSearchRequest request,
) {
  final VideoMediaReference? media = request.media;
  final List<String> languages = normalizeSubdlLanguages(request.languages);
  final Map<String, String> common = <String, String>{
    'subs_per_page': '$kSubdlSubtitlesPerPage',
    if (request.page > 1) 'page': '${request.page}',
    if (languages.isNotEmpty) 'languages': languages.join(','),
    if (request.effectiveSeason != null)
      'season_number': '${request.effectiveSeason}',
    if (request.effectiveEpisode != null)
      'episode_number': '${request.effectiveEpisode}',
  };
  final Map<String, String> type = <String, String>{
    if (media != null)
      'type': media.mediaKind == VideoMetadataMediaKind.movie ? 'movie' : 'tv',
  };
  final List<Map<String, String>> queries = <Map<String, String>>[];
  final String? imdb = media?.imdbId?.trim();
  if (imdb != null && imdb.isNotEmpty) {
    queries.add(<String, String>{
      ...common,
      ...type,
      // 站点样例带 `tt` 前缀；仓库内 imdbId 两种形态都有，统一补齐。
      'imdb_id': imdb.toLowerCase().startsWith('tt') ? imdb : 'tt$imdb',
    });
  }
  if (media?.tmdbId != null) {
    queries.add(<String, String>{
      ...common,
      ...type,
      'tmdb_id': '${media!.tmdbId}',
    });
  }
  final String filmName = sanitizeSubdlFilmName(request.effectiveQuery);
  if (filmName.isNotEmpty) {
    queries.add(<String, String>{
      ...common,
      ...type,
      'film_name': filmName,
      if (media?.year != null && media!.year! > 0) 'year': '${media.year}',
    });
  }
  return queries;
}

class _SubdlCandidate extends VideoSubtitleCandidate {
  _SubdlCandidate({
    required this.record,
    required SubdlWorkRecord? work,
    required int? season,
    required this.wantedEpisode,
    required int providerPriority,
  }) : super(
          providerId: kSubdlSubtitleProviderId,
          remoteId: record.url,
          // 真实文件名要解包后才知道；这里给 release 名 + 站点最常见的扩展名，
          // 下游落盘时以 [VideoSubtitleDownload.fileName] 为准。
          fileName: '${record.releaseName}.srt',
          language: record.language,
          providerPriority: providerPriority,
          releaseName: record.releaseName,
          season: season,
          episode: record.episode,
          hearingImpaired: record.hearingImpaired,
          fps: record.fps,
          collectionId: work == null ? null : '${work.sdId}',
          collectionLabel: work?.name,
          aiTranslated: record.aiTranslated,
        );

  final SubdlSubtitleRecord record;

  /// 多集包解包时要挑的集号（请求给的；单集条目也记着，无害）。
  final int? wantedEpisode;
}

Uri _apiUri(Uri base, String operation) {
  final String prefix = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return base.replace(path: '$prefix/$operation', query: '');
}

String _extensionOf(String fileName) {
  final int dot = fileName.lastIndexOf('.');
  return dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
}

String? _errorCode(String body) {
  if (body.isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final Object? error = decoded['error'];
    if (error is String) return error;
    if (error is Map) return _string(error['code']);
    return null;
  } on FormatException {
    return null;
  }
}

Duration? _retryAfter(String? raw) {
  final int? seconds = int.tryParse(raw?.trim() ?? '');
  return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
}

String? _string(Object? value) => value is String ? value : null;

int? _int(Object? value) => value is int
    ? value
    : value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '');

/// 集号 / 季号：服务端用 0 表示「没有」，与 null 同义。
int? _positive(Object? value) {
  final int? parsed = _int(value);
  return parsed == null || parsed <= 0 ? null : parsed;
}

double? _double(Object? value) =>
    value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
