// native/fushi_web_core（adblock-rust C ABI）的真实 FFI 调用测试。
//
// 库定位：环境变量 FUSHI_WEB_CORE_LIB，缺省用本仓 native/fushi_web_core/prebuilt/<平台>/ 下
// 构建脚本的产物。库不可用时整组 skip 并打印原因（CI 用输出里的 'native library not found'
// 断言没有被静默跳过，与 packages/fushi_p2p / fushi_srs 同一约定）。
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_web_core/fushi_web_core.dart';
import 'package:test/test.dart';

/// 本仓构建脚本的默认产物路径（相对 packages/fushi_web_core）。
String _defaultPrebuiltPath() {
  final String sep = Platform.pathSeparator;
  final String root = '..$sep..${sep}native${sep}fushi_web_core${sep}prebuilt';
  if (Platform.isWindows)
    return '$root${sep}windows-x64${sep}fushi_web_core.dll';
  if (Platform.isMacOS) return '$root${sep}macos${sep}libfushi_web_core.dylib';
  return '$root${sep}linux-x64${sep}libfushi_web_core.so';
}

String _libraryPath() {
  final String? env = Platform.environment[kFushiWebCoreLibEnv];
  if (env != null && env.isNotEmpty) return env;
  return File(_defaultPrebuiltPath()).absolute.path;
}

const String _list = '''
! Title: fushi test list
||ads.example.com^
||tracker.example.net^\$third-party
/banner/*\$image
@@||ads.example.com/allowed/*
example.com##.ad-banner
example.com###sponsor
##.generic-ad
example.com#@#.generic-ad
''';

