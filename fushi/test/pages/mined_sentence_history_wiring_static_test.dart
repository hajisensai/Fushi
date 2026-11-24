import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'reader_fushi_page_source_corpus.dart';
import 'video_fushi_page_source_corpus.dart';

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
    expect(
      src,
      contains('_recordMinedSentence('),
      reason: 'reader 成功制卡必须落制卡历史行',
    );
    expect(
      src,
      contains('Future<void> _recordMinedSentence('),
      reason: 'reader 应自带制卡历史 helper（不 mixin DictionaryPageMixin）',
    );
    expect(src, contains('addMinedSentence('));
    expect(
      src,
      contains('source: kStatSourceBook'),
      reason: 'reader 制卡历史来源应为书籍',
    );
    expect(
      src,
      contains('bookKey: widget.bookKey'),
      reason: 'reader 制卡历史必须带 bookKey 定位锚，收藏夹才能跳回原书',
    );
  });

  test('video 覆写 onMineEntry 在成功分支额外落一条 mined_sentences', () {
    // TODO-590 batch14: `_recordMinedSentenceForVideo` 已搬进 lookup_mining.part.dart，
    // 读合并语料（主壳 + 全部 part）才能命中。
    final String src = readVideoFushiSource();
    expect(
      src,
      contains('_recordMinedSentenceForVideo('),
      reason: 'video 成功制卡必须落制卡历史行',
    );
    expect(src, contains('Future<void> _recordMinedSentenceForVideo('));
    // 页面侧只转发：实际写入收口在 `recordVideoMinedSentence`（video_mine_queue.dart），
    // 暂存队列写入 Anki 时落的是同一行。
    expect(
      methodBody(src, 'Future<void> _recordMinedSentenceForVideo('),
      contains('recordVideoMinedSentence('),
      reason: '视频页制卡历史必须走与暂存队列共用的 recordVideoMinedSentence',
    );
    final String shared = methodBody(
      File('lib/src/mining/video_mine_queue.dart').readAsStringSync(),
      'Future<void> recordVideoMinedSentence(',
    );
    expect(shared, contains('addMinedSentence('));
    expect(
      shared,
      contains('source: kStatSourceVideo'),
      reason: 'video 制卡历史来源应为视频',
    );
    final String mine = compactCode(
      methodBody(src, 'Future<MinePopupResult> _onMineEntryImpl('),
    );
    expect(mine, contains('VideoMiningHistorySnapshot.capture('));
    // 制卡时冻结句子所属那一行的 uid：原盘菜单切标题后不能仍记入口视频；原盘「全部
    // 播放」按句子所在那一集记（BUG-5340 / BUG-5356，与收藏句同一口径），不在原盘
    // 播放列表里时 [_libraryAnchorAt] 自己回落到当前真实标题 [_activeBookUid]。
    expect(
      mine,
      contains('_libraryAnchorAt(historyCue.startMs)'),
      reason: '制卡历史锚点必须按句子所在那一集的时间轴算',
    );
    expect(
      mine,
      contains('bookKey:historyAnchor?.bookUid??_activeBookUid,'),
      reason: '制卡时冻结当前真实标题的 uid，原盘菜单切标题后不能仍记入口视频',
    );
    expect(
      compactCode(src),
      contains(
        '({StringbookUid,intms})_libraryAnchorAt(intplayerMs)=>_discMenuEpisodes?.anchorAt(playerMs)??(bookUid:_activeBookUid,ms:playerMs);',
      ),
      reason: '不在原盘播放列表里时锚点回落到当前真实标题',
    );
    expect(
      compactCode(src),
      contains(
        'Stringget_activeBookUid=>_discBookUid??_webEpisodeBookUid??widget.bookUid;',
      ),
      reason: '普通视频仍使用 widget.bookUid，原盘使用已绑定的当前标题身份',
    );
    final String record = compactCode(
      methodBody(src, 'Future<void> _recordMinedSentenceForVideo('),
    );
    expect(
      record,
      contains('bookKey:snapshot.bookKey,'),
      reason: '后台制卡历史必须沿点击时的快照写入，不能读取后来切换的标题',
    );
  });

  test('mixin onMineEntry 在 record 分支额外落一条 mined_sentences（首页/独立查词）', () {
    final String src = File(
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
    ).readAsStringSync();
    expect(src, contains('recordMinedSentence('), reason: '基类成功分支必须落制卡历史行');
    expect(src, contains('Future<void> recordMinedSentence('));
    expect(src, contains('addMinedSentence('));
    expect(
      src,
      contains('source: dictionarySourceType'),
      reason: 'mixin 制卡历史来源跟随 dictionarySourceType（book/video）',
    );
  });

  test('CollectionsPage 读 mined_sentences 并作独立「制卡句」分段展示 + 可删除', () {
    final String src = File(
      'lib/src/pages/implementations/collections_page.dart',
    ).readAsStringSync();
    expect(src, contains('_CollectionType.mined'), reason: '收藏夹应有独立的「制卡句」条目类型');
    expect(src, contains('getAllMinedSentences('), reason: '收藏夹应从 DB 读全部制卡历史');
    expect(src, contains('removeMinedSentence('), reason: '制卡历史条目应可按 id 删除');
    expect(src, contains('t.collection_mined'), reason: '制卡句条目应有自己的 i18n 标签');
  });
}
