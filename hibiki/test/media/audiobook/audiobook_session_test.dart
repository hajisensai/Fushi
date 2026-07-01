import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// TODO-291 阶段2 行为守卫：[AudiobookSession] 是进程级常驻控制器持有者。
/// 钉住：
///  - start 后会话持有控制器（退书可后台听书的地基）；
///  - attachReader 把 WebView 侧回调装到控制器；
///  - detachReader **不 dispose 控制器**（核心：退书音频继续），并把
///    getCurrentReaderSection 复位成 -1（跨章守卫天然不动作）；
///  - cue 变化 attach 期转发给 reader（保正文高亮链路），detach 后不再转发；
///  - start 第二本书顶掉第一本（同一时刻一本会话）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    const MethodChannel ch = MethodChannel('com.ryanheise.audio_session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
    });
    final JustAudioPlatform prev = JustAudioPlatform.instance;
    JustAudioPlatform.instance = _FakePlatform();
    addTearDown(() => JustAudioPlatform.instance = prev);
  }

  setUp(() {
    // 悬浮窗在 host 不可用：override 成不支持，所有悬浮窗调用短路（不打平台通道）。
    FloatingLyricChannel.platformOverride = false;
  });
  tearDown(() {
    FloatingLyricChannel.platformOverride = null;
  });

  AudiobookSession makeSession() {
    return AudiobookSession(
      audioHandler: () => null,
      showFloatingLyric: () => false,
      showMediaNotification: () => false,
      floatingLyricContextLines: () => 0,
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

  SessionPrefs prefs() => const SessionPrefs(
        followAudio: true,
        delayMs: 0,
        speed: 1.0,
        positionMs: 0,
        imagePauseSec: 0,
        volume: 1.0,
      );

  SessionPersistCallbacks persist() => SessionPersistCallbacks(
        onPositionWrite: (_, __) async {},
        onDelayPersist: (_) async {},
        onSpeedPersist: (_) async {},
        onVolumePersist: (_) async {},
        onImagePausePersist: (_) async {},
        onFollowAudioPersist: (_) async {},
      );

  Future<AudiobookSession> startedSession(
    String key, {
    List<AudioCue> cues = const <AudioCue>[],
    int positionMs = 0,
  }) async {
    installPlatform();
    final AudiobookSession session = makeSession();
    addTearDown(session.dispose);
    await session.start(
      info: SessionBookInfo(
        bookKey: key,
        audiobook: ab(key),
        title: 'Book $key',
        mediaIdentifier: 'hoshi://book/$key',
      ),
      audioFiles: <File>[makeFile('hibiki-session-$key.mp3')],
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

  test('start holds a live controller and book metadata', () async {
    final AudiobookSession session = await startedSession('a');
    expect(session.isActive, isTrue);
    expect(session.controller, isNotNull);
    expect(session.book?.bookKey, 'a');
  });

  test('start loads cues so currentCue resolves without a reader (TODO-354)',
      () async {
    // 后台听书（书架开悬浮字幕）无 reader 喂 cue。把 cue 随 start 传入后，控制器应在
    // load 后立即按当前位置解析 currentCue（悬浮窗首帧有字），无需进 reader。
    final AudiobookSession session = await startedSession(
      'a',
      cues: <AudioCue>[cue(0), cue(1000), cue(2000)],
      positionMs: 1000,
    );
    final AudiobookPlayerController c = session.controller!;
    expect(c.chapterCueCount, 3, reason: 'cue 应灌进控制器供跳句/解析');
    expect(c.currentCue, isNotNull, reason: '无 reader 也应解析出 currentCue（首帧有字）');
    expect(c.currentCue?.startMs, 1000,
        reason: 'currentCue 应对应 initialPositionMs=1000 那一句');
  });

  test('start without cues leaves the controller cue-less (reader path)',
      () async {
    // 不传 cue（reader 自己接管 cue 加载）时不动控制器，保留既有逻辑。
    final AudiobookSession session = await startedSession('a');
    final AudiobookPlayerController c = session.controller!;
    expect(c.chapterCueCount, 0);
    expect(c.currentCue, isNull);
  });

  test('attachReader wires the controller WebView callbacks to the reader',
      () async {
    final AudiobookSession session = await startedSession('a');
    final _FakeReader reader = _FakeReader(section: 3);
    session.attachReader(reader);

    final AudiobookPlayerController c = session.controller!;
    expect(c.getCurrentReaderSection?.call(), 3,
        reason: 'attach 后跨章判定参照系应是 reader 当前章');
    expect(c.onCrossChapter, isNotNull);
    expect(c.onBoundarySkip, isNotNull);
    expect(session.hasReaderAttached, isTrue);
  });

  test('detachReader keeps the controller alive (background listening core)',
      () async {
    final AudiobookSession session = await startedSession('a');
    final _FakeReader reader = _FakeReader(section: 3);
    session.attachReader(reader);

    final AudiobookPlayerController before = session.controller!;
    session.detachReader(reader);

    // 核心：detach 不 dispose 控制器，会话仍活（音频继续播）。
    expect(session.isActive, isTrue);
    expect(identical(session.controller, before), isTrue);
    expect(session.hasReaderAttached, isFalse);
    // getCurrentReaderSection 复位成 -1：跨章守卫 currentSec<0 分支天然不跨章。
    expect(before.getCurrentReaderSection?.call(), -1);
    expect(before.onCrossChapter, isNull);
    expect(before.onBoundarySkip, isNull);
  });

  test('cue change forwards to reader while attached, stops after detach',
      () async {
    final AudiobookSession session = await startedSession('a');
    final _FakeReader reader = _FakeReader(section: 0);
    session.attachReader(reader);

    final AudiobookPlayerController c = session.controller!;
    c.setChapterCues(<AudioCue>[cue(0), cue(1000), cue(2000)]);
    c.debugUpdateCueForPosition(1000);
    expect(reader.cueChangedCount, greaterThan(0),
        reason: 'attach 期 cue 变化应转发 reader 接 WebView 高亮');

    final int attachedCount = reader.cueChangedCount;
    session.detachReader(reader);
    c.debugUpdateCueForPosition(2000);
    expect(reader.cueChangedCount, attachedCount,
        reason: 'detach 后 cue 变化不再转发 reader（无 WebView 可动）');
  });

  test('starting a second book stops the first (single active session)',
      () async {
    final AudiobookSession session = await startedSession('a');
    final AudiobookPlayerController first = session.controller!;

    await session.start(
      info: SessionBookInfo(
        bookKey: 'b',
        audiobook: ab('b'),
        title: 'Book b',
        mediaIdentifier: 'hoshi://book/b',
      ),
      audioFiles: <File>[makeFile('hibiki-session-b.mp3')],
      prefs: prefs(),
      persist: persist(),
    );

    expect(session.book?.bookKey, 'b');
    expect(identical(session.controller, first), isFalse,
        reason: '切书应顶掉旧控制器换新');
  });

  test('stop disposes the controller and clears the session', () async {
    final AudiobookSession session = await startedSession('a');
    await session.stop();
    expect(session.isActive, isFalse);
    expect(session.controller, isNull);
    expect(session.book, isNull);
  });
}

class _FakeReader implements ReaderAudiobookView {
  _FakeReader({required this.section});

  int section;
  int cueChangedCount = 0;
  final List<int> crossChapterCalls = <int>[];

  @override
  int getCurrentReaderSection() => section;

  @override
  Future<void> onCueCrossChapter(int sectionIndex) async {
    crossChapterCalls.add(sectionIndex);
  }

  @override
  Future<void> onBoundarySkip(int delta) async {}

  @override
  void onReaderCueChanged() {
    cueChangedCount++;
  }
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
