import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reader consumes gamepad hold-A as caret long-press', () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_page.dart')
            .readAsStringSync();

    expect(source, contains('GamepadLongPressIntent'));
    expect(source, contains('_handleGamepadLongPress'));
    expect(source, contains('CaretAction.longPress'));
    expect(source, contains('_caretLongPress()'));
    expect(source, contains('ReaderCaretScripts.longPressInvocation()'));
  });

  test('popup WebView exposes caretLongPress through ReaderCaretScripts', () {
    final String source =
        File('lib/src/pages/implementations/dictionary_popup_webview.dart')
            .readAsStringSync();

    expect(source, contains('Future<void> caretLongPress()'));
    expect(source, contains('ReaderCaretScripts.longPressInvocation()'));
  });

  test('popup dictionary summary long-press is callable without touch events',
      () {
    final String source = File('assets/popup/popup.js').readAsStringSync();

    expect(
        source, contains('summary.__hoshiToggleSelection = toggleSelection'));
    expect(source, contains('window.__hoshiDictLongPress'));
    expect(source, contains("typeof toggle !== 'function'"));
  });
}
