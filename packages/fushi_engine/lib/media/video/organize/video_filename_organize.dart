/// 视频库「整理文件名」的纯函数部分（反馈 ZDYNkAP3Ln）：按刮削资料算规范名、
/// 认领跟着视频走的 sidecar、排出逐文件的「旧名 → 新名」清单。零 IO。
///
/// 背景：库里显示的是刮削后的新名（`ぼっち・ざ・ろっく！ Re:`），磁盘上仍是下载
/// 整理时按旧身份落的名（`ぼっち・ざ・ろっく！ Re_Re_ (2024).mkv`）。整理文件名
/// 是**用户手动触发**的可选操作：只改文件名（basename），不改目录结构——目录是
/// 来源库 / 下载任务 / 合集 `sourceFolderPath` 共用的锚点，挪目录的面远大于改名。
///
/// 规范名与下载整理器（`VideoDownloadOrganizer`）同一形态：
/// - 电影：`标题 (年份).ext`
/// - 剧集：`标题 (年份) - S01E02.ext`（一个文件绑多集：`S01E01-E02`）
/// 区别只在非法字符替身：这里用全角（`Re:` → `Re：`，[fullwidthSafeFileName]），
/// 因为改名的目的就是让文件名读起来与库里一致。
library;

import 'package:fushi_core/fushi_core.dart' show platformPathKey;
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/media_extensions.dart' show kVideoExtensions;
import 'package:fushi_engine/media/video/video_local_files.dart'
    show sidecarSubtitlesForDeletedVideo;
import 'package:fushi_engine/utils/misc/safe_file_name.dart';

/// 一个视频文件的刮削身份（只取命名用得到的字段）。
class VideoFilenameIdentity {
  const VideoFilenameIdentity({
    required this.title,
    this.year,
    this.seasonNumber,
    this.episodeNumbers = const <int>[],
  });

  /// 作品名（电视剧取作品，不取分集标题）。
  final String title;
  final int? year;

  /// 剧集的季号；电影为 null。
  final int? seasonNumber;

  /// 这个文件绑到的集号；电影为空。
  final List<int> episodeNumbers;

  bool get isEpisode => seasonNumber != null && episodeNumbers.isNotEmpty;
}

/// 规范文件名主干（不含扩展名）；标题安全化后为空返回 null（不改名）。
String? canonicalVideoFileStem(VideoFilenameIdentity identity) {
  final String title = fullwidthSafeFileName(identity.title);
  if (title.isEmpty) return null;
  final String root = identity.year == null
      ? title
      : '$title (${identity.year})';
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

/// 一个文件的改名（本机绝对路径）。
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

  /// 已经是规范名。
  unchanged,

  /// 没有刮削身份（未刮削 / 特典 / 只有作品没有分集绑定）。
  noIdentity,

  /// 不是单个本机文件（流媒体、多集播放列表、光盘目录等）。
  notLocalFile,

  /// 视频文件不在磁盘上。
  missing,

  /// 目标名已被别的文件占用（磁盘上或同一批里另一个条目）。
  conflict,
}

/// 纯函数：一个视频的改名清单。
///
/// [dirFileNames] 是视频所在目录的文件名清单；[claimedTargets] 是同一批里
/// 已被前面条目占用的目标（[platformPathKey]），命中即
/// [VideoFilenamePlanStatus.conflict]。返回 ready 时第一项是视频本体。
VideoFilenameItemDraft planVideoFilenameMoves({
  required String videoPath,
  required String targetStem,
  required List<String> dirFileNames,
  Set<String> claimedTargets = const <String>{},
}) {
  final String dir = p.dirname(videoPath);
  final String fileName = p.basename(videoPath);
  final String oldStem = p.basenameWithoutExtension(fileName);
  final String extension = p.extension(fileName);
  if (!dirFileNames.any(
    (String name) => name.toLowerCase() == fileName.toLowerCase(),
  )) {
    return const VideoFilenameItemDraft(VideoFilenamePlanStatus.missing);
  }
  if (oldStem == targetStem) {
    return const VideoFilenameItemDraft(VideoFilenamePlanStatus.unchanged);
  }
  final List<VideoFileMove> moves = <VideoFileMove>[
    VideoFileMove(
      from: videoPath,
      to: p.join(dir, '$targetStem$extension'),
      isVideo: true,
    ),
    for (final String sidecar in videoFollowingSidecars(
      videoFileName: fileName,
      dirFileNames: dirFileNames,
    ))
      VideoFileMove(
        from: p.join(dir, sidecar),
        to: p.join(dir, '$targetStem${sidecar.substring(oldStem.length)}'),
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

/// [planVideoFilenameMoves] 的结果。
class VideoFilenameItemDraft {
  const VideoFilenameItemDraft(
    this.status, {
    this.moves = const <VideoFileMove>[],
  });

  final VideoFilenamePlanStatus status;
  final List<VideoFileMove> moves;
}
