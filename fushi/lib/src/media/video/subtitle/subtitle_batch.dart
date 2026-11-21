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
import 'package:fushi/src/media/video/subtitle/subtitle_version_groups.dart'
    show subtitleVersionKeyOf;
import 'package:fushi_engine/media/video/subtitle/subtitle_content_language.dart'
    show SubtitleContentLanguage, coarseLanguageCode;
import 'package:fushi/src/media/video/subtitle/subtitle_version_language_probe.dart'
    show probeUnlabeledVersionLanguages;
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
    this.season,
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

  /// 可选显式季号（1-based）；为 null 时从路径 / 标题解析。
  final int? season;
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

  /// 用户中途停止了批量，这一集还没开始就被跳过（没有下载、没有落盘）。
  skipped,
}

/// [SubtitleBatchStatus.failed] 是在哪一步失败的。三步对用户是三件不同的事：没下下来
/// （换来源 / 等等再试）、下下来了但写不进本地（磁盘满 / 无权限）、写好了但没能设为
/// 这一集的字幕（数据库 / 宿主登记失败）——后两种说成「下载失败」会让用户去换来源。
enum SubtitleBatchFailureStage {
  /// 下载（含从整季包里拆）失败或拿到空内容。
  download,

  /// 下载到了，对时间轴 / 写盘失败。
  write,

  /// 已落盘，调用方的持久化回调（设为这一集的字幕）抛错。
  persist,
}

/// 一集的批量结果（可变：随处理推进更新 [status] 等）。
class SubtitleBatchItem {
  SubtitleBatchItem({required this.target, required this.episode, this.season});

  final SubtitleBatchTarget target;

  /// 用于匹配的集号（[resolveSubtitleBatchEpisode]）。
  final int episode;

  /// 用于匹配的季号（[resolveSubtitleBatchSeason]）；未知或单季不限时为 null。
  final int? season;

  SubtitleBatchStatus status = SubtitleBatchStatus.pending;

  /// 下载落盘的字幕文件绝对路径（成功时非空）。
  String? subtitlePath;

  /// 选中字幕的语言代码（`ja`/`zh`/...；来源没给且认不出为 null）。
  String? language;

  /// 失败/无匹配时的简短原因（诊断用的英文短句，不直接给用户看）。
  String? message;

  /// 失败/无匹配背后的**异常对象**（没有异常时为 null）。
  ///
  /// [message] 是 `'$e'` 字符串，分不出 401（key 过期）/ 429（限流）/ 404（文件
  /// 下架）；面板要把它喂给 `describeSubtitleFailure` 才能说出用户能据以行动的原因，
  /// 所以对象本身得留着。
  Object? error;

