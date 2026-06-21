import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// Source-level guards for two reader-open crashes that can only be reproduced
/// with a live WebView2 native layer / real focus tree, so we lock the contracts
/// at the source level (strongest feasible layer — see docs/BUGS.md).
///
/// BUG-019 — opening an audiobook-attached book on Windows rendered a permanent
/// blank reader. media_kit/libmpv (loaded when the audiobook plays) can leave
/// the platform thread's COM uninitialized, so WebView2's
/// `CreateCoreWebView2EnvironmentWithOptions` fails with CO_E_NOTINITIALIZED and
/// the reader never paints. The fork must call `CoInitializeEx` (idempotent,
/// refcounted) right before creating the environment so the precondition holds
/// regardless of what other plugins did to global COM state.
///
/// BUG-020 — `FocusScopeNode.nextFocus()` dereferences `context!`; calling it on
/// an unattached chrome scope (e.g. toggled while reader content isn't ready)
/// threw "Null check operator used on a null value". Every `nextFocus()` call on
/// the chrome scope must be guarded by a `context != null` check.
void main() {
  group('BUG-019 · WebView2 env creation initializes COM first', () {
    // Each fork file that calls CreateCoreWebView2EnvironmentWithOptions must
    // CoInitializeEx on the calling thread first.
    const List<String> forkEnvSites = <String>[
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp',
      '../packages/flutter_inappwebview_windows/windows/webview_environment/webview_environment.cpp',
    ];

    for (final String relativePath in forkEnvSites) {
      test('$relativePath calls CoInitializeEx before creating the env', () {
        final File file = File(relativePath);
        expect(file.existsSync(), isTrue,
            reason:
                'guarded fork file moved or renamed: $relativePath — update '
                'this test to keep covering every WebView2 env creation site');

        final String code = _stripCppLineComments(file.readAsStringSync());

        final int createIdx =
            code.indexOf('CreateCoreWebView2EnvironmentWithOptions(');
        expect(createIdx, isNonNegative,
            reason: '$relativePath no longer creates a WebView2 environment — '
                'remove it from forkEnvSites');

        final int coInitIdx = code.indexOf('CoInitializeEx(');
        expect(coInitIdx, isNonNegative,
            reason: '$relativePath dropped the CoInitializeEx guard — WebView2 '
                'env creation will fail with CO_E_NOTINITIALIZED after '
                'media_kit/libmpv tears down COM (blank reader on Windows)');

        expect(coInitIdx, lessThan(createIdx),
            reason: '$relativePath must CoInitializeEx BEFORE '
                'CreateCoreWebView2EnvironmentWithOptions, not after');
      });
    }
  });

  test('BUG-020 · every chrome-scope nextFocus() is context-guarded', () {
    // The chrome-scope traversal sites live across the reader shell + its
    // extracted part files (TODO-589), so read the merged corpus to keep
    // covering every `_chromeFocusScope.nextFocus()` site, not just the shell.
    final String code = _stripDartLineComments(readReaderPageSource());

    final int nextFocusCount =
        _countOccurrences(code, '_chromeFocusScope.nextFocus()');
    expect(nextFocusCount, greaterThan(0),
        reason:
            'expected the reader to traverse the chrome focus scope; if the '
            'call was removed, drop this guard');

    final int guardCount =
        _countOccurrences(code, '_chromeFocusScope.context != null');
    expect(guardCount, greaterThanOrEqualTo(nextFocusCount),
        reason: 'every `_chromeFocusScope.nextFocus()` must be guarded by a '
            '`_chromeFocusScope.context != null` check — nextFocus() throws on '
            'an unattached scope (Null check operator used on a null value)');
  });
}

int _countOccurrences(String haystack, String needle) {
  int count = 0;
  int from = 0;
  while (true) {
    final int idx = haystack.indexOf(needle, from);
    if (idx < 0) break;
    count++;
    from = idx + needle.length;
  }
  return count;
}

/// Drops `//` line comments so assertions match real code, not the prose that
/// documents the guards (which itself mentions the guarded calls).
String _stripDartLineComments(String source) => source
    .split('\n')
    .where((String line) => !line.trimLeft().startsWith('//'))
    .join('\n');

/// Same, for the C++ fork files (also `//`-commented).
String _stripCppLineComments(String source) => source
    .split('\n')
    .where((String line) => !line.trimLeft().startsWith('//'))
    .join('\n');
