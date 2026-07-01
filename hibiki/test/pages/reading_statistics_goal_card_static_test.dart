import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1046 守卫（static wiring）：统计页的日/周阅读目标卡片。
///
/// 该页需要完整 AppModel（DB + prefsRepo）初始化才能真装配，widget 装配成本高，
/// 因此按计划降级为源码 wiring 守卫（照 home_video_statistics_entry_static_test）。
/// 纯函数行为（封顶/关闭/达成）已由 test/pages/stat_goal_test.dart 直测；这里只坐实：
///   1) 目标卡 sliver 已接入 _buildContent（紧跟 summary cards）；
///   2) 两目标都 0 时 return SizedBox.shrink()（never-break 红线：零视觉变化）；
///   3) 进度条经纯函数 goalProgressFraction/goalReached 驱动，达成换 tertiary 色；
///   4) 编辑入口是 edit 图标按钮，写 pref 后 setState 即时刷新。
void main() {
  final File src =
      File('lib/src/pages/implementations/reading_statistics_page.dart');

  test('goal card sliver is wired right after the summary cards', () {
    final String text = src.readAsStringSync();
    expect(
      text.contains('SliverToBoxAdapter(child: _buildGoalPanel())'),
      isTrue,
      reason: '目标卡应作为独立 sliver 接入 _buildContent',
    );
    final int summaryIdx =
        text.indexOf('SliverToBoxAdapter(child: _buildSummaryCards())');
    final int goalIdx =
        text.indexOf('SliverToBoxAdapter(child: _buildGoalPanel())');
    expect(summaryIdx, greaterThanOrEqualTo(0));
    expect(goalIdx, greaterThan(summaryIdx),
        reason: '目标卡 sliver 应紧接在 summary cards 之后');
  });

  test('goal card hides entirely when both goals are 0 (never-break red line)',
      () {
    final String text = src.readAsStringSync();
    final int start = text.indexOf('Widget _buildGoalPanel()');
    expect(start, greaterThanOrEqualTo(0), reason: '应定义 _buildGoalPanel');
    final String body = text.substring(start, start + 400);
    expect(body.contains('dailyGoal <= 0 && weeklyGoal <= 0'), isTrue,
        reason: '两目标皆 0 才隐藏');
    expect(body.contains('return const SizedBox.shrink()'), isTrue,
        reason: '两目标皆 0 -> SizedBox.shrink()，默认零视觉变化');
  });

  test('goal row uses the pure fraction/reached helpers', () {
    final String text = src.readAsStringSync();
    // _buildGoalRow 是本文件唯一使用这些 goal 纯函数/文案的地方，用全文件 contains
    // 断言更稳（CJK 注释使窗口偏移不可靠）。
    expect(text.contains('Widget _buildGoalRow('), isTrue,
        reason: '应定义 _buildGoalRow');
    expect(text.contains('goalProgressFraction(read, goal)'), isTrue,
        reason: '进度条 value 应来自纯函数 goalProgressFraction');
    expect(text.contains('goalReached(read, goal)'), isTrue,
        reason: '达成判定应来自纯函数 goalReached');
    expect(text.contains('LinearProgressIndicator('), isTrue);
    expect(text.contains('colorScheme.tertiary'), isTrue,
        reason: '达成后进度条换 tertiary 色');
    expect(text.contains('t.stat_goal_reached'), isTrue,
        reason: '达成时展示 stat_goal_reached 文案');
    expect(
        text.contains('t.stat_goal_progress(read: read, goal: goal)'), isTrue,
        reason: '"已读 / 目标" 文案走带占位符 i18n key');
  });

  test('edit entry is an edit icon button that persists then setState', () {
    final String text = src.readAsStringSync();
    // 目标卡右上编辑入口。
    expect(text.contains('icon: Icons.edit'), isTrue,
        reason: '编辑入口应为 edit 图标按钮');
    expect(text.contains('onTap: _editGoals'), isTrue,
        reason: '编辑按钮应调 _editGoals');
    expect(text.contains('Future<void> _editGoals()'), isTrue,
        reason: '应定义 _editGoals');
    expect(text.contains('setReadingGoalDailyChars'), isTrue);
    expect(text.contains('setReadingGoalWeeklyChars'), isTrue);
    expect(text.contains('setState(() {})'), isTrue,
        reason: '写 pref 后 setState 即时刷新卡片');
  });
}
