import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dictionary settings dialogs use shared MD3 dialog chrome and tokens',
      () {
    final String source = File(
      'lib/src/pages/implementations/dictionary_settings_dialog_page.dart',
    ).readAsStringSync();

    expect(source, contains('HibikiDialogFrame('));
    expect(source, contains('HibikiModalSheetFrame('));
    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(source, isNot(contains('adaptiveAlertDialog(')));
  });
}
