/// 曲目所在发布的 MV 候选：同一个下载任务（同一个种子）里的特典视频与原盘流。
///
/// 本地 MV 匹配原来只看曲目**附近**（同目录 / MV 目录 / 相邻原盘）。下载整理会把视频
/// 改名搬进 `<作品 (年)>/Extras/…`、把原盘整盘搬进 `<作品 (年)>/<盘>/`，而随发布的 CD
/// 留在原发布目录：同一个发布的 NCOP / NCED / PV 和 CD 从此分在两棵目录树里，「附近」
/// 永远看不到（用户库实况：MV 绑定 0 条）。下载任务的文件清单是两者同属一个发布的
/// 直接证据，这里按它把发布里的特典 / 原盘流配给发布里的曲目。
///
/// 路径按**来源根下的相对路径**配，不按任务记下的绝对路径：整个来源被搬到别处（本机
/// → NAS 映射盘）后绝对路径全变了，相对结构不变——曲目路径以某条 CD 相对目录结尾，
/// 前面那段就是现在的来源根，特典 / 盘流的相对路径拼上它就是现在的位置。任务记下的
/// `finalAbsolutePath` 作为第二候选（来源根没动过时两者相同）。
///
/// 纯函数，不碰文件系统；存在性与大小由调用方（后台 isolate 里的候选收集）查。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_extensions.dart'
    show isAudioOnlyMediaPath;
import 'package:fushi_engine/media/music/metadata/music_video_match.dart'
    show kMusicVideoExtensions;
import 'package:fushi_engine/media/video/metadata/video_extra_markers.dart'
    show videoExtraMarkerKind;
import 'package:fushi_engine/media/video/metadata/video_local_extra_classifier.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataExtraKind;
import 'package:path/path.dart' as p;

/// 发布里一个可能是 MV 的视频（特典视频或原盘流）。
typedef MusicReleaseVideoRef = ({
  /// 来源根下的相对路径（`/` 分隔）。
  String relativePath,

  /// 任务记下的本机绝对路径（可能已过时）。
  String? recordedPath,

  /// 原盘流（`BDMV/STREAM/*.m2ts`）：文件名不带歌名，按大小筛（见调用方）。
  bool discStream,
});

/// 一个下载发布：随发布的纯音频所在的相对目录，和发布里的 MV 候选视频。
class MusicRelease {
  const MusicRelease({required this.audioDirs, required this.videos});

  /// 纯音频文件所在目录（来源根下的相对路径，`/` 分隔，原大小写）。
  final Set<String> audioDirs;

  final List<MusicReleaseVideoRef> videos;
}

/// 一个曲目目录配到的候选：按顺序试，第一个存在的就是它（[alternatives] 至少一项）。
typedef MusicReleaseVideoCandidate = ({
  List<String> alternatives,
  bool discStream,
});

