import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-136 回归守卫（源码扫描，沿用 `reanchor_charoffset_guard_test.dart` 的
/// `File(...).readAsStringSync()` + `contains` 模式）。
///
/// 现象：书籍退出再进，阅读位置不是同一个（系统性前移约一页）。
///
/// 根因：阅读器有两套位置坐标系——① 精确**绝对字符偏移**
/// （`getFirstVisibleCharOffset`→`scrollToCharOffset`，「存→取」不动点，BUG-109
/// 已让切样式/chrome-inset 重锚改用它）；② 粗粒度**进度分数**
/// （`calculateProgress`→`scrollToProgressPaged`/`findNodeAtProgress`+`alignToPage`
/// 取整，非不动点、落相邻页）。**持久化恢复**（退出再进）当年漏修，仍走 ②。
///
/// 修复：保存时把 `getFirstVisibleCharOffset()` 的 section 内精确字符偏移随
/// `hoshiProgressDetails` 报上来、落 DB 新列 `char_offset`；恢复时 `>=0` 走新增的
/// `restoreToCharOffset(charOffset)`（分页+连续都加，复用成熟 `scrollToCharOffset`），
/// 否则回退 `restoreProgress(分数)`（旧存档兼容）。
///
/// 谁把恢复退回纯粗粒度分数路径、或保存不再报精确偏移，本测试红。
void main() {
  final String pageSrc = File(
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ).readAsStringSync();
  final String jsSrc = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  ).readAsStringSync();

  test('hoshiProgressDetails 携带 getFirstVisibleCharOffset 精确偏移 (BUG-136)', () {
    final int start = pageSrc.indexOf('window.hoshiProgressDetails = function');
    expect(start, greaterThanOrEqualTo(0),
        reason: '找不到 hoshiProgressDetails 定义');
    final int end = pageSrc.indexOf('\n  };', start);
    expect(end, greaterThan(start));
    final String body = pageSrc.substring(start, end);
    expect(body.contains('getFirstVisibleCharOffset'), isTrue,
        reason: 'hoshiProgressDetails 必须报告精确字符偏移，否则退出再进只能回退粗粒度分数');
  });
}
