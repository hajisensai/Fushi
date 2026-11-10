/// 视频库「整理文件名」的纯函数部分（反馈 ZDYNkAP3Ln）：按刮削资料算规范名与
/// 规范目录、认领跟着视频走的 sidecar、排出逐文件的「旧路径 → 新路径」清单。零 IO。
///
/// 背景：库里显示的是刮削后的新名（`ぼっち・ざ・ろっく！ Re:`），磁盘上仍是下载
/// 整理时按旧身份落的名（`ぼっち・ざ・ろっく！ Re_Re_ (2024).mkv`）。整理是**用户
/// 手动触发**的可选操作，两种布局（[VideoOrganizeLayout]）：
/// - 只改文件名（basename），目录不动；
/// - 同时归到规范目录：来源库根下 `标题 (年份)/`（电影）或
///   `标题 (年份)/Season 01/`（剧集）。目录是来源库根 / 目录合集
///   `sourceFolderPath` / 下载任务保存位置共用的锚点，这些锚点由 IO 层
///   （`VideoFilenameOrganizeService`）逐一核对、迁移或拒绝。
///
/// 规范名与下载整理器（`VideoDownloadOrganizer`）同一形态、同一套非法字符替身
/// （全角，[fullwidthSafeFileName]）：
/// - 电影：`标题 (年份)/标题 (年份).ext`
/// - 剧集：`标题 (年份)/Season 01/标题 (年份) - S01E02.ext`（一个文件绑多集：
///   `S01E01-E02`）
library;

import 'package:fushi_core/fushi_core.dart' show platformPathKey;
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/media_extensions.dart' show kVideoExtensions;
import 'package:fushi_engine/media/video/video_local_files.dart'
    show sidecarSubtitlesForDeletedVideo;
import 'package:fushi_engine/utils/misc/safe_file_name.dart';

/// 整理的布局。
enum VideoOrganizeLayout {
  /// 只改文件名，目录不动。
  filenameOnly,

  /// 改文件名并归到来源库根下的规范目录（`标题 (年份)/[Season XX/]`）。
  directories,
}

/// 一个视频文件的刮削身份（只取命名用得到的字段）。
class VideoFilenameIdentity {
  const VideoFilenameIdentity({
    required this.title,
    this.year,
    this.seasonNumber,
    this.episodeNumbers = const <int>[],
    this.workId,
    this.seasonId,
    this.spansMultipleSeasons = false,
  });

  /// 作品名（电视剧取作品，不取分集标题）。
  final String title;
  final int? year;

  /// 剧集的季号；电影为 null。
  final int? seasonNumber;

  /// 这个文件绑到的集号；电影为空。
  final List<int> episodeNumbers;

  /// 刮削作品行 id（作品级 sidecar 所有权按它找）；纯函数测试可不填。
  final int? workId;

  /// 刮削季行 id（季级 sidecar 所有权按它找）；电影为 null。
  final int? seasonId;

  /// 绑到的分集横跨多季（多集播放列表书才会出现）：目录只到作品层，不进
  /// `Season XX`——任何一季的目录都装不下另一季的集。
  final bool spansMultipleSeasons;

  bool get isEpisode => seasonNumber != null && episodeNumbers.isNotEmpty;
}

/// 作品目录名（`标题 (年份)`）；标题安全化后为空返回 null。
String? canonicalVideoWorkDirectoryName(VideoFilenameIdentity identity) {
  final String title = fullwidthSafeFileName(identity.title);
  if (title.isEmpty) return null;
  return identity.year == null ? title : '$title (${identity.year})';
}

/// 季目录名（`Season 01`，特典季 `Season 00`，与下载整理器同一形态）。
String canonicalVideoSeasonDirectoryName(int seasonNumber) =>
    'Season ${seasonNumber.toString().padLeft(2, '0')}';

/// 规范目录相对来源库根的段：电影 `[标题 (年份)]`，剧集
/// `[标题 (年份), Season 01]`（横跨多季的只到作品层）。标题为空返回 null。
List<String>? canonicalVideoDirectorySegments(VideoFilenameIdentity identity) {
  final String? work = canonicalVideoWorkDirectoryName(identity);
  if (work == null) return null;
  if (!identity.isEpisode || identity.spansMultipleSeasons) {
    return <String>[work];
  }
  return <String>[
    work,
    canonicalVideoSeasonDirectoryName(identity.seasonNumber!),
  ];
}

/// 规范文件名主干（不含扩展名）；标题安全化后为空返回 null（不改名）。
String? canonicalVideoFileStem(VideoFilenameIdentity identity) {
  final String? root = canonicalVideoWorkDirectoryName(identity);
  if (root == null) return null;
  if (!identity.isEpisode) return root;
  final String season = identity.seasonNumber!.toString().padLeft(2, '0');
  final List<int> episodes = <int>{...identity.episodeNumbers}.toList()..sort();
  final String first = episodes.first.toString().padLeft(2, '0');
  final String range = episodes.length == 1
      ? 'E$first'
      : 'E$first-E${episodes.last.toString().padLeft(2, '0')}';
  return '$root - S$season$range';
}

