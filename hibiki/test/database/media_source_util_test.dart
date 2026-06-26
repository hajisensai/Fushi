import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  group('normalizeSourceRootPath', () {
    test('local: unifies backslashes to forward slashes', () {
      expect(
        normalizeSourceRootPath(r'C:\media\books', transport: 'local'),
        'C:/media/books',
      );
    });

    test('local: strips a single trailing slash', () {
      expect(
        normalizeSourceRootPath('/srv/media/', transport: 'local'),
        '/srv/media',
      );
    });

    test('local: preserves drive root trailing slash', () {
      expect(normalizeSourceRootPath('C:/', transport: 'local'), 'C:/');
      expect(
        normalizeSourceRootPath('C:\\', transport: 'local'),
        'C:/',
      );
    });

    test('local: preserves POSIX root', () {
      expect(normalizeSourceRootPath('/', transport: 'local'), '/');
    });

    test('network: preserves scheme and trims trailing slash', () {
      expect(
        normalizeSourceRootPath('sftp://host/media/', transport: 'sftp'),
        'sftp://host/media',
      );
      // Scheme separator is not collapsed.
      expect(
        normalizeSourceRootPath('http://host/', transport: 'http'),
        'http://host',
      );
    });

    test('empty input returns empty', () {
      expect(normalizeSourceRootPath('', transport: 'local'), '');
    });
  });

  group('defaultLabelFromRoot', () {
    test('takes the last path segment (local)', () {
      expect(
        defaultLabelFromRoot('/srv/media/Anime', transport: 'local'),
        'Anime',
      );
    });

    test('normalizes backslashes before taking last segment', () {
      expect(
        defaultLabelFromRoot(r'D:\Books\JP', transport: 'local'),
        'JP',
      );
    });

    test('trailing slash does not produce an empty label', () {
      expect(
        defaultLabelFromRoot('/srv/media/Anime/', transport: 'local'),
        'Anime',
      );
    });

    test('network root: last segment after host', () {
      expect(
        defaultLabelFromRoot('sftp://host/share/Video', transport: 'sftp'),
        'Video',
      );
    });

    test('empty input returns empty', () {
      expect(defaultLabelFromRoot('', transport: 'local'), '');
    });
  });

  group('config codec (M0 placeholders, no credentials)', () {
    test('encodeSourceConfig never persists plaintext (returns null in M0)',
        () {
      expect(
        encodeSourceConfig(<String, Object?>{'password': 'secret'}),
        isNull,
      );
    });

    test('decodeSourceConfig returns empty map in M0', () {
      expect(decodeSourceConfig(null), isEmpty);
      expect(decodeSourceConfig('{"k":1}'), isEmpty);
    });
  });
}
