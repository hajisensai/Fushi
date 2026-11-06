/// 光盘章节曲目 → mpv 吃得下的源（音乐方案 §9.2，与 CUE 拆轨同一做法：EDL 段）。
///
/// * **DVD**：title 经统一 FFmpeg 的 `dvdvideo` demuxer 整条读出（mpv 逐文件选项
///   `demuxer-lavf-format=dvdvideo` + `demuxer-lavf-o=title=N`），再用 EDL 段按章节时间裁。
///   mpv 自己的 `dvd://`（libdvdnav）不能当 EDL 段的源（实测 `EDL: Could not open source
///   file 'dvd://…'`），而 EDL 在解复用层裁段、解码器按样本裁边，不经播放器 seek——
///   这正是 CUE 拆轨无缝的原因（`mpv_music_output_backend.dart` 文件头）。EDL 段的源写盘上
///   的 `VIDEO_TS` 目录（文件夹形态）或 `.iso`：lavf 被强制成 dvdvideo 后由 libdvdread
///   打开它，目录不会再被 mpv 当成「目录播放列表」。
/// * **BD**：沿用视频侧 `bluray_source.dart` 的 EDL 拼法（段的源是 `STREAM/*.m2ts`、起点是
///   MPLS 的原始 PTS），只取章节范围内的那几段。
///
/// 两种都设 `vid=no` / `sid=no`：音乐实例是纯音频（`vo=null`），不必解 MPEG-2 / H.264。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';
import 'package:fushi_engine/media/video/dvd/dvd_title_path.dart';

/// EDL 段尾补偿（秒）：mpv 按 `floor((end - pts) · rate)` 截段尾，边界恰好落在样本上时
/// 浮点误差会少一个样本；段尾往后挪 1 µs 落回正确的样本（与 CUE 拆轨同一常量）。
const double kMusicEdlEndSlackSeconds = 0.000001;

/// 播到 title 结尾（最后一章）时给的段长：远超任何 title，让 mpv 播到真正的 EOF。
const int kMusicEdlOpenEndSeconds = 86400;

/// 一段源 → mpv EDL URI（`edl://%len%<源>,start=…,length=…`）。[endMs] 为 null = 播到
/// 源结尾。源按 UTF-8 字节数加 `%len%` 前缀，路径里的逗号 / 冒号不会被当成分隔符。
String musicEdlSegmentUri(String source, {required int startMs, int? endMs}) {
  final String length = endMs == null
      ? '$kMusicEdlOpenEndSeconds'
      : ((endMs - startMs) / 1000 + kMusicEdlEndSlackSeconds).toStringAsFixed(
          6,
        );
  return 'edl://%${utf8.encode(source).length}%$source,'
      'start=${(startMs / 1000).toStringAsFixed(6)},length=$length';
}

/// 一首光盘章节曲目交给 mpv 的东西：地址 + 加载这一项时要下发的逐文件选项。
class MusicDiscMediaSource {
  const MusicDiscMediaSource({
    required this.uri,
    this.fileLocalOptions = const <String, String>{},
  });

  final String uri;

  /// `file-local-options/<键>` 的值（音乐后端的 `on_load` 钩子下发）。
  final Map<String, String> fileLocalOptions;
}

/// 音乐实例里光盘曲目共有的逐文件选项：只要音频。
const Map<String, String> kMusicDiscAudioOnlyOptions = <String, String>{
  'vid': 'no',
  'sid': 'no',
};

/// [path] 是不是光盘章节曲目的 title 身份路径（DVD 虚拟成员 / BD `.mpls`）。
bool isMusicDiscTitlePath(String path) =>
    isDvdTitlePath(path) || isBlurayPlaylistPath(path);

/// DVD 的 dvdvideo demuxer 要打开的东西：文件夹形态给 `VIDEO_TS` 目录，镜像给 `.iso`。
String musicDvdDemuxerSource(String discRoot) =>
    isDiscImagePath(discRoot) ? discRoot : p.join(discRoot, kDvdVideoDirectory);

