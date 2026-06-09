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
    expect(src, contains('DesktopLookupService.instance.pendingText'));
    expect(src, contains('DesktopLookupService.instance.clearPending()'));
    expect(src, contains('_externalLookupText = text'));
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

    final int panelIndex = resultBody.indexOf('ClipboardLookupTextPanel(');
    final int neutralizerIndex =
        resultBody.indexOf('HibikiAppUiScaleNeutralizer(');
    final int webViewIndex = resultBody.indexOf('DictionaryPopupWebView(');
    expect(panelIndex, isNonNegative);
    expect(neutralizerIndex, isNonNegative);
    expect(webViewIndex, greaterThan(neutralizerIndex));
    expect(
      panelIndex,
      lessThan(neutralizerIndex),
      reason: 'The external clipboard text panel is regular app UI and must '
          'stay outside the WebView scale neutralizer so it follows the '
          'global UI/font size setting.',
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
