import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/text_leads_page_stop.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// 文字领读在真实控制器上的行为（假的 just_audio 平台）：屏末停播、翻屏续播、
/// 显式跳句不误停、停在屏末按播放 = 翻屏、关掉跟随即撤销。
///
/// 位置轮询周期设成 1 小时：平台位置流不会自己插进来，tick 全由
/// [AudiobookPlayerController.textLeadsPageStopTickForTesting] 手动驱动。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<AudioCue> cues = <AudioCue>[
    _cue(0, 0, 900),
    _cue(1, 1000, 1500),
    _cue(2, 2000, 2500),
    _cue(3, 3000, 3500),
  ];
  final TextLeadsPageBounds page1 = TextLeadsPageBounds(
    first: cues[0],
    last: cues[1],
  );
  final TextLeadsPageBounds page2 = TextLeadsPageBounds(
    first: cues[2],
    last: cues[3],
  );

  Future<(AudiobookPlayerController, _HangingAudioPlayer)> setUpPlaying({
    bool requested = true,
  }) async {
    final _HangingJustAudioPlatform platform = _installHangingAudioPlatform(
      ready: true,
    );
    final AudiobookPlayerController controller = AudiobookPlayerController(
      positionPollPeriod: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);
    await controller.load(
      audiobook: _audiobook(),
      audioFiles: <File>[File('${Directory.systemTemp.path}/text-leads.mp3')],
    );
    controller.setChapterCues(cues);
    controller.setTextLeadsRequested(requested);
    await controller.play();
    return (controller, platform.player!);
  }

  test('播到本屏末句句末就停，并记为「停在屏末」', () async {
    final (AudiobookPlayerController c, _) = await setUpPlaying();
    expect(c.textLeads, isTrue);
    await c.onReaderPageBounds(page1);
    expect(c.isPlaying, isTrue, reason: '音频在本屏：不动');

    expect(c.textLeadsPageStopTickForTesting(400), isFalse);
    expect(c.textLeadsPageStopTickForTesting(1520), isTrue);
    expect(c.isPlaying, isFalse);
    expect(c.pausedAtPageEnd, isTrue);
  });

  test('临近屏末按剩余时长精确停播，不等下一次位置轮询', () async {
    final (AudiobookPlayerController c, _) = await setUpPlaying();
    await c.onReaderPageBounds(page1);
    expect(c.textLeadsPageStopTickForTesting(1460), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(c.isPlaying, isFalse);
    expect(c.pausedAtPageEnd, isTrue);
  });

  test('停在屏末后翻到下一屏（音频已在新屏开头）→ 原地续播，不再 seek', () async {
    final (AudiobookPlayerController c, _HangingAudioPlayer player) =
        await setUpPlaying();
    await c.onReaderPageBounds(page1);
    c.textLeadsPageStopTickForTesting(400);
    c.textLeadsPageStopTickForTesting(1520);
    // 平台位置停在上一屏句末之后、新屏首句之前的静音里。
    player.emitPosition(0, const Duration(milliseconds: 1900));
    await pumpEventQueue();
    final int seeksBefore = player.seeks.length;

    await c.onReaderPageBounds(page2);
    expect(c.isPlaying, isTrue);
    expect(c.pausedAtPageEnd, isFalse);
    expect(player.seeks.length, seeksBefore, reason: '续播不 seek');
  });

  test('停在屏末后往回翻（音频不在那一屏）→ 跳到那一屏首句并播放', () async {
    final (AudiobookPlayerController c, _HangingAudioPlayer player) =
        await setUpPlaying();
    await c.onReaderPageBounds(page2);
    // page2 上报时音频在 0：不在本屏 → 正在播 → 跳到 page2 首句接着播。
    expect(player.seeks.last.position, const Duration(milliseconds: 2000));
    expect(c.isPlaying, isTrue);

    c.textLeadsPageStopTickForTesting(2100);
    expect(c.textLeadsPageStopTickForTesting(3600), isTrue);
    player.emitPosition(0, const Duration(milliseconds: 3600));
    await pumpEventQueue();

    await c.onReaderPageBounds(page1);
    expect(player.seeks.last.position, Duration.zero);
    expect(c.isPlaying, isTrue);
  });

  test('用户自己暂停后翻屏 → 只挪音频位置，不起播', () async {
    final (AudiobookPlayerController c, _HangingAudioPlayer player) =
        await setUpPlaying();
    await c.onReaderPageBounds(page1);
    await c.pause();
    await c.onReaderPageBounds(page2);
    expect(player.seeks.last.position, const Duration(milliseconds: 2000));
    expect(c.isPlaying, isFalse);
  });

  test('同一屏重复上报（重排）不重播这一屏', () async {
    final (AudiobookPlayerController c, _HangingAudioPlayer player) =
        await setUpPlaying();
    await c.onReaderPageBounds(page1);
    c.textLeadsPageStopTickForTesting(400);
    c.textLeadsPageStopTickForTesting(1520);
    final int seeksBefore = player.seeks.length;
    await c.onReaderPageBounds(
      TextLeadsPageBounds(first: cues[0], last: cues[1]),
    );
    expect(player.seeks.length, seeksBefore);
    expect(c.pausedAtPageEnd, isTrue);
    expect(c.isPlaying, isFalse);
  });

  test('显式跳句跳出本屏（新屏范围还没报上来）不被误判为越过屏末', () async {
    final (AudiobookPlayerController c, _) = await setUpPlaying();
    await c.onReaderPageBounds(page1);
    c.textLeadsPageStopTickForTesting(400);
    await c.skipToCue(cues[3], revealReader: true);
    expect(c.textLeadsPageStopTickForTesting(3100), isFalse);
    expect(c.pausedAtPageEnd, isFalse);
  });

  test('停在屏末时按播放 = 请 reader 翻到下一屏（续播由新屏上报驱动）', () async {
    final (AudiobookPlayerController c, _) = await setUpPlaying();
    int advances = 0;
    c.onTextLeadsAdvancePage = () {
      advances++;
      return true;
    };
    await c.onReaderPageBounds(page1);
    c.textLeadsPageStopTickForTesting(400);
    c.textLeadsPageStopTickForTesting(1520);

    await c.play();
    expect(advances, 1);
    expect(c.isPlaying, isFalse, reason: '等新屏上报再播');
    expect(c.pausedAtPageEnd, isTrue);
  });

  test('文字领读下音频从不被动翻屏（shouldRevealCurrentCue 恒假）', () async {
    final (AudiobookPlayerController c, _) = await setUpPlaying();
    expect(c.shouldRevealCurrentCue, isFalse);
    c.setTextLeadsRequested(false);
    expect(c.shouldRevealCurrentCue, isTrue, reason: '音频领读照旧跟随');
  });

  test('关掉跟随音频 → 文字领读撤销、屏末状态清空；重新打开会请求补报当前屏', () async {
    final (AudiobookPlayerController c, _) = await setUpPlaying();
    int reports = 0;
    c.onTextLeadsActivated = () => reports++;
    await c.onReaderPageBounds(page1);
    c.textLeadsPageStopTickForTesting(400);
    c.textLeadsPageStopTickForTesting(1520);

    c.setFollowAudio(false);
    expect(c.textLeads, isFalse);
    expect(c.pausedAtPageEnd, isFalse);
    expect(c.pageBoundsForTesting, isNull);

    c.setFollowAudio(true);
    expect(c.textLeads, isTrue);
    expect(reports, 1);
  });

  test('歌词覆盖层期间不生效（正文被强制跟随音频）', () async {
    final (AudiobookPlayerController c, _) = await setUpPlaying();
    c.setReaderFollowOverride(true);
    expect(c.textLeads, isFalse);
    c.setReaderFollowOverride(false);
    expect(c.textLeads, isTrue);
  });
}

