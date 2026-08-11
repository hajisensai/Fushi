import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// BUG-722: dictionary popup glossary furigana of multi-kanji words (勝負 / 将棋)
// fully superimposed — しょう printed on top of ぶ, しょう on top of ぎ.
//
// Root cause: a dictionary word is ONE <ruby> holding several base+<rt> pairs
// (e.g. <ruby>将<rt>しょう</rt>棋<rt>ぎ</rt></ruby>). popup.css positions each
// <rt> absolutely with left:0/right:0, which resolves against the nearest
// positioned ancestor. When that ancestor was the whole <ruby>, EVERY rt in the
// word stretched to the full ruby width and printed in the same band (headless
// Blink measured −40px / 100% overlap between consecutive rt boxes).
//
// Fix: popup.js's postProcessRuby wraps each base text node in a
// <span class="ruby-unit"> (position:relative) and moves that base's own <rt>
// INTO the span, so each rt anchors to — and centres over — its own kanji
// (headless: consecutive rt-box gap −40px → 0px, each rt clamped to its 20px
// unit). The base text stays a live text node inside the span, so ruby lookup
// selection is unchanged (BUG-110/123/125/129 must not regress).
//
// Ruby geometry can't render in a headless Flutter test, so guard the two
// halves of the contract in source: (1) popup.css scopes the per-base anchor to
// .ruby-unit; (2) postProcessRuby creates .ruby-unit per base and relocates the
// following <rt> into it. The Windows popup inlines the same popup.css/js and
// both extension mirrors are byte-identical (TODO-1267 parity guard), so this
// one guard covers every surface.
void main() {
  final String css = File('assets/popup/popup.css').readAsStringSync();
  final String js = File('assets/popup/popup.js').readAsStringSync();

  test(
      'popup.css gives each furigana base its own positioned .ruby-unit '
      'anchor (BUG-722)', () {
    final RegExp rubyUnitRule = RegExp(
      r':where\([^)]*\bglossary-group\b[^)]*,[^)]*\bglossary-content\b[^)]*\)\s*\.ruby-unit\s*\{([^}]*)\}',
    );
    final RegExpMatch? m = rubyUnitRule.firstMatch(css);
    expect(m, isNotNull,
        reason: 'popup.css must scope a .ruby-unit block to the glossary '
            'surfaces so each base kanji is its own positioned box (BUG-722)');
    expect(RegExp(r'position\s*:\s*relative').hasMatch(m!.group(1)!), isTrue,
        reason: '.ruby-unit must be position:relative so the absolute <rt> '
            'anchors to its own kanji, not the full-width <ruby> (BUG-722)');
  });

  test(
      'postProcessRuby wraps each base in .ruby-unit and moves its <rt> into '
      'the unit (BUG-722)', () {
    expect(js.contains('function postProcessRuby('), isTrue,
        reason: 'popup.js must define postProcessRuby');
    // Per-base unit is created…
    expect(js.contains("className = 'ruby-unit'"), isTrue,
        reason: 'postProcessRuby must wrap each base in a .ruby-unit span so '
            'its <rt> can anchor per-kanji (BUG-722)');
    // …and the base\'s own <rt> is relocated INTO that unit. If the rt stayed a
    // sibling of the whole ruby it would re-collapse to the full word width.
    // (BUG-733 refactored the tag test into an isEl(node, 'RT') helper; the
    // semantic — locate the following <rt> element — is unchanged.)
    expect(js.contains("isEl(sib, 'RT')"), isTrue,
        reason: 'postProcessRuby must find the base\'s following <rt> element');
    // BUG-1487 moved the positioned box one level in: the reading is wrapped in
    // a neutral <span class="ruby-rt"> which is appended to the unit, and the
    // <rt> goes inside that span (WebKit force-resets `position` on <rt>, so it
    // can never be the anchor itself). The BUG-722 invariant is unchanged — the
    // reading must end up under its own base's unit, not stay a sibling of the
    // whole <ruby> — so both halves of the relocation are pinned here.
    expect(js.contains("rtBox.className = 'ruby-rt'"), isTrue,
        reason: 'postProcessRuby must wrap each reading in a .ruby-rt box — '
            'that span, not the <rt>, carries position:absolute (BUG-1487)');
    expect(js.contains('unit.appendChild(rtBox)'), isTrue,
        reason: 'postProcessRuby must append the reading box to the per-base '
            '.ruby-unit — otherwise the reading anchors to the whole <ruby> and '
            'multi-kanji-word readings superimpose (BUG-722)');
    expect(js.contains('rtBox.appendChild(sib)'), isTrue,
        reason:
            'postProcessRuby must move each base\'s own <rt> INTO that reading '
            'box, so the annotation stays with its own kanji (BUG-722/1487)');
  });
}
