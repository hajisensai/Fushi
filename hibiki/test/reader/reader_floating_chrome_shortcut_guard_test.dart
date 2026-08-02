import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// BUG-1423：阅读器 `readerToggleChrome` 快捷键（键盘 / 手柄）在悬浮底栏下必须进
/// 临时显隐状态机，而不是去翻不可见的 `_showChrome` 旗标。
///
/// `_showChrome` 在悬浮态只是「底栏功能是否启用」的持久开关，用户看到的可见态是
/// `_chromeTransientVisible` + `_chromeAutoHideTimer`。旧实现让快捷键直接调
/// `_toggleChrome()`，于是按键什么都不发生（必须先用鼠标点空白唤栏），且旧计时器
/// 到点还会在操作中途把栏收掉。

/// 取 [startMarker] 到 [endMarker] 之间的源码片段。
///
/// 传进来的 [source] 必须是 [maskComments] 处理过的等长掩码串：相邻方法的文档注释
/// 里出现同名符号，会让下面的要求型断言被注释骗绿、负向断言被注释判红。
String _slice(String source, String startMarker, String endMarker) {
  final int start = source.indexOf(startMarker);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $startMarker');
  final int end = source.indexOf(endMarker, start + startMarker.length);
  expect(end, greaterThan(start),
      reason: 'missing $endMarker after $startMarker');
  return source.substring(start, end);
}

void main() {
  final String source = maskComments(readReaderPageSource());

  test('reader chrome shortcut enters the floating visibility state machine',
      () {
    final String action = _slice(
      source,
      'case ShortcutAction.readerToggleChrome:',
      'case ShortcutAction.readerOpenMenu:',
    );
    expect(action, contains('_toggleChromeFromShortcut();'));
    // 负向：绝不能退回直调挤压模式入口（`_toggleChromeFromShortcut();` 不含
    // `_toggleChrome();` 这个字面量，所以这条断言是真的负向断言）。
    expect(action, isNot(contains('_toggleChrome();')));

    final String helper = _slice(
      source,
      'void _toggleChromeFromShortcut()',
      'void _toggleChrome()',
    );
    expect(helper, contains('if (_bottomBarFloating)'));
    expect(helper, contains('_handleFloatingChromeReveal()'));
    expect(
      helper,
      contains('_focusOwnership.reclaim(FocusReclaimCause.chromeToggled)'),
    );
    // 挤压模式仍走旧入口。
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
