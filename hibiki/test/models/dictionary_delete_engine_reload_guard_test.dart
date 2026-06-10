// BUG-171 source-scan guard.
//
// Root cause: deleting a dictionary only updated the Dart-side caches but did
// NOT always rebuild the native hoshidicts FFI engine instance, so the deleted
// dictionary's in-memory index stayed loaded and queries kept hitting it until
// the app was restarted (TODO-095 user report).
//
// Two concrete control-flow holes existed:
//   A) `_rebuildDictPathsCache` / `_rebuildDictPathsCacheAsync` only called
//      `HoshiDicts.initializeTyped(...)` when at least one path bucket was
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
        if (depth == 0) return src.substring(open, i + 1);
      }
    }
    fail('unbalanced braces scanning $name');
  }

  test(
      'A: _rebuildDictPathsCache rebuilds the engine even when all path '
      'buckets are empty (deleting the last dictionary must reload)', () {
    final String body = bodyOf('void _rebuildDictPathsCache(');
    expect(body.contains('HoshiDicts.initializeTyped'), isTrue,
        reason: 'rebuild must drive the FFI engine');
    // The call to initializeTyped must NOT be gated behind an
    // `isNotEmpty`-style guard that skips the rebuild for an empty path set —
    // that is exactly the hole that left a stale engine after deleting the last
    // dictionary (BUG-171 hole A).
    expect(
      RegExp(r'isNotEmpty\s*\)\s*\{?\s*HoshiDicts\.initializeTyped')
          .hasMatch(body.replaceAll(RegExp(r'\s+'), ' ')),
      isFalse,
      reason: 'initializeTyped must run for an empty path set too; an empty '
          'rebuild yields an empty-but-fresh engine so deleting the last '
          'dictionary stops queries from hitting it (BUG-171).',
    );
  });

  test('A2: _rebuildDictPathsCacheAsync also rebuilds unconditionally', () {
    final String body = bodyOf('Future<void> _rebuildDictPathsCacheAsync(');
    expect(body.contains('HoshiDicts.initializeTyped'), isTrue);
    expect(
      RegExp(r'isNotEmpty\s*\)\s*\{?\s*HoshiDicts\.initializeTyped')
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
    expect(body.contains('_rebuildDictPathsCache'), isTrue,
        reason: 'deleting a single dictionary must rebuild the engine.');
  });
}
