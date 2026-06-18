import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;
  late String setupScript;

  setUpAll(() {
    source = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();
    setupScript = _between(
      source,
      r'var hoshiContinuousMode = $continuousMode;',
      'window.hoshiProgressDetails = function()',
    );
  });

  test('continuous mouse drag captures reader body text; paged protects it',
      () {
    final String guard = _functionSource(
      setupScript,
      'function _hoshiReaderMouseDragStartAllowed(e)',
      'function _hoshiReaderMouseDragScrollBy(dx, dy)',
    );

    expect(guard, contains("e.pointerType !== 'mouse'"));
    expect(guard, contains('e.button !== 0'));
    expect(guard, contains("closest('a[href], ruby, rt, rp')"),
        reason:
            'links and ruby text must keep native selection/click behavior');
    expect(guard, contains('window.getSelection'),
        reason: 'an existing text selection must not be grabbed for dragging');
    final int continuousModeIndex =
        guard.indexOf('if (hoshiContinuousMode) return true;');
    final int readerTextHitIndex =
        guard.indexOf('window.hoshiSelection.getCharacterAtPoint');
    final int caretHitIndex =
        guard.indexOf('return !_hoshiReaderCaretRangeAtPoint');
    expect(continuousModeIndex, isNonNegative,
        reason: 'continuous mode must capture body-text drags for scrolling');
    expect(readerTextHitIndex, greaterThan(continuousModeIndex),
        reason: 'reader text hit testing must only protect paged mode');
    expect(caretHitIndex, greaterThan(continuousModeIndex),
        reason: 'caret-range text hits must only protect paged mode');

    final String pointerDown = _listenerBlock(setupScript, 'pointerdown');
    final int guardIndex =
        pointerDown.indexOf('_hoshiReaderMouseDragStartAllowed(e)');
    final int startIndex = pointerDown.indexOf('_gestureStart', guardIndex);
    expect(guardIndex, isNonNegative);
    expect(startIndex, greaterThan(guardIndex),
        reason: 'left mouse gesture start must be gated before _gestureStart');
  });

  test(
      'text caret range helper uses browser hit testing without preventDefault',
      () {
    final String helper = _functionSource(
      setupScript,
      'function _hoshiReaderCaretRangeAtPoint(x, y)',
      'function _hoshiReaderMouseDragStartAllowed(e)',
    );

    expect(helper, contains('document.caretPositionFromPoint'));
    expect(helper, contains('document.caretRangeFromPoint'));
    expect(helper, contains('Node.TEXT_NODE'));
    expect(helper, isNot(contains('preventDefault')),
        reason: 'text hit testing must not cancel native drag selection');
  });

  test('claimed desktop mouse drag suppresses pointerup tap or swipe fallback',
      () {
    final String pointerMove = _listenerBlock(setupScript, 'pointermove');
    expect(pointerMove, contains('_hoshiReaderMouseDragClaimed = true'));
    expect(pointerMove, contains('e.preventDefault()'));
    expect(pointerMove, contains('_hoshiReaderClearMouseSelection()'),
        reason: 'claimed text drags must clear browser native selection');
    final String clearSelection = _functionSource(
      setupScript,
      'function _hoshiReaderClearMouseSelection()',
      'function _hoshiReaderMouseDragStartAllowed(e)',
    );
    expect(clearSelection, contains('window.getSelection'));
    expect(clearSelection, contains('removeAllRanges'));

    final String pointerUp = _listenerBlock(setupScript, 'pointerup');
    final int finishIndex = pointerUp.indexOf('_finishHoshiReaderMouseDrag(e)');
    final int gestureEndIndex = pointerUp.indexOf('_gestureEnd');
    expect(finishIndex, isNonNegative);
    expect(gestureEndIndex, isNonNegative);
    expect(finishIndex, lessThan(gestureEndIndex),
        reason: 'claimed drags must finish before the legacy _gestureEnd path');
    expect(pointerUp, contains('if (_hoshiReaderMouseDragClaimed)'));
  });

  test('continuous desktop mouse drag scrolls along the writing axis', () {
    final String scrollFn = _functionSource(
      setupScript,
      'function _hoshiReaderMouseDragScrollBy(dx, dy)',
      'function _finishHoshiReaderMouseDrag(e)',
    );

    expect(scrollFn, contains('r.isVertical'));
    expect(scrollFn, contains('writingMode'));
    expect(scrollFn, contains('window.scrollBy({left:'));
    expect(scrollFn, contains('window.scrollBy({left: 0, top:'));

    final String pointerMove = _listenerBlock(setupScript, 'pointermove');
    expect(pointerMove, contains('if (hoshiContinuousMode)'));
    expect(pointerMove, isNot(contains("callHandler('onSwipe'")),
        reason: 'continuous mouse drag should scroll, not page-turn');
  });

  test('paged desktop mouse drag emits at most one onSwipe on release', () {
    final String finishFn = _functionSource(
      setupScript,
      'function _finishHoshiReaderMouseDrag(e)',
      "document.addEventListener('touchstart'",
    );

    expect(finishFn, contains('_hoshiReaderMouseDragSwipeSent'));
    expect(finishFn, contains('_hoshiReaderMouseDragSwipeSent = true'));
    expect(finishFn, contains("callHandler('onSwipe'"));
    expect(finishFn, contains('_hoshiReaderMouseDragPageDirection = null'));

    final String pointerMove = _listenerBlock(setupScript, 'pointermove');
    expect(pointerMove, isNot(contains("callHandler('onSwipe'")),
        reason: 'paged mouse drag decides direction during move but sends once '
            'from pointerup');
  });

  test(
      'link image context menu and non-left pointer seek wiring stays separate',
      () {
    expect(setupScript, contains("closest('a[href]')"));
    expect(setupScript, contains("document.addEventListener('contextmenu'"));
    expect(setupScript, contains("'onImageContextMenu'"));

    final String mouseDown = _listenerBlock(setupScript, 'mousedown');
    expect(mouseDown, contains('if (e.button === 0) return;'));
    expect(mouseDown, contains('e.button === 2 && _hoshiBlockImageUrl'));
    expect(mouseDown, contains("callHandler('onPointerSeek'"));
  });
}

String _between(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'missing function marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'missing next marker: $end');
  return source.substring(startIndex, endIndex);
}

String _listenerBlock(String source, String eventName) {
  final String marker = "addEventListener('$eventName'";
  final int startIndex = source.indexOf(marker);
  expect(startIndex, isNonNegative, reason: 'missing listener: $eventName');
  final int endIndex = source.indexOf('}, {passive:', startIndex);
  expect(endIndex, isNonNegative,
      reason: 'listener must end with a passive option: $eventName');
  return source.substring(startIndex, endIndex);
}
