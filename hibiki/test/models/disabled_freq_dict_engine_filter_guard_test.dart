// BUG-177 source-scan guard.
//
// Root cause: a frequency / pitch dictionary that the user "disabled" in the
// dictionary manager (the visibility Switch toggles `Dictionary.hiddenLanguages`
// via `toggleDictionaryHidden`) was STILL loaded into the native hoshidicts FFI
// engine, so its frequency/pitch data kept appearing in the lookup popup. Unlike
// term glossaries (filtered at render time by `dictionaryNamesByHidden`, or never
// loaded for a hidden dict), frequency/pitch values come straight from
// `lookupPopupJson` (the C++ engine), whose freq/pitch indexes are loaded in
// `_rebuildDictPathsCache` / `_rebuildDictPathsCacheAsync`. Those two methods
// collected freqPaths/pitchPaths from EVERY dictionary of the matching type
// without ever checking `isHidden(...)`, so a disabled frequency dictionary was
// loaded and its values surfaced anyway.
//
// Fix: skip dictionaries that are hidden for the target language when collecting
// freqPaths/pitchPaths, so a disabled frequency/pitch dictionary never enters the
// engine. And clear the dictionary result cache on `toggleDictionaryHidden`, so a
// previously cached popupJson (built while the dict was still enabled) does not
// keep resurfacing the now-disabled dictionary's values until the next cold query.
//
// Layer rationale: the real reload happens through a C++ FFI engine flutter_test
// cannot link, and these are `AppModel` members wired to the live Drift DB +
// filesystem + FFI. The strongest *landable* automated guard is a source scan
// over `app_model.dart` asserting the control-flow invariants the bug violated.
// A real-device pass (disable a frequency dict, then look a word up without
// restarting and confirm the frequency tag is gone) is still required.
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
      '_rebuildDictPathsCache skips hidden dictionaries when collecting '
      'freq/pitch paths (disabled frequency dict must not enter the engine)',
      () {
    final String body = bodyOf('void _rebuildDictPathsCache(');
    expect(body.contains('isHidden'), isTrue,
        reason: 'the sync path-cache rebuild must consult isHidden(...) so a '
            'disabled frequency/pitch dictionary is not loaded into the FFI '
            'engine (BUG-177).');
  });

  test(
      '_rebuildDictPathsCacheAsync skips hidden dictionaries when collecting '
      'freq/pitch paths', () {
    final String body = bodyOf('Future<void> _rebuildDictPathsCacheAsync(');
    expect(body.contains('isHidden'), isTrue,
        reason: 'the async path-cache rebuild must also consult isHidden(...) '
            'for the same reason (BUG-177).');
  });

  test(
      'toggleDictionaryHidden clears the dictionary result cache so a stale '
      'popupJson does not keep resurfacing the disabled dictionary', () {
    final String body = bodyOf('void toggleDictionaryHidden(');
    expect(body.contains('clearDictionaryResultsCache'), isTrue,
        reason: 'toggling visibility must invalidate cached search results, '
            'otherwise a cached popupJson built while the dictionary was still '
            'enabled keeps showing its frequency/pitch values (BUG-177). This '
            'mirrors the delete paths that already clear the cache (BUG-171).');
  });
}
