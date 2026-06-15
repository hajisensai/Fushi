import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：制卡成功必须计入 `mining_statistics`（统计页「制卡 N」卡片的数据源）。
///
/// 历史 bug（TODO-047 part1）：唯一记账点是 [DictionaryPageMixin.recordMined]，但用户
/// 真正制卡的两条路径都各自绕过它——
///   - reader：`BaseSourcePageState.onMineFromPopup`（reader 覆写，**不 mixin
///     DictionaryPageMixin**，走独立体系，自带私有 `_recordMined`）；
///   - video：`_VideoHibikiPageState` 覆写 `onMineEntry`。
/// 于是 `mining_statistics` 永远 0 行。
///
/// 现状（架构整理阶段0 Task4）：四分支 outcome→消息/成功/记账 映射收口为
/// [describeMineOutcome]，各页只决定怎么展示 + 是否记账。记账判据从「在
/// `case MineResult.success:` 块内调记账」变成「`if (described.record)` 时调记账」
/// （`described.record` 仅 success 为 true，语义等价）。本守卫断言 reader/video 都经
/// describeMineOutcome 判定、并在 record 时记账（撤掉任一条修复对应断言即红）。
///
/// 这两条路径的页面（reader WebView / video media_kit）在 headless 无法实例化，
/// 真制卡又依赖真 Anki，端到端行为测试不可落地，故用结构化源码守卫。
void main() {
  test('reader onMineFromPopup 成功分支把制卡计入书籍统计', () {
    final String src =
        File('lib/src/pages/implementations/reader_hibiki_page.dart')
            .readAsStringSync();
    // reader 经 describeMineOutcome 路由：record（== 成功）时调私有 _recordMined（不 mixin）。
    expect(src, contains('describeMineOutcome('),
        reason: 'reader 应经 describeMineOutcome 判定制卡结果');
    expect(src, contains('if (described.record) unawaited(_recordMined());'),
        reason: 'reader 成功（described.record）必须记账，否则统计页「制卡」恒为 0');
    expect(src, contains('Future<void> _recordMined() async {'),
        reason: 'reader 应自带记账 helper（不 mixin DictionaryPageMixin）');
    expect(src, contains('addMiningCount('));
    expect(src, contains('sourceType: kStatSourceBook'),
        reason: 'reader 记账来源应为书籍');
  });

  test('video onMineEntry 成功分支把制卡计入视频统计', () {
    final String src =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();
    // video mixin 了 DictionaryPageMixin，record 时调 protected recordMined()，
    // 来源由 dictionarySourceType => kStatSourceVideo 决定。
    expect(src, contains('describeMineOutcome('),
        reason: 'video 应经 describeMineOutcome 判定制卡结果');
    expect(src, contains('if (described.record) unawaited(recordMined());'),
        reason: 'video 成功（described.record）必须记账，否则视频统计「制卡」恒为 0');
    expect(src, contains('String get dictionarySourceType => kStatSourceVideo'),
        reason: 'video 记账来源应为视频');
  });

  test('mixin 暴露 protected recordMined（供 video 等覆写页调用）', () {
    final String src =
        File('lib/src/pages/implementations/dictionary_page_mixin.dart')
            .readAsStringSync();
    expect(src, contains('@protected'),
        reason: 'recordMined 应是 protected 而非 private，子类覆写才能调');
    expect(src, contains('Future<void> recordMined() async {'));
    expect(src, contains('addMiningCount('));
    // 基类 onMineEntry 经 describeMineOutcome 路由，record 时记账（书内/独立查词页这条不回归）。
    expect(src, contains('if (described.record) unawaited(recordMined());'),
        reason: '基类成功分支记账不得丢');
  });

  test('stat_activity 暴露公开 statTodayKey（记账日期键的唯一权威实现）', () {
    final String src = File('lib/src/pages/implementations/stat_activity.dart')
        .readAsStringSync();
    expect(src, contains('String statTodayKey() =>'),
        reason: 'reader/mixin 记账共用同一个 today dateKey 实现，避免各写一遍');
    expect(src, contains('String statDateKey(DateTime d) =>'));
  });
}
