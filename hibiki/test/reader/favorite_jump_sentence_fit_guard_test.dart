import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// BUG-461 回归守卫（源码扫描）：连续(滚动)模式收藏句跳转必须把句长(句尾偏移)透传到
/// JS，按字符**区间**整句对齐进可见区，而不是只把句首贴顶（句尾被阅读底栏切 = 用户报的
/// 「五五开切句尾」）。
///
/// 数据流：`FavoriteSentence.normCharLength` → `_CollectionItem.normCharLength` →
/// `Bookmark.charAnchorLength` → 阅读器 `_initialCharOffsetEnd`(charAnchor+len) →
/// `ReaderPaginationScripts.shellScript(initialCharOffsetEnd:)` → 连续 shell
/// `restoreToCharOffset(start, end)` → 连续 `scrollToCharOffset(start, endCharOffset)`
/// 句尾区间对齐。
///
/// 谁把这条链任一环断掉（句长没透传 / 连续 scrollToCharOffset 退回只锚句首），本测试红。
void main() {
  final String jsSrc = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  ).readAsStringSync();
  final String collectionsSrc = File(
    'lib/src/pages/implementations/collections_page.dart',
  ).readAsStringSync();
  final String pageSrc = readReaderPageSource();

  test('collections 跳转把句长透传成 Bookmark.charAnchorLength (BUG-461)', () {
    expect(collectionsSrc.contains('charAnchorLength:'), isTrue,
        reason: '收藏句跳转必须把 item.normCharLength 透传为 Bookmark.charAnchorLength，'
            '否则连续模式只能锚句首、长句句尾被底栏切');
  });

  test('阅读器据 charAnchorLength 算句尾锚 _initialCharOffsetEnd 并传 shell (BUG-461)',
      () {
    expect(pageSrc.contains('charAnchorLength'), isTrue,
        reason: '阅读器 restore 必须读 bm.charAnchorLength');
    expect(pageSrc.contains('_initialCharOffsetEnd'), isTrue,
        reason: '阅读器必须算句尾绝对偏移 _initialCharOffsetEnd');
    expect(pageSrc.contains('initialCharOffsetEnd:'), isTrue,
        reason: 'shellScript 调用必须把 _initialCharOffsetEnd 传给 JS');
  });

  test('shellScript / 连续 shell 接受并透传 initialCharOffsetEnd (BUG-461)', () {
    expect(jsSrc.contains('int initialCharOffsetEnd = -1'), isTrue,
        reason:
            'shellScript 与 _continuousShellScript 必须接受 initialCharOffsetEnd 参数');
    // 连续 shell 在句尾>句首时调带两参的 restoreToCharOffset。
    expect(
      jsSrc.contains(
          r'restoreToCharOffset($initialCharOffset, $initialCharOffsetEnd)'),
      isTrue,
      reason: '连续 shell 必须在有句尾锚时调 restoreToCharOffset(start, end)',
    );
  });

  test('连续 scrollToCharOffset 接受 endCharOffset 并做句尾区间对齐 (BUG-461)', () {
    // 连续 scrollToCharOffset 签名带第二参 endCharOffset。
    expect(
        jsSrc.contains(
            'scrollToCharOffset: function(charOffset, endCharOffset)'),
        isTrue,
        reason: '连续 scrollToCharOffset 必须接受可选 endCharOffset 做整句区间对齐');
    // restoreToCharOffset 连续版把 endCharOffset 透传给 scrollToCharOffset。
    expect(
      jsSrc.contains(
          'restoreToCharOffset: async function(charOffset, endCharOffset)'),
      isTrue,
      reason: '连续 restoreToCharOffset 必须接受并透传 endCharOffset',
    );
    expect(jsSrc.contains('this.scrollToCharOffset(charOffset, endCharOffset)'),
        isTrue,
        reason: 'restoreToCharOffset 必须把 endCharOffset 透传给 scrollToCharOffset');
    // 区间对齐用 chrome-bottom-inset 算可见区底沿。
    expect(jsSrc.contains('--chrome-bottom-inset'), isTrue,
        reason: '句尾区间对齐必须按 chrome-bottom-inset 算可见区底沿，确保句尾不落底栏后');
  });
}
