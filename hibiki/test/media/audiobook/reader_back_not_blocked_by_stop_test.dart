import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// BUG-1273：有声书播放中按返回（手势侧滑 / 返回键 / ESC）无反应，等音频真停下来
/// 那一刻才连着止声一起退出书。
///
/// 根因：阅读器退出链是全程 await 的串行链
/// `PopScope.onPopInvokedWithResult` → `onWillPop` → `onSourcePagePop`
/// → **`await appModel.audiobookSession.stop()`** → `closeMedia` → `nav.pop()`，
/// 而 `stop()` 的 await 段是「停 native 播放器 + 销毁解码器」
/// （`stopPlayback` → just_audio `_setPlatformActive(false)` 拆平台，随后
/// `disposeAndRelease` 再 await 一次 `_player.dispose()`）：耗时不可控，且**只有
/// 播放态才真正干活**（暂停态几乎瞬时返回，所以用户只在播放时遇到）。外层还有
/// `_popInProgress` 单飞门——第一次返回把门顶住后，**后续每次返回都被静默丢弃**。
///
/// 修复：退出路径改 `unawaited(stop())`。会话可见状态（书架 NowListeningMiniBar
/// 读的 `isActive` / `book`）在 `_stopInternal` 的首段（第一个 await 之前）就归零并
/// 通知——只隔一个微任务，远早于 pop 动画首帧，TODO-831 的「不闪播放条」不受影响；
/// native 资源释放与「用户已经离开这一页」没有因果关系。
///
/// 本文件是**行为层**证据：native 释放挂起时，`stop()` 返回的 Future **不完成**
/// （证明 await 它就会把用户的返回吞掉），但会话已清空并通知监听者
/// （证明 fire-and-forget 不丢 TODO-831 的「不闪播放条」）。
/// 对应的**源码层**守卫（`onSourcePagePop` 必须 unawaited、不得 await）在
/// `audiobook_exit_stop_policy_static_test.dart` —— 那里是这条退出链契约的真相源。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Audiobook ab(String key) => Audiobook()
    ..bookKey = key
    ..audioPaths = const <String>[]
    ..audioRoot = null
    ..alignmentFormat = 'srt'
    ..alignmentPath = '';

  File makeFile(String name) {
    final File f = File('${Directory.systemTemp.path}/$name');
    if (!f.existsSync()) f.writeAsBytesSync(const <int>[0]);
    addTearDown(() {
      if (f.existsSync()) f.deleteSync();
    });
    return f;
  }

  AudiobookSession makeSession() {
    return AudiobookSession(
      audioHandler: () => null,
      showFloatingLyric: () => false,
      showMediaNotification: () => false,
      floatingLyricContextLines: () => 0,
      floatingLyricStyle: () => const FloatingLyricStyle(
        fontSize: 16,
        textColor: 0,
        bgColor: 0,
        buttonTextColor: 0,
        buttonBgColor: 0,
        highlightColor: 0,
        activeColor: 0,
      ),
      floatingLyricClickLookup: () => false,
      onFloatingLyricLookup: (_, __) {},
      controlStreams: AudioControlStreams(
        playStream: const Stream<void>.empty(),
        seekStream: const Stream<Duration>.empty(),
        skipNextStream: const Stream<void>.empty(),
        skipPreviousStream: const Stream<void>.empty(),
        toggleFloatingLyricStream: const Stream<void>.empty(),
      ),
    );
  }

  setUp(() {
    FloatingLyricChannel.platformOverride = false;
  });
  tearDown(() {
    FloatingLyricChannel.platformOverride = null;
  });

  group('AudiobookSession.stop 的会话归零契约 (BUG-1273)', () {
    test('native 释放挂起时 stop() 不完成，但会话已清空并通知', () async {
      const MethodChannel sessionChannel =
          MethodChannel('com.ryanheise.audio_session');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sessionChannel, (_) async => null);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(sessionChannel, null);
      });

      // 模拟「播放中释放 native 解码器很慢 / 挂住」：disposePlayer 挂在 completer 上。
      final Completer<void> releaseGate = Completer<void>();
      final JustAudioPlatform prev = JustAudioPlatform.instance;
      final _StallingReleasePlatform platform =
          _StallingReleasePlatform(releaseGate);
      JustAudioPlatform.instance = platform;
      addTearDown(() {
        if (!releaseGate.isCompleted) releaseGate.complete();
        JustAudioPlatform.instance = prev;
      });

      final AudiobookSession session = makeSession();
      await session.start(
        info: SessionBookInfo(
          bookKey: 'b1',
          audiobook: ab('b1'),
          title: 'Book b1',
          mediaIdentifier: 'hoshi://book/b1',
        ),
        audioFiles: <File>[makeFile('hibiki-back-stop-b1.mp3')],
        prefs: const SessionPrefs(
          followAudio: true,
          delayMs: 0,
          speed: 1.0,
          positionMs: 0,
          imagePauseSec: 0,
          volume: 1.0,
        ),
        persist: SessionPersistCallbacks(
          onPositionWrite: (_, __) async {},
          onDelayPersist: (_) async {},
          onSpeedPersist: (_) async {},
          onVolumePersist: (_) async {},
          onImagePausePersist: (_) async {},
          onFollowAudioPersist: (_) async {},
        ),
      );
      expect(session.isActive, isTrue, reason: 'precondition: 会话应持有控制器');

      // 关键前置：**播放中**。play() 才真正激活 native 平台（创建 native player），
      // 停止时才有解码器要释放——这正是 BUG-1273 只在播放态出现、暂停态没事的原因。
      final AudiobookPlayerController controller = session.controller!;
      await controller.play();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.debugMainPlayerPlaying, isTrue,
          reason: 'precondition: 播放器应处于播放态');
      expect(platform.players, isNotEmpty,
          reason: 'precondition: play 应激活 native 平台（创建 player）');

      int notifications = 0;
      void listener() => notifications++;
      session.addListener(listener);
      addTearDown(() => session.removeListener(listener));

      // 退出书：阅读器路径 fire-and-forget 调 stop（不 await）。
      bool stopped = false;
      final Future<void> stopping = session.stop();
      unawaited(stopping.then((_) => stopped = true));

      // stop() 走 _enqueueLifecycle，_stopInternal 的首段（第一个 await 之前）清空
      // 会话并通知——只隔一个微任务，远早于 pop 动画首帧，书架 NowListeningMiniBar
      // 照样从首帧就见空会话（TODO-831 不闪播放条）。
      await Future<void>.delayed(Duration.zero);
      expect(session.isActive, isFalse,
          reason: '_stopInternal 首段必须清空会话（不能等 native 释放完成）');
      expect(session.controller, isNull);
      expect(session.book, isNull);
      expect(notifications, greaterThanOrEqualTo(1),
          reason: '_stopInternal 首段必须 notifyListeners，让书架立刻收起播放条');

      // 而 stop() 本身仍挂在 native 释放上——旧实现 `await` 它，等于把用户的返回
      // 一起挂住（并被 _popInProgress 吞掉后续每一次返回），正是 BUG-1273 的症状。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(stopped, isFalse,
          reason: 'native 释放未完成时 stop() 不应完成——退出路径绝不能 await 它');

      // 放行后 stop 正常收尾（fire-and-forget 不丢释放语义）。
      releaseGate.complete();
      await stopping.timeout(const Duration(seconds: 5));
      expect(stopped, isTrue);
      session.dispose();
    });
  });
}

