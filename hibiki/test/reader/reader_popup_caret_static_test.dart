import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-387: the popup-surface caret state machine (transfer to top popup,
/// resume after a touch->hardware-nav flip) moved into the shared
/// [DictionaryCaretController]. This guard now splits its assertions: the
/// transition *algorithm* is asserted against the controller, while the reader
/// is asserted to delegate to it and to keep its popup-only jump dispatch.
void main() {
  final String reader = File(
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ).readAsStringSync();
  final String controller = File(
    'lib/src/shortcuts/dictionary_caret_controller.dart',
  ).readAsStringSync();

  test('hardware-nav resume revalidates the top popup caret surface', () {
    // The algorithm lives in the controller now.
    expect(
      controller,
      contains('void resumePopupCaretForHardwareNav()'),
    );
    expect(controller, contains('if (!identical(state, popupState))'));
    expect(controller, contains('unawaited(transferToTopPopup(state))'));
    expect(controller, contains('surface = CaretSurface.none'));
    // The reader keeps the wrapper and delegates to the controller.
    expect(reader, contains('void _resumePopupCaretForHardwareNav()'));
    expect(reader, contains('_caret.resumePopupCaretForHardwareNav()'));
  });

  test('TODO-070: jump-to-dictionary is wired into the popup caret dispatch',
      () {
    final String source = reader;

    // The popup-only jump helper exists and is dispatched from _runCaretAction
    // for both jump actions.
    expect(
        source, contains('Future<void> _caretJumpDict(bool forward) async {'));
    expect(source, contains('case CaretAction.jumpDictNext:'));
    expect(source, contains('case CaretAction.jumpDictPrev:'));
    expect(source, contains('await _caretJumpDict(true);'));
    expect(source, contains('await _caretJumpDict(false);'));
    // The Android-native gamepad key path routes LT/RT triggers through the
    // gamepad map (the polled path already calls decideGamepad).
    expect(
        source,
        contains(
            'shoulder == GamepadButton.lt || shoulder == GamepadButton.rt'));
    expect(source, contains('ReaderCaretRouter.decideGamepad(shoulder!)'));
    // Jump is popup-only — it must not fall through to the reader/lyrics caret.
    expect(
        source, contains('if (_caretSurface != CaretSurface.popup) return;'));
  });

  test('TODO-070: jump-to-dictionary fires once per press (not on auto-repeat)',
      () {
    final String source = reader;
    // Both jump actions sit in the non-repeatable arm of _isRepeatableCaretMove
    // (returns false), so holding the key/trigger does not blow past every
    // section.
    final int falseArm = source.indexOf('case CaretAction.activate:');
    final int retFalse = source.indexOf('return false;', falseArm);
    final String falseBlock = source.substring(falseArm, retFalse);
    expect(falseBlock, contains('case CaretAction.jumpDictNext:'));
    expect(falseBlock, contains('case CaretAction.jumpDictPrev:'));
  });
}
