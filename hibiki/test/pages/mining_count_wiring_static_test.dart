import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：制卡成功必须计入 `mining_statistics`（统计页「制卡 N」卡片的数据源）。
///
/// 历史 bug（TODO-047 part1）：唯一记账点是 [DictionaryPageMixin._recordMined]
/// （经 `onMineEntry` 成功分支触发），但用户真正制卡的两条路径都各自绕过它——
///   - reader：`BaseSourcePageState.onMineFromPopup`（reader 覆写，**不 mixin
///     DictionaryPageMixin**，走独立体系），成功分支只弹 toast；
///   - video：`_VideoHibikiPageState` 覆写 `onMineEntry`，成功分支只弹 OSD。
/// 于是 `mining_statistics` 永远 0 行。
///
/// 现有 `favorite_button_wiring_static_test.dart` 只断言 mixin 文件里存在
/// `addMiningCount(` 字符串，照不到这两条覆写路径。本守卫补盲区：断言 **reader 的
/// onMineFromPopup 成功分支 + video 的 onMineEntry 成功分支** 各自的 `MineResult.success`
/// case 块内都调用了记账（撤掉任一条修复，对应断言即红）。
///
/// 这两条路径的页面（reader WebView / video media_kit）在 headless 无法实例化，
/// 真制卡又依赖真 Anki，端到端行为测试不可落地，故用结构化源码守卫。
void main() {
  /// 从 [src] 里抽出从 `case MineResult.success:` 起、到下一个 `case ` 之前的代码块。
  /// 用于断言「记账调用确实在成功分支内」，而不是文件里任意位置出现一次即过。
  String successCaseBody(String src) {
    final int start = src.indexOf('case MineResult.success:');
    expect(start, greaterThanOrEqualTo(0), reason: '应存在 MineResult.success 分支');
    final int next = src.indexOf('case MineResult.', start + 1);
    expect(next, greaterThan(start), reason: '成功分支后应还有其它 case');
    return src.substring(start, next);
  }

  test('reader onMineFromPopup 成功分支把制卡计入书籍统计', () {
    final String src =
        File('lib/src/pages/implementations/reader_hibiki_page.dart')
            .readAsStringSync();
    // reader 自带私有 _recordMined（不 mixin），按 book 来源调 addMiningCount。
    final String body = successCaseBody(src);
    expect(body, contains('_recordMined()'),
        reason: 'reader 成功制卡必须记账，否则统计页「制卡」恒为 0');
    // 记账实现：固定 book 来源 + addMiningCount。
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
    final String body = successCaseBody(src);
    // video mixin 了 DictionaryPageMixin，直接调 protected recordMined()，
    // 来源由 dictionarySourceType => kStatSourceVideo 决定。
    expect(body, contains('recordMined()'),
        reason: 'video 成功制卡必须记账，否则视频统计「制卡」恒为 0');
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
    // 基类 onMineEntry 成功分支仍调记账（书内/独立查词页这条路径不回归）。
    expect(src, contains('unawaited(recordMined());'), reason: '基类成功分支记账不得丢');
  });

  test('stat_activity 暴露公开 statTodayKey（记账日期键的唯一权威实现）', () {
    final String src = File('lib/src/pages/implementations/stat_activity.dart')
        .readAsStringSync();
    expect(src, contains('String statTodayKey() =>'),
        reason: 'reader/mixin 记账共用同一个 today dateKey 实现，避免各写一遍');
    expect(src, contains('String statDateKey(DateTime d) =>'));
  });
}
