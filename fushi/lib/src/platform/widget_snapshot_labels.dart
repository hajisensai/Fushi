import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatTime;
import 'package:fushi/src/platform/widget_snapshot.dart';

/// 小组件快照的全部文案，按 app 内语言（当前 slang locale）取。键集合与含义见
/// [kWidgetLabelKeys]；这里是唯一把 i18n key 映射到快照 label 键的地方。
///
/// 模板键（`streakDays` / `updatedAgo` / `agoMinutes` / `agoHours` / `agoDays`）
/// 里的 `{n}` / `{age}` 原样保留给原生侧在显示时刻替换。
WidgetSnapshotLabels buildWidgetLabels() {
  const String n = '{n}';
  return WidgetSnapshotLabels(<String, String>{
    // v1
    'kind_book': t.books,
    'kind_manga': t.manga_library,
    'kind_video': t.nav_video,
    'resume': t.home_continue,
    'today': t.stat_today,
    'streak': t.stat_streak,
    'srsDue': t.srs_count_review,
    'srsOff': t.widget_label_srs_off,
    'review': t.home_srs_panel_start,
    'srsDone': t.home_srs_panel_done,
    'recent': t.widget_label_recent,
    'weekly': t.stat_this_week,
    'books': t.books,
    'manga': t.manga_library,
    'video': t.nav_video,
    'lookup': t.nav_lookup,
    'openToSetUp': t.widget_label_open_to_set_up,
    // 沉浸看板
    'dashboardTitle': t.widget_label_dashboard_title,
    'reading': t.widget_label_reading,
    'listening': t.widget_label_listening,
    'watching': t.widget_label_watching,
    'games': t.widget_label_games,
    'goal': t.widget_label_goal,
    'ofGoal': t.widget_label_of_goal,
    'streakDays': t.widget_label_streak_days(n: n),
    'longest': t.widget_label_longest_streak,
    'vsLastWeek': t.widget_label_vs_last_week,
    'thisMonth': t.stat_this_month,
    'activeDays': t.widget_label_active_days,
    // 复习
    'providerFushi': t.widget_label_provider_fushi,
    'providerAnki': t.widget_label_provider_anki,
    'srsNew': t.srs_count_new,
    'srsLearn': t.srs_count_learn,
    'reviewedToday': t.widget_label_reviewed_today,
    'dueTomorrow': t.widget_label_due_tomorrow,
    'reviewNow': t.widget_label_review_now,
    'openAnki': t.widget_label_open_anki,
    'allCaughtUp': t.widget_label_all_caught_up,
    'srsSetup': t.widget_label_srs_setup,
    'ankiPermission': t.widget_label_anki_permission,
    // 词汇 / 目标 / 快捷入口
    'vocabTitle': t.widget_label_vocab_title,
    'nextWord': t.widget_label_next_word,
    'lookUp': t.widget_label_look_up,
    'noVocab': t.widget_label_no_vocab,
    'goalsTitle': t.widget_label_goals_title,
    'noGoals': t.widget_label_no_goals,
    'vocab': t.widget_label_vocabulary,
    'stats': t.widget_label_statistics,
    'settings': t.settings,
    // 更新时间
    'updatedAgo': t.widget_label_updated_ago(age: '{age}'),
    'openToRefresh': t.widget_label_open_to_refresh,
    'agoNow': t.activity_just_now,
    'agoMinutes': t.activity_minutes_ago(n: n),
    'agoHours': t.activity_hours_ago(n: n),
    'agoDays': t.activity_days_ago(n: n),
    'zeroTime': formatStatTime(0),
    'streakSrs': t.widget_label_srs_streak,
    'weekReviews': t.widget_label_week_reviews,
    'weekGoalDays': t.widget_label_goal_days,
    'recentDays': t.widget_label_last_days(n: kWidgetMonthDays),
  });
}

/// `today.categories[].label`。
Map<WidgetImmersionCategory, String> buildWidgetCategoryLabels() =>
    <WidgetImmersionCategory, String>{
      WidgetImmersionCategory.reading: t.widget_label_reading,
      WidgetImmersionCategory.listening: t.widget_label_listening,
      WidgetImmersionCategory.watching: t.widget_label_watching,
      WidgetImmersionCategory.games: t.widget_label_games,
    };

/// `goals[].label`，键是目标 id（`total|reading|listening|watching|reviews|mined|chars`）。
Map<String, String> buildWidgetGoalLabels() => <String, String>{
  'total': t.widget_goal_total,
  'reading': t.widget_label_reading,
  'listening': t.widget_label_listening,
  'watching': t.widget_label_watching,
  'reviews': t.widget_goal_reviews,
  'mined': t.widget_goal_mined,
  'chars': t.widget_goal_chars,
};
