import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// 「播放中退出有声书 → 音频永不停止，且无法手动关闭」的回归测试。
///
/// 根因是一条**后端语义差异**，而此前全部有声书测试的假播放器都只模拟了 media_kit
/// 语义（`play()` 立刻返回），所以零覆盖：
///
/// * **media_kit**（Windows / Linux，经 just_audio_media_kit）：`play()` 在平台
///   接受播放请求时就完成。
/// * **just_audio 原生 Darwin**（macOS / iOS 的 AVQueuePlayer）与 **Android**
///   （ExoPlayer）：`play` 的平台回调被**挂起到 pause / complete / stop 才触发**。
///   见 `just_audio/darwin/Classes/AudioPlayer.m` 的 `_playResult`——`play:` 只把
///   `FlutterResult` 存进 `_playResult`，由 `pause`（"PLAY FINISHED DUE TO PAUSE"）、
///   `complete`、`stop`（"PLAY FINISHED DUE TO STOP"）三处释放。
///
/// 旧实现的 `_stopPlaybackOnce()` 第一步是 `await _playActivationTail`（挂着
/// `_player.play()` 返回的 Future）。在后两种后端上，播放中调 `stopPlayback()` 就是
/// **循环等待**：stop 等 play 完成，而唯一能让 play 完成的正是 stop 自己。后果是
/// `_player.stop()` 永不执行、音频一路播到整本结束；而 `AudiobookSession._stopInternal`
/// 已经同步清空 `_book`/`_controller` 并 notify，播放条随之消失、controller 沦为孤儿
/// ——用户除杀进程外没有任何停止入口。
///
/// 注意 `JustAudioMediaKit.ensureInitialized()` 的 `macOS` 形参默认 **false**
/// （`fushi/lib/main.dart` 未传），所以 macOS 走的就是原生 Darwin 后端。
///
/// 每条断言都带 `timeout`：死锁的表现是**永不返回**，没有超时就会把整个 suite 挂死
/// （而不是给出一条清晰的红）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Audiobook ab() => Audiobook()
    ..bookKey = 'book'
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

  _DarwinPlatform installPlatform() {
    const MethodChannel ch = MethodChannel('com.ryanheise.audio_session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
    });
    final JustAudioPlatform prev = JustAudioPlatform.instance;
    final _DarwinPlatform p = _DarwinPlatform();
    JustAudioPlatform.instance = p;
    addTearDown(() => JustAudioPlatform.instance = prev);
    return p;
  }

  test(
    'stopPlayback completes while playing on a Darwin-semantics backend',
    () async {
      final _DarwinPlatform plat = installPlatform();
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);

      await c.load(
        audiobook: ab(),
        audioFiles: <File>[makeFile('fushi-darwin-stop-deadlock.mp3')],
        initialPositionMs: 65000,
      );
      c.onPositionWrite = (String uid, int ms) async {};

      // fire-and-forget，与生产一致（play 的 Future 在 Darwin 上播放期间不会完成）。
      unawaited(c.play());
      await Future<void>.delayed(Duration.zero);
      expect(plat.player!.playCalls, 1);
      expect(plat.player!.playPending, isTrue,
          reason: '前提：这个假播放器必须复现 Darwin 的「play 挂起」语义');

      await c.stopPlayback();

      expect(plat.player!.stopCalls, greaterThan(0),
          reason: 'stopPlayback 必须真的把平台 stop 发下去，而不是卡在等 play');
      expect(plat.player!.playPending, isFalse,
          reason: 'stop 应当成为解开挂起 play 的那一方');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'stopPlayback persists the pre-stop position on a Darwin-semantics backend',
    () async {
      installPlatform();
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);

      await c.load(
        audiobook: ab(),
        audioFiles: <File>[makeFile('fushi-darwin-stop-position.mp3')],
        initialPositionMs: 65000,
      );
      final List<int> writes = <int>[];
      c.onPositionWrite = (String uid, int ms) async => writes.add(ms);

      unawaited(c.play());
      await Future<void>.delayed(Duration.zero);
      await c.stopPlayback();

      expect(writes, isNotEmpty, reason: 'BUG-1240：停止路径必须落一次位置');
      expect(writes.last, greaterThanOrEqualTo(65000),
          reason: 'stop 会把 position 归零，落库的必须是 stop **之前**采到的位置');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}

class _DarwinPlatform extends JustAudioPlatform {
  _DarwinPlayer? player;
  int disposePlayerCalls = 0;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    player = _DarwinPlayer(request.id);
    return player!;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    disposePlayerCalls++;
    await player?.dispose(DisposeRequest());
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    await player?.dispose(DisposeRequest());
    return DisposeAllPlayersResponse();
  }
}

/// 复现 `just_audio/darwin/Classes/AudioPlayer.m` 的 `_playResult` 语义：`play` 的
/// 结果被**存起来**，只有 `pause` / `stop` / `dispose`（播完）才释放它。
class _DarwinPlayer extends AudioPlayerPlatform {
  _DarwinPlayer(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  bool _disposed = false;

  Completer<PlayResponse>? _playResult;
  int playCalls = 0;
  int stopCalls = 0;
  int pauseCalls = 0;

  bool get playPending => !(_playResult?.isCompleted ?? true);

  void _releasePlayResult() {
    final Completer<PlayResponse>? pending = _playResult;
    if (pending != null && !pending.isCompleted) {
      pending.complete(PlayResponse());
    }
    _playResult = null;
  }

  void emit(int ms, ProcessingStateMessage state, {required bool playing}) {
    if (_events.isClosed) return;
    _events.add(PlaybackEventMessage(
      processingState: state,
      updateTime: DateTime.now(),
      updatePosition: Duration(milliseconds: ms),
      bufferedPosition: Duration(milliseconds: ms),
      duration: const Duration(seconds: 100),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    emit(request.initialPosition?.inMilliseconds ?? 0,
        ProcessingStateMessage.ready,
        playing: false);
    return LoadResponse(duration: const Duration(seconds: 100));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) {
    playCalls++;
    // AudioPlayer.m:1019-1032 —— 已在播放则立即返回；否则把结果挂起。
    final Completer<PlayResponse> pending = Completer<PlayResponse>();
    _playResult = pending;
    return pending.future;
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    pauseCalls++;
    _releasePlayResult(); // "PLAY FINISHED DUE TO PAUSE"
    return PauseResponse();
  }

  // just_audio 的 AudioPlayer.stop() 走平台 dispose/stop 路径；这里两处都释放，
  // 与 native "PLAY FINISHED DUE TO STOP" 对齐。
  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    stopCalls++;
    _releasePlayResult();
    if (_disposed) return DisposeResponse();
    _disposed = true;
    await _events.close();
    return DisposeResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    emit(request.position?.inMilliseconds ?? 0, ProcessingStateMessage.ready,
        playing: false);
    return SeekResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();
  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
              SetAutomaticallyWaitsToMinimizeStallingRequest request) async =>
          SetAutomaticallyWaitsToMinimizeStallingResponse();
  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
              SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest
                  request) async =>
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();
  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();
  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
          SetPreferredPeakBitRateRequest request) async =>
      SetPreferredPeakBitRateResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();
  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();
  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
          SetSkipSilenceRequest request) async =>
      SetSkipSilenceResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();
  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
          SetWebCrossOriginRequest request) async =>
      SetWebCrossOriginResponse();
}
