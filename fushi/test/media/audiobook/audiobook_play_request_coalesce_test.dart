import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// BUG-4349（反馈 4FX5H_19ei）：有声书阅读页里点查词弹窗顶栏的播放按钮后，之后的
/// 查词不再暂停有声书。
///
/// 根因在控制器的激活串行化：Android（ExoPlayer）/ Darwin 后端上一次 `play()` 激活要
/// 挂到**下一次暂停**才收尾，而旧实现把「已经在播时再来的 play 请求」排到它后面。
/// 弹窗顶栏按播放（一次激活）→ 关弹窗续播（又一次 play，排队）→ 下一次查词暂停让第一次
/// 激活收尾 → 排着的那次立刻执行 `_player.play()`，刚暂停的有声书被顶回播放。
///
/// 假播放器复现 Darwin / Android 的「play 挂到 pause 才完成」语义（与
/// `audiobook_stop_darwin_play_semantics_test.dart` 同一份）。
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

  Future<void> flush() async {
    for (int i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<AudiobookPlayerController> loaded(String fileName) async {
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);
    await c.load(
      audiobook: ab(),
      audioFiles: <File>[makeFile(fileName)],
      initialPositionMs: 65000,
    );
    c.onPositionWrite = (String uid, int ms) async {};
    return c;
  }

  test(
    'a play request while already playing does not resume after the next pause',
    () async {
      final _DarwinPlatform plat = installPlatform();
      final AudiobookPlayerController c = await loaded(
        'fushi-bug4323-replay.mp3',
      );

      unawaited(c.play());
      await flush();
      expect(c.isPlaying, isTrue);
      expect(plat.player!.playCalls, 1);
      expect(
        plat.player!.playPending,
        isTrue,
        reason: '前提：假播放器必须复现「play 挂到 pause 才完成」的语义',
      );

      // 已在播时再来一次 play（关查词弹窗的续播 / 「从此句播放」叠加续播）。
      unawaited(c.play());
      await flush();
      expect(c.isPlaying, isTrue);

      // 下一次查词暂停。
      await c.pause();
      await flush();

      expect(c.isPlaying, isFalse, reason: '在播时的 play 请求已被满足，不能排队到暂停之后把播放顶回去');
      expect(plat.player!.playCalls, 1);
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'lookup pause → popup play → close resume → next lookup pause stays paused',
    () async {
      final _DarwinPlatform plat = installPlatform();
      final AudiobookPlayerController c = await loaded(
        'fushi-bug4323-lookup.mp3',
      );

      unawaited(c.play());
      await flush();
      expect(c.isPlaying, isTrue);

      // 第一次查词：暂停。
      await c.pause();
      await flush();
      expect(c.isPlaying, isFalse);

      // 弹窗顶栏按播放。
      unawaited(c.togglePlayPause());
      await flush();
      expect(c.isPlaying, isTrue);

      // 关弹窗：阅读器按「查词暂停」标记续播（此刻已在播）。
      unawaited(c.play());
      await flush();
      expect(c.isPlaying, isTrue);

      // 第二次查词：必须停住。
      await c.pause();
      await flush();
      expect(c.isPlaying, isFalse, reason: '第二次查词暂停被排队的旧 play 顶掉');
      expect(plat.player!.playCalls, 2);
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test('play after a pause still starts a fresh activation', () async {
    final _DarwinPlatform plat = installPlatform();
    final AudiobookPlayerController c = await loaded('fushi-bug4323-fresh.mp3');

    unawaited(c.play());
    await flush();
    await c.pause();
    // 暂停后立刻再播（不等上一次激活收尾）：不能并入那次已停下的激活。
    unawaited(c.play());
    await flush();

    expect(c.isPlaying, isTrue);
    expect(plat.player!.playCalls, 2);
  }, timeout: const Timeout(Duration(seconds: 15)));
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
