import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/global_lookup_render.dart';

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
    test('the shared builder injects the global-lookup class (gated)', () {
      // TODO-895: the document tag moved into the SINGLE source of truth, gated
      // behind globalLookup so only the app-outside frame applies the scoped
      // popup.css chrome. The render.dart shim requests it via globalLookup:true.
      final String inject =
          read('lib/src/pages/implementations/popup_settings_injection.dart');
      expect(
        inject.contains(
            "document.documentElement.classList.add('global-lookup')"),
        isTrue,
        reason: 'the shared builder must tag the document when globalLookup',
      );
      final String render = read('lib/src/lookup/global_lookup_render.dart');
      expect(
          render.contains('PopupSettingsOptions(globalLookup: true)'), isTrue,
          reason:
              'the app-outside frame must request the global-lookup options');
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
    // TODO-895: the icon-font override moved into the SINGLE source of truth
    // popup_settings_injection.dart, gated behind options.globalLookup so only the
    // app-outside path emits it. The in-app popup still never receives it.
    late String inject;
    setUpAll(() => inject =
        read('lib/src/pages/implementations/popup_settings_injection.dart'));

    test('global-lookup iframe forces the monochrome Segoe UI Symbol font', () {
      // The popup card icons are Unicode chars (audio U+266A, arrows U+25B6/
      // U+25BC), NOT Material codepoints. Route A: give them a Windows font that
      // CARRIES those glyphs and is MONOCHROME, so they don't render as oversized
      // colour emoji.
      expect(inject.contains('"Segoe UI Symbol"'), isTrue,
          reason: 'must pin the monochrome symbol font that carries ♪/▶/▼');
    });

    test('the emoji font is DROPPED (no colour-emoji rendering of ♪/✕)', () {
      // "Segoe UI Emoji" in the stack is exactly what made Windows render ♪/✕ as
      // colour emoji (the reported "icon shows wrong"); it must be gone.
      expect(inject.contains('Segoe UI Emoji'), isFalse,
          reason: 'the emoji font caused the colour-emoji symbol rendering');
    });

    test('the icon font is applied to the audio button + collapse arrow glyph',
        () {
      // .audio-button = ♪ ; .glossary-group>summary::before = ▶/▼ content glyph.
      expect(inject.contains('.audio-button'), isTrue);
      expect(inject.contains('.glossary-group>summary::before'), isTrue,
          reason: 'the arrow glyph lives in the ::before content, so the font '
              'override must target the pseudo-element');
    });

    test(
        'the icon override is gated behind options.globalLookup (in-app never)',
        () {
      // The override is only emitted when options.globalLookup is true; the in-app
      // popup builds the shared body with globalLookup:false, so it never receives
      // the icon font. The render.dart shim still calls buildPopupSettingsJs with
      // globalLookup:true.
      expect(inject.contains('options.globalLookup ? _globalLookupIconFontJs'),
          isTrue,
          reason: 'icon override must be conditional on the globalLookup flag');
      final String render = read('lib/src/lookup/global_lookup_render.dart');
      expect(
          render.contains('PopupSettingsOptions(globalLookup: true)'), isTrue,
          reason:
              'the app-outside frame must request the global-lookup options');
      final String inApp =
          read('lib/src/pages/implementations/dictionary_popup_webview.dart');
      expect(inApp.contains('Segoe UI Symbol'), isFalse,
          reason:
              'in-app popup must not carry the global-lookup icon override');
    });
  });

  group('P3c F2 — outer shell chrome (.global-lookup-frame-shell)', () {
    late String host;
    setUpAll(() => host = read('assets/popup/global_lookup_host.js'));

    test('shell carries ONLY the radius + drop shadow (TODO-893: no border)',
        () {
      // TODO-893 symptom 1 — RESPONSIBILITY SPLIT. The single visible card
      // border belongs to the iframe (popup.css `html.global-lookup body`); the
      // shell must NOT draw a second border (that produced two concentric grey
      // rings with a white gap = the reported "white frame"). The shell keeps
      // the radius (so the shadow + overflow clip follow the rounded card) and
      // the drop-shadow the iframe element cannot cast.
      expect(host.contains('.global-lookup-frame-shell{'), isTrue);
      expect(host.contains('border-radius:10px'), isTrue,
          reason: 'hoshi 10px card radius (drives shadow + clip silhouette)');
      expect(host.contains('box-shadow:0 3px 12px rgba(0,0,0,0.22)'), isTrue,
          reason:
              'hoshi drop shadow (renders inside the enlarged bbox window)');
    });

    test('shell draws NO solid border (single border lives on the iframe body)',
        () {
      // The fix is exactly the removal of the shell border. Lock it so a later
      // edit cannot reintroduce the double-border. The border lives ONLY in
      // popup.css `html.global-lookup body` now.
      expect(host.contains('border:1px solid rgba(120,120,128,0.36)'), isFalse,
          reason: 'shell border was the double-border main cause; it is gone');
      expect(host.contains('border-color:rgba(255,255,255,0.34)'), isFalse,
          reason: 'the dark shell border-color override is gone too');
    });

    test('the SINGLE border lives on the iframe body (popup.css), not doubled',
        () {
      final String css = read('assets/popup/popup.css');
      // popup.css owns the one visible border.
      expect(css.contains('html.global-lookup body {'), isTrue);
      final int bodyAt = css.indexOf('html.global-lookup body {');
      final String bodyRule = css.substring(bodyAt, css.indexOf('}', bodyAt));
      expect(bodyRule.contains('border: 1px solid rgba(120, 120, 128, 0.36)'),
          isTrue,
          reason: 'the iframe body owns the one visible card border');
    });

    test('shell background stays transparent (iframe paints the card fill)',
        () {
      // The iframe (popup.html) already paints the THEME background + the
      // html.global-lookup body border, so the shell must NOT add a second fill.
      // The chrome rule is the .global-lookup-frame-shell block carrying the
      // radius (the first such block is the D1 reveal-gate visibility rule).
      final int chromeAt = host.indexOf('border-radius:10px');
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

  group('TODO-895 — settings injection is a single source of truth', () {
    late String inject;
    late String render;
    late String inApp;
    setUpAll(() {
      inject =
          read('lib/src/pages/implementations/popup_settings_injection.dart');
      render = read('lib/src/lookup/global_lookup_render.dart');
      inApp =
          read('lib/src/pages/implementations/dictionary_popup_webview.dart');
    });

    test('both call sites go through the shared buildPopupSettingsJs', () {
      // app-outside (buildFrameSettingsJs) and in-app (_pushResults) must both
      // delegate to the one builder, so the settings body can never drift again.
      expect(inject.contains('String buildPopupSettingsJs('), isTrue,
          reason: 'the single source of truth builder must exist');
      expect(render.contains('buildPopupSettingsJs('), isTrue,
          reason: 'the app-outside frame must call the shared builder');
      expect(inApp.contains('buildPopupSettingsJs('), isTrue,
          reason: 'the in-app popup must call the shared builder');
    });

    test('D1 — the dictionary font is injected by the shared builder', () {
      // app-outside used to lack the user dictionary font entirely; it now flows
      // through the shared font helper, so both paths apply the same font.
      expect(inject.contains("id = 'hoshi-dict-font'"), isTrue,
          reason: 'the shared builder must inject the dictionary font style');
      expect(inject.contains('DictionaryFontCss.build('), isTrue,
          reason: 'the font CSS must be built from the user dictionary fonts');
      // The app-outside file must NOT carry its own second font injection.
      expect(render.contains('hoshi-dict-font'), isFalse,
          reason: 'app-outside must not re-implement the font injection');
    });

    test('D2 — autoExpandDictionaries is in the shared body', () {
      // app-outside previously dropped this flag (folded popups never auto-
      // expanded). It now lives in the one body both paths emit.
      expect(inject.contains('window.autoExpandDictionaries ='), isTrue,
          reason: 'the shared body must inject autoExpandDictionaries');
      expect(inject.contains('appModel.popupAutoExpandDictionaries'), isTrue);
      // No second INJECTION of the flag in the app-outside file (a doc-comment
      // mention is fine; the actual `window.autoExpandDictionaries =` must not
      // be duplicated there).
      expect(render.contains('window.autoExpandDictionaries ='), isFalse,
          reason: 'app-outside must not re-inject the flag (single source)');
    });

    test('D3 — content zoom uses the clamped/NaN-guarded helper only', () {
      // app-outside used a bare inline `appUiScale * (...)` with no clamp/NaN
      // guard. The shared body must call popupContentZoom (the clamped helper),
      // and NEITHER builder may compute zoom inline anymore.
      expect(inject.contains('DictionaryPopupWebViewState.popupContentZoom('),
          isTrue,
          reason: 'the shared body must use the clamped zoom helper');
      expect(render.contains('appUiScale * ('), isFalse,
          reason: 'app-outside must not compute zoom inline (drift source)');
      expect(inject.contains('appModel.appUiScale * ('), isFalse,
          reason: 'the shared builder must defer zoom to popupContentZoom');
    });
  });

  group('TODO-893 v2 — three reopened symptoms (source guards)', () {
    test('symptom 1 — controller dispatches BOTH onLinkClick and textSelected',
        () {
      // Tapping plain glossary text emits textSelected (not onLinkClick); the
      // app-external controller used to register only onLinkClick, silently
      // dropping body taps. Lock that both handlers reach the shared nested
      // dispatch so a body tap opens a child card.
      final String controller =
          read('lib/src/lookup/global_lookup_controller.dart');
      expect(controller.contains("handler == 'textSelected'"), isTrue,
          reason: 'controller must handle the textSelected (body tap) trigger');
      expect(controller.contains("handler == 'onLinkClick'"), isTrue,
          reason: 'onLinkClick (headword/kanji) must still dispatch');
      expect(controller.contains('_dispatchNestedLookup('), isTrue,
          reason: 'both triggers share one dispatch helper (no special case)');
    });

    test('symptom 1 — host.js re-anchors textSelected like onLinkClick', () {
      // textSelected carries the same iframe-LOCAL rect in args[1]; without the
      // re-anchor the child card anchors at iframe-internal coords.
      final String host = read('assets/popup/global_lookup_host.js');
      expect(
        host.contains(
            "handler === 'onLinkClick' || handler === 'textSelected'"),
        isTrue,
        reason: 'transformFrameMessage must re-anchor both link + text taps',
      );
    });

    test('symptom 2 — popup.css makes html.global-lookup transparent', () {
      // The opaque documentElement fill clipped by the shell radius is the
      // residual "white frame"; transparent <html> leaves only body's rounded
      // card. Scoped so the in-app popup (no global-lookup class) is untouched.
      final String css = read('assets/popup/popup.css');
      expect(
        RegExp(r'html\.global-lookup\s*\{[^}]*background:\s*transparent')
            .hasMatch(css),
        isTrue,
        reason: 'html.global-lookup must be transparent so the clipped corners '
            'show the desktop, not opaque theme colour',
      );
      // The in-app html background rule stays (no global-lookup scope on it).
      expect(css.contains('html.global-lookup body {'), isTrue,
          reason: 'in-app vs global-lookup body scoping must remain intact');
    });

    test('symptom 3 — native reports the cursor work-area offset', () {
      // computeFrameRect screenW/H are work-area dimensions; the host child
      // anchor is window-local. Native must hand the window origin's offset
      // inside the work area so Dart can align the two zero points.
      final String fw = read('windows/runner/flutter_window.cpp');
      expect(fw.contains('cursorWorkX'), isTrue,
          reason: 'showAt reply must carry the work-area X offset');
      expect(fw.contains('cursorWorkY'), isTrue,
          reason: 'showAt reply must carry the work-area Y offset');
      expect(fw.contains('x - mi.rcWork.left'), isTrue,
          reason: 'X offset = window origin minus work-area left');
      expect(fw.contains('y - mi.rcWork.top'), isTrue,
          reason: 'Y offset = window origin minus work-area top');
    });

    test('symptom 3 — channel parses cursorWork offset into the show result',
        () {
      final String channel = read('lib/src/lookup/global_lookup_channel.dart');
      expect(channel.contains("reply['cursorWorkX']"), isTrue);
      expect(channel.contains("reply['cursorWorkY']"), isTrue);
      expect(channel.contains('this.cursorWorkX'), isTrue);
      expect(channel.contains('this.cursorWorkY'), isTrue);
    });

    test('symptom 3 — controller feeds selectionScreenOffset to the builder',
        () {
      // The window-local anchor must be lifted into the work-area-absolute
      // domain before the cascade math (and shifted back after).
      final String controller =
          read('lib/src/lookup/global_lookup_controller.dart');
      expect(controller.contains('_cursorWorkX'), isTrue);
      expect(controller.contains('_cursorWorkY'), isTrue);
      expect(
        controller.contains(
            'selectionScreenOffset: Offset(_cursorWorkX, _cursorWorkY)'),
        isTrue,
        reason: 'the cascade builder must receive the work-area offset',
      );
    });

    test('symptom 3 — render builder shifts anchor in then shifts result out',
        () {
      // computeFrameRect stays a pure single-domain function: the builder adds
      // the offset to the anchor before, and subtracts it from left/top after.
      final String render = read('lib/src/lookup/global_lookup_render.dart');
      expect(render.contains('Offset selectionScreenOffset'), isTrue,
          reason: 'builder must accept the offset param');
      expect(render.contains('anchorRect.shift(selectionScreenOffset)'), isTrue,
          reason: 'anchor lifted into work-area-absolute domain before layout');
      expect(render.contains('r.left - selectionScreenOffset.dx'), isTrue,
          reason: 'result shifted back to window-local (X)');
      expect(render.contains('r.top - selectionScreenOffset.dy'), isTrue,
          reason: 'result shifted back to window-local (Y)');
    });
  });

  group('TODO-938 — vertical cascade wired from writingMode', () {
    // App-OUTSIDE global lookup popped its nested cards with isVertical
    // HARDCODED false, so a vertical-writing book's lookup cards always cascaded
    // up/down (horizontal-writing layout). The render styling itself is already
    // shared with the in-app popup (TODO-895); this was the one布局参数 still
    // hardcoded. The fix reads the active reader's writingMode (same接口/判据 as
    // the in-app reader) with a null fallback for the over-another-app case.
    test('isVerticalFromWritingMode: vertical modes -> true', () {
      expect(isVerticalFromWritingMode('vertical-rl'), isTrue);
      expect(isVerticalFromWritingMode('vertical-lr'), isTrue);
    });

    test('isVerticalFromWritingMode: horizontal / null / empty -> false', () {
      expect(isVerticalFromWritingMode('horizontal-tb'), isFalse,
          reason: 'horizontal book cascades up/down');
      expect(isVerticalFromWritingMode(null), isFalse,
          reason: 'no active reader (lookup over another app) -> horizontal');
      expect(isVerticalFromWritingMode(''), isFalse);
    });

    test('controller no longer hardcodes isVertical:false; reads writingMode',
        () {
      final String controller =
          read('lib/src/lookup/global_lookup_controller.dart');
      // The dead `isVertical: false,` literal in the stack payload must be gone.
      expect(controller.contains('isVertical: false'), isFalse,
          reason: 'the hardcoded false cascade flag must be removed');
      // It must now derive the flag from the active reader writingMode via the
      // shared判据 helper.
      // Whitespace-collapsed so dart format line-wrapping at the `(` can't break
      // the match (the call is long and the formatter splits the argument).
      final String controllerFlat = controller.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        controllerFlat.contains(
            'isVerticalFromWritingMode( ReaderHibikiSource.readerSettings?.writingMode)'),
        isTrue,
        reason: 'cascade vertical flag must come from the reader writingMode',
      );
      expect(controller.contains('isVertical: isVertical'), isTrue,
          reason: 'the resolved flag must feed the frame payload');
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
