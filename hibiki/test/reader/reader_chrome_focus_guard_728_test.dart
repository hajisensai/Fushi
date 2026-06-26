import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-728 source-scan focus guards (TODO-700 invariant must not regress):
///  - The bottom chrome bars stay wrapped in ExcludeFocus (out of the focus
///    traversal pool).
///  - _setChromeVisible / _applyGamepadPresence only flip _showChrome + reapply
///    insets + requestFocus() — they never call moveFocusToChrome or otherwise
///    push the bar into the focus model.
///  - The top-progress tap-to-toggle GestureDetector is NOT wrapped in Focus /
///    canRequestFocus (it must remain a pure pointer surface, not a focus node).
void main() {
  final String chrome = File(
    'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
  ).readAsStringSync();

  // Strips '//' line comments so a guard inspects only real code (doc comments
  // legitimately mention the very tokens we forbid in code).
  String codeOnly(String segment) => segment
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  test('bottom chrome bars remain ExcludeFocus', () {
    expect('ExcludeFocus('.allMatches(chrome).length, greaterThanOrEqualTo(2));
  });

  test('_setChromeVisible only flips chrome + insets + requestFocus', () {
    final int start = chrome.indexOf('void _setChromeVisible(bool visible)');
    expect(start, isNonNegative);
    final int end = chrome.indexOf('void _applyGamepadPresence', start);
    expect(end, greaterThan(start));
    final String body = codeOnly(chrome.substring(start, end));
    expect(body, contains('_showChrome = visible'));
    expect(body, contains('_applyChromeInsets()'));
    expect(body, contains('_focusNode.requestFocus()'));
    // Must NOT resurrect the removed moveFocusToChrome path or touch the chrome
    // focus scope directly.
    expect(body, isNot(contains('moveFocusToChrome')));
    expect(body, isNot(contains('_chromeFocusScope')));
  });

  test('top-progress tap GestureDetector has no Focus wrapper', () {
    final int start = chrome.indexOf('Widget _buildTopProgressBar()');
    expect(start, isNonNegative);
    final int end = chrome.indexOf('// ── Theme Colors', start);
    expect(end, greaterThan(start));
    final String body = codeOnly(chrome.substring(start, end));
    expect(body, contains('HitTestBehavior.opaque'));
    expect(body, contains('onTap: _toggleChrome'));
    expect(body, isNot(contains('Focus(')));
    expect(body, isNot(contains('canRequestFocus')));
  });
}
