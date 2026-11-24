import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/models/audio_controller.dart';
import 'package:fushi/src/utils/misc/fushi_audio_handler.dart';

/// 后台继续放声音的视频（拍板台 42UUu_kcwD-media）在系统媒体会话里的一切：锁屏 /
/// 控制中心 / 通知栏的播放卡、耳机线控与蓝牙键、Android 媒体前台服务（进程后台不被
/// 回收靠它）、来电等音频打断后的暂停与恢复。
///
/// 系统一个 app 只有一套媒体控件，由 audio_service 的唯一 handler 提供，有声书与音乐
/// 已经在共用（[AudioController.sessionOwner]）。视频只是多一个成员
/// [MediaSessionOwner.video]，规则与另外两方相同：后开始出声的一方认领会话，被抢走的
/// 一方暂停。视频**只在「后台继续播放声音」开着、并且确实切到后台时**才认领
/// （[engage]），回到前台就让出（[release]）——前台的视频页照旧不挂通知。
class VideoBackgroundMediaSession {
  VideoBackgroundMediaSession({
    required MediaSessionSeat seat,
    required Future<FushiAudioHandler?> Function() handler,
    required VideoMediaSessionControls controls,
    required bool Function() fullNotification,
    VideoAudioFocus? focus,
    DateTime Function()? now,
  }) : _seat = seat,
       _obtainHandler = handler,
       _controls = controls,
       _fullNotification = fullNotification,
       _focus = focus ?? SystemVideoAudioFocus(),
       _now = now ?? DateTime.now;

  final MediaSessionSeat _seat;
  final Future<FushiAudioHandler?> Function() _obtainHandler;
  final VideoMediaSessionControls _controls;

  /// 「显示媒体通知」开关（与有声书 / 音乐同一个）：关着推最简形态（只有标题 + 播放 /
  /// 暂停），开着推完整形态。关着也照推播放态：Android 不推就没有前台服务（BUG-3777 A）。
  final bool Function() _fullNotification;
  final VideoAudioFocus _focus;
  final DateTime Function() _now;

  /// 进程里正挂在会话上的那一个（视频页换集是新页面接旧页面：新的认领后，旧的
  /// 离场时 [release] 不能把新的卡片撤掉）。
  static VideoBackgroundMediaSession? _current;

  VideoMediaSessionTarget? _target;
  VideoMediaSessionInfo Function()? _info;
  FushiAudioHandler? _handler;
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  /// 每次 [engage] 一个新代号：handler 冷启动（`AudioService.init`）期间已经
  /// [release] / 被抢 / 重新 engage 的，回来的那次不再推。
  int _generation = 0;
  VideoMediaSessionSnapshot? _lastPushed;
  bool _resumeAfterInterruption = false;

  /// 视频此刻挂在系统媒体会话上（已认领、未让出、未被抢）。
  bool get engaged => _target != null;

  /// 认领系统媒体会话并挂上锁屏 / 通知卡：正在放的有声书 / 音乐被抢走、暂停
  /// （[AudioController.claimSession]）。已挂着时只更新卡片信息。
  ///
  /// [info] 每次推卡时现取（后台连播换了集，卡片跟着换标题）。
  Future<void> engage(
    VideoMediaSessionTarget target,
    VideoMediaSessionInfo Function() info,
  ) async {
    _info = info;
    if (identical(_target, target)) {
      refreshInfo();
      return;
    }
    _detach();
    final VideoBackgroundMediaSession? previous = _current;
    if (previous != null && !identical(previous, this)) previous._detach();
    _current = this;
    final int generation = ++_generation;
    _target = target;
    _lastPushed = null;
    _seat.onPreempted = _onPreempted;
    _seat.claim();
    target.addListener(_publish);
    _subs.addAll(<StreamSubscription<Object?>>[
      _controls.playIntents.listen(_onPlayIntent),
      _controls.seeks.listen(
        (Duration p) => unawaited(target.seekMs(p.inMilliseconds)),
      ),
      _controls.skipNext.listen(
        (_) => unawaited(target.skipCue(forward: true)),
      ),
      _controls.skipPrevious.listen(
        (_) => unawaited(target.skipCue(forward: false)),
      ),
      _controls.rewind.listen(
        (_) => unawaited(target.seekRelativeMs(-kVideoMediaSessionSeekStepMs)),
      ),
      _controls.fastForward.listen(
        (_) => unawaited(target.seekRelativeMs(kVideoMediaSessionSeekStepMs)),
      ),
      _focus.interruptions.listen(_onInterruption),
      _focus.becomingNoisy.listen((_) {
        // 耳机拔出 / 蓝牙断开：立即暂停，不外放。
        if (target.isPlaying) unawaited(target.pause());
      }),
    ]);
    // 申请音频焦点（Android）/ 激活播放类会话（iOS）：别的 app 在放会让出，来电等
    // 打断才会作为 [VideoAudioFocus.interruptions] 送到这里。失败不影响出声。
    try {
      await _focus.activate();
    } catch (e) {
      debugPrint('[Fushi] video media session focus failed (non-fatal): $e');
    }
    final FushiAudioHandler? handler = await _obtainHandler();
    if (generation != _generation || !identical(_target, target)) return;
    _handler = handler;
    _publish();
  }

