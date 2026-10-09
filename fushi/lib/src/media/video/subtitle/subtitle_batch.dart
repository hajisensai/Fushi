/// 合集批量字幕下载的**来源无关**编排：对合集每一集在「一批候选」里按集号选一个 →
/// 经 [VideoSubtitleRegistry] 下载 → 落盘。持久化（本地写 DB / 远端写 prefs）由调用方在
/// [onItemDone] 里按 [SubtitleBatchTarget.isStream] 分派，本模块只负责下载落盘。
///
/// 此前这条路径只认 Jimaku（`jimaku_batch.dart` 直连 `JimakuClient`），OpenSubtitles /
/// AJATT 永远进不了批量。现在候选来自 registry，谁家的都一样；「哪一个文件是这一集的」
/// 仍只有一个判据：`chooseSubtitleForEpisode`（BUG-1695）。
library;

import 'dart:io';

import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart'
    show detectSubtitleLanguage, jimakuLanguageRank, parseSubtitleEpisode;
import 'package:fushi/src/media/video/subtitle/subtitle_episode_matching.dart';
import 'package:fushi_engine/media/video/subtitle/embedded_reference_subtitle_sync.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_archive.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:path/path.dart' as p;

/// 批量下载里的一集输入：稳定身份 + 定位信息 + 合集内序位。
class SubtitleBatchTarget {
  const SubtitleBatchTarget({
    required this.bookUid,
    required this.title,
    required this.videoPath,
    required this.sortIndex,
    required this.isStream,
  });

  /// 视频稳定身份（本地 = VideoBooks.bookUid，远端 = RemoteVideoInfo.id）。
  final String bookUid;

  /// 显示标题（用于解析集号 + UI 展示）。
  final String title;

  /// 视频路径（本地绝对路径 / http(s) 流 URL）；也用于解析集号。
  final String videoPath;

  /// 合集内序位（MediaCollectionItems.sortIndex，0-based）。解析不出真实集号时的兜底。
  final int sortIndex;

  /// 是否流媒体（videoPath 为 http/https）。决定持久化落 DB 还是 prefs。
  final bool isStream;
}

/// 一集在批量下载里的状态。
enum SubtitleBatchStatus {
  /// 排队中，尚未处理。
  pending,

  /// 正在下载。
  downloading,

  /// 已下载并（由调用方）持久化。
  done,

  /// 该集在所选来源无匹配字幕文件。
  noMatch,

  /// 下载/落盘失败。
  failed,
}

/// 一集的批量结果（可变：随处理推进更新 [status] 等）。
class SubtitleBatchItem {
  SubtitleBatchItem({required this.target, required this.episode});

  final SubtitleBatchTarget target;

  /// 用于匹配的集号（[resolveSubtitleBatchEpisode]）。
  final int episode;

  SubtitleBatchStatus status = SubtitleBatchStatus.pending;

  /// 下载落盘的字幕文件绝对路径（成功时非空）。
  String? subtitlePath;

  /// 选中字幕的语言代码（`ja`/`zh`/...；来源没给且认不出为 null）。
  String? language;

  /// 失败/无匹配时的简短原因（UI 副标题）。
  String? message;
}

/// 解析该集用于匹配的真实集号：优先从视频路径文件名 / 标题解析（`第N話` / `E01` /
/// `SxxEyy` / `- 12` 等），认不出退回 `sortIndex + 1`（合集内序位转 1-based）。
///
/// 用真实集号而非 sortIndex：sortIndex 可被用户拖拽重排、或合集含缺集/特典而与真实
/// 集号错位，直接拿它当集号会错配。纯函数，便于单测。
int resolveSubtitleBatchEpisode(SubtitleBatchTarget target) {
  final int? fromPath = parseVideoFilename(
    p.basename(target.videoPath),
  ).episode;
  if (fromPath != null) return fromPath;
  final int? fromTitle = parseVideoFilename(target.title).episode;
  if (fromTitle != null) return fromTitle;
  return target.sortIndex + 1;
}

