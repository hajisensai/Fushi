import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// BUG-278 / TODO-367：退出阅读 / 停止会话后有声书仍在播放。
///
/// 根因：[AudiobookSession.stop] 在 dispose 控制器前只 `pause()`（just_audio 语义
/// 「保留解码器以便快速恢复」，不释放 native 资源），紧随的同步 `dispose()` 抢不过
/// 异步的平台拆除，Android(ExoPlayer) 上表现为停止后音频仍在响。
///
/// 修复：控制器新增可 await 的 [AudiobookPlayerController.stopPlayback]（真正 stop
/// 主播放器与 clip 播放器、释放解码器、force-flush 位置），[AudiobookSession.stop]
/// 改为 `await controller.stopPlayback()` 再 `dispose()`。
///
/// 行为层断言（just_audio 公开播放态）：stopPlayback 把正在播放的主播放器停下。
/// 撤掉 stopPlayback 里的 `_player.stop()`（退回只 pause / 不停）则播放器仍 playing
/// → 红。另加源码守卫钉住 session.stop 用的是 stopPlayback 而非裸 pause。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudiobookPlayerController.stopPlayback (BUG-278)', () {
    test('releases the native player (stop), not just pause', () async {
      final _FakeJustAudioPlatform plat = _installFakeAudioPlatform();

      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);
      final File audioFile = _tempAudio('hibiki-audiobook-exit-stop.mp3');
      addTearDown(() {
        if (audioFile.existsSync()) audioFile.deleteSync();
      });

      await controller.load(
        audiobook: _audiobook(),
        audioFiles: <File>[audioFile],
      );

      // play() 激活 native 平台并把 playing=true（控制器内 play 是 unawaited，
      // 故让微任务/事件循环把 _setPlatformActive(true) → init 跑完）。
      await controller.play();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        controller.debugMainPlayerPlaying,
        isTrue,
        reason: 'precondition: 播放器应处于播放态',
      );
      expect(plat.players, isNotEmpty,
          reason: 'precondition: play 应激活 native 平台（创建 player）');

      // 基线：stop 之前的 native 释放次数（激活过程本身会切换 idle↔native）。
      final int disposeBefore = plat.disposePlayerCalls;
      await controller.stopPlayback();

      expect(
        controller.debugMainPlayerPlaying,
        isFalse,
        reason: '停止会话后主播放器不应在播放',
      );
      // 关键区分：stop() 走 _setPlatformActive(false) 释放当前 native 解码器
      // （触发一次 disposePlayer）；只 pause() 则保留解码器（计数不增），Android 上
      // 仍占输出 / 可秒续 → 用户感知「退出后还在响」。断言 stop 期间释放次数 +1，
      // 把「真停止/释放」钉死，挡住退回 pause 的回归。
      expect(plat.disposePlayerCalls, greaterThan(disposeBefore),
          reason: '停止会话必须释放 native 解码器（stop→disposePlayer 计数增加），'
              '不能只 pause（解码器存活、停止后仍在响）');
    });

    test('stopPlayback then dispose does not crash (no platform race)',
        () async {
      _installFakeAudioPlatform();

      final AudiobookPlayerController controller = AudiobookPlayerController();
      final File audioFile = _tempAudio('hibiki-audiobook-exit-dispose.mp3');
      addTearDown(() {
        if (audioFile.existsSync()) audioFile.deleteSync();
      });

      await controller.load(
        audiobook: _audiobook(),
        audioFiles: <File>[audioFile],
      );
      await controller.play();
      expect(controller.debugMainPlayerPlaying, isTrue);

      // 退出/停止路径：先 await stop 让平台切换 settle，再 dispose（不竞争）。
      await controller.stopPlayback();
      controller.dispose();

      await Future<void>.delayed(Duration.zero);
    });
  });

  group('AudiobookSession.stop source guard (BUG-278)', () {
    test('stop() releases the controller via stopPlayback() before dispose()',
        () {
      final File sessionFile = File(
        '${Directory.current.path}/lib/src/media/audiobook/audiobook_session.dart',
      );
      expect(sessionFile.existsSync(), isTrue,
          reason: 'audiobook_session.dart 应存在于预期路径');
      final String source = sessionFile.readAsStringSync();

      final int stopIdx = source.indexOf('Future<void> stop() async {');
      expect(stopIdx, greaterThanOrEqualTo(0),
          reason: 'AudiobookSession 应有 stop() 方法');
      // 取 stop() 方法体（到下一个顶层方法注释前）做局部断言。
      final String stopBody =
          source.substring(stopIdx, (stopIdx + 1500).clamp(0, source.length));

      expect(stopBody.contains('controller.stopPlayback()'), isTrue,
          reason: 'stop() 必须调 controller.stopPlayback() 真正止声/释放解码器');
      // 守卫回归：不得退回到只 pause（pause 不释放 native，停止后仍在响）。
      expect(stopBody.contains('await controller.pause()'), isFalse,
          reason: 'stop() 不应只 controller.pause()（pause 不释放 native 资源）');
    });
  });
}

