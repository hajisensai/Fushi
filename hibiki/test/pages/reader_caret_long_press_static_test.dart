import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

void main() {
  test('reader consumes gamepad hold-A as caret long-press', () {
    final String source = readReaderPageSource();

    expect(source, contains('GamepadLongPressIntent'));
    expect(source, contains('_handleGamepadLongPress'));
    expect(source, contains('CaretAction.longPress'));
    expect(source, contains('_caretLongPress()'));
    expect(source, contains('ReaderCaretScripts.longPressInvocation()'));
  });

  test('Android gameButtonA key path defers activate until release', () {
    final String source = readReaderPageSource();

    expect(source, contains('Timer? _gamepadAHoldTimer'));
    expect(source, contains('_handleGamepadAKeyEvent'));
    expect(source, contains('event is KeyUpEvent'));
    expect(source, contains('event is KeyRepeatEvent'));
    expect(source, contains('_clearGamepadAHold()'));
    expect(source, contains('CaretAction.activate'));
    expect(source, contains('CaretAction.longPress'));
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