/// native 释放（`disposePlayer` / `disposeAllPlayers`）挂在外部 gate 上的假平台：
/// 复现「播放中停播放器很慢 / 挂住」。其余调用即时完成。
class _StallingReleasePlatform extends JustAudioPlatform {
  _StallingReleasePlatform(this._releaseGate);

  final Completer<void> _releaseGate;
  final List<_StallingPlayer> players = <_StallingPlayer>[];

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final _StallingPlayer player = _StallingPlayer(request.id);
    players.add(player);
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async {
    await _releaseGate.future;
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
    DisposeAllPlayersRequest request,
  ) async {
    await _releaseGate.future;
    return DisposeAllPlayersResponse();
  }
}

class _StallingPlayer extends AudioPlayerPlatform {
  _StallingPlayer(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  bool _disposed = false;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  void _emit(int ms, {required bool playing}) {
    if (_disposed) return;
    _events.add(PlaybackEventMessage(
      processingState: ProcessingStateMessage.ready,
      updateTime: DateTime.now(),
      updatePosition: Duration(milliseconds: ms),
      bufferedPosition: Duration(milliseconds: ms),
      duration: const Duration(seconds: 10),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _emit(request.initialPosition?.inMilliseconds ?? 0, playing: false);
    return LoadResponse(duration: const Duration(seconds: 10));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _emit(0, playing: true);
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _emit(0, playing: false);
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _emit(request.position?.inMilliseconds ?? 0, playing: false);
    return SeekResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
    SetAndroidAudioAttributesRequest request,
  ) async =>
      SetAndroidAudioAttributesResponse();

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
    SetAutomaticallyWaitsToMinimizeStallingRequest request,
  ) async =>
          SetAutomaticallyWaitsToMinimizeStallingResponse();

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
    SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request,
  ) async =>
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
    SetPreferredPeakBitRateRequest request,
  ) async =>
      SetPreferredPeakBitRateResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async =>
      SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
    SetShuffleOrderRequest request,
  ) async =>
      SetShuffleOrderResponse();

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
    SetSkipSilenceRequest request,
  ) async =>
      SetSkipSilenceResponse();

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();

  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
    SetWebCrossOriginRequest request,
  ) async =>
      SetWebCrossOriginResponse();

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    if (_disposed) return DisposeResponse();
    _disposed = true;
    await _events.close();
    return DisposeResponse();
  }
}
