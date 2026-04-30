import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_controller.dart';

void main() {
  group('AudiobookPlayerController cue seek mapping', () {
    test('returns null for an invalid audio file index instead of falling back to the start', () {
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
  });
}
