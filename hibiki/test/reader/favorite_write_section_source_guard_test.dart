import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-492 (TODO-1053 Bug A) 源码守卫：收藏/制卡写入的 sectionIndex 必须绑定到「选中该句
/// 时」的真实章号，不能在写入时刻再读裸 _currentChapter（有声书连续推进/跨章滚动会在选区
/// 与写入之间异步改写 _currentChapter → 记成相邻错章 → 恢复端跳错章、charAnchor 在错章内
/// 合法 → scrollToCharOffset 静默停错位）。
///
/// 契约：① 存在选区时刻快照字段 _cachedSelectionSectionIndex + 消费 getter
/// _favoriteSectionIndex；② 收藏 toggle / 制卡 / isFavorited 查询三处消费 _favoriteSectionIndex
/// 而非裸 _lookupSectionIndex；③ 三个选区缓存点都同批快照 section；④ 恢复端对越界 charAnchor
/// 有回退章首兜底（护住旧脏收藏），不静默停错位。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('page shell 定义选区章号快照字段 + _favoriteSectionIndex 消费 getter', () {
    final String src =
        read('lib/src/pages/implementations/reader_hibiki_page.dart');
    expect(src, contains('int? _cachedSelectionSectionIndex;'),
        reason: '选区时刻快照所属章号的字段必须存在');
    expect(
        src,
        contains(
            'int get _favoriteSectionIndex =>\n      _cachedSelectionSectionIndex ?? _lookupSectionIndex;'),
        reason: '消费 getter 优先用快照、无快照回退当前 _lookupSectionIndex');
    // dispose/clear 时复位快照，避免跨句串味。
    expect(src, contains('_cachedSelectionSectionIndex = null;'),
        reason: 'clearDictionaryResult 必须复位选区章号快照');
  });

  test(
      '收藏 toggle 与制卡写入的 section 取自 _favoriteSectionIndex（非裸 _lookupSectionIndex）',
      () {
    final String chrome =
        read('lib/src/pages/implementations/reader_hibiki/chrome.part.dart');
    final String mining =
        read('lib/src/pages/implementations/reader_hibiki/mining.part.dart');
    expect(chrome, contains('final int section = _favoriteSectionIndex;'),
        reason: '收藏 toggle 的 section 必须来自选区快照 getter');
    expect(mining, contains('final int section = _favoriteSectionIndex;'),
        reason: '制卡历史落库的 section 必须来自选区快照 getter');
    // 不得再在这两处直接用裸 _lookupSectionIndex 当 section 写入。
    expect(chrome.contains('final int section = _lookupSectionIndex;'), isFalse,
        reason: '收藏写入点不得回退裸 _lookupSectionIndex');
    expect(mining.contains('final int section = _lookupSectionIndex;'), isFalse,
        reason: '制卡写入点不得回退裸 _lookupSectionIndex');
  });

  test('三个选区缓存点都同批快照 section；isFavorited 查询消费快照', () {
    final String lookup =
        read('lib/src/pages/implementations/reader_hibiki/lookup.part.dart');
    final String chrome =
        read('lib/src/pages/implementations/reader_hibiki/chrome.part.dart');
    // 主 onTextSelected 路径 + 歌词 cue 路径都写快照。
    expect('x$lookup'.split('_cachedSelectionSectionIndex =').length - 1,
        greaterThanOrEqualTo(2),
        reason: 'lookup 主选区路径与歌词 cue 路径都要写 section 快照');
    // 原生选区路径（导出/制卡）也写快照。
    expect(
        chrome, contains('_cachedSelectionSectionIndex = _lookupSectionIndex;'),
        reason: '原生选区路径同样锁定所属章号');
    // isFavorited 查询用快照 getter，保证「是否已收藏」判定与写入同源 section。
    expect(lookup, contains('sectionIndex: _favoriteSectionIndex,'),
        reason: 'isFavorited 查询 section 与写入同源，避免星标判定错位');
  });

  test('恢复端对越界 charAnchor 有回退章首兜底（分页 + 连续两 shell）', () {
    final String js = read('lib/src/reader/reader_pagination_scripts.dart');
    expect(js, contains('charOffsetInRange: function(charOffset)'),
        reason: '共享越界判据必须存在');
    // 连续 shell：越界回退章首。
    expect(js, contains('if (!this.charOffsetInRange(charOffset)) {'),
        reason: '连续恢复越界回退 scrollToChapterStart');
    // 分页 shell：越界回退章首（scrollToProgressPaged 0）。
    expect(
        js,
        contains(
            'if (charOffset < 0 || !this.charOffsetInRange(charOffset)) {'),
        reason: '分页恢复越界回退 scrollToProgressPaged(context, 0)');
  });
}
