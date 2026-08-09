// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

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
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();
    final String chrome = File(
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
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
    expect(body, contains("'data-fushi-sel-ball'"));
    expect(body, contains('var(--fushi-sel-handle'));
    expect(body, isNot(contains('rgba(255,138,0,0.98)')));
    final String cssSource = File(
      'lib/src/reader/reader_content_styles.dart',
    ).readAsStringSync();
    expect(cssSource, contains('--fushi-sel-handle:'));
  });
}