/// 批量下载落盘的文件名：以稳定 bookUid（清洗成合法文件名段）为前缀，避免多集拿到同名
/// 文件（整季打包字幕对不同集同名）时互相覆盖。纯函数，便于单测。
String batchSubtitleFileName(String bookUid, String fileName) {
  final String safe = bookUid.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return '${safe}__$fileName';
}

/// 合集批量里的整季压缩包拆分：每个包只下载一次（registry 的下载结果带回包内全部
/// 文本字幕 [VideoSubtitleDownload.archiveEntries]），再按集号逐集取文件。
///
/// 包按语言偏好排序，先试首选语言的包；解不开的格式（RAR / 7z）不下载，只在
/// [failureReason] 里说明——让该集显示「格式不支持」而不是「没有字幕」。
class _ArchivePackSplitter {
  _ArchivePackSplitter({
    required this.registry,
    required List<VideoSubtitleCandidate> candidates,
    this.preferredLanguage,
  }) : _packs =
           <VideoSubtitleCandidate>[
             for (final VideoSubtitleCandidate c in candidates)
               if (c.archiveFormat?.isSupported ?? false) c,
           ]..sort(
             (VideoSubtitleCandidate a, VideoSubtitleCandidate b) =>
                 compareCandidatesByLanguagePreference(a, b, preferredLanguage),
           ),
       _hasUnsupported = candidates.any(
         (VideoSubtitleCandidate c) =>
             c.archiveFormat != null && !c.archiveFormat!.isSupported,
       );

  final VideoSubtitleRegistry registry;
  final String? preferredLanguage;
  final List<VideoSubtitleCandidate> _packs;
  final bool _hasUnsupported;
  final Map<String, Future<VideoSubtitleDownload?>> _downloads =
      <String, Future<VideoSubtitleDownload?>>{};
  Object? _lastError;

  /// 本集没从任何包里拆出文件时的原因（没有包可试时为 null，交回单文件判据）。
  String? get failureReason {
    if (_lastError != null) return 'archive: $_lastError';
    if (_packs.isNotEmpty) return 'season pack has no file for this episode';
    if (_hasUnsupported) return 'season pack format is not supported';
    return null;
  }

  Future<VideoSubtitleDownload?> subtitleFor(
    int episode, {
    required bool soleTarget,
  }) async {
    for (final VideoSubtitleCandidate pack in _packs) {
      final VideoSubtitleDownload? download =
          await (_downloads[pack.identityKey] ??= _download(pack));
      if (download == null) continue;
      // 真整季包逐文件认语言；单文件下载保留 provider 已解析的标签。
      String languageOf(ArchivedSubtitle entry) =>
          download.archiveEntries.isEmpty && download.language.isNotEmpty
          ? download.language
          : detectSubtitleLanguage(entry.fileName) ?? pack.language;
      final List<ArchivedSubtitle> entries =
          List<ArchivedSubtitle>.of(
            download.archiveEntries.isEmpty
                ? <ArchivedSubtitle>[
                    ArchivedSubtitle(
                      fileName: download.fileName,
                      bytes: download.bytes,
                    ),
                  ]
                : download.archiveEntries,
          )..sort((ArchivedSubtitle a, ArchivedSubtitle b) {
            final int rankA = jimakuLanguageRank(
              languageOf(a),
              preferred: preferredLanguage,
            );
            final int rankB = jimakuLanguageRank(
              languageOf(b),
              preferred: preferredLanguage,
            );
            if (rankA != rankB) return rankA.compareTo(rankB);
            return a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());
          });
      // 多目标时只认集号精确命中：一个文件发给 N 集等于静默装错。
      ArchivedSubtitle? picked;
      for (final ArchivedSubtitle entry in entries) {
        if (parseSubtitleEpisode(entry.fileName) == episode) {
          picked = entry;
          break;
        }
      }
      if (picked == null && soleTarget && entries.length == 1) {
        picked = entries.single;
      }
      if (picked == null) continue;
      return VideoSubtitleDownload(
        bytes: picked.bytes,
        fileName: picked.fileName,
        language: languageOf(picked),
      );
    }
    return null;
  }

  Future<VideoSubtitleDownload?> _download(VideoSubtitleCandidate pack) async {
    try {
      return await registry.download(pack);
    } on Object catch (error) {
      _lastError = error;
      return null;
    }
  }
}

