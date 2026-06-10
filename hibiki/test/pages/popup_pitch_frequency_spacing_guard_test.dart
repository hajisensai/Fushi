import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// BUG-178 (part 2): in the dictionary popup, the pitch-accent section sits
// directly under the frequency section (buildEntryElement appends freqSection
// then pitchSection). Both are `.category-section`s with only a 2px top gap.
// The first pitch mora's high/low overline (.pronunciation-mora-line, top:-2px)
// pokes above its line box, so with the tight 2px gap it butts up against /
// overlaps the frequency tag on the line above — the user reported the pitch
// accent being covered. Pitch rendering can't run headless in a WebView, so
// guard the CSS spacing rule's presence and that it actually widens the gap.
void main() {
  test(
      'popup.css gives the pitch section that follows the frequency section '
      'extra top margin so the pitch overline does not overlap the frequency '
      'tag (BUG-178)', () {
    final String css = File('assets/popup/popup.css').readAsStringSync();

    final RegExp rule = RegExp(
      r'\.frequency-section\s*\+\s*\.pitch-section\s*\{([^}]*)\}',
    );
    final RegExpMatch? match = rule.firstMatch(css);
    expect(
      match,
      isNotNull,
      reason: 'popup.css must target the freq→pitch adjacency '
          '(.frequency-section + .pitch-section) to add breathing room so the '
          'pitch accent is not covered by the frequency values above (BUG-178).',
    );

    final String body = match!.group(1)!;
    final RegExpMatch? marginMatch =
        RegExp(r'margin-top\s*:\s*(\d+(?:\.\d+)?)\s*px').firstMatch(body);
    expect(
      marginMatch,
      isNotNull,
      reason: 'the freq→pitch rule must set an explicit px margin-top.',
    );

    final double margin = double.parse(marginMatch!.group(1)!);
    // The default .category-section gap is 2px; the fix must be strictly larger
    // so the pitch section actually gains separation from the frequency tags.
    expect(
      margin,
      greaterThan(2),
      reason: 'the freq→pitch margin-top ($margin px) must exceed the default '
          '2px category-section gap to clear the overlap (BUG-178).',
    );
  });
}
