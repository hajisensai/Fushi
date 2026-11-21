/// 学习目标的**装配**：把目标记录、统计事实、制卡 / 复习日表拼成 [WidgetGoalsInput]，
/// 再交给 [computeStudyGoals]（纯函数，`widget_snapshot.dart`）算进度；外加目标的
/// 标签 / 数值文案。
///
/// Android「目标」小组件、首页「今日」格与「语言目标」格都走这里——同一批记录、
/// 同一套分子，几处数字恒相等。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart' show SrsMiningTarget;
import 'package:fushi/src/pages/implementations/stat_charts.dart'
    show formatStatCharsAxis, statMyriadUnit;
import 'package:fushi/src/stats/stat_format.dart'
    show formatStatTime, formatStatWords;
import 'package:fushi/src/platform/widget_snapshot.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/stats/study_goal_language_scope.dart';
import 'package:fushi/src/stats/study_goal_record.dart'
    show StudyGoalReviewsHidden;
import 'package:fushi/src/utils/components/content_language_picker.dart'
    show contentLanguageLabelOf;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_goal_language.dart';

/// 统计日面 → 沉浸输入（各类别每日毫秒、每日字数、活跃日）。热力图窗口外的日子
/// 只进活跃日（连续天数要全部历史）。
WidgetImmersionInput buildStudyImmersionInput(
  Iterable<StatFact> daily,
  StatWindow window,
) {
  final String oldestKept = window.lastDayKeys(kWidgetHeatmapDays).first;
  final Map<String, Map<WidgetImmersionCategory, int>> msByDay =
      <String, Map<WidgetImmersionCategory, int>>{};
  final Map<String, int> charsByDay = <String, int>{};
  final Set<String> activeDays = <String>{};
  for (final StatFact f in daily) {
    final WidgetImmersionCategory? category =
        WidgetImmersionCategory.fromMediaKind(f.mediaKind);
    if (category == null) continue;
    if (f.ms > 0 || f.chars > 0 || f.pages > 0) activeDays.add(f.dateKey);
    if (f.dateKey.compareTo(oldestKept) < 0) continue;
    final Map<WidgetImmersionCategory, int> day = msByDay.putIfAbsent(
      f.dateKey,
      () => <WidgetImmersionCategory, int>{},
    );
    day[category] = (day[category] ?? 0) + f.ms;
    charsByDay[f.dateKey] = (charsByDay[f.dateKey] ?? 0) + f.chars;
  }
  return WidgetImmersionInput(
    msByDay: msByDay,
    charsByDay: charsByDay,
    activeDays: activeDays,
  );
}

/// 最近 [kWidgetMonthDays] 天每天制了多少张卡（统计口径：`mining_statistics` 按
/// (来源, 统计日) 聚合，行很少）。够月目标的窗口。
Future<Map<String, int>> loadStudyMinedByDay(
  FushiDatabase db,
  StatWindow window,
) async {
  final String oldest = window.lastDayKeys(kWidgetMonthDays).first;
  final Map<String, int> out = <String, int>{};
  for (final MiningStatisticRow m in await db.getAllMiningStatistics()) {
    if (m.dateKey.compareTo(oldest) < 0) continue;
    out[m.dateKey] = (out[m.dateKey] ?? 0) + m.count;
  }
  return out;
}

/// 复习是否走内置 SRS（只有这时才有复习数；Anki 的 API 没有）。
bool studyGoalsUseBuiltInSrs(
  PreferencesRepository prefs, {
  required bool miningToReview,
}) =>
    SrsMiningTarget.fromWire(prefs.srsMiningTarget) != SrsMiningTarget.anki &&
    miningToReview;

/// 内置 SRS 首页统计的「日序号 → 复习数」换成统计日 key 的日表（[today] 是 SRS 的
/// 今日序号，对到 [window] 的今日；SRS 有自己的日界，这里按天对齐）。
Map<String, int> studyReviewsByDateKey({
  required Map<int, int> countsByDay,
  required int today,
  required int doneToday,
  required StatWindow window,
}) {
  final Map<String, int> out = <String, int>{};
  countsByDay.forEach((int index, int count) {
    final int ago = today - index;
    if (ago < 0 || ago >= kWidgetMonthDays) return;
    out[FushiDatabase.statDateKeyPlusDays(window.todayKey, -ago)] = count;
  });
  out[window.todayKey] = doneToday;
  return out;
}

