import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/mining_audio_clip.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  group('miningSentenceAudioClip', () {
    test('adds a short tail to card sentence audio exports', () {
      final AudioCue cue = _cue(startMs: 1000, endMs: 2300);

      final AudioCue clip = miningSentenceAudioClip(cue);

      expect(clip.startMs, 1000);
      expect(clip.endMs, 2300 + kMiningSentenceAudioTailPaddingMs);
    });

    test('keeps invalid one-millisecond fallback ranges valid', () {
      final AudioCue cue = _cue(startMs: 5000, endMs: 5001);

      final AudioCue clip = miningSentenceAudioClip(cue);

      expect(clip.startMs, 5000);
      expect(clip.endMs, greaterThan(clip.startMs));
    });

    test('does not mutate the source cue', () {
      final AudioCue cue = _cue(startMs: 1000, endMs: 2300);

      miningSentenceAudioClip(cue);

      expect(cue.endMs, 2300);
    });
  });
}

AudioCue _cue({
  required int startMs,
  required int endMs,
}) {
  return AudioCue()
    ..bookKey = 'book'
    ..chapterHref = 'chapter.xhtml'
    ..sentenceIndex = 0
    ..textFragmentId = '#s0'
    ..text = '吾輩は猫である。'
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}
