import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/global_lookup_controller.dart';

/// TODO-867 P1 — app-external global lookup must resolve dictionary media for
/// BOTH custom schemes, symmetrically with the in-app InAppWebView.
///
/// Root cause it guards: the overlay WebView2 used to register ONLY `image://`
/// and the Dart resolver only read `queryParameters['path']`, so dictionary
/// `<link>` stylesheets (rewritten to `dictmedia://<path>?dictionary=..`, where
/// the path is in the URL HOST, not the query) 404'd → icons/CSS missing in the
/// app-external popup. Two halves are guarded here:
///   1. Source-scan symmetry: the native overlay registers a custom-scheme set
///      that is a superset of the in-app `dictionaryMediaCustomSchemes`.
///   2. Pure parse: [resolveGlobalLookupMedia] extracts (dictionary, path,
///      contentType) scheme-aware for image:// (query path, MIME by extension)
///      and dictmedia:// (host path, text/css).
void main() {
  String read(String p) => File(p).readAsStringSync();

  group('TODO-867 P1 scheme registration symmetry (native vs in-app)', () {
    test('overlay WebView2 registers a superset of in-app media schemes', () {
      // The in-app source of truth for the custom-scheme set.
      final String inApp =
          read('lib/src/pages/implementations/dictionary_webview_media.dart');
      final RegExp listRe = RegExp(
        r'dictionaryMediaCustomSchemes\s*=\s*<String>\[(.*?)\]',
        dotAll: true,
      );
      final Match? m = listRe.firstMatch(inApp);
      expect(m, isNotNull,
          reason: 'could not locate dictionaryMediaCustomSchemes literal');
      final Set<String> inAppSchemes = RegExp("'([a-z]+)'")
          .allMatches(m!.group(1)!)
          .map((Match e) => e.group(1)!)
          .toSet();
      // image + dictmedia today; if the in-app list grows this guard tightens.
      expect(inAppSchemes, containsAll(<String>['image', 'dictmedia']));

      // The native overlay must register every in-app scheme — and crucially
      // wire it into the regs[] array that is actually passed to
      // SetCustomSchemeRegistrations. Counting bare constructions is not enough
      // (a registration not handed to SetCustomSchemeRegistrations is inert), so
      // resolve variable->scheme then read the regs[] array membership + count.
      // Removing dictmedia from regs[] (the original asymmetry) turns this red.
      final String cpp = read('windows/runner/global_lookup_window.cpp');
      // Map each `auto <var> = Make<CoreWebView2CustomSchemeRegistration>(L"x")`
      // to its scheme string.
      final Map<String, String> varToScheme = <String, String>{};
      for (final Match m in RegExp(
        r'(\w+)\s*=\s*Make<CoreWebView2CustomSchemeRegistration>\(L"([a-z]+)"\)',
      ).allMatches(cpp)) {
        varToScheme[m.group(1)!] = m.group(2)!;
      }
      // Extract the regs[] array element list.
      final Match? regsArray =
          RegExp(r'regs\[\]\s*=\s*\{([^}]*)\}', dotAll: true).firstMatch(cpp);
      expect(regsArray, isNotNull, reason: 'could not locate regs[] array');
      final Set<String> wiredSchemes = RegExp(r'(\w+)\.Get\(\)')
          .allMatches(regsArray!.group(1)!)
          .map((Match e) => varToScheme[e.group(1)!])
          .whereType<String>()
          .toSet();
      expect(wiredSchemes, containsAll(inAppSchemes),
          reason: 'native overlay must WIRE every in-app media scheme into '
              'regs[]; in-app=$inAppSchemes wired=$wiredSchemes');
      // And SetCustomSchemeRegistrations count must match the array size.
      final Match? count =
          RegExp(r'SetCustomSchemeRegistrations\((\d+),').firstMatch(cpp);
      expect(count, isNotNull);
      expect(int.parse(count!.group(1)!), wiredSchemes.length,
          reason: 'SetCustomSchemeRegistrations count must equal regs[] size');
    });

    test('overlay routes both schemes to the media resolver (not passthrough)',
        () {
      final String cpp = read('windows/runner/global_lookup_window.cpp');
      // Both schemes are matched in WebResourceRequested and only OTHER urls
      // fall through to the virtual host.
      expect(cpp.contains('url.rfind("image://", 0) == 0'), isTrue);
      expect(cpp.contains('url.rfind("dictmedia://", 0) == 0'), isTrue);
      // Content-Type is derived from the URL, not hardcoded to image/png.
      expect(cpp.contains('MediaContentTypeHeader('), isTrue);
      expect(
        cpp.contains('L"Content-Type: image/png", &resp'),
        isFalse,
        reason: 'must not hardcode image/png (would reject dictmedia CSS)',
      );
    });
  });

  group('TODO-867 P1 resolveGlobalLookupMedia (pure parse)', () {
    test('image:// — dictionary+path from query, MIME by extension', () {
      final GlobalLookupMediaRequest? r = resolveGlobalLookupMedia(
        'image://?dictionary=My%20Dict&path=sub%2Fpic.png',
      );
      expect(r, isNotNull);
      expect(r!.dictionary, 'My Dict');
      expect(r.path, 'sub/pic.png');
      expect(r.contentType, 'image/png');
    });

    test('image:// — jpg/gif/webp/svg/unknown extension MIME', () {
      String? mime(String ext) =>
          resolveGlobalLookupMedia('image://?dictionary=d&path=a.$ext')
              ?.contentType;
      expect(mime('jpg'), 'image/jpeg');
      expect(mime('jpeg'), 'image/jpeg');
      expect(mime('gif'), 'image/gif');
      expect(mime('webp'), 'image/webp');
      expect(mime('svg'), 'image/svg+xml');
      expect(mime('bin'), 'application/octet-stream');
    });

    test('dictmedia:// — path from HOST, dictionary from query, text/css', () {
      final GlobalLookupMediaRequest? r = resolveGlobalLookupMedia(
        'dictmedia://style.css?dictionary=My%20Dict',
      );
      expect(r, isNotNull);
      expect(r!.dictionary, 'My Dict');
      expect(r.path, 'style.css');
      expect(r.contentType, 'text/css');
    });

    test('dictmedia:// — percent-encoded nested host path is decoded', () {
      final GlobalLookupMediaRequest? r = resolveGlobalLookupMedia(
        'dictmedia://${Uri.encodeComponent('css/main.css')}?dictionary=d',
      );
      expect(r, isNotNull);
      expect(r!.path, 'css/main.css');
      expect(r.contentType, 'text/css');
    });

    test('missing fields / unknown scheme -> null (served as 404)', () {
      expect(
          resolveGlobalLookupMedia('image://?path=a.png'), isNull); // no dict
      expect(resolveGlobalLookupMedia('image://?dictionary=d'), isNull); // path
      expect(resolveGlobalLookupMedia('dictmedia://style.css'), isNull); // dict
      expect(resolveGlobalLookupMedia('http://x/y.png'), isNull);
    });
  });
}