/// 记录 + 统计 → 目标输入。限定了语言的目标按 [StudyGoalLanguageScope.includes]
/// 过滤日面，各语言另算一份沉浸量（[WidgetGoalsInput.languageImmersion]）。
WidgetGoalsInput buildStudyGoalsInput({
  required PreferencesRepository prefs,
  required List<StudyGoal> goals,
  required Map<String, String> mediaLanguages,
  required Iterable<StatFact> daily,
  required StatWindow window,
  required Map<String, int> minedByDay,
}) {
  final StudyGoalUnitChoice unitChoice = prefs.readingGoalTextUnit;
  return WidgetGoalsInput(
    goals: goals,
    languageImmersion: <String, WidgetImmersionInput>{
      for (final String language in <String>{
        for (final StudyGoal g in goals)
          if (g.language != null) g.language!,
      })
        language: buildStudyImmersionInput(
          daily.where(
            studyGoalScopeFor(
              language,
              prefs,
              mediaLanguages: mediaLanguages,
            ).includes,
          ),
          window,
        ),
    },
    minedByDay: minedByDay,
    unitChoice: unitChoice,
    labelOf: (StudyGoal g, {required bool restDay}) =>
        studyGoalShortLabel(g, unitChoice: unitChoice, restDay: restDay),
    formatWords: formatStatWords,
    compactOf: (StudyGoalProgress g) =>
        studyGoalCompactText(g, unitChoice: unitChoice),
  );
}

// ---------------------------------------------------------------------------
// 紧凑外显（系统小组件 / 设置行共用）：数值对不重复单位，精度够分辨，状态一句话。
// ---------------------------------------------------------------------------

/// 数量的紧凑写法（目标外显用）：千进制「14.8K」「1.2M」，CJK 界面万进制「1.48万」；
/// 不到一千（万进制不到一万）写满位数带分组（「950」「9,950」）。小数保留至多
/// [decimals] 位、去掉尾零。默认**向下截断**：没完成的量不会被四舍五入成目标
/// （9,960 / 10K 写「9.9K」而不是「10K」）；[roundUp] 向上取整，给「还差」用（不会
/// 显示「还差 0」）。小数点固定写「.」（与统计页的紧凑数字一致）。
String formatStudyGoalCount(
  int n, {
  int decimals = 1,
  bool roundUp = false,
  String? languageTag,
}) {
  final String tag = languageTag ?? LocaleSettings.currentLocale.languageTag;
  final int value = n < 0 ? 0 : n;
  final String? myriad = statMyriadUnit(tag);
  final (int scale, String suffix) = switch (value) {
    _ when myriad != null => value >= 10000 ? (10000, myriad) : (1, ''),
    >= 1000000 => (1000000, 'M'),
    >= 1000 => (1000, 'K'),
    _ => (1, ''),
  };
  if (scale == 1) return NumberFormat.decimalPattern(tag).format(value);
  int places = decimals.clamp(0, 3);
  int step = scale;
  for (int i = 0; i < places; i++) {
    step ~/= 10;
  }
  if (step < 1) {
    step = 1;
    places = 0;
  }
  final int units = roundUp ? (value + step - 1) ~/ step : value ~/ step;
  int pow10 = 1;
  for (int i = 0; i < places; i++) {
    pow10 *= 10;
  }
  final String whole = (units ~/ pow10).toString();
  String fraction = places == 0
      ? ''
      : (units % pow10).toString().padLeft(places, '0');
  while (fraction.endsWith('0')) {
    fraction = fraction.substring(0, fraction.length - 1);
  }
  return fraction.isEmpty ? '$whole$suffix' : '$whole.$fraction$suffix';
}

/// 时长的紧凑写法：「1h 36m」「1h」「36m」（各语言的「时 / 分」缩写取统计轴的
/// i18n）。默认按分钟**向下截断**；[roundUp] 向上取整到分钟（「还差」用）。
String formatStudyGoalDuration(int ms, {bool roundUp = false}) {
  final int safe = ms < 0 ? 0 : ms;
  final int minutes = roundUp ? (safe + 59999) ~/ 60000 : safe ~/ 60000;
  final int h = minutes ~/ 60;
  final int m = minutes % 60;
  if (h == 0) return t.stat_axis_minutes(n: m);
  if (m == 0) return t.stat_axis_hours(n: h);
  return '${t.stat_axis_hours(n: h)} ${t.stat_axis_minutes(n: m)}';
}

