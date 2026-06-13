import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_selection.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  AudioCue cue(int startMs, int endMs, String text) => AudioCue()
    ..startMs = startMs
    ..endMs = endMs
    ..text = text;

  test(
      'selected subtitle cue context combines selected lines in timeline order',
      () {
    final AudioCue? context = buildSelectedSubtitleCueContext(
      cues: <AudioCue>[
        cue(1000, 1800, 'first line'),
        cue(2200, 2800, 'middle line'),
        cue(3200, 4100, 'last line'),
      ],
      selectedStartMs: <int>{3200, 1000},
    );

    expect(context, isNotNull);
    expect(context!.startMs, 1000);
    expect(context.endMs, 4100);
    expect(context.text, 'first line\nlast line');
  });

  test('selected subtitle cue context ignores stale selections', () {
    final AudioCue? context = buildSelectedSubtitleCueContext(
      cues: <AudioCue>[
        cue(500, 900, 'only current cue'),
      ],
      selectedStartMs: <int>{123456},
    );

    expect(context, isNull);
  });
}
