import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart' as ag;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/utils/misc/fushi_audio_handler.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// BUG-2961：后台挂有声书——切回来高亮 / 视口与音频不同步；挂久了音频断掉且点不起来。
///
/// 三条根因各一组：
/// * 视口是「音频位置的投影」，后台期间投影丢失（WebView 节流、帧冻结、积压的恢复
///   重锚提交把视口拽回进章那一句），回前台 / 重锚落定后必须按跟随意图重新投影
///   （[AudiobookPlayerController.resyncReaderToAudio]）。
/// * 播放激活串行尾押在 just_audio `play()` 的 Future 上，而音频会话激活被拒时那个
///   Future 永不完成 → 此后所有播放请求永久排队（[playActivationSettled]）。
/// * 系统媒体控制的 PLAY / PAUSE 被压成同一个无方向 toggle 事件，蓝牙 / 车机重连
///   补发的 PLAY 把正在播的声音暂停（[MediaPlayIntent]）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('playActivationSettled', () {
    test('play Future 永不完成、播放态翻回 false（会话激活被拒）→ 激活结束', () async {
      final StreamController<bool> playing = StreamController<bool>();
      bool settled = false;
      unawaited(
        playActivationSettled(
          Completer<void>().future,
          playing.stream,
        ).then((_) => settled = true),
      );
      playing.add(true);
      await pumpEventQueue();
      expect(settled, isFalse, reason: '仍在播放时激活不算结束（串行化保留）');

      playing.add(false);
      await pumpEventQueue();
      expect(settled, isTrue, reason: '播放态翻回 false 就是这次激活的终点，不能永久卡住串行尾');
      await playing.close();
    });

    test('play Future 正常完成 → 激活结束', () async {
      final StreamController<bool> playing = StreamController<bool>();
      playing.add(true);
      await expectLater(
        playActivationSettled(Future<void>.value(), playing.stream),
        completes,
      );
      await playing.close();
    });

    test('播放态流关闭（播放器已释放）→ 激活结束且不抛错', () async {
      final StreamController<bool> playing = StreamController<bool>();
      final Future<void> settled = playActivationSettled(
        Completer<void>().future,
        playing.stream,
      );
      playing.add(true);
      await playing.close();
      await expectLater(settled, completes);
    });
  });

  group('MediaPlayIntent', () {
    test('PLAY / PAUSE 有方向且幂等，耳机单击恒切换', () {
      expect(
        mediaPlayIntentNeedsToggle(MediaPlayIntent.play, isPlaying: true),
        isFalse,
        reason: '播放中补发的 PLAY（蓝牙 / 车机重连）不得把声音暂停',
      );
      expect(
        mediaPlayIntentNeedsToggle(MediaPlayIntent.play, isPlaying: false),
        isTrue,
      );
      expect(
        mediaPlayIntentNeedsToggle(MediaPlayIntent.pause, isPlaying: false),
        isFalse,
        reason: '暂停中收到 PAUSE 不得把声音放出来',
      );
      expect(
        mediaPlayIntentNeedsToggle(MediaPlayIntent.pause, isPlaying: true),
        isTrue,
      );
      expect(
        mediaPlayIntentNeedsToggle(MediaPlayIntent.toggle, isPlaying: true),
        isTrue,
      );
      expect(
        mediaPlayIntentNeedsToggle(MediaPlayIntent.toggle, isPlaying: false),
        isTrue,
      );
    });

    test('handler 把 play / pause / 单击分别发成各自的意图', () async {
      final List<MediaPlayIntent> intents = <MediaPlayIntent>[];
      int nextCalls = 0;
      final FushiAudioHandler handler = FushiAudioHandler(
        onPlayIntent: intents.add,
        onSeek: (_) {},
        onRewind: () {},
        onFastForward: () {},
        onSkipToNext: () => nextCalls++,
      );

      await handler.play();
      await handler.pause();
      await handler.click();
      await handler.click(ag.MediaButton.next);

      expect(intents, <MediaPlayIntent>[
        MediaPlayIntent.play,
        MediaPlayIntent.pause,
        MediaPlayIntent.toggle,
      ]);
      expect(nextCalls, 1, reason: '非 media 键照旧走基类分派');
    });
  });

  group('resyncReaderToAudio', () {
    test('跟随播放中：强制 reveal 一次并通知 reader', () async {
      final AudiobookPlayerController c = await _playingController();
      int notifies = 0;
      c.addListener(() => notifies++);

      c.resyncReaderToAudio();

      expect(notifies, 1);
      expect(
        c.consumeForceReveal(),
        isTrue,
        reason: 'reader 的 _onCueChanged 据此把视口滚回当前句',
      );
      c.dispose();
    });

    test('暂停态不动视口（用户自己滚走的阅读位置不被拽回）', () async {
      final AudiobookPlayerController c = await _playingController();
      await c.pause();
      int notifies = 0;
      c.addListener(() => notifies++);

      c.resyncReaderToAudio();

      expect(notifies, 0);
      expect(c.consumeForceReveal(), isFalse);
      c.dispose();
    });

    test('手动翻页护栏在位时不动视口', () async {
      final AudiobookPlayerController c = await _playingController();
      c.noteManualReaderNavigation();
      int notifies = 0;
      c.addListener(() => notifies++);

      c.resyncReaderToAudio();

      expect(notifies, 0);
      expect(c.consumeForceReveal(), isFalse);
      c.dispose();
    });

    test('跟随音频关闭时不动视口', () async {
      final AudiobookPlayerController c = await _playingController();
      c.followAudio.value = false;
      int notifies = 0;
      c.addListener(() => notifies++);

      c.resyncReaderToAudio();

      expect(notifies, 0);
      expect(c.consumeForceReveal(), isFalse);
      c.dispose();
    });
  });

  group('装配守卫', () {
    String read(String path) => File(path).readAsStringSync();

    test('回前台（resumed）在第一帧后按跟随意图重投影', () {
      final String src = read(
        'lib/src/pages/implementations/reader_fushi_page.dart',
      );
      final int start = src.indexOf('void didChangeAppLifecycleState(');
      expect(start, greaterThan(-1));
      final int resumed = src.indexOf(
        'state == AppLifecycleState.resumed',
        start,
      );
      expect(resumed, greaterThan(start));
      final int end = src.indexOf('\n  }\n', resumed);
      final String body = src.substring(resumed, end);
      expect(
        body,
        contains('addPostFrameCallback'),
        reason: '必须排在积压的 post-frame（恢复重锚提交）之后',
      );
      expect(body, contains('resyncReaderToAudio()'));
    });

    test('恢复重锚落定后把视口归属交还给跟随音频', () {
      final String src = read(
        'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
      );
      final int start = src.indexOf(
        'Future<void> _reanchorContinuousAfterRestore()',
      );
      expect(start, greaterThan(-1));
      final int commit = src.indexOf('onAfterCommit:', start);
      final int end = src.indexOf('\n      },', commit);
      expect(src.substring(commit, end), contains('resyncReaderToAudio()'));
    });

    test('播放激活串行尾按 playActivationSettled 结束，不押 play() 的 Future', () {
      final String src = read(
        'lib/src/media/audiobook/audiobook_controller.dart',
      );
      final int start = src.indexOf('Future<void> _activateMainPlayer()');
      final int end = src.indexOf('Future<void> pause()', start);
      final String body = src.substring(start, end);
      expect(
        body,
        contains(
          'playActivationSettled(_player.play(), _player.playingStream)',
        ),
      );
      expect(body, isNot(contains('await _player.play();')));
    });

    test('会话按意图落控制器，不再把系统 PLAY 当 toggle', () {
      final String src = read('lib/src/media/audiobook/audiobook_session.dart');
      final int start = src.indexOf('_playStreamSub = _controlStreams');
      final int end = src.indexOf(';', src.indexOf('listen(', start));
      final String body = src.substring(start, end);
      expect(body, contains('playIntentStream'));
      expect(body, contains('applyMediaPlayIntent'));
      expect(body, isNot(contains('togglePlayPause')));
    });
  });
}

