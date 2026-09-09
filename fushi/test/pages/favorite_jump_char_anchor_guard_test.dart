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
        File('lib/src/pages/implementations/reader_fushi_page.dart')
            .readAsStringSync();
    expect(src, contains('final int? charAnchor = bm.charAnchor;'),
        reason: '读取跳转携带的绝对字符锚');
    // 钉不变式而不是写法：起点字段后来收敛成唯一写入口 [_setOpenResumePoint]
    // （某条分支只写 progress 不决定 charOffset 会让上一条分支残留的锚把视口拽回
    // 旧位置），`_initialCharOffset = charAnchor;` 这行字面量早就不存在了，但接线
    // 一点没断。所以这里只要求「精确判据存在」且「charAnchor 被交给起点的
    // charOffset」，允许中间隔着三元、换行与参数名。
    expect(
      src,
      matches(RegExp(r'precise\s*=\s*charAnchor\s*!=\s*null\s*&&'
          r'\s*charAnchor\s*>=\s*0')),
      reason: 'charAnchor 非负才算精确锚',
    );
    expect(
      src,
      matches(RegExp(r'charOffset:\s*precise\s*\?\s*charAnchor\s*:')),
      reason: 'charAnchor 精确时交给起点的 charOffset → restoreToCharOffset 精确恢复',
    );
    expect(
        src, contains('_suppressPositionPersist = bm.preserveSavedPosition;'),
        reason: '临时浏览跳转据 preserveSavedPosition 置位抑制标记');
    // BUG-162 分数兜底路径仍在（真实书签 charAnchor==null）。
    expect(
      src,
      matches(RegExp(r'progress:\s*precise\s*\?\s*0\.0\s*:'
          r'\s*bm\.normCharOffset\s*/\s*10000\.0')),
      reason: '不精确时仍按分数恢复，未破坏既有行为',
    );
    // 起点必须经唯一写入口写——这才是那次重构真正要护住的东西，旧守卫护不到：
    // 绕开它单写 _initialCharOffset 就会让别的分支残留锚复活。
    expect(
      src,
      contains('void _setOpenResumePoint({'),
      reason: '开书起点必须保留唯一写入口',
    );
    expect(
      RegExp(r'^\s*_initialCharOffset\s*=', multiLine: true)
          .allMatches(src)
          .length,
      1,
      reason: '_initialCharOffset 只能在 _setOpenResumePoint 里被赋值一次'
          '（字段声明的初始化不算——正则按行首赋值语句匹配）',
    );
  });

  test('_persistPosition 单点拦截：preserve 跳转不落盘覆盖原进度', () {
    final String src =
        File('lib/src/pages/implementations/reader_fushi/navigation.part.dart')
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
