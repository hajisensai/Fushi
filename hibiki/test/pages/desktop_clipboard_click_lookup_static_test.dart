import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('HomeDictionaryPage preserves source lookup text for click lookup', () {
    final String src =
        read('lib/src/pages/implementations/home_dictionary_page.dart');
    final String resultBody = _functionSource(
      src,
      'Widget _buildSearchResultBody()',
      'Future<void> _pushNestedPopup(',
    );

    expect(src, contains('SourceLookupTextPanel'));
    expect(src, contains('_sourceLookupText'));
    expect(src, contains('DesktopLookupService.instance.pendingRequest'));
    expect(src, contains('DesktopLookupService.instance.clearPending()'));
    expect(src, contains('_sourceLookupText = request.showSourcePanel'));
    expect(src, contains('_pushNestedPopup(query, localRect'));
    expect(
      _withoutWhitespace(resultBody),
      contains(
        'dictionaryHeadwordScale:'
        'appModel.dictionaryFontSize/appModel.defaultDictionaryFontSize',
      ),
      reason: 'Source lookup text should visually match the popup '
          'headword size through the shared panel style, scaled by dictionary '
          'font size only.',
    );
    expect(
      resultBody,
      isNot(contains('headwordTextStyle:')),
      reason: 'HomeDictionaryPage must not reopen page-local text-style '
          'decisions to size the native clipboard strip.',
    );
    expect(
      resultBody,
      contains('Column('),
      reason: 'External lookup text must reserve layout space above results.',
    );
    expect(
      resultBody.contains('Positioned(') &&
          resultBody.contains('child: SourceLookupTextPanel('),
      isFalse,
      reason: 'The source text panel must not be stacked over WebView '
          'results; that visually overlaps the first dictionary row.',
    );

    final int panelIndex = resultBody.indexOf('SourceLookupTextPanel(');
    final int neutralizerIndex =
        resultBody.indexOf('HibikiAppUiScaleNeutralizer(');
    final int webViewIndex = resultBody.indexOf('DictionaryPopupWebView(');
    expect(panelIndex, isNonNegative);
    expect(neutralizerIndex, isNonNegative);
    expect(webViewIndex, greaterThan(neutralizerIndex));
    expect(
      panelIndex,
      lessThan(neutralizerIndex),
      reason: 'The source text panel is regular app UI and must '
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

String _withoutWhitespace(String source) =>
    source.replaceAll(RegExp(r'\s+'), '');
