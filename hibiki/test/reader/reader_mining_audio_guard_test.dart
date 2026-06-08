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
  });
}
