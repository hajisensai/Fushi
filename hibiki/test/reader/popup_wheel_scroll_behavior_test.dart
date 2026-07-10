import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1387: the lookup popup froze on a Windows precision touchpad
/// ("时好时坏") because the document wheel handler in assets/popup/popup.js has
/// no sub-pixel remainder accumulator: a touchpad reports deltaMode=PIXEL with a
/// tiny fractional deltaY, and after POPUP_WHEEL_PIXEL_FACTOR (0.24) and the zoom
/// divide each frame is a fraction of a layout pixel. scrollBy(fraction) was lost
/// every frame while preventDefault killed native scroll, so slow scrolling moved
/// ~0px; a fast fling cleared the 1px threshold, hence the intermittency. It also
/// dropped genuine vertical frames that carried horizontal jitter.
///
/// popup_wheel_scroll_asset_test.dart guards the SOURCE (constants + accumulator).
/// This test executes the REAL handler in Node against synthetic touchpad / mouse
/// wheel events and asserts the popup actually SCROLLS (real displacement), the
/// fix that constant-only guards cannot prove. Skipped when node is unavailable.
void main() {
  test(
    'popup wheel handler scrolls on synthetic touchpad + mouse events (node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest =
          File('test/reader/popup_wheel_scroll_behavior_test.js');
      expect(jsTest.existsSync(), isTrue,
          reason: 'behavior harness ${jsTest.path} must exist');

      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
      );

      expect(
        result.exitCode,
        0,
        reason: 'popup wheel behavior test failed. '
            'stdout: ${result.stdout} stderr: ${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    },
  );
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