/// 播放中、跟随开、按过播放、cue 落在 reader 当前章（不触发跨章）的控制器。
Future<AudiobookPlayerController> _playingController() async {
  _installFakeAudioPlatform();
  final AudiobookPlayerController c = AudiobookPlayerController();
  final File audioFile = File(
    '${Directory.systemTemp.path}/fushi-bg-resync-${DateTime.now().microsecondsSinceEpoch}.mp3',
  );
  audioFile.writeAsBytesSync(const <int>[0]);
  addTearDown(() {
    if (audioFile.existsSync()) audioFile.deleteSync();
  });
  await c.load(audiobook: _audiobook(), audioFiles: <File>[audioFile]);
  c.onPositionWrite = (String uid, int ms) async {};
  c.setChapterCues(<AudioCue>[_cue(0), _cue(1000), _cue(2000)]);
  c.getCurrentReaderSection = () => 12;
  c.onCrossChapter = (_) {};
  await c.play();
  await Future<void>.delayed(const Duration(milliseconds: 10));
  c.debugUpdateCueForPosition(1500);
  expect(c.currentCue?.startMs, 1000, reason: '前提：当前句就位');
  expect(c.isPlaying, isTrue, reason: '前提：正在播放');
  c.consumeForceReveal();
  return c;
}

AudioCue _cue(int startMs) {
  return AudioCue()
    ..id = null
    ..bookKey = 'book'
    ..chapterHref = 'chapter-12'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = SubtitleRematchCodec.encodeHit(
      sectionIndex: 12,
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
  JustAudioPlatform.instance = _FakeJustAudioPlatform();
  addTearDown(() {
    JustAudioPlatform.instance = previousPlatform;
  });
}

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
    _events.add(
      PlaybackEventMessage(
        processingState: ProcessingStateMessage.ready,
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
