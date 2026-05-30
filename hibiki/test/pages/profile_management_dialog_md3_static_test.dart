import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('profile management dialogs use shared MD3 dialog chrome and tokens',
      () {
    final String source = File(
      'lib/src/pages/implementations/profile_management_page.dart',
    ).readAsStringSync();

    expect(source, contains('HibikiDialogFrame('));
    expect(source, contains('HibikiModalSheetFrame('));
    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(source, contains('insetPadding: EdgeInsets.symmetric('));
    expect(source, contains('horizontal: tokens.spacing.card'));
    expect(source, contains('vertical: tokens.spacing.card'));
    expect(source, isNot(contains('adaptiveAlertDialog(')));
    expect(
      source,
      isNot(
        contains('const EdgeInsets.symmetric(horizontal: 16, vertical: 16)'),
      ),
    );
  });
}
