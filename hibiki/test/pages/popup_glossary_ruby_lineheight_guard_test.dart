import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// BUG-108: in the dictionary popup, furigana (<ruby>'s <rt>) inside a
// glossary body overlapped the kanji on the line above. Glossary content uses
// a compact line-height (1.4) that reserves no vertical room for the ruby
// annotation, so in WebKit/Blink the <rt> overflows upward onto the preceding
// line (明鏡's related-word lists, where every line carries ruby, made it
// obvious). The fix reserves line-height on the inline <ruby> inside glossary
// bodies so only ruby-bearing line boxes grow. Ruby rendering can't run
// headless in a WebView, so guard the CSS rule's presence.
void main() {
  test('glossary ruby reserves line-height so furigana never overlaps', () {
    final String css = File('assets/popup/popup.css').readAsStringSync();

    // The fix must scope a ruby line-height rule to the glossary surfaces
    // (.glossary-group / .glossary-content), not the headword (.expression).
    final RegExp rubyRule = RegExp(
      r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*ruby\s*\{[^}]*line-height\s*:\s*2',
    );
    expect(
      rubyRule.hasMatch(css),
      isTrue,
      reason:
          'popup.css must give glossary-body <ruby> a reserved line-height so '
          'the <rt> furigana does not overlap the kanji on the line above '
          '(BUG-108)',
    );
  });
}
