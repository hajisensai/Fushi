import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('media item edit dialog uses shared MD3 dialog chrome and tokens', () {
    final String source = File(
      'lib/src/pages/implementations/media_item_edit_dialog_page.dart',
    ).readAsStringSync();
    final String dialogSource = _sectionSource(
      source,
      'class MediaItemEditDialogFrame',
      'class MediaItemCoverOverrideField',
    );

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
        contains('const EdgeInsets.symmetric(horizontal: 16, vertical: 12)'),
      ),
    );
  });
}

String _sectionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  final int endIndex = source.indexOf(end, startIndex);
  expect(startIndex, isNonNegative, reason: 'Missing source marker: $start');
  expect(endIndex, isNonNegative, reason: 'Missing source marker: $end');
  return source.substring(startIndex, endIndex);
}
