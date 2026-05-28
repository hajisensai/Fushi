import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('switch settings dialog uses shared MD3 dialog chrome', () {
    final String source = File(
      'lib/src/pages/implementations/switch_settings_page.dart',
    ).readAsStringSync();

    expect(source, contains('HibikiDialogFrame('));
    expect(source, contains('HibikiModalSheetFrame('));
    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(source, isNot(contains('adaptiveAlertDialog(')));
    expect(source, isNot(contains('contentPadding: const EdgeInsets')));
  });
}
