import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudiobookPlayerController cue seek mapping', () {
    test(
        'returns null for an invalid audio file index instead of falling back to the start',
        () {
      final ms = AudiobookPlayerController.positionMsForCueForTesting(
        audioFileIndex: 3,
        startMs: 1250,
        audioFileCount: 1,
      );

      expect(ms, isNull);
    });

    test('uses per-file cue positions for valid multi-file cues', () {
      final ms = AudiobookPlayerController.positionMsForCueForTesting(
        audioFileIndex: 1,
        startMs: 1250,
        audioFileCount: 2,
      );

      expect(ms, 1250);
    });

    test('next cue prefers the tracked cue index over a stale player position',
        () {
      final List<AudioCue> cues = [
        _cue(0),
        _cue(1000),
        _cue(2000),
        _cue(3000),
      ];

      final int? nextIndex = AudiobookPlayerController.nextCueIndexForTesting(
        cues: cues,
        currentCueIndex: 2,
        positionMs: 0,
      );

      expect(nextIndex, 3);
    });

    test('prev cue: with a current cue jumps to the immediately previous one',
        () {
      final List<AudioCue> cues = [_cue(0), _cue(1000), _cue(2000), _cue(3000)];

      final int? prev = AudiobookPlayerController.prevCueIndexForTesting(
        cues: cues,
        currentCueIndex: 2,
        currentCue: cues[2],
        positionMs: 2100,
      );

      expect(prev, 1);
    });

    test('prev cue: at the first cue returns null (chapter boundary)', () {
      final List<AudioCue> cues = [_cue(0), _cue(1000)];

      final int? prev = AudiobookPlayerController.prevCueIndexForTesting(
        cues: cues,
        currentCueIndex: 0,
        currentCue: cues[0],
        positionMs: 100,
      );

      expect(prev, isNull);
    });

    test(
        'prev cue: in a gap (no current cue) jumps to the last cue started '
        'before now', () {
      // _cue(n) spans [n, n+500]; position 1700 falls in the gap after cue 1
      // ([1000,1500]) and before cue 2 starts (2000), so "previous" is index 1.
      final List<AudioCue> cues = [_cue(0), _cue(1000), _cue(2000)];

      final int? prev = AudiobookPlayerController.prevCueIndexForTesting(
        cues: cues,
        currentCueIndex: -1,
        currentCue: null,
        positionMs: 1700,
      );

      expect(prev, 1);
    });

    test('prev cue: before the first cue starts jumps to the first cue', () {
      final List<AudioCue> cues = [_cue(1000), _cue(2000)];

      final int? prev = AudiobookPlayerController.prevCueIndexForTesting(
        cues: cues,
        currentCueIndex: -1,
        currentCue: null,
        positionMs: 200,
      );

      expect(prev, 0);
    });

    test('prev cue: empty cue list returns null', () {
      final int? prev = AudiobookPlayerController.prevCueIndexForTesting(
        cues: const <AudioCue>[],
        currentCueIndex: -1,
        currentCue: null,
        positionMs: 0,
      );

      expect(prev, isNull);
    });

    test(
        'prev cue: a current cue absent from the list falls through to the '
        'position search', () {
      // currentCue is set but its fragmentId is not in cues and the tracked
      // index is stale (-1): the faithful fallthrough must use the position
      // search (→ index 1 at pos 1700), not a boundary/first-cue shortcut.
      final List<AudioCue> cues = [_cue(0), _cue(1000), _cue(2000)];
      final AudioCue orphan = _cue(9999); // fragmentId 'cue-9999' not in cues

      final int? prev = AudiobookPlayerController.prevCueIndexForTesting(
        cues: cues,
        currentCueIndex: -1,
        currentCue: orphan,
        positionMs: 1700,
      );

      expect(prev, 1);
    });

    test('all-book cue lookup does not collapse duplicate selectors', () {
      final List<AudioCue> cues = [
        _cue(0, id: 1, fragmentId: ''),
        _cue(1000, id: 2, fragmentId: ''),
        _cue(2000, id: 3, fragmentId: ''),
      ];
      final AudioCue current = _cue(1000, id: 2, fragmentId: '');

      final int index = AudiobookPlayerController.allBookCueIndexForTesting(
        allBookCues: cues,
        currentCue: current,
      );

      expect(index, 1);
    });

    test('load does not wait for platform preload to finish', () async {
      final _HangingJustAudioPlatform platform = _installHangingAudioPlatform();

      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);
      final File audioFile =
          File('${Directory.systemTemp.path}/hibiki-audiobook-load-test.mp3');
      if (!audioFile.existsSync()) {
        audioFile.writeAsBytesSync(const <int>[0]);
      }
      addTearDown(() {
        if (audioFile.existsSync()) audioFile.deleteSync();
      });

      await controller.load(
        audiobook: _audiobook(),
        audioFiles: <File>[audioFile],
      ).timeout(const Duration(milliseconds: 200));

      expect(platform.player?.loadCalls ?? 0, 0);
    });

    test('multi-file load does not wait for duration probes', () async {
      final _HangingJustAudioPlatform platform = _installHangingAudioPlatform();

      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);
      final List<File> audioFiles = <File>[
        File('${Directory.systemTemp.path}/hibiki-audiobook-load-test-1.mp3'),
        File('${Directory.systemTemp.path}/hibiki-audiobook-load-test-2.mp3'),
      ];
      for (final File audioFile in audioFiles) {
        if (!audioFile.existsSync()) {
          audioFile.writeAsBytesSync(const <int>[0]);
        }
      }
      addTearDown(() {
        for (final File audioFile in audioFiles) {
          if (audioFile.existsSync()) audioFile.deleteSync();
        }
      });

      await controller
          .load(
            audiobook: _audiobook(),
            audioFiles: audioFiles,
          )
          .timeout(const Duration(milliseconds: 200));

      expect(platform.player?.loadCalls ?? 0, 0);
    });

    test('skipToCue works before audio duration is known', () async {
      _installHangingAudioPlatform();

      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);
      final File audioFile =
          File('${Directory.systemTemp.path}/hibiki-audiobook-skip-test.mp3');
      if (!audioFile.existsSync()) {
        audioFile.writeAsBytesSync(const <int>[0]);
      }
      addTearDown(() {
        if (audioFile.existsSync()) audioFile.deleteSync();
      });
      final AudioCue cue = _cue(1250);

      await controller.load(
        audiobook: _audiobook(),
        audioFiles: <File>[audioFile],
      );
      controller.setChapterCues(<AudioCue>[cue]);
      await controller.skipToCue(cue);

      expect(controller.currentCue, same(cue));
      expect(controller.currentCueIdx, 0);
    });
  });
}

AudioCue _cue(
  int startMs, {
  int? id,
  String? fragmentId,
}) {
  return AudioCue()
    ..id = id
    ..bookUid = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = fragmentId ?? 'cue-$startMs'
    ..text = 'cue $startMs'
    ..startMs = startMs
    ..endMs = startMs + 500
    ..audioFileIndex = 0;
}

Audiobook _audiobook() {
  return Audiobook()
    ..bookUid = 'book'
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
  int loadCalls = 0;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) {
    loadCalls++;
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
