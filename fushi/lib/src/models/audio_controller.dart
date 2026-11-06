import 'dart:async';

import 'package:audio_service/audio_service.dart' as ag;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/misc/fushi_audio_handler.dart';

/// 系统媒体会话（锁屏 / 通知 / 耳机键）此刻归谁：有声书与音乐**同一时刻只有一个**
/// 持有（设计 §7.5），另一个暂停。
enum MediaSessionOwner { none, audiobook, music }

class AudioController {
  /// 当前持有媒体会话的一方。控制流按它分发：有声书收除音乐持有外的全部事件（保持
  /// 既有行为），音乐只在自己持有时收。
  final ValueNotifier<MediaSessionOwner> sessionOwner =
      ValueNotifier<MediaSessionOwner>(MediaSessionOwner.none);

  /// 认领媒体会话。
  void claimSession(MediaSessionOwner owner) => sessionOwner.value = owner;

  /// 只在 [owner] 持有会话时放行的控制流视图。
  Stream<T> streamFor<T>(Stream<T> source, MediaSessionOwner owner) =>
      owner == MediaSessionOwner.music
      ? source.where((_) => sessionOwner.value == MediaSessionOwner.music)
      : source.where((_) => sessionOwner.value != MediaSessionOwner.music);

  Stream<MediaPlayIntent> get playIntentStream => _playController.stream;
  final StreamController<MediaPlayIntent> _playController =
      StreamController.broadcast();

  Stream<Duration> get seekStream => _seekController.stream;
  final StreamController<Duration> _seekController =
      StreamController.broadcast();

  Stream<void> get rewindStream => _rewindController.stream;
  final StreamController<void> _rewindController = StreamController.broadcast();

  Stream<void> get fastForwardStream => _fastForwardController.stream;
  final StreamController<void> _fastForwardController =
      StreamController.broadcast();

  Stream<void> get skipNextStream => _skipNextController.stream;
  final StreamController<void> _skipNextController =
      StreamController.broadcast();

  Stream<void> get skipPreviousStream => _skipPreviousController.stream;
  final StreamController<void> _skipPreviousController =
      StreamController.broadcast();

  /// 通知栏「悬浮字幕」custom action 广播流。
  Stream<void> get toggleFloatingLyricStream =>
      _toggleFloatingLyricController.stream;
  final StreamController<void> _toggleFloatingLyricController =
      StreamController.broadcast();

  Stream<void> get currentMediaPauseStream => _mediaPauseController.stream;
  final StreamController<void> _mediaPauseController =
      StreamController.broadcast();

  Stream<void> get playPauseHeadsetActionStream =>
      _playPauseHeadsetController.stream;
  final StreamController<void> _playPauseHeadsetController =
      StreamController.broadcast();

  FushiAudioHandler? get audioHandler => _audioHandler;
  FushiAudioHandler? _audioHandler;

  void emitMediaPause() => _mediaPauseController.add(null);

  /// 在飞/已完成的初始化 future（并发安全 + 可重复 await 的单次初始化）。
  /// openMedia 只起跑不 await（audio_service 冷启不再阻塞导航）；真正需要
  /// handler 的消费端（audiobook 会话 attach/start、书架后台听书）各自 await
  /// 同一份。方法体自带 catch 兜底（构造本地 handler）、永不失败，故无需
  /// 失败重置。旧实现只查 `_audioHandler != null`，并发双调会双跑
  /// AudioService.init。
  Future<void>? _handlerInit;

  Future<void> initialiseHandler() => _handlerInit ??= _initialiseHandlerOnce();

  Future<void> _initialiseHandlerOnce() async {
    if (_audioHandler != null) return;

    try {
      _audioHandler = await ag.AudioService.init<FushiAudioHandler>(
        builder: () => FushiAudioHandler(
          onPlayIntent: _playController.add,
          onSeek: (pos) => _seekController.add(pos),
          onRewind: () => _rewindController.add(null),
          onFastForward: () => _fastForwardController.add(null),
          onSkipToNext: () => _skipNextController.add(null),
          onSkipToPrevious: () => _skipPreviousController.add(null),
          onToggleFloatingLyric: () => _toggleFloatingLyricController.add(null),
        ),
        config: const ag.AudioServiceConfig(
          androidNotificationChannelId: 'app.fushi.reader.channel.audio',
          androidNotificationChannelName: 'fushi',
          androidNotificationIcon: 'drawable/ic_stat_fushi',
          notificationColor: Colors.black,
          fastForwardInterval: Duration(seconds: 5),
          rewindInterval: Duration(seconds: 5),
        ),
      );
    } catch (e) {
      debugPrint('[Fushi] AudioService.init failed (non-fatal): $e');
      _audioHandler = FushiAudioHandler(
        onPlayIntent: _playController.add,
        onSeek: (pos) => _seekController.add(pos),
        onRewind: () => _rewindController.add(null),
        onFastForward: () => _fastForwardController.add(null),
        onSkipToNext: () => _skipNextController.add(null),
        onSkipToPrevious: () => _skipPreviousController.add(null),
        onToggleFloatingLyric: () => _toggleFloatingLyricController.add(null),
      );
    }
  }

  void dispose() {
    sessionOwner.dispose();
    _mediaPauseController.close();
    _playPauseHeadsetController.close();
    _playController.close();
    _seekController.close();
    _rewindController.close();
    _fastForwardController.close();
    _skipNextController.close();
    _skipPreviousController.close();
    _toggleFloatingLyricController.close();
  }
}
