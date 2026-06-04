import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

/// BUG-020 回归守卫：阅读 caret 激活时按物理「下」到可视底边，应**晋升到底栏**
/// 而非翻页（候选①：Down 不翻页；翻页留给 Left/Right 或 LB/RB）。
///
/// 纯决策函数 [readerCaretMoveOutcome] 把 hoshiCaret.move 返回的 status +
/// 物理方向映射到 Dart 侧动作，脱离 WebView 可单测（caret 移动的 JS 行为本身在
/// 设备复测覆盖）。只有**物理 down**（方向键/D-pad 下）在页边晋升底栏；逻辑
/// `forward`（Tab/竖排阅读推进）仍照常翻页，二者必须区分。
void main() {
  test('physical down at page/scroll edge promotes to chrome, not paginate',
      () {
    expect(readerCaretMoveOutcome('down', 'pageForward'),
        ReaderCaretMoveOutcome.promoteChrome);
    // 连续模式到文档末尾返回 blocked → 同样晋升底栏（不是死路）。
    expect(readerCaretMoveOutcome('down', 'blocked'),
        ReaderCaretMoveOutcome.promoteChrome);
  });

  test('mid-page down just moves the caret (no promote, no paginate)', () {
    expect(
        readerCaretMoveOutcome('down', 'moved'), ReaderCaretMoveOutcome.none);
  });

  test('logical forward (Tab / vertical reading) still paginates at edge', () {
    // 竖排里物理 down 的「逻辑」是 forward，但 Tab 传的是 'forward'，不该被当成
    // 「去底栏」——只拦截显式物理 'down'。
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
    // sibling layer; popup-up→header is handled separately).
    expect(
        readerCaretMoveOutcome('up', 'blocked'), ReaderCaretMoveOutcome.none);
  });
}
