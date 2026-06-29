import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-459 接线守卫：收藏句 / 制卡历史「跳回原文」必须按「章节内绝对字符锚」定位，
/// 不能把 getNormalizedOffset 口径的绝对索引误当 0-10000 进度分数 /10000≈0 而恒跳
/// 章首；且临时浏览跳转不得覆盖用户该书已保存的真实阅读进度。
///
/// 这是源码扫描守卫（跳转走 WebView 几何，widget 层难真触发），盯死契约分流点不回归。
void main() {
  test('collections_page 句子/制卡跳转走 charAnchor + preserveSavedPosition（非分数）', () {
    final String src =
        File('lib/src/pages/implementations/collections_page.dart')
            .readAsStringSync();
    // 必须按行类型分流：sentence/mined = 绝对字符锚跳转。
    expect(src, contains('item.type == _CollectionType.sentence ||'),
        reason: '必须区分句子/制卡（绝对字符锚）与书签（0-10000 分数）');
    expect(src, contains('charAnchor: isSentenceJump ? item.normCharOffset'),
        reason: '句子/制卡的 normCharOffset 是绝对字符锚，须经 charAnchor 透传');
    expect(src, contains('preserveSavedPosition: isSentenceJump'),
        reason: '临时浏览跳转必须标 preserveSavedPosition 防覆盖原阅读进度');
    // 书签仍走 normCharOffset 分数（非句子跳转才填 normCharOffset）。
    expect(
        src,
        contains(
            'normCharOffset: isSentenceJump ? 0 : (item.normCharOffset ?? 0)'),
        reason: '真实书签仍按 normCharOffset 分数路径（向后兼容）');
  });

  test('reader 跳转分支：charAnchor 走精确字符锚恢复、preserve 时抑制持久化', () {
    final String src =
        File('lib/src/pages/implementations/reader_hibiki_page.dart')
            .readAsStringSync();
    expect(src, contains('final int? charAnchor = bm.charAnchor;'),
        reason: '读取跳转携带的绝对字符锚');
    expect(src, contains('_initialCharOffset = charAnchor;'),
        reason: 'charAnchor 非负时设精确字符锚 → restoreToCharOffset 精确恢复');
    expect(
        src, contains('_suppressPositionPersist = bm.preserveSavedPosition;'),
        reason: '临时浏览跳转据 preserveSavedPosition 置位抑制标记');
    // BUG-162 分数兜底路径仍在（真实书签 charAnchor==null）。
    expect(src, contains('_initialProgress = bm.normCharOffset / 10000.0;'),
        reason: '真实书签仍按分数恢复，未破坏既有行为');
  });

  test('_persistPosition 单点拦截：preserve 跳转不落盘覆盖原进度', () {
    final String src =
        File('lib/src/pages/implementations/reader_hibiki/navigation.part.dart')
            .readAsStringSync();
    // 抑制守卫必须在写 _lastSaved* / upsert 之前（debounce 与退出 flush 都汇聚此处）。
    final int guardIdx = src.indexOf('if (_suppressPositionPersist)');
    final int persistIdx = src.indexOf('_lastSavedSection = section;');
    expect(guardIdx, greaterThanOrEqualTo(0),
        reason: '_persistPosition 必须有 _suppressPositionPersist 抑制守卫');
    expect(persistIdx, greaterThan(guardIdx),
        reason: '抑制守卫必须在落盘写入之前（早返回不覆盖原 ReaderPosition）');
  });
}
