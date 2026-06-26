import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-867 P2 — guards for the app-OUTSIDE global-lookup popup styling.
///
/// popup.css/js are SHARED by the in-app popup (Flutter-Material card chrome)
/// and the bare Windows global-lookup WebView2 window (no native card). The P2
/// fixes — hoshi card chrome (#1), no first-result equal-height stretch (#2),
/// flex-wrap variable-height sub-boxes (#3) — MUST be scoped to
/// `html.global-lookup` so the in-app popup and its tested --dict-columns grid
/// stay untouched. These guards lock that scoping in source so a later refactor
/// can't leak the chrome into the in-app popup or drop the scope marker.
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  group('scope marker', () {
    test('global_lookup_render injects the global-lookup class', () {
      final String src = read('lib/src/lookup/global_lookup_render.dart');
      expect(
        src.contains("document.documentElement.classList.add('global-lookup')"),
        isTrue,
        reason: 'the app-outside render script must tag the document so the '
            'scoped popup.css chrome applies',
      );
    });

    test('in-app dictionary_popup_webview NEVER adds the global-lookup class',
        () {
      final String src =
          read('lib/src/pages/implementations/dictionary_popup_webview.dart');
      expect(
        src.contains("classList.add('global-lookup')"),
        isFalse,
        reason: 'the in-app popup must NOT tag itself global-lookup — its card '
            'chrome is the Flutter Material card; adding it would double-frame '
            'and switch the tested grid to flex-wrap (regression)',
      );
    });
  });

  group('popup.css scoping (source)', () {
    late String css;
    setUpAll(() => css = read('assets/popup/popup.css'));

    test('card chrome is scoped to html.global-lookup body, not bare body', () {
      expect(css.contains('html.global-lookup body {'), isTrue,
          reason: 'hoshi card chrome must live under the global-lookup scope');
      // The chrome props (radius/border) must not appear in the bare body rule.
      final int bareStart = RegExp(r'(^|\n)body \{').firstMatch(css)!.start;
      final int bareEnd = css.indexOf('}', bareStart);
      final String bareBody = css.substring(bareStart, bareEnd);
      expect(bareBody.contains('border-radius'), isFalse,
          reason: 'bare body{} feeds the in-app popup — no card radius there');
      expect(bareBody.contains('box-shadow'), isFalse);
    });

    test('in-app grid stays grid; global-lookup overrides to flex-wrap', () {
      expect(css.contains('.glossary-section > .category-body {'), isTrue);
      // in-app rule keeps grid.
      final int gridAt = css.indexOf('.glossary-section > .category-body {');
      final String gridRule = css.substring(gridAt, css.indexOf('}', gridAt));
      expect(gridRule.contains('display: grid'), isTrue,
          reason: 'the tested --dict-columns grid must remain for in-app');

      // global-lookup override switches to variable-height flex-wrap.
      expect(
        css.contains('html.global-lookup .glossary-section > .category-body {'),
        isTrue,
      );
      final int flexAt = css
          .indexOf('html.global-lookup .glossary-section > .category-body {');
      final String flexRule = css.substring(flexAt, css.indexOf('}', flexAt));
      expect(flexRule.contains('display: flex'), isTrue);
      expect(flexRule.contains('flex-wrap: wrap'), isTrue);
      expect(flexRule.contains('align-items: flex-start'), isTrue,
          reason: 'flex-start = content height, kills the first-result '
              'equal-height stretch (#2) and fixed-3 equal-height rows (#3)');
      expect(flexRule.contains('grid-template-columns'), isFalse);
    });
  });

  group('native rounded window (C++)', () {
    test('global_lookup_window rounds the opaque window via SetWindowRgn', () {
      final String cpp = read('windows/runner/global_lookup_window.cpp');
      expect(cpp.contains('ApplyRoundedRegion'), isTrue);
      expect(cpp.contains('CreateRoundRectRgn'), isTrue,
          reason: 'opaque non-layered window needs a region for real round '
              'corners (CSS radius alone leaves square window corners)');
      expect(cpp.contains('SetWindowRgn'), isTrue);
      // Applied on size change so the region tracks the settled window size.
      final int sizeAt = cpp.indexOf('case WM_SIZE:');
      final int applyAt = cpp.indexOf('ApplyRoundedRegion();', sizeAt);
      expect(applyAt, greaterThan(sizeAt),
          reason: 'region must be (re)applied on WM_SIZE');
    });

    test('header declares ApplyRoundedRegion', () {
      final String h = read('windows/runner/global_lookup_window.h');
      expect(h.contains('void ApplyRoundedRegion();'), isTrue);
    });
  });

  group('JS harness (node)', () {
    test('popup.css scoped-style structure (executes parser via node)',
        () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS structure test');
        return;
      }
      final File jsTest =
          File('test/lookup/global_lookup_popup_style_test.mjs');
      expect(jsTest.existsSync(), isTrue);
      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
      );
      expect(
        result.exitCode,
        0,
        reason: 'global-lookup popup style JS test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(),
          contains('global_lookup_popup_style_test: PASS'));
    });
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
