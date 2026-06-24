import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  group('reindexCuesByFileBoundaries', () {
    test('assigns audioFileIndex 1 to cues past the first file boundary', () {
      // File 0 = 0..30000ms, file 1 = 30000..60000ms (single SRT timeline).
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 1000, endMs: 5000),
        _cue(startMs: 29000, endMs: 30000),
        _cue(startMs: 35000, endMs: 40000),
        _cue(startMs: 59000, endMs: 60000),
      ];

      final List<AudioCue> out = reindexCuesByFileBoundaries(
        cues: cues,
        fileDurationsMs: <int>[30000, 30000],
      );

      expect(out[0].audioFileIndex, 0);
      expect(out[1].audioFileIndex, 0);
      // Past the first file: belongs to file 1, timestamps rebased to local time.
      expect(out[2].audioFileIndex, 1);
      expect(out[2].startMs, 5000);
      expect(out[2].endMs, 10000);
      expect(out[3].audioFileIndex, 1);
      expect(out[3].startMs, 29000);
      expect(out[3].endMs, 30000);
    });

    test('leaves cues untouched for a single audio file', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 1000, endMs: 5000),
        _cue(startMs: 90000, endMs: 95000),
      ];

      reindexCuesByFileBoundaries(
        cues: cues,
        fileDurationsMs: <int>[60000],
      );

      expect(cues[0].audioFileIndex, 0);
      expect(cues[0].startMs, 1000);
      expect(cues[1].audioFileIndex, 0);
      expect(cues[1].startMs, 90000);
    });

    test('clamps cues past the last file boundary to the last file', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 65000, endMs: 66000),
      ];

      reindexCuesByFileBoundaries(
        cues: cues,
        fileDurationsMs: <int>[30000, 30000],
      );

      expect(cues[0].audioFileIndex, 1);
      expect(cues[0].startMs, 35000);
    });
  });
}

AudioCue _cue({required int startMs, required int endMs}) {
  return AudioCue()
    ..bookKey = 'book'
    ..chapterHref = 'chapter.xhtml'
    ..sentenceIndex = 0
    ..textFragmentId = '[data-cue-id="0"]'
    ..text = 'x'
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}
