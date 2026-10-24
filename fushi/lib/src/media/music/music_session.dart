/// 进程级音乐会话（设计 §7.5）：持有 [MusicPlayerEngine]，接系统媒体会话（锁屏 /
/// 通知 / 耳机键），与有声书互斥——同一时刻只有一方持有媒体会话，另一方暂停。
/// 播放流（最近播放）也在这里落库。
library;

import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/models/audio_controller.dart';
import 'package:fushi/src/utils/misc/fushi_audio_handler.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/i18n/strings.g.dart';

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
      // 独占 / 指定设备打不开、已自动退回：明确提示，不静默（设计 §14）。
      ..onOutputFallback = (MusicBackendOutputFallback f) {
        FushiToast.show(
          msg: switch (f.reason) {
            MusicOutputFallbackReason.exclusiveUnavailable =>
              t.music_output_fallback_exclusive,
            MusicOutputFallbackReason.deviceUnavailable =>
              t.music_output_fallback_device,
          },
        );
      }
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

  bool _audioSessionSubscribed = false;
  bool _resumeAfterInterruption = false;

  int? _playEventId;
  MusicPlayItem? _playEventItem;

  bool get isActive => engine.isActive;

  /// 锁屏 / 媒体通知副标题要显示的当前歌词行（设计 §6.2；null = 显示艺人）。由 AppModel
  /// 接到 `MusicLyricsLive.mediaSessionLine`，行变化时调 [refreshMediaSession]。
  String? Function()? mediaSessionLyricLine;

  /// 当前行变了：重发媒体会话元数据。
  void refreshMediaSession() => _publishMediaSession();

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

  /// 系统音频会话（设计 §7.5）：mpv 不管 Android 音频焦点 / iOS AVAudioSession，
  /// 由 audio_session 接——耳机拔出暂停、来电等打断暂停并在系统允许时恢复。
  /// 蓝牙 / 线控按键走 audio_service 的媒体按键（[AudioController] 的意图流）。
  ///
  /// 每次开播都重新 configure：有声书用的是 spokenAudio 模式，两边共用同一个系统会话。
  Future<void> _ensureAudioSession() async {
    final AudioSession session = await AudioSession.instance;
    await session.configure(
      const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.none,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.longFormAudio,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        // 被短暂压低（导航播报等）时系统自己降音量，不暂停。
        androidWillPauseWhenDucked: false,
      ),
    );
    if (_audioSessionSubscribed) return;
    _audioSessionSubscribed = true;
    _subs.add(
      session.becomingNoisyEventStream.listen((_) {
        // 耳机拔出 / 蓝牙断开：立即暂停，不外放。
        if (engine.isPlaying) unawaited(engine.pause());
      }),
    );
    _subs.add(session.interruptionEventStream.listen(_onInterruption));
  }

  void _onInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          return;
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          if (engine.isPlaying) {
            _resumeAfterInterruption =
                event.type == AudioInterruptionType.pause;
            unawaited(engine.pause());
          }
      }
      return;
    }
    // 打断结束：只有系统表示可以恢复（暂时性打断，如来电挂断）才自动续播。
    if (event.type == AudioInterruptionType.pause && _resumeAfterInterruption) {
      unawaited(engine.play());
    }
    _resumeAfterInterruption = false;
  }

  /// 音乐要开始出声：认领媒体会话，正在放的有声书暂停（不停会话，回去还能接着听）。
  void _onWillPlay() {
    unawaited(
      _ensureAudioSession().then(
        (_) async => (await AudioSession.instance).setActive(true),
      ),
    );
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
      // 服务器曲库的封面是 http(s) 地址（audio_service 自己下载），本地封面是文件。
      artUri: cover == null
          ? null
          : (cover.startsWith('http://') || cover.startsWith('https://'))
          ? Uri.parse(cover)
          : (File(cover).existsSync() ? Uri.file(cover) : null),
    );
    final String? line = mediaSessionLyricLine?.call();
    if (line != null) {
      handler.updateNotificationSubtitle(
        title: item.title,
        subtitle: line,
        fallbackArtist: item.artist,
      );
    }
    handler.updatePlaybackState(
      playing: engine.isPlaying,
      position: engine.position,
      speed: engine.currentSettings.speed,
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