/// 「已完成 / 目标」两个数的紧凑写法，**不带单位**（单位在度量名里）：
/// 「14.8K / 10K」「1h 36m / 30m」「3.6K / 4K」。两数不同却写成一样时自动加精度
/// （10,040 / 10,000 → 「10.04K / 10K」），三位小数仍分不开就写满位数。
/// [isTime]：两数是毫秒。
({String value, String target}) studyGoalCompactPair(
  int value,
  int target, {
  required bool isTime,
  String? languageTag,
}) {
  if (isTime) {
    return (
      value: formatStudyGoalDuration(value),
      target: formatStudyGoalDuration(target),
    );
  }
  for (int decimals = 1; decimals <= 3; decimals++) {
    final String v = formatStudyGoalCount(
      value,
      decimals: decimals,
      languageTag: languageTag,
    );
    final String g = formatStudyGoalCount(
      target,
      decimals: decimals,
      languageTag: languageTag,
    );
    if (value == target || v != g) return (value: v, target: g);
  }
  final NumberFormat full = NumberFormat.decimalPattern(
    languageTag ?? LocaleSettings.currentLocale.languageTag,
  );
  return (value: full.format(value), target: full.format(target));
}

/// 一条进度的状态短句：「已完成」/「还差 400」/「+4.8K」/「休息日」（没开始也是
/// 「还差 …」）。超出量显示成 0（不到一分钟 / 截断后为 0）时写「已完成」。
String studyGoalStatusLabel(StudyGoalProgress g, {String? languageTag}) {
  final bool time = g.id.isTime;
  String amount(int n, {bool roundUp = false}) => time
      ? formatStudyGoalDuration(n, roundUp: roundUp)
      : formatStudyGoalCount(n, roundUp: roundUp, languageTag: languageTag);
  switch (g.state) {
    case StudyGoalState.restDay:
      return t.study_goal_status_rest_day;
    case StudyGoalState.completed:
      return t.study_goal_status_completed;
    case StudyGoalState.exceeded:
      final int shown = time ? g.excess ~/ 60000 : g.excess;
      return shown <= 0
          ? t.study_goal_status_completed
          : '+${amount(g.excess)}';
    case StudyGoalState.notStarted:
    case StudyGoalState.inProgress:
      return t.study_goal_status_left(
        amount: amount(g.remaining, roundUp: true),
      );
  }
}

/// 一条进度的全部紧凑文案（[StudyGoalCompactText]）：系统小组件的格子与设置行共用。
StudyGoalCompactText studyGoalCompactText(
  StudyGoalProgress g, {
  required StudyGoalUnitChoice unitChoice,
  String? languageTag,
}) {
  final StudyGoal goal = g.goal;
  final String metric = studyGoalMetricLabel(
    goal.metric,
    unit: studyGoalUnitOf(goal, unitChoice),
  );
  final String period = goal.period == StudyGoalPeriod.daily
      ? ''
      : studyGoalPeriodShortLabel(goal.period);
  final ({String value, String target}) pair = studyGoalCompactPair(
    g.value,
    g.target,
    isTime: g.id.isTime,
    languageTag: languageTag,
  );
  final int remaining = g.remaining;
  final StudyGoalTodayText? today = g.splitsPeriod
      ? studyGoalTodayText(g, languageTag: languageTag)
      : null;
  return StudyGoalCompactText(
    language: goal.metric.languageScoped
        ? studyGoalLanguageLabel(goal.language)
        : '',
    metric: metric,
    period: period,
    caption: period.isEmpty ? metric : '$metric · $period',
    value: pair.value,
    target: pair.target,
    status: studyGoalStatusLabel(g, languageTag: languageTag),
    remaining: remaining <= 0
        ? ''
        : g.id.isTime
        ? formatStudyGoalDuration(remaining, roundUp: true)
        : formatStudyGoalCount(
            remaining,
            roundUp: true,
            languageTag: languageTag,
          ),
    todayValue: today?.value ?? '',
    todayShare: today?.share ?? '',
    todayLine: today?.line ?? '',
    todayShort: today?.short ?? '',
    periodLine: today?.periodLine ?? '',
    pace: today?.pace ?? '',
    daysLeft: today?.daysLeft ?? '',
  );
}

/// 周 / 月目标「今日份额」的文案（[studyGoalTodayText]）。
typedef StudyGoalTodayText = ({
  String value,
  String share,
  String line,
  String short,
  String periodLine,
  String pace,
  String daysLeft,
});

