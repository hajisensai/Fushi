/// AJATT 日语字幕库作为 [VideoSubtitleProvider]（id `ajatt`）。
///
/// 第一个**零配置**的字幕源：没填 Jimaku / OpenSubtitles key 的用户此前一个源都没有。
/// 搜索对齐 Jimaku 的「先身份、后文本」：
/// 1. 目录里按标题归一匹配挑候选作品（精确命中优先，最多 [maxEntryMatches] 部）；
/// 2. 请求带 AniList id 时，逐个读候选目录的 `.kitsuinfo.json` 确认——id 相等的直接
///    确认，id 明确不等的丢弃，目录没标 id 的只在没有任何确认时才保留；
/// 3. 拉确认下来的作品页文件表，过滤成文本字幕候选。
///
/// 站点/仓库形态见 `ajatt_catalog.dart` 文件头。
library;

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/subtitle/ajatt_catalog.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';

/// provider id（registry 分派 / 候选 `providerId`）。
const String kAjattSubtitleProviderId = 'ajatt';

class AjattVideoSubtitleProvider implements VideoSubtitleProvider {
  AjattVideoSubtitleProvider({
    required AjattClient client,
    this.priority = 150,
    this.maxEntryMatches = 5,
    bool closesClient = false,
  }) : _client = client,
       _closesClient = closesClient;

  final AjattClient _client;
  final bool _closesClient;

  /// 文本匹配最多带几部作品进入身份确认 / 文件列举（每部各一次请求）。
  final int maxEntryMatches;

  @override
  final int priority;

  @override
  String get id => kAjattSubtitleProviderId;

  /// 无配额，允许为语言探测白下载一次（与 Jimaku 同）。
  @override
  bool get allowsFreeProbeDownload => true;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    try {
      final List<AjattCatalogEntry> catalog = await _client.loadCatalog();
      List<AjattCatalogEntry> matches = rankAjattEntries(
        catalog,
        queries: _queriesFor(request),
        category: request.media?.discoveryCategory,
        limit: maxEntryMatches,
      );
      final int? anilistId = request.media?.anilistId;
      if (anilistId != null && matches.isNotEmpty) {
        matches = await _confirmByAnilistId(matches, anilistId);
      }
      final List<VideoSubtitleCandidate> candidates =
          <VideoSubtitleCandidate>[];
      final int? episode = request.effectiveEpisode;
      for (final AjattCatalogEntry entry in matches) {
        final List<AjattSubtitleFile> files = await _client.listEntryFiles(
          entry,
        );
        for (final AjattSubtitleFile file in files) {
          if (!file.isTextSubtitle) continue;
          // 与 Jimaku 的服务端 `episode=` 启发式同一语义：认得出集号的只留这一集，
          // 认不出集号的（剧场版 / 整季单文件）保留让用户判断。
          if (episode != null &&
              file.episode != null &&
              file.episode != episode) {
            continue;
          }
          // 站点是日语字幕库：文件名没标语言 = 日语，不是「未知」。
          final String language = file.taggedLanguage ?? 'ja';
          if (request.languages.isNotEmpty &&
              !request.languages.contains(language)) {
            continue;
          }
          candidates.add(
            _AjattSubtitleCandidate(
              entry: entry,
              file: file,
              language: language,
              season: request.effectiveSeason,
              providerPriority: priority,
            ),
          );
        }
      }
      return ProviderBatchResult<VideoSubtitleCandidate>.success(candidates);
    } on Object catch (error) {
      return ProviderBatchResult<VideoSubtitleCandidate>.failure(
        _ajattFailure('search', error),
      );
    }
  }

  /// 按 `.kitsuinfo.json` 的 `anilist_id` 收敛文本候选。
  ///
  /// 三档：id 相等 → 确认；id 存在且不等 → 明确排除（「K-ON!」对「K-ON!!」这种
  /// 文本几乎同名但季不同的，正是要靠这一步分开）；目录没标 id / 没有
  /// `.kitsuinfo.json` → 不确认也不排除，只在一部都确认不了时才保留。
  Future<List<AjattCatalogEntry>> _confirmByAnilistId(
    List<AjattCatalogEntry> matches,
    int anilistId,
  ) async {
    final List<AjattCatalogEntry> confirmed = <AjattCatalogEntry>[];
    final List<AjattCatalogEntry> unknown = <AjattCatalogEntry>[];
    for (final AjattCatalogEntry entry in matches) {
      final AjattEntryInfo? info = await _client.fetchEntryInfo(entry);
      final int? remoteId = info?.anilistId;
      if (remoteId == null) {
        unknown.add(entry);
      } else if (remoteId == anilistId) {
        confirmed.add(entry);
      }
    }
    return confirmed.isNotEmpty ? confirmed : unknown;
  }

  static List<String> _queriesFor(VideoSubtitleSearchRequest request) {
    final VideoMediaReference? media = request.media;
    return <String>{
      request.effectiveQuery,
      ...request.alternateTitles,
      if (media?.originalTitle != null) media!.originalTitle!,
      if (media != null) ...media.aliases,
    }.where((String value) => value.trim().isNotEmpty).toList();
  }

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async {
    if (candidate is! _AjattSubtitleCandidate) {
      throw const ExternalProviderFailure(
        providerId: kAjattSubtitleProviderId,
        operation: 'download',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'candidate belongs to another provider',
      );
    }
    try {
      final bytes = await _client.download(candidate.file.downloadUrl);
      if (bytes.isEmpty) {
        throw const ExternalProviderFailure(
          providerId: kAjattSubtitleProviderId,
          operation: 'download',
          kind: ExternalProviderFailureKind.unavailable,
          message: 'subtitle download returned no data',
          retryable: true,
        );
      }
      return VideoSubtitleDownload(
        bytes: bytes,
        fileName: candidate.file.name,
        language: candidate.language,
      );
    } on Object catch (error) {
      throw _ajattFailure('download', error);
    }
  }

  @override
  void close() {
    _client.close();
    if (_closesClient) {
      // AjattClient 自己按 closesClient 决定是否关 http.Client；这里没有第二个句柄。
    }
  }
}

