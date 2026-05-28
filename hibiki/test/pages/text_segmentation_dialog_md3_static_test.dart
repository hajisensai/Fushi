import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('text segmentation dialog uses shared MD3 dialog and chip chrome', () {
    final String source = File(
      'lib/src/pages/implementations/text_segmentation_dialog_page.dart',
    ).readAsStringSync();

    expect(source, contains('HibikiDialogFrame('));
    expect(source, contains('HibikiModalSheetFrame('));
    expect(source, contains('HibikiSelectableChip('));
    expect(source, isNot(contains('adaptiveAlertDialog(')));
    expect(source, isNot(contains('Spacing.of(context)')));
    expect(source, isNot(contains('Container(')));
  });
}