/// 每集处理完（下载落盘后，含 noMatch/failed）的回调；调用方据此持久化 + 刷新 UI。
typedef SubtitleBatchItemCallback =
    Future<void> Function(SubtitleBatchItem item);

/// 编排合集批量字幕下载：对 [targets] 逐集在 [candidates]（用户选定的一个来源的**全部**
/// 文本字幕候选，整批只列一次，见 BUG-1695）里按集号选一个 → 经 [registry] 下载 →
/// 落 [saveDirectory]。每集处理前后各回调一次（[onItemStart] / [onItemDone]）。
///
/// 尽力而为：单集失败/无匹配不中断整批（记该集状态后继续）。返回全部集的结果。
Future<List<SubtitleBatchItem>> runSubtitleBatch({
  required VideoSubtitleRegistry registry,
  required List<VideoSubtitleCandidate> candidates,
  required List<SubtitleBatchTarget> targets,
  required String saveDirectory,
  String? preferredLanguage,
  SubtitleBatchItemCallback? onItemStart,
  SubtitleBatchItemCallback? onItemDone,
  AutomaticSubtitleAligner? subtitleAligner,
}) async {
  final List<SubtitleBatchItem> results = <SubtitleBatchItem>[];
  final Directory dir = Directory(saveDirectory);
  final bool soleTarget = targets.length == 1;
  final SubtitleEpisodeIndex<VideoSubtitleCandidate> index =
      SubtitleEpisodeIndex.fromCandidates(
        candidates,
        preferredLanguage: preferredLanguage,
      );
  final _ArchivePackSplitter packs = _ArchivePackSplitter(
    registry: registry,
    candidates: candidates,
    preferredLanguage: preferredLanguage,
  );
  for (final SubtitleBatchTarget target in targets) {
    final SubtitleBatchItem item = SubtitleBatchItem(
      target: target,
      episode: resolveSubtitleBatchEpisode(target),
    );
    item.status = SubtitleBatchStatus.downloading;
    if (onItemStart != null) await onItemStart(item);
    try {
      final SubtitleEpisodeMatch<VideoSubtitleCandidate> match =
          chooseSubtitleForEpisode(
            index,
            episode: item.episode,
            soleTarget: soleTarget,
          );
      final VideoSubtitleCandidate? best = match.file;
      // 没有单集文件时，从整季压缩包里按集号拆（整包只下一次）。
      final VideoSubtitleDownload? fromPack = best == null
          ? await packs.subtitleFor(item.episode, soleTarget: soleTarget)
          : null;
      if (best == null && fromPack == null) {
        item.status = SubtitleBatchStatus.noMatch;
        // 「为什么没配上」对用户是三件不同的事（改来源 / 等字幕 / 无能为力），
        // 别全压成一句「无匹配」。
        item.message = packs.failureReason ?? match.failureReason;
      } else {
        final VideoSubtitleDownload download =
            fromPack ?? await registry.download(best!);
        if (download.bytes.isEmpty) {
          item.status = SubtitleBatchStatus.failed;
          item.message = 'download';
        } else {
          if (!dir.existsSync()) dir.createSync(recursive: true);
          final String dest = p.join(
            dir.path,
            batchSubtitleFileName(target.bookUid, download.fileName),
          );
          // 流媒体没有本地文件可读内嵌轨，对齐器自己会原样返回。网络路径
          // （UNC / smb:// …）是后台批量，不抽内嵌轨——整片 demux 走网络等于把整部
          // 视频拉一遍，原样写。
          await File(dest).writeAsBytes(
            subtitleAligner == null || isNetworkMediaPath(target.videoPath)
                ? download.bytes
                : await subtitleAligner(download.bytes, target.videoPath),
          );
          item.subtitlePath = dest;
          item.language = download.language.isEmpty ? null : download.language;
          item.status = SubtitleBatchStatus.done;
        }
      }
    } catch (e) {
      item.status = SubtitleBatchStatus.failed;
      item.message = '$e';
    }
    if (onItemDone != null) await onItemDone(item);
    results.add(item);
  }
  return results;
}
