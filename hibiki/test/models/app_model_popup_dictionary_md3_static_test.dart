import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop popup dictionary lookup uses shared MD3 dialog frame', () {
    final String source =
        File('lib/src/models/app_model.dart').readAsStringSync();
    final String lookupSource = _between(
      source,
      'Future<void> openPopupDictionaryLookup({',
      '/// A helper function for opening a text segmentation dialog.',
    );

    expect(lookupSource, contains('HibikiDialogFrame('));
    expect(lookupSource, contains('PopupDictionaryPage('));
    expect(
        lookupSource, isNot(contains('builder: (dialogContext) => Dialog(')));
    expect(lookupSource, isNot(contains('child: ConstrainedBox(')));
  });
}

String _between(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  final int endIndex = source.indexOf(end, startIndex);
  expect(startIndex, isNonNegative, reason: 'Missing source marker: $start');
  expect(endIndex, isNonNegative, reason: 'Missing source marker: $end');
  return source.substring(startIndex, endIndex);
}
