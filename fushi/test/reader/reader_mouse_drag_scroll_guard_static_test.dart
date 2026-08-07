import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// TODO-2527：本文件所有窗口从**掩码语料**上切、断言一律 [containsCodeLine]。
///
/// 旧写法有两个洞，reader 合并语料里注释占 37%，两个洞都是现成的假绿机会：
/// - 窗口从**原始**语料切 ⇒ 窗口里的 JS 注释参与 `contains`，把实现删光、注释里留下
///   同名字面量（`_wheelBoundaryArmed`、`window.getSelection` 这类符号本来就写在生产
///   注释里）照样绿；
/// - 窗口右边界是 `indexOf('}, {passive:')` / 「下一个函数签名」这种**文本**标记，
///   窗口会横跨到别的监听器 / 别的函数里，断言命中的可能根本不是被守的那一段。
///
/// 现在：语料先过 [maskCommentsAndScriptLines]（Dart 注释 + 三引号里的 JS 注释一起换
/// 等长空白），窗口由 [methodBody] 的花括号配对给出（JS 词法），断言走 [containsCodeLine]。
void main() {
  late String setupScript;

  setUpAll(() {
    // TODO-589 batch8: setup 脚本(鼠标拖动状态机)已搬到
    // reader_fushi/webview.part.dart，改读「主壳 + 全部 part」合并语料。
    // TODO-2527: 语料先掩码——三引号里的 JS 注释与 Dart 注释一起变等长空白，
    // 下标与原文逐字节对齐，切片位置不变、注释不再能满足任何断言。
    setupScript = _between(
      maskCommentsAndScriptLines(readReaderPageSource()),
      r'var fushiContinuousMode = C.continuousMode;',
      'window.fushiProgressDetails = function()',
    );
  });

  test('continuous pointer drag captures reader body text; paged protects it',
      () {
    final String guard = _jsFunction(
      setupScript,
      'function _fushiReaderMouseDragStartAllowed(e)',
    );

    expect(
        containsCodeLine(guard, '_fushiReaderPointerPrimaryButton(e)'), isTrue);
    expect(containsCodeLine(guard, "e.pointerType !== 'mouse'"), isFalse,
        reason: 'touch and mouse must share the same drag state machine');
    expect(containsCodeLine(guard, "closest('a[href], ruby, rt, rp')"), isTrue,
        reason:
            'links and ruby text must keep native selection/click behavior');
    expect(containsCodeLine(guard, 'input, textarea, select, button'), isTrue,
        reason: 'form controls must keep native editing and selection');
    expect(containsCodeLine(guard, '[contenteditable="true"]'), isTrue,
        reason: 'editable islands must not be grabbed for reader scrolling');
    expect(containsCodeLine(guard, 'window.getSelection'), isTrue,
        reason: 'an existing text selection must not be grabbed for dragging');
    // 砍掉 PC 鼠标左键拖动平移：连续模式 _fushiReaderMouseDragStartAllowed 返 false，
    // 鼠标左键回归原生选字/划词；不再捕获正文做 JS scrollBy 平移（卡顿 + 鼠标拖动提前
    // 跨章的来源）。分页模式仍走下方 caret 命中逻辑（拖动转翻页 BUG-368 不受影响）。
    expect(containsCodeLine(guard, 'if (fushiContinuousMode) return false;'),
        isTrue,
        reason: '连续模式鼠标左键回归原生选字/划词，不再捕获正文拖动平移（已砍）');
    expect(containsCodeLine(guard, 'if (fushiContinuousMode) return true;'),
        isFalse,
        reason: '旧的「连续模式捕获正文拖动平移」已砍，防回归');
    final int continuousModeIndex =
        guard.indexOf('if (fushiContinuousMode) return false;');
    final int readerTextHitIndex =
        guard.indexOf('window.fushiSelection.getCharacterAtPoint');
    final int caretHitIndex =
        guard.indexOf('return !_fushiReaderCaretRangeAtPoint');
    expect(readerTextHitIndex, greaterThan(continuousModeIndex),
        reason: 'reader text hit testing must only protect paged mode');
    expect(caretHitIndex, greaterThan(continuousModeIndex),
        reason: 'caret-range text hits must only protect paged mode');

    final String pointerDown = _jsListener(setupScript, 'pointerdown');
    expect(
        containsCodeLine(pointerDown, "e.pointerType === 'touch' ||"), isFalse,
        reason: 'touch must not be filtered out of pointer drag startup');
    final int guardIndex =
        pointerDown.indexOf('_fushiReaderMouseDragStartAllowed(e)');
    final int startIndex = pointerDown.indexOf('_gestureStart', guardIndex);
    expect(guardIndex, isNonNegative);
    expect(startIndex, greaterThan(guardIndex),
        reason:
            'primary pointer gesture start must be gated before _gestureStart');
  });

  test(
      'text caret range helper uses browser hit testing without preventDefault',
      () {
    final String helper = _jsFunction(
      setupScript,
      'function _fushiReaderCaretRangeAtPoint(x, y)',
    );

    expect(containsCodeLine(helper, 'document.caretPositionFromPoint'), isTrue);
    expect(containsCodeLine(helper, 'document.caretRangeFromPoint'), isTrue);
    expect(containsCodeLine(helper, 'Node.TEXT_NODE'), isTrue);
    expect(containsCodeLine(helper, 'preventDefault'), isFalse,
        reason: 'text hit testing must not cancel native drag selection');
  });

  test(
      'claimed pointer drag suppresses pointerup/touchend tap or swipe fallback',
      () {
    final String pointerMove = _jsListener(setupScript, 'pointermove');
    expect(containsCodeLine(pointerMove, "e.pointerType === 'touch') return"),
        isFalse,
        reason: 'touch moves must be able to claim reader scrolling');
    expect(containsCodeLine(pointerMove, '_fushiReaderPointerStillDown(e)'),
        isTrue);
    expect(containsCodeLine(pointerMove, '_fushiReaderMouseDragClaimed = true'),
        isTrue);
    expect(
        containsCodeLine(
            pointerMove, '_fushiReaderMouseDragIgnoreTouchEnd = true'),
        isTrue,
        reason:
            'claimed touch drags must suppress the following legacy touchend');
    expect(containsCodeLine(pointerMove, 'e.preventDefault()'), isTrue);
    expect(containsCodeLine(pointerMove, '_fushiReaderClearMouseSelection()'),
        isTrue,
        reason: 'claimed text drags must clear browser native selection');
    expect(containsCodeLine(pointerMove, '_fushiReaderPointerNoSelect(true)'),
        isTrue,
        reason:
            'claimed drags temporarily disable native selection only while active');
    final String clearSelection = _jsFunction(
      setupScript,
      'function _fushiReaderClearMouseSelection()',
    );
    expect(containsCodeLine(clearSelection, 'window.getSelection'), isTrue);
    expect(containsCodeLine(clearSelection, 'removeAllRanges'), isTrue);

    final String pointerUp = _jsListener(setupScript, 'pointerup');
    expect(containsCodeLine(pointerUp, "e.pointerType === 'touch' ||"), isFalse,
        reason: 'touch pointerup must finish the same claimed-drag path');
    final int finishIndex = pointerUp.indexOf('_finishFushiReaderMouseDrag(e)');
    final int gestureEndIndex = pointerUp.indexOf('_gestureEnd');
    expect(finishIndex, isNonNegative);
    expect(gestureEndIndex, isNonNegative);
    expect(finishIndex, lessThan(gestureEndIndex),
        reason: 'claimed drags must finish before the legacy _gestureEnd path');
    expect(containsCodeLine(pointerUp, 'if (_fushiReaderMouseDragClaimed)'),
        isTrue);
    expect(containsCodeLine(pointerUp, '_fushiReaderPointerNoSelect(false)'),
        isTrue);

    final String touchEnd = _jsListener(setupScript, 'touchend');
    final int ignoreIndex =
        touchEnd.indexOf('_fushiReaderMouseDragIgnoreTouchEnd');
    final int legacyEndIndex = touchEnd.indexOf('_gestureEnd');
    expect(ignoreIndex, isNonNegative);
    expect(legacyEndIndex, isNonNegative);
    expect(ignoreIndex, lessThan(legacyEndIndex),
        reason:
            'claimed touch drags must not replay tap/selection on touchend');
    expect(containsCodeLine(touchEnd, 'e.preventDefault()'), isTrue);
  });

  test('continuous pointer drag scrolls along horizontal and vertical axes',
      () {
    final String scrollFn = _jsFunction(
      setupScript,
      'function _fushiReaderMouseDragScrollBy(dx, dy)',
    );

    expect(containsCodeLine(scrollFn, 'r.isVertical'), isTrue);
    expect(containsCodeLine(scrollFn, 'window.scrollBy({left:'), isTrue);
    expect(
        containsCodeLine(scrollFn, 'window.scrollBy({left: 0, top:'), isTrue);

    final String pointerMove = _jsListener(setupScript, 'pointermove');
    expect(containsCodeLine(pointerMove, 'if (fushiContinuousMode)'), isTrue);
    expect(containsCodeLine(pointerMove, "callHandler('onSwipe'"), isFalse,
        reason: 'continuous pointer drag should scroll, not page-turn');
  });

  // BUG-338 (TODO-597): drag-to-pan must follow the pointer regardless of
  // writing-mode. Mouse-right (dx>0) → content right → scrollLeft down →
  // scrollBy({left: -dx}); mouse-up (dy<0) → content up → scrollTop up →
  // scrollBy({top: -dy}). The old vertical-rl `sign = -1` produced
  // scrollBy({left: dx}) and reversed the drag direction. Removing the sign
  // is the fix; this guard turns red if the writing-mode sign flip returns.
  test('continuous vertical drag follows the pointer without a sign flip', () {
    final String scrollFn = _jsFunction(
      setupScript,
      'function _fushiReaderMouseDragScrollBy(dx, dy)',
    );

    // Vertical axis: content follows the pointer with plain `-dx` (no sign).
    expect(containsCodeLine(scrollFn, 'window.scrollBy({left: -dx, top: 0'),
        isTrue,
        reason: 'vertical drag must pan with scrollBy({left: -dx}) so the '
            'content follows the pointer (mouse-right → content-right)');
    // Horizontal axis stays finger-following on the vertical pointer axis.
    expect(containsCodeLine(scrollFn, 'window.scrollBy({left: 0, top: -dy'),
        isTrue,
        reason: 'horizontal-writing drag must pan with scrollBy({top: -dy})');
    // The writing-mode-dependent sign flip that reversed vertical-rl is gone.
    expect(containsCodeLine(scrollFn, '-dx * sign'), isFalse,
        reason:
            'BUG-338: the writing-mode sign flip reversed vertical-rl drag');
    expect(containsCodeLine(scrollFn, "=== 'vertical-rl') ? -1"), isFalse,
        reason: 'BUG-338: drag pan direction must not depend on writing-mode');
  });

  test('paged desktop mouse drag emits at most one onSwipe on release', () {
    final String finishFn = _jsFunction(
      setupScript,
      'function _finishFushiReaderMouseDrag(e)',
    );

    expect(
        containsCodeLine(finishFn, '_fushiReaderMouseDragSwipeSent'), isTrue);
    expect(containsCodeLine(finishFn, '_fushiReaderMouseDragSwipeSent = true'),
        isTrue);
    expect(containsCodeLine(finishFn, "callHandler('onSwipe'"), isTrue);
    expect(
        containsCodeLine(finishFn, '_fushiReaderMouseDragPageDirection = null'),
        isTrue);

    final String pointerMove = _jsListener(setupScript, 'pointermove');
    expect(containsCodeLine(pointerMove, "callHandler('onSwipe'"), isFalse,
        reason: 'paged mouse drag decides direction during move but sends once '
            'from pointerup');
  });

  test(
      'link image context menu and non-left pointer seek wiring stays separate',
      () {
    expect(containsCodeLine(setupScript, "closest('a[href]')"), isTrue);
    expect(
        containsCodeLine(
            setupScript, "document.addEventListener('contextmenu'"),
        isTrue);
    expect(containsCodeLine(setupScript, "'onImageContextMenu'"), isTrue);

    final String mouseDown = _jsListener(setupScript, 'mousedown');
    expect(containsCodeLine(mouseDown, 'if (e.button === 0) return;'), isTrue);
    expect(containsCodeLine(mouseDown, 'e.button === 2 && _fushiBlockImageUrl'),
        isTrue);
    expect(containsCodeLine(mouseDown, "callHandler('onPointerSeek'"), isTrue);
  });

  // TODO-553: paged-mode touch must fall back to the touchstart/touchend swipe
  // path; only continuous mode lets touch drive the pointer drag machine. The
  // executable proof lives in reader_paged_touch_swipe_behavior_test.{js,dart};
  // this is the node-less static tripwire for the gates.
  test('touch only engages the pointer drag machine in continuous mode', () {
    final String engages = _jsFunction(
      setupScript,
      'function _fushiReaderPointerEngages(e)',
    );
    expect(containsCodeLine(engages, '_fushiReaderPointerPrimaryButton(e)'),
        isTrue);
    expect(containsCodeLine(engages, "e.pointerType === 'touch'"), isTrue);
    expect(containsCodeLine(engages, 'return fushiContinuousMode'), isTrue,
        reason: 'paged-mode touch must not enter the pointer drag machine');

    final String pointerDown = _jsListener(setupScript, 'pointerdown');
    expect(
        containsCodeLine(pointerDown, '_fushiReaderPointerEngages(e)'), isTrue,
        reason: 'pointerdown must gate touch through the engage predicate');

    final String pointerMove = _jsListener(setupScript, 'pointermove');
    expect(
        containsCodeLine(
            pointerMove, "e.pointerType === 'touch' && !fushiContinuousMode"),
        isTrue,
        reason: 'paged-mode touch moves must return before claiming a drag, '
            'leaving touchend -> _gestureEnd -> onSwipe to turn the page');

    final String pointerUp = _jsListener(setupScript, 'pointerup');
    expect(containsCodeLine(pointerUp, '_fushiReaderPointerEngages(e)'), isTrue,
        reason: 'paged-mode touch pointerup must not run the native-text path');

    final String pointerCancel = _jsListener(setupScript, 'pointercancel');
    expect(
        containsCodeLine(
            pointerCancel, "e.pointerType === 'touch' && !fushiContinuousMode"),
        isTrue,
        reason: 'paged-mode touch pointercancel must bail before resetting the '
            'drag machine, mirroring the pointermove exclusion');
  });
}

/// 从**掩码后**的合并语料里切出 setup 脚本这一段。
///
/// 两个标记都是 JS 语句本体，掩码后仍在；注释里写着同样的文字也不会再把边界锚歪。
String _between(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

/// JS 函数体窗口（花括号配对，JS 词法）。
///
/// 替掉旧的「从本函数签名找到**下一个**函数签名」文本窗口：那种窗口把两者之间的
/// 所有内容（别的函数、别的监听器）都算进来，断言命中的可能根本不是被守的函数。
String _jsFunction(String source, String signature) =>
    methodBody(source, signature, lexicon: SourceLexicon.js);

/// `document.addEventListener('<event>', function(e) {...})` 的**回调体**窗口。
///
/// 锚点取 `'<event>', function(e)`，[methodBody] 从这里配对回调的花括号，窗口就是
/// 这一个监听器的函数体。旧写法右边界是 `indexOf('}, {passive:')`——一旦某个监听器
/// 漏写 passive 选项，窗口会一路吞到下一个监听器里去。
String _jsListener(String source, String eventName) => methodBody(
      source,
      "'$eventName', function(e)",
      lexicon: SourceLexicon.js,
    );
