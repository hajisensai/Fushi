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

    test('pads card sentence audio before exporting the clip', () {
      final String source = File(
        'lib/src/pages/implementations/reader_hibiki_page.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('final AudioCue clip = miningSentenceAudioClip(cue);'),
        reason:
            'Card sentence audio must use a mining-specific clip window with '
            'a short tail; raw cue.endMs can cut off the final sound.',
      );
      expect(
        source,
        contains('endMs: clip.endMs'),
        reason:
            'The export call must use the padded clip end, not the raw cue end.',
      );
      expect(
        source,
        isNot(contains('endMs: cue.endMs,\n        outputPath: outputPath')),
        reason:
            'Passing raw cue.endMs to extractAudioSegment regresses the cut-off '
            'sentence audio bug.',
      );
    });
  });
}
