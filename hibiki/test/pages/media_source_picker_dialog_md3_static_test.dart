import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('media source picker uses shared MD3 dialog shell', () {
    final String source = File(
      'lib/src/pages/implementations/media_source_picker_dialog_page.dart',
    ).readAsStringSync();

    expect(source, contains('HibikiDialogFrame('));
    expect(source, contains('HibikiModalSheetFrame('));
    expect(source, contains('HibikiListItem('));
    expect(source, isNot(contains('adaptiveAlertDialog(')));
    expect(source, isNot(contains('Spacing.of(context)')));
  });
}