  /// 卡片信息变了（如封面异步探测完）：已挂着时按最新信息重推一次卡片。
  void refreshInfo() {
    if (!engaged) return;
    _lastPushed = null;
    _publish();
  }

  /// 回到前台 / 离开视频页：让出会话、撤下通知卡（Android 随之结束前台服务）。
  /// 已被别人抢走时只拆自己的监听，不碰对方的卡。
  Future<void> release() async {
    if (!engaged) return;
    final FushiAudioHandler? handler = _handler;
    _detach();
    if (!identical(_current, this)) return;
    _current = null;
    if (!_seat.claimed) return;
    handler?.clearNotification();
    _seat.release();
  }

  void dispose() => unawaited(release());

  /// 会话被有声书 / 音乐抢走：视频暂停，拆掉自己的控制监听（锁屏卡已归对方）。
  void _onPreempted() {
    final VideoMediaSessionTarget? target = _target;
    _detach();
    if (identical(_current, this)) _current = null;
    if (target != null && target.isPlaying) unawaited(target.pause());
  }

  void _detach() {
    _generation++;
    _target?.removeListener(_publish);
    _target = null;
    _handler = null;
    _lastPushed = null;
    _resumeAfterInterruption = false;
    // 被抢回调按「谁」登记在同一个位子上：只有正挂着的那一个才注销，已被新页面接手
    // 的旧实例离场时不能把新实例的回调一并摘掉。
    if (identical(_current, this)) _seat.onPreempted = null;
    for (final StreamSubscription<Object?> s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
  }

  void _onPlayIntent(MediaPlayIntent intent) {
    final VideoMediaSessionTarget? target = _target;
    if (target == null) return;
    final bool play = switch (intent) {
      MediaPlayIntent.play => true,
      MediaPlayIntent.pause => false,
      MediaPlayIntent.toggle => !target.isPlaying,
    };
    // 用户在锁屏 / 耳机上亲手按过，打断结束时不再替他续播。
    _resumeAfterInterruption = false;
    unawaited(play ? target.play() : target.pause());
  }

  void _onInterruption(AudioInterruptionEvent event) {
    final VideoMediaSessionTarget? target = _target;
    if (target == null) return;
    if (event.begin) {
      switch (event.type) {
        case AudioInterruptionType.duck:
          // 被短暂压低（导航播报等）由系统降音量，不暂停。
          return;
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          if (target.isPlaying) {
            _resumeAfterInterruption =
                event.type == AudioInterruptionType.pause;
            unawaited(target.pause());
          }
      }
      return;
    }
    // 打断结束：只有系统表示可以恢复（暂时性打断，如来电挂断）才自动续播。
    if (event.type == AudioInterruptionType.pause && _resumeAfterInterruption) {
      unawaited(target.play());
    }
    _resumeAfterInterruption = false;
  }

  /// 把卡片与播放态推给 audio_service。挂在视频控制器的每次 notify 上：卡片内容由
  /// handler 去重（BUG-4507），播放态只在真变了时推（[videoMediaSessionNeedsPush]）。
  void _publish() {
    final VideoMediaSessionTarget? target = _target;
    final VideoMediaSessionInfo Function()? infoOf = _info;
    final FushiAudioHandler? handler = _handler;
    if (target == null || infoOf == null || handler == null) return;
    if (!_seat.claimed) return;
    final VideoMediaSessionInfo info = infoOf();
    final bool full = _fullNotification();
    final int? durationMs = target.durationMs;
    final Duration? duration = durationMs != null && durationMs > 0
        ? Duration(milliseconds: durationMs)
        : null;
    if (full) {
      handler.setMediaItemInfo(
        title: info.title,
        artist: info.subtitle,
        duration: duration,
        artUri: info.artUri,
      );
    } else {
      handler.setMinimalMediaItem(title: info.title);
    }
    final VideoMediaSessionSnapshot next = (
      playing: target.isPlaying,
      positionMs: target.positionMs,
      speed: target.speed,
      full: full,
      at: _now(),
    );
    if (!videoMediaSessionNeedsPush(_lastPushed, next)) return;
    _lastPushed = next;
    handler.updatePlaybackState(
      playing: next.playing,
      position: Duration(milliseconds: next.positionMs),
      speed: next.speed,
      duration: duration ?? Duration.zero,
      minimal: !full,
      floatingLyricControl: false,
    );
  }
}

/// 锁屏「快退 / 快进」一步的长度，与 audio_service 配置的 rewind / fastForward
/// 间隔（[AudioController.initialiseHandler]）一致。
const int kVideoMediaSessionSeekStepMs = 5000;

/// 系统按「位置 + 速度 + 时刻」自己外推进度条，推一次够用；位置与外推值差出这么多
/// （拖动 / 跳句 / 缓冲卡顿）才重推。
const int kVideoMediaSessionDriftToleranceMs = 1500;

/// 上一次推给系统的播放态。
typedef VideoMediaSessionSnapshot = ({
  bool playing,
  int positionMs,
  double speed,
  bool full,
  DateTime at,
});

/// 这一拍要不要重推播放态（纯函数，供单测直接验证）：首次、播放 / 暂停翻转、倍速
/// 变化、通知形态变化，或位置偏离系统外推值超过 [kVideoMediaSessionDriftToleranceMs]。
/// 视频控制器每个进度 tick 都 notify，逐拍都推会让 Android 端反复重建通知。
bool videoMediaSessionNeedsPush(
  VideoMediaSessionSnapshot? last,
  VideoMediaSessionSnapshot next,
) {
  if (last == null) return true;
  if (last.playing != next.playing ||
      last.speed != next.speed ||
      last.full != next.full) {
    return true;
  }
  final int elapsedMs = next.at.difference(last.at).inMilliseconds;
  final int expectedMs = last.playing
      ? last.positionMs + (elapsedMs * last.speed).round()
      : last.positionMs;
  return (next.positionMs - expectedMs).abs() >
      kVideoMediaSessionDriftToleranceMs;
}

/// 锁屏卡上显示的内容。
@immutable
class VideoMediaSessionInfo {
  const VideoMediaSessionInfo({
    required this.title,
    this.subtitle,
    this.artUri,
  });

