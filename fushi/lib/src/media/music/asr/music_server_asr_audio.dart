/// 媒体服务器曲目（Jellyfin / Subsonic）→ 「生成日语字幕」要转写的音频。
///
/// 服务器曲目没有本机文件：播放路径是带凭据的 HTTP 流地址，曲目 uid 是哈希
/// （[musicServerTrackUid]）。与在线音源插件曲目同一条路（`music_plugin_asr_audio.dart`）：
/// 开管线前把这一首的音频取到本机 16 kHz WAV（[MusicPluginAsrAudioStager.stageStream]），
/// 管线照本机文件处理，产物登记成**服务器曲目 uid** 的 `asr` 歌词行——从服务器页直接播、
/// 从音乐库 / 本地歌单播（v149 行，同一个 uid）都认这一行。
///
/// 取流按 [MusicServerTrackRef] 找当前配置的那台服务器（[MusicServerBinding]），请**原样直出**
/// （不带码率上限：转写不需要再转码一次）；地址只在内存里交给 ffmpeg，报错文本由取音频步骤
/// 脱敏，不进日志 / 数据库。
///
/// 输入是 [MusicAsrAudioInput]：这首有本机离线副本（v175 下载，[musicServerLocalCopyLookup]）
/// 时直接转写那份文件（[MusicAsrLocalAudio]，不删、不连服务器——服务器离线也能生成）；否则从
/// 服务器取流（[MusicAsrStreamAudio]）。
library;

import 'dart:io';

import 'package:fushi_engine/media/music/server/music_server.dart'
    show
        MusicServerStream,
        MusicServerTrack,
        MusicServerTrackRef,
        musicServerTrackUid;
import 'package:fushi_music/fushi_music.dart' show MusicPluginStream;

import 'package:fushi/src/media/music/asr/music_plugin_asr_audio.dart';
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/music_remote_tracks.dart'
    show MusicServerBinding, MusicServerBindingLoader, musicServerKindStorable;
import 'package:fushi/src/media/music/server/music_server_play_item.dart'
    show
        MusicServerLocalCopy,
        MusicServerLocalCopyLookup,
        musicServerLocalCopyLookup;

/// 一首要转写的服务器曲目从哪来。
sealed class MusicAsrAudioInput {
  const MusicAsrAudioInput();
}

/// 本机已有的完整音频（离线副本）：直接转写，登记完**不删**。
final class MusicAsrLocalAudio extends MusicAsrAudioInput {
  const MusicAsrLocalAudio(this.file);

  final File file;
}

/// 要先从服务器取到本机的流（[open] 每次现算地址，凭据只在内存里）。
final class MusicAsrStreamAudio extends MusicAsrAudioInput {
  const MusicAsrStreamAudio(this.open);

  final Future<MusicPluginStream> Function() open;
}

/// 这一项是不是能生成字幕的服务器曲目（Jellyfin / Subsonic，且不是试听片段）。
bool musicItemIsTranscribableServerTrack(MusicPlayItem item) {
  final MusicServerTrackRef? ref = item.serverTrack;
  return ref != null && musicServerKindStorable(ref.kind) && !item.isPreview;
}

/// 服务器曲目 → 转写输入。有离线副本（[localCopies]，缺省进程级
/// [musicServerLocalCopyLookup]）时用副本；否则这台设备上没配这台服务器时抛
/// [MusicPluginAsrAudioUnavailable]。
Future<MusicAsrAudioInput> musicServerAsrAudioInput(
  MusicServerTrackRef ref, {
  required MusicServerBindingLoader servers,
  MusicServerLocalCopyLookup? localCopies,
}) async {
  final MusicServerLocalCopy? local =
      (localCopies ?? musicServerLocalCopyLookup)?.call(ref.trackUid);
  if (local != null && await File(local.path).exists()) {
    return MusicAsrLocalAudio(File(local.path));
  }
  final MusicServerBinding? binding = (await servers())[ref.serverId];
  if (binding == null || binding.browser.kind != ref.kind) {
    throw const MusicPluginAsrAudioUnavailable(
      'this music server is not configured on this device',
    );
  }
  return MusicAsrStreamAudio(() async {
    final MusicServerStream s = binding.browser.streamFor(
      MusicServerTrack(id: ref.trackId, title: '', albumId: ref.albumId),
    );
    // 试听片段（服务器只给预览）拒掉：转写半首没有意义。
    if (s.isPreview) {
      throw const MusicPluginAsrAudioUnavailable('only a preview is available');
    }
    return MusicPluginStream(url: s.uri.toString());
  });
}

/// 转写输入 → 本机音频文件与「登记完要不要删」。流输入经 [stager] 取到本机。
Future<({File audio, bool staged})> musicAsrAudioFileOf(
  MusicAsrAudioInput input, {
  required MusicPlayItem item,
  required MusicPluginAsrAudioStager stager,
  required void Function(double? fraction) onProgress,
  required Future<void> cancel,
}) async => switch (input) {
  MusicAsrLocalAudio(:final File file) => (audio: file, staged: false),
  MusicAsrStreamAudio(:final Future<MusicPluginStream> Function() open) => (
    audio: await stager.stageStream(
      item,
      open: open,
      onProgress: onProgress,
      cancel: cancel,
    ),
    staged: true,
  ),
};

/// 服务器曲目 → 生成字幕用的播放项身份（批量入口没有播放项时用；uid 与播放时一致）。
MusicPlayItem musicServerAsrItem(
  MusicServerTrackRef ref, {
  required String title,
  String? album,
  String? albumUid,
  int? durationMs,
}) => MusicPlayItem(
  trackUid: musicServerTrackUid(ref.serverId, ref.trackId),
  path: '',
  title: title,
  album: album,
  albumUid: albumUid,
  durationMs: durationMs,
  serverTrack: ref,
);
