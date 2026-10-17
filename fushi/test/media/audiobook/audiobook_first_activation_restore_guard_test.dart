import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// BUG-3496：有声书播放中正文被拽回第 1 章、高亮「小学館eBooks」（全书第一句）。
///
/// `load()` 以 `preload: false` 设源，「恢复上次播放位置」的 seek 只记在 just_audio
/// 的空闲播放器上；平台真正载入发生在第一次 play，恢复点作为 `initialPosition`
/// 交给平台。Windows / Linux 的 just_audio_media_kit 载入时先把位置清零、按挂起的
/// 播放请求从 0 起播，等 mpv 报出时长后才 seek 到 initialPosition
/// （`MediaKitPlayer.load` / `stream.duration` 监听）。这段窗口里 positionStream
/// 一路报 0：当前句解析成全书第一句，按过播放、跟随开着，于是请求跨章到第 1 章。
///
/// 下面的假平台按 media_kit 的载入契约行事（[_MediaKitLikePlayer]），断言首次播放
/// 的载入窗口里当前句始终是恢复点那句、不请求跨章、不把瞬态位置落库，平台落到
/// 恢复点后照常跟读。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const int restoreMs = 65000;

  AudioCue cue(int sentence, int startMs, int endMs, String fragment) =>
      AudioCue()
        ..bookKey = 'book'
        ..chapterHref = 'srt://default'
        ..sentenceIndex = sentence
        ..textFragmentId = fragment
        ..text = 'cue $sentence'
        ..startMs = startMs
        ..endMs = endMs
        ..audioFileIndex = 0;

  late _MediaKitLikePlatform platform;
  late File audio;

  setUp(() {
    const MethodChannel session = MethodChannel('com.ryanheise.audio_session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(session, (MethodCall call) async => null);
    final JustAudioPlatform previous = JustAudioPlatform.instance;
    platform = _MediaKitLikePlatform();
    JustAudioPlatform.instance = platform;
    audio = File('${Directory.systemTemp.path}/hibiki-first-activation.m4b')
      ..writeAsBytesSync(const <int>[0]);
    addTearDown(() {
      JustAudioPlatform.instance = previous;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(session, null);
      if (audio.existsSync()) audio.deleteSync();
    });
  });

  Future<AudiobookPlayerController> loadAtRestorePoint(
    List<AudioCue> cues,
  ) async {
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);
    c.setAllBookCues(cues);
    await c.load(
      audiobook: Audiobook()
        ..bookKey = 'book'
        ..audioPaths = const <String>[]
        ..audioRoot = null
        ..alignmentFormat = 'srt'
        ..alignmentPath = '',
      audioFiles: <File>[audio],
      initialPositionMs: restoreMs,
    );
    c.setChapterCues(cues);
    return c;
  }

  test('first play keeps the restored cue through the platform load window '
      'and never cross-chapters to the book start', () async {
    final AudioCue bookStart = cue(0, 0, 8896, 'fushi-cue://s=1&ns=0&ne=9');
    final AudioCue restored = cue(
      4700,
      restoreMs - 1000,
      restoreMs + 4000,
      'fushi-cue://s=31&ns=100&ne=120',
    );
    final AudioCue next = cue(
      4701,
      restoreMs + 4000,
      restoreMs + 9000,
      'fushi-cue://s=31&ns=120&ne=140',
    );
    final AudiobookPlayerController c = await loadAtRestorePoint(<AudioCue>[
      bookStart,
      restored,
      next,
    ]);
    final List<int> crossChapterRequests = <int>[];
    c.getCurrentReaderSection = () => 31;
    c.onCrossChapter = crossChapterRequests.add;
    final List<int> seenSentences = <int>[];
    c.addListener(() {
      final AudioCue? current = c.currentCue;
      if (current != null) seenSentences.add(current.sentenceIndex);
    });
    expect(
      c.currentCue,
      same(restored),
      reason: 'the paused open resolves the restore point',
    );

    // 对外读口（进度条 / 悬浮字幕 / 歌词入场锚定）在窗口里也只看得到恢复点。
    final List<int> sampledPositions = <int>[];
    final List<int?> sampledBookCues = <int?>[];
    final Timer sampler = Timer.periodic(const Duration(milliseconds: 30), (_) {
      sampledPositions.add(c.position.inMilliseconds);
      sampledBookCues.add(c.cueAtCurrentPositionInBook()?.sentenceIndex);
      sampledBookCues.add(c.displayCueForFloatingLyric?.sentenceIndex);
    });
    addTearDown(sampler.cancel);

    await c.play().timeout(const Duration(seconds: 10));
    final _MediaKitLikePlayer player = platform.player!;
    await player.landed.future.timeout(const Duration(seconds: 10));
    // 落定后再走几个 125ms tick。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    sampler.cancel();
    expect(
      sampledPositions.where((int ms) => ms < restoreMs - 1000),
      isEmpty,
      reason: 'position exposed during the load window: $sampledPositions',
    );
    expect(sampledBookCues, isNot(contains(0)));

    expect(
      player.ticksNearZeroWhilePlaying,
      greaterThan(0),
      reason: 'the fake must actually reproduce the media_kit load window',
    );
    expect(crossChapterRequests, isEmpty);
    expect(seenSentences, isNot(contains(0)));
    expect(c.currentCue, same(restored));
    // 落点刚到、还没从它往后播满一秒：回退挡板仍在。
    expect(c.activationRestorePendingForTesting, isTrue);

    // 落定后真实推进照常：平台走到下一句，当前句跟上。
    player.jumpTo(restoreMs + 5000);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.currentCue, same(next));
    expect(c.activationRestorePendingForTesting, isFalse);
  });

  test(
    'load-window positions are never persisted as the listening position',
    () async {
      final AudiobookPlayerController c = await loadAtRestorePoint(<AudioCue>[
        cue(0, 0, 8896, 'fushi-cue://s=1&ns=0&ne=9'),
        cue(
          1,
          restoreMs - 1000,
          restoreMs + 4000,
          'fushi-cue://s=31&ns=0&ne=9',
        ),
      ]);
      final List<int> writes = <int>[];
      c.onPositionWrite = (String _, int positionMs) async {
        writes.add(positionMs);
      };
      await c.play().timeout(const Duration(seconds: 10));
      await platform.player!.landed.future.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        writes.where((int ms) => ms < restoreMs - 1000),
        isEmpty,
        reason: 'writes during the load window: $writes',
      );
    },
  );

  group('pure decision: classifyActivationTickForTesting', () {
    ActivationRestoreTick classify({
      bool loading = false,
      int? durationMs = 20000000,
      int fileIndex = 0,
      required int posMs,
      int targetFileIndex = 0,
      int targetMs = restoreMs,
    }) => AudiobookPlayerController.classifyActivationTickForTesting(
      platformLoading: loading,
      durationMs: durationMs,
      currentFileIndex: fileIndex,
      posMs: posMs,
      targetFileIndex: targetFileIndex,
      targetMs: targetMs,
    );

    test('the loading-state echo of initialPosition is not a landing', () {
      expect(
        classify(loading: true, durationMs: null, posMs: restoreMs),
        ActivationRestoreTick.transient,
      );
      expect(
        classify(loading: true, posMs: restoreMs),
        ActivationRestoreTick.transient,
      );
    });

    test('no decoded duration yet means the seek has not been issued', () {
      expect(
        classify(durationMs: null, posMs: restoreMs),
        ActivationRestoreTick.transient,
      );
    });

    test('positions below the target are transient, at the target land', () {
      expect(classify(posMs: 0), ActivationRestoreTick.transient);
      expect(classify(posMs: restoreMs - 100), ActivationRestoreTick.landed);
      expect(classify(posMs: restoreMs + 40), ActivationRestoreTick.landed);
    });

    test('a later audio file counts as landed, an earlier one does not', () {
      expect(
        classify(fileIndex: 3, posMs: 0, targetFileIndex: 2),
        ActivationRestoreTick.landed,
      );
      expect(
        classify(fileIndex: 1, posMs: restoreMs, targetFileIndex: 2),
        ActivationRestoreTick.transient,
      );
    });

    test('a target beyond the decoded duration is unreachable', () {
      expect(
        classify(durationMs: restoreMs - 1, posMs: 0),
        ActivationRestoreTick.unreachable,
      );
    });
  });
}

