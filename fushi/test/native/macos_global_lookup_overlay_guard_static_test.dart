// Source guard for the macOS app-external global lookup overlay
// (macos/Runner/GlobalLookupOverlay.swift + SelectionCaptureMac.swift), the
// macOS counterpart of windows/runner/global_lookup_window.cpp. macOS native
// code cannot be compiled on the Windows/Linux CI runners, so this scans the
// Swift sources (like macos_foreground_selection_guard_static_test) to guard
// that the MethodChannel contract shared with lib/src/lookup/
// overlay_window_channel.dart, the JS entry points the host expects, the
// never-activate window contract and the Xcode wiring stay in place.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String relativeToFushi) {
    final File file = File(relativeToFushi);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected file at ${file.absolute.path}',
    );
    return file.readAsStringSync().replaceAll('\r\n', '\n');
  }

  group('macOS global lookup overlay (GlobalLookupOverlay.swift)', () {
    late String swift;
    late String dartChannel;
    setUpAll(() {
      swift = read('macos/Runner/GlobalLookupOverlay.swift');
      dartChannel = read('lib/src/lookup/overlay_window_channel.dart');
    });

    test('registers the shared global_lookup channel', () {
      expect(swift, contains('"app.fushi.reader/global_lookup"'));
      expect(
        read('lib/src/utils/misc/channel_constants.dart'),
        contains("/global_lookup'"),
      );
    });

    test('implements every forward method the Dart channel invokes', () {
      // Every _invoke<...>('name' ...) in the Dart wrapper must have a Swift
      // `case "name"` (an unhandled one would reply MethodNotImplemented and
      // silently break that step of the lookup pipeline on macOS).
      final RegExp invoke = RegExp(r"_invoke<[^>]+>\(\s*'([a-zA-Z]+)'");
      final Set<String> methods = invoke
          .allMatches(dartChannel)
          .map((RegExpMatch m) => m.group(1)!)
          .toSet();
      expect(methods, contains('showAt'));
      expect(methods, contains('revealStack'));
      expect(methods, contains('setGlobalMouseTrigger'));
      for (final String method in methods) {
        expect(
          swift,
          contains('case "$method"'),
          reason: 'Swift overlay must handle "$method"',
        );
      }
    });

    test('emits every reverse call the Dart channel handles', () {
      for (final String reverse in <String>[
        'getMedia',
        'jsMessage',
        'overlayHidden',
        'nativeError',
        'globalMouseTrigger',
      ]) {
        expect(dartChannel, contains("case '$reverse'"));
        expect(
          swift,
          contains('invokeMethod("$reverse"'),
          reason: 'Swift overlay must emit "$reverse"',
        );
      }
      // jsMessage / overlayHidden carry the routed envelope
      // {payload, source, routeEpoch, lookupEpoch} like the Windows runner.
      expect(swift, contains('envelope["payload"] = json'));
      expect(swift, contains('"routeEpoch": NSNumber(value: routeEpoch)'));
    });

    test('calls the same host / adapter JS entry points as Windows', () {
      for (final String entry in <String>[
        'window.__globalLookupHost.commitLayerShift(',
        'resetLayerOffsetForLegacyReveal',
        'window.__globalLookupHost.handleGlobalClick(',
        'window.__globalLookupHost.gamepadAction(',
        'window.__globalLookupHost.endLiveResize();',
        'window.__fushiBridgeResolve(',
      ]) {
        expect(swift, contains(entry), reason: 'missing JS entry $entry');
      }
      // The gamepad action whitelist is pinned (strings are spliced into JS).
      expect(swift, contains('["next", "prev", "mine", "audio", "scroll"]'));
    });

    test('bridges chrome.webview.postMessage + injects adapter and host', () {
      expect(swift, contains('window.chrome.webview = {'));
      expect(swift, contains('window.webkit.messageHandlers.'));
      expect(
        swift,
        contains('injectionTime: .atDocumentStart, forMainFrameOnly: false'),
      );
      expect(
        swift,
        contains('"popup_bridge_adapter.js", "global_lookup_host.js"'),
      );
      expect(swift, contains('global_lookup_host.html'));
    });

    test('deferred bridge handlers match the Windows router', () {
      final String cpp = read('windows/runner/global_lookup_window.cpp');
      for (final String handler in <String>[
        'resolveWordAudio',
        'queryLocalAudio',
        'favoriteEntry',
        'favoriteCheck',
        'mineEntry',
        'duplicateCheck',
        'overwriteTargetNoteId',
        'updateEntry',
        'findMinedMatches',
        'openMinedNote',
        'openInAnki',
      ]) {
        expect(
          cpp,
          contains('"\\"$handler\\""'),
          reason: 'Windows deferred list changed: $handler',
        );
        expect(
          swift,
          contains('"$handler"'),
          reason: 'macOS deferred list must include $handler',
        );
      }
    });

    test('serves image:// and dictmedia:// through Dart getMedia', () {
      expect(swift, contains('forURLScheme: "image"'));
      expect(swift, contains('forURLScheme: "dictmedia"'));
      expect(swift, contains('FlutterStandardTypedData'));
      // dictmedia is always CSS, image by extension (MediaContentTypeHeader).
      expect(swift, contains('if url.scheme?.lowercased() == "dictmedia"'));
    });

    test('never activates or takes keyboard focus; dismisses like Windows', () {
      expect(swift, contains('.nonactivatingPanel'));
      expect(
        swift,
        contains('override var canBecomeKey: Bool { return false }'),
      );
      expect(
        swift,
        contains('override var canBecomeMain: Bool { return false }'),
      );
      expect(swift, contains('orderFrontRegardless()'));
      // click-outside (global + local monitors) + foreground app switch.
      expect(swift, contains('addGlobalMonitorForEvents'));
      expect(swift, contains('addLocalMonitorForEvents'));
      expect(swift, contains('NSWorkspace.didActivateApplicationNotification'));
      // Armed only while shown, released on hide (BUG-1077 discipline).
      expect(swift, contains('private func armDismissMonitors()'));
      expect(swift, contains('disarmDismissMonitors()'));
    });

    test('showAt reply carries the physical-px work area + monitor dpr', () {
      for (final String key in <String>[
        '"ok"',
        '"workW"',
        '"workH"',
        '"cursorWorkX"',
        '"cursorWorkY"',
        '"monitorDpr"',
      ]) {
        expect(swift, contains(key));
      }
      expect(swift, contains('backingScaleFactor'));
      expect(swift, contains('visibleFrame'));
    });

    test('block-capture maps to NSWindow.sharingType', () {
      expect(swift, contains('sharingType = blockCapture ? .none : .readOnly'));
    });

    test('test hooks are env-gated (no production JS evaluation surface)', () {
      expect(swift, contains('environment["FUSHI_TEST_INPUT"] != nil'));
      expect(swift, contains('case "debugEvaluateJs" where testHooksEnabled'));
      expect(swift, contains('case "debugSnapshot" where testHooksEnabled'));
    });
  });

  group('macOS selection capture (SelectionCaptureMac.swift)', () {
    late String swift;
    late String appDelegate;
    late String dart;
    setUpAll(() {
      swift = read('macos/Runner/SelectionCaptureMac.swift');
      appDelegate = read('macos/Runner/AppDelegate.swift');
      dart = read('lib/src/lookup/selection_capture_ffi.dart');
    });

    test('rides the shared foreground_selection channel', () {
      expect(
        appDelegate,
        contains('MacSelectionCapture.handle(call, result: result)'),
      );
      for (final String method in <String>[
        'captureSelection',
        'isAccessibilityTrusted',
        'requestAccessibilityTrust',
      ]) {
        expect(swift, contains('case "$method"'));
        expect(dart, contains("'$method'"));
      }
    });

    test('AX selection first, then clean ⌘C with pasteboard restore', () {
      expect(swift, contains('kAXSelectedTextAttribute'));
      expect(swift, contains('.maskCommand'));
      expect(swift, contains('post(tap: .cghidEventTap)'));
      expect(swift, contains('pasteboard.changeCount'));
      expect(swift, contains('pasteboard.clearContents()'));
      expect(swift, contains('pasteboard.writeObjects(items)'));
    });

    test('prompting is isolated to the explicit permission request path', () {
      // The prompting variant only in requestAccessibilityTrust. Dart calls
      // it from settings and the first explicit global-lookup trigger; it is
      // never part of app startup.
      final int prompts = 'AXIsProcessTrustedWithOptions'
          .allMatches(swift)
          .length;
      expect(prompts, 1);
      expect(swift, contains('case "requestAccessibilityTrust"'));
      expect(dart, contains('first explicit global-lookup'));
    });

    test('Dart macOS capture runs inside the clipboard gate', () {
      expect(dart, contains('if (Platform.isMacOS) {'));
      expect(
        dart,
        contains(
          '_runClipboardExclusive<String>(\n        _captureForegroundSelectionMac,',
        ),
      );
    });
  });

  group('Xcode wiring', () {
    test('both Swift files are in the Runner target sources', () {
      final String pbx = read('macos/Runner.xcodeproj/project.pbxproj');
      expect(pbx, contains('GlobalLookupOverlay.swift in Sources'));
      expect(pbx, contains('SelectionCaptureMac.swift in Sources'));
      expect(pbx, contains('path = GlobalLookupOverlay.swift;'));
      expect(pbx, contains('path = SelectionCaptureMac.swift;'));
    });

    test('AppDelegate owns the overlay controller', () {
      final String appDelegate = read('macos/Runner/AppDelegate.swift');
      expect(
        appDelegate,
        contains('globalLookupOverlay = GlobalLookupOverlayController('),
      );
    });
  });
}