/// 周 / 月目标的「今天」文案：今日量 / 份额的紧凑对、「今天」一行（份额 · 进度差；
/// 休息日 / 周期已达成换成状态）、周期一行（「本周 99 / 100 · 还剩 3 天」）、进度差、
/// 剩余生效日。进度差在目标 5% 以内写「进度正常」（[StudyGoalProgress.paceStatus]）。
StudyGoalTodayText studyGoalTodayText(
  StudyGoalProgress g, {
  String? languageTag,
}) {
  final bool time = g.id.isTime;
  String amount(int n) => time
      ? formatStudyGoalDuration(n, roundUp: true)
      : formatStudyGoalCount(n, roundUp: true, languageTag: languageTag);
  final ({String value, String target}) today = studyGoalCompactPair(
    g.todayValue,
    g.todayShare,
    isTime: time,
    languageTag: languageTag,
  );
  final ({String value, String target}) period = studyGoalCompactPair(
    g.value,
    g.target,
    isTime: time,
    languageTag: languageTag,
  );
  final String pace = switch (g.paceStatus) {
    StudyGoalPace.onTrack => t.study_goal_pace_on_track,
    StudyGoalPace.behind => t.study_goal_pace_behind(amount: amount(-g.pace)),
    StudyGoalPace.ahead => t.study_goal_pace_ahead(amount: amount(g.pace)),
  };
  final String daysLeft = g.periodDaysLeft == 1
      ? t.study_goal_days_left_one
      : t.study_goal_days_left(n: g.periodDaysLeft);
  final bool weekly = g.goal.period == StudyGoalPeriod.weekly;
  final String done = weekly
      ? t.study_goal_status_week_done
      : t.study_goal_status_month_done;
  final String pair = '${period.value} / ${period.target}';
  final String periodPair = weekly
      ? t.study_goal_period_week_pair(pair: pair)
      : t.study_goal_period_month_pair(pair: pair);
  final String todayPair = t.study_goal_today_pair(
    pair: '${today.value} / ${today.target}',
  );
  // 不带进度差的短写法（环下 / 设置行的小字）。
  final String short = g.periodReached
      ? done
      : g.todayRest
      ? t.study_goal_status_rest_day
      : todayPair;
  final String line;
  if (g.periodReached) {
    line = done;
  } else if (g.todayRest) {
    line = '${t.study_goal_status_rest_day} · $pace';
  } else {
    line = '$todayPair · $pace';
  }
  return (
    value: today.value,
    share: today.target,
    line: line,
    short: short,
    periodLine: g.periodReached || g.periodDaysLeft <= 0
        ? periodPair
        : '$periodPair · $daysLeft',
    pace: pace,
    daysLeft: daysLeft,
  );
}

/// [goal] 的文字单位。
StudyGoalUnit studyGoalUnitOf(StudyGoal goal, StudyGoalUnitChoice choice) =>
    choice.fixed ?? studyGoalUnitFor(goal.language);

/// 度量名（「字数」「学习时长」「复习」…）。文字目标按单位叫「字数」或「词数」。
String studyGoalMetricLabel(
  StudyGoalId metric, {
  StudyGoalUnit unit = StudyGoalUnit.chars,
}) => switch (metric) {
  StudyGoalId.total => t.widget_settings_goal_total,
  StudyGoalId.reading => t.widget_label_reading,
  StudyGoalId.listening => t.widget_label_listening,
  StudyGoalId.watching => t.widget_label_watching,
  StudyGoalId.reviews => t.widget_goal_reviews,
  StudyGoalId.mined => t.widget_goal_mined,
  StudyGoalId.chars => switch (unit) {
    StudyGoalUnit.chars => t.widget_goal_chars,
    StudyGoalUnit.words => t.widget_goal_words,
  },
};

/// 度量的短名（「语言目标」格同一周期有几条目标时的环下标签：「字数」「听力」…）。
String studyGoalMetricShortLabel(
  StudyGoalId metric, {
  StudyGoalUnit unit = StudyGoalUnit.chars,
}) => switch (metric) {
  StudyGoalId.total => t.study_goal_metric_short_total,
  StudyGoalId.reading => t.widget_label_reading,
  StudyGoalId.listening => t.widget_label_listening,
  StudyGoalId.watching => t.widget_label_watching,
  StudyGoalId.reviews => t.widget_goal_reviews,
  StudyGoalId.mined => t.study_goal_metric_short_mined,
  StudyGoalId.chars => switch (unit) {
    StudyGoalUnit.chars => t.study_goal_metric_short_chars,
    StudyGoalUnit.words => t.widget_goal_words,
  },
};

