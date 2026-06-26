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
