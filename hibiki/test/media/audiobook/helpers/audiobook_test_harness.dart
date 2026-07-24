import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// 有声书测试共享夹具。
///
/// 这些测试原本各自内联一整套「假 just_audio 平台/播放器」——同一份 ~110 行的
/// [JustAudioPlatform] / [AudioPlayerPlatform] 桩在 10 个文件里逐字复制。真正分化的
/// 只有 `load/play/pause/seek` 的少数几行语义；其余（20 个空实现 setter、事件流、
/// dispose、平台侧 init/disposePlayer 转发）完全一致。
///
/// 这里把不变的部分抽成 [FakeAudioPlayerBase] / [FakeAudioPlatformBase]，把两种真实
/// 用到的语义变体固化成 [EmittingFakeAudioPlatform]（load/seek 吐出 `ready` 事件，
/// play/pause 立即返回）和 [HangingFakeAudioPlatform]（load 永不完成，用于「加载未完成
/// 也能跳句/不阻塞」类断言）。测试语义与断言逐字保留，差异全部参数化。

// ── 数据夹具 ──────────────────────────────────────────────────────────

/// 所有有声书测试共用的最小 [Audiobook]：无音频路径、srt 对齐、空对齐路径。
Audiobook fakeAudiobook({String bookKey = 'book'}) => Audiobook()
  ..bookKey = bookKey
  ..audioPaths = const <String>[]
  ..audioRoot = null
  ..alignmentFormat = 'srt'
  ..alignmentPath = '';

/// 在系统临时目录建一个 1 字节的占位音频文件；[autoDelete] 时注册 tearDown 清理。
File createFakeAudioFile(String name, {bool autoDelete = true}) {
  final File file = File('${Directory.systemTemp.path}/$name');
  if (!file.existsSync()) {
    file.writeAsBytesSync(const <int>[0]);
  }
  if (autoDelete) {
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
  }
  return file;
}

// ── 平台安装 ──────────────────────────────────────────────────────────

/// mock 掉 audio_session 的方法通道并把 [platform] 装成当前 [JustAudioPlatform]，
/// 两者都在 tearDown 里还原。返回 [platform] 便于调用方读取其 player。
T installFakeAudioPlatform<T extends JustAudioPlatform>(T platform) {
  const MethodChannel audioSessionChannel =
      MethodChannel('com.ryanheise.audio_session');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(audioSessionChannel, (_) async => null);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, null);
  });

  final JustAudioPlatform previousPlatform = JustAudioPlatform.instance;
  JustAudioPlatform.instance = platform;
  addTearDown(() => JustAudioPlatform.instance = previousPlatform);
  return platform;
}

/// 装一个「吐事件」的假平台（load/seek 立即 emit `ready`）。
EmittingFakeAudioPlatform installEmittingAudioPlatform() =>
    installFakeAudioPlatform(EmittingFakeAudioPlatform());

/// 装一个「加载挂起」的假平台（load 永不完成）。
HangingFakeAudioPlatform installHangingAudioPlatform() =>
    installFakeAudioPlatform(HangingFakeAudioPlatform());

// ── 假播放器基类 ──────────────────────────────────────────────────────

/// 所有假 [AudioPlayerPlatform] 的公共骨架：事件流、[emit]、[dispose] 与 20 个平台
/// setter 的空实现。子类只需覆写 `load/play/pause/seek` 的差异语义。
abstract class FakeAudioPlayerBase extends AudioPlayerPlatform {
  FakeAudioPlayerBase(super.id);

  final StreamController<PlaybackEventMessage> events =
      StreamController<PlaybackEventMessage>.broadcast();

  /// 投递一条播放事件（位置=缓冲位置=[ms]）。播放器已 dispose（事件流已关）时静默跳过。
  void emit(
    int ms, {
    ProcessingStateMessage state = ProcessingStateMessage.ready,
    Duration duration = const Duration(seconds: 100),
  }) {
    if (events.isClosed) return;
    events.add(PlaybackEventMessage(
      processingState: state,
      updateTime: DateTime.now(),
      updatePosition: Duration(milliseconds: ms),
      bufferedPosition: Duration(milliseconds: ms),
      duration: duration,
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => events.stream;

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
    if (!events.isClosed) await events.close();
    return DisposeResponse();
  }
}

/// 单播放器假 [JustAudioPlatform] 骨架：init 建一个 [P] 并暂存到 [player]，
/// disposePlayer / disposeAllPlayers 都转发到它。
abstract class FakeAudioPlatformBase<P extends FakeAudioPlayerBase>
    extends JustAudioPlatform {
  P? player;

  /// 子类工厂：为给定 id 造一个具体的假播放器。
  P createPlayer(String id);

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final P created = createPlayer(request.id);
    player = created;
    return created;
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

// ── 吐事件变体 ────────────────────────────────────────────────────────

/// load/seek 时立即 emit 一条 `ready` 事件（位置=请求位置），play/pause 立即返回。
/// 用于依赖「加载后有初始位置事件 / seek 后有落点事件」的测试。
class EmittingFakeAudioPlayer extends FakeAudioPlayerBase {
  EmittingFakeAudioPlayer(super.id);

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    emit(request.initialPosition?.inMilliseconds ?? 0);
    return LoadResponse(duration: const Duration(seconds: 100));
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    emit(request.position?.inMilliseconds ?? 0);
    return SeekResponse();
  }
}

class EmittingFakeAudioPlatform
    extends FakeAudioPlatformBase<EmittingFakeAudioPlayer> {
  @override
  EmittingFakeAudioPlayer createPlayer(String id) =>
      EmittingFakeAudioPlayer(id);
}

// ── 加载挂起变体 ──────────────────────────────────────────────────────

/// load 返回一个永不完成的 Future（模拟平台预加载卡住），[loadCalls] 记录调用次数；
/// play/pause/seek 立即返回。用于「加载未落定也能跳句/不阻塞」类断言。
class HangingFakeAudioPlayer extends FakeAudioPlayerBase {
  HangingFakeAudioPlayer(super.id);

  int loadCalls = 0;

  @override
  Future<LoadResponse> load(LoadRequest request) {
    loadCalls++;
    return Completer<LoadResponse>().future;
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();

  @override
  Future<SeekResponse> seek(SeekRequest request) async => SeekResponse();
}

class HangingFakeAudioPlatform
    extends FakeAudioPlatformBase<HangingFakeAudioPlayer> {
  @override
  HangingFakeAudioPlayer createPlayer(String id) => HangingFakeAudioPlayer(id);
}