/// 复习目标在首页上不出现时的说明（设置 › 目标的行、目标面板选「复习」时）。
String studyGoalReviewsHiddenNote(StudyGoalReviewsHidden reason) =>
    switch (reason) {
      StudyGoalReviewsHidden.srsModuleOff =>
        t.study_goal_reviews_hidden_srs_off,
      StudyGoalReviewsHidden.cardsGoToAnki => t.study_goal_reviews_hidden_anki,
    };

/// 一条目标的标签：「<语言> · <度量>[本周 / 本月]」（全部语言不写语言），休息日再带
/// 「休息日」后缀。小组件、首页、设置共用。
String studyGoalLabel(
  StudyGoal goal, {
  required StudyGoalUnitChoice unitChoice,
  bool restDay = false,
}) {
  final String metric = studyGoalMetricLabel(
    goal.metric,
    unit: studyGoalUnitOf(goal, unitChoice),
  );
  final String periodic = switch (goal.period) {
    StudyGoalPeriod.daily => metric,
    StudyGoalPeriod.weekly => t.study_goal_label_weekly(metric: metric),
    StudyGoalPeriod.monthly => t.study_goal_label_monthly(metric: metric),
  };
  final String? language = goal.language;
  final String label = language == null
      ? periodic
      : '${studyGoalLanguageName(language)} · $periodic';
  return restDay ? t.study_goal_label_rest_day(label: label) : label;
}

/// 系统小组件里的短标签：「<语言> · <度量短名>[ / 周 | / 月]」（「日本語 · Chars / wk」
/// 「Listening / mo」），休息日照样带后缀。小组件格子窄，长标签会被截断。
String studyGoalShortLabel(
  StudyGoal goal, {
  required StudyGoalUnitChoice unitChoice,
  bool restDay = false,
}) {
  final String metric = studyGoalMetricShortLabel(
    goal.metric,
    unit: studyGoalUnitOf(goal, unitChoice),
  );
  final String periodic = switch (goal.period) {
    StudyGoalPeriod.daily => metric,
    StudyGoalPeriod.weekly => t.study_goal_label_short_weekly(metric: metric),
    StudyGoalPeriod.monthly => t.study_goal_label_short_monthly(metric: metric),
  };
  final String? language = goal.language;
  final String label = language == null
      ? periodic
      : '${studyGoalLanguageName(language)} · $periodic';
  return restDay ? t.study_goal_label_rest_day(label: label) : label;
}

/// 周期名（「每日」「每周」「每月」）。
String studyGoalPeriodLabel(StudyGoalPeriod period) => switch (period) {
  StudyGoalPeriod.daily => t.stat_goal_period_daily,
  StudyGoalPeriod.weekly => t.stat_goal_period_weekly,
  StudyGoalPeriod.monthly => t.stat_goal_period_monthly,
};

/// 周期的短名（「日」「周」「月」，「语言目标」格的环下标签）。
String studyGoalPeriodShortLabel(StudyGoalPeriod period) => switch (period) {
  StudyGoalPeriod.daily => t.study_goal_period_short_daily,
  StudyGoalPeriod.weekly => t.study_goal_period_short_weekly,
  StudyGoalPeriod.monthly => t.study_goal_period_short_monthly,
};

/// 周期的缩写（「周」「月」；英文 Wk / Mo），跟在度量短名后面：「字数 · 周」。
String studyGoalPeriodAbbrLabel(StudyGoalPeriod period) => switch (period) {
  StudyGoalPeriod.daily => t.study_goal_period_abbr_daily,
  StudyGoalPeriod.weekly => t.study_goal_period_abbr_weekly,
  StudyGoalPeriod.monthly => t.study_goal_period_abbr_monthly,
};

/// 语言名；null = 「全部语言」。
String studyGoalLanguageLabel(String? language) => language == null
    ? t.stat_goal_language_all
    : studyGoalLanguageName(language);

/// 目标里的语言名：内容语言名去掉末尾的「(标签)」（「日本語 (ja)」→「日本語」，
/// mockup 的写法）；不认识的标签原样返回。
String studyGoalLanguageName(String tag) {
  final String label = contentLanguageLabelOf(tag);
  final String suffix = ' ($tag)';
  return label.endsWith(suffix)
      ? label.substring(0, label.length - suffix.length)
      : label;
}

