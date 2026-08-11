import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'reader_fushi_page_source_corpus.dart';
import 'video_fushi_page_source_corpus.dart';

/// 源码守卫：制卡成功必须计入 `mining_statistics`（统计页「制卡 N」卡片的数据源）。
///
/// 历史 bug（TODO-047 part1）：唯一记账点是 [DictionaryPageMixin.recordMined]，但用户
/// 真正制卡的两条路径都各自绕过它——
///   - reader：`BaseSourcePageState.onMineFromPopup`（reader 覆写，**不 mixin
///     DictionaryPageMixin**，走独立体系，自带私有 `_recordMined`）；
///   - video：`_VideoFushiPageState` 覆写 `onMineEntry`。
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
///
/// 现状（P4 写侧收敛，a8439b2f45）：底层两表累加（`addMiningCount` /
/// `addMineCountPerBook`）被收编进 DB 复合入口 [FushiDatabase.recordMiningEvent]
/// （同事务齐写），页面层不再直调底层 DAO。本守卫的落地判据随之从
/// 「记账 helper 里出现 addMiningCount」改成「记账 helper 里出现 recordMiningEvent」。
///
/// 与 `test/tools/statistics_write_convergence_guard_test.dart` 的分工（两者都不可省）：
/// 那条 P4 守卫只问**文件级**「这个写点文件里出现过 recordMiningEvent 吗」，管的是
/// 「别再绕开复合入口散点直写」；本守卫管的是**接线**——记账调用必须落在记账 helper
/// 体内、必须由 `described.record`（== 成功）触发、来源必须对。把记账整段删掉、把
/// `if (described.record)` 这行删掉、或把来源写错，P4 守卫全都照绿。
void main() {
  test('reader onMineFromPopup 成功分支把制卡计入书籍统计', () {
    final String src = readReaderPageSource();
    // reader 经 describeMineOutcome 路由：record（== 成功）时调私有 _recordMined（不 mixin）。
    expect(containsIdentifierCall(src, 'describeMineOutcome'), isTrue,
        reason: 'reader 应经 describeMineOutcome 判定制卡结果');
    expect(
        containsCodeLine(
            src, 'if (described.record) unawaited(_recordMined());'),
        isTrue,
        reason: 'reader 成功（described.record）必须记账，否则统计页「制卡」恒为 0');
    // helper 缺失时 methodBody 直接 fail（不会静默返回空串再让下面的断言假绿）。
    final String recordBody =
        methodBody(src, 'Future<void> _recordMined() async {');
    expect(containsIdentifierCall(recordBody, 'recordMiningEvent'), isTrue,
        reason: 'reader 记账必须走 FushiDatabase.recordMiningEvent 复合入口'
            '（同事务写 mining_statistics + per-book），不得回到散点直调底层 DAO');
    expect(containsCodeLine(recordBody, 'sourceType: kStatSourceBook'), isTrue,
        reason: 'reader 记账来源应为书籍');
  });

  test('video onMineEntry 成功分支把制卡计入视频统计', () {
    // TODO-590 batch14: 制卡记账（describeMineOutcome / recordMined）已随
    // `_mineVideoCard` 搬进 lookup_mining.part.dart，读合并语料才能命中。
    final String src = readVideoFushiSource();
    // video mixin 了 DictionaryPageMixin，record 时调 protected recordMined()。
    // TODO-590 batch14: `_mineVideoCard` 搬进 extension 后不能直调 @protected，故经
    // 主壳 `_recordMinedForVideo()` 转发（纯 1 行委托，等价于直调 recordMined）；
    // 来源仍由 dictionarySourceType => kStatSourceVideo 决定。
    expect(containsIdentifierCall(src, 'describeMineOutcome'), isTrue,
        reason: 'video 应经 describeMineOutcome 判定制卡结果');
    expect(
        containsCodeLine(
            src, 'if (described.record) unawaited(_recordMinedForVideo());'),
        isTrue,
        reason: 'video 成功（described.record）必须记账，否则视频统计「制卡」恒为 0');
    // 主壳的 _recordMinedForVideo 必须是 recordMined 的纯转发器（不得吞掉记账）。
    expect(
        containsCodeLine(
            src, 'Future<void> _recordMinedForVideo() => recordMined();'),
        isTrue,
        reason: 'extension 经主壳转发器调 @protected recordMined，转发器不得改写语义');
    expect(
        containsCodeLine(
            src, 'String get dictionarySourceType => kStatSourceVideo'),
        isTrue,
        reason: 'video 记账来源应为视频');
  });

  test('mixin 暴露 protected recordMined（供 video 等覆写页调用）', () {
    final String src =
        File('lib/src/pages/implementations/dictionary_page_mixin.dart')
            .readAsStringSync();
    // 裸 `contains('@protected')` 只问「文件里有没有这个注解」——本文件里 @protected
    // 有一大把，recordMined 就算被改回 private 也照绿。这里钉的是**紧邻 recordMined
    // 签名的那一个**。
    const String signature = 'Future<void> recordMined() async {';
    final String masked = maskComments(src);
    final int signatureAt = masked.indexOf(signature);
    expect(signatureAt, greaterThanOrEqualTo(0),
        reason: 'mixin 必须自带 recordMined 记账 helper');
    expect(masked.substring(0, signatureAt).trimRight().endsWith('@protected'),
        isTrue,
        reason: 'recordMined 应是 protected 而非 private，子类覆写才能调');
    final String recordBody = methodBody(src, signature);
    expect(containsIdentifierCall(recordBody, 'recordMiningEvent'), isTrue,
        reason: 'mixin 记账必须走 FushiDatabase.recordMiningEvent 复合入口'
            '（同事务写 mining_statistics + per-book），不得回到散点直调底层 DAO');
    // 基类 onMineEntry 经 describeMineOutcome 路由，record 时记账（书内/独立查词页这条不回归）。
    expect(
        containsCodeLine(
            src, 'if (described.record) unawaited(recordMined());'),
        isTrue,
        reason: '基类成功分支记账不得丢');
  });

  test('stat_activity 暴露公开 statTodayKey（记账日期键的唯一权威实现）', () {
    final String src = File('lib/src/pages/implementations/stat_activity.dart')
        .readAsStringSync();
    expect(containsCodeLine(src, 'String statTodayKey() =>'), isTrue,
        reason: 'reader/mixin 记账共用同一个 today dateKey 实现，避免各写一遍');
    expect(containsCodeLine(src, 'String statDateKey(DateTime d) =>'), isTrue);
  });
}
