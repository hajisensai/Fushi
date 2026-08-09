import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _between(String source, String start, String end) {
  final int startAt = source.indexOf(start);
  final int endAt = source.indexOf(end, startAt + start.length);
  if (startAt < 0 || endAt <= startAt) {
    throw StateError('guard markers missing: $start .. $end');
  }
  return source.substring(startAt, endAt);
}

void main() {
  final String source =
      File('lib/src/pages/implementations/dictionary_popup_webview.dart')
          .readAsStringSync();
  final String menu =
      _between(source, 'contextMenu: ContextMenu(', 'gestureRecognizers:');

  group('BUG-1237 Android popup actions bypass finished ActionMode', () {
    test('Android hides broken system items while iOS is not expanded', () {
      expect(
        menu,
        contains('Platform.isAndroid || isWindowsPlatform'),
      );
      expect(menu, contains('if (Platform.isAndroid)'));
    });

    test('copy is custom Dart clipboard action and selection is cleared', () {
      expect(menu, contains('title: t.copy'));
      expect(menu, contains('await _copySelectionToClipboard(text)'));
      expect(
        source,
        contains('Clipboard.setData(ClipboardData(text: text))'),
        reason: '共享复制 helper 仍必须真正写入系统剪贴板',
      );
      expect(menu, contains('_selectedTextAcrossFrames()'));
      expect(menu, contains('_clearSelectedTextAcrossFrames()'));
    });

    test('share and web search reuse the common action seam', () {
      expect(menu, contains('title: t.share'));
      expect(menu, contains('title: t.selection_web_search'));
      expect(
          menu, contains('SelectionExternalActions.instance.shareText(text)'));
      expect(
          menu, contains('SelectionExternalActions.instance.searchWeb(text)'));
      expect(menu, contains('t.selection_web_search_unavailable'));
    });
  });

  test('Windows right-click path remains unchanged', () {
    final String windows = _between(
      source,
      'Future<void> _showWindowsContextMenu(',
      'static String? _cachedStylesJson',
    );
    expect(source, contains('disableContextMenu: isWindowsPlatform'));
    expect(windows, contains('_selectedTextAcrossFrames()'));
    expect(windows, contains('await _copySelectionToClipboard(text)'));
    expect(windows, isNot(contains('SelectionExternalActions')));
  });
}
