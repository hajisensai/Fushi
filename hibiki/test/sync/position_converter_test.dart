import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/position_converter.dart';

void main() {
  group('parseChaptersJson', () {
    test('parses standard chaptersJson', () {
      final json = jsonEncode([
        {
          'id': 'c1',
          'href': 'ch1.xhtml',
          'mediaType': 'text/html',
          'characters': 1000
        },
        {
          'id': 'c2',
          'href': 'ch2.xhtml',
          'mediaType': 'text/html',
          'characters': 2000
        },
        {
          'id': 'c3',
          'href': 'ch3.xhtml',
          'mediaType': 'text/html',
          'characters': 500
        },
      ]);
      final chapters = parseChaptersJson(json);
      expect(chapters.length, 3);
      expect(chapters[0].characters, 1000);
      expect(chapters[1].characters, 2000);
      expect(chapters[2].characters, 500);
    });
  });

  group('totalCharacterCount', () {
    test('sums all chapters', () {
      final chapters = [
        const ChapterCharInfo(characters: 1000),
        const ChapterCharInfo(characters: 2000),
        const ChapterCharInfo(characters: 500),
      ];
      expect(totalCharacterCount(chapters), 3500);
    });

    test('empty list returns 0', () {
      expect(totalCharacterCount([]), 0);
    });
  });

  group('toExploredCharCount', () {
    final chapters = [
      const ChapterCharInfo(characters: 1000),
      const ChapterCharInfo(characters: 2000),
      const ChapterCharInfo(characters: 500),
    ];

    test('start of first chapter', () {
      expect(
        toExploredCharCount(
            sectionIndex: 0, normCharOffset: 0, chapters: chapters),
        0,
      );
    });

    test('end of first chapter', () {
      expect(
        toExploredCharCount(
            sectionIndex: 0, normCharOffset: 10000, chapters: chapters),
        1000,
      );
    });

    test('middle of first chapter', () {
      expect(
        toExploredCharCount(
            sectionIndex: 0, normCharOffset: 5000, chapters: chapters),
        500,
      );
    });

    test('start of second chapter', () {
      expect(
        toExploredCharCount(
            sectionIndex: 1, normCharOffset: 0, chapters: chapters),
        1000,
      );
    });

    test('middle of second chapter', () {
      expect(
        toExploredCharCount(
            sectionIndex: 1, normCharOffset: 5000, chapters: chapters),
        2000,
      );
    });

    test('end of last chapter', () {
      expect(
        toExploredCharCount(
            sectionIndex: 2, normCharOffset: 10000, chapters: chapters),
        3500,
      );
    });

    test('clamps out-of-range section', () {
      expect(
        toExploredCharCount(
            sectionIndex: 10, normCharOffset: 5000, chapters: chapters),
        3250,
      );
    });

    test('empty chapters returns 0', () {
      expect(
        toExploredCharCount(
            sectionIndex: 0, normCharOffset: 5000, chapters: []),
        0,
      );
    });
  });

  group('fromExploredCharCount', () {
    final chapters = [
      const ChapterCharInfo(characters: 1000),
      const ChapterCharInfo(characters: 2000),
      const ChapterCharInfo(characters: 500),
    ];

    test('0 chars = start of book', () {
      final result =
          fromExploredCharCount(exploredCharCount: 0, chapters: chapters);
      expect(result.sectionIndex, 0);
      expect(result.normCharOffset, 0);
    });

    test('500 chars = middle of first chapter', () {
      final result =
          fromExploredCharCount(exploredCharCount: 500, chapters: chapters);
      expect(result.sectionIndex, 0);
      expect(result.normCharOffset, 5000);
    });

    test('1000 chars = end of first chapter', () {
      final result =
          fromExploredCharCount(exploredCharCount: 1000, chapters: chapters);
      expect(result.sectionIndex, 0);
      expect(result.normCharOffset, 10000);
    });

    test('1500 chars = into second chapter', () {
      final result =
          fromExploredCharCount(exploredCharCount: 1500, chapters: chapters);
      expect(result.sectionIndex, 1);
      expect(result.normCharOffset, 2500);
    });

    test('3000 chars = end of second chapter (boundary)', () {
      final result =
          fromExploredCharCount(exploredCharCount: 3000, chapters: chapters);
      expect(result.sectionIndex, 1);
      expect(result.normCharOffset, 10000);
    });

    test('3001 chars = into third chapter', () {
      final result =
          fromExploredCharCount(exploredCharCount: 3001, chapters: chapters);
      expect(result.sectionIndex, 2);
      expect(result.normCharOffset, closeTo(20, 1));
    });

    test('3500 chars = end of book', () {
      final result =
          fromExploredCharCount(exploredCharCount: 3500, chapters: chapters);
      expect(result.sectionIndex, 2);
      expect(result.normCharOffset, 10000);
    });

    test('beyond total clamps to end', () {
      final result =
          fromExploredCharCount(exploredCharCount: 9999, chapters: chapters);
      expect(result.sectionIndex, 2);
      expect(result.normCharOffset, 10000);
    });

    test('empty chapters returns zero', () {
      final result =
          fromExploredCharCount(exploredCharCount: 100, chapters: []);
      expect(result.sectionIndex, 0);
      expect(result.normCharOffset, 0);
    });
  });

  group('round-trip', () {
    final chapters = [
      const ChapterCharInfo(characters: 1234),
      const ChapterCharInfo(characters: 5678),
      const ChapterCharInfo(characters: 910),
    ];

    test('export then import preserves position approximately', () {
      const originalSection = 1;
      const originalOffset = 7500;

      final charCount = toExploredCharCount(
        sectionIndex: originalSection,
        normCharOffset: originalOffset,
        chapters: chapters,
      );

      final result = fromExploredCharCount(
        exploredCharCount: charCount,
        chapters: chapters,
      );

      expect(result.sectionIndex, originalSection);
      expect((result.normCharOffset - originalOffset).abs(), lessThan(2));
    });
  });
}
