/// 制卡截句子音频的「逻辑曲目路径 → ffmpeg 能读的源」解析（播放侧的对应物是
/// [resolveMusicMedia]）。
///
/// 音乐播放项的 `path` 不一定是文件：在线音源插件曲目是 `fushi-music-plugin://` 占位、
/// 音频 CD 是 `cdda://`、光盘章节曲目是虚拟的 title 路径。播放侧经 [resolveMusicMedia]
/// 统一解析；制卡侧以前直接把 `item.path` 交给 ffmpeg，插件曲目必然报「sentence audio
/// export failed」。制卡边界一律经这里：插件曲目向插件取流（与播放共用
/// [resolveMusicPluginStream] 这一个真相源），本地文件 / CUE 曲目沿用原路径与偏移，
/// ffmpeg 读不了的虚拟路径明确报不支持（不悄悄降级）。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart'
    show isAppleMusicTrackPath;
import 'package:fushi_engine/media/music/disc/music_disc_media.dart'
    show isMusicDiscTitlePath;
import 'package:fushi_engine/media/music/youtube/youtube_music_client.dart'
    show youtubeMusicVideoIdFromPath;
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show
        audioSourceNeedsRangeMaterialization,
        materializeRemoteAudioViaRangeDownload;
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/disc/music_audio_cd.dart'
    show isMusicCddaPath;
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/media/music/server/youtube_music_gate.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart'
    show RemoteAudioMaterializer;

/// 截音频用的源：[inputPath] 交给 ffmpeg（本机路径或流 URL），[httpHeaders] 是流的请求头
/// （本机文件为空），[fileOffsetMs] 是曲目在该输入里的起点（CUE 虚拟曲目非 0）。
@immutable
final class MusicClipSource {
  const MusicClipSource({
    required this.inputPath,
    this.httpHeaders = const <String, String>{},
    this.fileOffsetMs = 0,
  });

  final String inputPath;
  final Map<String, String> httpHeaders;
  final int fileOffsetMs;
}

/// 这一首截不出句子音频；[message] 是具体原因（拼进制卡失败提示给用户看）。
final class MusicClipSourceUnavailable implements Exception {
  const MusicClipSourceUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 这一首受 DRM 保护（Apple Music 整曲在 Apple 授权的播放器里解密，拿不到 PCM；录制输出
/// 违反 MusicKit 条款）：不是失败，制卡方降级成不带句子音频的卡并说明原因。
final class MusicClipSourceProtected implements Exception {
  const MusicClipSourceProtected();

  @override
  String toString() => 'track audio is DRM-protected';
}

/// 播放项 → 制卡截音频的源。截不了抛 [MusicClipSourceUnavailable]（带原因）；受 DRM 保护
/// 抛 [MusicClipSourceProtected]（调用方降级成纯文本卡）。
///
/// [pluginResolver]：插件曲目取流（缺省 [resolveMusicPluginStream]，测试注入替身）。
/// [youtubeResolver]：YouTube 内置音源曲目取流（缺省 [resolveMusicYoutubeStream]）。
Future<MusicClipSource> resolveMusicClipSource(
  MusicPlayItem item, {
  MusicPluginStreamResolver? pluginResolver,
  MusicYoutubeStreamResolver? youtubeResolver,
}) async {
  if (isAppleMusicTrackPath(item.path)) {
    throw const MusicClipSourceProtected();
  }
  final String? youtubeId = youtubeMusicVideoIdFromPath(item.path);
  if (youtubeId != null) {
    final MusicYoutubeStream s;
    try {
      s = await (youtubeResolver ?? resolveMusicYoutubeStream)(youtubeId);
    } on MusicPluginStreamUnavailable catch (e) {
      throw MusicClipSourceUnavailable(
        'youtube stream unavailable: ${e.message}',
      );
    }
    // 取到的 audio-only 流就是这一首本身：起点 0。
    return MusicClipSource(
      inputPath: s.url,
      httpHeaders: Map<String, String>.unmodifiable(s.headers),
    );
  }
  if (isMusicPluginPath(item.path)) {
    final MusicPluginStream s;
    try {
      s = await (pluginResolver ?? resolveMusicPluginStream)(item.path);
    } on MusicPluginStreamUnavailable catch (e) {
      throw MusicClipSourceUnavailable(
        'plugin stream unavailable: ${e.message}',
      );
    }
    // 插件流就是这一首本身：起点 0。
    return MusicClipSource(
      inputPath: s.url,
      httpHeaders: Map<String, String>.unmodifiable(s.headers),
    );
  }
  if (isMusicCddaPath(item.path)) {
    throw const MusicClipSourceUnavailable(
      'audio CD tracks cannot be clipped for sentence audio',
    );
  }
  if (isMusicDiscTitlePath(item.path)) {
    throw const MusicClipSourceUnavailable(
      'disc chapter tracks cannot be clipped for sentence audio',
    );
  }
  return MusicClipSource(inputPath: item.path, fileOffsetMs: item.startMs ?? 0);
}

/// 截音频前把「远端 seek 会卡死」的源物化成本地文件，返回 ffmpeg 该读的源。
///
/// googlevideo（YouTube 内置音源曲目）的 audio-only 流对 ffmpeg 远端 `-ss` 会被限速卡住直到
/// 120 秒超时、出不了句子音频（TODO-1314 / BUG-600，视频制卡同一根因）。判据与视频制卡共用
/// [audioSourceNeedsRangeMaterialization]，物化与视频制卡共用 range 分片整段下载
/// （[materializeRemoteAudioViaRangeDownload]，写到 [workDir] 下），之后对本地文件 `-ss` 即时。
/// 其余源（本机文件 / CUE、插件 CDN 直链）原样返回：它们没有这个限速，直接裁即可。
///
/// 物化失败抛 [MusicClipSourceUnavailable]（带下载失败的原因），不回退成对 URL 裁——那条路
/// 就是要绕开的 120 秒干等。[materializer] 仅供测试注入。
Future<MusicClipSource> materializeMusicClipSource(
  MusicClipSource source, {
  required String workDir,
  RemoteAudioMaterializer? materializer,
}) async {
  if (!audioSourceNeedsRangeMaterialization(source.inputPath)) return source;
  String? failure;
  final String? local = await (materializer ?? _defaultMusicClipMaterializer)(
    audioUrl: source.inputPath,
    outputPath: '$workDir${Platform.pathSeparator}track_audio_src',
    onFailure: (String summary) => failure ??= summary,
  );
  if (local == null) {
    throw MusicClipSourceUnavailable(
      failure == null
          ? 'youtube audio download failed'
          : 'youtube audio download failed: $failure',
    );
  }
  // 本地文件不再需要流的请求头；曲目起点不变。
  return MusicClipSource(inputPath: local, fileOffsetMs: source.fileOffsetMs);
}

Future<String?> _defaultMusicClipMaterializer({
  required String audioUrl,
  required String outputPath,
  void Function(String summary)? onFailure,
}) => materializeRemoteAudioViaRangeDownload(
  audioUrl: audioUrl,
  outputPath: outputPath,
  onFailure: onFailure,
);
