import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

void main() {
  group('sanitizeTtuFilename', () {
    test('plain title unchanged', () {
      expect(sanitizeTtuFilename('かがみの孤城'), 'かがみの孤城');
    });

    test('trailing space replaced', () {
      expect(sanitizeTtuFilename('Book '), 'Book~ttu-spc~');
    });

    test('trailing dot replaced', () {
      expect(sanitizeTtuFilename('Book.'), 'Book~ttu-dend~');
    });

    test('asterisk replaced', () {
      expect(sanitizeTtuFilename('Book*Title'), 'Book~ttu-star~Title');
    });

    test('slash URL-encoded', () {
      expect(sanitizeTtuFilename('A/B'), 'A%2FB');
    });

    test('backslash URL-encoded', () {
      expect(sanitizeTtuFilename(r'A\B'), 'A%5CB');
    });

    test('colon URL-encoded', () {
      expect(sanitizeTtuFilename('A:B'), 'A%3AB');
    });

    test('question mark URL-encoded', () {
      expect(sanitizeTtuFilename('A?B'), 'A%3FB');
    });

    test('percent URL-encoded', () {
      expect(sanitizeTtuFilename('50%'), '50%25');
    });

    test('multiple trailing spaces: only last is trailing', () {
      expect(sanitizeTtuFilename('Book  '), 'Book ~ttu-spc~');
    });

    test('multiple trailing dots: only last is trailing', () {
      expect(sanitizeTtuFilename('Book..'), 'Book.~ttu-dend~');
    });

    test('combined special chars', () {
      final result = sanitizeTtuFilename('Book: A/B* ');
      expect(result, contains('%3A'));
      expect(result, contains('%2F'));
      expect(result, contains('~ttu-star~'));
      expect(result, endsWith('~ttu-spc~'));
    });
  });

  group('progressFileName', () {
    test('standard format', () {
      expect(
        progressFileName(1705944232500, 0.35),
        'progress_1_6_1705944232500_0.35.json',
      );
    });
  });

  group('audioBookFileName', () {
    test('standard format', () {
      expect(
        audioBookFileName(1705944232500, 123.45),
        'audioBook_1_6_1705944232500_123.45.json',
      );
    });
  });

  group('parseProgressTimestamp', () {
    test('parses valid filename', () {
      expect(
        parseProgressTimestamp('progress_1_6_1705944232500_0.35.json'),
        1705944232500,
      );
    });

    test('returns null for non-progress file', () {
      expect(parseProgressTimestamp('statistics_1_6_123_456.json'), null);
    });

    test('returns null for malformed name', () {
      expect(parseProgressTimestamp('progress_1_6.json'), null);
    });
  });

  group('statisticsFileName', () {
    test('generates correct aggregated filename', () {
      final stats = [
        TtuStatistics(
          title: 'Book',
          dateKey: '2026-01-01',
          charactersRead: 1000,
          readingTimeSec: 3600,
          minReadingSpeed: 300,
          altMinReadingSpeed: 280,
          lastReadingSpeed: 350,
          maxReadingSpeed: 400,
          lastStatisticModified: 1000000,
        ),
      ];
      final name = statisticsFileName(stats);
      expect(name, startsWith('statistics_1_6_'));
      expect(name, endsWith('_na.json'));
      expect(name, contains('1000000'));
    });

    test('empty list produces zeroed filename', () {
      final name = statisticsFileName([]);
      expect(name, startsWith('statistics_1_6_0_0_'));
      expect(name, endsWith('_na.json'));
    });
  });

  group('detectCoverFormat', () {
    test('detects PNG', () {
      final result = detectCoverFormat([0x89, 0x50, 0x4E, 0x47, 0x00]);
      expect(result.mimeType, 'image/png');
      expect(result.extension, 'png');
    });

    test('detects JPEG by default', () {
      final result = detectCoverFormat([0xFF, 0xD8, 0xFF, 0xE0]);
      expect(result.mimeType, 'image/jpeg');
      expect(result.extension, 'jpeg');
    });

    test('detects WebP', () {
      final result = detectCoverFormat([0x52, 0x49, 0x46, 0x46, 0x00]);
      expect(result.mimeType, 'image/webp');
      expect(result.extension, 'webp');
    });

    test('detects GIF', () {
      final result = detectCoverFormat([0x47, 0x49, 0x46, 0x38, 0x00]);
      expect(result.mimeType, 'image/gif');
      expect(result.extension, 'gif');
    });

    test('detects BMP', () {
      final result = detectCoverFormat([0x42, 0x4D, 0x00, 0x00]);
      expect(result.mimeType, 'image/bmp');
      expect(result.extension, 'bmp');
    });

    test('short bytes fallback to JPEG', () {
      final result = detectCoverFormat([0x00, 0x01]);
      expect(result.mimeType, 'image/jpeg');
    });
  });
}
