import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-700 T8 回归守卫：阅读 caret 激活时按物理「下」到可视底边，应**翻页**
/// （和正文 Down 翻页同路径），而不是晋升底栏。底栏已被 ExcludeFocus 移出焦点
/// 遍历池，旧的「Down→晋升底栏」(BUG-019/020) 搬运路径 (`_promoteCaretToChrome`)
/// 已随之删除——若再退回那条路径会逐行退化成纯 no-op（Down 到底边卡死，既不翻页
/// 也进不了底栏）。本守卫锁死「Down 到底边 == 翻页」这一名实相符的语义，并在源码
/// 层扫描确认死路径符号不再复活。
///
/// 纯决策函数 [readerCaretMoveOutcome] 把 hoshiCaret.move 返回的 status +
/// 物理方向映射到 Dart 侧动作，脱离 WebView 可单测（caret 移动的 JS 行为本身在
/// 设备复测覆盖）。
void main() {
  test('physical down at page/scroll edge paginates forward (no dead promote)',
      () {
    // 分页模式：到页边返回 pageForward → 翻到下一页。
    expect(readerCaretMoveOutcome('down', 'pageForward'),
        ReaderCaretMoveOutcome.paginateForward);
    // 连续模式：到文档末尾返回 blocked → 同样翻页（不再是死路 / no-op）。
    expect(readerCaretMoveOutcome('down', 'blocked'),
        ReaderCaretMoveOutcome.paginateForward);
  });

  test('mid-page down just moves the caret (no paginate)', () {
    expect(
        readerCaretMoveOutcome('down', 'moved'), ReaderCaretMoveOutcome.none);
  });

  test('logical forward (Tab / vertical reading) still paginates at edge', () {
    // 竖排里物理 down 的「逻辑」是 forward；Tab 传的是 'forward'，照常翻页。
    expect(readerCaretMoveOutcome('forward', 'pageForward'),
        ReaderCaretMoveOutcome.paginateForward);
  });

  test('non-down directions keep page-turn at edges', () {
    expect(readerCaretMoveOutcome('up', 'pageBackward'),
        ReaderCaretMoveOutcome.paginateBackward);
    expect(readerCaretMoveOutcome('left', 'pageForward'),
        ReaderCaretMoveOutcome.paginateForward);
    expect(readerCaretMoveOutcome('right', 'pageBackward'),
        ReaderCaretMoveOutcome.paginateBackward);
    // up blocked (top edge) is a no-op here (reader content has no upward
    // sibling layer; popup-up->header is handled separately).
    expect(
        readerCaretMoveOutcome('up', 'blocked'), ReaderCaretMoveOutcome.none);
  });

  test('dead caret->chrome promote path stays removed (TODO-700 T8)', () {
    // T8 把底栏移出焦点遍历后，这些符号若复活就是 dead-no-op 回归：
    //  - `promoteChrome` 枚举值 / `_promoteCaretToChrome` 搬运方法已删；
    //  - 底栏 ExcludeFocus 后 `_chromeFocusScope.nextFocus()` 恒不可达，零调用。
    final String code = readReaderPageSource();
    expect(code.contains('promoteChrome'), isFalse,
        reason: 'ReaderCaretMoveOutcome.promoteChrome was removed in T8 — a '
            'physical Down at the bottom edge paginates, it does not promote '
            'into the (now unfocusable) chrome bar');
    expect(code.contains('_promoteCaretToChrome'), isFalse,
        reason: 'the _promoteCaretToChrome caret->chrome hand-off was removed '
            'in T8 (it degraded to a pure no-op once the bar left focus '
            'traversal); do not reintroduce it');
    expect(code.contains('_chromeFocusScope.nextFocus()'), isFalse,
        reason: 'the chrome bar is ExcludeFocus-wrapped and never traversed; '
            'any _chromeFocusScope.nextFocus() call is unreachable dead code');
  });
}
