import 'dart:async';

import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show ProviderContainer, ProviderScope;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/study_goal_edit_sheet.dart';
import 'package:fushi/src/pages/implementations/study_goal_visuals.dart';
import 'package:fushi/src/platform/widget_snapshot.dart'
    show StudyGoalProgress, WidgetGoalsInput, computeStudyGoals;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/srs/srs_home_stats.dart'
    show SrsHomeStats, srsHomeStatsProvider;
import 'package:fushi/src/srs/srs_providers.dart'
    show srsMiningToReviewProvider;
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/stats/study_goal_groups.dart';
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi/src/stats/study_goals.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart'
    show AdaptiveSettingsRow;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_goal_language.dart';

/// 「目标」子页（「通用 › 学习计时」与 Android「主屏幕小组件」两处入口共用；设计 A
/// 「目标列表」，mockup 第一屏）。
///
/// 三块：
/// - 我的目标：按语言分组（中文 / 日本語 / … → 全部语言 → 不分语言，
///   [groupStudyGoals]），组头可折叠，组内可拖动 / 上移下移重排；每条目标一行
///   （行首小进度环、「阅读 — 1 小时 / 天」、进度数字），点开编辑面板；末行「添加目标」；
/// - 计数：文字单位（自动 / 字 / 词，全局）、一周从星期几开始；
/// - 「今日」格：主目标（从记录里选）与左右滑范围（只有每日目标 / 全部目标）。
///
/// 子页共用父分类 id（[SettingsDestinationId.general]）；闭包零参、只读 i18n 常量。
SettingsDestination buildStudyGoalsDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.general,
    title: t.settings_study_goals_title,
    summary: t.settings_study_goals_summary,
    icon: FushiIcons.flag,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'study_goals.section.list',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_study_goals_section_list,
        footer: t.settings_study_goals_list_hint,
        items: <SettingsItem>[
          SettingsCustomItem.rows(
            id: 'study_goals.list',
            searchTitle: t.settings_study_goals_section_list,
            searchKeywords: (SettingsContext c) => <String>[
              t.settings_study_goals_add,
              for (final StudyGoal g in c.appModel.studyGoals)
                studyGoalRowTitle(g, c.appModel.readingGoalTextUnit),
              for (final StudyGoalGroup group in groupStudyGoals(
                c.appModel.studyGoals,
              ))
                studyGoalGroupTitle(group),
            ],
            rowsBuilder: (SettingsContext c) => c.appModel.isPreferencesReady
                ? buildStudyGoalRows(c.context, c.appModel, c.refresh)
                : const <Widget>[],
          ),
        ],
      ),
      SettingsSection(
        id: 'study_goals.section.counting',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_study_goals_section_counting,
        items: <SettingsItem>[
          SettingsSegmentedItem<StudyGoalUnitChoice>(
            id: 'study_goals.text_unit',
            title: t.settings_study_goals_unit,
            subtitle: t.settings_study_goals_unit_hint,
            icon: FushiIcons.textFields,
            defaultValue: StudyGoalUnitChoice.auto,
            options: <SettingsSegmentOption<StudyGoalUnitChoice>>[
              SettingsSegmentOption<StudyGoalUnitChoice>(
                value: StudyGoalUnitChoice.auto,
                label: t.settings_study_goals_unit_auto,
              ),
              SettingsSegmentOption<StudyGoalUnitChoice>(
                value: StudyGoalUnitChoice.chars,
                label: t.widget_goal_chars,
              ),
              SettingsSegmentOption<StudyGoalUnitChoice>(
                value: StudyGoalUnitChoice.words,
                label: t.widget_goal_words,
              ),
            ],
            selected: (SettingsContext c) => c.appModel.readingGoalTextUnit,
            onChanged: (SettingsContext c, StudyGoalUnitChoice v) async {
              await c.appModel.setReadingGoalTextUnit(v);
              c.refresh();
            },
          ),
          _weekStartItem(),
        ],
      ),
      SettingsSection(
        id: 'study_goals.section.today',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_study_goals_section_today,
        footer: t.settings_study_goals_today_hint,
        items: <SettingsItem>[
          _todayLayoutItem(),
          _mainGoalItem(),
          _swipeItem(),
        ],
      ),
    ],
  );
}

