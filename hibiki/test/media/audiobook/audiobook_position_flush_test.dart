import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// BUG-032：歌词模式播放中进程被杀，音频进度归零。
///
/// 根因不在控制器本身（load 能正确恢复 savedMs、播放中周期保存也能写出新值，
/// 见下面两条基线），而在「退到后台→被杀」这条生命周期：dispose 的 force-save
/// 在硬杀场景不执行，周期保存又是 fire-and-forget（可能没 commit 就被回收）。
/// 修复给控制器加了一个**可 await 到落库**的 [AudiobookPlayerController.flushPosition]，
/// reader 页在 `didChangeAppLifecycleState(paused/inactive)` 里调用它，把退到
/// 后台那一刻的播放位置写穿。
///
/// 这条测试钉住 flushPosition 的两个关键性质：
///  1) 即使整秒没变也 **force** 写（不被周期节流吞掉）；
///  2) 返回的 Future **await 到写库真正完成**（durability 保证）。
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

  // ── baselines：证明控制器层的恢复 / 周期保存本身没坏 ────────────────────

  test('baseline: load(initialPositionMs) restores position, not 0', () async {
    installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: ab(),
      audioFiles: <File>[makeFile('hibiki-flush-a.mp3')],
      initialPositionMs: 65000,
    );

    expect(c.position.inMilliseconds, 65000);
  });

  test('baseline: priming cues after load must not clobber savedMs with 0',
      () async {
    installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: ab(),
      audioFiles: <File>[makeFile('hibiki-flush-b.mp3')],
      initialPositionMs: 65000,
    );

    final List<int> writes = <int>[];
    c.onPositionWrite = (String uid, int ms) async => writes.add(ms);
    c.setChapterCues(<AudioCue>[cue(60000), cue(65000), cue(70000)]);

    expect(writes, isNot(contains(0)));
  });

  // ── the actual fix ───────────────────────────────────────────────────

  test('flushPosition force-saves the current position even at the same second',
      () async {
    final _FakePlatform plat = installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: ab(),
      audioFiles: <File>[makeFile('hibiki-flush-c.mp3')],
      initialPositionMs: 0,
    );
    c.setChapterCues(<AudioCue>[cue(0), cue(1000), cue(2000), cue(3000)]);

    final List<int> writes = <int>[];
    c.onPositionWrite = (String uid, int ms) async => writes.add(ms);

    await c.play();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Advance playback to 3s: the periodic save persists the position once the
    // whole-second changes (the playing position extrapolates a few ms past).
    plat.player!.emit(3000, ProcessingStateMessage.ready, playing: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(writes.where((int w) => w >= 3000), isNotEmpty,
        reason: 'periodic save must persist advancing playback position');

    // App goes to background within the same whole-second: the periodic save
    // would be throttled (wholeSec unchanged), but flushPosition must still
    // write so a subsequent kill keeps the progress.
    writes.clear();
    await c.flushPosition();
    // Exactly one write, carrying the live position within the same 3s window
    // (the playing position extrapolates a few ms past the emitted 3000).
    expect(writes, hasLength(1),
        reason: 'background flush must write once despite the per-second '
            'throttle');
    expect(writes.single, inInclusiveRange(3000, 3999),
        reason: 'background flush must persist the latest position');
  });

  test('flushPosition awaits the persistence write (durability)', () async {
    installPlatform();
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);

    await c.load(
      audiobook: ab(),
      audioFiles: <File>[makeFile('hibiki-flush-d.mp3')],
      initialPositionMs: 12000,
    );

    final Completer<void> writeStarted = Completer<void>();
    final Completer<void> allowWrite = Completer<void>();
    bool writeFinished = false;
    c.onPositionWrite = (String uid, int ms) async {
      if (!writeStarted.isCompleted) writeStarted.complete();
      await allowWrite.future;
      writeFinished = true;
    };

    final Future<void> flush = c.flushPosition();
    await writeStarted.future;
    expect(writeFinished, isFalse,
        reason: 'flushPosition must not return before the write completes');

    allowWrite.complete();
    await flush;
    expect(writeFinished, isTrue);
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
    await _events.close();
    return DisposeResponse();
  }
}
