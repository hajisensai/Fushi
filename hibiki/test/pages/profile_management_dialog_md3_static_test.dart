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

  test('profile action buttons use shared MD3 icon buttons', () {
    final String source = File(
      'lib/src/pages/implementations/profile_management_page.dart',
    ).readAsStringSync();

    final int actionStart = source.indexOf('class _ProfileActionButton');
    final int deleteStart = source.indexOf('@visibleForTesting', actionStart);
    final String actionSource = source.substring(actionStart, deleteStart);

    expect(actionSource, contains('HibikiIconButton('));
    expect(actionSource, isNot(contains('return IconButton(')));
    expect(actionSource, isNot(contains('VisualDensity.compact')));
  });
}
