import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

// BUG-400 / TODO-711 (merged with TODO-707 "opened but nothing appears")
// contract guard.
//
// Root cause (Android): show() goes through startForegroundService and returns
// before the service runs onCreate. Dart pushes the current cue text via
// updateText immediately after show() (in start()'s background-surfaces phase),
// so FloatingLyricService.getInstance() is still null and the line is silently
// dropped -> the current line stays blank until the next cue (severe enough to
// look like "opened but nothing appears"). The real fix lives in Java
// (updateText persists to SharedPreferences unconditionally + readInitialState
// replays it), which the Dart host cannot verify. So this guard only pins the
// Dart wire contract: after show(), updateText IS emitted carrying the current
// cue, ordered after show().
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String channelName = 'app.hibiki.reader/floating_lyric';

  AudioCue cue(int startMs) => AudioCue()
    ..id = startMs
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = 'cue-$startMs'
    ..text = 'cue $startMs'
    ..startMs = startMs
    ..endMs = startMs + 1000
    ..audioFileIndex = 0;

  Audiobook ab(String key) => Audiobook()
    ..bookKey = key
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

  void installPlatform() {
    const MethodChannel sessionCh =
        MethodChannel('com.ryanheise.audio_session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sessionCh, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sessionCh, null);
    });
    final JustAudioPlatform prev = JustAudioPlatform.instance;
    JustAudioPlatform.instance = _FakePlatform();
    addTearDown(() => JustAudioPlatform.instance = prev);
  }

  late List<MethodCall> nativeCalls;

  setUp(() {
    nativeCalls = <MethodCall>[];
    FloatingLyricChannel.platformOverride = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(channelName),
      (MethodCall call) async {
        nativeCalls.add(call);
        switch (call.method) {
          case 'canDrawOverlays':
          case 'show':
          case 'isShowing':
            return true;
          default:
            return null;
        }
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
    FloatingLyricChannel.clearEventHandlers();
    FloatingLyricChannel.platformOverride = null;
  });

  AudiobookSession makeSession({
    required bool floatingOn,
    int contextLines = 0,
  }) {
    return AudiobookSession(
      audioHandler: () => null,
      showFloatingLyric: () => floatingOn,
      showMediaNotification: () => false,
      floatingLyricContextLines: () => contextLines,
      floatingLyricStyle: () => const FloatingLyricStyle(
        fontSize: 16,
        textColor: 0,
        bgColor: 0,
        buttonTextColor: 0,
        buttonBgColor: 0,
        highlightColor: 0,
        activeColor: 0,
      ),
      floatingLyricClickLookup: () => false,
      onFloatingLyricLookup: (_, __) {},
      controlStreams: AudioControlStreams(
        playStream: const Stream<void>.empty(),
        seekStream: const Stream<Duration>.empty(),
        skipNextStream: const Stream<void>.empty(),
        skipPreviousStream: const Stream<void>.empty(),
        toggleFloatingLyricStream: const Stream<void>.empty(),
      ),
    );
  }

  SessionPersistCallbacks persist() => SessionPersistCallbacks(
        onPositionWrite: (_, __) async {},
        onDelayPersist: (_) async {},
        onSpeedPersist: (_) async {},
        onVolumePersist: (_) async {},
        onImagePausePersist: (_) async {},
        onFollowAudioPersist: (_) async {},
      );

  Future<AudiobookSession> startedSession({
    required bool floatingOn,
    required List<AudioCue> cues,
    int positionMs = 0,
    int contextLines = 0,
    required String audioName,
  }) async {
    installPlatform();
    final AudiobookSession session =
        makeSession(floatingOn: floatingOn, contextLines: contextLines);
    addTearDown(session.dispose);
    await session.start(
      info: SessionBookInfo(
        bookKey: 'a',
        audiobook: ab('a'),
        title: 'Book a',
        mediaIdentifier: 'hoshi://book/a',
      ),
      audioFiles: <File>[makeFile(audioName)],
      prefs: SessionPrefs(
        followAudio: true,
        delayMs: 0,
        speed: 1.0,
        positionMs: positionMs,
        imagePauseSec: 0,
        volume: 1.0,
      ),
      persist: persist(),
      cues: cues,
    );
    return session;
  }

  test(
    'starting the overlay pushes the current cue via updateText, after show '
    '(seeds the native prefs replay)',
    () async {
      await startedSession(
        floatingOn: true,
        cues: <AudioCue>[cue(0), cue(1000), cue(2000)],
        positionMs: 1000,
        audioName: 'hibiki-lyric-seed.mp3',
      );

      // Observed call order on host:
      //   canDrawOverlays, updateText, setPlaybackState, show, updateStyle,
      //   setClickLookupEnabled, updateLabels, updateText, setPlaybackState
      // The controller's listener (_onControllerChanged -> _syncFloatingLyric)
      // fires an EARLY updateText during load/setChapterCues, before show();
      // _startBackgroundSurfaces then fires another updateText after show().
      // On the real Android path BOTH early and post-show pushes hit a service
      // that may not exist yet, which is exactly why the fix persists the line
      // on EVERY updateText. The contract that protects the prefs replay is:
      // there is an updateText carrying the current cue ordered after show().
      final int showIndex =
          nativeCalls.indexWhere((MethodCall c) => c.method == 'show');
      final int postShowUpdateIndex = nativeCalls.indexWhere(
          (MethodCall c) => c.method == 'updateText', showIndex + 1);

      expect(showIndex, isNonNegative, reason: 'show must be called');
      expect(postShowUpdateIndex, isNonNegative,
          reason: 'an updateText carrying the current cue must follow show '
              '(so the native prefs replay has a real value to seed the first '
              'frame). An order regression that drops the post-show push would '
              'fail here.');

      final MethodCall update = nativeCalls[postShowUpdateIndex];
      final Map<Object?, Object?> args =
          update.arguments as Map<Object?, Object?>;
      expect(args['text'], 'cue 1000',
          reason: 'the cue at positionMs=1000 is the current line seeded '
              'on the first frame');
    },
  );

  test('updateText is not emitted when the floating overlay is disabled',
      () async {
    await startedSession(
      floatingOn: false,
      cues: <AudioCue>[cue(0)],
      audioName: 'hibiki-lyric-seed-off.mp3',
    );
    expect(nativeCalls.any((MethodCall c) => c.method == 'updateText'), isFalse,
        reason: 'no updateText should be pushed when the overlay is off');
  });

  // TODO-708 P4 T4: 默认 N=0 = 零变化守卫。_syncFloatingLyric 走原单行分支——
  // updateText 只携带当前行文本 + 无行标记 (-1, 0)，与今天逐字节等价（原生据此退化为
  // 单行渲染，无中间行明暗）。任何回归把 N=0 也灌多行/带真实区间都会在这里挂。
  test('N=0 keeps single-line updateText with no-line-marker range (-1, 0)',
      () async {
    await startedSession(
      floatingOn: true,
      contextLines: 0,
      cues: <AudioCue>[cue(0), cue(1000), cue(2000)],
      positionMs: 1000,
      audioName: 'hibiki-lyric-n0.mp3',
    );
    final int showIndex =
        nativeCalls.indexWhere((MethodCall c) => c.method == 'show');
    final int postShowUpdateIndex = nativeCalls.indexWhere(
        (MethodCall c) => c.method == 'updateText', showIndex + 1);
    final MethodCall update = nativeCalls[postShowUpdateIndex];
    final Map<Object?, Object?> args =
        update.arguments as Map<Object?, Object?>;
    expect(args['text'], 'cue 1000',
        reason: 'N=0 still pushes only the current line');
    expect(args['currentLineStart'], -1,
        reason: 'N=0 must carry no-line-marker start (-1)');
    expect(args['currentLineLength'], 0,
        reason: 'N=0 must carry no-line-marker length (0)');
    expect(args['text'], isNot(contains('\n')),
        reason: 'N=0 payload must remain single-line');
  });

  // TODO-708 P4: N>0 = 多行块 + 当前行真实区间。current line = 'cue 1000' 位于
  // 'cue 0\ncue 1000\ncue 2000' 的 offset 6，长度 8。
  test('N=1 pushes a 3-line context block with the real current-line range',
      () async {
    await startedSession(
      floatingOn: true,
      contextLines: 1,
      cues: <AudioCue>[cue(0), cue(1000), cue(2000)],
      positionMs: 1000,
      audioName: 'hibiki-lyric-n1.mp3',
    );
    final int showIndex =
        nativeCalls.indexWhere((MethodCall c) => c.method == 'show');
    final int postShowUpdateIndex = nativeCalls.indexWhere(
        (MethodCall c) => c.method == 'updateText', showIndex + 1);
    final MethodCall update = nativeCalls[postShowUpdateIndex];
    final Map<Object?, Object?> args =
        update.arguments as Map<Object?, Object?>;
    expect(args['text'], 'cue 0\ncue 1000\ncue 2000');
    expect(args['currentLineStart'], 6);
    expect(args['currentLineLength'], 'cue 1000'.length);
  });
}