/// 刮削写出的元数据 sidecar 后缀（`video_sidecar_target_resolver.dart` 的命名：
/// `<stem>.nfo`、分集缩略图 `<stem>.jpg`、共享目录电影图 `<stem>-poster.jpg` 等）。
final RegExp _metadataSidecarSuffix = RegExp(
  r'^(\.nfo|(-(poster|backdrop|fanart|logo|disc|banner|thumb|clearart|landscape))?\.(jpg|jpeg|png|webp))$',
  caseSensitive: false,
);

/// 纯函数：同目录 [dirFileNames] 里跟着 [videoFileName] 走的 sidecar 文件名
/// （外挂字幕 + 刮削元数据），原样返回。
///
/// 字幕复用删除流程的归属判据（[sidecarSubtitlesForDeletedVideo]：`ep01.5.srt`
/// 属于 `ep01.5.mkv` 而不是 `ep01.mkv`）；元数据后缀是固定词表，没有这种歧义。
List<String> videoFollowingSidecars({
  required String videoFileName,
  required List<String> dirFileNames,
}) {
  final String stem = p.basenameWithoutExtension(videoFileName);
  if (stem.isEmpty) return const <String>[];
  final String stemLower = stem.toLowerCase();
  final Set<String> seen = <String>{};
  final List<String> out = <String>[];
  for (final String name in sidecarSubtitlesForDeletedVideo(
    videoFileName: videoFileName,
    dirFileNames: dirFileNames,
  )) {
    if (seen.add(name.toLowerCase())) out.add(name);
  }
  for (final String name in dirFileNames) {
    if (name.length <= stem.length) continue;
    if (!name.toLowerCase().startsWith(stemLower)) continue;
    if (kVideoExtensions.contains(p.extension(name).toLowerCase())) continue;
    if (!_metadataSidecarSuffix.hasMatch(name.substring(stem.length))) {
      continue;
    }
    if (seen.add(name.toLowerCase())) out.add(name);
  }
  return out;
}

/// 季级刮削 sidecar 的落点：`seasonXX-poster.jpg` / `season-specials-*` 是
/// Kodi 约定放在**作品目录**的季图，其余（季目录里的 `season.nfo`、
/// `poster.jpg`）放在**季目录**。返回 true = 进作品目录。
bool seasonSidecarBelongsInWorkDirectory(String fileName) => RegExp(
  r'^season(\d{2,}|-specials)-',
  caseSensitive: false,
).hasMatch(fileName);

/// 一个文件的改名 / 搬动（本机绝对路径）。
class VideoFileMove {
  const VideoFileMove({
    required this.from,
    required this.to,
    required this.isVideo,
  });

  final String from;
  final String to;

  /// 视频本体（false = sidecar）。
  final bool isVideo;
}

/// 单个视频条目的整理结论。
enum VideoFilenamePlanStatus {
  /// 有文件要改名。
  ready,

  /// 已经是规范名（规范目录）。
  unchanged,

  /// 没有刮削身份（未刮削 / 特典 / 只有作品没有分集绑定）。
  noIdentity,

  /// 不是本机文件（流媒体、远端条目等）。
  notLocalFile,

  /// 光盘条目（蓝光 `BDMV/PLAYLIST/*.mpls` / DVD 虚拟标题）：盘内文件名是盘
  /// 结构本身，一张盘的多条标题共用同一批码流，不能逐文件改名或搬走。
  disc,

  /// 多集播放列表书只改文件名：各集与分集的对应只记在书上、没有逐文件
  /// 绑定，给每个文件编 `S01Exx` 只能猜。归到规范目录（保留原文件名）可以做。
  playlistNeedsDirectories,

  /// 归到规范目录时，文件不在任何本机来源库根下：没有「库根」就没有规范
  /// 目录的落点。
  outsideLibraryRoot,

  /// 在做种的文件要搬出种子的保存目录：引擎只能在保存目录内改相对路径，
  /// 搬出去要整种 move_storage，会连带同种子的其它文件。
  torrentOutsideSaveRoot,

  /// 归到规范目录会拆开一个目录合集（合集里还有别的成员不跟着走，或目标
  /// 目录已属于另一个目录合集）。
  folderCollectionSplit,

  /// 视频文件不在磁盘上。
  missing,

  /// 目标名已被别的文件占用（磁盘上或同一批里另一个条目）。
  conflict,
}