  /// 卡片标题（当前这一集）。
  final String title;

  /// 副标题（作品名；与标题相同时调用方传 null）。
  final String? subtitle;

  /// 封面（本机文件）。
  final Uri? artUri;
}

/// 系统媒体控件要操作的那台视频播放器。
abstract interface class VideoMediaSessionTarget implements Listenable {
  bool get isPlaying;
  int get positionMs;
  int? get durationMs;
  double get speed;
  Future<void> play();
  Future<void> pause();
  Future<void> seekMs(int positionMs);
  Future<void> seekRelativeMs(int deltaMs);

  /// 上 / 下一句（无字幕时按秒跳，与视频页底栏同名按钮同一条）。
  Future<void> skipCue({required bool forward});
}

/// [VideoPlayerController] 接到系统媒体控件上。
class VideoControllerMediaSessionTarget implements VideoMediaSessionTarget {
  VideoControllerMediaSessionTarget(
    this._controller, {
    required int Function() skipSeekSeconds,
  }) : _skipSeekSeconds = skipSeekSeconds;

  final VideoPlayerController _controller;
  final int Function() _skipSeekSeconds;

  @override
  void addListener(VoidCallback listener) => _controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _controller.removeListener(listener);

  @override
  bool get isPlaying => _controller.isPlaying;

