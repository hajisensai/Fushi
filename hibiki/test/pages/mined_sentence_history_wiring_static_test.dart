import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';
import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫（TODO-633 制卡历史）：制卡成功的**三条**真实路径都必须额外落一条
/// `mined_sentences` 历史行，否则收藏夹页「制卡句」分段恒为空。
///
/// 与 [mining_count_wiring_static_test] 同理：reader（`BaseSourcePageState`
/// 覆写，自带私有钩子）、mixin（`DictionaryPageMixin.onMineEntry`，服务独立查词/
/// 首页词典）、video（覆写 `onMineEntry`，绕过 mixin）三条路径各自记账，撤掉任一
/// 条写入即红。这些页面（reader WebView / video media_kit）headless 无法实例化、
/// 真制卡依赖真 Anki，端到端不可落地，故用结构化源码守卫。
///
/// 同时守 CollectionsPage 把制卡历史读出来并作为独立分段展示 + 可按 id 删除。
void main() {
  test('reader 制卡成功在 record 分支额外落一条 mined_sentences', () {
    final String src = readReaderPageSource();
    expect(src, contains('_recordMinedSentence('),
        reason: 'reader 成功制卡必须落制卡历史行');
    expect(
      src,
      contains('Future<void> _recordMinedSentence('),
      reason: 'reader 应自带制卡历史 helper（不 mixin DictionaryPageMixin）',
    );
    expect(src, contains('addMinedSentence('));
    expect(src, contains('source: kStatSourceBook'),
        reason: 'reader 制卡历史来源应为书籍');
    expect(src, contains('bookKey: widget.bookKey'),
        reason: 'reader 制卡历史必须带 bookKey 定位锚，收藏夹才能跳回原书');
  });

  test('video 覆写 onMineEntry 在成功分支额外落一条 mined_sentences', () {
    // TODO-590 batch14: `_recordMinedSentenceForVideo` 已搬进 lookup_mining.part.dart，
    // 读合并语料（主壳 + 全部 part）才能命中。
    final String src = readVideoHibikiSource();
    expect(src, contains('_recordMinedSentenceForVideo('),
        reason: 'video 成功制卡必须落制卡历史行');
    expect(src, contains('Future<void> _recordMinedSentenceForVideo('));
    expect(src, contains('addMinedSentence('));
    expect(src, contains('source: kStatSourceVideo'),
        reason: 'video 制卡历史来源应为视频');
    expect(src, contains('bookKey: widget.bookUid'),
        reason: 'video 制卡历史的定位锚是 bookUid，收藏夹才能跳回视频');
  });

  test('mixin onMineEntry 在 record 分支额外落一条 mined_sentences（首页/独立查词）', () {
    final String src =
        File('lib/src/pages/implementations/dictionary_page_mixin.dart')
            .readAsStringSync();
    expect(src, contains('recordMinedSentence('), reason: '基类成功分支必须落制卡历史行');
    expect(src, contains('Future<void> recordMinedSentence('));
    expect(src, contains('addMinedSentence('));
    expect(src, contains('source: dictionarySourceType'),
        reason: 'mixin 制卡历史来源跟随 dictionarySourceType（book/video）');
  });

  test('CollectionsPage 读 mined_sentences 并作独立「制卡句」分段展示 + 可删除', () {
    final String src =
        File('lib/src/pages/implementations/collections_page.dart')
            .readAsStringSync();
    expect(src, contains('_CollectionType.mined'), reason: '收藏夹应有独立的「制卡句」条目类型');
    expect(src, contains('getAllMinedSentences('), reason: '收藏夹应从 DB 读全部制卡历史');
    expect(src, contains('removeMinedSentence('), reason: '制卡历史条目应可按 id 删除');
    expect(src, contains('t.collection_mined'), reason: '制卡句条目应有自己的 i18n 标签');
  });
}
