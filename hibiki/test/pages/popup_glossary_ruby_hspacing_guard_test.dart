import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// BUG-345 / TODO-620: in the dictionary popup, glossary bodies that carry
// per-character furigana (明鏡-style 逐字 ruby, e.g. 顔(かお)を洗(あら)う…) rendered
// with ragged horizontal spacing. popup.js's postProcessRuby replaces each
// <ruby>'s base text node with a bare <span> so the ruby text stays
// selectable (BUG-110/123/125/129 must not regress), but that <span> is still a
// ruby base box: Blink sizes every ruby base box to max(base, rt). With
// rt{font-size:0.5em}, a reading of >=3 kana is wider than its 1em kanji, so
// each ruby base is stretched to its own annotation width and the line goes
// ragged. popup.css previously only constrained the vertical line-height
// (BUG-108) — there was no horizontal rule.
//
// The fix (pure CSS, Yomitan structured-content pattern) takes the <rt> out of
// the inline flow so it no longer widens the base box, while keeping the
// furigana centred above the kanji:
//   :where(.glossary-group, .glossary-content) ruby {
//       display: inline-block; position: relative;
//   }
//   :where(.glossary-group, .glossary-content) rt {
//       position: absolute; left:0; right:0; bottom:100%;
//       text-align: center; white-space: nowrap; line-height: 1;
//   }
// Ruby geometry can't render headless in a WebView, so guard the CSS rules'
// presence (the headless-Chromium repro proved spread 18.25px -> 0px). The
// Windows popup inlines this same popup.css via _winCss, so one guard covers
// all platforms.
void main() {
  final String css = File('assets/popup/popup.css').readAsStringSync();

  test(
      'glossary ruby is laid out as inline-block + relative so rt cannot '
      'stretch the base box (BUG-345)', () {
    final RegExp rubyRule = RegExp(
      r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*ruby\s*\{([^}]*)\}',
    );
    final RegExpMatch? match = rubyRule.firstMatch(css);
    expect(
      match,
      isNotNull,
      reason: 'popup.css must scope a ruby block to the glossary surfaces '
          '(.glossary-group / .glossary-content)',
    );
    final String body = match!.group(1)!;
    expect(
      RegExp(r'display\s*:\s*inline-block').hasMatch(body),
      isTrue,
      reason: 'glossary <ruby> must be display:inline-block so the base box '
          'collapses to the kanji width instead of being stretched to the '
          'rt width (BUG-345)',
    );
    expect(
      RegExp(r'position\s*:\s*relative').hasMatch(body),
      isTrue,
      reason: 'glossary <ruby> must be position:relative so the absolutely '
          'positioned <rt> anchors to its own base (BUG-345)',
    );
  });

  test(
      'glossary rt is taken out of the inline flow (absolute, above the base) '
      'so it cannot widen the base box (BUG-345)', () {
    final RegExp rtRule = RegExp(
      r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*rt\s*\{([^}]*)\}',
    );
    final RegExpMatch? match = rtRule.firstMatch(css);
    expect(
      match,
      isNotNull,
      reason: 'popup.css must scope an rt block to the glossary surfaces',
    );
    final String body = match!.group(1)!;
    expect(
      RegExp(r'position\s*:\s*absolute').hasMatch(body),
      isTrue,
      reason: 'glossary <rt> must be position:absolute so it leaves the inline '
          'flow and stops dictating the ruby base box width (BUG-345)',
    );
    expect(
      RegExp(r'bottom\s*:\s*100%').hasMatch(body),
      isTrue,
      reason: 'glossary <rt> must sit at bottom:100% (above its base), kept '
          'clear of the previous line by the line-height:2 reserve (BUG-108)',
    );
  });

  test('the BUG-108 vertical line-height reserve is preserved (no regression)',
      () {
    final RegExp rubyLineHeight = RegExp(
      r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*ruby\s*\{[^}]*line-height\s*:\s*2',
    );
    expect(
      rubyLineHeight.hasMatch(css),
      isTrue,
      reason: 'glossary <ruby> must keep line-height:2 — the absolutely '
          'positioned furigana relies on that reserve to clear the line '
          'above it (BUG-108 must not regress)',
    );
  });
}
