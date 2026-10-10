// 互联远端播放蓝光标题。
//
// 库里一条蓝光标题的 `videoPath` 是几 KB 的 `BDMV/PLAYLIST/*.mpls`，真正的码流分散在
// `BDMV/STREAM/*.m2ts`（还可能 AACS 加密）。本地播放由 [resolveBluraySource] +
// [AacsMediaSession] 把它变成 `edl://`（每段一个本地路径或解密回环 URL）。远端
// client 没有盘，过去 host 把 `.mpls` 本身当视频直传，播放器一打开就报错。
//
// 修法是让 client 走**同一条 EDL 路径**：host 按段下发（必要时先解密）每个 m2ts，
// 支持 Range；client 拿到段表后用 [buildBlurayEdlUri] 拼出与本地逐 tick 相同的时间
// 轴。不转码、不改容器，seek / 时长 / 章节 / 多音轨 / PGS 字幕都与本地播放同语义。
//
// 光盘菜单（BD-J / HDMV 按钮）由 libbluray 直接读盘目录，远端只有 HTTP 流，做不到，
// 也不在这里假装支持。

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';

/// 蓝光分段端点的路径尾（`/api/library/videos/<id>/bdclip.m2ts?token=&n=`）。
const String kBlurayClipPathSuffix = 'bdclip.m2ts';

/// host 侧：一条标题解析出的段表与它引用的物理码流。
class BlurayTitleStreams {
  const BlurayTitleStreams({
    required this.playlist,
    required this.streamPaths,
    required this.clipStreams,
  });

  final BlurayPlaylist playlist;

  /// 去重后的 `STREAM/*.m2ts` 绝对路径；下标就是分段端点的 `n`。
  final List<String> streamPaths;

  /// 与 `playlist.clips` 一一对应：第 i 段用的是 [streamPaths] 的哪一个。
  final List<int> clipStreams;

  /// 按 [streamUrl]（流下标 → 可直接交给播放器的 URL）生成下发给 client 的描述。
  BlurayRemoteTitle remoteTitle(String Function(int stream) streamUrl) =>
      BlurayRemoteTitle(
        duration: playlist.duration,
        chapters: <Duration>[
          for (final BlurayChapter chapter in playlist.chapters) chapter.start,
        ],
        clips: <BlurayRemoteClip>[
          for (int i = 0; i < playlist.clips.length; i++)
            BlurayRemoteClip(
              url: streamUrl(clipStreams[i]),
              inTimeTicks: playlist.clips[i].inTimeTicks,
              durationTicks: playlist.clips[i].durationTicks,
            ),
        ],
      );
}

/// 读入 [playlistPath] 并列出它引用的码流。不是 MPLS、盘结构不完整、段表为空时返回
/// null。不检查码流是否存在——缺段在取那一段时如实 404，而不是让整条标题先失败。
Future<BlurayTitleStreams?> readBlurayTitleStreams(String playlistPath) async {
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
  if (playlist == null || playlist.clips.isEmpty) return null;
  final List<String> streamPaths = <String>[];
  final List<int> clipStreams = <int>[];
  for (final BlurayClipRef clip in playlist.clips) {
    final String path = p.join(root, 'BDMV', 'STREAM', clip.streamFileName);
    int index = streamPaths.indexOf(path);
    if (index < 0) {
      index = streamPaths.length;
      streamPaths.add(path);
    }
    clipStreams.add(index);
  }
  return BlurayTitleStreams(
    playlist: playlist,
    streamPaths: streamPaths,
    clipStreams: clipStreams,
  );
}

/// 远端一段：[url] 是 host 的分段地址，IN / 时长是 MPLS tick。
class BlurayRemoteClip {
  const BlurayRemoteClip({
    required this.url,
    required this.inTimeTicks,
    required this.durationTicks,
  });

  final String url;
  final int inTimeTicks;
  final int durationTicks;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'inTicks': inTimeTicks,
    'durationTicks': durationTicks,
  };

  static BlurayRemoteClip? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? url = json['url'];
    final Object? inTicks = json['inTicks'];
    final Object? durationTicks = json['durationTicks'];
    if (url is! String || url.isEmpty) return null;
    if (inTicks is! int || durationTicks is! int || durationTicks <= 0) {
      return null;
    }
    return BlurayRemoteClip(
      url: url,
      inTimeTicks: inTicks,
      durationTicks: durationTicks,
    );
  }
}

/// host 下发给 client 的一条蓝光标题（`/streamurl` 响应的 `discTitle` 字段）。
class BlurayRemoteTitle {
  const BlurayRemoteTitle({
    required this.duration,
    required this.chapters,
    required this.clips,
  });

  final Duration duration;

  /// 章节起点，相对播放列表时间轴（来自 MPLS，与本地播放同一份）。
  final List<Duration> chapters;

  final List<BlurayRemoteClip> clips;

  /// 拼成交给播放内核的 `edl://`。[mapUrl] 在拼接前改写每段地址——client 用它把
  /// 互联 host 的自签 https 降成交给本地中继的明文 http（`nativePlaybackUri`）；
  /// 整串 EDL 不是 URL，过不了那道改写，必须逐段做。
  String edlUri([String Function(String url)? mapUrl]) =>
      buildBlurayEdlUri(<BlurayEdlSegment>[
        for (final BlurayRemoteClip clip in clips)
          (
            source: mapUrl == null ? clip.url : mapUrl(clip.url),
            inTimeTicks: clip.inTimeTicks,
            durationTicks: clip.durationTicks,
          ),
      ]);

  Map<String, Object?> toJson() => <String, Object?>{
    'durationMs': duration.inMilliseconds,
    'chaptersMs': <int>[
      for (final Duration chapter in chapters) chapter.inMilliseconds,
    ],
    'clips': <Map<String, Object?>>[
      for (final BlurayRemoteClip clip in clips) clip.toJson(),
    ],
  };

  /// 任何一段解析不了就整体判 null：少一段的 EDL 时间轴是错的，比没有更糟。
  static BlurayRemoteTitle? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? rawClips = json['clips'];
    if (rawClips is! List || rawClips.isEmpty) return null;
    final List<BlurayRemoteClip> clips = <BlurayRemoteClip>[];
    for (final Object? raw in rawClips) {
      final BlurayRemoteClip? clip = BlurayRemoteClip.fromJson(raw);
      if (clip == null) return null;
      clips.add(clip);
    }
    final Object? durationMs = json['durationMs'];
    final Object? rawChapters = json['chaptersMs'];
    return BlurayRemoteTitle(
      duration: Duration(milliseconds: durationMs is int ? durationMs : 0),
      chapters: <Duration>[
        if (rawChapters is List)
          for (final Object? ms in rawChapters)
            if (ms is int && ms >= 0) Duration(milliseconds: ms),
      ],
      clips: clips,
    );
  }
}
