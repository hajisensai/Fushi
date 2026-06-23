import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level guard for a reader-open crash that can only be reproduced with a
/// live WebView2 native layer, so we lock the contract at the source level
/// (strongest feasible layer — see docs/BUGS.md).
///
/// BUG-019 — opening an audiobook-attached book on Windows rendered a permanent
/// blank reader. media_kit/libmpv (loaded when the audiobook plays) can leave
/// the platform thread's COM uninitialized, so WebView2's
/// `CreateCoreWebView2EnvironmentWithOptions` fails with CO_E_NOTINITIALIZED and
/// the reader never paints. The fork must call `CoInitializeEx` (idempotent,
/// refcounted) right before creating the environment so the precondition holds
/// regardless of what other plugins did to global COM state.
///
/// (The former BUG-020 sub-guard — "every `_chromeFocusScope.nextFocus()` must
/// be context-guarded" — was removed in TODO-700 T8: the bottom chrome bar is
/// now wrapped in `ExcludeFocus` and no longer traversed, so the reader no
/// longer calls `_chromeFocusScope.nextFocus()` at all and the unattached-scope
/// crash path is gone at the root. The "no dead chrome-focus traversal" contract
/// is now held by reader_caret_down_paginates_test.dart.)
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
}

/// Drops `//` line comments so assertions match real code, not the prose that
/// documents the guards (which itself mentions the guarded calls).
String _stripCppLineComments(String source) => source
    .split('\n')
    .where((String line) => !line.trimLeft().startsWith('//'))
    .join('\n');
