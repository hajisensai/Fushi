import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('anki settings page uses MD3 spacing tokens for inline states', () {
    final String source = File(
      'lib/src/pages/implementations/anki_settings_page.dart',
    ).readAsStringSync();
    final String pageSource =
        source.substring(0, source.indexOf('Widget _buildFetchTile'));

    expect(pageSource, contains('HibikiDesignTokens.of(context)'));
    expect(
      pageSource,
      isNot(contains('padding: const EdgeInsets.fromLTRB(12, 0, 12, 12)')),
    );
    expect(
      pageSource,
      isNot(contains('padding: const EdgeInsets.fromLTRB(16, 8, 16, 20)')),
    );
  });

  test('anki handlebar picker dialog uses shared MD3 dialog chrome and tokens',
      () {
    final String source = File(
      'lib/src/pages/implementations/anki_settings_page.dart',
    ).readAsStringSync();
    final String dialogSource =
        source.substring(source.indexOf('class AnkiHandlebarPickerDialog'));

    expect(dialogSource, contains('HibikiDialogFrame('));
    expect(dialogSource, contains('HibikiModalSheetFrame('));
    expect(dialogSource, contains('HibikiDesignTokens.of(context)'));
    expect(dialogSource, contains('insetPadding: EdgeInsets.symmetric('));
    expect(dialogSource, contains('horizontal: tokens.spacing.card'));
    expect(dialogSource, contains('vertical: tokens.spacing.gap'));
    expect(dialogSource, isNot(contains('adaptiveAlertDialog(')));
    expect(
      dialogSource,
      isNot(
        contains('const EdgeInsets.symmetric(horizontal: 12, vertical: 8)'),
      ),
    );
  });
}
