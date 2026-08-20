// BUG-171 source-scan guard.
//
// Root cause: deleting a dictionary only updated the Dart-side caches but did
// NOT always rebuild the native fushidicts FFI engine instance, so the deleted
// dictionary's in-memory index stayed loaded and queries kept hitting it until
// the app was restarted (TODO-095 user report).
//
// Two concrete control-flow holes existed:
//   A) `_rebuildDictPathsCache` / `_rebuildDictPathsCacheAsync` only called
//      `FushiDicts.initializeTyped(...)` when at least one path bucket was
//      non-empty. Deleting the LAST dictionary left all buckets empty, so the
//      rebuild was skipped and the stale engine survived.
//   B) `deleteDictionaries()` (delete-all) never touched the engine at all — it
//      cleared Dart caches + files but left every old index loaded natively.
//
// Fix: always rebuild the engine after a dictionary set change (an empty path
// set rebuilds into an empty-but-valid engine, which `searchDictionary` already
// degrades to empty results via the `isInitialized` guard), and make
// `deleteDictionaries` go through that rebuild path.
//
// Layer rationale: the actual reload happens through a C++ FFI engine that
// flutter_test cannot link, and the delete methods are `AppModel` members wired
// to the live Drift DB + filesystem + FFI. The strongest *landable* automated
// guard is therefore a source scan over `app_model.dart` asserting the
// control-flow invariants that the bug violated. A real device pass (delete a
// dictionary, then look the word up without restarting) is still required.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  late String src;

  setUpAll(() {
    final File f = File('lib/src/models/app_model.dart');
    expect(f.existsSync(), isTrue,
        reason: 'app_model.dart not found at ${f.absolute.path}');
    src = f.readAsStringSync();
  });

  /// Extracts the body of a method/function named [name] using relative brace
  /// balance from its first `{` so unrelated code can't skew the scan.
  String bodyOf(String name) {
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
        // 掩掉注释再断言：断言的是**控制流**，注释里出现同名 token 不算数
        // （BUG-1756 的教训：给 deleteDictionary 写的说明性注释里提到
        // `_rebuildDictPathsCache`，让「必须调用它」的断言在代码早已不调用时依旧
        // 绿）。maskComments 是等长掩码，下标仍可直接与原串对齐。
        if (depth == 0) return maskComments(src.substring(open, i + 1));
      }
    }
    fail('unbalanced braces scanning $name');
  }

  test(
      'A: _rebuildDictPathsCache rebuilds the engine even when all path '
      'buckets are empty (deleting the last dictionary must reload)', () {
    final String body = bodyOf('void _rebuildDictPathsCache(');
    expect(body.contains('FushiDicts.initializeTyped'), isTrue,
        reason: 'rebuild must drive the FFI engine');
    // The call to initializeTyped must NOT be gated behind an
    // `isNotEmpty`-style guard that skips the rebuild for an empty path set —
    // that is exactly the hole that left a stale engine after deleting the last
    // dictionary (BUG-171 hole A).
    expect(
      RegExp(r'isNotEmpty\s*\)\s*\{?\s*FushiDicts\.initializeTyped')
          .hasMatch(body.replaceAll(RegExp(r'\s+'), ' ')),
      isFalse,
      reason: 'initializeTyped must run for an empty path set too; an empty '
          'rebuild yields an empty-but-fresh engine so deleting the last '
          'dictionary stops queries from hitting it (BUG-171).',
    );
  });

  test('A2: _rebuildDictPathsCacheAsync also rebuilds unconditionally', () {
    final String body = bodyOf('Future<void> _rebuildDictPathsCacheAsync(');
    expect(body.contains('FushiDicts.initializeTyped'), isTrue);
    expect(
      RegExp(r'isNotEmpty\s*\)\s*\{?\s*FushiDicts\.initializeTyped')
          .hasMatch(body.replaceAll(RegExp(r'\s+'), ' ')),
      isFalse,
      reason: 'async rebuild must not skip initializeTyped on empty path set '
          '(BUG-171).',
    );
  });

  test('B: deleteDictionaries (delete-all) reloads the FFI engine', () {
    final String body = bodyOf('Future<void> deleteDictionaries(');
    expect(body.contains('_rebuildDictPathsCache'), isTrue,
        reason: 'deleting ALL dictionaries must rebuild the engine so no stale '
            'index survives until restart (BUG-171 hole B).');
  });

  test('C: deleteDictionary (single) still reloads the FFI engine', () {
    final String body = bodyOf('Future<void> deleteDictionary(');
    // 引擎重载现在收口在 DictionaryRepository.deleteDictionaryMeta 里
    // （移除 cache + _onCacheRebuild 重载引擎 + 清查词缓存 + 删 DB 行，BUG-1492）。
    expect(body.contains('dictRepo.deleteDictionaryMeta('), isTrue,
        reason: 'deleting a single dictionary must go through the repo so the '
            'engine reloads (and its mmap views are released).');
    // BUG-1756：绕开 repo 直打 DB 的老写法会把 DB 行删掉却不卸载引擎 —— 目录删
    // 不掉、toast 报「删除失败」，但重启后词典已经没了。这条入口必须不存在。
    expect(body.contains('_database.deleteDictionaryMeta('), isFalse,
        reason: 'must NOT bypass the repo: a raw DB delete leaves the engine '
            'holding the dictionary mmap, so the directory delete then fails '
            'while the metadata is already gone (BUG-1756).');
  });

  // ── BUG-1756：撤 meta（= 引擎释放 mmap）必须早于删磁盘目录 ──────────────
  //
  // Windows 上词典的 hash.table / blobs.bin / … 被 native 引擎 MapViewOfFile
  // 常驻映射，view 还活着时 DeleteFileW 一律 ERROR_USER_MAPPED_FILE(1224)。
  // 四个删除入口原先全是「先删目录、后卸载引擎」。
  test('D: deleteDictionary 先撤 meta（引擎重载）再删目录', () {
    final String body = bodyOf('Future<void> deleteDictionary(');
    final int meta = body.indexOf('dictRepo.deleteDictionaryMeta(');
    final int dir = body.indexOf('deleteDictionaryDirectory(');
    expect(meta, greaterThanOrEqualTo(0));
    expect(dir, greaterThanOrEqualTo(0),
        reason: '删目录必须走 deleteDictionaryDirectory 原语（它负责先释放映射）');
    expect(meta, lessThan(dir),
        reason: '顺序不可交换：引擎还攥着 mmap view 时目录删不掉（BUG-1756）');
    expect(body.contains('deleteSync('), isFalse,
        reason: '裸 deleteSync 绕过了释放映射那一步（BUG-1756）');
  });

  test('E: deleteDictionaries（清空全部）先重载引擎再删目录', () {
    final String body = bodyOf('Future<void> deleteDictionaries(');
    final int rebuild = body.indexOf('_rebuildDictPathsCache()');
    final int dir = body.indexOf('deleteDictionaryDirectory(');
    expect(rebuild, greaterThanOrEqualTo(0));
    expect(dir, greaterThanOrEqualTo(0),
        reason: '删目录必须走 deleteDictionaryDirectory 原语');
    expect(rebuild, lessThan(dir),
        reason: '空集重载先释放全部 mmap view，之后资源根才删得掉（BUG-1756）');
  });

  // BUG-355 / TODO-641 (merged from dictionary_reorder_search_again_guard_test.dart):
  // reordering dictionaries went through `AppModel.updateDictionaryOrder`, a pure
  // forwarder to `DictionaryRepository.updateDictionaryOrder` that — unlike the
  // delete / hide paths above — did NOT notify open lookup pages to re-query, so an
  // already-open lookup kept showing the OLD merge order until reopen/restart. Fix:
  // the app-model layer now fires `dictionarySearchAgainNotifier.notifyListeners()`.
  // Same app_model.dart source-scan paradigm (live Drift DB + FFI engine can't be
  // constructed cheaply in flutter_test); a real device pass (reorder, then look the
  // word up WITHOUT restarting) is still required.
  test(
      'updateDictionaryOrder forwards to the repo AND nudges open lookups to '
      're-query (BUG-355)', () {
    final String body = bodyOf('void updateDictionaryOrder(');
    expect(
      body.contains('dictRepo.updateDictionaryOrder('),
      isTrue,
      reason:
          'must still delegate the persistence/cache/engine work to the repo.',
    );
    expect(
      body.contains('dictionarySearchAgainNotifier.notifyListeners()'),
      isTrue,
      reason:
          'reordering must nudge any already-open lookup page to re-query so '
          'it picks up the new merge order without an app restart (BUG-355); '
          'mirrors the delete paths.',
    );
  });
}
