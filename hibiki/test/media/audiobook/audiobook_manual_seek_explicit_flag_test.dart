import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// BUG-903：有声书暂停态下点某句（skipToCue）立起显式 seek 抑制窗后，用户拖进度条
/// / 快进（seekMs）到新位置，抑制旗不复位、旧目标不更新；按播放后
/// [AudiobookPlayerController.debugUpdateCueForPosition]（模拟 tick）仍以旧目标判据
/// 抑制新位置，cue/高亮卡在旧句直到到达旧目标（原 BUG-061 的回归缺口）。
///
/// 根因：抑制旗 `_explicitSeekInFlight` 只在上下文边界（setChapterCues /
/// notifySectionRestoreCompleted / 落定 tick）复位，三条**手动改位置**路径
/// （seekMs / seekRelative / noteManualReaderNavigation）不复位。
///
/// 修复：手动 seek 代表一个全新的、取代 in-flight explicit seek 的用户意图，
/// 在 seekMs（及经它的 seekRelative）与 noteManualReaderNavigation 里
/// `_clearExplicitSeekSuppression()` 复位旗 + 清 stale 目标，让 tick 恢复正常跟随。
/// 这不是「在别处不立旗」——skipToCue 仍立旗，暂停态 skipToCue 精确定位与
/// BUG-061 的加载期抖动抑制原样保留。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('manual seek clears in-flight explicit-seek suppression (BUG-903)', () {
    test('暂停态 skipToCue 立旗 → seekMs 到新位置复位抑制旗，后续 tick 不再被旧目标抑制', () async {
      final AudiobookPlayerController controller =
          await _loadController(<AudioCue>[
        _cue(0), // cue0: [0, 1000]
        _cue(1000), // cue1: [1000, 2000]
        _cue(2000), // cue2: [2000, 3000]
      ]);

      // 暂停态点最后一句 → 立起显式 seek 抑制窗，权威 cue 写成 cue2。
      await controller.skipToCue(controller.chapterCuesSnapshot[2]);
      expect(controller.explicitSeekInFlightForTesting, isTrue,
          reason: 'skipToCue（sasayaki 路径）暂停态应立起抑制窗');
      expect(controller.currentCue?.startMs, 2000);

      // 让 skipToCue 那次 seek 吐出的事件落库，`_player.duration` 就绪，
      // 否则 seekMs 的 duration 守卫会早退（广播事件异步投递）。
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 用户拖进度条回到 cue1（1000ms）—— 全新意图，取代 in-flight explicit seek。
      await controller.seekMs(1000);
      expect(controller.explicitSeekInFlightForTesting, isFalse,
          reason: '手动 seek 必须复位显式 seek 抑制旗（BUG-903 根因）');

      // 模拟暂停态下到达新位置的 tick：旗已复位，不再被旧目标(cue2@2000)抑制，
      // cue 正常收敛到 cue1。旧行为下旗仍立，!playing 早退 → cue 卡在 cue2。
      controller.debugUpdateCueForPosition(1000);
      expect(controller.currentCue?.startMs, 1000,
          reason: '复位后暂停态 tick 应跟随新位置到 cue1，而非被旧目标抑制');

      controller.dispose();
    });

    test('暂停态 skipToCue 立旗 → noteManualReaderNavigation 手动翻页也复位抑制旗', () async {
      final AudiobookPlayerController controller =
          await _loadController(<AudioCue>[
        _cue(0),
        _cue(1000),
        _cue(2000),
      ]);

      await controller.skipToCue(controller.chapterCuesSnapshot[2]);
      expect(controller.explicitSeekInFlightForTesting, isTrue);

      // 手动翻页（TOC / 链接 / 书签 / 翻页）同样取代 in-flight explicit seek。
      controller.noteManualReaderNavigation();
      expect(controller.explicitSeekInFlightForTesting, isFalse,
          reason: 'noteManualReaderNavigation 必须复位显式 seek 抑制旗');

      controller.dispose();
    });

    test('未手动 seek：暂停态无关瞬态 tick 不复位抑制旗（BUG-061 暂停抑制原样保留）', () async {
      final AudiobookPlayerController controller =
          await _loadController(<AudioCue>[
        _cue(0),
        _cue(1000),
        _cue(2000),
      ]);

      await controller.skipToCue(controller.chapterCuesSnapshot[2]);
      expect(controller.explicitSeekInFlightForTesting, isTrue);
      expect(controller.currentCue?.startMs, 2000);

      // 没有手动 seek 介入：加载期旧位置瞬态 tick 既不能清旗，也不能把权威
      // cue2 覆盖回旧句——证明修复只在「手动改位置」路径复位，没过度清旗。
      controller.debugUpdateCueForPosition(800);
      expect(controller.explicitSeekInFlightForTesting, isTrue,
          reason: '无手动 seek 时暂停态瞬态 tick 不得复位抑制旗（不重引 BUG-061）');
      expect(controller.currentCue?.startMs, 2000,
          reason: '抑制窗仍应保护权威 cue2 不被瞬态旧位置覆盖');

      controller.dispose();
    });
  });

  // 源码守卫：手动改位置路径必须复位抑制窗；删掉复位就会让 BUG-903 复发。
  test('源码守卫：seekMs / noteManualReaderNavigation 均复位显式 seek 抑制窗', () {
    final String src = File(
      '../packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart',
    ).readAsStringSync();

    int bodyOf(String signature) {
      final int start = src.indexOf(signature);
      expect(start, greaterThanOrEqualTo(0), reason: '找不到 $signature');
      final int braceOpen = src.indexOf('{', start);
      int depth = 0;
      for (int i = braceOpen; i < src.length; i++) {
        if (src[i] == '{') depth++;
        if (src[i] == '}') {
          depth--;
          if (depth == 0) return i;
        }
      }
      fail('$signature 花括号不匹配');
    }

    final int seekMsStart = src.indexOf('Future<void> seekMs(int positionMs)');
    final String seekMsBody = src.substring(
        seekMsStart, bodyOf('Future<void> seekMs(int positionMs)'));
    expect(seekMsBody.contains('_clearExplicitSeekSuppression()'), isTrue,
        reason: 'seekMs 必须复位显式 seek 抑制窗（BUG-903）');

    final int noteStart = src.indexOf('void noteManualReaderNavigation()');
    final String noteBody =
        src.substring(noteStart, bodyOf('void noteManualReaderNavigation()'));
    expect(noteBody.contains('_clearExplicitSeekSuppression()'), isTrue,
        reason: 'noteManualReaderNavigation 必须复位显式 seek 抑制窗（BUG-903）');
  });
}

Future<AudiobookPlayerController> _loadController(List<AudioCue> cues) async {
  _installFakeAudioPlatform();
  final AudiobookPlayerController controller = AudiobookPlayerController();
  final File audioFile = File(
    '${Directory.systemTemp.path}/hibiki-manual-seek-${cues.length}.mp3',
  );
  if (!audioFile.existsSync()) {
    audioFile.writeAsBytesSync(const <int>[0]);
  }
  addTearDown(() {
    if (audioFile.existsSync()) audioFile.deleteSync();
  });
  await controller.load(
    audiobook: _audiobook(),
    audioFiles: <File>[audioFile],
  );
  controller.setChapterCues(cues);
  return controller;
}

AudioCue _cue(int startMs) {
  return AudioCue()
    ..id = null
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = 'cue-$startMs'
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
