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

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/music/disc/music_disc_media.dart'
    show isMusicDiscTitlePath;
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/disc/music_audio_cd.dart'
    show isMusicCddaPath;
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';

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

/// 播放项 → 制卡截音频的源。截不了抛 [MusicClipSourceUnavailable]（带原因）。
///
/// [pluginResolver]：插件曲目取流（缺省 [resolveMusicPluginStream]，测试注入替身）。
Future<MusicClipSource> resolveMusicClipSource(
  MusicPlayItem item, {
  MusicPluginStreamResolver? pluginResolver,
}) async {
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