/// 指向「目标」子页的一行（各入口 id 不同，子页本身只有一份）。
SettingsNavigationItem buildStudyGoalsNavigationItem(String id) {
  return SettingsNavigationItem(
    id: id,
    title: t.settings_study_goals_title,
    subtitle: t.settings_study_goals_summary,
    icon: FushiIcons.flag,
    child: buildStudyGoalsDestination,
  );
}

/// 一条目标的行标题：「阅读 — 1 小时 / 天」「字数 — 28,000 / 周」（目标值与周期用
/// 白话写在一起；语言由所在分组的组头给出）。
String studyGoalRowTitle(StudyGoal goal, StudyGoalUnitChoice unitChoice) {
  final String metric = studyGoalMetricLabel(
    goal.metric,
    unit: studyGoalUnitOf(goal, unitChoice),
  );
  final String target = studyGoalTargetLabel(goal);
  final String perPeriod = switch (goal.period) {
    StudyGoalPeriod.daily => t.study_goal_target_per_day(unit: target),
    StudyGoalPeriod.weekly => t.study_goal_target_per_week(unit: target),
    StudyGoalPeriod.monthly => t.study_goal_target_per_month(unit: target),
  };
  return t.settings_study_goals_row_title(metric: metric, target: perPeriod);
}

/// 行副标题里进度之外的说明：只算某种文字（「只算 简体中文」）、只在某几天生效
/// （「仅 周一, 周三」）。没有就是空列表。
List<String> studyGoalRowNotes(StudyGoal goal) {
  final List<String> out = <String>[];
  final String? language = goal.language;
  if (language != null && resolveStudyGoalLanguage(language)?.script != null) {
    out.add(
      t.study_goal_sheet_script_only(language: studyGoalLanguageName(language)),
    );
  }
  if (goal.activeWeekdays.isNotEmpty) {
    final List<int> days = goal.activeWeekdays.toList()..sort();
    out.add(
      t.settings_study_goals_row_active_days(
        days: days
            .map((int d) => studyGoalWeekdayName(d, short: true))
            .join(', '),
      ),
    );
  }
  return out;
}

/// 组头的名字：语言名 /「全部语言」/「不分语言」。
String studyGoalGroupTitle(StudyGoalGroup group) => switch (group.kind) {
  StudyGoalGroupKind.language => studyGoalLanguageName(group.language!),
  StudyGoalGroupKind.allLanguages => t.stat_goal_language_all,
  StudyGoalGroupKind.anyLanguage => t.settings_study_goals_no_language,
};

/// 「我的目标」分组的行：按语言分组（[groupStudyGoals]：各语言 → 全部语言 → 不分
/// 语言），每组一块（组头可折叠，组内可拖动 / 上移下移重排），末行「添加目标」。
/// 目标行整行 Enter / 点按 = 编辑；增删改与重排（含删除后的「撤销」）后 [refresh]。
List<Widget> buildStudyGoalRows(
  BuildContext context,
  AppModel appModel,
  VoidCallback refresh,
) {
  Future<void> open({StudyGoal? goal}) async {
    final StudyGoalSheetResult? result = await showStudyGoalEditSheet(
      context,
      appModel,
      goal: goal,
      onRestored: refresh,
    );
    if (result != null) refresh();
  }

  final StudyGoalSettingsProgress progress = StudyGoalSettingsProgress.of(
    context,
    appModel,
  );
  return <Widget>[
    for (final StudyGoalGroup group in groupStudyGoals(appModel.studyGoals))
      StudyGoalGroupBlock(
        key: ValueKey<String>('study-goal-group-${group.id}'),
        group: group,
        appModel: appModel,
        progress: progress,
        onOpen: (StudyGoal goal) => unawaited(open(goal: goal)),
        onReordered: refresh,
      ),
    AdaptiveSettingsRow(
      key: const ValueKey<String>('study-goal-add'),
      icon: FushiIcons.add,
      showIcon: true,
      title: t.settings_study_goals_add,
      onTap: () => unawaited(open()),
    ),
  ];
}

