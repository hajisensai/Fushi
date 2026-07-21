import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';

String _between(String source, String start, String end) {
  final int from = source.indexOf(start);
  final int to = source.indexOf(end, from + start.length);
  expect(from, greaterThanOrEqualTo(0));
  expect(to, greaterThan(from));
  return source.substring(from, to);
}

void main() {
  test('Windows right-click menu is single-flight and above popup WebView', () {
    final String state = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();
    final String chrome = File(
      'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
    ).readAsStringSync();
    final String body = _between(
      chrome,
      'Future<void> _showReaderTextContextMenu(',
      'Future<void> _handleSelectionMenu(',
    );
    expect(state, contains('bool _readerTextContextMenuActive = false;'));
    final int gate = body.indexOf('_readerTextContextMenuActive = true;');
    final int jsAwait = body.indexOf('evaluateJavascript(');
    final int prune = body.indexOf('_webviewPrunePopupStack(0);');
    final int menu = body.indexOf('showMenu<String>(');
    final int reset = body.lastIndexOf('_readerTextContextMenuActive = false;');
    expect(jsAwait, greaterThan(gate));
    expect(prune, greaterThan(jsAwait));
    expect(menu, greaterThan(prune));
    expect(body, contains('finally {'));
    expect(reset, greaterThan(menu));
  });

  test('Android caret hit test falls back when WebView returns an element', () {
    final String js = ReaderSelectionScripts.source();
    final String body = _between(
      js,
      'getCaretRange: function',
      'getCharacterAtPoint: function',
    );
    final int caret = body.indexOf('caretPositionFromPoint');
    final int textNode = body.indexOf('nodeType === Node.TEXT_NODE');
    final int fallback =
        body.indexOf('var element = document.elementFromPoint');
    expect(caret, greaterThanOrEqualTo(0));
    expect(textNode, greaterThan(caret));
    expect(fallback, greaterThan(textNode));
    expect(body, isNot(contains('if (!pos) return null;')));
  });

  test('selection handle has a larger touch target and themed inner ball', () {
    final String js = ReaderSelectionScripts.source();
    final String body = _between(
      js,
      'ensureSelectionHandles: function',
      '_wireHandle: function',
    );
    expect(body, contains('width:32px;height:32px'));
    expect(body, contains("'data-hoshi-sel-ball'"));
    expect(body, contains('var(--hoshi-sel-handle'));
    expect(body, isNot(contains('rgba(255,138,0,0.98)')));
    final String cssSource = File(
      'lib/src/reader/reader_content_styles.dart',
    ).readAsStringSync();
    expect(cssSource, contains('--hoshi-sel-handle:'));
  });
}
