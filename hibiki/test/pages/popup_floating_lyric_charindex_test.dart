import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

/// Behaviour test for the Dart half of the BUG-214 fix: the popup must segment
/// the *tapped* word from the supplied charIndex, instead of always searching
/// from the sentence head.
///
/// popup_main._extractWord delegates the actual segmentation to
/// [JapaneseLanguage.wordFromIndex]. The C++ FFI segmenter (HoshiDicts) is not
/// available on the Dart test host, so wordFromIndex runs in its documented
/// degraded mode where it returns the single tapped character. That degraded
/// path is exactly what proves the regression contract: the *index* is the
/// anchor that decides where the word is cut.
///
/// Before the fix the Android native popup discarded charIndex entirely and
/// fed HoshiDicts the whole sentence, so its longest-match always started at
/// offset 0 ("点哪都查句首"). These assertions pin that wordFromIndex actually
/// consumes the index — different indices yield different anchors, and the
/// out-of-range / negative sentinel falls back to "no per-character word"
/// (which _extractWord maps to a whole-sentence search, matching the system
/// PROCESS_TEXT path).
void main() {
  final JapaneseLanguage language = JapaneseLanguage.instance;

  group('BUG-214 wordFromIndex consumes the tapped charIndex', () {
    const String sentence = '今日は良い天気ですね';

    test('different tap indices anchor on different characters', () {
      // Each tap must resolve to the glyph under the finger, not offset 0.
      final String head = language.wordFromIndex(text: sentence, index: 0);
      final String middle = language.wordFromIndex(text: sentence, index: 4);
      final String later = language.wordFromIndex(text: sentence, index: 7);

      expect(head, isNotEmpty);
      expect(head, equals(sentence[0]),
          reason: 'index 0 anchors on the first glyph');
      expect(middle, equals(sentence[4]),
          reason: 'a mid-sentence tap must anchor mid-sentence, not at the '
              'head — this is the exact regression ("点哪都查句首")');
      expect(later, equals(sentence[7]));
      expect(middle, isNot(equals(head)),
          reason: 'the index must change the result; if it were ignored every '
              'tap would return the same head word');
    });

    test(
        'negative / out-of-range index returns empty so the caller falls '
        'back to the whole sentence', () {
      // _extractWord uses an empty result as the signal to search the full
      // text — this preserves the system PROCESS_TEXT (charIndex == -1) path.
      expect(language.wordFromIndex(text: sentence, index: -1), isEmpty);
      expect(
        language.wordFromIndex(text: sentence, index: sentence.length),
        isEmpty,
      );
      expect(
        language.wordFromIndex(text: sentence, index: sentence.length + 5),
        isEmpty,
      );
    });
  });
}
