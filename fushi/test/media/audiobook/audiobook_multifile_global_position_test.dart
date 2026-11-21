import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// BUG-2330：多文件有声书的播放位置此前持久化的是 `_player.position`（文件内毫秒）
/// 且不存文件下标，`load()` 又裸 `seek(savedMs)` → 重开恒落文件 0 的同一毫秒；
/// BUG-2328 的开书仲裁一旦选中音频起点，视口也跟着落到错误章。
///
/// 修法：三条落库路径（周期 / flushPosition / stopPlayback）一律存 [globalPosition]
/// 全书毫秒；`load()` 在 [setAllBookCues] 已灌好各文件时长时按 [splitGlobalMs] 拆成
/// （文件下标, 文件内偏移）seek。单文件 / 无对齐数据时全书毫秒 = 文件内毫秒，行为不变。
///
/// 断言口径：`preload: false` 下 load 期的 seek 走 just_audio 的 idle 播放器（假平台
/// 看不到 SeekRequest），所以不钉 seek 参数，钉**可观察结果**——当前位置对应的 cue 落在
/// 哪个文件、播放推进后 flush 落库的是不是全书毫秒。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AudioCue cue(int fileIndex, int startMs) => AudioCue()
    ..id = fileIndex * 100000 + startMs
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = fileIndex * 100 + startMs ~/ 1000
    ..textFragmentId = 'cue-$fileIndex-$startMs'
    ..text = 'cue $fileIndex $startMs'
    ..startMs = startMs
    ..endMs = startMs + 1000
    ..audioFileIndex = fileIndex;

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

  _FakePlatform installPlatform() {
    const MethodChannel ch = MethodChannel('com.ryanheise.audio_session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
    });
    final JustAudioPlatform prev = JustAudioPlatform.instance;
    final _FakePlatform p = _FakePlatform();
    JustAudioPlatform.instance = p;
    addTearDown(() => JustAudioPlatform.instance = prev);
    return p;
  }

  // 文件 0 时长 10s（末 cue endMs）、文件 1 时长 8s。
  List<AudioCue> twoFileCues() => <AudioCue>[
    cue(0, 0),
    cue(0, 9000),
    cue(1, 0),
    cue(1, 7000),
  ];

  test('load() lands a saved global position in the right file when cues '
      'were primed before load', () async {
    installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    c.setAllBookCues(twoFileCues());
    await c.load(
      audiobook: ab(),
      audioFiles: <File>[
        makeFile('fushi-mf-0.mp3'),
        makeFile('fushi-mf-1.mp3'),
      ],
      initialPositionMs: 13000,
    );

    // 13000ms 全书位置 = 文件 1 的 3000ms：位置驱动的 cue 查找必须落在文件 1
    //（旧实现裸 seek(13000) 落文件 0，查到的是 cue(0, 9000)）。
    final AudioCue? at = c.cueAtCurrentPositionInBook();
    expect(at, isNotNull);
    expect(at!.audioFileIndex, 1);
    expect(at.startMs, 0);
    expect(c.globalPosition.inMilliseconds, 13000);
  });

  test('flushPosition / stopPlayback persist the global position after '
      'playback advanced inside file 1', () async {
    final _FakePlatform plat = installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();

    c.setAllBookCues(twoFileCues());
    await c.load(
      audiobook: ab(),
      audioFiles: <File>[
        makeFile('fushi-mf-2.mp3'),
        makeFile('fushi-mf-3.mp3'),
      ],
      initialPositionMs: 13000,
    );
    c.setChapterCues(twoFileCues());
    final List<int> writes = <int>[];
    c.onPositionWrite = (String uid, int ms) async => writes.add(ms);

    // play 激活假平台：平台 load 带 initialIndex=1 / initialPosition=3000，
    // 之后在文件 1 内推进到 4000ms。
    await c.play();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(plat.player, isNotNull);
    expect(
      plat.player!.loadedIndex,
      1,
      reason: 'platform load must carry the split file index',
    );
    plat.player!.emit(4000, ProcessingStateMessage.ready, playing: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    writes.clear();
    await c.flushPosition();
    expect(writes, hasLength(1));
    // 全书毫秒 = 文件 0 时长 10000 + 文件内 4000（播放中按墙钟外推几毫秒）。
    expect(writes.single, greaterThanOrEqualTo(14000));
    expect(
      writes.single,
      lessThan(15000),
      reason: 'must be global (>=14000), not file-local (~4000)',
    );

    await c.stopPlayback();
    await c.disposeAndRelease();
    expect(
      writes.last,
      greaterThanOrEqualTo(14000),
      reason: 'stop samples the same global position before the reset',
    );
  });

  test('single-file / no-cue books keep global == local (bare seek)', () async {
    installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: ab(),
      audioFiles: <File>[makeFile('fushi-mf-single.mp3')],
      initialPositionMs: 13000,
    );
    expect(c.globalPosition.inMilliseconds, 13000);
    expect(c.fileDurationsMs, isEmpty);
  });

  // BUG-5006（反馈 sGoT-tNpkx）：cue 只估到末句结束，片尾静音 / 音乐不在 cue 里。
  // 进度条用 [totalDuration]（末文件取真实时长），拖动走 [seekGlobalMs]；两者必须同一
  // 口径，否则拖到片尾会被夹回末句结束，显示「3:43 / -0:31」却怎么也拖不进去。
  group('drag into the tail beyond the last cue (BUG-5006)', () {
    test('splitGlobalMs extends only the last file by its real duration', () {
      const List<int> durations = <int>[10000, 8000];
      expect(AudiobookPlayerController.splitGlobalMs(70000, durations), (
        fileIndex: 1,
        offsetMs: 8000,
      ), reason: 'without a known real duration the cue estimate still caps');
      expect(
        AudiobookPlayerController.splitGlobalMs(
          70000,
          durations,
          lastFileDurationMs: 100000,
        ),
        (fileIndex: 1, offsetMs: 60000),
      );
      expect(
        AudiobookPlayerController.splitGlobalMs(
          200000,
          durations,
          lastFileDurationMs: 100000,
        ),
        (fileIndex: 1, offsetMs: 100000),
      );
      // 真实时长比估算短时不缩短时间轴（估算口径是持久化编码，不能被它改小）。
      expect(
        AudiobookPlayerController.splitGlobalMs(9000, const <int>[
          10000,
        ], lastFileDurationMs: 5000),
        (fileIndex: 0, offsetMs: 9000),
      );
      // 非末文件不受影响。
      expect(
        AudiobookPlayerController.splitGlobalMs(
          9500,
          durations,
          lastFileDurationMs: 100000,
        ),
        (fileIndex: 0, offsetMs: 9500),
      );
    });

    test('single-file book: seeking to the slider end reaches the real '
        'file end', () async {
      installPlatform();
      final AudiobookPlayerController c = AudiobookPlayerController();

      // cue 只到 10s，真实文件 100s（假平台 LoadResponse）。
      final List<AudioCue> cues = <AudioCue>[cue(0, 0), cue(0, 9000)];
      c.setAllBookCues(cues);
      await c.load(
        audiobook: ab(),
        audioFiles: <File>[makeFile('fushi-tail-single.mp3')],
      );
      c.setChapterCues(cues);
      await c.play();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await c.pause();

      expect(c.totalDuration.inMilliseconds, 100000);
      await c.seekGlobalMs(95000);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        c.globalPosition.inMilliseconds,
        95000,
        reason: 'must not be clamped back to the last cue end (10000)',
      );
      await c.disposeAndRelease();
    });

    test('multi-file book playing the last file: seek reaches its tail and '
        'totalDuration uses its real length', () async {
      installPlatform();
      final AudiobookPlayerController c = AudiobookPlayerController();

      c.setAllBookCues(twoFileCues());
      await c.load(
        audiobook: ab(),
        audioFiles: <File>[
          makeFile('fushi-tail-mf-0.mp3'),
          makeFile('fushi-tail-mf-1.mp3'),
        ],
        initialPositionMs: 13000,
      );
      c.setChapterCues(twoFileCues());
      await c.play();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await c.pause();

      // 文件 0 按 cue 估算 10000 + 文件 1 真实 100000。
      expect(c.totalDuration.inMilliseconds, 110000);
      await c.seekGlobalMs(70000);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.currentFilePosition.fileIndex, 1);
      expect(c.globalPosition.inMilliseconds, 70000);
      await c.disposeAndRelease();
    });
  });

  // HBK-AUDIT-036：冷启动时平台还没载入任何文件，末文件真实时长不可知。旧实现在
  // load() 里按 cue 估算（末句结束）夹存档，片尾静音 / 音乐里的存档被拽回末句。
  group('cold start resumes into the last file tail (HBK-AUDIT-036)', () {
    test('splitGlobalMs keeps the last-file offset when clampLastFile is '
        'false', () {
      const List<int> durations = <int>[10000, 8000];
      expect(
        AudiobookPlayerController.splitGlobalMs(
          70000,
          durations,
          clampLastFile: false,
        ),
        (fileIndex: 1, offsetMs: 60000),
      );
      // 非末文件仍按估算拆分，不受影响。
      expect(
        AudiobookPlayerController.splitGlobalMs(
          9500,
          durations,
          clampLastFile: false,
        ),
        (fileIndex: 0, offsetMs: 9500),
      );
    });

    test('a saved position in the last file tail survives load() and the '
        'first platform activation', () async {
      final _FakePlatform plat = installPlatform();
      final AudiobookPlayerController c = AudiobookPlayerController();

      // 文件 0 估算 10000、文件 1 估算 8000（末句结束），文件 1 真实 100000。
      // 存档 70000 = 文件 1 的 60000，落在末句之后的片尾里。
      c.setAllBookCues(twoFileCues());
      await c.load(
        audiobook: ab(),
        audioFiles: <File>[
          makeFile('fushi-cold-tail-0.mp3'),
          makeFile('fushi-cold-tail-1.mp3'),
        ],
        initialPositionMs: 70000,
      );
      c.setChapterCues(twoFileCues());

      expect(c.currentFilePosition.fileIndex, 1);
      expect(
        c.currentFilePosition.positionMs,
        60000,
        reason:
            'must not be clamped to the last cue end (8000) before the '
            'real duration of the last file is known',
      );
      expect(c.globalPosition.inMilliseconds, 70000);

      await c.play();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(plat.player!.loadedIndex, 1);
      expect(
        plat.player!.loadedPositionMs,
        60000,
        reason: 'the platform must be activated at the saved in-file offset',
      );
      await c.pause();
      expect(c.currentFilePosition.fileIndex, 1);
      // 播放期间 just_audio 按墙钟外推几十毫秒。
      expect(
        c.globalPosition.inMilliseconds,
        inInclusiveRange(70000, 70999),
      );
      expect(c.totalDuration.inMilliseconds, 110000);
      await c.disposeAndRelease();
    });

    test('a saved position beyond the real last-file duration is capped at '
        'the real end once the platform reports it', () async {
      final _FakePlatform plat = installPlatform();
      final AudiobookPlayerController c = AudiobookPlayerController();

      c.setAllBookCues(twoFileCues());
      await c.load(
        audiobook: ab(),
        audioFiles: <File>[
          makeFile('fushi-cold-over-0.mp3'),
          makeFile('fushi-cold-over-1.mp3'),
        ],
        // 文件 1 的 150000，超出真实时长 100000（音频被换短 / 存档越界）。
        initialPositionMs: 160000,
      );
      c.setChapterCues(twoFileCues());

      await c.play();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await c.pause();
      expect(plat.player!.loadedPositionMs, 150000);
      expect(c.activationRestorePendingForTesting, isFalse);
      expect(c.currentFilePosition.fileIndex, 1);
      expect(
        c.currentFilePosition.positionMs,
        100000,
        reason: 'the upper bound is the real duration reported by the platform',
      );
      await c.disposeAndRelease();
    });
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

/// 与 audiobook_position_flush_test 的替身同款，另记平台 load 带来的 initialIndex 并
/// 把当前文件下标回放进事件流的 currentIndex（just_audio 的 `currentIndex` 只认事件里
/// 的值）。
class _FakePlayer extends AudioPlayerPlatform {
  _FakePlayer(super.id);
  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  int? loadedIndex;
  int? loadedPositionMs;
  int _currentIndex = 0;
  bool _disposed = false;

  void emit(int ms, ProcessingStateMessage state, {required bool playing}) {
    _events.add(
      PlaybackEventMessage(
        processingState: state,
        updateTime: DateTime.now(),
        updatePosition: Duration(milliseconds: ms),
        bufferedPosition: Duration(milliseconds: ms),
        duration: const Duration(seconds: 100),
        icyMetadata: null,
        currentIndex: _currentIndex,
        androidAudioSessionId: null,
      ),
    );
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    loadedIndex = request.initialIndex;
    loadedPositionMs = request.initialPosition?.inMilliseconds;
    _currentIndex = request.initialIndex ?? 0;
    emit(
      request.initialPosition?.inMilliseconds ?? 0,
      ProcessingStateMessage.ready,
      playing: false,
    );
    return LoadResponse(duration: const Duration(seconds: 100));
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();
  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();
  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    if (request.index != null) _currentIndex = request.index!;
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
  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    if (_disposed) return DisposeResponse();
    _disposed = true;
    await _events.close();
    return DisposeResponse();
  }
}
