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

  test('continuous pointer drag captures reader body text; paged protects it',
      () {
    final String guard = _functionSource(
      setupScript,
      'function _hoshiReaderMouseDragStartAllowed(e)',
      'function _hoshiReaderMouseDragScrollBy(dx, dy)',
    );

    expect(guard, contains('_hoshiReaderPointerPrimaryButton(e)'));
    expect(guard, isNot(contains("e.pointerType !== 'mouse'")),
        reason: 'touch and mouse must share the same drag state machine');
    expect(guard, contains("closest('a[href], ruby, rt, rp')"),
        reason:
            'links and ruby text must keep native selection/click behavior');
    expect(guard, contains('input, textarea, select, button'),
        reason: 'form controls must keep native editing and selection');
    expect(guard, contains('[contenteditable="true"]'),
        reason: 'editable islands must not be grabbed for reader scrolling');
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
    expect(pointerDown, isNot(contains("e.pointerType === 'touch' ||")),
        reason: 'touch must not be filtered out of pointer drag startup');
    final int guardIndex =
        pointerDown.indexOf('_hoshiReaderMouseDragStartAllowed(e)');
    final int startIndex = pointerDown.indexOf('_gestureStart', guardIndex);
    expect(guardIndex, isNonNegative);
    expect(startIndex, greaterThan(guardIndex),
        reason:
            'primary pointer gesture start must be gated before _gestureStart');
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

  test(
      'claimed pointer drag suppresses pointerup/touchend tap or swipe fallback',
      () {
    final String pointerMove = _listenerBlock(setupScript, 'pointermove');
    expect(pointerMove, isNot(contains("e.pointerType === 'touch') return")),
        reason: 'touch moves must be able to claim reader scrolling');
    expect(pointerMove, contains('_hoshiReaderPointerStillDown(e)'));
    expect(pointerMove, contains('_hoshiReaderMouseDragClaimed = true'));
    expect(pointerMove, contains('_hoshiReaderMouseDragIgnoreTouchEnd = true'),
        reason:
            'claimed touch drags must suppress the following legacy touchend');
    expect(pointerMove, contains('e.preventDefault()'));
    expect(pointerMove, contains('_hoshiReaderClearMouseSelection()'),
        reason: 'claimed text drags must clear browser native selection');
    expect(pointerMove, contains('_hoshiReaderPointerNoSelect(true)'),
        reason:
            'claimed drags temporarily disable native selection only while active');
    final String clearSelection = _functionSource(
      setupScript,
      'function _hoshiReaderClearMouseSelection()',
      'function _hoshiReaderPointerPrimaryButton(e)',
    );
    expect(clearSelection, contains('window.getSelection'));
    expect(clearSelection, contains('removeAllRanges'));

    final String pointerUp = _listenerBlock(setupScript, 'pointerup');
    expect(pointerUp, isNot(contains("e.pointerType === 'touch' ||")),
        reason: 'touch pointerup must finish the same claimed-drag path');
    final int finishIndex = pointerUp.indexOf('_finishHoshiReaderMouseDrag(e)');
    final int gestureEndIndex = pointerUp.indexOf('_gestureEnd');
    expect(finishIndex, isNonNegative);
    expect(gestureEndIndex, isNonNegative);
    expect(finishIndex, lessThan(gestureEndIndex),
        reason: 'claimed drags must finish before the legacy _gestureEnd path');
    expect(pointerUp, contains('if (_hoshiReaderMouseDragClaimed)'));
    expect(pointerUp, contains('_hoshiReaderPointerNoSelect(false)'));

    final String touchEnd = _listenerBlock(setupScript, 'touchend');
    final int ignoreIndex =
        touchEnd.indexOf('_hoshiReaderMouseDragIgnoreTouchEnd');
    final int legacyEndIndex = touchEnd.indexOf('_gestureEnd');
    expect(ignoreIndex, isNonNegative);
    expect(legacyEndIndex, isNonNegative);
    expect(ignoreIndex, lessThan(legacyEndIndex),
        reason:
            'claimed touch drags must not replay tap/selection on touchend');
    expect(touchEnd, contains('e.preventDefault()'));
  });

  test('continuous pointer drag scrolls along horizontal and vertical axes',
      () {
    final String scrollFn = _functionSource(
      setupScript,
      'function _hoshiReaderMouseDragScrollBy(dx, dy)',
      'function _finishHoshiReaderMouseDrag(e)',
    );

    expect(scrollFn, contains('r.isVertical'));
    expect(scrollFn, contains('window.scrollBy({left:'));
    expect(scrollFn, contains('window.scrollBy({left: 0, top:'));

    final String pointerMove = _listenerBlock(setupScript, 'pointermove');
    expect(pointerMove, contains('if (hoshiContinuousMode)'));
    expect(pointerMove, isNot(contains("callHandler('onSwipe'")),
        reason: 'continuous pointer drag should scroll, not page-turn');
  });

  // BUG-338 (TODO-597): drag-to-pan must follow the pointer regardless of
  // writing-mode. Mouse-right (dx>0) → content right → scrollLeft down →
  // scrollBy({left: -dx}); mouse-up (dy<0) → content up → scrollTop up →
  // scrollBy({top: -dy}). The old vertical-rl `sign = -1` produced
  // scrollBy({left: dx}) and reversed the drag direction. Removing the sign
  // is the fix; this guard turns red if the writing-mode sign flip returns.
  test('continuous vertical drag follows the pointer without a sign flip', () {
    final String scrollFn = _functionSource(
      setupScript,
      'function _hoshiReaderMouseDragScrollBy(dx, dy)',
      'function _finishHoshiReaderMouseDrag(e)',
    );

    // Vertical axis: content follows the pointer with plain `-dx` (no sign).
    expect(scrollFn, contains('window.scrollBy({left: -dx, top: 0'),
        reason: 'vertical drag must pan with scrollBy({left: -dx}) so the '
            'content follows the pointer (mouse-right → content-right)');
    // Horizontal axis stays finger-following on the vertical pointer axis.
    expect(scrollFn, contains('window.scrollBy({left: 0, top: -dy'),
        reason: 'horizontal-writing drag must pan with scrollBy({top: -dy})');
    // The writing-mode-dependent sign flip that reversed vertical-rl is gone.
    expect(scrollFn, isNot(contains('-dx * sign')),
        reason:
            'BUG-338: the writing-mode sign flip reversed vertical-rl drag');
    expect(scrollFn, isNot(contains("=== 'vertical-rl') ? -1")),
        reason: 'BUG-338: drag pan direction must not depend on writing-mode');
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

  // TODO-553: paged-mode touch must fall back to the touchstart/touchend swipe
  // path; only continuous mode lets touch drive the pointer drag machine. The
  // executable proof lives in reader_paged_touch_swipe_behavior_test.{js,dart};
  // this is the node-less static tripwire for the gates.
  test('touch only engages the pointer drag machine in continuous mode', () {
    final String engages = _functionSource(
      setupScript,
      'function _hoshiReaderPointerEngages(e)',
      'function _hoshiReaderPointerNoSelect(enabled)',
    );
    expect(engages, contains('_hoshiReaderPointerPrimaryButton(e)'));
    expect(engages, contains("e.pointerType === 'touch'"));
    expect(engages, contains('return hoshiContinuousMode'),
        reason: 'paged-mode touch must not enter the pointer drag machine');

    final String pointerDown = _listenerBlock(setupScript, 'pointerdown');
    expect(pointerDown, contains('_hoshiReaderPointerEngages(e)'),
        reason: 'pointerdown must gate touch through the engage predicate');

    final String pointerMove = _listenerBlock(setupScript, 'pointermove');
    expect(pointerMove,
        contains("e.pointerType === 'touch' && !hoshiContinuousMode"),
        reason: 'paged-mode touch moves must return before claiming a drag, '
            'leaving touchend -> _gestureEnd -> onSwipe to turn the page');

    final String pointerUp = _listenerBlock(setupScript, 'pointerup');
    expect(pointerUp, contains('_hoshiReaderPointerEngages(e)'),
        reason: 'paged-mode touch pointerup must not run the native-text path');

    final String pointerCancel = _listenerBlock(setupScript, 'pointercancel');
    expect(pointerCancel,
        contains("e.pointerType === 'touch' && !hoshiContinuousMode"),
        reason: 'paged-mode touch pointercancel must bail before resetting the '
            'drag machine, mirroring the pointermove exclusion');
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