/// 纯函数：DVD title 成员路径 + 章节起止 → mpv 源。形状不对返回 null。
MusicDiscMediaSource? musicDvdMediaSource(
  String titlePath, {
  required int startMs,
  int? endMs,
}) {
  final String? root = dvdDiscRootForTitlePath(titlePath);
  final int? title = dvdTitleNumberForPath(titlePath);
  if (root == null || title == null) return null;
  final String source = musicDvdDemuxerSource(root);
  return MusicDiscMediaSource(
    uri: musicEdlSegmentUri(source, startMs: startMs, endMs: endMs),
    fileLocalOptions: <String, String>{
      ...kMusicDiscAudioOnlyOptions,
      'demuxer-lavf-format': 'dvdvideo',
      'demuxer-lavf-o': 'title=$title',
    },
  );
}

/// 纯函数：播放列表时间轴上的 [start, end) → 落在其中的各 PlayItem 段（源、MPLS 原始 PTS
/// 起点、时长，45 kHz tick）。[end] 为 null = 到播放列表结尾。
List<BlurayEdlSegment> blurayEdlSegmentsForRange(
  BlurayPlaylist playlist, {
  required String discRootPath,
  required Duration start,
  Duration? end,
}) {
  final int from = start.inMicroseconds * kBlurayTimeScale ~/ 1000000;
  final int? to = end == null
      ? null
      : end.inMicroseconds * kBlurayTimeScale ~/ 1000000;
  final List<BlurayEdlSegment> out = <BlurayEdlSegment>[];
  int offset = 0;
  for (final BlurayClipRef clip in playlist.clips) {
    final int itemStart = offset;
    final int itemEnd = offset + clip.durationTicks;
    offset = itemEnd;
    final int segStart = from > itemStart ? from : itemStart;
    final int segEnd = to == null ? itemEnd : (to < itemEnd ? to : itemEnd);
    if (segEnd <= segStart) continue;
    out.add((
      source: p.join(discRootPath, 'BDMV', 'STREAM', clip.streamFileName),
      inTimeTicks: clip.inTimeTicks + (segStart - itemStart),
      durationTicks: segEnd - segStart,
    ));
  }
  return out;
}

/// BD `.mpls` 成员路径 + 章节起止 → mpv 源。读不到 / 不是播放列表返回 null。
Future<MusicDiscMediaSource?> musicBlurayMediaSource(
  String playlistPath, {
  required int startMs,
  int? endMs,
}) async {
  if (!isBlurayPlaylistPath(playlistPath)) return null;
  final String? root = blurayDiscRootForPlaylistPath(playlistPath);
  if (root == null) return null;
  final Uint8List bytes;
  try {
    bytes = await File(playlistPath).readAsBytes();
  } on FileSystemException {
    return null;
  }
  final BlurayPlaylist? playlist = parseBlurayPlaylist(
    bytes,
    id: p.basenameWithoutExtension(playlistPath),
  );
  if (playlist == null) return null;
  final List<BlurayEdlSegment> segments = blurayEdlSegmentsForRange(
    playlist,
    discRootPath: root,
    start: Duration(milliseconds: startMs),
    end: endMs == null ? null : Duration(milliseconds: endMs),
  );
  if (segments.isEmpty) return null;
  return MusicDiscMediaSource(
    uri: buildBlurayEdlUri(segments),
    fileLocalOptions: kMusicDiscAudioOnlyOptions,
  );
}

/// 光盘章节曲目 → mpv 源（DVD 同步可得，BD 要读 MPLS）。不是光盘曲目返回 null。
Future<MusicDiscMediaSource?> resolveMusicDiscMediaSource(
  String path, {
  required int startMs,
  int? endMs,
}) async {
  if (isDvdTitlePath(path)) {
    return musicDvdMediaSource(path, startMs: startMs, endMs: endMs);
  }
  if (isBlurayPlaylistPath(path)) {
    return musicBlurayMediaSource(path, startMs: startMs, endMs: endMs);
  }
  return null;
}
