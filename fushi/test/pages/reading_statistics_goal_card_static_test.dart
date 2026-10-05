import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// TODO-1046 守卫（static wiring）：统计页的日/周阅读目标。
///
/// 该页需要完整 AppModel（DB + prefsRepo）初始化才能真装配，widget 装配成本高，
/// 因此按计划降级为源码 wiring 守卫（照 home_video_statistics_entry_static_test）。
/// 纯函数行为（封顶/关闭/达成）已由 test/pages/stat_goal_test.dart 直测，目标面板
/// 的渲染由 test/pages/stat_overview_test.dart 直测；这里只坐实：
///   1) 2026-10 统计中心重设计后目标是关键指标区的 lead（共享 [StatGoalPanel]，
///      与总览同一个组件），喂日 / 周两个目标与学习域分子（BUG-1993）；
///   2) 两目标都 0 时面板显示「设定目标」引导而不是整块消失（总览同款）；
///   3) 周进度条经纯函数 goalProgressFraction/goalReached 驱动，达成换 reached 色；
///   4) 整张面板可点进目标编辑，写 pref 后 setState 即时刷新。
void main() {
  final File src =
      File('lib/src/pages/implementations/reading_statistics_page.dart');
  final File dashboard =
      File('lib/src/pages/implementations/stat_dashboard.dart');

  test('goal panel is the hero lead, fed both goals and study-domain numerators',
      () {
    final String content =
        methodBody(src.readAsStringSync(), 'Widget _buildContent()');
    final int hero = content.indexOf('StatHero(');
    final int goal = content.indexOf('lead: StatGoalPanel(');
    expect(hero, greaterThanOrEqualTo(0), reason: '阅读页应有关键指标区');
    expect(goal, greaterThan(hero), reason: '目标面板是指标区的 lead');
    for (final String arg in <String>[
      'goalChars: appModelNoUpdate.readingGoalDailyChars',
      'progressChars: _todayStudyChars',
      'weeklyGoalChars: appModelNoUpdate.readingGoalWeeklyChars',
      'weeklyProgressChars: _weekStudyChars',
      '_editGoals',
    ]) {
      expect(content.contains(arg), isTrue, reason: '目标面板缺 $arg');
    }
  });

  test('both goals 0 shows the set-goal guide instead of hiding', () {
    final String text = dashboard.readAsStringSync();
    final int start = text.indexOf('class StatGoalPanel extends StatelessWidget');
    final int end = text.indexOf('class _StatWeeklyGoalBar', start);
    expect(start, greaterThanOrEqualTo(0));
    final String panel = text.substring(start, end);
    expect(panel.contains('goalChars <= 0 && weeklyGoalChars <= 0'), isTrue,
        reason: '两目标皆 0 才进引导态');
    expect(panel.contains('t.stat_overview_goal_unset'), isTrue);
    expect(panel.contains('onTap: onTap'), isTrue, reason: '整卡可点进目标编辑');
  });

  test('weekly bar uses the pure fraction/reached helpers', () {
    final String text = dashboard.readAsStringSync();
    expect(text.contains('goalProgressFraction(read, goal)'), isTrue,
        reason: '进度条 value 应来自纯函数 goalProgressFraction');
    expect(text.contains('goalReached(read, goal)'), isTrue,
        reason: '达成判定应来自纯函数 goalReached');
    expect(text.contains('LinearProgressIndicator('), isTrue);
    expect(text.contains('reached ? colors.reached : colors.series'), isTrue,
        reason: '达成后换「达成」色');
    final String shared =
        File('lib/src/pages/implementations/stat_shared.dart')
            .readAsStringSync();
    expect(shared.contains('reached: scheme.tertiary,'), isTrue,
        reason: '达成色在 MD3 下是 tertiary');
    expect(text.contains('t.stat_goal_reached'), isTrue,
        reason: '达成时展示 stat_goal_reached 文案');
    expect(text.contains('t.stat_goal_progress(read: read, goal: goal)'), isTrue,
        reason: '"已读 / 目标" 文案走带占位符 i18n key');
  });

  test('edit goals persists via the shared dialog then setState', () {
    final String text = src.readAsStringSync();
    expect(text.contains('Future<void> _editGoals()'), isTrue,
        reason: '应定义 _editGoals');
    final String editGoals = methodBody(text, 'Future<void> _editGoals()');
    expect(editGoals.contains('showStatGoalEditDialog(context'), isTrue,
        reason: '_editGoals 应调统计页共享目标对话框');
    expect(editGoals.contains('setState(() {})'), isTrue,
        reason: '保存后 setState 即时刷新面板');
  });

  test('shared goal dialog is the single place that persists both goals', () {
    final String text =
        File('lib/src/pages/implementations/stat_shared.dart')
            .readAsStringSync();
    final String dialog =
        methodBody(text, 'Future<bool> showStatGoalEditDialog(');
    expect(dialog.contains('setReadingGoalDailyChars'), isTrue,
        reason: '共享目标对话框应写穿每日目标');
    expect(dialog.contains('setReadingGoalWeeklyChars'), isTrue,
        reason: '共享目标对话框应写穿每周目标');
  });

  test('BUG-970: goal-set entry lives in the page top bar, always reachable',
      () {
    final String text = src.readAsStringSync();
    // 目标入口必须常驻页面顶栏 actions（目标面板只在内容区，加载 / 出错时不在），
    // 否则从未设过目标的用户可能无法首次设置。守卫：
    //   1) 顶栏有 flag 图标按钮，onTap 直接调 _editGoals；
    //   2) 该按钮位于 scaffold actions（在 body: 之前）；
    //   3) 顶栏入口不被任何 dailyGoal/weeklyGoal 条件包裹（恒可见）。
    // 窗口是承重结构，不是装饰：`tooltip: t.stat_goal_set` / `onTap: _editGoals`
    // 在目标卡内的 edit 按钮处也逐字存在，全文件级 contains 分辨不出顶栏与卡内。
    // 统计中心大改造把顶栏动作从 `FushiPageScaffold(actions: <Widget>[...])` 内联
    // 提升成局部变量 `actions`（供独立页与嵌入 tab 两条路径共用），旧的两个字面量
    // 锚点双双失效：`actions: <Widget>[` 全文件仅剩 _editGoals 弹窗那处（会把窗口
    // 静默开在弹窗上），`body: buildStatPageBody(` 彻底消失。改为先用 methodBody 把
    // 窗口框死在 State.build 内，再取语义唯一的局部变量声明作起点。
    final String build = methodBody(text, 'Widget build(BuildContext context)');
    final int actionsIdx =
        build.indexOf('final List<Widget> actions = <Widget>[');
    expect(actionsIdx, greaterThanOrEqualTo(0), reason: '页面应有顶栏 actions 列表');
    final int bodyIdx =
        build.indexOf('final Widget body = buildStatPageBody(', actionsIdx);
    expect(bodyIdx, greaterThan(actionsIdx), reason: '应能定位 actions 与 body 边界');

    final String actionsRegion =
        maskComments(build.substring(actionsIdx, bodyIdx));
    expect(actionsRegion.contains('icon: Icons.flag_outlined'), isTrue,
        reason: '顶栏应有 flag 目标设置图标按钮');
    expect(actionsRegion.contains('onTap: _editGoals'), isTrue,
        reason: '顶栏目标按钮应直接调 _editGoals');
    expect(actionsRegion.contains('tooltip: t.stat_goal_set'), isTrue,
        reason: '顶栏目标按钮复用 stat_goal_set 文案');
    // 恒可见：顶栏 actions 区域内不得出现目标数值的门控条件。
    expect(actionsRegion.contains('dailyGoal'), isFalse,
        reason: '顶栏目标入口不得被 dailyGoal 条件门控');
    expect(actionsRegion.contains('weeklyGoal'), isFalse,
        reason: '顶栏目标入口不得被 weeklyGoal 条件门控');

    // 统计中心大改造引入了 embedded 分叉：同一份 actions 必须喂给两条渲染路径，
    // 否则统计中心 tab 里这个唯一的首次设置入口会静默丢失。
    expect(
      containsCodeLine(build, 'buildEmbeddedStatTab(context, actions, body)'),
      isTrue,
      reason: '统计中心 tab 嵌入态必须渲染同一份 actions',
    );
    expect(
      containsCodeLine(build, 'actions: actions,'),
      isTrue,
      reason: '独立页 scaffold 必须渲染同一份 actions',
    );
  });
}
