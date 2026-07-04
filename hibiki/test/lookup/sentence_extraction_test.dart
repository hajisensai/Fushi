// TODO-1030 M0 — guards the pure sentence extractor (sentence_extraction.dart)
// used to trim the Windows UIA foreground-selection context down to one
// sentence for the global-lookup popup.
//
// Two layers:
//   1. behavioural cases — the boundary walk (backward to the preceding
//      delimiter, forward through the terminating delimiter + trailing closers)
//      and the re-based {selStart, selLen} offsets.
//   2. a DOUBLE-SIDED CONSISTENCY guard — the delimiter tables in
//      sentence_extraction.dart MUST stay byte-identical to the reader's DOM
//      sentence walk (hoshiSelection.sentenceDelimiters / trailingSentenceChars
//      in reader_selection_scripts.dart). If the reader ever retunes its
//      sentence boundaries, this test fails until the extractor is re-synced, so
//      the app-external capture can never silently drift from the in-app reader.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/sentence_extraction.dart';

void main() {
  group('extractSentenceAt — boundary walk', () {
    test('isolates the sentence containing the selection (JA)', () {
      // Buffer holds three sentences; the selection is "世界" in the middle one.
      const String text = '前の文です。こんにちは世界。次の文です。';
      final int selStart = text.indexOf('世界');
      final SentenceExtractionResult r =
          extractSentenceAt(text, selStart, '世界'.length);
      expect(r.sentence, 'こんにちは世界。');
      // selStart re-based into the extracted sentence.
      expect(r.sentence.substring(r.selStart, r.selStart + r.selLen), '世界');
    });

    test('sentence begins AFTER the preceding delimiter (delimiter excluded)',
        () {
      const String text = 'A。B';
      final SentenceExtractionResult r = extractSentenceAt(text, 2, 1); // "B"
      expect(r.sentence, 'B');
      expect(r.selStart, 0);
      expect(r.selLen, 1);
    });

    test('terminating delimiter is INCLUDED, with trailing closers', () {
      const String text = 'これはテストです。」あと';
      final int selStart = text.indexOf('テスト');
      final SentenceExtractionResult r =
          extractSentenceAt(text, selStart, 'テスト'.length);
      // The 」 after 。is a trailing closer pulled into the sentence.
      expect(r.sentence, 'これはテストです。」');
    });

    test('no delimiters — whole buffer is one sentence', () {
      const String text = 'ひとつの文だけ';
      final SentenceExtractionResult r = extractSentenceAt(text, 3, 2);
      expect(r.sentence, 'ひとつの文だけ');
      expect(r.selStart, 3);
      expect(r.selLen, 2);
    });

    test('latin sentence with . delimiter', () {
      const String text = 'First one. Second word here. Third.';
      final int selStart = text.indexOf('word');
      final SentenceExtractionResult r =
          extractSentenceAt(text, selStart, 'word'.length);
      expect(r.sentence, 'Second word here.');
      expect(r.sentence.substring(r.selStart, r.selStart + r.selLen), 'word');
    });

    test('leading whitespace after delimiter is trimmed and offsets re-based',
        () {
      const String text = 'A。   BB world.';
      final int selStart = text.indexOf('BB');
      final SentenceExtractionResult r =
          extractSentenceAt(text, selStart, 'BB'.length);
      expect(r.sentence, 'BB world.');
      expect(r.selStart, 0);
      expect(r.selLen, 2);
    });

    test('newline is a sentence boundary', () {
      const String text = 'line one\nselected line\nlast';
      final int selStart = text.indexOf('selected');
      final SentenceExtractionResult r =
          extractSentenceAt(text, selStart, 'selected'.length);
      expect(r.sentence, 'selected line');
    });
  });

  group('extractSentenceAt — defensive clamping', () {
    test('empty buffer returns empty sentence', () {
      final SentenceExtractionResult r = extractSentenceAt('', 0, 0);
      expect(r.sentence, '');
      expect(r.selStart, 0);
      expect(r.selLen, 0);
    });

    test('out-of-range selection is clamped, never throws', () {
      const String text = 'short。text';
      final SentenceExtractionResult r = extractSentenceAt(text, 999, 999);
      expect(r.sentence, 'text');
      expect(r.selStart, 4);
      expect(r.selLen, 0);
    });

    test('negative selStart clamps to 0', () {
      const String text = 'abc def';
      final SentenceExtractionResult r = extractSentenceAt(text, -5, 3);
      expect(r.sentence, 'abc def');
      expect(r.selStart, 0);
    });
  });

  group('double-sided consistency with the reader DOM sentence walk', () {
    test('delimiter tables are byte-identical to reader_selection_scripts.dart',
        () {
      final File readerScripts =
          File('lib/src/reader/reader_selection_scripts.dart');
      expect(readerScripts.existsSync(), isTrue,
          reason: 'reader_selection_scripts.dart must exist to guard against '
              'delimiter drift');
      final String src = readerScripts.readAsStringSync();
      // The reader stores the same two tables as JS string literals. Extract
      // them and assert byte equality with the Dart extractor's constants.
      final String? readerSentence =
          _extractJsStringField(src, 'sentenceDelimiters');
      final String? readerTrailing =
          _extractJsStringField(src, 'trailingSentenceChars');
      expect(readerSentence, isNotNull,
          reason: 'could not locate sentenceDelimiters in reader scripts');
      expect(readerTrailing, isNotNull,
          reason: 'could not locate trailingSentenceChars in reader scripts');
      expect(readerSentence, kSentenceDelimiters,
          reason: 'sentence_extraction.dart kSentenceDelimiters drifted from '
              'the reader; re-sync so app-external capture matches in-app '
              'sentence boundaries');
      expect(readerTrailing, kTrailingSentenceChars,
          reason: 'sentence_extraction.dart kTrailingSentenceChars drifted '
              'from the reader; re-sync the trailing-closer table');
    });
  });
}

/// Pulls the single-quoted string value of a `field: '...'` JS object entry out
/// of the reader script source, then decodes the two JS escape sequences the
/// tables actually use (`\n` / `\r`) into their real control chars so the value
/// can be compared byte-for-byte with the Dart extractor's constants (which hold
/// the real chars). Returns null when the field is not found.
String? _extractJsStringField(String src, String field) {
  final RegExp re = RegExp("$field: '([^']*)'");
  final RegExpMatch? m = re.firstMatch(src);
  final String? raw = m?.group(1);
  if (raw == null) {
    return null;
  }
  return raw.replaceAll(r'\n', '\n').replaceAll(r'\r', '\r');
}
