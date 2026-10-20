import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_search_seed.dart';
import 'package:fushi/src/pages/implementations/subtitle_search_panel.dart'
    show
        JimakuCandidate,
        safeSubtitleFileName,
        sortJimakuCandidates,
        uniqueSubtitleDestination;
import 'package:fushi/src/sync/video_remote_host.dart'
    show VideoRemoteSubtitleCandidate, VideoRemoteSubtitleSearchResult;
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/embedded_reference_subtitle_sync.dart'
    show AutomaticSubtitleAligner;
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';
import 'package:path/path.dart' as p;

/// 正在播放的这一集「找字幕」时的预填：与字幕工作台（`SubtitleWorkbenchPage` 的
/// 「本集」页签）同一份番名、身份种子、集号、季号与本地视频路径。
@immutable
class VideoRemoteSubtitleTarget {
  const VideoRemoteSubtitleTarget({
    required this.initialQuery,
    required this.seed,
    this.episode,
    this.season,
    this.videoPath,
    this.preferredLanguage,
  });

  /// 视频页算出的番名（`_jimakuQuery`），即工作台输入框的原始词。
  final String initialQuery;
  final SubtitleSearchSeed seed;
  final int? episode;
  final int? season;

  /// 本地视频文件（远端流为 null）：OpenSubtitles 按文件哈希精确匹配、下载后按内嵌轨对轴。
  final String? videoPath;

  /// 排序用的优先语言（该系列记忆的语言 / 设置页默认语言）。
  final String? preferredLanguage;

  /// 工作台输入框实际预填的词：有身份种子用种子的主词，否则番名。
  String get prefillQuery =>
      seed.primaryQuery.isEmpty ? initialQuery : seed.primaryQuery;
}

/// 手机遥控「在线字幕」的电脑侧执行体：用字幕工作台同一个 [VideoSubtitleRegistry]
/// 搜候选、按工作台同一套规则下载落盘（安全叶名、不覆盖、可选按内嵌轨对轴）。
///
/// 候选只留在电脑上：手机拿到的是 [VideoSubtitleCandidate.identityKey] 句柄，下载时
/// 凭句柄取回原候选交还给它自己的 provider。句柄表随视频页存活（换集 = 新页 = 新表），
/// 上限 [maxCandidates]，超出按最早登记的先丢。
class VideoRemoteSubtitleSearcher {
  VideoRemoteSubtitleSearcher({
    required this.registry,
    required this.saveDirectory,
    this.aligner,
  });

  /// 每次现取（填 / 改 API key 会重建 provider runtime，早绑的实例会过期）。
  final Future<VideoSubtitleRegistry?> Function() registry;

  /// 下载落盘目录（`AppPaths.videoSubtitlesDirectory()`）。
  final Future<String> Function() saveDirectory;

  /// 下载后按视频内嵌文本轨对轴（远端流 / 没装配时原样写盘）。
  final AutomaticSubtitleAligner? Function()? aligner;

  /// 句柄表上限：一次搜索最多回 [kVideoRemoteSubtitleMaxCandidates] 条，留几轮余量。
  static const int maxCandidates = 400;

  final LinkedHashMap<String, VideoSubtitleCandidate> _candidates =
      LinkedHashMap<String, VideoSubtitleCandidate>();

