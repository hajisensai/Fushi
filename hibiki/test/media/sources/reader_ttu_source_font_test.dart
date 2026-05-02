import 'dart:convert';

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

    test('builds font faces for downloaded recommended fonts', () {
      final fontCss = ReaderTtuSource.customFontCssForEntries(
        [
          {
            'name': 'Klee One',
            'path': r'C:\fonts\KleeOne-Regular.ttf',
            'enabled': true,
          },
          {
            'name': 'Noto Sans JP',
            'path': r'C:\fonts\NotoSansJP-Regular.ttf',
            'enabled': true,
          },
        ],
        fontServerPort: 52061,
      );

      expect(fontCss.fontFamily, '"Klee One", "Noto Sans JP"');
      expect(fontCss.fontFaces, contains('@font-face'));
      expect(fontCss.fontFaces, contains('font-family: "Klee One"'));
      expect(fontCss.fontFaces, contains('font-family: "Noto Sans JP"'));
      expect(fontCss.fontFaces, contains('http://localhost:52061/'));
      expect(fontCss.fontFaces, contains('KleeOne-Regular.ttf'));
      expect(fontCss.fontFaces, contains('NotoSansJP-Regular.ttf'));
    });
  });

  group('ReaderTtuSource TTU settings helpers', () {
    test('enables TTU reading statistics for Hibiki statistics sync', () {
      expect(
        ReaderTtuSource.ttuStatisticsSettingsJs,
        contains('window.localStorage.setItem("statisticsEnabled","1")'),
      );
    });
  });

  group('ReaderTtuSource history parsing', () {
    test('builds shelf items from projected metadata only', () {
      final items = ReaderTtuSource.instance.getItemsFromJson(
        {
          'bookmark': jsonEncode([
            {'dataId': 7, 'exploredCharCount': 50, 'progress': 0.5},
          ]),
          'data': jsonEncode([
            {
              'id': 7,
              'title': 'Fast book',
              'coverImage': 'data:image/png;base64,abc',
              'lastBookOpen': 20,
              'sections': List.filled(1000, 'large body not needed'),
            },
            {
              'id': 8,
              'title': 'Newer book',
              'coverImage': null,
              'lastBookOpen': 30,
            },
          ]),
        },
        52059,
      );

      expect(items.map((item) => item.title), ['Newer book', 'Fast book']);
      expect(items.last.position, 50);
      expect(items.last.duration, 100);
      expect(items.last.mediaIdentifier, contains('id=7'));
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
