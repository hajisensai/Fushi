import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// 有声书控制器测试用的假音频后端：just_audio 平台层 + audio_session 通道都换成
/// 内存实现，seek 立即把目标位置当播放事件回报（单文件，时长 [duration]，默认 100 秒）。
///
/// 只在 [testWidgets] / 已 `TestWidgetsFlutterBinding.ensureInitialized()` 的测试里
/// 调用；teardown 自动还原原平台与通道。
void installFakeJustAudio({Duration duration = const Duration(seconds: 100)}) {
  const MethodChannel audioSessionChannel = MethodChannel(
    'com.ryanheise.audio_session',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(audioSessionChannel, (_) async => null);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, null);
  });

  final JustAudioPlatform previousPlatform = JustAudioPlatform.instance;
  JustAudioPlatform.instance = _FakeJustAudioPlatform(duration);
  addTearDown(() {
    JustAudioPlatform.instance = previousPlatform;
  });
}

/// 装好假后端、载入一本单文件有声书（时长 [duration]）的控制器。调用方负责 dispose。
Future<AudiobookPlayerController> loadFakeAudiobookController({
  int initialPositionMs = 0,
  Duration duration = const Duration(seconds: 100),
}) async {
  installFakeJustAudio(duration: duration);
  final AudiobookPlayerController c = AudiobookPlayerController();
  final File audioFile = File(
    '${Directory.systemTemp.path}/fushi-fake-audio-${DateTime.now().microsecondsSinceEpoch}.mp3',
  );
  audioFile.writeAsBytesSync(const <int>[0]);
  addTearDown(() {
    if (audioFile.existsSync()) audioFile.deleteSync();
  });
  await c.load(
    audiobook: Audiobook()
      ..bookKey = 'book'
      ..audioPaths = const <String>[]
      ..audioRoot = null
      ..alignmentFormat = 'srt'
      ..alignmentPath = '',
    audioFiles: <File>[audioFile],
    initialPositionMs: initialPositionMs,
  );
  c.onPositionWrite = (String uid, int ms) async {};
  return c;
}

class _FakeJustAudioPlatform extends JustAudioPlatform {
  _FakeJustAudioPlatform(this.duration);

  final Duration duration;
  _FakeAudioPlayer? player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    player = _FakeAudioPlayer(request.id, duration);
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

class _FakeAudioPlayer extends AudioPlayerPlatform {
  _FakeAudioPlayer(super.id, this.duration);

  final Duration duration;

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  void _emit(int ms) {
    _events.add(
      PlaybackEventMessage(
        processingState: ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: Duration(milliseconds: ms),
        bufferedPosition: Duration(milliseconds: ms),
        duration: duration,
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
    _emit(request.initialPosition?.inMilliseconds ?? 0);
    return LoadResponse(duration: duration);
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _emit(request.position?.inMilliseconds ?? 0);
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

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    if (!_events.isClosed) await _events.close();
    return DisposeResponse();
  }
}
