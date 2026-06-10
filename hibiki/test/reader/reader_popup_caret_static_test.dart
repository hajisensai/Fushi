import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hardware-nav resume revalidates the top popup caret surface', () {
    final String source = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();

    expect(source, contains('void _resumePopupCaretForHardwareNav()'));
    expect(source, contains('if (!identical(state, _caretPopupState))'));
    expect(source, contains('unawaited(_transferCaretToTopPopup(state))'));
    expect(source, contains('_caretSurface = CaretSurface.none'));
  });

  test('TODO-070: jump-to-dictionary is wired into the popup caret dispatch',
      () {
    final String source = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();

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
    final String source = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();
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
