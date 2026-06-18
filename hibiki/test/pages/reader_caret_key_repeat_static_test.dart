import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-066 源码守卫：阅读器字符光标在按住方向键时随 OS 自动重复
/// ([KeyRepeatEvent]) 连续逐字移动，而激活 / 退出不随重复连发。
///
/// 阅读器光标活在 WebView 里，Flutter 框架的方向遍历照不到它，所以「按住连续移动」
/// 必须由阅读器 `_handleKeyEvent` 在 KeyDown-only 闸门之前显式处理 KeyRepeat。
/// 这里用源码扫描守卫（光标行为需真实 WebView，无法纯 widget 测试），锁定：
///   ① 存在 caret 的 KeyRepeat 分支，且门控在 `_focusNavEnabled && _caretActive`；
///   ② 只放行移动类 [CaretAction]（`_isRepeatableCaretMove`），activate/dismissOrExit
///      仍一次一按（按住 Enter 不连发查词、按住 Esc 不连发退出）。
void main() {
  late final String reader = File(
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ).readAsStringSync();

  test(
      'caret repeat-step branch is gated on the focus-nav switch + active caret',
      () {
    expect(
      reader,
      contains('_focusNavEnabled && _caretActive && event is KeyRepeatEvent'),
      reason: '光标连续移动只在焦点导航开关开 + 光标激活时处理 KeyRepeat',
    );
    // 重复分支必须落在 KeyDown-only 闸门之前，否则闸门会先把 KeyRepeat 拦掉。
    final int repeatIdx = reader
        .indexOf('_focusNavEnabled && _caretActive && event is KeyRepeatEvent');
    final int keyDownGateIdx = reader.indexOf(
      'if (event is! KeyDownEvent) return KeyEventResult.ignored;',
      repeatIdx,
    );
    expect(repeatIdx, isNonNegative);
    expect(keyDownGateIdx, isNonNegative);
    expect(
      repeatIdx,
      lessThan(keyDownGateIdx),
      reason: '光标 KeyRepeat 分支必须在 KeyDown-only 闸门之前',
    );
  });

  test(
      'only movement caret actions repeat; activate/dismiss stay one-per-press',
      () {
    expect(reader, contains('_isRepeatableCaretMove(repeatCaret)'));
    expect(reader,
        contains('static bool _isRepeatableCaretMove(CaretAction action)'));
    // 移动类放行。
    for (final String move in <String>[
      'CaretAction.stepForward',
      'CaretAction.stepBackward',
      'CaretAction.moveUp',
      'CaretAction.moveDown',
      'CaretAction.moveLeft',
      'CaretAction.moveRight',
    ]) {
      expect(reader, contains(move), reason: '$move 应可重复');
    }
    // 非移动类（激活 / 查词 / 长按 / 退出）必须在 helper 中显式列为 false 分支，
    // 确保按住 Enter / Esc 不会随重复连发。
    final int helperStart = reader
        .indexOf('static bool _isRepeatableCaretMove(CaretAction action)');
    final int helperEnd =
        reader.indexOf('Future<void> _runCaretAction', helperStart);
    expect(helperStart, isNonNegative);
    expect(helperEnd, greaterThan(helperStart));
    final String helperBody = reader.substring(helperStart, helperEnd);
    for (final String nonMove in <String>[
      'CaretAction.activate',
      'CaretAction.lookup',
      'CaretAction.longPress',
      'CaretAction.dismissOrExit',
    ]) {
      expect(helperBody, contains(nonMove),
          reason: '$nonMove 必须在 helper 中显式归为不可重复（false）');
    }
    expect(helperBody, contains('return false;'),
        reason: 'helper 必须有非移动类 → false 的分支');
  });
}
