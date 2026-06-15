// TODO-094 S4 source-scan guard for the kanji dictionary routing chain.
//
// S1/S2 (native query_kanji / add_kanji_dict) and S3 (FFI + JNI bindings) are
// merged; S4 is the Dart application layer that actually loads kanji
// dictionaries into the kanji bucket and routes a single-character lookup
// through query_kanji:
//
//   1. `_rebuildDictPathsCache` / `_rebuildDictPathsCacheAsync` must collect
//      `DictionaryType.kanji` paths into a SEPARATE `kanjiPaths` list and pass
//      them to `HoshiDicts.initializeTyped(..., kanjiPaths: ...)` -- NOT fold
//      them into `termPaths` (the pre-S4 behaviour that made kanji dictionaries
//      resolve through the term index).
//   2. `searchDictionary` must query the kanji bucket for a single-kanji lookup
//      and attach the results to the search result.
//   3. The Android popup path (`PopupDbReader.kt`) must emit a real "kanji"
//      type so the dormant "kanji" branch in `HoshiBridge.kt` routes kanji
//      dictionaries to `nativeAddKanjiDict`.
//
// Layer rationale: the real engine reload + kanji query go through a C++ FFI
// engine flutter_test cannot link, and these touch the live Drift DB +
// filesystem. The strongest *landable* guard is a source scan asserting the
// control-flow invariants the routing depends on. A real-device pass (import a
// kanji dictionary, look up a single kanji, see the kanji card) requires the
// FFI library to be recompiled with the S3 kanji exports -- the current dev
// .dll/.so predate them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String appModel;

  setUpAll(() {
    final File f = File('lib/src/models/app_model.dart');
    expect(f.existsSync(), isTrue,
        reason: 'app_model.dart not found at ${f.absolute.path}');
    appModel = f.readAsStringSync();
  });

  /// Extracts the body of a method named [name] using relative brace balance
  /// from its first `{` so unrelated code can't skew the scan.
  String bodyOf(String src, String name) {
    final int sig = src.indexOf(name);
    expect(sig, greaterThanOrEqualTo(0), reason: '$name not found');
    final int open = src.indexOf('{', sig);
    expect(open, greaterThanOrEqualTo(0), reason: 'no { after $name');
    int depth = 0;
    for (int i = open; i < src.length; i++) {
      final String c = src[i];
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return src.substring(open, i + 1);
      }
    }
    fail('unbalanced braces scanning $name');
  }

  group('kanji bucket split (sync + async path-cache rebuild)', () {
    // 分桶逻辑收口到顶层 bucketDictPaths（同步/异步两方法共用）；kanji 仍进自己的桶、
    // 不 fall through 到 term，rebuild 方法把该桶 (b.kanji) 传给 initializeTyped。
    test('bucketDictPaths 把 kanji 收进独立桶（不并进 term，TODO-094 S4）', () {
      final String body = bodyOf(appModel, 'bucketDictPaths(');
      expect(
          body.contains('case DictionaryType.kanji:') &&
              body.contains('kanji.add('),
          isTrue,
          reason: 'bucketDictPaths 的 kanji case 必须加进独立 kanji 桶');
      expect(
          body.contains('case DictionaryType.term:\n'
              '        case DictionaryType.kanji:'),
          isFalse,
          reason:
              'kanji must not fall through to the term case (pre-S4 behaviour)');
    });

    test(
        '_rebuildDictPathsCache passes the kanji bucket to initializeTyped '
        '(not folded into termPaths)', () {
      final String body = bodyOf(appModel, 'void _rebuildDictPathsCache(');
      expect(body.contains('bucketDictPaths('), isTrue,
          reason: 'sync rebuild must bucket via bucketDictPaths');
      expect(body.contains('kanjiPaths: b.kanji'), isTrue,
          reason:
              'initializeTyped must receive the kanji bucket so kanji dicts '
              'load into the kanji index (TODO-094 S4)');
    });

    test(
        '_rebuildDictPathsCacheAsync passes the kanji bucket to initializeTyped',
        () {
      final String body =
          bodyOf(appModel, 'Future<void> _rebuildDictPathsCacheAsync(');
      expect(body.contains('bucketDictPaths('), isTrue,
          reason: 'async rebuild must bucket via bucketDictPaths');
      expect(body.contains('kanjiPaths: b.kanji'), isTrue,
          reason: 'async initializeTyped must receive the kanji bucket');
    });
  });

  /// Slices the source between the [start] signature and the next method
  /// signature [end]. Used for `searchDictionary`, whose named-parameter `{...}`
  /// block defeats simple brace-balance body extraction (the param list closes
  /// the first brace pair before the function body even opens).
  String regionBetween(String src, String start, String end) {
    final int s = src.indexOf(start);
    expect(s, greaterThanOrEqualTo(0), reason: '$start not found');
    final int e = src.indexOf(end, s);
    expect(e, greaterThan(s), reason: '$end not found after $start');
    return src.substring(s, e);
  }

  group('searchDictionary wires the kanji query', () {
    test('searchDictionary computes kanji results and attaches them', () {
      // `_searchRemoteDictionary` is the method immediately after
      // `searchDictionary`, bounding its source region.
      final String body = regionBetween(
          appModel,
          'Future<DictionarySearchResult> searchDictionary(',
          'Future<DictionarySearchResult?> _searchRemoteDictionary(');
      expect(body.contains('queryKanjiForTerm('), isTrue,
          reason: 'searchDictionary must query the kanji bucket for a '
              'single-kanji lookup');
      expect(body.contains('withKanjiResults('), isTrue,
          reason: 'kanji results must be attached to the term result so the '
              'popup data layer carries them (TODO-094 S4)');
      expect(body.contains('kanjiResults: kanjiResults'), isTrue,
          reason: 'a kanji-only lookup (no term match) must still return a '
              'result carrying the kanji card');
    });

    test('queryKanjiForTerm only queries the engine for a single kanji', () {
      final String body =
          bodyOf(appModel, 'List<HoshiKanjiResult> queryKanjiForTerm(');
      expect(body.contains('isSingleKanji('), isTrue,
          reason: 'must gate the engine call on isSingleKanji so multi-char '
              'terms and kana/latin singletons skip the kanji query');
      expect(body.contains('HoshiDicts.instance.queryKanji('), isTrue,
          reason: 'must call the FFI queryKanji for a real single kanji');
    });
  });

  group('Android popup process routes kanji to its own bucket', () {
    test('PopupDbReader maps the kanji type to a real "kanji" bucket', () {
      final File f =
          File('android/app/src/main/java/app/hibiki/reader/PopupDbReader.kt');
      expect(f.existsSync(), isTrue);
      final String src = f.readAsStringSync();
      expect(src.contains('"term", "kanji" -> "term"'), isFalse,
          reason: 'the pre-S4 kanji->term shim must be removed (TODO-094 S4)');
      expect(src.contains('"kanji" -> "kanji"'), isTrue,
          reason: 'the popup DB reader must emit a real "kanji" type so the '
              'kanji bucket is routed to nativeAddKanjiDict');
    });

    test('HoshiBridge routes a "kanji" type to nativeAddKanjiDict', () {
      final File f =
          File('android/app/src/main/java/app/hibiki/reader/HoshiBridge.kt');
      expect(f.existsSync(), isTrue);
      final String src = f.readAsStringSync();
      expect(
          src.contains('"kanji" -> nativeAddKanjiDict(handle, path)'), isTrue,
          reason: 'the kanji branch (no longer dormant) must add to the native '
              'kanji index (TODO-094 S4)');
    });
  });
}
