import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio recorder dialog uses shared MD3 dialog chrome and tokens', () {
    final String source = File(
      'lib/src/pages/implementations/audio_recorder_page.dart',
    ).readAsStringSync();

    expect(source, contains('HibikiDialogFrame('));
    expect(source, contains('HibikiModalSheetFrame('));
    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(source, contains('insetPadding: EdgeInsets.symmetric('));
    expect(source, contains('horizontal: tokens.spacing.card'));
    expect(source, contains('vertical: tokens.spacing.card'));
    expect(source, isNot(contains('adaptiveAlertDialog(')));
    expect(source, isNot(contains('Spacing.of(context)')));
    expect(
      source,
      isNot(
        contains('const EdgeInsets.symmetric(horizontal: 16, vertical: 16)'),
      ),
    );
    expect(source, isNot(contains('const EdgeInsets.all(16)')));
  });

  test('audio recorder player controls use shared MD3 icon buttons', () {
    final String source = File(
      'lib/src/pages/implementations/audio_recorder_page.dart',
    ).readAsStringSync();

    expect(source, contains('HibikiIconButton('));
    expect(source, isNot(contains('return IconButton(')));
    expect(source, isNot(contains('child: IconButton(')));
  });
}
