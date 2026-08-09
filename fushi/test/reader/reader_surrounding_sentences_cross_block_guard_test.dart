// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

/// BUG-764 守卫：制卡「上 N 句 / 下 N 句」的相邻句种子游走（charAt / charBefore）必须能
/// 跨 `<p>`/块级边界——即用 document.body 级 walker，而**不**困在 `findParagraph` 的当前块内。
///
/// 旧实现用 `findParagraph(node)` 作 TreeWalker root，`nextNode()`/`previousNode()` 走不出
/// 当前 `<p>`，段末即返回 null → `getSurroundingSentences` break → 跨段落取不到下一句 →
/// 用户点「后加一句」没反应。句子自身仍由 getSentenceContext 的 findParagraph 限定在其块内，
/// 这里只放宽「找相邻句起点」到跨段（与 collectRangeBetween 同一套 document 级 walker）。
///
/// 触屏真机才能跑真 DOM 遍历，故用生成 JS 源码扫描钉死契约。
String _between(String src, String start, String end) {
  final int s = src.indexOf(start);
  final int e = src.indexOf(end, s + start.length);
  expect(s, greaterThanOrEqualTo(0), reason: '找不到 $start');
  expect(e, greaterThan(s), reason: '找不到 $end（在 $start 之后）');
  return src.substring(s, e);
}

void main() {
  final String js = ReaderSelectionScripts.source();

  test('charBefore 用 document.body 级 walker（跨段回退上一句）', () {
    final String body =
        _between(js, 'charBefore: function', 'charAt: function');
    expect(body, contains('this.createWalker(document.body)'),
        reason: 'charBefore 必须用 document.body walker 才能跨块');
    expect(body, isNot(contains('findParagraph(node)')),
        reason: 'charBefore 不得再用 findParagraph 把 walker 困在当前块（BUG-764 根因）');
  });

  test('charAt 用 document.body 级 walker（跨段取下一句）', () {
    final String body =
        _between(js, 'charAt: function', 'selectText: function');
    expect(body, contains('this.createWalker(document.body)'),
        reason: 'charAt 必须用 document.body walker 才能跨块');
    expect(body, isNot(contains('findParagraph(node)')),
        reason: 'charAt 不得再用 findParagraph 把 walker 困在当前块（BUG-764 根因）');
  });
}
