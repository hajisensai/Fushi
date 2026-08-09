// TODO-1305 / BUG-607 static guard: the dictionary popup's pitch-accent
// pronunciation area (katakana reading rendered mora-by-mora + the [n] pitch
// number + IPA tags) must be non-selectable, so dragging across it does NOT
// leave a native text selection that mining then bakes into the Anki card's
// SelectionText field (user reported "Text Selection 1/3 カンロク" — the pitch
// reading — appearing in cards instead of the dictionary term).
//
// Root cause: popup.js createPitchHtml/createPitchGroup render each mora as a
// `.pronunciation-mora` span (textContent = katakana) inside `.pitch-group`,
// which — like the rest of the popup body — was `user-select:text`. The click
// handler bails out on a >5px drag (never opens a nested lookup), so the raw
// selection survives and popup.js snapshots `window.getSelection().toString()`
// into popupSelectionText → cloze-inside SelectionText.
//
// Fix (plan A, minimal): `.pitch-group { user-select:none }`. It is a sibling
// section to `.glossary-section`, so glossary body text stays selectable for
// nested lookup. This is a pure-CSS change in a static asset, so a file-text
// scan is the strongest landable guard.
//
// Three mirrors are guarded: the in-app popup (assets/popup) and the two
// byte-identical browser-extension vendor copies (assets/browser_extension and
// tools/browser-extension), which render pitch the same way.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Extract the body of the first `<selector> { ... }` rule (naive single-level
/// brace match — the popup pitch rules contain no nested braces).
String _ruleBody(String css, String selector) {
  final int start = css.indexOf('$selector {');
  expect(start, greaterThanOrEqualTo(0), reason: 'rule "$selector" not found');
  final int open = css.indexOf('{', start);
  final int close = css.indexOf('}', open);
  expect(close, greaterThan(open), reason: 'rule "$selector" not closed');
  return css.substring(open + 1, close);
}

void main() {
  // flutter test cwd is the hibiki package root.
  final Map<String, String> popupCssFiles = <String, String>{
    'in-app popup': 'assets/popup/popup.css',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.css',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.css',
  };

  popupCssFiles.forEach((String name, String relPath) {
    group('pitch pronunciation non-selectable [$name] $relPath', () {
      late final String css;

      setUpAll(() {
        final File file = File(relPath);
        expect(file.existsSync(), isTrue,
            reason: 'popup.css not found at ${file.absolute.path}');
        css = file.readAsStringSync();
      });

      test('.pitch-group blocks text selection (both standard + -webkit)', () {
        final String body = _ruleBody(css, '.pitch-group');
        expect(body, contains('user-select: none;'),
            reason:
                'pitch pronunciation area must set user-select:none, or the '
                'katakana reading gets dragged into the mined SelectionText');
        expect(body, contains('-webkit-user-select: none;'),
            reason: 'WebKit/Blink WebView needs the -webkit- prefix too');
      });

      test('dictionary body keeps text selection (glossary lookup preserved)',
          () {
        // Popup body base rule stays selectable so nested lookup on glossary
        // text still works. The fix must NOT globally disable selection.
        expect(css, contains('-webkit-user-select: text;'),
            reason: 'popup body must remain text-selectable for nested lookup');
        final String glossary = _ruleBody(css, '.glossary-content');
        expect(glossary.contains('user-select: none'), isFalse,
            reason: 'glossary content must stay selectable (do not spill the '
                'pitch user-select:none onto the dictionary body)');
      });
    });
  });

  test('the two extension vendor popup.css copies stay byte-identical', () {
    // Complements browser_extension_installer_test's drift guard: the pitch
    // user-select:none fix must land in BOTH vendor copies identically.
    final List<int> assetsBytes =
        File('assets/browser_extension/vendor/popup.css').readAsBytesSync();
    final List<int> toolsBytes =
        File('../tools/browser-extension/vendor/popup.css').readAsBytesSync();
    expect(assetsBytes, toolsBytes,
        reason: 'extension vendor popup.css copies diverged');
  });
}
