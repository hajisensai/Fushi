import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-706 (TODO-1392): the lookup popup rendered BLANK on every surface
/// (reader / video / home / app-external + the browser extension) after PR#12
/// (BUG-688) wrapped the popup DOM behind a `window.__fushiRoot` shadow-root
/// marker.
///
/// Root cause: popup.js declared a top-level helper `function __fushiRoot(){
/// return window.__fushiRoot || document; }`. A classic-script top-level
/// function declaration ALSO creates a same-named property on the global object,
/// so the declaration itself set `window.__fushiRoot` = the function. In-app the
/// extension never overwrites it, so `window.__fushiRoot` was truthy (the
/// function), and `__fushiContainer()` / `__fushiRootNode()` then called
/// `.querySelector` on a function -> `TypeError: ... is not a function` ->
/// `renderPopup()` aborted -> the popup showed nothing though the FFI lookup
/// returned entries.
///
/// Fix: the internal helper was renamed to `__fushiRootNode()` so it no longer
/// shadows the `window.__fushiRoot` marker. These guards lock the invariant on
/// the three shipped popup.js assets: the marker read is kept, but no helper may
/// be *declared* with the marker's name.
void main() {
  const List<String> popupJsPaths = <String>[
    'assets/popup/popup.js',
    'assets/browser_extension/vendor/popup.js',
    '../tools/browser-extension/vendor/popup.js',
  ];

  for (final String rel in popupJsPaths) {
    test(
        'popup.js "$rel" does not shadow the window.__fushiRoot marker with a '
        'same-named function declaration', () {
      final File f = File(rel);
      expect(f.existsSync(), isTrue, reason: 'missing popup.js asset: $rel');
      final String js = f.readAsStringSync();

      // The shadow-DOM marker contract (BUG-688) must remain: popup.js still
      // reads window.__fushiRoot (set only by the extension's content.js).
      expect(js.contains('window.__fushiRoot'), isTrue,
          reason: 'popup.js must keep reading the window.__fushiRoot marker');

      // REGRESSION LOCK: no top-level `function __fushiRoot(` — declaring a
      // function with the marker's exact name republishes window.__fushiRoot as
      // that function, making it truthy in-app and blanking the popup.
      final RegExp collidingDecl = RegExp(r'function\s+__fushiRoot\s*\(');
      expect(collidingDecl.hasMatch(js), isFalse,
          reason: 'a `function __fushiRoot(` declaration collides with the '
              'window.__fushiRoot shadow-root marker and blanks the popup '
              '(BUG-706). Name the helper something else (e.g. '
              '__fushiRootNode).');

      // The renamed helper must exist and be used (the DOM-access indirection is
      // still present, just collision-free).
      expect(js.contains('function __fushiRootNode('), isTrue,
          reason: 'the collision-free root helper __fushiRootNode must exist');
      expect(js.contains('__fushiRootNode()'), isTrue,
          reason: 'popup.js must route DOM access through __fushiRootNode()');
    });
  }
}