void main() {
  final String path = _libraryPath();
  final FushiWebCoreLibrary? lib = FushiWebCoreLibrary.tryLoad(
    libraryPath: path,
  );
  if (lib == null) {
    // ignore: avoid_print
    print('fushi_web_core native library not found at $path; skipping');
  }
  final Object? skip = lib == null ? 'native library not found: $path' : null;

  group('FushiAdblockEngine (real native library)', () {
    late FushiAdblockEngine engine;

    setUp(() {
      engine = FushiAdblockEngine.load(<String>[_list], library: lib);
    });

    tearDown(() => engine.dispose());

    test('version is non-empty', () {
      expect(lib!.version(), isNotEmpty);
    });

    test('blocks listed domain, allows others', () {
      expect(
        engine.check(
          'https://ads.example.com/x.js',
          sourceUrl: 'https://news.test/',
          type: AdblockRequestType.script,
        ),
        AdblockDecision.block,
      );
      expect(
        engine.check(
          'https://ok.example.com/x.js',
          sourceUrl: 'https://news.test/',
          type: AdblockRequestType.script,
        ),
        AdblockDecision.allow,
      );
    });

    test('third-party and request-type options', () {
      expect(
        engine.check(
          'https://tracker.example.net/p.gif',
          sourceUrl: 'https://news.test/',
          type: AdblockRequestType.image,
        ),
        AdblockDecision.block,
      );
      expect(
        engine.check(
          'https://tracker.example.net/p.gif',
          sourceUrl: 'https://tracker.example.net/',
          type: AdblockRequestType.image,
        ),
        AdblockDecision.allow,
      );
      expect(
        engine.check(
          'https://site.test/banner/a.js',
          sourceUrl: 'https://site.test/',
          type: AdblockRequestType.script,
        ),
        AdblockDecision.allow,
      );
    });

    test('exception rule reported as exception (allowed)', () {
      final AdblockCheckResult r = engine.checkDetailed(
        'https://ads.example.com/allowed/a.js',
        sourceUrl: 'https://news.test/',
        type: AdblockRequestType.script,
      );
      expect(r.decision, AdblockDecision.exception);
      expect(r.decision.shouldBlock, isFalse);
    });

    test('invalid url is error, not a crash', () {
      expect(engine.check('not a url'), AdblockDecision.error);
    });

    test('cosmetic + generic selectors', () {
      final AdblockCosmeticResources c = engine.cosmetic(
        'https://example.com/page',
      );
      expect(c.hideSelectors, containsAll(<String>['.ad-banner', '#sponsor']));
      expect(c.exceptions, contains('.generic-ad'));
      expect(
        engine.genericSelectors(
          classes: <String>['generic-ad'],
          exceptions: c.exceptions,
        ),
        isEmpty,
      );
      final AdblockCosmeticResources other = engine.cosmetic(
        'https://other.test/',
      );
      expect(other.hideSelectors, isNot(contains('.ad-banner')));
      expect(
        engine.genericSelectors(
          classes: <String>['generic-ad'],
          exceptions: other.exceptions,
        ),
        <String>['.generic-ad'],
      );
    });

    test('serialize / deserialize round trip', () {
      final Uint8List bytes = engine.serialize();
      expect(bytes, isNotEmpty);
      final FushiAdblockEngine restored = FushiAdblockEngine.deserialize(
        bytes,
        library: lib,
      );
      addTearDown(restored.dispose);
      expect(
        restored.check(
          'https://ads.example.com/x.js',
          sourceUrl: 'https://news.test/',
          type: AdblockRequestType.script,
        ),
        AdblockDecision.block,
      );
    });

    test('corrupt serialized data throws AdblockEngineException', () {
      expect(
        () => FushiAdblockEngine.deserialize(
          Uint8List.fromList(<int>[1, 2, 3]),
          library: lib,
        ),
        throwsA(isA<AdblockEngineException>()),
      );
    });

    test('use after dispose throws StateError', () {
      final FushiAdblockEngine e = FushiAdblockEngine.load(<String>[
        _list,
      ], library: lib);
      e.dispose();
      e.dispose(); // 幂等
      expect(() => e.check('https://ads.example.com/'), throwsStateError);
    });

    test('content blocking rules export', () {
      final List<Map<String, Object?>> rules =
          FushiAdblockEngine.contentBlockingRules(<String>[
            _list,
          ], library: lib);
      expect(rules, isNotEmpty);
      final Iterable<Object?> types = rules.map(
        (Map<String, Object?> r) =>
            (r['action'] as Map<String, Object?>)['type'],
      );
      expect(types, contains('block'));
      expect(types, contains('css-display-none'));
    });
  }, skip: skip);

  group('AdblockEngineLoader (real native library)', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('fwc_loader_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('compiles in background, caches engine, reuses cache', () async {
      int fetches = 0;
      final AdblockFilterListService lists = AdblockFilterListService(
        cacheDir: tmp,
        fetcher: (Uri url, {String? etag, String? lastModified}) async {
          fetches++;
          return const AdblockFetchResponse(statusCode: 200, body: _list);
        },
      );
      final AdblockEngineLoader loader = AdblockEngineLoader(
        listService: lists,
        library: lib,
      );
      final AdblockFilterList list = AdblockFilterList(
        id: 'test',
        title: 'Test',
        url: Uri.parse('https://lists.test/test.txt'),
      );

      final AdblockEngineBundle? first = await loader.load(<AdblockFilterList>[
        list,
      ], withContentBlockingRules: true);
      expect(first, isNotNull);
      expect(first!.fromEngineCache, isFalse);
      expect(first.contentBlockingRules, isNotEmpty);
      expect(
        first.engine.check(
          'https://ads.example.com/x.js',
          sourceUrl: 'https://news.test/',
          type: AdblockRequestType.script,
        ),
        AdblockDecision.block,
      );
      first.engine.dispose();

      final AdblockEngineBundle? second = await loader.load(<AdblockFilterList>[
        list,
      ], withContentBlockingRules: true);
      expect(second!.fromEngineCache, isTrue);
      expect(second.contentBlockingRules, isNotEmpty);
      expect(fetches, 1, reason: 'fresh cache must not hit the network');
      expect(
        second.engine.check(
          'https://ads.example.com/x.js',
          sourceUrl: 'https://news.test/',
          type: AdblockRequestType.script,
        ),
        AdblockDecision.block,
      );
      second.engine.dispose();
    });
  }, skip: skip);
}
