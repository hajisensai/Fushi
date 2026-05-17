import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

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
