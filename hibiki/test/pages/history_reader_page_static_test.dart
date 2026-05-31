import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/history_reader_page.dart';

void main() {
  test('history reader page library compiles', () {
    expect(const HistoryReaderPage(), isA<HistoryReaderPage>());
  });

  test('history reader shelf uses shared MD3 card and token chrome', () {
    final String source =
        File('lib/src/pages/implementations/history_reader_page.dart')
            .readAsStringSync();

    expect(source, contains('HibikiDesignTokens.of(context)'));
    expect(source, contains('tokens.spacing'));
    expect(source, contains('tokens.type.metadata'));
    expect(source, isNot(contains('Card(')));
    expect(source, isNot(contains('ListTile(')));
    expect(source, isNot(contains('SwitchListTile(')));
    expect(source, isNot(contains('CheckboxListTile(')));
    expect(source, isNot(contains('BorderRadius.circular(')));
    expect(source, isNot(contains('fontSize:')));
  });
}
