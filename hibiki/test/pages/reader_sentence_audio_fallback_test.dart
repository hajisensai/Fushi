import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_sentence_audio_fallback.dart';

void main() {
  group('shouldSynthesizeSentenceTtsFallback', () {
    test('real audiobook clip present then no TTS fallback', () {
      expect(
        shouldSynthesizeSentenceTtsFallback(
          realSentenceAudioPath: '/tmp/sentence.aac',
          sentence: '独占欲も強いんでしょうね。',
        ),
        isFalse,
      );
    });

    test('no real clip plus non-empty sentence then synthesize', () {
      expect(
        shouldSynthesizeSentenceTtsFallback(
          realSentenceAudioPath: null,
          sentence: '独占欲も強いんでしょうね。',
        ),
        isTrue,
      );
    });

    test('empty real clip path counts as missing then synthesize', () {
      expect(
        shouldSynthesizeSentenceTtsFallback(
          realSentenceAudioPath: '',
          sentence: '老いぼれども',
        ),
        isTrue,
      );
    });

    test('no real clip plus blank sentence then no TTS', () {
      expect(
        shouldSynthesizeSentenceTtsFallback(
          realSentenceAudioPath: null,
          sentence: '   ',
        ),
        isFalse,
      );
    });
  });
}
