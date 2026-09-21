import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) {
    final File file = File(path);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected file at ${file.absolute.path}',
    );
    return file.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('macOS global hotkey gates capture on Accessibility permission', () {
    final String controller = read(
      'lib/src/lookup/global_lookup_controller.dart',
    );
    expect(controller, contains('Platform.isMacOS'));
    expect(controller, contains('_ensureMacAccessibilityForSelection()'));
    expect(
      controller,
      contains('SelectionCapture.requestAccessibilityTrust()'),
    );
    expect(
      controller,
      contains('capturing now would read the wrong app'),
      reason: 'the permission pane becomes foreground; do not capture its text',
    );
  });

  test('macOS copy fallback restores the complete pasteboard on every exit', () {
    final String capture = read('macos/Runner/SelectionCaptureMac.swift');
    expect(capture, contains('func restorePasteboard()'));
    expect(capture, contains('restorePasteboard()\n      return nil'));
    expect(capture, contains('restorePasteboard()\n    return text'));
    expect(
      capture,
      contains('pasteboard.writeObjects(items)'),
      reason:
          'a failed global lookup must not destroy a copied image or rich text',
    );
  });
}
