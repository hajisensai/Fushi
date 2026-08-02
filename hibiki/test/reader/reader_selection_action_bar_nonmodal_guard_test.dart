import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

String _between(String source, String start, String end) {
  final int startAt = source.indexOf(start);
  final int endAt = source.indexOf(end, startAt + start.length);
  if (startAt < 0 || endAt <= startAt) {
    throw StateError('guard markers missing: $start .. $end');
  }
  return source.substring(startAt, endAt);
}

String _withoutLineComments(String source) => maskComments(source);

void main() {
  final String chrome =
      File('lib/src/pages/implementations/reader_hibiki/chrome.part.dart')
          .readAsStringSync();
  final String bar = _between(
    chrome,
    'Future<void> _handleSelectionMenu(',
    'Future<void> _clearReaderAppSelection(',
  );

  group('BUG-1236 selection action bar stays non-modal', () {
    test('uses OverlayEntry and never showMenu/showDialog', () {
      final String code = _withoutLineComments(bar);
      expect(code, isNot(contains('showMenu')));
      expect(code, isNot(contains('showDialog')));
      expect(bar, contains('OverlayEntry('));
      expect(bar, contains('overlay.insert(entry)'));
      expect(bar, contains('markNeedsBuild()'));
      expect(bar, contains('handleReserve'));
    });

    test('remove path disposes entry and clears payload', () {
      final String remove = _between(
        bar,
        'void _removeSelectionActionBar()',
        'Widget _buildSelectionActionBar(',
      );
      expect(remove, contains('remove()'));
      expect(remove, contains('dispose()'));
      expect(remove, contains('_selectionActionBarEntry = null'));
      expect(remove, contains('_selectionActionData = null'));
    });

    test('Android actions include lookup copy share and web search', () {
      expect(bar, contains("t.search, 'search'"));
      expect(bar, contains("t.copy, 'copy'"));
      expect(bar, contains("t.share, 'share'"));
      expect(bar, contains('t.selection_web_search'));
      expect(bar, contains("case 'share':"));
      expect(bar, contains("case 'webSearch':"));
      expect(bar,
          contains('SelectionExternalActions.instance.shareText(data.text)'));
      expect(bar,
          contains('SelectionExternalActions.instance.searchWeb(data.text)'));
      expect(bar, contains('t.selection_web_search_unavailable'));
      expect(bar, contains('await _clearReaderAppSelection()'));
    });
  });

  test('all selection convergence/lifecycle paths remove the bar', () {
    final String lookup =
        File('lib/src/pages/implementations/reader_hibiki/lookup.part.dart')
            .readAsStringSync();
    final String page =
        File('lib/src/pages/implementations/reader_hibiki_page.dart')
            .readAsStringSync();
    expect(
      _between(
        chrome,
        'Future<void> _clearReaderAppSelection(',
        'Future<ReaderSelectionData?>',
      ),
      contains('_removeSelectionActionBar()'),
    );
    expect(
      _between(
        chrome,
        'Future<void> _hideReaderSelectionHandles(',
        '_extractSelectionClipImages',
      ),
      contains('_removeSelectionActionBar()'),
    );
    expect(
      _between(
        lookup,
        'Future<void> _handleTextSelected(',
        '_miningDraft.clear()',
      ),
      contains('_removeSelectionActionBar()'),
    );
    expect(page.substring(page.indexOf('void dispose()')),
        contains('_removeSelectionActionBar()'));
  });

  test('ordinary Android native selection menu has all four requested actions',
      () {
    final String webview =
        File('lib/src/pages/implementations/reader_hibiki/webview.part.dart')
            .readAsStringSync();
    final String menu = _between(
        webview, 'contextMenu: isWindowsPlatform', 'initialUserScripts:');
    expect(menu, contains('title: t.search'));
    expect(menu, contains('title: t.copy'));
    expect(menu, contains('title: t.share'));
    expect(menu, contains('title: t.selection_web_search'));
    expect(menu, contains('SelectionExternalActions'));
    expect(menu, isNot(contains('multiSelect')));
    expect(menu, isNot(contains('selectionMode')));
  });
}
