import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

String _slice(String source, String startMarker, String endMarker) {
  final int start = source.indexOf(startMarker);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $startMarker');
  final int end = source.indexOf(endMarker, start + startMarker.length);
  expect(end, greaterThan(start),
      reason: 'missing $endMarker after $startMarker');
  return source.substring(start, end);
}

void main() {
  final String source = readReaderPageSource();

  test('reader chrome shortcut enters the floating visibility state machine',
      () {
    final String action = _slice(
      source,
      'case ShortcutAction.readerToggleChrome:',
      'case ShortcutAction.readerOpenMenu:',
    );
    expect(action, contains('_toggleChromeFromShortcut();'));

    final String helper = _slice(
      source,
      'void _toggleChromeFromShortcut()',
      'void _toggleChrome()',
    );
    expect(helper, contains('if (_bottomBarFloating)'));
    expect(helper, contains('_handleFloatingChromeReveal()'));
    expect(
      helper,
      contains(
        '_focusOwnership.reclaim(FocusReclaimCause.chromeToggled)',
      ),
    );
    expect(helper, contains('_toggleChrome();'));
  });

  test('floating show/hide cancels or re-arms the one auto-hide timer', () {
    final String reveal = _slice(
      source,
      'bool _handleFloatingChromeReveal()',
      'void _handleVnBlankTap()',
    );
    expect(reveal, contains('_cancelChromeAutoHide();'));
    expect(reveal, contains('_chromeTransientVisible = false'));
    expect(reveal, contains('_chromeTransientVisible = true'));
    expect(reveal, contains('_armChromeAutoHide();'));
  });
}
