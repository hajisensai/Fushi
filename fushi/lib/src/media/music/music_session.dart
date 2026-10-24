/// 进程级音乐会话（设计 §7.5）：持有 [MusicPlayerEngine]，接系统媒体会话（锁屏 /
/// 通知 / 耳机键），与有声书互斥——同一时刻只有一方持有媒体会话，另一方暂停。
/// 播放流（最近播放）也在这里落库。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/models/audio_controller.dart';
import 'package:fushi/src/utils/misc/fushi_audio_handler.dart';

/// 一首播完算「听完」的容差。
const Duration kMusicCompletionSlack = Duration(seconds: 2);

class MusicSession extends ChangeNotifier {
  MusicSession({
    required this.engine,
    required AudioController audio,
    required AudiobookSession audiobook,
    required FushiDatabase? Function() database,
    required bool Function() showMediaNotification,
  }) : _audio = audio,
       _audiobook = audiobook,
       _database = database,
       _showMediaNotification = showMediaNotification {
    engine
      ..onWillPlay = _onWillPlay
      ..onTrackStarted = _onTrackStarted
      ..addListener(_onEngineChanged);
    _audiobook.addListener(_onAudiobookChanged);
    _subs.addAll(<StreamSubscription<Object?>>[
      _audio
          .streamFor(_audio.playIntentStream, MediaSessionOwner.music)
          .listen(_onPlayIntent),
      _audio
          .streamFor(_audio.seekStream, MediaSessionOwner.music)
          .listen((Duration p) => unawaited(engine.seek(p))),
      _audio
          .streamFor(_audio.skipNextStream, MediaSessionOwner.music)
          .listen((_) => unawaited(engine.skipNext())),
      _audio
          .streamFor(_audio.skipPreviousStream, MediaSessionOwner.music)
          .listen((_) => unawaited(engine.skipPrevious())),
      _audio
          .streamFor(_audio.rewindStream, MediaSessionOwner.music)
          .listen(
            (_) => unawaited(engine.seekRelative(const Duration(seconds: -5))),
          ),
      _audio
          .streamFor(_audio.fastForwardStream, MediaSessionOwner.music)
          .listen(
            (_) => unawaited(engine.seekRelative(const Duration(seconds: 5))),
          ),
    ]);
  }

  final MusicPlayerEngine engine;
  final AudioController _audio;
  final AudiobookSession _audiobook;
  final FushiDatabase? Function() _database;
  final bool Function() _showMediaNotification;
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  int? _playEventId;
  MusicPlayItem? _playEventItem;

  bool get isActive => engine.isActive;

  void _onPlayIntent(MediaPlayIntent intent) {
    switch (intent) {
      case MediaPlayIntent.play:
        unawaited(engine.play());
      case MediaPlayIntent.pause:
        unawaited(engine.pause());
      case MediaPlayIntent.toggle:
        unawaited(engine.togglePlayPause());
    }
  }

  /// 音乐要开始出声：认领媒体会话，正在放的有声书暂停（不停会话，回去还能接着听）。
  void _onWillPlay() {
    _audio.claimSession(MediaSessionOwner.music);
    final controller = _audiobook.controller;
    if (controller != null && controller.isPlaying) {
      unawaited(controller.pause());
    }
  }

  /// 有声书开始出声：把会话让回去，音乐暂停。
  void _onAudiobookChanged() {
    final controller = _audiobook.controller;
    if (controller == null || !controller.isPlaying) return;
    if (_audio.sessionOwner.value != MediaSessionOwner.audiobook) {
      _audio.claimSession(MediaSessionOwner.audiobook);
    }
    if (engine.isPlaying) unawaited(engine.pause());
  }

  void _onTrackStarted(MusicPlayItem item) {
    unawaited(_rotatePlayEvent(item));
  }

  Future<void> _rotatePlayEvent(MusicPlayItem? next) async {
    final FushiDatabase? db = _database();
    if (db == null) return;
    await _finishPlayEvent(db);
    if (next == null) return;
    _playEventItem = next;
    _playEventId = await db.startMusicPlayEvent(
      trackUid: next.trackUid,
      startedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _finishPlayEvent(FushiDatabase db) async {
    final int? id = _playEventId;
    final MusicPlayItem? item = _playEventItem;
    _playEventId = null;
    _playEventItem = null;
    if (id == null || item == null) return;
    final Duration listened = engine.position;
    final int? durationMs = item.durationMs;
    await db.finishMusicPlayEvent(
      id,
      listenedMs: listened.inMilliseconds,
      completed:
          durationMs != null &&
          listened + kMusicCompletionSlack >=
              Duration(milliseconds: durationMs),
    );
  }

  void _onEngineChanged() {
    _publishMediaSession();
    notifyListeners();
  }

  void _publishMediaSession() {
    if (_audio.sessionOwner.value != MediaSessionOwner.music) return;
    if (!_showMediaNotification()) return;
    final FushiAudioHandler? handler = _audio.audioHandler;
    final MusicPlayItem? item = engine.current;
    if (handler == null) return;
    if (item == null) {
      handler.clearNotification();
      return;
    }
    final String? cover = item.coverPath;
    handler.setMediaItemInfo(
      title: item.title,
      artist: item.artist,
      duration: item.durationMs == null
          ? null
          : Duration(milliseconds: item.durationMs!),
      artUri: cover != null && File(cover).existsSync()
          ? Uri.file(cover)
          : null,
    );
    handler.updatePlaybackState(
      playing: engine.isPlaying,
      position: engine.position,
      speed: 1,
      duration: engine.duration ?? Duration.zero,
    );
  }

  /// 停止音乐并释放媒体会话。
  Future<void> stop() async {
    final FushiDatabase? db = _database();
    if (db != null) await _finishPlayEvent(db);
    await engine.stop();
    if (_audio.sessionOwner.value == MediaSessionOwner.music) {
      _audio.audioHandler?.clearNotification();
      _audio.claimSession(MediaSessionOwner.none);
    }
  }

  @override
  void dispose() {
    for (final StreamSubscription<Object?> s in _subs) {
      unawaited(s.cancel());
    }
    _audiobook.removeListener(_onAudiobookChanged);
    engine.removeListener(_onEngineChanged);
    engine.dispose();
    super.dispose();
  }
}