/// 目标时长的外显：整小时不写「0 分钟」（「1 小时」「10 小时」「1 小时 30 分钟」）。
String studyGoalDurationLabel(int ms) {
  final int minutes = ms ~/ 60000;
  if (minutes >= 60 && minutes % 60 == 0) {
    return t.stat_format_hours(n: minutes ~/ 60);
  }
  return formatStatTime(ms);
}

/// 目标值的外显（「10,000」「1 小时」「150」），设置行标题用。时长目标存分钟；数量
/// 写满位数（mockup「Characters · 10,000」）。
String studyGoalTargetLabel(StudyGoal goal) {
  if (goal.metric.isTime) return studyGoalDurationLabel(goal.target * 60000);
  return NumberFormat.decimalPattern(
    LocaleSettings.currentLocale.languageTag,
  ).format(goal.target);
}

/// 数量的单位文案（「字」「词」「张」；时长为 null，[formatStatTime] 自带单位）。
String? studyGoalUnitLabel(StudyGoalId metric, StudyGoalUnit unit) {
  if (metric.isTime) return null;
  if (metric == StudyGoalId.chars) {
    return switch (unit) {
      StudyGoalUnit.chars => t.stat_goal_unit_chars,
      StudyGoalUnit.words => t.stat_goal_unit_words,
    };
  }
  return t.widget_settings_unit_cards;
}

/// 一个目标的进度文案「已完成 / 目标」。数量类单位只写一次（「4,200 / 5,000 字」），
/// 窄格里也放得下。
String studyGoalValueLabel(StudyGoalProgress g, WidgetGoalsInput input) {
  if (g.id.isTime) {
    return '${formatStatTime(g.value)} / ${formatStatTime(g.target)}';
  }
  final String? unit = g.id == StudyGoalId.chars
      ? studyGoalUnitLabel(g.id, input.unitOf(g.goal))
      : null;
  final String core =
      '${formatStatCharsAxis(g.value)} / ${formatStatCharsAxis(g.target)}';
  return unit == null ? core : '$core $unit';
}

/// 一个目标「已完成」的大字与单位：数量 = 紧凑数字 + 单位；时长 = 「1 小时 5 分」整串、
/// 无单位。
({String value, String? unit}) studyGoalFigure(
  StudyGoalProgress g,
  WidgetGoalsInput input,
) {
  if (g.id.isTime) return (value: formatStatTime(g.value), unit: null);
  return (
    value: formatStatCharsAxis(g.value),
    unit: studyGoalUnitLabel(g.id, input.unitOf(g.goal)),
  );
}

/// 近 [days] 天（含今天）平均每天的量，口径与目标分子相同（时长 = 毫秒、字数），
/// 按 [language] 过滤：添加 / 编辑目标面板的「近 7 天」参考。复习 / 制卡没有日面
/// 数据，返回 null。
int? studyGoalRecentDailyAverage({
  required StudyGoalId metric,
  required String? language,
  required PreferencesRepository prefs,
  required Iterable<StatFact> daily,
  required Map<String, String> mediaLanguages,
  required StatWindow window,
  int days = 7,
}) {
  if (!metric.languageScoped) return null;
  final StudyGoalLanguageScope scope = studyGoalScopeFor(
    language,
    prefs,
    mediaLanguages: mediaLanguages,
  );
  final Set<String> keys = window.lastDayKeys(days).toSet();
  int total = 0;
  for (final StatFact f in daily) {
    if (!keys.contains(f.dateKey) || !scope.includes(f)) continue;
    final WidgetImmersionCategory? category =
        WidgetImmersionCategory.fromMediaKind(f.mediaKind);
    if (category == null) continue;
    total += switch (metric) {
      StudyGoalId.chars => f.chars,
      StudyGoalId.total => f.ms,
      StudyGoalId.reading =>
        category == WidgetImmersionCategory.reading ? f.ms : 0,
      StudyGoalId.listening =>
        category == WidgetImmersionCategory.listening ? f.ms : 0,
      StudyGoalId.watching =>
        category == WidgetImmersionCategory.watching ? f.ms : 0,
      StudyGoalId.reviews || StudyGoalId.mined => 0,
    };
  }
  return total ~/ days;
}

