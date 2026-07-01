import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1065 guard -- the app-OUTSIDE / floating-subtitle popup (popup_main
/// host) must render with a TRANSPARENT `<html>` documentElement.
///
/// Root cause of the reported washout: popup.css fills BOTH `<html>` and `<body>`
/// with the opaque theme surface (`html,body{background-color:var(--background-
/// color,transparent)}`). The desktop bare-WebView2 global-lookup path already
/// neutralises `<html>` via `html.global-lookup{background:transparent}`, but the
/// mobile external popup (popup_main -> PopupDictionaryPage -> DictionaryPopupLayer
/// -> DictionaryPopupWebView) got NO such class, so its `<html>` filled the whole
/// WebView viewport opaque near-white ON TOP of the transparent floating window +
/// Flutter `HibikiPopupSurface` card = full-viewport wash in light themes.
///
/// The fix mirrors the proven global-lookup scoping with a NEW `mobile-external`
/// document class (transparent `<html>` only, NO body chrome -- the Flutter card
/// owns border/radius/fill). These guards lock the wiring in source so a later
/// refactor can neither drop the transparent rule nor leak it into the in-app
/// popup / desktop global-lookup (which stay opaque-html by design).
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  group('popup.css -- mobile-external transparent <html> rule', () {
    late String css;
    setUpAll(() => css = read('assets/popup/popup.css'));

    test('html.mobile-external is transparent (kills the viewport wash)', () {
      expect(
        RegExp(r'html\.mobile-external\s*\{[^}]*background:\s*transparent')
            .hasMatch(css),
        isTrue,
        reason: 'html.mobile-external must be transparent so the opaque '
            'documentElement fill no longer washes the external popup white',
      );
    });

    test('the mobile-external rule adds NO body chrome (Flutter owns the card)',
        () {
      expect(css.contains('html.mobile-external body'), isFalse,
          reason: 'the Flutter surface owns the card chrome; the mobile scope '
              'only makes <html> transparent, it must not draw a body card');
    });

    test('the in-app html,body opaque var fill is untouched (no scope leak)',
        () {
      expect(
        css.contains('background-color: var(--background-color, transparent)'),
        isTrue,
        reason: 'the in-app opaque html,body fill must remain (no regression)',
      );
    });
  });

  group('shared builder -- mobile-external class is gated', () {
    late String inject;
    setUpAll(() => inject =
        read('lib/src/pages/implementations/popup_settings_injection.dart'));

    test('PopupSettingsOptions exposes a mobileExternal flag', () {
      expect(inject.contains('final bool mobileExternal;'), isTrue,
          reason: 'the shared options must carry the mobile-external toggle');
      expect(inject.contains('this.mobileExternal = false'), isTrue,
          reason: 'mobileExternal must default to false (in-app / desktop '
              'global-lookup stay opaque-html)');
    });

    test('the shared builder adds the mobile-external class when requested',
        () {
      expect(
        inject.contains("classList.add('mobile-external')"),
        isTrue,
        reason:
            'the single source of truth must tag the doc mobile-external so '
            'popup.css turns <html> transparent on the external popup path',
      );
    });

    test('global-lookup and mobile-external are mutually exclusive branches',
        () {
      expect(inject.contains("classList.add('global-lookup')"), isTrue);
      final int gAt = inject.indexOf('final String classLine = globalLookup');
      expect(gAt, greaterThan(-1));
      final String block = inject.substring(gAt, gAt + 400);
      expect(block.contains('mobileExternal'), isTrue,
          reason: 'the class ternary must branch on mobileExternal after '
              'globalLookup (mutually exclusive)');
    });
  });

  group('widget wiring -- external popup sets the flag, in-app never', () {
    test('DictionaryPopupWebView exposes transparentDocumentBackground (false)',
        () {
      final String src =
          read('lib/src/pages/implementations/dictionary_popup_webview.dart');
      expect(src.contains('final bool transparentDocumentBackground;'), isTrue,
          reason: 'the popup WebView must carry the transparent-doc toggle');
      expect(src.contains('this.transparentDocumentBackground = false'), isTrue,
          reason:
              'it must default to false (in-app opaque-html, no regression)');
      expect(
        src.contains('mobileExternal: widget.transparentDocumentBackground'),
        isTrue,
        reason: 'the widget flag must feed the shared builder mobileExternal',
      );
    });

    test('DictionaryPopupLayer forwards the flag to the WebView', () {
      final String layer =
          read('lib/src/pages/implementations/dictionary_popup_layer.dart');
      expect(
          layer.contains('final bool transparentDocumentBackground;'), isTrue,
          reason: 'the layer must carry the toggle to forward');
      expect(
        layer.contains(
            'transparentDocumentBackground: transparentDocumentBackground'),
        isTrue,
        reason:
            'the layer must pass the flag straight to DictionaryPopupWebView',
      );
      expect(
          layer.contains('this.transparentDocumentBackground = false'), isTrue,
          reason: 'default false so in-app hosts stay opaque-html');
    });

    test('popup_dictionary_page (mobile external host) sets the flag true', () {
      final String page =
          read('lib/src/pages/implementations/popup_dictionary_page.dart');
      expect(page.contains('transparentDocumentBackground: true'), isTrue,
          reason: 'the app-outside / floating-subtitle popup MUST request the '
              'transparent <html> (this is the washout fix entry point)');
    });

    test('in-app hosts do NOT set the flag (stay opaque-html, zero regression)',
        () {
      for (final String path in <String>[
        'lib/src/pages/base_source_page.dart',
        'lib/src/pages/implementations/dictionary_page_mixin.dart',
      ]) {
        final String src = read(path);
        expect(src.contains('transparentDocumentBackground'), isFalse,
            reason: '$path is an in-app host; it must not request the '
                'transparent <html> (that would wash the in-app popup)');
      }
    });
  });
}
