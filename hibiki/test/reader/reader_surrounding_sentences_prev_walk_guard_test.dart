import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';

/// BUG-829 守卫：制卡「往前加一句」的向前句游走不得用 `before.offset + 1`。
///
/// 根因：`charBefore(node, offset)` 在同节点内返回 `{node, offset-1}`，即
/// `before.offset = anchorOffset - 1`。若再 `getSentenceContext(before.node, before.offset + 1)`
/// 就等于 `anchorOffset` = 当前句首光标 → `getSentenceContext` 重新解析出**当前句**、
/// anchor 原地不动 → 前文列表全是同一句（当前句）重复。必须用 `before.offset` 本身
/// （= 上一句最后一个字符/句号），才会落在上一句里逐句后退。向后循环
/// `getSentenceContext(after.node, after.offset)` 本就无 `+1`，故对称。
///
/// 触屏真机才能跑真 DOM 遍历，故沿用 BUG-764 同款生成 JS 源码扫描守卫。
String _between(String src, String start, String end) {
  final int s = src.indexOf(start);
  final int e = src.indexOf(end, s + start.length);
  expect(s, greaterThanOrEqualTo(0), reason: '找不到 $start');
  expect(e, greaterThan(s), reason: '找不到 $end（在 $start 之后）');
  return src.substring(s, e);
}

void main() {
  final String js = ReaderSelectionScripts.source();

  test('getSurroundingSentences 向前循环用 before.offset（不得 +1 退回当前句）', () {
    final String body = _between(
      js,
      'getSurroundingSentences: function',
      'nativeSelectionSentenceRange: function',
    );
    // 只截到向前循环（往后循环用 after/getSentenceContext(after.offset)，不受本守卫约束）。
    final String prevLoop = _between(
      body,
      'for (var i = 0; i < prevCount; i++)',
      'result.prev.unshift',
    );
    expect(
      prevLoop,
      contains('this.getSentenceContext(before.node, before.offset)'),
      reason: '向前循环必须用 before.offset 定位上一句（BUG-829 根因）',
    );
    expect(
      prevLoop,
      isNot(contains('before.offset + 1')),
      reason: 'before.offset + 1 会退回当前句首光标 → 前文重复当前句（BUG-829）',
    );
  });
}
