// AdblockCore 的 Dart 封装 + 真原生库（找不到库就失败，不 skip：原生库是硬依赖）。
// 业务规则（过期、304、离线回退、白名单解析……）的完整覆盖在 Rust 单测里；这里钉 Dart 侧
// 的粗粒度命令、字节交接、后台 isolate 收尾与快照解析。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:fushi_web_core/testing.dart';
import 'package:test/test.dart';

const String _list = '''
! Title: fushi test list
||ads.example.com^
||tracker.example.net^\$third-party
@@||ads.example.com/allowed/*
example.com##.ad-banner
##.generic-ad
example.com#@#.generic-ad
''';

void main() {
  setUpAll(useDevFushiWebCoreLibrary);

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fwc_core_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  AdblockCore openOnly(String id, {bool contentBlocking = false}) {
    final AdblockCore core = AdblockCore.open(
      tmp.path,
      wantContentBlocking: contentBlocking,
    );
    for (final AdblockCatalogEntry e in AdblockCore.catalog()) {
      core.setListEnabled(e.id, e.id == id);
    }
    return core;
  }

  test('library is a hard dependency and reports its version', () {
    final FushiWebCoreLibrary lib = FushiWebCoreLibrary.instance;
    expect(lib.version(), matches(RegExp(r'^\d+\.\d+\.\d+$')));
    final String sep = Platform.pathSeparator;
    final List<String> c = FushiWebCoreLibrary.libraryCandidates(
      libraryPath: 'explicit',
      environment: <String, String>{kFushiWebCoreLibEnv: 'from-env'},
      executablePath: '${tmp.path}${sep}bin${sep}app',
    );
    final String name = FushiWebCoreLibrary.defaultLibraryName();
    expect(c.first, 'explicit');
    expect(c[1], 'from-env');
    expect(c[2], '${tmp.path}${sep}bin$sep$name');
    expect(c.last, name);
    expect(
      FushiWebCoreLibraryMissing(const <String>['a', 'b']).message,
      allOf(contains('a, b'), contains(kFushiWebCoreLibEnv)),
    );
  });

  test(
    'test hosts find the repository prebuilt; shipped executables do not',
    () {
      final String sep = Platform.pathSeparator;
      final String name = FushiWebCoreLibrary.defaultLibraryName();
      final String platformDir = Platform.isWindows
          ? 'windows-x64'
          : Platform.isMacOS
          ? 'macos'
          : 'linux-x64';
      final Directory repo = Directory.systemTemp.createTempSync('fwc_repo_');
      addTearDown(() => repo.deleteSync(recursive: true));
      final File lib = File(
        '${repo.path}${sep}native${sep}fushi_web_core${sep}prebuilt'
        '$sep$platformDir$sep$name',
      )..createSync(recursive: true);
      final Directory cwd = Directory('${repo.path}${sep}fushi${sep}test')
        ..createSync(recursive: true);

      final List<String> asTest = FushiWebCoreLibrary.libraryCandidates(
        environment: const <String, String>{},
        executablePath: '${sep}sdk${sep}bin${sep}dart',
        currentDirectory: cwd.path,
      );
      expect(asTest[asTest.length - 2], lib.path);
      expect(asTest.last, name);

      final List<String> asApp = FushiWebCoreLibrary.libraryCandidates(
        environment: const <String, String>{},
        executablePath: '${sep}opt${sep}fushi${sep}bin${sep}fushi_server',
        currentDirectory: cwd.path,
      );
      expect(asApp, isNot(contains(lib.path)));
      expect(
        FushiWebCoreLibrary.isTestHost(r'C:\sdk\bin\flutter_tester.exe'),
        isTrue,
      );
      expect(FushiWebCoreLibrary.isTestHost(r'C:\app\fushi.exe'), isFalse);
    },
  );

  test('catalog lists the four built-in filter lists', () {
    final List<AdblockCatalogEntry> c = AdblockCore.catalog();
    expect(c.map((AdblockCatalogEntry e) => e.id), <String>[
      'easylist',
      'easyprivacy',
      'adguard_chinese',
      'adguard_japanese',
    ]);
    expect(c.first.host, 'easylist.to');
  });

  test('sync: plan -> raw bytes -> background finish -> check', () async {
    final AdblockCore core = openOnly('easylist');
    addTearDown(core.close);
    final List<Uri> fetched = <Uri>[];
    final AdblockSnapshot s = await runAdblockSync(
      core,
      fetcher: (Uri url, {String? etag, String? lastModified}) async {
        fetched.add(url);
        return AdblockFetchResponse(
          statusCode: 200,
          body: Uint8List.fromList(utf8.encode(_list)),
          etag: '"v1"',
        );
      },
    );
    expect(fetched, <Uri>[
      Uri.parse('https://easylist.to/easylist/easylist.txt'),
    ]);
    expect(s.status, AdblockEngineStatus.ready);
    expect(s.isActive, isTrue);
    expect(s.ruleCount, greaterThanOrEqualTo(6));
    expect(s.lastUpdatedAt, isNotNull);
    expect(s.lists.first.lastResult, AdblockListResult.downloaded);

    AdblockDecision check(String url, {String page = 'https://news.test/'}) =>
        core.check(
          url,
          sourceUrl: page,
          pageUrl: page,
          type: AdblockRequestType.script,
        );
    expect(check('https://ads.example.com/x.js'), AdblockDecision.block);
    expect(check('https://ok.example.com/x.js'), AdblockDecision.allow);
    expect(
      check('https://ads.example.com/allowed/a.js'),
      AdblockDecision.exception,
    );
    // 非 ASCII 走 utf8.encode 分支，长 URL 触发暂存区扩容。
    expect(check('https://ads.example.com/路径/x.js'), AdblockDecision.block);
    expect(
      check('https://ads.example.com/${'a' * 9000}.js'),
      AdblockDecision.block,
    );
    expect(check('not a url'), AdblockDecision.error);

    core.setAllowlist('news.test');
    expect(check('https://ads.example.com/x.js'), AdblockDecision.allow);
    core.setAllowlist('');
    final AdblockSnapshot off = core.setEnabled(false);
    expect(off.isActive, isFalse);
    expect(check('https://ads.example.com/x.js'), AdblockDecision.allow);
    core.setEnabled(true);

    // 第二次：缓存新鲜、引擎已是最新——不联网也不重编。
    final AdblockSnapshot again = await runAdblockSync(
      core,
      fetcher: (Uri url, {String? etag, String? lastModified}) =>
          throw StateError('must not fetch'),
    );
    expect(again.status, AdblockEngineStatus.ready);
  });

  test(
    'forced update sends conditional headers; offline keeps the cache',
    () async {
      final AdblockCore core = openOnly('easylist');
      addTearDown(core.close);
      await runAdblockSync(
        core,
        fetcher: (Uri url, {String? etag, String? lastModified}) async =>
            AdblockFetchResponse(
              statusCode: 200,
              body: Uint8List.fromList(utf8.encode(_list)),
              etag: '"v1"',
              lastModified: 'Mon, 19 Oct 2026 00:00:00 GMT',
            ),
      );
      String? sentEtag;
      String? sentLm;
      final AdblockSnapshot s = await runAdblockSync(
        core,
        force: true,
        fetcher: (Uri url, {String? etag, String? lastModified}) async {
          sentEtag = etag;
          sentLm = lastModified;
          throw const SocketException('offline');
        },
      );
      expect(sentEtag, '"v1"');
      expect(sentLm, 'Mon, 19 Oct 2026 00:00:00 GMT');
      expect(s.lastSyncOk, isFalse);
      expect(s.status, AdblockEngineStatus.ready);
      expect(s.lists.first.lastResult, AdblockListResult.staleCache);
      expect(s.lists.first.lastError, contains('offline'));
      expect(
        core.check('https://ads.example.com/x.js', pageUrl: 'https://n.test/'),
        AdblockDecision.block,
      );
    },
  );

  test(
    'state survives reopen; engine comes back from the disk cache',
    () async {
      final AdblockCore first = openOnly('easylist');
      await runAdblockSync(
        first,
        fetcher: (Uri url, {String? etag, String? lastModified}) async =>
            AdblockFetchResponse(
              statusCode: 200,
              body: Uint8List.fromList(utf8.encode(_list)),
            ),
      );
      first
        ..setAllowlist('keep.test, *.foo.org')
        ..close();
      final AdblockCore core = AdblockCore.open(tmp.path);
      addTearDown(core.close);
      expect(core.snapshot().allowlistHosts, <String>['keep.test', 'foo.org']);
      expect(core.snapshot().isListEnabled('easylist'), isTrue);
      expect(core.snapshot().isListEnabled('easyprivacy'), isFalse);
      final AdblockSnapshot s = await runAdblockSync(
        core,
        fetcher: (Uri url, {String? etag, String? lastModified}) =>
            throw StateError('fresh cache must not fetch'),
      );
      expect(s.status, AdblockEngineStatus.ready);
      expect(s.fromCache, isTrue);
    },
  );

  test('cosmetic / generic payloads are the JSON handed to the page', () async {
    final AdblockCore core = openOnly('easylist');
    addTearDown(core.close);
    expect(
      core.cosmeticPayload('https://example.com/'),
      isNull,
      reason: 'not ready',
    );
    await runAdblockSync(
      core,
      fetcher: (Uri url, {String? etag, String? lastModified}) async =>
          AdblockFetchResponse(
            statusCode: 200,
            body: Uint8List.fromList(utf8.encode(_list)),
          ),
    );
    final Map<String, Object?> page =
        jsonDecode(core.cosmeticPayload('https://example.com/a')!)
            as Map<String, Object?>;
    expect(page['hideSelectors'], contains('.ad-banner'));
    expect(page['generichide'], isFalse);
    expect(
      core.genericPayload(
        'https://example.com/a',
        classes: 'generic-ad\nfoo',
        ids: '',
      ),
      '[]',
      reason: 'example.com excepts .generic-ad',
    );
    expect(
      core.genericPayload(
        'https://other.test/',
        classes: 'generic-ad\nfoo',
        ids: 'x',
      ),
      '[".generic-ad"]',
    );
    core.setAllowlist('example.com');
    expect(
      core.cosmeticPayload(
        'https://example.com/a',
        pageUrl: 'https://example.com/',
      ),
      isNull,
    );
  });

  test('content blockers only on platforms that asked for them', () async {
    final AdblockCore core = openOnly('easylist', contentBlocking: true);
    addTearDown(core.close);
    await runAdblockSync(
      core,
      fetcher: (Uri url, {String? etag, String? lastModified}) async =>
          AdblockFetchResponse(
            statusCode: 200,
            body: Uint8List.fromList(utf8.encode(_list)),
          ),
    );
    final List<Object?> rules =
        jsonDecode(utf8.decode(core.contentBlockersJson()!)) as List<Object?>;
    expect(rules, isNotEmpty);
    for (final Object? r in rules) {
      final Object? type =
          ((r! as Map<String, Object?>)['action']!
              as Map<String, Object?>)['type'];
      expect(type, anyOf('block', 'ignore-previous-rules'));
    }
  });

  test('closed handle throws instead of touching freed memory', () {
    final AdblockCore core = AdblockCore.open(tmp.path)..close();
    core.close();
    expect(core.snapshot, throwsStateError);
    expect(() => core.check('https://a.test/'), throwsStateError);
  });
}