/// 一个语言分组：组头（语言色点、名字、目标数、折叠箭头；整行可聚焦，Enter 折叠 /
/// 展开）+ 组内目标行（[FushiReorderableColumn]：把手拖动；每行另有可聚焦的上移 /
/// 下移按钮与同名读屏动作，键盘 / 手柄可达）。
///
/// 折叠状态只记在内存里（本次运行内、按组 id），不进偏好：它只是看列表的方式。
class StudyGoalGroupBlock extends StatefulWidget {
  const StudyGoalGroupBlock({
    super.key,
    required this.group,
    required this.appModel,
    required this.progress,
    required this.onOpen,
    required this.onReordered,
  });

  final StudyGoalGroup group;
  final AppModel appModel;
  final StudyGoalSettingsProgress progress;
  final ValueChanged<StudyGoal> onOpen;
  final VoidCallback onReordered;

  /// 收起的组 id（进程内记忆；测试可清空）。
  @visibleForTesting
  static final Set<String> collapsedGroups = <String>{};

  @override
  State<StudyGoalGroupBlock> createState() => _StudyGoalGroupBlockState();
}

class _StudyGoalGroupBlockState extends State<StudyGoalGroupBlock> {
  /// 拖拽提交后、偏好落库前的乐观顺序（与「功能模块」排序列表同一做法）：
  /// FushiReorderableColumn 提交即复位，父级还按旧顺序重建时行会先弹回原位。
  List<StudyGoal>? _pending;

  bool get _collapsed =>
      StudyGoalGroupBlock.collapsedGroups.contains(widget.group.id);

  List<StudyGoal> get _goals => _pending ?? widget.group.goals;

  void _toggle() {
    setState(() {
      if (!StudyGoalGroupBlock.collapsedGroups.remove(widget.group.id)) {
        StudyGoalGroupBlock.collapsedGroups.add(widget.group.id);
      }
    });
  }

  Future<void> _reorder(int from, int to) async {
    final List<StudyGoal> goals = _goals;
    if (from == to || to < 0 || to >= goals.length) return;
    final List<String> ids = reorderStudyGoalsInGroup(
      allIds: <String>[
        for (final StudyGoal g in widget.appModel.studyGoals) g.id,
      ],
      groupIds: <String>[for (final StudyGoal g in goals) g.id],
      from: from,
      to: to,
    );
    final List<StudyGoal> moved = <StudyGoal>[...goals];
    moved.insert(to, moved.removeAt(from));
    setState(() => _pending = moved);
    try {
      await widget.appModel.reorderStudyGoals(ids);
    } finally {
      // 落库失败也清掉乐观顺序：列表回到偏好真值，不显示一个没存上的顺序。
      if (mounted) setState(() => _pending = null);
      widget.onReordered();
    }
  }

