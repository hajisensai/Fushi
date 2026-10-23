/// [AudiobookRemotePlayback] 的 Audiobookshelf 实现：一本绑定了服务器条目的字幕书，
/// 每条音轨一个流式源，制卡时给 ffmpeg 的是文件地址 + 现取的鉴权头。
library;

import 'dart:io';

import 'package:fushi/src/media/audiobook/remote/audiobook_remote_playback.dart';
import 'package:fushi/src/media/audiobook/remote/audiobookshelf_track_audio_source.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

class AudiobookshelfRemotePlayback implements AudiobookRemotePlayback {
  /// [api] 是注册表借来的共享实例，本类不会关它。
  AudiobookshelfRemotePlayback({
    required AudiobookshelfApi api,
    required this.binding,
  }) : _api = api;

  final AudiobookshelfApi _api;
  final RemoteAudioBinding binding;

  List<RemoteAudioTrack> get tracks => binding.tracks;

  @override
  int get trackCount => tracks.length;

  /// 占位路径形如 `abs-remote/<条目>/<ino>.mp3`：相对路径、不存在，一眼能看出不是
  /// 本机文件（日志里出现时也好认）。
  @override
  late final List<File> placeholderFiles = <File>[
    for (final RemoteAudioTrack track in tracks)
      File(
        p.join(
          'abs-remote',
          binding.itemId,
          '${track.ino}${_extensionOf(track)}',
        ),
      ),
  ];

  @override
  List<AudioSource> buildSources() => <AudioSource>[
    for (int i = 0; i < tracks.length; i++) buildTrackSource(i),
  ];

  @override
  AudioSource buildTrackSource(int index) {
    final RemoteAudioTrack track = tracks[index];
    return AudiobookshelfTrackAudioSource(
      api: _api,
      itemId: binding.itemId,
      ino: track.ino,
      mimeType: track.mimeType,
      sizeBytes: track.sizeBytes,
    );
  }

  @override
  Future<AudiobookTrackInput> trackInput(int index) async {
    final RemoteAudioTrack track = tracks[index];
    return AudiobookTrackInput(
      input: _api.fileUri(binding.itemId, track.ino).toString(),
      headers: await _api.freshAuthorizationHeaders(),
    );
  }

  @override
  Future<void> release() async {
    // 共享的协议层实例归 AudiobookshelfApiRegistry 管，这里没有要释放的东西。
    // P5 的进度同步在此结算并关闭服务器会话。
  }

  static String _extensionOf(RemoteAudioTrack track) {
    final String? name = track.filename;
    if (name != null) {
      final String ext = p.extension(name);
      if (ext.isNotEmpty) return ext;
    }
    return switch (track.mimeType) {
      'audio/mp4' || 'audio/x-m4b' || 'audio/m4b' => '.m4b',
      'audio/ogg' => '.ogg',
      'audio/flac' => '.flac',
      _ => '.mp3',
    };
  }
}
