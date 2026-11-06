import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/media/video/subtitle/subtitle_search_seed.dart';
import 'package:fushi/src/pages/implementations/subtitle_search_panel.dart'
    show
        JimakuCandidate,
        safeSubtitleFileName,
        sortJimakuCandidates,
        uniqueSubtitleDestination;
import 'package:fushi/src/sync/video_remote_host.dart'
    show VideoRemoteOnlineSubtitle, VideoRemoteOnlineSubtitleSearch;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';
import 'package:path/path.dart' as p;

/// 电脑上正在放的视频给在线字幕检索的默认值（与字幕工作台「本集」作用域同一组：
/// `_jimakuQuery` / `_buildJimakuSeed` / `_jimakuEpisodeNumber` /
/// `_jimakuSeasonNumber`）。
class RemoteOnlineSubtitleContext {
  const RemoteOnlineSubtitleContext({
    required this.seriesQuery,
    required this.seed,
    this.episode,
    this.season,
    this.videoPath,
  });

  /// 番名（语言记忆的系列键也按它算）。
  final String seriesQuery;
  final SubtitleSearchSeed seed;
  final int? episode;
  final int? season;

  /// 本机视频文件（远端流为 null）：算 OpenSubtitles 文件指纹、下载后按内嵌轨对齐。
  final String? videoPath;

  /// 预填给手机的检索词：有刮削原名用原名，否则番名。
  String get defaultQuery =>
      seed.primaryQuery.isEmpty ? seriesQuery : seed.primaryQuery;
}

/// 手机遥控「在线搜索字幕」在电脑上的执行体：检索请求、排序、下载落盘都与字幕
/// 工作台本集作用域一致（[SubtitleSearchPanel] 的 `_fetchCandidates` /
/// `_downloadSource`），只是没有界面——候选按不透明 id 记在这里，手机点哪条就
/// 下哪条。只留最近一次检索的候选：旧 id 下载回 `subtitle_candidate_missing`。
///
/// 错误一律是 [VideoRemoteException]（手机按 code 显示本地化文案）：
/// `409 subtitle_source_missing`（一个字幕来源都没配）、
/// `502 subtitle_search_failed`（零结果且有来源报错：没问到，不是没有）、
/// `404 subtitle_candidate_missing`、`502 subtitle_download_failed`。
class RemoteOnlineSubtitleSearch {
  RemoteOnlineSubtitleSearch({
    required this.registry,
    required this.preferredLanguageFor,
    required this.saveDirectory,
    this.aligner,
  });

  /// 现取的字幕来源（填 key 会重建 runtime，不能缓存）；null = 没配。
  final Future<VideoSubtitleRegistry?> Function() registry;
  final String? Function(String seriesKey) preferredLanguageFor;
  final Future<Directory> Function() saveDirectory;

  /// 下载落盘前按视频内嵌字幕轨对时间轴；null = 不对齐。
  final Future<Uint8List> Function(Uint8List bytes, String videoPath)? aligner;

  Map<String, VideoSubtitleCandidate> _candidates =
      <String, VideoSubtitleCandidate>{};
  int _generation = 0;

