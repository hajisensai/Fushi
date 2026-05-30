import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dictionary result stack uses shared MD3 spacing tokens', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/dictionary_result_page.dart',
      'lib/src/pages/implementations/dictionary_term_page.dart',
      'lib/src/pages/implementations/dictionary_entry_page.dart',
    ]) {
      final String source = File(path).readAsStringSync();

      expect(source, contains('HibikiDesignTokens.of(context)'), reason: path);
      expect(source, contains('tokens.spacing'), reason: path);
      expect(source, isNot(contains('Spacing.of(context)')), reason: path);
    }
  });
}