File _tempAudio(String name) {
  final File audioFile = File('${Directory.systemTemp.path}/$name');
  if (!audioFile.existsSync()) {
    audioFile.writeAsBytesSync(const <int>[0]);
  }
  return audioFile;
}

Audiobook _audiobook() {
  return Audiobook()
    ..bookKey = 'book'
    ..audioPaths = const <String>[]
    ..audioRoot = null
    ..alignmentFormat = 'srt'
    ..alignmentPath = '';
}

_FakeJustAudioPlatform _installFakeAudioPlatform() {
  const MethodChannel audioSessionChannel =
      MethodChannel('com.ryanheise.audio_session');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(audioSessionChannel, (_) async => null);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, null);
  });

  final JustAudioPlatform previousPlatform = JustAudioPlatform.instance;
  final _FakeJustAudioPlatform platform = _FakeJustAudioPlatform();
  JustAudioPlatform.instance = platform;
  addTearDown(() {
    JustAudioPlatform.instance = previousPlatform;
  });
  return platform;
}

class _FakeJustAudioPlatform extends JustAudioPlatform {
  final List<_FakeAudioPlayer> players = <_FakeAudioPlayer>[];

  /// just_audio 释放某个 player 平台时的调用计数。`stop()` 切到 idle 平台会先
  /// `disposePlayer(native)`，是「真释放 native 解码器」的可观测信号；`pause()`
  /// 不触发。
  int disposePlayerCalls = 0;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final _FakeAudioPlayer player = _FakeAudioPlayer(request.id);
    players.add(player);
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async {
    disposePlayerCalls++;
    for (final _FakeAudioPlayer p in players) {
      if (p.id == request.id) {
        await p.dispose(DisposeRequest());
      }
    }
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
    DisposeAllPlayersRequest request,
  ) async {
    disposePlayerCalls++;
    for (final _FakeAudioPlayer p in players) {
      await p.dispose(DisposeRequest());
    }
    return DisposeAllPlayersResponse();
  }
}

/// 立即完成 load/seek（不挂起），让 play() 能真正激活并保持 playing 状态。
class _FakeAudioPlayer extends AudioPlayerPlatform {
  _FakeAudioPlayer(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  bool _disposed = false;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  void _emit(int ms, ProcessingStateMessage state, {required bool playing}) {
    if (_disposed) return;
    _events.add(PlaybackEventMessage(
      processingState: state,
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
    // 源就绪后处于 ready（解码器存活）：pause 维持 ready，stop 切到 idle 平台。
    _emit(request.initialPosition?.inMilliseconds ?? 0,
        ProcessingStateMessage.ready,
        playing: false);
    return LoadResponse(duration: const Duration(seconds: 10));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _emit(0, ProcessingStateMessage.ready, playing: true);
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _emit(0, ProcessingStateMessage.ready, playing: false);
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _emit(request.position?.inMilliseconds ?? 0, ProcessingStateMessage.ready,
        playing: false);
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