class _MediaKitLikePlatform extends JustAudioPlatform {
  _MediaKitLikePlayer? player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    player = _MediaKitLikePlayer(request.id);
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

/// 按 just_audio_media_kit 2.1.0 `MediaKitPlayer` 的载入契约行事（`load()` 与
/// `stream.duration` / `stream.position` 监听）：
/// 1. 位置清零、`loading` 立即上报；
/// 2. `open()` 返回后、mpv 真 seek 之前回显一帧「恰为 initialPosition」（仍 loading、
///    时长未知）——审查指出的那一步；
/// 3. 挂起的播放请求让 mpv 从 0 起播：若干 tick 报 0 附近（先 loading，后 ready）；
/// 4. 「时长到了」：此刻才下发 seek，而这一帧事件里的位置还是第 2 步留下的回显值；
/// 5. seek 还没生效时 mpv 再报一帧旧的 0 附近位置；
/// 6. seek 生效，位置从恢复点往后走。
class _MediaKitLikePlayer extends AudioPlayerPlatform {
  _MediaKitLikePlayer(super.id);

  static const Duration _duration = Duration(hours: 6);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  final Completer<void> landed = Completer<void>();
  bool _disposed = false;
  bool _playing = false;
  bool _durationKnown = false;
  ProcessingStateMessage _state = ProcessingStateMessage.idle;
  int _positionMs = 0;

