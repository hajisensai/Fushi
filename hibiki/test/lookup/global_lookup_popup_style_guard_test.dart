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

  group('P3c F1 — icon glyph fix (route A: monochrome symbol font)', () {
    late String render;
    setUpAll(() => render = read('lib/src/lookup/global_lookup_render.dart'));

    test('global-lookup iframe forces the monochrome Segoe UI Symbol font', () {
      // The popup card icons are Unicode chars (audio U+266A, arrows U+25B6/
      // U+25BC), NOT Material codepoints. Route A: give them a Windows font that
      // CARRIES those glyphs and is MONOCHROME, so they don't render as oversized
      // colour emoji.
      expect(render.contains('"Segoe UI Symbol"'), isTrue,
          reason: 'must pin the monochrome symbol font that carries ♪/▶/▼');
    });

    test('the emoji font is DROPPED (no colour-emoji rendering of ♪/✕)', () {
      // "Segoe UI Emoji" in the stack is exactly what made Windows render ♪/✕ as
      // colour emoji (the reported "icon shows wrong"); it must be gone.
      expect(render.contains('Segoe UI Emoji'), isFalse,
          reason: 'the emoji font caused the colour-emoji symbol rendering');
    });

    test('the icon font is applied to the audio button + collapse arrow glyph',
        () {
      // .audio-button = ♪ ; .glossary-group>summary::before = ▶/▼ content glyph.
      expect(render.contains('.audio-button'), isTrue);
      expect(render.contains('.glossary-group>summary::before'), isTrue,
          reason: 'the arrow glyph lives in the ::before content, so the font '
              'override must target the pseudo-element');
    });

    test('the icon CSS is global-lookup scoped (buildFrameSettingsJs only)',
        () {
      // buildFrameSettingsJs is the global-lookup-only per-frame body; the in-app
      // popup (dictionary_popup_webview) never calls it, so this never leaks.
      expect(render.contains('String buildFrameSettingsJs('), isTrue);
      final String inApp =
          read('lib/src/pages/implementations/dictionary_popup_webview.dart');
      expect(inApp.contains('buildFrameSettingsJs'), isFalse,
          reason: 'in-app popup must not run the global-lookup icon override');
    });
  });

  group('P3c F2 — outer shell chrome (.global-lookup-frame-shell)', () {
    late String host;
    setUpAll(() => host = read('assets/popup/global_lookup_host.js'));

    test('shell carries the hoshi card border + radius + drop shadow', () {
      expect(host.contains('.global-lookup-frame-shell{'), isTrue);
      expect(host.contains('border:1px solid rgba(120,120,128,0.36)'), isTrue,
          reason: 'hoshi shell border spec');
      expect(host.contains('border-radius:10px'), isTrue,
          reason: 'hoshi 10px card radius');
      expect(host.contains('box-shadow:0 3px 12px rgba(0,0,0,0.22)'), isTrue,
          reason:
              'hoshi drop shadow (renders inside the enlarged bbox window)');
    });

    test('shell background stays transparent (iframe paints the card fill)',
        () {
      // The iframe (popup.html) already paints the THEME background + the
      // html.global-lookup body border, so the shell must NOT add a second fill.
      // The chrome rule is the .global-lookup-frame-shell block carrying the
      // border (the first such block is the D1 reveal-gate visibility rule).
      final int chromeAt =
          host.indexOf('border:1px solid rgba(120,120,128,0.36)');
      final int ruleStart =
          host.lastIndexOf('.global-lookup-frame-shell{', chromeAt);
      final String rule =
          host.substring(ruleStart, host.indexOf('}', chromeAt));
      expect(rule.contains('background:transparent'), isTrue,
          reason: 'shell owns only the rounded clip + shadow, not the fill');
    });

    test('dark variant is keyed on data-theme stamped by the render payload',
        () {
      expect(host.contains('.global-lookup-frame-shell[data-theme="dark"]'),
          isTrue,
          reason:
              'the host document has no theme of its own; the shell reads a '
              'per-layer data-theme the render payload supplies');
      expect(host.contains('descriptor && descriptor.theme'), isTrue,
          reason: 'host.js must stamp data-theme from the descriptor');
      final String render = read('lib/src/lookup/global_lookup_render.dart');
      expect(render.contains("map['theme'] ="), isTrue,
          reason: 'the render payload must carry the resolved brightness');
    });

    test('the shell chrome stays global-lookup scoped (host.js only)', () {
      // host.js is C++-injected into the global-lookup window ONLY; the in-app
      // popup never loads it, so .global-lookup-frame-shell can never reach it.
      expect(host.contains('window.top !== window.self'), isTrue,
          reason: 'host runs on the top-level global-lookup document only');
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