  /// 检索。[query] / [episode] 为 null = 用 [context] 的默认值（身份种子、季号、
  /// 备选词只在检索词就是默认词时生效：手机改了词说明要按自己的词搜）。
  Future<VideoRemoteOnlineSubtitleSearch> search(
    RemoteOnlineSubtitleContext context, {
    String? query,
    int? episode,
  }) async {
    final String defaultQuery = context.defaultQuery.trim();
    final String effective = (query ?? defaultQuery).trim();
    final int? effectiveEpisode = query == null && episode == null
        ? context.episode
        : episode;
    if (effective.isEmpty) {
      return VideoRemoteOnlineSubtitleSearch(
        query: '',
        episode: effectiveEpisode,
        candidates: const <VideoRemoteOnlineSubtitle>[],
      );
    }
    final VideoSubtitleRegistry? sources = await registry();
    if (sources == null || sources.providers.isEmpty) {
      throw const VideoRemoteException(409, 'subtitle_source_missing');
    }
    final bool untouched = effective == defaultQuery;
    final SubtitleSearchSeed seed = context.seed;
    final int? anilistId = untouched ? seed.anilistId : null;
    final ProviderBatchResult<VideoSubtitleCandidate> result = await sources
        .search(
          VideoSubtitleSearchRequest(
            media: VideoMediaReference(
              providerId: 'anilist',
              mediaId: anilistId?.toString() ?? effective,
              mediaKind: seed.isMovie
                  ? VideoMetadataMediaKind.movie
                  : VideoMetadataMediaKind.tv,
              discoveryCategory: VideoDiscoveryCategory.anime,
              title: effective,
              originalTitle: untouched && seed.queries.isNotEmpty
                  ? seed.queries.first
                  : null,
              anilistId: anilistId,
              tmdbId: untouched ? seed.tmdbId : null,
              episode: effectiveEpisode,
            ),
            query: effective,
            alternateTitles: untouched
                ? seed.fallbackQueries
                : const <String>[],
            season: untouched ? context.season : null,
            episode: effectiveEpisode,
            fingerprint: await _fingerprint(context.videoPath),
          ),
        );
    if (result.items.isEmpty && result.failures.isNotEmpty) {
      throw const VideoRemoteException(502, 'subtitle_search_failed');
    }
    final List<JimakuCandidate> sorted = sortJimakuCandidates(
      <JimakuCandidate>[
        for (final VideoSubtitleCandidate candidate in result.items)
          JimakuCandidate.fromProvider(candidate),
      ],
      preferredLanguage: preferredLanguageFor(
        context.seriesQuery.trim().toLowerCase(),
      ),
    );
    final int generation = ++_generation;
    final Map<String, VideoSubtitleCandidate> byId =
        <String, VideoSubtitleCandidate>{};
    final List<VideoRemoteOnlineSubtitle> offers =
        <VideoRemoteOnlineSubtitle>[];
    for (int i = 0; i < sorted.length; i++) {
      final JimakuCandidate candidate = sorted[i];
      final VideoSubtitleCandidate? source = candidate.source;
      if (source == null) continue;
      final String id = '$generation.$i';
      byId[id] = source;
      offers.add(
        VideoRemoteOnlineSubtitle(
          id: id,
          fileName: candidate.name,
          provider: candidate.providerId,
          language: candidate.language,
          episode: candidate.episode,
          aiTranslated: source.aiTranslated,
          hearingImpaired: source.hearingImpaired,
        ),
      );
    }
    _candidates = byId;
    return VideoRemoteOnlineSubtitleSearch(
      query: effective,
      episode: effectiveEpisode,
      candidates: offers,
    );
  }

  /// 下载候选 [id] 落盘（文件名只取安全叶名、同名加序号），返回落盘路径；本机视频
  /// 按内嵌轨对齐时间轴（[videoPath] 为 null 不对齐）。
  Future<String> download(String id, {String? videoPath}) async {
    final VideoSubtitleCandidate? candidate = _candidates[id];
    if (candidate == null) {
      throw const VideoRemoteException(404, 'subtitle_candidate_missing');
    }
    final VideoSubtitleRegistry? sources = await registry();
    if (sources == null || sources.providers.isEmpty) {
      throw const VideoRemoteException(409, 'subtitle_source_missing');
    }
    final VideoSubtitleDownload download;
    try {
      download = await sources.download(candidate);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'RemoteOnlineSubtitleSearch.download',
        error,
        stack,
      );
      throw const VideoRemoteException(502, 'subtitle_download_failed');
    }
    if (download.bytes.isEmpty) {
      throw const VideoRemoteException(502, 'subtitle_download_failed');
    }
    final Directory dir = await saveDirectory();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final String dest = uniqueSubtitleDestination(
      dir.path,
      safeSubtitleFileName(download.fileName),
    );
    final Future<Uint8List> Function(Uint8List, String)? align = aligner;
    final Uint8List bytes = align != null && videoPath != null
        ? await align(download.bytes, videoPath)
        : download.bytes;
    await File(dest).writeAsBytes(bytes);
    return dest;
  }

  /// OpenSubtitles 按文件哈希精确匹配用的指纹；拿不到就退回按标题搜（与字幕工作台
  /// `_fingerprint` 同一口径，失败留诊断不报错）。
  Future<LocalVideoFingerprint?> _fingerprint(String? path) async {
    if (path == null || path.trim().isEmpty) return null;
    try {
      final File file = File(path);
      if (!await file.exists()) return null;
      return LocalVideoFingerprint(
        fileSize: await file.length(),
        openSubtitlesMovieHash: await computeOpenSubtitlesMovieHash(path),
        fileName: p.basename(path),
      );
    } on Object catch (error) {
      ErrorLogService.instance.logDiagnostic(
        'RemoteOnlineSubtitleSearch._fingerprint',
        error,
      );
      return null;
    }
  }
}