String _portable(String path) => path.replaceAll(r'\', '/');

List<String> _segments(String path) => <String>[
  for (final String s in _portable(path).split('/'))
    if (s.isNotEmpty && s != '.') s,
];

/// 特典视频里哪些可能是 MV：片头片尾 / PV / CM（[VideoMetadataExtraKind.clip]），或
/// 放在 MV / PV 目录里的。菜单、预告、访谈、花絮不算。
bool isMusicVideoCandidateExtra(String relativePath) {
  final String ext = p
      .extension(relativePath)
      .replaceFirst('.', '')
      .toLowerCase();
  if (!kMusicVideoExtensions.contains(ext)) return false;
  if (videoExtraMarkerKind(
        p.basenameWithoutExtension(_portable(relativePath)),
      ) ==
      VideoMetadataExtraKind.clip) {
    return true;
  }
  final VideoLocalExtraMatch? m = classifyLocalVideoExtra(relativePath);
  return m?.kind == VideoMetadataExtraKind.clip;
}

bool _isDiscStream(String relativePath) {
  final List<String> s = _segments(relativePath);
  return s.length >= 3 &&
      s[s.length - 3].toUpperCase() == 'BDMV' &&
      s[s.length - 2].toUpperCase() == 'STREAM' &&
      p.extension(s.last).toLowerCase() == '.m2ts';
}

/// 由一个下载任务的文件行得出它的发布（[MusicRelease]）；没有纯音频、或没有候选视频
/// 时返回 null。纯函数。
///
/// - 纯音频：kind `other`、没被跳过 / 失败、扩展名是纯音频；取所在相对目录。
/// - 候选视频：已整理的特典（kind `extra`）里 [isMusicVideoCandidateExtra] 的，以及
///   原盘流（盘内文件，相对路径落在 `BDMV/STREAM/*.m2ts`）。正片 / 分集不算——整片
///   解码对齐太慢，片中主题曲归主题曲识别（`video_theme_song_spans`）管。
/// - [minDiscBytes] / [maxDiscBytes]：原盘流按任务记下的大小筛（菜单背景、整场
///   正片不要），每张盘按大小降序最多取 [discStreamLimit] 条。
MusicRelease? musicReleaseOfDownloadJob(
  Iterable<VideoDownloadJobFileRow> files, {
  required int minDiscBytes,
  required int maxDiscBytes,
  required int discStreamLimit,
}) {
  final Set<String> audioDirs = <String>{};
  final List<MusicReleaseVideoRef> videos = <MusicReleaseVideoRef>[];
  final Map<String, List<VideoDownloadJobFileRow>> streamsByDisc =
      <String, List<VideoDownloadJobFileRow>>{};
  for (final VideoDownloadJobFileRow row in files) {
    if (row.status == VideoDownloadJobFileStatus.skipped ||
        row.status == VideoDownloadJobFileStatus.failed ||
        !row.selected) {
      continue;
    }
    final String rel = _portable(row.currentRelativePath.trim());
    if (rel.isEmpty) continue;
    if (row.kind == 'other' && isAudioOnlyMediaPath(rel)) {
      final List<String> s = _segments(rel);
      if (s.length >= 2) audioDirs.add(s.sublist(0, s.length - 1).join('/'));
      continue;
    }
    if (_isDiscStream(rel)) {
      final int size = row.sizeBytes ?? 0;
      if (size < minDiscBytes || size > maxDiscBytes) continue;
      final List<String> s = _segments(rel);
      (streamsByDisc[s.sublist(0, s.length - 3).join('/')] ??=
              <VideoDownloadJobFileRow>[])
          .add(row);
      continue;
    }
    if (row.kind == 'extra' && isMusicVideoCandidateExtra(rel)) {
      videos.add((
        relativePath: rel,
        recordedPath: row.finalAbsolutePath,
        discStream: false,
      ));
    }
  }
  for (final List<VideoDownloadJobFileRow> streams in streamsByDisc.values) {
    streams.sort(
      (VideoDownloadJobFileRow a, VideoDownloadJobFileRow b) =>
          (b.sizeBytes ?? 0).compareTo(a.sizeBytes ?? 0),
    );
    for (final VideoDownloadJobFileRow row in streams.take(discStreamLimit)) {
      videos.add((
        relativePath: _portable(row.currentRelativePath.trim()),
        recordedPath: row.finalAbsolutePath,
        discStream: true,
      ));
    }
  }
  if (audioDirs.isEmpty || videos.isEmpty) return null;
  return MusicRelease(audioDirs: audioDirs, videos: videos);
}

/// 曲目目录 [trackDir]（本机绝对路径）所属发布里的 MV 候选。[trackDir] 以某个发布的
/// 某条纯音频相对目录结尾（逐段、大小写不敏感）时，前面那段就是这个发布现在的来源根，
/// 候选 = 来源根 + 视频相对路径，其后接任务记下的绝对路径。一个目录可能属于多个发布
/// （同一个 CD 目录被两个任务下载过），候选按路径去重。纯函数。
List<MusicReleaseVideoCandidate> musicReleaseVideosForDir(
  String trackDir,
  Iterable<MusicRelease> releases, {
  p.Context? context,
}) {
  final p.Context ctx = context ?? p.context;
  final List<String> dir = ctx.split(ctx.normalize(trackDir));
  final List<String> dirLower = <String>[
    for (final String s in dir) s.toLowerCase(),
  ];
  final List<MusicReleaseVideoCandidate> out = <MusicReleaseVideoCandidate>[];
  final Set<String> seen = <String>{};
  for (final MusicRelease release in releases) {
    String? base;
    for (final String audioDir in release.audioDirs) {
      final List<String> rel = <String>[
        for (final String s in _segments(audioDir)) s.toLowerCase(),
      ];
      if (rel.isEmpty || rel.length >= dir.length) continue;
      final int start = dir.length - rel.length;
      bool same = true;
      for (int i = 0; i < rel.length; i++) {
        if (dirLower[start + i] != rel[i]) {
          same = false;
          break;
        }
      }
      if (!same) continue;
      base = ctx.joinAll(dir.sublist(0, start));
      break;
    }
    if (base == null) continue;
    for (final MusicReleaseVideoRef v in release.videos) {
      final String mapped = ctx.normalize(
        ctx.joinAll(<String>[base, ..._segments(v.relativePath)]),
      );
      final String? recorded = v.recordedPath == null
          ? null
          : ctx.normalize(v.recordedPath!);
      if (!seen.add(mapped.toLowerCase())) continue;
      out.add((
        alternatives: <String>[
          mapped,
          if (recorded != null &&
              recorded.toLowerCase() != mapped.toLowerCase())
            recorded,
        ],
        discStream: v.discStream,
      ));
    }
  }
  return out;
}