  @override
  int get positionMs => _controller.positionMs ?? 0;

  @override
  int? get durationMs => _controller.durationMs;

  @override
  double get speed => _controller.speed;

  /// 锁屏 / 耳机的「播放」是续上暂停前那段：已自然播完时不从头重播（同
  /// [VideoPlayerController.resumePlayback]）。
  @override
  Future<void> play() => _controller.resumePlayback();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> seekMs(int positionMs) => _controller.seekMs(positionMs);

  @override
  Future<void> seekRelativeMs(int deltaMs) => _controller.seekRelative(deltaMs);

  @override
  Future<void> skipCue({required bool forward}) => forward
      ? _controller.skipToNextCueOrSeekForward(seekSeconds: _skipSeekSeconds())
      : _controller.skipToPrevCueOrSeekBack(seekSeconds: _skipSeekSeconds());
}

/// 系统媒体控件发来的命令里视频要听的那几路（只在视频持有会话时放行）。
@immutable
class VideoMediaSessionControls {
  const VideoMediaSessionControls({
    required this.playIntents,
    required this.seeks,
    required this.skipNext,
    required this.skipPrevious,
    required this.rewind,
    required this.fastForward,
  });

  /// 从 [AudioController] 的意图流里取视频那一份（[MediaSessionOwner.video]）。
  factory VideoMediaSessionControls.of(AudioController audio) =>
      VideoMediaSessionControls(
        playIntents: audio.streamFor(
          audio.playIntentStream,
          MediaSessionOwner.video,
        ),
        seeks: audio.streamFor(audio.seekStream, MediaSessionOwner.video),
        skipNext: audio.streamFor(
          audio.skipNextStream,
          MediaSessionOwner.video,
        ),
        skipPrevious: audio.streamFor(
          audio.skipPreviousStream,
          MediaSessionOwner.video,
        ),
        rewind: audio.streamFor(audio.rewindStream, MediaSessionOwner.video),
        fastForward: audio.streamFor(
          audio.fastForwardStream,
          MediaSessionOwner.video,
        ),
      );

  final Stream<MediaPlayIntent> playIntents;
  final Stream<Duration> seeks;
  final Stream<void> skipNext;
  final Stream<void> skipPrevious;
  final Stream<void> rewind;
  final Stream<void> fastForward;
}

/// 音频焦点 / 系统音频会话（来电等打断、耳机拔出）。
abstract interface class VideoAudioFocus {
  /// 配置成「影片播放」并激活（Android 申请音频焦点）。
  Future<void> activate();
  Stream<AudioInterruptionEvent> get interruptions;
  Stream<void> get becomingNoisy;
}

/// 真实系统音频会话（audio_session 插件）。只在移动端被用到（后台继续放声音只对
/// 手机 / 平板有意义）。
class SystemVideoAudioFocus implements VideoAudioFocus {
  @override
  Future<void> activate() async {
    final AudioSession session = await AudioSession.instance;
    await session.configure(
      const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.none,
        avAudioSessionMode: AVAudioSessionMode.moviePlayback,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.longFormVideo,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.movie,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ),
    );
    await session.setActive(true);
  }

  @override
  Stream<AudioInterruptionEvent> get interruptions =>
      _sessionStream((AudioSession s) => s.interruptionEventStream);

  @override
  Stream<void> get becomingNoisy =>
      _sessionStream((AudioSession s) => s.becomingNoisyEventStream);

  /// 插件只在 Android / iOS 有实现；其余平台给空流（不会走到这里，兜底防误用）。
  static Stream<T> _sessionStream<T>(Stream<T> Function(AudioSession) pick) {
    if (!(Platform.isAndroid || Platform.isIOS)) return Stream<T>.empty();
    return Stream<AudioSession>.fromFuture(
      AudioSession.instance,
    ).asyncExpand(pick);
  }
}
