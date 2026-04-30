import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/sources/reader_ttu_source.dart';

void main() {
  group('ReaderTtuSource font family helpers', () {
    test('normalizes Google font ids and quotes CSS family names', () {
      expect(
        ReaderTtuSource.cssFontFamilyName('Klee_One'),
        '"Klee One"',
      );
    });

    test('builds a valid CSS font-family fallback list', () {
      expect(
        ReaderTtuSource.cssFontFamilyList(['Noto Sans JP', 'Noto Serif JP']),
        '"Noto Sans JP", "Noto Serif JP"',
      );
    });
  });

  group('ReaderTtuSource furigana helpers', () {
    test('normalizes unknown furigana modes to show', () {
      expect(ReaderTtuSource.normalizeFuriganaMode('show'), 'show');
      expect(ReaderTtuSource.normalizeFuriganaMode('partial'), 'partial');
      expect(ReaderTtuSource.normalizeFuriganaMode(''), 'show');
      expect(ReaderTtuSource.normalizeFuriganaMode('invalid'), 'show');
    });

    test('maps furigana modes to TTU styles', () {
      expect(ReaderTtuSource.furiganaModeToStyle('show'), 'partial');
      expect(ReaderTtuSource.furiganaModeToStyle('hide'), 'Hide');
      expect(ReaderTtuSource.furiganaModeToStyle('partial'), 'partial');
      expect(ReaderTtuSource.furiganaModeToStyle('toggle'), 'toggle');
      expect(ReaderTtuSource.furiganaModeToStyle('invalid'), 'partial');
    });
  });
}