/// 纯函数：一个视频文件（及其 sidecar）的改名 / 搬动清单。
///
/// [targetDirectory] 为 null = 原目录；[targetStem] 为 null = 保留原文件名
/// （多集播放列表只归目录）。[dirFileNames] 是视频所在目录的文件名清单；
/// [targetDirFileNames] 是目标目录现有的文件名（目标目录 = 原目录时可不传）；
/// [claimedTargets] 是同一批里已被前面条目占用的目标（[platformPathKey]），
/// 命中即 [VideoFilenamePlanStatus.conflict]。返回 ready 时第一项是视频本体。
VideoFilenameItemDraft planVideoFileMoves({
  required String videoPath,
  required List<String> dirFileNames,
  String? targetDirectory,
  String? targetStem,
  List<String> targetDirFileNames = const <String>[],
  Set<String> claimedTargets = const <String>{},
}) {
  final String dir = p.dirname(videoPath);
  final String toDir = targetDirectory ?? dir;
  final bool sameDir = platformPathKey(toDir) == platformPathKey(dir);
  final String fileName = p.basename(videoPath);
  final String oldStem = p.basenameWithoutExtension(fileName);
  final String newStem = targetStem ?? oldStem;
  final String extension = p.extension(fileName);
  if (!dirFileNames.any(
    (String name) => name.toLowerCase() == fileName.toLowerCase(),
  )) {
    return const VideoFilenameItemDraft(VideoFilenamePlanStatus.missing);
  }
  if (sameDir && oldStem == newStem) {
    return const VideoFilenameItemDraft(VideoFilenamePlanStatus.unchanged);
  }
  final List<VideoFileMove> moves = <VideoFileMove>[
    VideoFileMove(
      from: videoPath,
      to: p.join(toDir, '$newStem$extension'),
      isVideo: true,
    ),
    for (final String sidecar in videoFollowingSidecars(
      videoFileName: fileName,
      dirFileNames: dirFileNames,
    ))
      VideoFileMove(
        from: p.join(dir, sidecar),
        to: p.join(toDir, '$newStem${sidecar.substring(oldStem.length)}'),
        isVideo: false,
      ),
  ];
  // 目标被**本条以外**的文件占着就整条不动：覆盖用户文件不可接受，只改一半
  // （视频改了、字幕撞名没改）会把字幕从视频身边拆散。大小写不同的同名（Windows
  // 上就是同一个文件）算本条自己。
  final Set<String> sources = <String>{
    for (final VideoFileMove move in moves) platformPathKey(move.from),
  };
  final Set<String> existing = <String>{
    for (final String name in dirFileNames) platformPathKey(p.join(dir, name)),
    if (!sameDir)
      for (final String name in targetDirFileNames)
        platformPathKey(p.join(toDir, name)),
  };
  for (final VideoFileMove move in moves) {
    final String key = platformPathKey(move.to);
    if (claimedTargets.contains(key)) {
      return const VideoFilenameItemDraft(VideoFilenamePlanStatus.conflict);
    }
    if (existing.contains(key) && !sources.contains(key)) {
      return const VideoFilenameItemDraft(VideoFilenamePlanStatus.conflict);
    }
  }
  return VideoFilenameItemDraft(VideoFilenamePlanStatus.ready, moves: moves);
}

/// 只改文件名（原目录）的 [planVideoFileMoves]。
VideoFilenameItemDraft planVideoFilenameMoves({
  required String videoPath,
  required String targetStem,
  required List<String> dirFileNames,
  Set<String> claimedTargets = const <String>{},
}) => planVideoFileMoves(
  videoPath: videoPath,
  targetStem: targetStem,
  dirFileNames: dirFileNames,
  claimedTargets: claimedTargets,
);

/// [planVideoFileMoves] 的结果。
class VideoFilenameItemDraft {
  const VideoFilenameItemDraft(
    this.status, {
    this.moves = const <VideoFileMove>[],
  });

  final VideoFilenamePlanStatus status;
  final List<VideoFileMove> moves;
}

/// 纯函数：[path] 落在哪个来源库根之下（取最深的那个）；都不在返回 null。
/// 比较走 [platformPathKey]（Windows 折大小写）；根本身不算「之下」。
String? containingLibraryRoot(String path, Iterable<String> roots) {
  final String key = platformPathKey(path);
  String? best;
  for (final String root in roots) {
    final String trimmed = root.trim();
    if (trimmed.isEmpty || !p.isAbsolute(trimmed)) continue;
    if (!p.isWithin(platformPathKey(trimmed), key)) continue;
    if (best == null || trimmed.length > best.length) {
      best = p.normalize(trimmed);
    }
  }
  return best;
}

/// 纯函数：搬走文件后可能变空、可以顺手删掉的旧目录（由深到浅），只取
/// [root] 之内（不含 [root] 本身）的。[movedFrom] 是被搬走文件的旧路径。
/// 调用方只删**真的空了**的目录（非递归删除，非空自然失败）。
List<String> emptiedDirectoryCandidates(
  Iterable<String> movedFrom,
  String root,
) {
  final String rootKey = platformPathKey(root);
  final Map<String, String> byKey = <String, String>{};
  for (final String path in movedFrom) {
    String dir = p.dirname(p.normalize(path));
    while (p.isWithin(rootKey, platformPathKey(dir))) {
      byKey.putIfAbsent(platformPathKey(dir), () => dir);
      final String parent = p.dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
  }
  final List<String> out = byKey.values.toList()
    ..sort((String a, String b) => b.length.compareTo(a.length));
  return out;
}