  /// 载入窗口里、已在播放时报出的 0 附近位置次数（证明假平台确实复现了窗口）。
  int ticksNearZeroWhilePlaying = 0;

  void _emit() {
    if (_disposed) return;
    _events.add(
      PlaybackEventMessage(
        processingState: _state,
        updateTime: DateTime.now(),
        updatePosition: Duration(milliseconds: _positionMs),
        bufferedPosition: Duration(milliseconds: _positionMs),
        duration: _durationKnown ? _duration : null,
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  void jumpTo(int positionMs) {
    _positionMs = positionMs;
    _emit();
  }

  Future<void> _step() =>
      Future<void>.delayed(const Duration(milliseconds: 125));

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final int target = request.initialPosition?.inMilliseconds ?? 0;
    // 1.
    _positionMs = 0;
    _state = ProcessingStateMessage.loading;
    _emit();
    await _step();
    // 2. open() 返回后的回显。
    _positionMs = target;
    _emit();
    // 3. mpv 从 0 起播。
    for (int i = 0; i < 6; i++) {
      await _step();
      if (_disposed) return LoadResponse(duration: _duration);
      if (_playing) ticksNearZeroWhilePlaying++;
      if (i == 3) _state = ProcessingStateMessage.ready;
      _positionMs = 40 * i;
      _emit();
    }
    // 4. 时长到达、seek 刚下发，事件里还是回显值。
    await _step();
    _durationKnown = true;
    _positionMs = target;
    _emit();
    // 5. seek 生效前 mpv 的旧 time-pos。
    await _step();
    _positionMs = 280;
    _emit();
    // 6. seek 生效。
    await _step();
    _positionMs = target + 20;
    _emit();
    if (!landed.isCompleted) landed.complete();
    return LoadResponse(duration: _duration);
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _positionMs = request.position?.inMilliseconds ?? 0;
    _emit();
    return SeekResponse();
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _playing = true;
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _playing = false;
    return PauseResponse();
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
    if (_disposed) return DisposeResponse();
    _disposed = true;
    await _events.close();
    return DisposeResponse();
  }
}
