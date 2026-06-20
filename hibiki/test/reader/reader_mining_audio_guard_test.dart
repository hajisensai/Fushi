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
      // TODO-644 / BUG-357：sentenceOffset 现在经 await 前快照局部值传入（消除并发
      // 查词在 extractAudioSegment 的 await 处改写 _cachedSentenceOffset 的 race）。
      // 快照仍源自 JS 的 _cachedSentenceOffset，语义不变。
      expect(
        source,
        contains('final int? snapshotSentenceOffset = _cachedSentenceOffset'),
        reason:
            'AnkiMiningContext.sentenceOffset must be snapshotted from the JS '
            '_cachedSentenceOffset BEFORE the extractAudioSegment await, so a '
            'concurrent lookup cannot overwrite it mid-prepare.',
      );
      expect(
        source,
        contains('sentenceOffset: snapshotSentenceOffset'),
        reason:
            'AnkiMiningContext.sentenceOffset is consumed as a sentence-local '
            'character offset; it must read the pre-await snapshot, not the '
            'shared mutable member.',
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
        contains('final AudioPlaybackRange? clip = miningSentenceAudioRange('),
        reason:
            'Card sentence audio must resolve the selected sentence to a full '
            'audio range, not export only the lookup cue.',
      );
      // TODO-393：句子音频区间解析下沉到参数化 helper _sentenceAudioRangeFor，当前句
      // 经 _currentSentenceAudioRange 把 _cachedSentenceRange 的 offset/length 传进去。
      expect(
        source,
        contains('sentenceNormCharOffset: normOffset'),
        reason:
            'The parametrized helper takes the sentence normalized offset; the '
            'current-sentence path feeds _cachedSentenceRange?.offset into it.',
      );
      expect(
        source,
        contains('normOffset: _cachedSentenceRange?.offset'),
        reason:
            'The cached JS sentence range is the strongest signal for the full '
            'current-sentence audio span.',
      );
      expect(
        source,
        contains('normLength: _cachedSentenceRange?.length'),
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

    test('does not gate sentence audio on a non-null lookup cue (BUG-172)', () {
      final String source = File(
        'lib/src/pages/implementations/reader_hibiki_page.dart',
      ).readAsStringSync();

      // Audiobook cue alignment leaves gaps: a word can fall in covered-but-
      // uncued text so _lookupCue is null while the sentence is still spanned by
      // surrounding cues. The mining gate must not require a cue; it must try the
      // sentence-span range whenever audio files exist.
      expect(
        source,
        isNot(contains('if (cue != null && audioFiles != null) {')),
        reason:
            'Gating sentence audio on `cue != null` silently drops sentence '
            'audio for gap words; resolve by sentence span instead.',
      );
      expect(
        source,
        contains('if (audioFiles != null) {'),
        reason:
            'Sentence-audio mining should attempt a clip whenever audio files '
            'exist and let miningSentenceAudioRange decide if a range is found.',
      );
      expect(
        source,
        contains('if (clip != null &&'),
        reason:
            'miningSentenceAudioRange is now nullable; the reader must null-check '
            'the clip before extracting a segment.',
      );
    });

    test('aborts mining when requested sentence-audio export fails', () {
      final String source = File(
        'lib/src/pages/implementations/reader_hibiki_page.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('bool requestedSentenceAudioClip = false'),
        reason: 'The reader must remember that a real sentence-audio clip was '
            'requested; otherwise ffmpeg failures become silent no-audio cards.',
      );
      expect(
        source,
        contains('requestedSentenceAudioClip = true'),
        reason:
            'The failure guard should only fire after a clip range and output '
            'path were actually chosen.',
      );
      expect(
        source,
        contains(
            'if (requestedSentenceAudioClip && sasayakiAudioPath == null)'),
        reason:
            'A requested but failed sentence-audio export must stop card mining '
            'with a visible error instead of continuing as a success.',
      );
      expect(
        source,
        contains('card_export_failed_detail'),
        reason: 'The stopped path must be user-visible, not just logged.',
      );
      expect(
        source,
        contains('String? sentenceAudioFailure'),
        reason: 'The reader must preserve the ffmpeg failure summary for the '
            'visible no-audio-card guard.',
      );
      expect(
        source,
        contains('onFailure: (String summary)'),
        reason: 'TtsChannel/extractor diagnostics should flow back to the '
            'reader mining path.',
      );
      expect(
        source,
        contains(r'sentence audio export failed: $sentenceAudioFailure'),
        reason:
            'The visible error should include executable/fallback/0xC000007B '
            'details instead of a generic no-audio message.',
      );

      final int guardIndex = source.indexOf(
        'if (requestedSentenceAudioClip && sasayakiAudioPath == null)',
      );
      final int mineIndex = source.indexOf('outcome = await repo.mineEntry');
      expect(guardIndex, greaterThanOrEqualTo(0));
      expect(mineIndex, greaterThan(guardIndex));
    });
  });
}
