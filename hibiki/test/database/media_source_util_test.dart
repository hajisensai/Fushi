import 'dart:convert';

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

    test('webdav: URL rootPath keeps scheme, trims trailing slash', () {
      // TODO-1274: WebDAV 来源的 rootPath 即完整集合 URL；归一只去尾斜杠，不动
      // scheme 的 `://`（FS 侧再按需补回集合尾斜杠给 PROPFIND）。
      expect(
        normalizeSourceRootPath(
          'https://dav.example.com/dav/books/',
          transport: 'webdav',
        ),
        'https://dav.example.com/dav/books',
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

    test('webdav URL: last path segment as default label', () {
      expect(
        defaultLabelFromRoot(
          'https://dav.example.com/dav/books',
          transport: 'webdav',
        ),
        'books',
      );
    });

    test('empty input returns empty', () {
      expect(defaultLabelFromRoot('', transport: 'local'), '');
    });
  });

  // TODO-1274: encodeSourceConfig persists ONLY non-sensitive connection params
  // (host/port/username/useTls); it MUST drop any password/privateKey/unknown key
  // (credential red line — secrets go to MediaSourceCredentialStore, never here).
  group('config codec (TODO-1274 connection params, no credentials)', () {
    test('round-trips the allowed connection params', () {
      final String? encoded = encodeSourceConfig(<String, Object?>{
        'host': 'ssh.example.com',
        'port': 2222,
        'username': 'reader',
        'useTls': true,
      });
      expect(encoded, isNotNull);
      final Map<String, Object?> decoded = decodeSourceConfig(encoded);
      expect(decoded['host'], 'ssh.example.com');
      expect(decoded['port'], 2222);
      expect(decoded['username'], 'reader');
      expect(decoded['useTls'], true);
    });

    test('🔴 red line: password / privateKey are stripped, never persisted',
        () {
      final String? encoded = encodeSourceConfig(<String, Object?>{
        'host': 'h',
        'username': 'u',
        'password': 'super-secret',
        'privateKey': '-----BEGIN KEY-----',
      });
      expect(encoded, isNotNull);
      // Neither the raw secret nor its keys may appear in the serialized config.
      expect(encoded, isNot(contains('super-secret')));
      expect(encoded, isNot(contains('password')));
      expect(encoded, isNot(contains('privateKey')));
      final Map<String, Object?> decoded = decodeSourceConfig(encoded);
      expect(decoded.containsKey('password'), isFalse);
      expect(decoded.containsKey('privateKey'), isFalse);
      expect(decoded['host'], 'h');
      expect(decoded['username'], 'u');
    });

    test('empty / only-sensitive config encodes to null (local sources)', () {
      expect(encodeSourceConfig(<String, Object?>{}), isNull);
      expect(
        encodeSourceConfig(<String, Object?>{'password': 'x'}),
        isNull,
        reason: 'a config with only stripped keys is empty -> null',
      );
    });

    test('decodeSourceConfig tolerates null / empty / malformed', () {
      expect(decodeSourceConfig(null), isEmpty);
      expect(decodeSourceConfig(''), isEmpty);
      expect(decodeSourceConfig('not-json'), isEmpty);
      expect(decodeSourceConfig('[1,2,3]'), isEmpty,
          reason: 'non-object top level -> empty map');
    });

    test('encoded config is valid JSON containing only allowed keys', () {
      final String? encoded = encodeSourceConfig(<String, Object?>{
        'host': 'h',
        'port': 21,
        'username': 'u',
        'useTls': false,
        'somethingElse': 'x',
      });
      final Map<String, dynamic> parsed =
          jsonDecode(encoded!) as Map<String, dynamic>;
      expect(
          parsed.keys.toSet(), <String>{'host', 'port', 'username', 'useTls'});
    });
  });
}