  /// [SubtitleBatchStatus.failed] 时失败在哪一步；其余状态为 null。
  SubtitleBatchFailureStage? failureStage;
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

/// 解析该集用于匹配的季号：优先显式 [SubtitleBatchTarget.season] → 完整视频路径
/// （含父目录 `Show/Season 2/01.mkv`）→ 标题；认不出为 null。纯函数，便于单测。
int? resolveSubtitleBatchSeason(SubtitleBatchTarget target) {
  final int? explicit = target.season;
  if (explicit != null && explicit > 0) return explicit;
  final int? fromPath = parseVideoPath(target.videoPath).season;
  if (fromPath != null && fromPath > 0) return fromPath;
  final int? fromTitle = parseVideoFilename(target.title).season;
  if (fromTitle != null && fromTitle > 0) return fromTitle;
  return null;
}

int? _seasonFromSubtitleFileName(String fileName) {
  String stem = p.basename(fileName.trim());
  if (stem.isEmpty) return null;
  final int dot = stem.lastIndexOf('.');
  if (dot > 0) {
    final String ext = stem.substring(dot + 1).toLowerCase();
    if (const <String>{
      'srt',
      'ass',
      'ssa',
      'vtt',
      'zip',
      'rar',
      '7z',
    }.contains(ext)) {
      stem = stem.substring(0, dot);
    }
  }
  final int dot2 = stem.lastIndexOf('.');
  if (dot2 > 0) {
    final String tail = stem.substring(dot2 + 1);
    if (detectSubtitleLanguage('_.$tail.srt') != null) {
      stem = stem.substring(0, dot2);
    }
  }
  final int? season = parseVideoFilename(stem).season;
  return season != null && season > 0 ? season : null;
}

/// 从字幕候选取出它的季号：优先来源声明的 [VideoSubtitleCandidate.season]，
/// 否则从文件名解析（`S02E01` 等）；认不出为 null。纯函数。
int? subtitleCandidateSeason(VideoSubtitleCandidate candidate) {
  final int? declared = candidate.season;
  if (declared != null && declared > 0) return declared;
  return _seasonFromSubtitleFileName(candidate.fileName);
}

bool _matchesSeason(
  int? candidateSeason, {
  required int? season,
  required bool allowUnseasoned,
}) {
  if (season == null) return allowUnseasoned;
  if (candidateSeason == season) return true;
  return candidateSeason == null && allowUnseasoned;
}

/// 按目标季号过滤字幕候选。纯函数。
///
/// - [season] 为 null：保留全部（[allowUnseasoned] 为 false 时仅当无法容忍未知季号
///   才返回空）。
/// - [season] 非 null：保留属于该季的候选；季号未知的候选仅在 [allowUnseasoned]
///   为 true（单季场景）时保留，多季混跑时拒绝，防止第一季未标季号的字幕静默套用到
///   其它季。
List<VideoSubtitleCandidate> filterSubtitleCandidatesForSeason(
  List<VideoSubtitleCandidate> candidates, {
  required int? season,
  bool allowUnseasoned = true,
}) {
  if (season == null) {
    return allowUnseasoned ? candidates : const <VideoSubtitleCandidate>[];
  }
  return <VideoSubtitleCandidate>[
    for (final VideoSubtitleCandidate c in candidates)
      if (_matchesSeason(
        subtitleCandidateSeason(c),
        season: season,
        allowUnseasoned: allowUnseasoned,
      ))
        c,
  ];
}

/// 前缀最多保留多少字符的 bookUid 原文：加上 8 位摘要与分隔符后仍远短于文件名上限。
const int _kBatchPrefixChars = 32;

/// 叶名（字幕文件名本身）裁剪上限：Windows 单个文件名不能超过 255 字符，且整条路径
/// 还要留给保存目录。100 足够认人，也够长名字的 BD 命名。
const int _kBatchLeafChars = 100;

/// 批量下载落盘的文件名：以稳定 bookUid（清洗成合法文件名段）为前缀，避免多集拿到同名
/// 文件（整季打包字幕对不同集同名）时互相覆盖。纯函数，便于单测。
///
/// 前缀必须**有上限**：流媒体成员的 bookUid 是整条 `anime-source://<扩展>/<id>/<签名>/
/// …&epurl=…` 播放描述，实测 407 字符；原样拼进文件名会让单个文件名达到约 460 字符，
/// 超过 Windows 每个文件名分段 255 字符的硬上限，`File.writeAsBytes` 抛 ERROR_INVALID_NAME
/// （EINVAL）——表现就是**流媒体合集的「下载全部」每一集都「下载失败」，而本集面板
/// （用 safeSubtitleFileName，不带 uid 前缀）和本地视频合集（bookUid 短）都正常**。
/// 超长 uid 改用「前 32 字符 + 8 位 FNV-1a 摘要」：仍然稳定、仍然跨集唯一。
String batchSubtitleFileName(String bookUid, String fileName) {
  final String safe = bookUid.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final String prefix = safe.length <= _kBatchPrefixChars
      ? safe
      : '${safe.substring(0, _kBatchPrefixChars)}_${_fnv1aHex(safe)}';
  return '${prefix}__${_clipSubtitleLeafName(fileName)}';
}

/// 32 位 FNV-1a（十六进制、定长 8 位）：只用来在截断前缀后保持跨集唯一，不做安全用途。
String _fnv1aHex(String value) {
  int hash = 0x811c9dc5;
  for (final int unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// 把远端文件名裁到 [_kBatchLeafChars]，保留扩展名（短扩展名才有意义）。
String _clipSubtitleLeafName(String fileName) {
  if (fileName.length <= _kBatchLeafChars) return fileName;
  final int dot = fileName.lastIndexOf('.');
  final String extension = dot > 0 && fileName.length - dot <= 8
      ? fileName.substring(dot)
      : '';
  return fileName.substring(0, _kBatchLeafChars - extension.length) + extension;
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
       _unsupportedPacks = <VideoSubtitleCandidate>[
         for (final VideoSubtitleCandidate c in candidates)
           if (c.archiveFormat != null && !c.archiveFormat!.isSupported) c,
       ];

  final VideoSubtitleRegistry registry;
  final String? preferredLanguage;
  final List<VideoSubtitleCandidate> _packs;
  final List<VideoSubtitleCandidate> _unsupportedPacks;
  final Map<String, Future<VideoSubtitleDownload?>> _downloads =
      <String, Future<VideoSubtitleDownload?>>{};

  /// 下载失败的包（identityKey → 异常）。包的下载结果整批只取一次，不重试。
  final Map<String, Object> _errors = <String, Object>{};

  static bool _packMayServeSeason(int? packSeason, int? targetSeason) =>
      targetSeason == null || packSeason == null || packSeason == targetSeason;

  List<VideoSubtitleCandidate> _packsForSeason(int? season) =>
      <VideoSubtitleCandidate>[
        for (final VideoSubtitleCandidate pack in _packs)
          if (_packMayServeSeason(subtitleCandidateSeason(pack), season)) pack,
      ];

  /// 对 [season] 可试的包中是否有下载失败。
  bool hasFailureFor(int? season) {
    for (final VideoSubtitleCandidate pack in _packsForSeason(season)) {
      if (_errors.containsKey(pack.identityKey)) return true;
    }
    return false;
  }

  /// 对 [season] **每一个**可试的包都没下下来时，首选包的那次异常；否则 null。
  ///
  /// 只在一集没从任何包里拆出文件之后读（那时所有包都已试过）。只要有一个包下成功，
  /// 这一集没配上的原因就是「包里没有这一集」，不是别的包的下载失败——把后者挂到
  /// 这一集上，行文案会说成「连不上来源」。
  Object? allPacksFailedErrorFor(int? season) {
    final List<VideoSubtitleCandidate> applicable = _packsForSeason(season);
    if (applicable.isEmpty) return null;
    for (final VideoSubtitleCandidate pack in applicable) {
      if (!_errors.containsKey(pack.identityKey)) return null;
    }
    return _errors[applicable.first.identityKey];
  }

  /// 本集没从任何包里拆出文件时的原因（没有对 [season] 可试的包时为 null，交回单文件判据）。
  String? failureReasonFor(int? season) {
    final List<VideoSubtitleCandidate> applicable = _packsForSeason(season);
    Object? lastError;
    for (final VideoSubtitleCandidate pack in applicable) {
      final Object? err = _errors[pack.identityKey];
      if (err != null) lastError = err;
    }
    if (lastError != null) return 'archive: $lastError';
    if (applicable.isNotEmpty) {
      return 'season pack has no file for this episode';
    }
    if (_unsupportedPacks.any(
      (VideoSubtitleCandidate pack) =>
          _packMayServeSeason(subtitleCandidateSeason(pack), season),
    )) {
      return 'season pack format is not supported';
    }
    return null;
  }

  Future<({VideoSubtitleDownload? download, bool seasonMismatch})> subtitleFor(
    int episode, {
    int? season,
    required bool soleTarget,
    bool allowUnseasoned = true,
  }) async {
    bool sawSeasonMismatch = _packs.any(
      (VideoSubtitleCandidate pack) =>
          !_packMayServeSeason(subtitleCandidateSeason(pack), season),
    );
    for (final VideoSubtitleCandidate pack in _packsForSeason(season)) {
      final int? packSeason = subtitleCandidateSeason(pack);
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
      // 多目标时只认集号精确命中；按季隔离且优先季号精确命中的文件。
      ArchivedSubtitle? exactSeason;
      ArchivedSubtitle? fallbackUnseasoned;
      for (final ArchivedSubtitle entry in entries) {
        if (parseSubtitleEpisode(entry.fileName) != episode) continue;
        final int? entrySeason = _seasonFromSubtitleFileName(entry.fileName);
        if (season != null && entrySeason != null && entrySeason != season) {
          sawSeasonMismatch = true;
          continue;
        }
        if (season != null &&
            entrySeason == null &&
            !allowUnseasoned &&
            packSeason != season) {
          sawSeasonMismatch = true;
          continue;
        }
        if (season != null && entrySeason == season) {
          exactSeason ??= entry;
          break;
        }
        fallbackUnseasoned ??= entry;
        if (season == null) break;
      }
      ArchivedSubtitle? picked = exactSeason ?? fallbackUnseasoned;
      if (picked == null && soleTarget && entries.length == 1) {
        final ArchivedSubtitle only = entries.single;
        final int? entrySeason = _seasonFromSubtitleFileName(only.fileName);
        final bool conflict =
            season != null && entrySeason != null && entrySeason != season;
        final bool ambiguous =
            season != null &&
            entrySeason == null &&
            !allowUnseasoned &&
            packSeason != season;
        if (conflict || ambiguous) {
          sawSeasonMismatch = true;
        } else {
          picked = only;
        }
      }
      if (picked == null) continue;
      return (
        download: VideoSubtitleDownload(
          bytes: picked.bytes,
          fileName: picked.fileName,
          language: languageOf(picked),
        ),
        seasonMismatch: sawSeasonMismatch,
      );
    }
    return (download: null, seasonMismatch: sawSeasonMismatch);
  }

  Future<VideoSubtitleDownload?> _download(VideoSubtitleCandidate pack) async {
    try {
      return await registry.download(pack);
    } on Object catch (error) {
      _errors[pack.identityKey] = error;
      return null;
    }
  }
}

/// [results] 里带异常的集，按异常对象 `identical` 去重、各留最先出现的那一集。
///
/// 一个整季包下载失败会让它覆盖的每一集都带上**同一个**异常对象（包只下一次）；
/// 记日志时逐集各记一条，12 集的季就是 12 条一模一样的报错。
List<SubtitleBatchItem> subtitleBatchDistinctFailures(
  List<SubtitleBatchItem> results,
) {
  final List<SubtitleBatchItem> distinct = <SubtitleBatchItem>[];
  for (final SubtitleBatchItem item in results) {
    final Object? error = item.error;
    if (error == null) continue;
    if (distinct.any((SubtitleBatchItem d) => identical(d.error, error))) {
      continue;
    }
    distinct.add(item);
  }
  return distinct;
}

/// 每集处理完（下载落盘后，含 noMatch/failed）的回调；调用方据此持久化 + 刷新 UI。
typedef SubtitleBatchItemCallback =
    Future<void> Function(SubtitleBatchItem item);

/// 编排合集批量字幕下载：对 [targets] 逐集在 [candidates]（用户选定的一个来源的**全部**
/// 文本字幕候选，整批只列一次，见 BUG-1695）里按集号选一个 → 经 [registry] 下载 →
/// 落 [saveDirectory]。每集处理前后各回调一次（[onItemStart] / [onItemDone]）。
///
/// [download]：候选下载入口，**由调用方持有缓存**时传入（合集面板：探测下过的代表
/// 文件被选中时不再下第二次，探测与批量并发时也只下一份）；不传则本次批量内按
/// identityKey 去重后经 [registry] 下载。
///
/// [probedVersionLanguages]：调用方已经探过的版本（版本键 → 正文语言，null = 探过
/// 但判不出）。这些版本不再重探——「判不出」也是结论。
///
/// 尽力而为：单集失败/无匹配不中断整批（记该集状态后继续）。返回全部集的结果。
/// [onItemDone] 抛错（调用方的持久化失败）同样只算**这一集**失败：状态改记
/// [SubtitleBatchStatus.failed]、异常留在 [SubtitleBatchItem.error]，已落盘的
/// [SubtitleBatchItem.subtitlePath] 保留，后面的集照常处理。
///
/// [isCancelled]：每集**开始前**问一次；返回 true 后不再开始新的一集，正在下载 /
/// 对齐 / 落盘的那一集照常做完（不留半个字幕文件），其余集记
/// [SubtitleBatchStatus.skipped] 并逐集回调 [onItemDone]（不回调 [onItemStart]）。
/// 只有用户显式点「停止」才取消——关掉工作台不取消（BUG-4496）。
Future<List<SubtitleBatchItem>> runSubtitleBatch({
  required VideoSubtitleRegistry registry,
  required List<VideoSubtitleCandidate> candidates,
  required List<SubtitleBatchTarget> targets,
  required String saveDirectory,
  String? preferredLanguage,
  SubtitleBatchItemCallback? onItemStart,
  SubtitleBatchItemCallback? onItemDone,
  AutomaticSubtitleAligner? subtitleAligner,
  Future<VideoSubtitleDownload> Function(VideoSubtitleCandidate candidate)?
  download,
  Map<String, SubtitleContentLanguage?> probedVersionLanguages =
      const <String, SubtitleContentLanguage?>{},
  bool Function()? isCancelled,
}) async {
  final List<SubtitleBatchItem> results = <SubtitleBatchItem>[];
  final Directory dir = Directory(saveDirectory);
  final bool soleTarget = targets.length == 1;
  final List<int> episodes = <int>[
    for (final SubtitleBatchTarget target in targets)
      resolveSubtitleBatchEpisode(target),
  ];
  final List<int?> rawSeasons = <int?>[
    for (final SubtitleBatchTarget target in targets)
      resolveSubtitleBatchSeason(target),
  ];
  final Set<int> knownSeasons = <int>{
    for (final int? s in rawSeasons)
      if (s != null) s,
  };
  final bool hasUnseasonedTarget = rawSeasons.any((int? s) => s == null);
  final bool hasMultipleTargetSeasons =
      knownSeasons.length >= 2 ||
      (hasUnseasonedTarget && knownSeasons.any((int s) => s >= 2));
  final List<int?> targetSeasons = <int?>[
    for (final int? s in rawSeasons) hasMultipleTargetSeasons ? (s ?? 1) : s,
  ];
  final bool allowUnseasoned = !hasMultipleTargetSeasons;

  bool matchesTargetForProbe(VideoSubtitleCandidate c) {
    final int? candSeason = subtitleCandidateSeason(c);
    for (int i = 0; i < targets.length; i++) {
      if (!_matchesSeason(
        candSeason,
        season: targetSeasons[i],
        allowUnseasoned: allowUnseasoned,
      )) {
        continue;
      }
      if (c.episode == null || c.episode == episodes[i]) return true;
    }
    return false;
  }

  // 同一候选只下一次：语言探测下过的代表文件，被选中时直接复用。
  final Map<String, Future<VideoSubtitleDownload>> localDownloads =
      <String, Future<VideoSubtitleDownload>>{};
  final Future<VideoSubtitleDownload> Function(VideoSubtitleCandidate)
  fetchCandidate =
      download ??
      (VideoSubtitleCandidate c) =>
          localDownloads[c.identityKey] ??= registry.download(c);
  // 文件名没写语言的版本按正文判语言——否则它们在语言排名里垫底，整季会被
  // 一个「文件名带了 ja 标记」的版本抢走（BUG-3998）。调用方已经探过的
  // （[probedVersionLanguages]，含判不出的）不再重下。
  final Map<String, SubtitleContentLanguage?> probedLanguage =
      <String, SubtitleContentLanguage?>{
        ...probedVersionLanguages,
        ...await probeUnlabeledVersionLanguages<VideoSubtitleCandidate>(
          // 有下载配额的源（OpenSubtitles：免费账号一天 5~20 次）不为排名去探——
          // 那等于拿用户的配额换一个排序依据。
          files: candidates.where(
            (VideoSubtitleCandidate c) =>
                !c.isArchivePack &&
                registry.allowsFreeProbeDownload(c) &&
                !probedVersionLanguages.containsKey(subtitleVersionKeyOf(c)) &&
                matchesTargetForProbe(c),
          ),
          targetEpisodes: episodes,
          versionOf: subtitleVersionKeyOf,
          declaredLanguageOf: (VideoSubtitleCandidate c) => c.language,
          episodeOf: (VideoSubtitleCandidate c) => c.episode,
          sizeOf: (VideoSubtitleCandidate c) => c.fileSize,
          fetch: (VideoSubtitleCandidate c) async =>
              (await fetchCandidate(c)).bytes,
        ),
      };
  String? languageOf(VideoSubtitleCandidate c) {
    if (c.language.isNotEmpty) return c.language;
    final SubtitleContentLanguage? probed =
        probedLanguage[subtitleVersionKeyOf(c)];
    return probed == null ? null : coarseLanguageCode(probed);
  }

  // 整批按季各建一份索引，每季共用一个版本（缺集由次选版本补），而不是逐集各挑各的、
  // 更不让一季的字幕跨季套到别的季。
  final Map<int?, List<int>> episodesBySeason = <int?, List<int>>{};
  for (int i = 0; i < targets.length; i++) {
    episodesBySeason
        .putIfAbsent(targetSeasons[i], () => <int>[])
        .add(episodes[i]);
  }
  final Map<int?, SubtitleEpisodeIndex<VideoSubtitleCandidate>> indexBySeason =
      <int?, SubtitleEpisodeIndex<VideoSubtitleCandidate>>{
        for (final MapEntry<int?, List<int>> entry in episodesBySeason.entries)
          entry.key:
              SubtitleEpisodeIndex.fromCandidates(
                filterSubtitleCandidatesForSeason(
                  candidates,
                  season: entry.key,
                  allowUnseasoned: allowUnseasoned,
                ),
                preferredLanguage: preferredLanguage,
              ).preferConsistentVersion(
                targetEpisodes: entry.value,
                versionOf: subtitleVersionKeyOf,
                languageRankOf: (VideoSubtitleCandidate c) =>
                    jimakuLanguageRank(
                      languageOf(c),
                      preferred: preferredLanguage,
                    ),
                fileNameOf: (VideoSubtitleCandidate c) => c.fileName,
              ),
      };
  final _ArchivePackSplitter packs = _ArchivePackSplitter(
    registry: registry,
    candidates: candidates,
    preferredLanguage: preferredLanguage,
  );
  for (int i = 0; i < targets.length; i++) {
    final SubtitleBatchTarget target = targets[i];
    final int? targetSeason = targetSeasons[i];
    final SubtitleBatchItem item = SubtitleBatchItem(
      target: target,
      episode: episodes[i],
      season: targetSeason,
    );
    if (isCancelled?.call() ?? false) {
      item.status = SubtitleBatchStatus.skipped;
      if (onItemDone != null) await onItemDone(item);
      results.add(item);
      continue;
    }
    item.status = SubtitleBatchStatus.downloading;
    if (onItemStart != null) await onItemStart(item);
    SubtitleBatchFailureStage stage = SubtitleBatchFailureStage.download;
    try {
      final SubtitleEpisodeIndex<VideoSubtitleCandidate> index =
          indexBySeason[targetSeason]!;
      final SubtitleEpisodeMatch<VideoSubtitleCandidate> match =
          chooseSubtitleForEpisode(
            index,
            episode: item.episode,
            soleTarget: soleTarget,
          );
      final VideoSubtitleCandidate? best = match.file;
      // 没有单集文件时，从整季压缩包里按季+集号拆（整包只下一次）。
      final ({VideoSubtitleDownload? download, bool seasonMismatch})
      packResult = best == null
          ? await packs.subtitleFor(
              item.episode,
              season: targetSeason,
              soleTarget: soleTarget,
              allowUnseasoned: allowUnseasoned,
            )
          : (download: null, seasonMismatch: false);
      final VideoSubtitleDownload? fromPack = packResult.download;
      if (best == null && fromPack == null) {
        item.status = SubtitleBatchStatus.noMatch;
        final bool excludedBySeason =
            packResult.seasonMismatch ||
            candidates.any(
              (VideoSubtitleCandidate c) =>
                  !c.isArchivePack &&
                  c.episode == item.episode &&
                  !_matchesSeason(
                    subtitleCandidateSeason(c),
                    season: targetSeason,
                    allowUnseasoned: allowUnseasoned,
                  ),
            );
        final String? packFailure = packs.failureReasonFor(targetSeason);
        // 「为什么没配上」对用户是三件不同的事（改来源 / 等字幕 / 无能为力），
        // 别全压成一句「无匹配」。
        item.message = excludedBySeason && !packs.hasFailureFor(targetSeason)
            ? 'subtitle season does not match target season'
            : (packFailure ?? match.failureReason);
        item.error = packs.allPacksFailedErrorFor(targetSeason);
      } else {
        final VideoSubtitleDownload fetched =
            fromPack ?? await fetchCandidate(best!);
        if (fetched.bytes.isEmpty) {
          item.status = SubtitleBatchStatus.failed;
          item.failureStage = SubtitleBatchFailureStage.download;
          item.message = 'download';
        } else {
          stage = SubtitleBatchFailureStage.write;
          if (!dir.existsSync()) dir.createSync(recursive: true);
          final String dest = p.join(
            dir.path,
            batchSubtitleFileName(target.bookUid, fetched.fileName),
          );
          // 流媒体没有本地文件可读内嵌轨，对齐器自己会原样返回。网络路径
          // （UNC / smb:// …）是后台批量，不抽内嵌轨——整片 demux 走网络等于把整部
          // 视频拉一遍，原样写。
          await File(dest).writeAsBytes(
            subtitleAligner == null || isNetworkMediaPath(target.videoPath)
                ? fetched.bytes
                : await subtitleAligner(fetched.bytes, target.videoPath),
          );
          item.subtitlePath = dest;
          item.language = fetched.language.isNotEmpty
              ? fetched.language
              : (best == null ? null : languageOf(best));
          item.status = SubtitleBatchStatus.done;
        }
      }
    } on Object catch (e) {
      item.status = SubtitleBatchStatus.failed;
      item.failureStage = stage;
      item.message = '$e';
      item.error = e;
    }
    if (onItemDone != null) {
      try {
        await onItemDone(item);
      } on Object catch (e) {
        item.status = SubtitleBatchStatus.failed;
        item.failureStage = SubtitleBatchFailureStage.persist;
        item.message = '$e';
        item.error = e;
      }
    }
    results.add(item);
  }
  return results;
}