class _FakePlatform extends JustAudioPlatform {
  _FakePlayer? player;
  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    player = _FakePlayer(request.id);
    return player!;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    await player?.dispose(DisposeRequest());
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    await player?.dispose(DisposeRequest());
    return DisposeAllPlayersResponse();
  }
}

class _FakePlayer extends AudioPlayerPlatform {
  _FakePlayer(super.id);
  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  void emit(int ms, ProcessingStateMessage state, {required bool playing}) {
    _events.add(PlaybackEventMessage(
      processingState: state,
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
    emit(request.initialPosition?.inMilliseconds ?? 0,
        ProcessingStateMessage.ready,
        playing: false);
    return LoadResponse(duration: const Duration(seconds: 100));
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();
  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();
  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    emit(request.position?.inMilliseconds ?? 0, ProcessingStateMessage.ready,
        playing: false);
    return SeekResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();
  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
              SetAutomaticallyWaitsToMinimizeStallingRequest request) async =>
          SetAutomaticallyWaitsToMinimizeStallingResponse();
  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
              SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest
                  request) async =>
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();
  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();
  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(
          SetPreferredPeakBitRateRequest request) async =>
      SetPreferredPeakBitRateResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();
  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();
  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
          SetSkipSilenceRequest request) async =>
      SetSkipSilenceResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();
  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(
          SetWebCrossOriginRequest request) async =>
      SetWebCrossOriginResponse();
  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    if (!_events.isClosed) await _events.close();
    return DisposeResponse();
  }
}
