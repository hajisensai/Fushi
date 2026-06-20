// BUG-355 / TODO-641 source-scan guard.
//
// Root cause: reordering dictionaries went through `AppModel.updateDictionaryOrder`,
// which was a pure forwarder to `DictionaryRepository.updateDictionaryOrder`. Unlike
// the delete / hide paths (`deleteDictionaries` / `deleteDictionary` /
// `toggleDictionaryHidden`), it did NOT notify the open lookup pages to re-query, so
// an already-open lookup kept showing the OLD merge order until the page was reopened
// or the app restarted (the repo-layer search cache fix alone re-merges only on the
// *next* query, not the one already on screen).
//
// Fix (two layers):
//   - repo layer: `DictionaryRepository.updateDictionaryOrder` now calls
//     `clearDictionaryResultsCache()` so the next lookup re-merges in the new order
//     — covered by a real behavioural test in dictionary_repository_test.dart.
//   - app-model layer: `AppModel.updateDictionaryOrder` now fires
//     `dictionarySearchAgainNotifier.notifyListeners()` so an already-open lookup page
//     rebuilds — mirrors the delete paths.
//
// Layer rationale: `AppModel.updateDictionaryOrder` is an `AppModel` member wired to
// the live Drift DB + FFI engine via `dictRepo`, which flutter_test cannot construct
// cheaply (same constraint as dictionary_delete_engine_reload_guard_test.dart). The
// strongest *landable* guard for the notify half is therefore a source scan over
// `app_model.dart` asserting the control-flow invariant the bug violated. A real
// device pass (reorder dictionaries, then look the word up WITHOUT restarting) is
// still required.
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
