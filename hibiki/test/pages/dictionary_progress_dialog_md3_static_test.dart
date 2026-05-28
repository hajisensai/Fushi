import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dictionary progress dialogs use shared MD3 dialog chrome and tokens',
      () {
    final List<String> paths = <String>[
      'lib/src/pages/implementations/dictionary_dialog_import_page.dart',
      'lib/src/pages/implementations/dictionary_dialog_delete_page.dart',
    ];

    for (final String path in paths) {
      final String source = File(path).readAsStringSync();

      expect(source, contains('HibikiDialogFrame('), reason: path);
      expect(source, contains('HibikiModalSheetFrame('), reason: path);
      expect(source, contains('HibikiDesignTokens.of(context)'), reason: path);
      expect(source, isNot(contains('adaptiveAlertDialog(')), reason: path);
      expect(source, isNot(contains('Spacing.of(context)')), reason: path);
    }
  });
}
