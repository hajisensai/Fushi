import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// TODO-1037 / BUG-487 (reentrant cross-chapter race). During cross-chapter
/// advance through a standalone image-only chapter, the reader's
/// _pauseThroughImageOnlyChapters navigates each intermediate image chapter to
/// pause on it. Each intermediate chapter load SYNCHRONOUSLY calls
/// notifySectionRestoreCompleted, which previously cleared _chapterTransition
/// and re-ran _updateCurrentCue while audio was still playing (the pause in
/// awaitImageChapterPause only fires after this navigate's await returns) and
/// the cue still pointed at the final text chapter -> _maybeEmitCrossChapter
/// re-fired cross-chapter -> remaining image chapters skipped (the very symptom
/// f3e4d2e52 claimed to fix). Fix: the reader sets setImageChapterPauseActive
/// for the whole pause sequence; notifySectionRestoreCompleted keeps the guard
/// held and skips the recompute while active.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('image-only chapter cross-chapter reentrancy guard (TODO-1037/BUG-487)',
      () {
    test(
        'active sequence: synchronous notify on intermediate image chapter does not reenter cross-chapter',
        () async {
      final AudiobookPlayerController controller =
          await _loadPlayingController();
      final List<int> crossCalls = <int>[];
      controller.onCrossChapter = (int sec) => crossCalls.add(sec);
      controller.getCurrentReaderSection = () => 2;

      controller.holdChapterTransition();
      controller.setImageChapterPauseActive(true);
      expect(controller.chapterTransitionHeldForTesting, isTrue);

      controller.notifySectionRestoreCompleted(
        currentReaderSection: 2,
        success: true,
      );

      expect(crossCalls, isEmpty,
          reason: 'in-flight intermediate load must not reenter cross-chapter');
      expect(controller.chapterTransitionHeldForTesting, isTrue,
          reason: 'guard stays held during the pause sequence');

      controller.dispose();
    });

    test(
        'contrast: when sequence finished (active=false) final navigate still cross-chapters',
        () async {
      final AudiobookPlayerController controller =
          await _loadPlayingController();
      final List<int> crossCalls = <int>[];
      controller.onCrossChapter = (int sec) => crossCalls.add(sec);
      controller.getCurrentReaderSection = () => 2;

      controller.holdChapterTransition();
      controller.setImageChapterPauseActive(true);
      controller.setImageChapterPauseActive(false);

      controller.notifySectionRestoreCompleted(
        currentReaderSection: 2,
        success: true,
      );

      expect(crossCalls, <int>[5],
          reason:
              'reentrant path proven reachable; guard, not dead branch, blocks first case');

      controller.dispose();
    });
  });

  group('reentrancy guard wiring (TODO-1037/BUG-487)', () {
    test('notifySectionRestoreCompleted early-returns while sequence active',
        () {
      final String src = File(
        '../packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart',
      ).readAsStringSync();
      final int notifyIdx = src.indexOf('void notifySectionRestoreCompleted({');
      expect(notifyIdx, greaterThanOrEqualTo(0));
      final int clearIdx =
          src.indexOf('_chapterTransition = false;', notifyIdx);
      final String head = src.substring(notifyIdx, clearIdx);
      expect(head.contains('if (_imageChapterPauseActive) return;'), isTrue,
          reason: 'guard must early-return before clearing _chapterTransition');
    });

    test('reader toggles setImageChapterPauseActive at sequence entry/exit',
        () {
      final String src = File(
        'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
      ).readAsStringSync();
      expect(
          src.contains('controller.setImageChapterPauseActive(true);'), isTrue);
      expect(src.contains('controller.setImageChapterPauseActive(false);'),
          isTrue);
      final int onIdx =
          src.indexOf('controller.setImageChapterPauseActive(true);');
      final int offIdx =
          src.indexOf('controller.setImageChapterPauseActive(false);');
      expect(onIdx >= 0 && offIdx > onIdx, isTrue,
          reason: 'set true at entry, false in finally');
    });
  });
}

Future<AudiobookPlayerController> _loadPlayingController() async {
  _installHangingAudioPlatform();
  final AudiobookPlayerController controller = AudiobookPlayerController();
  final File audioFile = File(
    '${Directory.systemTemp.path}/hibiki-reentrant-1037.mp3',
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
  final List<AudioCue> cues = <AudioCue>[_sasayakiCue(0, section: 5)];
  controller.setAllBookCues(cues);
  controller.setChapterCues(cues);
  controller.followAudio.value = true;
  await controller.play();
  return controller;
}

AudioCue _sasayakiCue(int startMs, {required int section}) {
  return AudioCue()
    ..id = null
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = SasayakiMatchCodec.encodeHit(
      sectionIndex: section,
      normCharStart: 0,
      normCharEnd: 10,
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

_HangingJustAudioPlatform _installHangingAudioPlatform() {
  const MethodChannel audioSessionChannel =
      MethodChannel('com.ryanheise.audio_session');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(audioSessionChannel, (_) async => null);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSessionChannel, null);
  });

  final JustAudioPlatform previousPlatform = JustAudioPlatform.instance;
  final _HangingJustAudioPlatform platform = _HangingJustAudioPlatform();
  JustAudioPlatform.instance = platform;
  addTearDown(() {
    JustAudioPlatform.instance = previousPlatform;
  });
  return platform;
}

class _HangingJustAudioPlatform extends JustAudioPlatform {
  _HangingAudioPlayer? player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    player = _HangingAudioPlayer(request.id);
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
  _HangingAudioPlayer(super.id);

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) {
    return Completer<LoadResponse>().future;
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();

  @override
  Future<SeekResponse> seek(SeekRequest request) async => SeekResponse();

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
