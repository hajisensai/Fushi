import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('example sentences dialog uses shared MD3 dialog and card chrome', () {
    final String source = File(
      'lib/src/pages/implementations/example_sentences_dialog_page.dart',
    ).readAsStringSync();

    expect(source, contains('HibikiDialogFrame('));
    expect(source, contains('HibikiModalSheetFrame('));
    expect(source, contains('HibikiCard('));
    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(source, isNot(contains('adaptiveAlertDialog(')));
    expect(source, isNot(contains('Spacing.of(context)')));
    expect(source, isNot(contains('GestureDetector(')));
    expect(source, isNot(contains('Container(')));
  });
}