/// 目标值的快捷预设（时长 = 分钟，其余 = 条数 / 字数），按度量 × 周期 × 语言 / 单位：
/// - 字数：日 / 周用 [studyGoalDailyPresetsFor] / [studyGoalWeeklyPresetsFor]（按语言
///   与单位的量级），月 = 日 × 30；
/// - 时长：日 15 分 / 30 分 / 1 时 / 2 时，周 2 / 5 / 10 / 15 时，月 10 / 20 / 40 / 60 时；
/// - 复习 / 制卡：日一档，周 × 7、月 × 30。
List<int> studyGoalPresetsFor(
  StudyGoalId metric,
  StudyGoalPeriod period, {
  String? language,
  StudyGoalUnit? unit,
}) {
  List<int> scaled(List<int> daily) => switch (period) {
    StudyGoalPeriod.daily => daily,
    StudyGoalPeriod.weekly => <int>[for (final int d in daily) d * 7],
    StudyGoalPeriod.monthly => <int>[for (final int d in daily) d * 30],
  };
  return switch (metric) {
    StudyGoalId.chars => switch (period) {
      StudyGoalPeriod.weekly => studyGoalWeeklyPresetsFor(language, unit: unit),
      _ => scaled(studyGoalDailyPresetsFor(language, unit: unit)),
    },
    StudyGoalId.total ||
    StudyGoalId.reading ||
    StudyGoalId.listening ||
    StudyGoalId.watching => switch (period) {
      StudyGoalPeriod.daily => const <int>[15, 30, 60, 120],
      StudyGoalPeriod.weekly => const <int>[120, 300, 600, 900],
      StudyGoalPeriod.monthly => const <int>[600, 1200, 2400, 3600],
    },
    StudyGoalId.reviews => scaled(const <int>[50, 100, 150, 200]),
    StudyGoalId.mined => scaled(const <int>[5, 10, 20, 30]),
  };
}

/// 一条进度的标签（[studyGoalLabel]，休息日带后缀）。
String studyGoalProgressLabel(StudyGoalProgress g, WidgetGoalsInput input) =>
    input.labelOf?.call(g.goal, restDay: g.restDay) ??
    studyGoalLabel(g.goal, unitChoice: input.unitChoice, restDay: g.restDay);

/// 统计页「今天」卡字数环用哪条目标：全部语言的每日字数目标 → 任一每日字数目标 →
/// 任一字数目标；没有字数目标为 null。
StudyGoal? studyGoalStatsCharsGoal(Iterable<StudyGoal> goals) {
  StudyGoal? firstWhere(bool Function(StudyGoal g) test) {
    for (final StudyGoal g in goals) {
      if (test(g)) return g;
    }
    return null;
  }

  bool chars(StudyGoal g) => g.metric == StudyGoalId.chars;
  bool daily(StudyGoal g) => chars(g) && g.period == StudyGoalPeriod.daily;
  return firstWhere((StudyGoal g) => daily(g) && g.language == null) ??
      firstWhere(daily) ??
      firstWhere(chars);
}

/// 「语言目标」格里的一个环位：[progress] 为 null 时是空环（这一周期没有目标）。
class StudyGoalRingSlot {
  const StudyGoalRingSlot({
    required this.key,
    required this.caption,
    this.progress,
  });

  /// 稳定键：按周期排时是周期 wire（`daily` / `weekly` / `monthly`），按目标排时是
  /// 目标 id。
  final String key;

  /// 环下标签。
  final String caption;
  final StudyGoalProgress? progress;
}

/// 「语言目标」格最多几个环。
const int kStudyGoalRingSlots = 3;

