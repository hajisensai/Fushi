import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// BUG-2779：有声书**暂停**时用户翻到别的章，新章一载入就被拽回音频所在章。
///
/// 真机形状（iOS VN，俺ガイル 1 卷）：音频停在 ch12「文芸部か」；在纯图片章 ch11
/// 往回翻，上一章 ch10 刚露一帧就被拉回 ch12，再往回翻落到插图章又被拉回——
/// 插图位置永远翻不过去。
///
/// 根因：每章文档载入 `_injectAudiobookBridge` 都会 `setChapterCues(allCues)`，而
/// 它先把 `_currentCue` 清空、`_currentCueIndex = -1` 再按位置重算——同一句被判成
/// 「cue 变了」，走变更分支：清掉手动翻页护栏、无视暂停直接 `_maybeEmitCrossChapter`。
/// 换 cue 列表不是音频推进，不得借此发跨章。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('暂停 + 手动翻到别章后重灌同一份 cue：不发跨章、护栏保留', () async {
    final List<AudioCue> cues = <AudioCue>[
      _cue(0, section: 10),
      _cue(1000, section: 12),
      _cue(2000, section: 12),
    ];
    final AudiobookPlayerController controller = await _loadController(cues);
    // 本会话按过一次播放（hasPlayedOnce），随后暂停在 ch12 的 cue1。阅读器此刻还没
    // 挂上（getCurrentReaderSection 未装配 = -1），定位过程不会发跨章。
    await controller.play();
    await controller.pause();
    // 让假平台的 load 事件落地（duration 就绪），seekMs 才会真正下发。
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await controller.seekMs(1500);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    controller.debugUpdateCueForPosition(1500);
    expect(controller.currentCue?.startMs, 1000);

    // 阅读器挂在音频所在的 ch12。
    int readerSection = 12;
    final List<int> crossRequests = <int>[];
    controller.getCurrentReaderSection = () => readerSection;
    controller.onCrossChapter = crossRequests.add;

    // 用户手动翻回 ch10：阅读器先登记手动导航，再载入新章文档 → 重灌 cue。
    controller.noteManualReaderNavigation();
    readerSection = 10;
    controller.setChapterCues(cues);
    controller.notifySectionRestoreCompleted(
      currentReaderSection: 10,
      success: true,
    );

    expect(
      crossRequests,
      isEmpty,
      reason: '暂停态重灌同一份 cue 不得把阅读器拽回音频章（BUG-2779）',
    );
    expect(
      controller.currentCue?.startMs,
      1000,
      reason: '当前句身份应在换列表后保留',
    );

    // 对照：音频真的推进到下一句时，跟随照常接管。
    await controller.seekMs(2500);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    controller.debugUpdateCueForPosition(2500);
    expect(crossRequests, <int>[12], reason: '换句后的正常跟随不受影响');

    controller.dispose();
  });

  test('重灌的列表里没有原来那句（逐章 cue 列表）时照旧按位置重算', () async {
    final AudiobookPlayerController controller = await _loadController(
      <AudioCue>[_cue(0, section: 1)],
    );
    controller.getCurrentReaderSection = () => 2;
    controller.debugUpdateCueForPosition(500);
    expect(controller.currentCue?.startMs, 0);

    controller.setChapterCues(<AudioCue>[_cue(3000, section: 2)]);
    controller.debugUpdateCueForPosition(3500);
    expect(controller.currentCue?.startMs, 3000);

    controller.dispose();
  });
}

Future<AudiobookPlayerController> _loadController(List<AudioCue> cues) async {
  _installFakeAudioPlatform();
  final AudiobookPlayerController controller = AudiobookPlayerController();
  final File audioFile = File(
    '${Directory.systemTemp.path}/hibiki-paused-reload-${cues.length}.mp3',
  );
  if (!audioFile.existsSync()) {
    audioFile.writeAsBytesSync(const <int>[0]);
  }
  addTearDown(() {
    if (audioFile.existsSync()) audioFile.deleteSync();
  });
  await controller.load(audiobook: _audiobook(), audioFiles: <File>[audioFile]);
  controller.setChapterCues(cues);
  return controller;
}

AudioCue _cue(int startMs, {required int section}) {
  return AudioCue()
    ..id = null
    ..bookKey = 'book'
    ..chapterHref = 'chapter-$section'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = SubtitleRematchCodec.encodeHit(
      sectionIndex: section,
      normCharStart: startMs ~/ 100,
      normCharEnd: startMs ~/ 100 + 5,
    )
    ..text = 'cue $startMs'
    ..startMs = startMs
    ..endMs = startMs + 1000
    ..audioFileIndex = 0;
}

Audiobook _audiobook() {
  return Audiobook()
    ..bookKey = 'book'
    ..audioPaths = const <String>[]
    ..audioRoot = null
    ..alignmentFormat = 'srt'
    ..alignmentPath = '';
}

void _installFakeAudioPlatform() {
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
}

/// seek/load 时吐出带 duration 的事件，让 `_player.duration` 就绪、seekMs 能通过
/// duration 守卫真正下发 seek（暂停态，playing 恒为 false）。
class _FakeJustAudioPlatform extends JustAudioPlatform {
  _FakeAudioPlayer? player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    player = _FakeAudioPlayer(request.id);
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
  _FakeAudioPlayer(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  void _emit(int ms) {
    _events.add(PlaybackEventMessage(
      processingState: ProcessingStateMessage.ready,
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
    _emit(request.initialPosition?.inMilliseconds ?? 0);
    return LoadResponse(duration: const Duration(seconds: 100));
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
    if (!_events.isClosed) await _events.close();
    return DisposeResponse();
  }
}
