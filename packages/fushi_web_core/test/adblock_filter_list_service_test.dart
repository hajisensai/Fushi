// AdblockFilterListService 的纯 Dart 测试：假下载器 + 临时目录，覆盖下载落盘、未过期走缓存、
// 过期条件请求（304 续期）、离线退回缓存、无缓存缺席、HTML 门户页拒收。
@TestOn('vm')
library;

import 'dart:io';

import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:test/test.dart';

class _FakeFetcher {
  final List<({Uri url, String? etag, String? lastModified})> calls =
      <({Uri url, String? etag, String? lastModified})>[];
  AdblockFetchResponse Function(Uri url)? respond;
  Object? throwError;

  Future<AdblockFetchResponse> call(
    Uri url, {
    String? etag,
    String? lastModified,
  }) async {
    calls.add((url: url, etag: etag, lastModified: lastModified));
    final Object? err = throwError;
    if (err != null) throw err;
    return respond!(url);
  }
}

void main() {
  late Directory tmp;
  late _FakeFetcher fetcher;
  late DateTime now;
  late AdblockFilterListService service;
  final AdblockFilterList list = AdblockFilterList(
    id: 'easylist',
    title: 'EasyList',
    url: Uri.parse('https://easylist.to/easylist/easylist.txt'),
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fwc_lists_');
    fetcher = _FakeFetcher();
    now = DateTime.utc(2026, 10, 1, 12);
    service = AdblockFilterListService(
      cacheDir: tmp,
      fetcher: fetcher.call,
      maxAge: const Duration(days: 4),
      clock: () => now,
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('default lists carry the four official URLs', () {
    expect(
      kDefaultAdblockFilterLists.map((AdblockFilterList l) => l.id),
      <String>[
        'easylist',
        'easyprivacy',
        'adguard_chinese',
        'adguard_japanese',
      ],
    );
    for (final AdblockFilterList l in kDefaultAdblockFilterLists) {
      expect(l.url.scheme, 'https');
    }
    expect(adblockFilterListById('easyprivacy')?.title, 'EasyPrivacy');
    expect(adblockFilterListById('nope'), isNull);
  });

  test(
    'downloads, persists, then serves fresh cache without network',
    () async {
      fetcher.respond = (Uri _) => const AdblockFetchResponse(
        statusCode: 200,
        body: '||ads.example.com^\n',
        etag: '"v1"',
      );
      final AdblockListLoadResult first = await service.loadList(list);
      expect(first.source, AdblockListSource.downloaded);
      expect(first.text, contains('ads.example.com'));
      expect(fetcher.calls, hasLength(1));

      now = now.add(const Duration(days: 1));
      final AdblockListLoadResult second = await service.loadList(list);
      expect(second.source, AdblockListSource.cache);
      expect(second.text, first.text);
      expect(fetcher.calls, hasLength(1));
    },
  );

  test('stale cache revalidates with ETag; 304 renews', () async {
    fetcher.respond = (Uri _) => const AdblockFetchResponse(
      statusCode: 200,
      body: '||ads.example.com^\n',
      etag: '"v1"',
      lastModified: 'Wed, 01 Oct 2026 00:00:00 GMT',
    );
    await service.loadList(list);

    now = now.add(const Duration(days: 5));
    fetcher.respond = (Uri _) => const AdblockFetchResponse(statusCode: 304);
    final AdblockListLoadResult r = await service.loadList(list);
    expect(r.source, AdblockListSource.notModified);
    expect(r.text, contains('ads.example.com'));
    expect(fetcher.calls.last.etag, '"v1"');
    expect(fetcher.calls.last.lastModified, 'Wed, 01 Oct 2026 00:00:00 GMT');
    expect(r.info!.fetchedAt, now);

    // 续期后又是新鲜缓存。
    now = now.add(const Duration(days: 1));
    expect((await service.loadList(list)).source, AdblockListSource.cache);
  });

  test('offline falls back to stale cache; force bypasses freshness', () async {
    fetcher.respond = (Uri _) =>
        const AdblockFetchResponse(statusCode: 200, body: '||a.test^\n');
    await service.loadList(list);

    fetcher.throwError = const SocketException('offline');
    final AdblockListLoadResult forced = await service.loadList(
      list,
      force: true,
    );
    expect(forced.source, AdblockListSource.staleCache);
    expect(forced.text, contains('a.test'));
    expect(forced.error, isA<SocketException>());
  });

  test('no cache and offline: missing, does not throw', () async {
    fetcher.throwError = const SocketException('offline');
    final List<AdblockListLoadResult> rs = await service.loadLists(
      <AdblockFilterList>[list],
    );
    expect(rs.single.source, AdblockListSource.missing);
    expect(rs.single.text, isNull);
  });

  test('HTML portal page is rejected, not cached as a list', () async {
    fetcher.respond = (Uri _) => const AdblockFetchResponse(
      statusCode: 200,
      body: '<!DOCTYPE html><html><body>login</body></html>',
    );
    final AdblockListLoadResult r = await service.loadList(list);
    expect(r.source, AdblockListSource.missing);
    expect(await service.readCached(list), isNull);
  });

  test('HTTP error without cache is missing; evict clears disk', () async {
    fetcher.respond = (Uri _) => const AdblockFetchResponse(statusCode: 500);
    expect((await service.loadList(list)).source, AdblockListSource.missing);
    fetcher.respond = (Uri _) =>
        const AdblockFetchResponse(statusCode: 200, body: '||b.test^\n');
    await service.loadList(list, force: true);
    expect(await service.readCached(list), isNotNull);
    await service.evict(list);
    expect(await service.readCached(list), isNull);
    expect(await service.cacheInfo(list), isNull);
  });

  test('engine cache key changes with content and native version', () {
    AdblockListLoadResult r(String text) => AdblockListLoadResult(
      list: list,
      source: AdblockListSource.cache,
      text: text,
    );
    final String a = AdblockEngineLoader.engineCacheKey(
      '0.1.0',
      <AdblockListLoadResult>[r('||a.test^')],
    );
    expect(
      AdblockEngineLoader.engineCacheKey('0.1.0', <AdblockListLoadResult>[
        r('||a.test^'),
      ]),
      a,
    );
    expect(
      AdblockEngineLoader.engineCacheKey('0.1.0', <AdblockListLoadResult>[
        r('||b.test^'),
      ]),
      isNot(a),
    );
    expect(
      AdblockEngineLoader.engineCacheKey('0.2.0', <AdblockListLoadResult>[
        r('||a.test^'),
      ]),
      isNot(a),
    );
  });

  test('library candidates honour explicit path and env var', () {
    final List<String> c = FushiWebCoreLibrary.libraryCandidates(
      libraryPath: '/explicit/lib',
      environment: <String, String>{kFushiWebCoreLibEnv: '/from/env'},
      executablePath: '/app/bin/fushi',
    );
    expect(c.first, '/explicit/lib');
    expect(c[1], '/from/env');
    expect(c.last, FushiWebCoreLibrary.defaultLibraryName());
  });

  test('missing library: tryLoad returns null instead of throwing', () {
    expect(
      FushiWebCoreLibrary.tryLoad(
        libraryPath: '${tmp.path}${Platform.pathSeparator}nope.dll',
        environment: const <String, String>{},
        executablePath: '${tmp.path}${Platform.pathSeparator}app.exe',
      ),
      // 裸名候选可能在系统路径里命中真库（CI 装了的话），所以只断言「不抛」。
      anyOf(isNull, isA<FushiWebCoreLibrary>()),
    );
  });
}
