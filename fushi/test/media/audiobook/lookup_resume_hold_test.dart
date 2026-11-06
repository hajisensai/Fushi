import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/lookup_resume_hold.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// 查词暂停 → 关弹窗恢复 → 起播 → 用户暂停：阅读器 `_lookupResumeInFlight`
/// （喂 `playbackHeldForLookup`）的撤销时机，跑在真 [AudiobookPlayerController] +
/// 复现 just_audio 原生 Darwin / Android「play 挂到 pause 才回」语义的假平台上。
///
/// 旧实现在 `ctrl.play().whenComplete` 里撤掉按住；在这类后端上 `play()` 要到下一次
/// 暂停才完成，于是恢复后的整段正常播放都被记成「被查词按住」。这里断言按住在播放器
/// 真正起播时就撤掉，而那一刻 `play()` 的 Future 确实还挂着。
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

  Future<AudiobookPlayerController> loaded(String file) async {
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);
    await c.load(audiobook: ab(), audioFiles: <File>[makeFile(file)]);
    c.onPositionWrite = (String uid, int ms) async {};
    return c;
  }

  Future<void> settleUntil(bool Function() done) async {
    for (int i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'hold releases when playback actually starts, while play() is still pending',
    () async {
      final _DarwinPlatform plat = installPlatform();
      final AudiobookPlayerController c = await loaded(
        'fushi-lookup-resume-hold.mp3',
      );

      // 正在听书。
      unawaited(c.play());
      await settleUntil(() => c.isPlaying);
      expect(c.isPlaying, isTrue, reason: '前提：已在播放');

      // 查词暂停（lookup.part.dart 的弹窗路径：isPlaying 时 pause）。
      await c.pause();
      expect(c.isPlaying, isFalse);

      // 关弹窗恢复：与 _clearLookupState 同一调用形状。
      bool resumeSettled = false;
      final Future<void> resume = c.play();
      unawaited(
        resume.then<void>(
          (_) => resumeSettled = true,
          onError: (Object _, StackTrace __) => resumeSettled = true,
        ),
      );
      bool held = true;
      unawaited(
        lookupResumeHoldReleased(
          playback: c,
          isPlaying: () => c.isPlaying,
          resume: resume,
        ).then((_) => held = false),
      );
      // 激活链（等载入 → 串行尾 → 平台 play）全是异步的：调用返回这一刻还没起播。
      expect(c.isPlaying, isFalse);
      expect(held, isTrue, reason: '激活在途、还没起播：仍算查词按住');

      await settleUntil(() => c.isPlaying);
      await Future<void>.delayed(Duration.zero);
      expect(c.isPlaying, isTrue);
      expect(
        plat.player!.playPending,
        isTrue,
        reason: '前提：Darwin / Android 语义下 play 结果挂到下次暂停',
      );
      expect(
        resumeSettled,
        isFalse,
        reason: '前提：play() 的 Future 此刻没完成——等它就会整段播放都算按住',
      );
      expect(held, isFalse, reason: '播放器起播即撤掉按住，恢复后的正常播放不再算查词按住');

      // 用户暂停：play() 这才完成；按住早已撤掉，不受影响。
      await c.pause();
      await settleUntil(() => resumeSettled);
      expect(resumeSettled, isTrue);
      expect(held, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'hold releases when the resume never starts playback (stop requested)',
    () async {
      installPlatform();
      final AudiobookPlayerController c = await loaded(
        'fushi-lookup-resume-hold-stopped.mp3',
      );
      // 会话已在停止：play() 直接返回、不会起播。
      await c.stopPlayback();

      bool held = true;
      final Future<void> resume = c.play();
      unawaited(
        lookupResumeHoldReleased(
          playback: c,
          isPlaying: () => c.isPlaying,
          resume: resume,
        ).then((_) => held = false),
      );
      await settleUntil(() => !held);
      expect(c.isPlaying, isFalse);
      expect(held, isFalse, reason: '不会起播的恢复不能让按住悬着');
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
    DisposePlayerRequest request,
  ) async {
    disposePlayerCalls++;
    await player?.dispose(DisposeRequest());
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
    DisposeAllPlayersRequest request,
  ) async {
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
    _events.add(
      PlaybackEventMessage(
        processingState: state,
        updateTime: DateTime.now(),
        updatePosition: Duration(milliseconds: ms),
        bufferedPosition: Duration(milliseconds: ms),
        duration: const Duration(seconds: 100),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    emit(
      request.initialPosition?.inMilliseconds ?? 0,
      ProcessingStateMessage.ready,
      playing: false,
    );
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
    emit(
      request.position?.inMilliseconds ?? 0,
      ProcessingStateMessage.ready,
      playing: false,
    );
    return SeekResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
    SetAndroidAudioAttributesRequest request,
  ) async => SetAndroidAudioAttributesResponse();
  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
  setAutomaticallyWaitsToMinimizeStalling(
    SetAutomaticallyWaitsToMinimizeStallingRequest request,
  ) async => SetAutomaticallyWaitsToMinimizeStallingResponse();
  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
  setCanUseNetworkResourcesForLiveStreamingWhilePaused(
    SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request,
  ) async => SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();
  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();
  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
    SetPreferredPeakBitRateRequest request,
  ) async => SetPreferredPeakBitRateResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async => SetShuffleModeResponse();
  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
    SetShuffleOrderRequest request,
  ) async => SetShuffleOrderResponse();
  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
    SetSkipSilenceRequest request,
  ) async => SetSkipSilenceResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();
  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
    SetWebCrossOriginRequest request,
  ) async => SetWebCrossOriginResponse();
}
