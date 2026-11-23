import 'dart:async';

import 'package:audio_service/audio_service.dart' as ag;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/src/platform/android/android_notification_channels.dart';
import 'package:fushi/src/utils/misc/fushi_audio_handler.dart';

/// 系统媒体会话（锁屏 / 通知 / 耳机键 / Android 媒体前台服务）此刻归谁。系统那边一个
/// app 只有一套媒体控件，所以有声书、音乐、视频（后台继续播放声音时）**同一时刻只有
/// 一个**持有（音乐设计 §7.5；视频见拍板台 42UUu_kcwD-media）。规则：后开始出声的一方
/// 认领会话，被抢走的一方暂停（[MediaSessionSeat.onPreempted]）。
enum MediaSessionOwner { none, audiobook, music, video }

class AudioController {
  /// 当前持有媒体会话的一方。控制流按它分发（[ownsSession]）：有声书在无人持有时
  /// 也收（保持既有行为），音乐 / 视频只在自己持有时收。
  final ValueNotifier<MediaSessionOwner> sessionOwner =
      ValueNotifier<MediaSessionOwner>(MediaSessionOwner.none);

  /// 各方「会话被别人抢走」时的回调（被抢方据此暂停）。经 [seat] 登记。
  final Map<MediaSessionOwner, VoidCallback> _preemptHandlers =
      <MediaSessionOwner, VoidCallback>{};

  /// 认领媒体会话。从另一方（非 [MediaSessionOwner.none]）手里抢过来时，通知被抢方
  /// （它登记的 [MediaSessionSeat.onPreempted]）暂停；让回 none 不算抢。
  void claimSession(MediaSessionOwner owner) {
    final MediaSessionOwner previous = sessionOwner.value;
    if (previous == owner) return;
    sessionOwner.value = owner;
    if (previous == MediaSessionOwner.none || owner == MediaSessionOwner.none) {
      return;
    }
    _preemptHandlers[previous]?.call();
  }

  /// [owner] 此刻是否该收系统媒体控制、能不能往通知 / 锁屏推内容：有声书在无人持有
  /// 时也算（它是这套会话最早的使用者，开书即推通知），其余只认自己持有。
  bool ownsSession(MediaSessionOwner owner) {
    final MediaSessionOwner current = sessionOwner.value;
    if (owner == MediaSessionOwner.audiobook) {
      return current == MediaSessionOwner.none ||
          current == MediaSessionOwner.audiobook;
    }
    return current == owner;
  }

  /// [owner] 一方的座位：认领 / 让出 / 被抢回调都经它。
  MediaSessionSeat seat(MediaSessionOwner owner) =>
      MediaSessionSeat._(this, owner);

  /// 只在 [owner] 持有会话时放行的控制流视图（判据 [ownsSession]）。
  Stream<T> streamFor<T>(Stream<T> source, MediaSessionOwner owner) =>
      source.where((_) => ownsSession(owner));

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
        config: ag.AudioServiceConfig(
          androidNotificationChannelId: kAudioServiceNotificationChannelId,
          // 只在渠道还不存在时生效；之后跟界面语言改名由启动同步负责
          // （android_notification_channels.dart，拍板台 left3621）。
          androidNotificationChannelName: t.notification_channel_media_playback,
          androidNotificationIcon: 'drawable/ic_stat_fushi',
          notificationColor: Colors.black,
          fastForwardInterval: const Duration(seconds: 5),
          rewindInterval: const Duration(seconds: 5),
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
    _preemptHandlers.clear();
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

/// 一方在系统媒体会话上的座位（[AudioController.seat]）。参与方只经它认领、让出、
/// 登记「被抢」回调，不直接改 [AudioController.sessionOwner]。
class MediaSessionSeat {
  MediaSessionSeat._(this._controller, this.owner);

  final AudioController _controller;
  final MediaSessionOwner owner;

  /// 本方此刻该收控制、能往通知 / 锁屏推内容（[AudioController.ownsSession]）。
  bool get held => _controller.ownsSession(owner);

  /// 本方正式持有（不含有声书「无人持有也算」的兜底）。
  bool get claimed => _controller.sessionOwner.value == owner;

  /// 认领会话；返回持有方是否因此换了（换了的话调用方要重推自己的媒体卡）。
  bool claim() {
    final bool changed = _controller.sessionOwner.value != owner;
    _controller.claimSession(owner);
    return changed;
  }

  /// 本方正式持有时让回无人持有；已被别人抢走时什么都不做。
  void release() {
    if (claimed) _controller.claimSession(MediaSessionOwner.none);
  }

  /// 会话被另一方抢走时的回调（被抢方在这里暂停）。设 null 注销。
  set onPreempted(VoidCallback? callback) {
    if (callback == null) {
      _controller._preemptHandlers.remove(owner);
    } else {
      _controller._preemptHandlers[owner] = callback;
    }
  }
}
