import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'helpers/audiobook_test_harness.dart';

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
      final HangingFakeAudioPlatform platform = installHangingAudioPlatform();

      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);
      final File audioFile =
          createFakeAudioFile('hibiki-audiobook-load-test.mp3');

      await controller.load(
        audiobook: fakeAudiobook(),
        audioFiles: <File>[audioFile],
      ).timeout(const Duration(milliseconds: 200));

      expect(platform.player?.loadCalls ?? 0, 0);
    });

    test('multi-file load does not wait for duration probes', () async {
      final HangingFakeAudioPlatform platform = installHangingAudioPlatform();

      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);
      final List<File> audioFiles = <File>[
        createFakeAudioFile('hibiki-audiobook-load-test-1.mp3'),
        createFakeAudioFile('hibiki-audiobook-load-test-2.mp3'),
      ];

      await controller
          .load(
            audiobook: fakeAudiobook(),
            audioFiles: audioFiles,
          )
          .timeout(const Duration(milliseconds: 200));

      expect(platform.player?.loadCalls ?? 0, 0);
    });

    test('skipToCue works before audio duration is known', () async {
      installHangingAudioPlatform();

      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);
      final File audioFile =
          createFakeAudioFile('hibiki-audiobook-skip-test.mp3');
      final AudioCue cue = _cue(1250);

      await controller.load(
        audiobook: fakeAudiobook(),
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
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = fragmentId ?? 'cue-$startMs'
    ..text = 'cue $startMs'
    ..startMs = startMs
    ..endMs = startMs + 500
    ..audioFileIndex = 0;
}