  /// 拖拽、上移下移按钮、读屏动作共用的提交入口；落库失败进全局错误日志。
  void _commit(int from, int to) {
    unawaited(
      _reorder(from, to).catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'settings',
            context: ErrorDescription('while saving the study goal order'),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final StudyGoalGroup group = widget.group;
    final String title = studyGoalGroupTitle(group);
    final List<StudyGoal> goals = _goals;
    final StudyGoalColors colors = studyGoalColorsOf(
      context,
      language: group.language,
      metric: group.kind == StudyGoalGroupKind.anyLanguage
          ? goals.first.metric
          : null,
    );
    final bool collapsed = _collapsed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          expanded: !collapsed,
          child: AdaptiveSettingsRow(
            key: ValueKey<String>('study-goal-group-toggle-${group.id}'),
            leading: SizedBox.square(
              dimension: 28,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.ring,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: 14),
                ),
              ),
            ),
            title: title,
            subtitle: goals.length == 1
                ? t.settings_study_goals_group_count_one(count: 1)
                : t.settings_study_goals_group_count(count: goals.length),
            subtitleMaxLines: 1,
            trailing: FushiIcon(
              collapsed ? FushiIcons.expandMore : FushiIcons.expandLess,
              semanticLabel: collapsed
                  ? t.settings_study_goals_group_expand(language: title)
                  : t.settings_study_goals_group_collapse(language: title),
            ),
            onTap: _toggle,
          ),
        ),
        FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: collapsed
              ? const SizedBox(width: double.infinity)
              : FushiReorderableColumn(
                  itemCount: goals.length,
                  useDragHandles: true,
                  keyForIndex: (int index) =>
                      ValueKey<String>('study-goal-reorder-${goals[index].id}'),
                  onReorder: _commit,
                  itemBuilder: (BuildContext context, int index) =>
                      _buildGoalRow(context, goals, index),
                ),
        ),
      ],
    );
  }

  Widget _buildGoalRow(BuildContext context, List<StudyGoal> goals, int index) {
    final StudyGoal goal = goals[index];
    final AppModel appModel = widget.appModel;
    final bool canUp = index > 0;
    final bool canDown = index < goals.length - 1;
    // 复习目标在首页不出现时（复习数只有内置复习给得出），行里写明原因。
    final StudyGoalReviewsHidden? reviewsHidden =
        goal.metric == StudyGoalId.reviews
        ? appModel.studyGoalReviewsHidden
        : null;
    return Semantics(
      key: ValueKey<String>('study-goal-row-semantics-${goal.id}'),
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        if (canUp)
          CustomSemanticsAction(label: t.move_up): () =>
              _commit(index, index - 1),
        if (canDown)
          CustomSemanticsAction(label: t.move_down): () =>
              _commit(index, index + 1),
      },
      child: ListenableBuilder(
        listenable: widget.progress,
        builder: (BuildContext context, Widget? _) {
          final StudyGoalProgress? p = widget.progress.progressOf(
            goal,
            context,
          );
          final String? value = p == null
              ? null
              : widget.progress.valueLabelOf(p);
          final List<String> lines = <String>[
            <String>[?value, ...studyGoalRowNotes(goal)].join(' · '),
            if (reviewsHidden != null)
              studyGoalReviewsHiddenNote(reviewsHidden),
          ].where((String s) => s.isNotEmpty).toList();
          return AdaptiveSettingsRow(
            key: ValueKey<String>('study-goal-row-${goal.id}'),
            icon: studyGoalMetricIcon(goal.metric),
            leading: _StudyGoalRowRing(
              goal: goal,
              progress: p,
              loaded: widget.progress.loaded,
            ),
            title: studyGoalRowTitle(goal, appModel.readingGoalTextUnit),
            subtitle: lines.isEmpty ? null : lines.join('\n'),
            subtitleMaxLines: reviewsHidden != null ? 4 : 2,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // 移不动的方向不画箭头（只占位、行尾对齐）：灰掉的箭头在墨水屏上
                // 和可用的一样黑，看不出是禁用的（2026-11-20 走查）。
                Visibility(
                  visible: canUp,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: FushiIconButton(
                    key: ValueKey<String>('study-goal-up-${goal.id}'),
                    icon: FushiIcons.expandLess,
                    size: 18,
                    tooltip: t.move_up,
                    enabled: canUp,
                    isWideTapArea: true,
                    onTap: () => _commit(index, index - 1),
                  ),
                ),
                // 移不动的方向不画箭头（只占位、行尾对齐）：灰掉的箭头在墨水屏上
                // 和可用的一样黑，看不出是禁用的（2026-11-20 走查）。
                Visibility(
                  visible: canDown,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: FushiIconButton(
                    key: ValueKey<String>('study-goal-down-${goal.id}'),
                    icon: FushiIcons.expandMore,
                    size: 18,
                    tooltip: t.move_down,
                    enabled: canDown,
                    isWideTapArea: true,
                    onTap: () => _commit(index, index + 1),
                  ),
                ),
                FushiReorderableDragHandle(
                  child: ExcludeSemantics(
                    child: FushiIcon(
                      FushiIcons.dragIndicator,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            onTap: () => widget.onOpen(goal),
          );
        },
      ),
    );
  }
}

/// 一周从星期几开始（周一 / 周日 / 周六）：每周目标、首页「今日」格与统计的「本周」
/// 共用（[StatWindow.weekStartDay]）。
SettingsSegmentedItem<int> _weekStartItem() {
  return SettingsSegmentedItem<int>(
    id: 'study_goals.week_start',
    title: t.settings_study_goals_week_start,
    subtitle: t.settings_study_goals_week_start_hint,
    icon: FushiIcons.calendar,
    defaultValue: DateTime.monday,
    options: <SettingsSegmentOption<int>>[
      SettingsSegmentOption<int>(
        value: DateTime.monday,
        label: t.settings_study_goals_week_monday,
      ),
      SettingsSegmentOption<int>(
        value: DateTime.sunday,
        label: t.settings_study_goals_week_sunday,
      ),
      SettingsSegmentOption<int>(
        value: DateTime.saturday,
        label: t.settings_study_goals_week_saturday,
      ),
    ],
    selected: (SettingsContext c) => c.appModel.statWeekStart,
    onChanged: (SettingsContext c, int day) async {
      await c.appModel.setStatWeekStart(day);
      c.refresh();
    },
  );
}

/// 「今日」格的版式：聚焦（一条目标大环 + 左右滑）/ 总览（全部目标列表）。
SettingsSegmentedItem<StudyGoalTodayLayout> _todayLayoutItem() {
  return SettingsSegmentedItem<StudyGoalTodayLayout>(
    id: 'study_goals.today_layout',
    title: t.settings_study_goals_today_layout,
    subtitle: t.settings_study_goals_today_layout_hint,
    icon: FushiIcons.viewAgenda,
    defaultValue: StudyGoalTodayLayout.focus,
    options: <SettingsSegmentOption<StudyGoalTodayLayout>>[
      SettingsSegmentOption<StudyGoalTodayLayout>(
        value: StudyGoalTodayLayout.focus,
        label: t.settings_study_goals_today_layout_focus,
      ),
      SettingsSegmentOption<StudyGoalTodayLayout>(
        value: StudyGoalTodayLayout.overview,
        label: t.settings_study_goals_today_layout_overview,
      ),
    ],
    selected: (SettingsContext c) => c.appModel.homeTodayLayout,
    onChanged: (SettingsContext c, StudyGoalTodayLayout v) async {
      await c.appModel.setHomeTodayLayout(v);
      c.refresh();
    },
  );
}

/// 主目标与左右滑只对聚焦版式有意义（总览列出全部目标）。
bool _todayFocusLayout(SettingsContext c) =>
    c.appModel.homeTodayLayout == StudyGoalTodayLayout.focus;

/// 「今日」格的主目标：从记录里选（存记录 id；'' = 第一个目标）。
SettingsSegmentedItem<String> _mainGoalItem() {
  return SettingsSegmentedItem<String>(
    id: 'study_goals.today_main',
    title: t.settings_study_goals_today_main,
    icon: FushiIcons.flag,
    dropdown: true,
    defaultValue: '',
    enabled: _todayFocusLayout,
    options: <SettingsSegmentOption<String>>[
      SettingsSegmentOption<String>(
        value: '',
        label: t.settings_study_goals_main_first,
      ),
    ],
    optionsBuilder: (SettingsContext c) {
      final StudyGoalUnitChoice unit = c.appModel.readingGoalTextUnit;
      return <SettingsSegmentOption<String>>[
        SettingsSegmentOption<String>(
          value: '',
          label: t.settings_study_goals_main_first,
        ),
        for (final StudyGoal g in c.appModel.studyGoals)
          SettingsSegmentOption<String>(
            value: g.id,
            label: studyGoalLabel(g, unitChoice: unit),
          ),
      ];
    },
    selected: (SettingsContext c) {
      final String id = c.appModel.homeTodayMainGoal;
      return c.appModel.studyGoals.any((StudyGoal g) => g.id == id) ? id : '';
    },
    onChanged: (SettingsContext c, String id) async {
      await c.appModel.setHomeTodayMainGoal(id);
      c.refresh();
    },
  );
}

/// 「今日」格左右滑显示哪些目标。
SettingsSegmentedItem<StudyGoalSwipeScope> _swipeItem() {
  return SettingsSegmentedItem<StudyGoalSwipeScope>(
    id: 'study_goals.today_swipe',
    title: t.settings_study_goals_swipe,
    subtitle: t.settings_study_goals_swipe_hint,
    icon: FushiIcons.swap,
    defaultValue: StudyGoalSwipeScope.daily,
    enabled: _todayFocusLayout,
    options: <SettingsSegmentOption<StudyGoalSwipeScope>>[
      SettingsSegmentOption<StudyGoalSwipeScope>(
        value: StudyGoalSwipeScope.daily,
        label: t.settings_study_goals_swipe_daily,
      ),
      SettingsSegmentOption<StudyGoalSwipeScope>(
        value: StudyGoalSwipeScope.all,
        label: t.settings_study_goals_swipe_all,
      ),
    ],
    selected: (SettingsContext c) => c.appModel.homeTodaySwipeGoals,
    onChanged: (SettingsContext c, StudyGoalSwipeScope v) async {
      await c.appModel.setHomeTodaySwipeGoals(v);
      c.refresh();
    },
  );
}

/// 设置 › 目标行首进度环的数据：统计日面、媒体语言表、制卡日表**每个页面只加载一次**
/// （挂在所在的设置详情页上，[of]），目标增删改后用同一份数据现算（与首页 / 小组件
/// 同一个纯函数 [computeStudyGoals]）。复习数读复习首页那份统计（内置 SRS 时才有）。
class StudyGoalSettingsProgress extends ChangeNotifier {
  StudyGoalSettingsProgress._(this._appModel) {
    unawaited(_load());
  }

  /// [context] 所在页面的那一份（同一页的各行共用；换页 / 重新进入重新加载）。
  static StudyGoalSettingsProgress of(BuildContext context, AppModel appModel) {
    final Object owner =
        context.findAncestorStateOfType<State<SettingsDetailPage>>() ??
        ModalRoute.of(context) ??
        appModel;
    return _byOwner[owner] ??= StudyGoalSettingsProgress._(appModel);
  }

  static final Expando<StudyGoalSettingsProgress> _byOwner =
      Expando<StudyGoalSettingsProgress>('study-goal-settings-progress');

  final AppModel _appModel;
  StatWindow? _window;
  List<StatFact> _daily = const <StatFact>[];
  Map<String, String> _media = const <String, String>{};
  Map<String, int> _mined = const <String, int>{};

  /// 上次算进度用的记录（编码后比较）与结果。
  String? _goalsKey;
  Map<String, StudyGoalProgress> _byId = const <String, StudyGoalProgress>{};

  bool get loaded => _window != null;

  Future<void> _load() async {
    final FushiDatabase db = _appModel.database;
    final StatWindow window = StatWindow(DateTime.now());
    final StatFacts facts = await loadStatFacts(db, activityLimit: 0);
    final Map<String, String> media = await loadStudyGoalMediaLanguages(db);
    final Map<String, int> mined = await loadStudyMinedByDay(db, window);
    _daily = facts.daily;
    _media = media;
    _mined = mined;
    _window = window;
    _goalsKey = null;
    notifyListeners();
  }

  /// [goal] 今天（它自己的周期窗口）的进度；还没加载完、或是复习目标但复习数不可得
  /// 时为 null。
  StudyGoalProgress? progressOf(StudyGoal goal, BuildContext context) {
    final StatWindow? window = _window;
    if (window == null) return null;
    final List<StudyGoal> goals = _appModel.studyGoals;
    // 周起始日也进键：改了「一周从星期几开始」，每周目标的窗口跟着变。
    final String key = '${StatWindow.weekStartDay}|${encodeStudyGoals(goals)}';
    if (key != _goalsKey) {
      _goalsKey = key;
      final WidgetGoalsInput input = buildStudyGoalsInput(
        prefs: _appModel.prefsRepo,
        goals: goals,
        mediaLanguages: _media,
        daily: _daily,
        window: window,
        minedByDay: _mined,
      );
      _byId = <String, StudyGoalProgress>{
        for (final StudyGoalProgress p in computeStudyGoals(
          goals: input,
          immersion: buildStudyImmersionInput(_daily, window),
          day: window.todayKey,
          reviewsByDay: _reviewsByDay(context, window),
        ))
          p.goal.id: p,
      };
    }
    return _byId[goal.id];
  }

  /// 一条进度的副标题文案：「3.2K / 28K · 400 left」，周 / 月目标再接今天的份额
  /// 「· 12 / 20 today」（与主屏幕小组件同一个紧凑
  /// 格式化：单位已在行标题里，这里不重复；精度足以区分 9,950 与 10K）。
  String valueLabelOf(StudyGoalProgress p) {
    final ({String value, String target}) pair = studyGoalCompactPair(
      p.value,
      p.target,
      isTime: p.id.isTime,
    );
    final String base =
        '${pair.value} / ${pair.target} · ${studyGoalStatusLabel(p)}';
    // 周 / 月目标再带今天的份额：「… · 12 / 20 today」（休息日 / 本周已完成）。
    return p.splitsPeriod ? '$base · ${studyGoalTodayText(p).short}' : base;
  }

  Map<String, int>? _reviewsByDay(BuildContext context, StatWindow window) {
    final ProviderContainer container = ProviderScope.containerOf(
      context,
      listen: false,
    );
    if (!studyGoalsUseBuiltInSrs(
      _appModel.prefsRepo,
      miningToReview: container.read(srsMiningToReviewProvider),
    )) {
      return null;
    }
    final SrsHomeStats? stats = container.read(srsHomeStatsProvider).value;
    if (stats == null) return null;
    return studyReviewsByDateKey(
      countsByDay: stats.countsByDay,
      today: stats.today,
      doneToday: stats.doneToday,
      window: window,
    );
  }
}

/// 目标行首的小进度环（语言色，不抢标题：不写百分比，百分比进读屏标签；数字进度
/// 在副标题）；进度不可得（复习数没有）时是度量图标。
class _StudyGoalRowRing extends StatelessWidget {
  const _StudyGoalRowRing({
    required this.goal,
    required this.progress,
    required this.loaded,
  });

  final StudyGoal goal;
  final StudyGoalProgress? progress;
  final bool loaded;

  static const double _size = 28;

  @override
  Widget build(BuildContext context) {
    final StudyGoalColors colors = studyGoalColorsOf(
      context,
      language: goal.language,
      metric: goal.metric,
    );
    final StudyGoalProgress? p = progress;
    if (p == null && loaded) {
      return SizedBox.square(
        dimension: _size,
        child: Center(
          child: FushiIcon(
            studyGoalMetricIcon(goal.metric),
            size: 20,
            color: colors.ring,
          ),
        ),
      );
    }
    return Semantics(
      key: ValueKey<String>('study-goal-row-ring-${goal.id}'),
      label: p == null ? null : '${p.percent}% · ${studyGoalStatusLabel(p)}',
      child: StudyGoalRing(
        fraction: p?.fraction ?? 0,
        state: p?.state,
        color: colors.ring,
        track: colors.track,
        size: _size,
        showPercent: false,
      ),
    );
  }
}
