import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

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

  test('floating show/hide is one click switch, no timer of its own', () {
    final String reveal = _slice(
      source,
      'bool _handleFloatingChromeReveal()',
      'void _handleVnBlankTap()',
    );
    // 用户 2026-09-14：这条路是纯开关——同一下点击既能开也能关，方向由当前态
    // 决定，而不是「开一次再等计时关」。
    expect(reveal, contains('_chromeTransientVisible = !_chromeTransientVisible'));
    expect(
      reveal,
      isNot(contains('_armChromeAutoHide();')),
      reason: '点出来的栏不自动收起；计时只剩 VN 推进那一处',
    );
    // 仍要停表：VN 推进可能刚武装过一次，收起时不停掉，计时到点会对着已收起的
    // 栏再通知一次。
    expect(reveal, contains('_cancelChromeAutoHide();'));
  });
}
