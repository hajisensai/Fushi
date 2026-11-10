/// 一条发布在**下载规划**语义下的范围：整包（整季 / 全集）、单条，还是证据不足。
///
/// 标题判据（[looksLikeBatchVideoRelease]）刻意保守：BD 整包常常只写
/// `[BDRip 1080p HEVC-10bit FLAC]`，既没有 batch / complete，也没有集数区间或季号
/// （`[喵萌Production&LoliHouse] … Garupa☆PICO～OHMORI～ [BDRip …]`、
/// `[Moozzi2] BanG Dream! Ave Mujica (BD …) - TV + SP`），从标题上与「一集特典」
/// （`Show Special`）分不开——当「全集」下错了比给不出计划更糟。所以这一类标题
/// 不靠猜，而是去看**种子里到底装了什么**：
///
/// * 文件列表（最强证据，[VideoReleaseManifest]）：正片里有 ≥2 个不同集号、且
///   带集号的正片占多数 → 整包；正片只有一个视频 → 单条；原盘 / 编号不全 → 仍不定。
///   正片 / 特典的划分与下载整理器同一口径（[videoPackEpisodeEvidence]），规划认出
///   的整包与落地时整理器看到的是同一批正片。
/// * 体积相对单集的倍数：**只作反证**——不比一集大多少的发布不值得花一次请求去取
///   文件列表（[videoReleaseManifestTargets]）。它不能单独证成整包：一部剧场版长度
///   的 Remux 特典可以是 WebRip 单集的十几倍。
/// * 索引器类别：现有索引器（Nyaa 式站点 / apibay / Knaben / Torznab）都没有「整季
///   合集」这一类别，类别里没有可用的证据，所以不进判据。
library;

import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/download/subscription_release_scope.dart';
import 'package:fushi_engine/media/video/download/video_download_organizer.dart';

/// 一条发布的种子文件清单（种子内相对路径）。
class VideoReleaseManifest {
  VideoReleaseManifest(Iterable<String> files)
    : files = List<String>.unmodifiable(files);

  final List<String> files;
}

enum VideoReleaseScope {
  /// 整包：整季 / 全集 / 多集合集。
  seasonPack,

  /// 单条：某一集，或只有一个正片视频的发布（特典 / 单集 / 剧场版）。
  singleRelease,

  /// 证据不足：标题认不出、也没有（或看不懂）文件列表。规划按「不是整包」处理。
  undetermined,
}

/// 判据依据的是哪一类证据。
enum VideoReleaseScopeBasis { title, fileList, none }

class VideoReleaseScopeEvidence {
  const VideoReleaseScopeEvidence({
    required this.scope,
    required this.basis,
    this.episodes = const <int>{},
  });

  final VideoReleaseScope scope;
  final VideoReleaseScopeBasis basis;

  /// 文件列表证成整包时覆盖到的集号；其余情况为空。
  final Set<int> episodes;

  bool get isSeasonPack => scope == VideoReleaseScope.seasonPack;
}

/// 文件名本身标明是特典 / 特别篇的视频（不在特典目录里、整理器的严格附件名也
/// 没收的那些）：`Show - SP01.mkv`、`Show Special 02.mkv`、`OVA 1.mkv`。它们常带
/// 序号，算进集号就会把「两集特典」当成整季包。
final RegExp _specialFileMarker = RegExp(
  r'(?<![A-Za-z0-9])(?:SP|Specials?|OVA|OAD)(?:\s*\d{1,3})?(?![A-Za-z])'
  r'|特別編|特别篇|特典',
  caseSensitive: false,
);

/// 判一条发布的范围。[manifest] 为 null = 没有文件列表。
VideoReleaseScopeEvidence judgeVideoReleaseScope(
  String title, {
  VideoReleaseManifest? manifest,
}) {
  if (looksLikeBatchVideoRelease(title)) {
    return const VideoReleaseScopeEvidence(
      scope: VideoReleaseScope.seasonPack,
      basis: VideoReleaseScopeBasis.title,
    );
  }
  if (!subscriptionReleaseIsBatch(title)) {
    // 标题解析得出集号：某一集。
    return const VideoReleaseScopeEvidence(
      scope: VideoReleaseScope.singleRelease,
      basis: VideoReleaseScopeBasis.title,
    );
  }
  if (manifest == null) {
    return const VideoReleaseScopeEvidence(
      scope: VideoReleaseScope.undetermined,
      basis: VideoReleaseScopeBasis.none,
    );
  }
  return _judgeManifest(manifest);
}

