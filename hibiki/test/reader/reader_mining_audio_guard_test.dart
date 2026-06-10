import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reader mining context guard', () {
    test('passes selection sentenceOffset to Anki sentence renderer', () {
      final String source = File(
        'lib/src/pages/implementations/reader_hibiki_page.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('_cachedSentenceOffset'),
        reason:
            'Reader mining must keep the JS sentenceOffset; normalized book '
            'offsets are not valid character positions inside the sentence.',
      );
      expect(
        source,
        contains('_cachedSentenceOffset = data.sentenceOffset'),
        reason:
            'The value passed to AnkiMiningContext.sentenceOffset must come '
            'from ReaderSelectionData.sentenceOffset.',
      );
      expect(
        source,
        contains('sentenceOffset: _cachedSentenceOffset'),
        reason:
            'AnkiMiningContext.sentenceOffset is consumed as a sentence-local '
            'character offset when bolding the mined expression.',
      );
      expect(
        source,
        isNot(contains('sentenceOffset: _cachedSentenceRange?.offset')),
        reason:
            'Whole-book normalized offsets must not be reused as sentence-local '
            'character offsets.',
      );
    });

    test('uses a unique temporary file for every sentence-audio clip', () {
      final String source = File(
        'lib/src/pages/implementations/reader_hibiki_page.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('createTempSync('),
        reason:
            'Sentence-audio mining should not reuse a fixed temp filename that '
            'a later mining request can overwrite before Anki stores it.',
      );
      expect(
        source,
        isNot(contains("'mine_sentence_audio.aac'")),
        reason: 'Fixed mine_sentence_audio.aac reuses one file for all cards.',
      );
    });

    test('exports complete sentence audio range instead of padding one cue',
        () {
      final String source = File(
        'lib/src/pages/implementations/reader_hibiki_page.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('final AudioPlaybackRange clip = miningSentenceAudioRange('),
        reason:
            'Card sentence audio must resolve the selected sentence to a full '
            'audio range, not export only the lookup cue.',
      );
      expect(
        source,
        contains('sentenceNormCharOffset: _cachedSentenceRange?.offset'),
        reason:
            'The cached JS sentence range is the strongest signal for the full '
            'sentence audio span.',
      );
      expect(
        source,
        contains('sentenceNormCharLength: _cachedSentenceRange?.length'),
        reason:
            'Without sentence length, the reader falls back to a single cue and '
            'can cut off sentences split across multiple cues.',
      );
      expect(
        source,
        isNot(contains('kMiningSentenceAudioTailPaddingMs')),
        reason: 'Fixed tail padding is not a complete-sentence range resolver.',
      );
    });

    test('synthesizes TTS sentence audio fallback when no audiobook clip', () {
      final String source = File(
        'lib/src/pages/implementations/reader_hibiki_page.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('shouldSynthesizeSentenceTtsFallback('),
        reason: 'Plain-text books (no audiobook) must fall back to OS TTS for '
            'SentenceAudio instead of leaving the field empty.',
      );
      expect(
        source,
        contains('TtsChannel.instance.ttsToFile('),
        reason:
            'The sentence-audio fallback must synthesize the full sentence via '
            'ttsToFile, mirroring the term-audio TTS fallback.',
      );
    });
  });
}
