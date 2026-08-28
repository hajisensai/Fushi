import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';

void main() {
  late Directory root;
  late File file;
  int now = 1_000_000;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-aidoku-cookies-');
    file = File('${root.path}/nested/cookies.json');
    now = 1_000_000;
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  AidokuCookieJar jar() => AidokuCookieJar(file, clock: () => now);

  group('AidokuCookie', () {
    test('matches the registered domain and its subdomains only', () {
      const AidokuCookie cookie = AidokuCookie(
        name: 'cf_clearance',
        value: 'x',
        domain: '.MangaFire.to',
      );
      expect(cookie.canonicalDomain, 'mangafire.to');
      expect(cookie.matchesHost('mangafire.to'), isTrue);
      expect(cookie.matchesHost('img.mangafire.to'), isTrue);
      expect(cookie.matchesHost('MANGAFIRE.TO'), isTrue);
      expect(cookie.matchesHost('notmangafire.to'), isFalse);
      expect(cookie.matchesHost('mangafire.to.evil'), isFalse);
      expect(cookie.matchesHost(''), isFalse);
    });

    test('round-trips through JSON with a canonical domain', () {
      const AidokuCookie cookie = AidokuCookie(
        name: 'a',
        value: 'b',
        domain: '.example.test',
        path: '/x',
        secure: true,
        expiresAt: 42,
      );
      final AidokuCookie restored = AidokuCookie.fromJson(
        jsonDecode(jsonEncode(cookie.toJson())) as Map<String, Object?>,
      );
      expect(restored.name, 'a');
      expect(restored.value, 'b');
      expect(restored.domain, 'example.test');
      expect(restored.path, '/x');
      expect(restored.secure, isTrue);
      expect(restored.expiresAt, 42);
    });
  });

  group('AidokuCookieJar', () {
    test('persists replaced cookies and reloads them from disk', () async {
      final AidokuCookieJar first = jar();
      await first.replaceForHost('mangafire.to', const <AidokuCookie>[
        AidokuCookie(name: 'cf_clearance', value: 'ok', domain: 'mangafire.to'),
        AidokuCookie(name: 'session', value: 's', domain: '.mangafire.to'),
      ]);
      expect(await file.exists(), isTrue, reason: 'parent dir is created');

      final AidokuCookieJar second = jar();
      await second.ensureLoaded();
      expect(second.cookies.length, 2);
      expect(
        second.cookieHeaderFor(Uri.parse('https://static.mangafire.to/a.jpg')),
        'cf_clearance=ok; session=s',
      );
      expect(second.cookieHeaderFor(Uri.parse('https://other.test/')), isNull);
      expect(
        second.hasClearanceFor(Uri.parse('https://mangafire.to/filter')),
        isTrue,
      );
    });

    test(
      'replaceForHost only touches the domains that host belongs to',
      () async {
        final AidokuCookieJar store = jar();
        await store.replaceForHost('a.test', const <AidokuCookie>[
          AidokuCookie(name: 'cf_clearance', value: 'old', domain: 'a.test'),
        ]);
        await store.replaceForHost('b.test', const <AidokuCookie>[
          AidokuCookie(name: 'cf_clearance', value: 'b', domain: 'b.test'),
        ]);
        await store.replaceForHost('a.test', const <AidokuCookie>[
          AidokuCookie(name: 'cf_clearance', value: 'new', domain: 'a.test'),
          // 不属于 a.test 的条目不能借道混进来。
          AidokuCookie(name: 'cf_clearance', value: 'evil', domain: 'c.test'),
        ]);
        expect(
          store.cookieHeaderFor(Uri.parse('https://a.test/')),
          'cf_clearance=new',
        );
        expect(
          store.cookieHeaderFor(Uri.parse('https://b.test/')),
          'cf_clearance=b',
        );
        expect(store.cookieHeaderFor(Uri.parse('https://c.test/')), isNull);
      },
    );

    test('expired cookies are neither served nor sent to the host', () async {
      final AidokuCookieJar store = jar();
      await store.replaceForHost('a.test', const <AidokuCookie>[
        AidokuCookie(
          name: 'cf_clearance',
          value: 'x',
          domain: 'a.test',
          expiresAt: 2_000_000,
        ),
        AidokuCookie(name: 'keep', value: 'y', domain: 'a.test'),
      ]);
      expect(store.hasClearanceFor(Uri.parse('https://a.test/')), isTrue);
      now = 2_000_000;
      expect(store.hasClearanceFor(Uri.parse('https://a.test/')), isFalse);
      expect(store.cookieHeaderFor(Uri.parse('https://a.test/')), 'keep=y');

      final Map<String, Object?> payload = store.networkPayload();
      expect(payload['userAgent'], kAidokuUserAgent);
      final List<Object?> cookies = payload['cookies'] as List<Object?>;
      expect(cookies.length, 1);
      expect((cookies.single as Map<String, Object?>)['name'], 'keep');
    });

    test('a corrupt cookie file degrades to an empty jar', () async {
      await file.parent.create(recursive: true);
      await file.writeAsString('{not json');
      final AidokuCookieJar store = jar();
      await store.ensureLoaded();
      expect(store.cookies, isEmpty);
      expect(store.networkPayload()['cookies'], isEmpty);
    });

    test(
      'an undecodable (non-UTF-8) cookie file also degrades to empty',
      () async {
        await file.parent.create(recursive: true);
        // 0xFF 开头不是合法 UTF-8：readAsString 抛 FileSystemException 而非
        // FormatException——同样只算「没 cookie」，不许拦下整个 invoke。
        await file.writeAsBytes(<int>[0xFF, 0xFE, 0x00, 0x9F]);
        final AidokuCookieJar store = jar();
        await store.ensureLoaded();
        expect(store.cookies, isEmpty);
      },
    );

    test('a failed load is retried on the next ensureLoaded call', () async {
      int attempts = 0;
      final AidokuCookieJar store = AidokuCookieJar.lazy(() async {
        attempts++;
        if (attempts == 1) {
          throw const FileSystemException('platform channel not ready');
        }
        return file;
      });
      await expectLater(
        store.ensureLoaded(),
        throwsA(isA<FileSystemException>()),
      );
      // 失败不被备忘：第二次调用重新走加载而不是复放同一个失败。
      await store.ensureLoaded();
      expect(attempts, 2);
    });

    test(
      'clearanceValueFor returns the live cf_clearance value only',
      () async {
        final AidokuCookieJar store = jar();
        await store.replaceForHost('mangafire.to', const <AidokuCookie>[
          AidokuCookie(
            name: 'cf_clearance',
            value: 'v1',
            domain: '.mangafire.to',
          ),
          AidokuCookie(name: 'other', value: 'x', domain: '.mangafire.to'),
        ]);
        expect(
          store.clearanceValueFor(Uri.parse('https://mangafire.to/a')),
          'v1',
        );
        expect(
          store.clearanceValueFor(Uri.parse('https://elsewhere.example/')),
          isNull,
        );
      },
    );
  });
}