VideoReleaseScopeEvidence _judgeManifest(VideoReleaseManifest manifest) {
  // 文件名标明是特典的视频先拿出来：它们不算正片集号，但算「别的正片外视频」。
  final List<String> regular = <String>[];
  int specials = 0;
  for (final String path in manifest.files) {
    if (isVideoDownloadVideoFile(path) &&
        _specialFileMarker.hasMatch(_basename(path))) {
      specials++;
    } else {
      regular.add(path);
    }
  }
  final VideoPackEpisodeEvidence evidence = videoPackEpisodeEvidence(regular);
  if (evidence.hasDisc) {
    // 原盘：盘内 `.m2ts` 的序号不是集号，一张盘装几集看文件名看不出来。
    return const VideoReleaseScopeEvidence(
      scope: VideoReleaseScope.undetermined,
      basis: VideoReleaseScopeBasis.fileList,
    );
  }
  final int others = evidence.unnumbered + evidence.movieHinted + specials;
  if (evidence.episodes.length >= 2 && evidence.numbered > others) {
    return VideoReleaseScopeEvidence(
      scope: VideoReleaseScope.seasonPack,
      basis: VideoReleaseScopeBasis.fileList,
      episodes: Set<int>.unmodifiable(evidence.episodes),
    );
  }
  if (evidence.numbered + others <= 1) {
    return const VideoReleaseScopeEvidence(
      scope: VideoReleaseScope.singleRelease,
      basis: VideoReleaseScopeBasis.fileList,
    );
  }
  return const VideoReleaseScopeEvidence(
    scope: VideoReleaseScope.undetermined,
    basis: VideoReleaseScopeBasis.fileList,
  );
}

String _basename(String path) {
  final List<String> segments = path
      .split(RegExp(r'[\\/]'))
      .where((String segment) => segment.isNotEmpty)
      .toList(growable: false);
  return segments.isEmpty ? path : segments.last;
}

/// 标题给不出答案、需要文件列表才能判的发布：标题既不是显式整包，也解析不出集号。
bool videoReleaseNeedsManifest(String title) =>
    subscriptionReleaseIsBatch(title) && !looksLikeBatchVideoRelease(title);

/// 一次资源搜索最多为几条发布去取文件列表。取列表要下载 `.torrent`，Nyaa 式站点
/// 同 host 每两次请求至少隔 2 秒（`kNyaaMinRequestInterval`），这里再给总量封顶。
const int kVideoReleaseManifestInspectionLimit = 3;

/// 体积不到单集参考体积的这个倍数 → 装不下两集，不值得取文件列表。
const double kVideoReleaseManifestMinSizeMultiple = 1.5;

/// 下载规划需要取文件列表的发布（按 [candidates] 的输入次序，即相关度名次）。
///
/// * 只挑 [videoReleaseNeedsManifest] 的发布，且跳过 [inspected] 里已经取过的
///   （拿不到列表的也算取过，不再重试）；
/// * 体积反证：[sizeReference] 里与它同清晰度、标题带集号的单集发布给出单集参考
///   体积（中位数），它的体积不到参考的 [kVideoReleaseManifestMinSizeMultiple] 倍 →
///   跳过；体积或参考缺失时不跳；
/// * 总量：[sizeReference]（= 这次搜索的全部结果）里已取过的条数计入 [limit]。
List<VideoResourceCandidate> videoReleaseManifestTargets(
  Iterable<VideoResourceCandidate> candidates, {
  required Iterable<VideoResourceCandidate> sizeReference,
  required Set<String> inspected,
  int limit = kVideoReleaseManifestInspectionLimit,
}) {
  final List<VideoResourceCandidate> reference = sizeReference.toList(
    growable: false,
  );
  final int alreadyInspected = <String>{
    for (final VideoResourceCandidate candidate in reference)
      if (inspected.contains(candidate.identityKey)) candidate.identityKey,
  }.length;
  int budget = limit - alreadyInspected;
  if (budget <= 0) return const <VideoResourceCandidate>[];
  final Map<String, int?> referenceByResolution = <String, int?>{};
  final Set<String> picked = <String>{};
  final List<VideoResourceCandidate> targets = <VideoResourceCandidate>[];
  for (final VideoResourceCandidate candidate in candidates) {
    if (budget <= 0) break;
    final String key = candidate.identityKey;
    if (inspected.contains(key) || picked.contains(key)) continue;
    if (!videoReleaseNeedsManifest(candidate.title)) continue;
    final int? size = candidate.sizeBytes;
    final String resolution = _resolutionOf(candidate);
    final int? perEpisode = referenceByResolution.putIfAbsent(
      resolution,
      () => _medianEpisodeBytes(reference, resolution),
    );
    if (size != null &&
        size > 0 &&
        perEpisode != null &&
        size < perEpisode * kVideoReleaseManifestMinSizeMultiple) {
      continue;
    }
    picked.add(key);
    targets.add(candidate);
    budget--;
  }
  return List<VideoResourceCandidate>.unmodifiable(targets);
}

String _resolutionOf(VideoResourceCandidate candidate) =>
    (candidate.resolution ??
            RegExp(
              r'\b(2160|1440|1080|720|576|480)[pP]\b',
            ).firstMatch(candidate.title)?.group(0) ??
            '')
        .toLowerCase();

int? _medianEpisodeBytes(
  List<VideoResourceCandidate> reference,
  String resolution,
) {
  final List<int> sizes = <int>[
    for (final VideoResourceCandidate candidate in reference)
      if ((candidate.sizeBytes ?? 0) > 0 &&
          _resolutionOf(candidate) == resolution &&
          !subscriptionReleaseIsBatch(candidate.title))
        candidate.sizeBytes!,
  ]..sort();
  if (sizes.isEmpty) return null;
  return sizes[sizes.length ~/ 2];
}
