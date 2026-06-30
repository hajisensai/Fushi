import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-860 / BUG-435: dictionary structured-content TEXT links
/// (`<a class="gloss-sc-a">`) escape the inline flow and land "off to the side"
/// because their structured-content node carries an inline `style`
/// (`float` / `position:absolute|fixed`) that popup.js
/// `setStructuredContentElementStyle` lands on `element.style` with no
/// whitelist (popup.js:516). Secondary cause: the dictionary's own styles.css
/// `a{float/position}`. The fix is a pure CSS rule in popup.css that pulls the
/// text link back into the inline flow.
///
/// Two guards:
/// 1) Behaviour — Node truly executes popup.js `renderStructuredContent` +
///    `createDefinitionImage`, then matches the actual popup.css rule against
///    the rendered text link and image link. Asserts the rule neutralizes the
///    text link (float none / position static) and, crucially, does NOT touch
///    the image link (`gloss-image-link`, TODO-859/350 keeps position/float).
///    Skipped when node is absent.
/// 2) CSS source — scans popup.css for the `a.gloss-sc-a` rule with
///    `float:none!important` + `position:static!important`, and asserts the
///    rule does NOT mention `gloss-image-link`. Holds even without node.
void main() {
  test(
    'popup glossary text link stays inline, image link untouched (node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest = File(
        'test/pages/popup_glossary_link_scope_test.js',
      );
      expect(
        jsTest.existsSync(),
        isTrue,
        reason: 'behavior harness ${jsTest.path} must exist',
      );

      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
      );

      expect(
        result.exitCode,
        0,
        reason: 'glossary link scope JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );

  test('popup.css scopes the inline-flow fix to a.gloss-sc-a only', () {
    // Strip CSS comments first so the prose (which mentions gloss-image-link)
    // can never be mistaken for the rule itself.
    final String raw = File('assets/popup/popup.css').readAsStringSync();
    final String css = raw.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');

    final int ruleStart = css.indexOf('a.gloss-sc-a');
    expect(ruleStart, greaterThanOrEqualTo(0),
        reason:
            'popup.css must carry the TODO-860 a.gloss-sc-a inline-flow rule');

    final int braceOpen = css.indexOf('{', ruleStart);
    final int braceClose = css.indexOf('}', braceOpen);
    expect(braceOpen, greaterThan(ruleStart));
    expect(braceClose, greaterThan(braceOpen));

    final String selector = css.substring(ruleStart, braceOpen);
    final String body =
        css.substring(braceOpen + 1, braceClose).replaceAll(RegExp(r'\s+'), '');

    // The fix must neutralize the escaping properties.
    expect(body.contains('float:none!important'), isTrue,
        reason: 'fix must force float:none!important');
    expect(body.contains('position:static!important'), isTrue,
        reason: 'fix must force position:static!important');

    // SCOPE GUARD: never touch image links (TODO-859/350 keep position/float).
    expect(selector.contains('gloss-image-link'), isFalse,
        reason: 'fix selector must NOT mention gloss-image-link');
    expect(body.contains('gloss-image-link'), isFalse,
        reason: 'fix body must NOT mention gloss-image-link');
  });

  // TODO-1022 / BUG-435 regression (uncovered branch): the misplaced glyph is a
  // NON-<a> structured-content span/div (Meikyo opening quote, class
  // gloss-sc-span / gloss-sc-div) that the a.gloss-sc-a rule never reached. The
  // fix extends the inline-flow neutralization to span/div carrying a gloss-sc-*
  // class, while EXPLICITLY excluding .gloss-image-link (image links keep their
  // position/float) and ruby/rt (furigana layout).
  test(
      'popup.css extends the inline-flow fix to gloss-sc span/div, '
      'excluding image links + ruby/rt (TODO-1022)', () {
    final String raw = File('assets/popup/popup.css').readAsStringSync();
    final String css = raw.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');

    // The new neutralization rule targets span/div with a gloss-sc-* class and
    // forces them back into the inline flow.
    final int ruleStart =
        css.indexOf('span[class*="gloss-sc-"]:not(.gloss-image-link)');
    expect(ruleStart, greaterThanOrEqualTo(0),
        reason:
            'popup.css must carry the TODO-1022 span/div inline-flow rule that '
            'excludes .gloss-image-link via :not()');

    final int braceOpen = css.indexOf('{', ruleStart);
    final int braceClose = css.indexOf('}', braceOpen);
    expect(braceOpen, greaterThan(ruleStart));
    expect(braceClose, greaterThan(braceOpen));

    final String selector = css.substring(ruleStart, braceOpen);
    final String body =
        css.substring(braceOpen + 1, braceClose).replaceAll(RegExp(r'\s+'), '');

    // Coverage: the rule must mention BOTH span and div forms.
    final int spanIdx = css.lastIndexOf('span[class*="gloss-sc-"]', braceOpen);
    final int divIdx = css.lastIndexOf('div[class*="gloss-sc-"]', braceOpen);
    expect(spanIdx, greaterThanOrEqualTo(0),
        reason: 'rule must cover span gloss-sc-*');
    expect(divIdx, greaterThanOrEqualTo(0),
        reason: 'rule must cover div gloss-sc-*');

    // The fix must neutralize the escaping properties.
    expect(body.contains('float:none!important'), isTrue,
        reason: 'span/div fix must force float:none!important');
    expect(body.contains('position:static!important'), isTrue,
        reason: 'span/div fix must force position:static!important');

    // SCOPE GUARD: the neutralization selector must EXCLUDE image links.
    expect(selector.contains(':not(.gloss-image-link)'), isTrue,
        reason: 'span/div fix selector must exclude .gloss-image-link');

    // There must be a restore rule that re-grants float/position to span/div
    // nested inside an image link or inside ruby/rt, so those legitimate uses
    // are never collateral-damaged.
    final int restoreImg =
        css.indexOf('.gloss-image-link span[class*="gloss-sc-"]');
    expect(restoreImg, greaterThanOrEqualTo(0),
        reason:
            'popup.css must restore float/position inside .gloss-image-link');
    expect(css.contains('ruby span[class*="gloss-sc-"]'), isTrue,
        reason: 'popup.css must restore float/position inside ruby');
    expect(css.contains('rt span[class*="gloss-sc-"]'), isTrue,
        reason: 'popup.css must restore float/position inside rt');
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}
