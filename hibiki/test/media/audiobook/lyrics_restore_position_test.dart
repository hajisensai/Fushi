import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

// BUG-872 contract guard — 歌词模式重开书高亮跳回开头。
//
// Root cause: AudiobookPlayerController.load() seeks the player to the saved
// position but leaves the derived _currentCue stale. _currentCue is only set by
// the 125ms playback tick (_updateCurrentCue), and load() commonly emits a
// transient posMs~=0 first, so on a paused reopen _currentCue lands on the
// FIRST cue (allBookCueIdx == 0). The old lyrics window read allBookCueIdx
// directly, so it opened on line 0; the first real play tick then jumped to the
// correct line — exactly the reported symptom.
//
// The player *position* is restored correctly to savedMs, so
// cueAtCurrentPositionInBook() is the authoritative source at restore time. The
// fix adds allBookCueIdxAtPosition (purely position-driven, independent of the
// tick-updated _currentCue) and points the lyrics window at it.
//
// This guard pins the controller contract: after loading to a saved position
// while paused, allBookCueIdxAtPosition resolves to the cue spanning that
// position (not the stale line-0 that allBookCueIdx reports).
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

  Future<AudiobookPlayerController> loadedAt({
    required int positionMs,
    required List<AudioCue> cues,
    required String audioName,
  }) async {
    installPlatform();
    final AudiobookPlayerController controller = AudiobookPlayerController();
    addTearDown(controller.dispose);
    controller.setAllBookCues(cues);
    controller.setChapterCues(cues);
    await controller.load(
      audiobook: ab('a'),
      audioFiles: <File>[makeFile(audioName)],
      initialPositionMs: positionMs,
    );
    return controller;
  }

  test(
    'reopen at a saved position: allBookCueIdxAtPosition resolves the current '
    'line even though the live index is a stale line-0',
    () async {
      final AudiobookPlayerController controller = await loadedAt(
        positionMs: 1000,
        cues: <AudioCue>[cue(0), cue(1000), cue(2000)],
        audioName: 'hibiki-lyrics-restore-1.mp3',
      );

      // Bug precondition: the live index is NOT the saved line. A load-time
      // transient (or an absent play tick) leaves _currentCue on the first cue
      // (or unset), so allBookCueIdx cannot be trusted for the restore anchor.
      expect(controller.allBookCueIdx, isNot(1),
          reason: 'the tick-updated live index does not reflect the restored '
              'position yet — this is why the old window jumped to the start');

      // Fix: the position-driven getter reads the restored player position and
      // maps it to the cue spanning it (cue(1000) at index 1).
      expect(controller.allBookCueIdxAtPosition, 1,
          reason: 'the saved position 1000ms falls inside cue(1000), whose '
              'all-book index is 1 — the line the lyrics page must open on');
    },
  );

  test(
    'reopen at position 0: window anchors to the first line',
    () async {
      final AudiobookPlayerController controller = await loadedAt(
        positionMs: 0,
        cues: <AudioCue>[cue(0), cue(1000), cue(2000)],
        audioName: 'hibiki-lyrics-restore-0.mp3',
      );
      expect(controller.allBookCueIdxAtPosition, 0,
          reason: 'position 0 is inside cue(0), index 0');
    },
  );

  test(
    'reopen deep into the book: window anchors to the matching line',
    () async {
      final AudiobookPlayerController controller = await loadedAt(
        positionMs: 2500,
        cues: <AudioCue>[cue(0), cue(1000), cue(2000)],
        audioName: 'hibiki-lyrics-restore-2.mp3',
      );
      expect(controller.allBookCueIdxAtPosition, 2,
          reason: 'position 2500ms falls inside cue(2000) (2000..3000), '
              'all-book index 2');
    },
  );
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
