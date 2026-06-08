import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('HomeDictionaryPage preserves external clipboard text for click lookup',
      () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');
    final String resultBody = _functionSource(
      src,
      'Widget _buildSearchResultBody()',
      'Future<void> _pushNestedPopup(',
    );

    expect(src, contains('ClipboardLookupTextPanel'));
    expect(src, contains('_externalLookupText'));
    expect(src, contains('_externalLookupText = req.text'));
    expect(src, contains('_pushNestedPopup(query, localRect'));
    expect(
      resultBody,
      contains('Column('),
      reason: 'External lookup text must reserve layout space above results.',
    );
    expect(
      resultBody.contains('Positioned(') &&
          resultBody.contains('child: ClipboardLookupTextPanel('),
      isFalse,
      reason: 'The clipboard text panel must not be stacked over WebView '
          'results; that visually overlaps the first dictionary row.',
    );
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex);
  expect(endIndex, isNonNegative, reason: 'missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