/// 目录标题匹配：所有 [queries] 与每条目的 `name / english_name / japanese_name`
/// 两侧归一（[normalizeMediaSearchText]：全角→半角、片假名→平假名、去标点空白）后比较。
///
/// 精确相等优先于子串包含：只要有精确命中就**只**返回精确命中的（「K-ON!」精确命中
/// 后不再把「K-ON!!」「K-ON! Movie」一起带上）；没有精确命中才退回子串命中。同档内按
/// 目录最后修改时间降序（新上传的更可能是当季）。[category] 非 null 时按动画 /
/// 真人分类过滤（unsorted 两边都算）。纯函数，便于单测。
List<AjattCatalogEntry> rankAjattEntries(
  List<AjattCatalogEntry> catalog, {
  required List<String> queries,
  VideoDiscoveryCategory? category,
  int limit = 5,
}) {
  final List<String> needles = queries
      .map(normalizeMediaSearchText)
      .where((String value) => value.isNotEmpty)
      .toSet()
      .toList();
  if (needles.isEmpty || limit <= 0) return const <AjattCatalogEntry>[];
  final List<AjattCatalogEntry> exact = <AjattCatalogEntry>[];
  final List<AjattCatalogEntry> partial = <AjattCatalogEntry>[];
  for (final AjattCatalogEntry entry in catalog) {
    if (!_categoryAllows(category, entry.type)) continue;
    final List<String> titles = entry.searchTitles
        .map(normalizeMediaSearchText)
        .toList();
    bool isExact = false;
    bool isPartial = false;
    for (final String needle in needles) {
      for (final String title in titles) {
        if (title == needle) {
          isExact = true;
        } else if (title.contains(needle) || needle.contains(title)) {
          // 双向包含：库里显示名可能比目录名长（带季/篇名），也可能更短。
          // 太短的标题（≤2 个归一后字符）不参与「目录名包含在查询里」这一向，
          // 否则「K」「Re」之类会命中一切。
          if (title.contains(needle) || title.length > 2) isPartial = true;
        }
      }
    }
    if (isExact) {
      exact.add(entry);
    } else if (isPartial) {
      partial.add(entry);
    }
  }
  int newestFirst(AjattCatalogEntry a, AjattCatalogEntry b) =>
      b.lastModifiedMs.compareTo(a.lastModifiedMs);
  final List<AjattCatalogEntry> picked = (exact.isNotEmpty ? exact : partial)
    ..sort(newestFirst);
  return picked.length <= limit ? picked : picked.sublist(0, limit);
}

bool _categoryAllows(VideoDiscoveryCategory? category, AjattEntryType type) {
  return switch (category) {
    null => true,
    VideoDiscoveryCategory.anime => type.isAnime,
    VideoDiscoveryCategory.movie ||
    VideoDiscoveryCategory.tv => type.isLiveAction,
  };
}

class _AjattSubtitleCandidate extends VideoSubtitleCandidate {
  _AjattSubtitleCandidate({
    required this.entry,
    required this.file,
    required String language,
    required int? season,
    required int providerPriority,
  }) : super(
         providerId: kAjattSubtitleProviderId,
         remoteId: '${entry.pagePath}:${file.name}',
         fileName: file.name,
         language: language,
         providerPriority: providerPriority,
         releaseName: entry.name,
         season: season,
         episode: file.episode,
         fileSize: file.size,
         uploadedAtMs: file.lastModifiedMs,
         collectionId: entry.pagePath,
         collectionLabel: entry.name,
       );

  final AjattCatalogEntry entry;
  final AjattSubtitleFile file;
}

ExternalProviderFailure _ajattFailure(String operation, Object error) {
  if (error is! AjattRequestException) {
    return ExternalProviderFailure.fromException(
      providerId: kAjattSubtitleProviderId,
      operation: operation,
      error: error,
    );
  }
  final int? status = error.statusCode;
  return ExternalProviderFailure(
    providerId: kAjattSubtitleProviderId,
    operation: operation,
    kind: switch (status) {
      404 => ExternalProviderFailureKind.notFound,
      429 => ExternalProviderFailureKind.rateLimited,
      _ =>
        status == null
            ? ExternalProviderFailureKind.invalidResponse
            : ExternalProviderFailureKind.unavailable,
    },
    message: status == null
        ? 'AJATT page layout was not recognised'
        : 'AJATT returned HTTP $status',
    statusCode: status,
    retryable: status == 429 || (status != null && status >= 500),
  );
}
