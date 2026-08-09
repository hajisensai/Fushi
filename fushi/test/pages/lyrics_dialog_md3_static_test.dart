import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lyrics dialog uses shared MD3 dialog chrome and token spacing', () {
    final String source = File(
      'lib/src/pages/implementations/lyrics_dialog_page.dart',
    ).readAsStringSync();

    expect(source, contains('FushiDialogFrame('));
    expect(source, contains('FushiModalSheetFrame('));
    expect(source, contains('FushiDesignTokens.of(context)'));
    expect(source, isNot(contains('adaptiveAlertDialog(')));
    expect(source, isNot(contains('Spacing.of(context)')));
  });
}