AudioCue _cue(int sid, int startMs, int endMs) {
  return AudioCue()
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = sid
    ..textFragmentId = 'cue-$sid'
    ..text = 'cue $sid'
    ..startMs = startMs
    ..endMs = endMs
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

// ── 假 just_audio 平台（与 audiobook_controller_seek_test.dart 同款）──────────
_HangingJustAudioPlatform _installHangingAudioPlatform({bool ready = false}) {
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
  final _HangingJustAudioPlatform platform = _HangingJustAudioPlatform(
    ready: ready,
  );
  JustAudioPlatform.instance = platform;
  addTearDown(() {
    JustAudioPlatform.instance = previousPlatform;
  });
  return platform;
}

class _HangingJustAudioPlatform extends JustAudioPlatform {
  _HangingJustAudioPlatform({this.ready = false});
  final bool ready;
  _HangingAudioPlayer? player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    player = _HangingAudioPlayer(request.id, ready: ready);
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

class _HangingAudioPlayer extends AudioPlayerPlatform {
  _HangingAudioPlayer(super.id, {this.ready = false});
  final bool ready;
  final List<SeekRequest> seeks = <SeekRequest>[];

  void emitPosition(int index, Duration position) {
    _events.add(
      PlaybackEventMessage(
        processingState: ProcessingStateMessage.ready,
        updateTime: DateTime.now(),
        updatePosition: position,
        bufferedPosition: position,
        duration: Duration(seconds: index == 0 ? 2 : 120),
        icyMetadata: null,
        currentIndex: index,
        androidAudioSessionId: null,
      ),
    );
  }

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  int loadCalls = 0;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) {
    loadCalls++;
    if (ready) {
      emitPosition(
        request.initialIndex ?? 0,
        request.initialPosition ?? Duration.zero,
      );
      return Future<LoadResponse>.value(
        LoadResponse(duration: const Duration(seconds: 2)),
      );
    }
    return Completer<LoadResponse>().future;
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    return PauseResponse();
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    return PlayResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    seeks.add(request);
    if (ready) {
      emitPosition(request.index ?? 0, request.position ?? Duration.zero);
    }
    return SeekResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
    SetAndroidAudioAttributesRequest request,
  ) async {
    return SetAndroidAudioAttributesResponse();
  }

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
  setAutomaticallyWaitsToMinimizeStalling(
    SetAutomaticallyWaitsToMinimizeStallingRequest request,
  ) async {
    return SetAutomaticallyWaitsToMinimizeStallingResponse();
  }

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
  setCanUseNetworkResourcesForLiveStreamingWhilePaused(
    SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request,
  ) async {
    return SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    return SetLoopModeResponse();
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async {
    return SetPitchResponse();
  }

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
    SetPreferredPeakBitRateRequest request,
  ) async {
    return SetPreferredPeakBitRateResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async {
    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
    SetShuffleOrderRequest request,
  ) async {
    return SetShuffleOrderResponse();
  }

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
    SetSkipSilenceRequest request,
  ) async {
    return SetSkipSilenceResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    return SetSpeedResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    return SetVolumeResponse();
  }

  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
    SetWebCrossOriginRequest request,
  ) async {
    return SetWebCrossOriginResponse();
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    await _events.close();
    return DisposeResponse();
  }
}
