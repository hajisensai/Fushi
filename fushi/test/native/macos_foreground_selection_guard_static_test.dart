// TODO-1030 M1 -- source guard for the macOS Accessibility (AX) foreground-
// selection context capture (macos/Runner/AppDelegate.swift), the symmetric
// counterpart to the Windows UIA capture (windows/runner/foreground_selection
// .cpp). macOS native code cannot be compiled on the Windows/Linux CI runners,
// so this scans the Swift + Dart sources to guard that the AX call chain, the
// fail-open branches, the off-main-thread dispatch and the shared channel
// contract stay wired. It mirrors the Dart-side sentence_extraction_test and
// the settings coverage guard.
//
// A source scan (not a compile) so it asserts on unique real-code lines (e.g.
// the capture signature + the AX-trust guard) plus the API token set; a
// wholesale removal of the capture trips it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String relativeToHibiki) {
    final File file = File(relativeToHibiki);
    expect(file.existsSync(), isTrue,
        reason: 'expected file at ${file.absolute.path}');
    return file.readAsStringSync();
  }

  group('macOS AX foreground-selection capture (AppDelegate.swift)', () {
    late String code;
    setUpAll(() {
      code = read('macos/Runner/AppDelegate.swift');
    });

    test('registers the shared foreground_selection channel + captureContext',
        () {
      // Same channel name + method the Windows runner exposes and the Dart
      // SelectionCapture.captureForegroundContext invokes.
      expect(code, contains('app.fushi.reader/foreground_selection'));
      expect(code, contains('call.method == "captureContext"'));
      expect(code, contains('handleForegroundSelection'));
    });

    test('walks the AX selection + parameterized-range API chain', () {
      expect(code, contains('AXUIElementCreateSystemWide()'));
      expect(code, contains('kAXFocusedUIElementAttribute'));
      expect(code, contains('kAXSelectedTextAttribute'));
      expect(code, contains('kAXSelectedTextRangeAttribute'));
      expect(code, contains('kAXStringForRangeParameterizedAttribute'),
          reason: 'the expanded context window is fetched via the '
              'parameterized string-for-range attribute');
      expect(code, contains('AXUIElementCopyParameterizedAttributeValue('));
    });

    test('capture is a real function gated fail-open on AX trust', () {
      // Unique real-code lines: the capture signature and the trust guard that
      // returns nil (never prompt on the hotkey path).
      expect(code, contains('static func capture(maxExpand: Int) -> Result?'));
      expect(code, contains('guard AXIsProcessTrusted() else { return nil }'));
      // The handler replies nil on any capture miss so Dart falls back to the
      // clipboard capture (never break the existing lookup path).
      expect(code, contains('result(nil)'));
    });

    test('runs the blocking AX read off the main thread, replies on main', () {
      // Cross-process AX can block; capture on a background queue, complete the
      // FlutterResult back on the main (platform) thread.
      expect(code, contains('DispatchQueue.global('));
      expect(code, contains('DispatchQueue.main.async'));
    });

    test('offsets/expansion mirror the Windows contract', () {
      expect(code, contains('static let defaultExpand: Int = 600'),
          reason: 'mirrors kForegroundContextExpand (Windows)');
      // The channel reply carries the same keys the Dart side reads.
      expect(code, contains('contextText'));
      expect(code, contains('selStart'));
      expect(code, contains('selLen'));
      expect(code, contains('elapsedMs'));
    });

    test('documents the sandbox runtime constraint (honest fail-open)', () {
      // Keep the sandbox caveat in the source so a future reader/build does not
      // assume it works cross-app under the App Sandbox.
      expect(code, contains('SANDBOX NOTE'));
    });
  });

  group('Dart consumer allows macOS (selection_capture_ffi.dart)', () {
    test('captureForegroundContext is not gated to Windows only', () {
      final String dart = read('lib/src/lookup/selection_capture_ffi.dart');
      // The context capture path must run on macOS too (AX channel), not just
      // Windows; the gate excludes only truly-unsupported platforms.
      expect(dart, contains('!Platform.isWindows && !Platform.isMacOS'));
      expect(dart, contains('app.fushi.reader/foreground_selection'));
    });
  });
}
