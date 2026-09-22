// 蓝光标题的容器事实：不跑 ffprobe，直接从 MPLS 读。
//
// MPLS 的 STN table 本来就写着编码、扫描格式、帧率、每条音轨与字幕轨的语言——这正是
// 库页角标要的那几样。反过来 ffprobe 在这里既慢又给不全：`.mpls` 它根本不认，要探只
// 能去探 `STREAM/*.m2ts`，而 BD 的 m2ts 实测一条 18~75 秒（BUG-1867/1877）；就算探
// 了，多段正片的总时长也只能是某一段的时长，不是这条播放列表的。
//
// 唯一给不出的是**画面宽度**：`video_format` 只编码扫描格式，而 BD 规范允许 1080 行
// 同时对应 1920 与 1440（MPEG-2/VC-1 的变形宽高比）。这里不猜，留 null——展示层对
// 「有高度没宽度」已有兜底（只是不显示像素对）。

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../video_duration_probe.dart';
import 'bluray_playlist.dart';
import 'bluray_source.dart';

/// 读 [playlistPath] 指向的 MPLS 并折成 [VideoProbeFacts]。
///
/// 读不到/解不开返回 [VideoProbeFacts.unavailable]——这是「没得出结论」，与「探完了，
/// 这文件没有规格」不同，调用方据此会在冷却后重试而不是永久记账。
Future<VideoProbeFacts> probeBlurayPlaylistFacts(String playlistPath) async {
  final File file = File(playlistPath);
  final Uint8List bytes;
  try {
    if (!file.existsSync()) return VideoProbeFacts.unavailable;
    bytes = await file.readAsBytes();
  } on FileSystemException {
    return VideoProbeFacts.unavailable;
  }
  final BlurayPlaylist? playlist = parseBlurayPlaylist(
    bytes,
    id: p.basenameWithoutExtension(playlistPath),
  );
  if (playlist == null) return VideoProbeFacts.unavailable;

  return blurayPlaylistFacts(
    playlist,
    streamBytes: await _sumClipBytes(playlistPath, playlist),
  );
}

/// 这条播放列表引用到的 m2ts 总字节数；一个都 stat 不到返回 null。
Future<int?> _sumClipBytes(String playlistPath, BlurayPlaylist playlist) async {
  final String? root = blurayDiscRootForPlaylistPath(playlistPath);
  if (root == null) return null;
  int total = 0;
  bool any = false;
  for (final String clipId in playlist.clipIds.toSet()) {
    try {
      final FileStat stat = await FileStat.stat(
        p.join(root, 'BDMV', 'STREAM', '$clipId.m2ts'),
      );
      if (stat.type == FileSystemEntityType.notFound) continue;
      total += stat.size;
      any = true;
    } on FileSystemException {
      continue;
    }
  }
  return any ? total : null;
}

/// 纯函数：把一条播放列表折成容器事实。
VideoProbeFacts blurayPlaylistFacts(
  BlurayPlaylist playlist, {
  int? streamBytes,
}) {
  final List<BlurayStream> videos = playlist.videoStreams;
  final BlurayStream? video = videos.isEmpty ? null : videos.first;
  final double? fps = video?.framesPerSecond;

  int index = 0;
  final List<AudioTrackFacts> audio = <AudioTrackFacts>[
    for (final BlurayStream stream in playlist.audioStreams)
      AudioTrackFacts(
        index: index++,
        codec: _audioCodecName(stream.codingType),
        language: stream.languageCode,
      ),
  ];
  final List<SubtitleTrackFacts> subtitles = <SubtitleTrackFacts>[
    for (final BlurayStream stream in playlist.subtitleStreams)
      SubtitleTrackFacts(
        index: index++,
        codec: _subtitleCodecName(stream.codingType),
        language: stream.languageCode,
      ),
  ];

  return VideoProbeFacts(
    durationMs: playlist.duration.inMilliseconds,
    fileSizeBytes: streamBytes,
    video: video == null
        ? null
        : VideoStreamFacts(
            codec: _videoCodecName(video.codingType),
            height: video.videoHeight,
            frameRateMilli: fps == null ? null : (fps * 1000).round(),
          ),
    audioTracks: audio,
    subtitleTracks: subtitles,
  );
}

/// BD 的 `stream_coding_type` → ffprobe 的 `codec_name` 写法。
///
/// 用 ffprobe 的名字而不是 BD 的显示名，是因为下游的编码名映射表（角标、字幕格式标
/// 签）统一按 ffprobe 的拼写查表；换一套拼写等于给每张表加一份分支。
String? _videoCodecName(int codingType) => switch (codingType) {
  0x01 => 'mpeg1video',
  0x02 => 'mpeg2video',
  0x1B || 0x20 => 'h264',
  0x24 => 'hevc',
  0xEA => 'vc1',
  _ => null,
};

String? _audioCodecName(int codingType) => switch (codingType) {
  0x03 || 0x04 => 'mp2',
  0x80 => 'pcm_bluray',
  0x81 => 'ac3',
  0x82 || 0x85 || 0x86 || 0xA2 => 'dts',
  0x83 => 'truehd',
  0x84 || 0xA1 => 'eac3',
  _ => null,
};

String? _subtitleCodecName(int codingType) => switch (codingType) {
  0x90 => 'hdmv_pgs_subtitle',
  0x92 => 'hdmv_text_subtitle',
  _ => null,
};
