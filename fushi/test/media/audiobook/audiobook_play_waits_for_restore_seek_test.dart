import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// BUG-3430：开书慢时用户按播放早于「恢复上次播放位置」落定。旧实现 `play()`
/// 不等载入：just_audio 先记下播放请求，随后 `setAudioSource` 按**当时位置 0**
/// 激活平台并起播，恢复 seek 之后才跟上——当前句先跳到全书第一句（Windows 歌词
/// 模式里看到的「小学館」那句），再跳回。
///
/// 把载入卡在音频会话配置（真实载入里最先的慢步），此时调用
/// [AudiobookPlayerController.play]，断言平台的 play 请求只在载入（含恢复 seek）
/// 完成后发出，且发出时位置已是恢复点。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'play() issued during the restore load starts only after it lands',
    () async {
      const MethodChannel session = MethodChannel(
        'com.ryanheise.audio_session',
      );
      bool gateArmed = false;
      final Completer<void> configureReached = Completer<void>();
      final Completer<void> configureGate = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(session, (MethodCall call) async {
            if (gateArmed && call.method == 'setConfiguration') {
              if (!configureReached.isCompleted) configureReached.complete();
              await configureGate.future;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(session, null);
      });
      final JustAudioPlatform previous = JustAudioPlatform.instance;
      final _RecordingPlatform platform = _RecordingPlatform();
      JustAudioPlatform.instance = platform;
      addTearDown(() => JustAudioPlatform.instance = previous);

      final File audio = File(
        '${Directory.systemTemp.path}/hibiki-play-waits-seek.mp3',
      )..writeAsBytesSync(const <int>[0]);
      addTearDown(() {
        if (audio.existsSync()) audio.deleteSync();
      });

      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);
      // 播放器构造时自己的会话配置先放过，只卡本次载入那一下。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gateArmed = true;

      final Future<void> loading = c.load(
        audiobook: Audiobook()
          ..bookKey = 'book'
          ..audioPaths = const <String>[]
          ..audioRoot = null
          ..alignmentFormat = 'srt'
          ..alignmentPath = '',
        audioFiles: <File>[audio],
        initialPositionMs: 65000,
      );
      await configureReached.future;

      // 载入还卡着：用户此刻按播放。
      final Future<void> playing = c.play();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        platform.player?.playPositionsMs ?? const <int>[],
        isEmpty,
        reason: 'playback must not start while the load is still pending',
      );

      configureGate.complete();
      await loading;
      for (
        int i = 0;
        i < 100 && (platform.player?.playPositionsMs.isEmpty ?? true);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(platform.player!.playPositionsMs, <int>[65000]);
      await playing.timeout(const Duration(seconds: 10));
    },
  );
}

class _RecordingPlatform extends JustAudioPlatform {
  _RecordingPlayer? player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    player = _RecordingPlayer(request.id);
    return player!;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async {
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

class _RecordingPlayer extends AudioPlayerPlatform {
  _RecordingPlayer(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  bool _disposed = false;
  bool _loaded = false;
  bool _playPending = false;
  int _positionMs = 0;

  /// 每次平台真正起播时的位置。
  final List<int> playPositionsMs = <int>[];

  void _emit() {
    if (_disposed) return;
    _events.add(
      PlaybackEventMessage(
        processingState: ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: Duration(milliseconds: _positionMs),
        bufferedPosition: Duration(milliseconds: _positionMs),
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
    _positionMs = request.initialPosition?.inMilliseconds ?? 0;
    _loaded = true;
    // just_audio 激活平台时 play 请求可能先于 load 发出；真实播放器把它排队，
    // 载入后从 initialPosition 起播——起播位置在这里结算。
    if (_playPending) {
      _playPending = false;
      playPositionsMs.add(_positionMs);
    }
    _emit();
    return LoadResponse(duration: const Duration(seconds: 100));
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _positionMs = request.position?.inMilliseconds ?? 0;
    _emit();
    return SeekResponse();
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    if (_loaded) {
      playPositionsMs.add(_positionMs);
    } else {
      _playPending = true;
    }
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();
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
  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    if (_disposed) return DisposeResponse();
    _disposed = true;
    await _events.close();
    return DisposeResponse();
  }
}
