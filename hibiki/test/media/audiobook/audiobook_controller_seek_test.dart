import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_controller.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';

void main() {
  group('AudiobookPlayerController cue seek mapping', () {
    test(
        'returns null for an invalid audio file index instead of falling back to the start',
        () {
      final ms = AudiobookPlayerController.globalMsForCueForTesting(
        audioFileIndex: 3,
        startMs: 1250,
        fileOffsets: [0],
      );

      expect(ms, isNull);
    });

    test('adds the selected file offset for valid multi-file cues', () {
      final ms = AudiobookPlayerController.globalMsForCueForTesting(
        audioFileIndex: 1,
        startMs: 1250,
        fileOffsets: [0, 60000],
      );

      expect(ms, 61250);
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
  });
}

AudioCue _cue(int startMs) {
  return AudioCue()
    ..bookUid = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = 'cue-$startMs'
    ..text = 'cue $startMs'
    ..startMs = startMs
    ..endMs = startMs + 500
    ..audioFileIndex = 0;
}