  /// 搜 [target]。[query] / [episode] 为 null 时用工作台的预填（番名 + 身份种子 +
  /// 当前集号）；用户改过搜索词就只按他写的词搜，不再套刮削身份与原视频季号
  /// （与工作台「untouchedQuery」同一判据）。
  Future<VideoRemoteSubtitleSearchResult> search(
    VideoRemoteSubtitleTarget target, {
    String? query,
    int? episode,
  }) async {
    final String searched = query ?? target.prefillQuery;
    final int? searchedEpisode = query == null && episode == null
        ? target.episode
        : episode;
    final VideoSubtitleRegistry? sources = await registry();
    if (sources == null || sources.providers.isEmpty) {
      return VideoRemoteSubtitleSearchResult(
        query: searched,
        episode: searchedEpisode,
        candidates: const <VideoRemoteSubtitleCandidate>[],
        error: 'no_source',
      );
    }
    final bool untouched = searched == target.prefillQuery;
    final SubtitleSearchSeed seed = target.seed;
    final int? anilistId = untouched ? seed.anilistId : null;
    final ProviderBatchResult<VideoSubtitleCandidate> result = await sources
        .search(
          VideoSubtitleSearchRequest(
            media: VideoMediaReference(
              providerId: 'anilist',
              mediaId: anilistId?.toString() ?? searched,
              mediaKind: seed.isMovie
                  ? VideoMetadataMediaKind.movie
                  : VideoMetadataMediaKind.tv,
              discoveryCategory: VideoDiscoveryCategory.anime,
              title: searched,
              originalTitle: untouched && seed.queries.isNotEmpty
                  ? seed.queries.first
                  : null,
              anilistId: anilistId,
              tmdbId: untouched ? seed.tmdbId : null,
              episode: searchedEpisode,
            ),
            query: searched,
            alternateTitles: untouched
                ? seed.fallbackQueries
                : const <String>[],
            season: untouched ? target.season : null,
            episode: searchedEpisode,
            fingerprint: await _fingerprint(target.videoPath),
          ),
        );
    final List<JimakuCandidate> sorted = sortJimakuCandidates(<JimakuCandidate>[
      for (final VideoSubtitleCandidate candidate in result.items)
        JimakuCandidate.fromProvider(candidate),
    ], preferredLanguage: target.preferredLanguage);
    final List<VideoRemoteSubtitleCandidate> candidates =
        <VideoRemoteSubtitleCandidate>[];
    for (final JimakuCandidate row in sorted) {
      final VideoSubtitleCandidate? source = row.source;
      if (source == null) continue;
      if (candidates.length >= kVideoRemoteSubtitleMaxCandidates) break;
      _remember(source);
      candidates.add(
        VideoRemoteSubtitleCandidate(
          handle: source.identityKey,
          provider: source.providerId,
          fileName: source.fileName,
          language: row.language ?? '',
          episode: row.episode,
          downloadCount: source.downloadCount,
          aiTranslated: source.aiTranslated,
          hearingImpaired: source.hearingImpaired,
        ),
      );
    }
    return VideoRemoteSubtitleSearchResult(
      query: searched,
      episode: searchedEpisode,
      candidates: candidates,
      // 一条都没有且有来源失败 = 「没问到」，不是「没有字幕」（BUG-1844 同理）。
      error: candidates.isEmpty && result.failures.isNotEmpty
          ? 'search_failed'
          : null,
    );
  }

  /// 下载句柄 [handle] 对应的候选并落盘，返回本机路径。句柄过期（页面重开 / 被挤出
  /// 句柄表）抛 `404 subtitle_candidate_missing`，下载失败抛
  /// `502 subtitle_download_failed`。
  Future<String> download(String handle, {String? videoPath}) async {
    final VideoSubtitleCandidate? candidate = _candidates[handle];
    if (candidate == null) {
      throw const VideoRemoteException(404, 'subtitle_candidate_missing');
    }
    final VideoSubtitleRegistry? sources = await registry();
    if (sources == null) {
      throw const VideoRemoteException(502, 'subtitle_download_failed');
    }
    final VideoSubtitleDownload download;
    try {
      download = await sources.download(candidate);
    } on Object {
      throw const VideoRemoteException(502, 'subtitle_download_failed');
    }
    if (download.bytes.isEmpty) {
      throw const VideoRemoteException(502, 'subtitle_download_failed');
    }
    final Directory dir = Directory(await saveDirectory());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // 文件名来自远端 provider，只取安全叶名（BUG-1845）。
    final String dest = uniqueSubtitleDestination(
      dir.path,
      safeSubtitleFileName(
        download.fileName.isNotEmpty ? download.fileName : candidate.fileName,
      ),
    );
    final AutomaticSubtitleAligner? align = aligner?.call();
    final Uint8List bytes = align == null || videoPath == null
        ? download.bytes
        : await align(download.bytes, videoPath);
    await File(dest).writeAsBytes(bytes);
    return dest;
  }

  void _remember(VideoSubtitleCandidate candidate) {
    _candidates.remove(candidate.identityKey);
    _candidates[candidate.identityKey] = candidate;
    while (_candidates.length > maxCandidates) {
      _candidates.remove(_candidates.keys.first);
    }
  }

  static Future<LocalVideoFingerprint?> _fingerprint(String? path) async {
    if (path == null || path.trim().isEmpty) return null;
    try {
      final File file = File(path);
      if (!await file.exists()) return null;
      return LocalVideoFingerprint(
        fileSize: await file.length(),
        openSubtitlesMovieHash: await computeOpenSubtitlesMovieHash(path),
        fileName: p.basename(path),
      );
    } on Object {
      // 指纹只是精确匹配的捷径，算不出照常按词搜。
      return null;
    }
  }
}

/// 一次回给手机的候选上限（防整季包把响应撑爆；与扩展「查字幕」桥同一量级）。
const int kVideoRemoteSubtitleMaxCandidates = 100;
