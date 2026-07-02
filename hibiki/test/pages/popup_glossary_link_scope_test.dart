import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-860 / BUG-435 / TODO-1022 / BUG-478 / BUG-520: dictionary
/// structured-content nodes carry inline `style` (`float` /
/// `position:absolute|fixed|sticky`) that used to land verbatim on
/// `element.style` via popup.js `setStructuredContentElementStyle` and push
/// text out of the inline flow. Two rounds of CSS bandaids followed; the
/// second (BUG-478) was a blanket span/div rule whose `display:inline`
/// destroyed the div-based line breaks of every dictionary (BUG-520).
///
/// ROOT FIX contract: popup.js drops the flow-escaping properties at the
/// source (`isFlowEscapingStructuredContentStyle`); the only CSS rule left is
/// the narrow `a.gloss-sc-a` one (still needed against the dictionary's own
/// styles.css, secondary cause of BUG-435). Blanket gloss-sc span/div CSS
/// rules are banned.
///
/// Three guards:
/// 1) Behaviour — Node truly executes popup.js `renderStructuredContent` +
///    `createDefinitionImage` and asserts the source filter semantics (see
///    popup_glossary_link_scope_test.js). Skipped when node is absent.
/// 2) CSS source — scans popup.css for the `a.gloss-sc-a` rule with
///    `float:none!important` + `position:static!important`, and asserts the
///    rule does NOT mention `gloss-image-link`. Holds even without node.
/// 3) Source filter + BUG-520 regression guard — popup.js (app + extension
///    vendor) must carry the filter; popup.css must NOT carry blanket
///    gloss-sc span/div rules.
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

  // BUG-520 (regression of the BUG-478 fix): the blanket popup.css rule
  //   span/div[class*="gloss-sc-"] { float:none!important;
  //     position:static!important; display:inline; }
  // forced display:inline onto every gloss-sc-div. Structured content relies
  // on the div's UA block display for line breaks, so every dictionary's lines
  // collapsed into one run-on line and icon containers overlapped text.
  //
  // ROOT FIX contract: popup.js filters the flow-escaping inline styles at the
  // source (isFlowEscapingStructuredContentStyle inside
  // setStructuredContentElementStyle), and the blanket CSS rule is BANNED.
  // The same filter must exist in the browser-extension vendor snapshot.
  test(
      'popup.js filters flow-escaping dict styles at the source; '
      'no blanket gloss-sc span/div CSS rule (BUG-520)', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();

    // Source filter present and wired into setStructuredContentElementStyle.
    expect(js.contains('function isFlowEscapingStructuredContentStyle'), isTrue,
        reason: 'popup.js must define the flow-escape source filter '
            '(root fix for BUG-435/478/519)');
    final int setterIdx =
        js.indexOf('function setStructuredContentElementStyle');
    expect(setterIdx, greaterThanOrEqualTo(0));
    final int setterEnd = js.indexOf('\n}', setterIdx);
    final String setterBody = js.substring(setterIdx, setterEnd);
    expect(setterBody.contains('isFlowEscapingStructuredContentStyle'), isTrue,
        reason: 'setStructuredContentElementStyle must consult the filter '
            'before landing dict inline styles');

    // The filter must drop float and absolute/fixed/sticky position, and it
    // must NOT special-case relative (position:relative stays in the flow and
    // is legitimately used by dictionaries for glyph nudges).
    final int filterIdx =
        js.indexOf('function isFlowEscapingStructuredContentStyle');
    final int filterEnd = js.indexOf('\n}', filterIdx);
    final String filterBody = js.substring(filterIdx, filterEnd);
    expect(filterBody.contains("'float'"), isTrue,
        reason: 'filter must drop float');
    expect(filterBody.contains('absolute|fixed|sticky'), isTrue,
        reason: 'filter must drop only absolute/fixed/sticky positions');

    // BUG-520 regression guard: the blanket span/div neutralization rule that
    // broke line breaks must never come back.
    final String rawCss = File('assets/popup/popup.css').readAsStringSync();
    final String css = rawCss.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    expect(css.contains('span[class*="gloss-sc-"]'), isFalse,
        reason: 'BUG-520: no blanket span[class*="gloss-sc-"] rule in '
            'popup.css -- neutralize at the popup.js source instead');
    expect(css.contains('div[class*="gloss-sc-"]'), isFalse,
        reason: 'BUG-520: no blanket div[class*="gloss-sc-"] rule in '
            'popup.css -- forcing display:inline on dict divs destroys '
            'line breaks');

    // The browser-extension vendor snapshot ships the same renderer and must
    // carry the same source filter (both vendor copies are byte-locked by the
    // browser_extension_installer drift guard).
    final String vendorJs =
        File('assets/browser_extension/vendor/popup.js').readAsStringSync();
    expect(vendorJs.contains('function isFlowEscapingStructuredContentStyle'),
        isTrue,
        reason: 'extension vendor popup.js must carry the same source filter');
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