/// 一种语言的目标 → 「语言目标」格的环（用户 2026-11 拍板）：
/// - 每个周期至多一条目标：固定「日 / 周 / 月」三环，没有目标的周期是空环 +「—」；
/// - 某个周期有几条目标：一条目标一个环（每日 → 每周 → 每月，同周期按列表顺序，
///   最多 [kStudyGoalRingSlots] 个），环下是度量短名（「字数」「听力」）；显示的环
///   跨了周期时再带周期缩写（「字数 · 周」），每个环都不会认错。
List<StudyGoalRingSlot> studyGoalRingSlots(
  List<StudyGoalProgress> goals,
  WidgetGoalsInput input,
) {
  final List<StudyGoalProgress> ordered = studyGoalProgressByPeriod(goals);
  final Map<StudyGoalPeriod, int> perPeriod = <StudyGoalPeriod, int>{};
  for (final StudyGoalProgress g in ordered) {
    perPeriod.update(g.goal.period, (int n) => n + 1, ifAbsent: () => 1);
  }
  if (perPeriod.values.every((int n) => n <= 1)) {
    return <StudyGoalRingSlot>[
      for (final StudyGoalPeriod period in StudyGoalPeriod.values)
        () {
          final StudyGoalProgress? g = ordered
              .where((StudyGoalProgress p) => p.goal.period == period)
              .firstOrNull;
          return StudyGoalRingSlot(
            key: period.wire,
            caption: g == null ? '—' : studyGoalPeriodShortLabel(period),
            progress: g,
          );
        }(),
    ];
  }
  final List<StudyGoalProgress> shown = ordered
      .take(kStudyGoalRingSlots)
      .toList();
  final bool onePeriod =
      shown.map((StudyGoalProgress g) => g.goal.period).toSet().length == 1;
  return <StudyGoalRingSlot>[
    for (final StudyGoalProgress g in shown)
      () {
        final String metric = studyGoalMetricShortLabel(
          g.goal.metric,
          unit: input.unitOf(g.goal),
        );
        return StudyGoalRingSlot(
          key: g.goal.id,
          caption: onePeriod
              ? metric
              : '$metric · ${studyGoalPeriodAbbrLabel(g.goal.period)}',
          progress: g,
        );
      }(),
  ];
}

/// 「语言目标」格用户挑的目标（[ids] 是记录 id，按挑的顺序）：删掉的记录静默跳过，
/// 至多 [kStudyGoalRingSlots] 条。空 = 一条都不剩（调用方回到自动挑）。
List<StudyGoalProgress> studyGoalPickedProgress(
  Iterable<StudyGoalProgress> all,
  List<String> ids,
) {
  final Map<String, StudyGoalProgress> byId = <String, StudyGoalProgress>{
    for (final StudyGoalProgress g in all) g.goal.id: g,
  };
  return <StudyGoalProgress>[
    for (final String id in ids)
      if (byId[id] case final StudyGoalProgress g) g,
  ].take(kStudyGoalRingSlots).toList();
}

/// 用户挑的目标的环位：照挑的顺序一条一环；环下写度量短名，周期不全相同时带周期
/// 缩写（「字数 · 周」），语言不全相同时前面带语言名（「中文 · 字数」）。
List<StudyGoalRingSlot> studyGoalPickedRingSlots(
  List<StudyGoalProgress> picked,
  WidgetGoalsInput input,
) {
  final bool onePeriod =
      picked.map((StudyGoalProgress g) => g.goal.period).toSet().length <= 1;
  final bool oneLanguage =
      picked.map((StudyGoalProgress g) => g.goal.language).toSet().length <= 1;
  return <StudyGoalRingSlot>[
    for (final StudyGoalProgress g in picked)
      () {
        String caption = studyGoalMetricShortLabel(
          g.goal.metric,
          unit: input.unitOf(g.goal),
        );
        if (!onePeriod) {
          caption = '$caption · ${studyGoalPeriodAbbrLabel(g.goal.period)}';
        }
        if (!oneLanguage) {
          caption = '${studyGoalLanguageLabel(g.goal.language)} · $caption';
        }
        return StudyGoalRingSlot(key: g.goal.id, caption: caption, progress: g);
      }(),
  ];
}

/// 一组目标共同的语言：都相同返回 `(language: 它)`（null = 全部语言）；不全相同
/// 返回 null（「语言目标」格标题改成「目标」）。
({String? language})? studyGoalsSharedLanguage(
  Iterable<StudyGoalProgress> goals,
) {
  final Set<String?> languages = <String?>{
    for (final StudyGoalProgress g in goals) g.goal.language,
  };
  return languages.length == 1 ? (language: languages.single) : null;
}

/// 进度按周期排：每日 → 每周 → 每月，同周期保持原顺序（稳定）。
List<StudyGoalProgress> studyGoalProgressByPeriod(
  Iterable<StudyGoalProgress> goals,
) {
  final List<StudyGoalProgress> list = goals.toList();
  final List<int> order = <int>[for (int i = 0; i < list.length; i++) i]
    ..sort((int a, int b) {
      final int byPeriod = list[a].goal.period.index.compareTo(
        list[b].goal.period.index,
      );
      return byPeriod != 0 ? byPeriod : a.compareTo(b);
    });
  return <StudyGoalProgress>[for (final int i in order) list[i]];
}
