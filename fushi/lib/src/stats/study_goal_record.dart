/// 学习目标的**记录**（设计 A「目标列表」，2026-11）：每个目标是一条记录——
/// 算什么（[StudyGoal.metric]）、多久一次（[StudyGoal.period]）、多少
/// （[StudyGoal.target]）、哪种语言（[StudyGoal.language]，null = 全部语言）、
/// 在哪几天生效（[StudyGoal.activeWeekdays]；周 / 月目标按生效日摊「今日份额」）。
///
/// 持久化：偏好 `study_goals`（随 Profile）存 JSON 数组
/// `[{"id":"…","metric":"chars","period":"daily","target":10000,"language":"ja","days":[1,2,3,4,5]}]`。
/// 键缺失 = 用户还没编辑过目标列表，渲染时由旧的逐项目标偏好现算
/// （[migrateLegacyStudyGoals]，不落盘），与首页小组件布局同一套迁移思路。
///
/// 语言带文字（`zh-Hans`）的记录只算那种文字的内容，存盘时带 `"scriptExact":true`。
/// 没有这个标记的旧记录（只按主语言匹配的时期写的，`zh-Hans` 当时也算繁体）解析时
/// 归一成整门语言（`zh`），意思不变；下次用户保存目标列表时才写回。
///
/// 纯 Dart：不碰 Flutter、不读偏好。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:fushi/src/stats/study_goal_period.dart';
import 'package:fushi/src/stats/study_goal_slots.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/stats/study_goal_language.dart'
    show
        StudyGoalLanguage,
        resolveStudyGoalLanguage,
        studyGoalCombinedLanguageTag;

export 'package:fushi/src/stats/study_goal_period.dart';
export 'package:fushi/src/stats/study_goal_slots.dart';

/// 目标值上限（防误输入）：分钟 = 一个月的分钟数；条数 / 字数 = 一亿。
const int kStudyGoalMaxMinutes = 31 * 24 * 60;
const int kStudyGoalMaxCount = 100000000;

/// 一个学习目标。不可变；编辑走 [copyWith] 再整条替换。
class StudyGoal {
  StudyGoal({
    required this.id,
    required this.metric,
    required this.period,
    required int target,
    String? language,
    Set<int> activeWeekdays = const <int>{},
  }) : target = target.clamp(
         1,
         metric.isTime ? kStudyGoalMaxMinutes : kStudyGoalMaxCount,
       ),
       // 复习 / 制卡不分语言；空串与空白一律当「全部语言」。
       language = metric.languageScoped && (language?.trim() ?? '').isNotEmpty
           ? language!.trim()
           : null,
       // 全选 = 每天（存成空集，避免两种写法）。每日目标：不生效的日子是休息日；
       // 周 / 月目标：周期目标摊到这些日子上（「今日份额」，`computeStudyGoals`）。
       activeWeekdays = _normalizeWeekdays(activeWeekdays);

  /// 稳定 id（新建时 [newStudyGoalId]；迁移出来的是 `legacy-<metric>`）。首页「今日」
  /// 格的主目标偏好存它。
  final String id;
  final StudyGoalId metric;
  final StudyGoalPeriod period;

  /// 时长类（[StudyGoalId.isTime]）是分钟，其余是条数 / 字数。恒 >= 1。
  final int target;

  /// BCP-47 语言标签；null = 全部语言。复习 / 制卡恒为 null。
  final String? language;

  /// ISO 星期（1 = 周一 … 7 = 周日）；空 = 每天。
  final Set<int> activeWeekdays;

  /// 这一天（dateKey）是不是生效日（没限定生效日 = 每天都是）。
  bool isActiveOn(String dateKey) =>
      activeWeekdays.isEmpty ||
      activeWeekdays.contains(FushiDatabase.statDateKeyToDay(dateKey).weekday);

  /// 这一天（dateKey）是不是休息日：限定了生效日、且这天不在其中。每日目标的休息日
  /// 不算欠着；周 / 月目标的休息日今日份额为 0。
  bool isRestDay(String dateKey) => !isActiveOn(dateKey);

  StudyGoal copyWith({
    StudyGoalId? metric,
    StudyGoalPeriod? period,
    int? target,
    String? Function()? language,
    Set<int>? activeWeekdays,
  }) => StudyGoal(
    id: id,
    metric: metric ?? this.metric,
    period: period ?? this.period,
    target: target ?? this.target,
    language: language == null ? this.language : language(),
    activeWeekdays: activeWeekdays ?? this.activeWeekdays,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'metric': metric.wire,
    'period': period.wire,
    'target': target,
    'language': ?language,
    if (resolveStudyGoalLanguage(language)?.script != null) 'scriptExact': true,
    if (activeWeekdays.isNotEmpty) 'days': (activeWeekdays.toList()..sort()),
  };

  /// 存盘的语言：没有 `scriptExact` 标记的带文字写法是旧记录 → 整门语言（见库注释）。
  static String _languageOfStored(String tag, {required bool scriptExact}) {
    if (scriptExact) return tag;
    final StudyGoalLanguage? language = resolveStudyGoalLanguage(tag);
    return language?.script == null ? tag : language!.combined.tag;
  }

  /// 宽容解析：缺 id / 未知 metric / 目标 <= 0 的条目返回 null（调用方丢弃）；
  /// 未知 period 回落每日；坏的 `days` 元素忽略。
  static StudyGoal? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? metricWire = raw['metric'];
    final Object? target = raw['target'];
    if (id is! String || id.isEmpty || metricWire is! String) return null;
    final StudyGoalId? metric = StudyGoalId.fromWire(metricWire);
    if (metric == null) return null;
    final int? value = switch (target) {
      final int v => v,
      final double v when v.isFinite => v.round(),
      _ => null,
    };
    if (value == null || value <= 0) return null;
    final Object? language = raw['language'];
    final Object? days = raw['days'];
    return StudyGoal(
      id: id,
      metric: metric,
      period: StudyGoalPeriod.fromWire(
        raw['period'] is String ? raw['period'] as String : null,
      ),
      target: value,
      language: language is String
          ? _languageOfStored(language, scriptExact: raw['scriptExact'] == true)
          : null,
      activeWeekdays: <int>{
        if (days is List)
          for (final Object? d in days)
            if (d is int) d,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StudyGoal &&
      other.id == id &&
      other.metric == metric &&
      other.period == period &&
      other.target == target &&
      other.language == language &&
      other.activeWeekdays.length == activeWeekdays.length &&
      other.activeWeekdays.containsAll(activeWeekdays);

  @override
  int get hashCode => Object.hash(
    id,
    metric,
    period,
    target,
    language,
    Object.hashAllUnordered(activeWeekdays),
  );

  @override
  String toString() =>
      'StudyGoal($id ${metric.wire} ${period.wire} $target '
      '${language ?? '*'} ${activeWeekdays.toList()..sort()})';
}

Set<int> _normalizeWeekdays(Set<int> days) {
  final Set<int> valid = <int>{
    for (final int d in days)
      if (d >= DateTime.monday && d <= DateTime.sunday) d,
  };
  return valid.length == 7 ? const <int>{} : Set<int>.unmodifiable(valid);
}

/// 新目标的 id：毫秒时间戳 + 随机后缀（同一毫秒连加两个也不撞）。
String newStudyGoalId({DateTime? now, math.Random? random}) {
  final int ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final int salt = (random ?? math.Random()).nextInt(1 << 30);
  return '${ms.toRadixString(36)}-${salt.toRadixString(36)}';
}

/// 解出偏好 `study_goals`。null = 键缺失 / 空串 / 坏 JSON / 不是数组（调用方走迁移）；
/// 数组里的坏条目丢弃，重复 id 只留第一个。
List<StudyGoal>? decodeStudyGoals(String json) {
  if (json.trim().isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! List) return null;
  final List<StudyGoal> out = <StudyGoal>[];
  final Set<String> seen = <String>{};
  for (final Object? entry in decoded) {
    final StudyGoal? goal = StudyGoal.fromJson(entry);
    if (goal == null || !seen.add(goal.id)) continue;
    out.add(goal);
  }
  return out;
}

String encodeStudyGoals(List<StudyGoal> goals) => jsonEncode(
  <Map<String, Object?>>[for (final StudyGoal g in goals) g.toJson()],
);

/// 旧的逐项目标偏好 → 记录（每个 > 0 的目标一条每日记录；字数按旧周期取日 / 周
/// 那一份）。id 固定为 `legacy-<metric>`：迁移态不落盘、每次渲染现算，id 必须稳定
/// （主目标偏好要能指回它）。[language] 是分支期的 `reading_goal_language`（'' = 全部），
/// 只给字数与时长目标。
List<StudyGoal> migrateLegacyStudyGoals({
  int totalMinutes = 0,
  int readingMinutes = 0,
  int listeningMinutes = 0,
  int videoMinutes = 0,
  int reviews = 0,
  int minedCards = 0,
  int dailyChars = 0,
  int weeklyChars = 0,
  StudyGoalPeriod charsPeriod = StudyGoalPeriod.daily,
  String language = '',
}) {
  final List<StudyGoal> out = <StudyGoal>[];
  void add(StudyGoalId metric, int target, {StudyGoalPeriod? period}) {
    if (target <= 0) return;
    out.add(
      StudyGoal(
        id: 'legacy-${metric.wire}',
        metric: metric,
        period: period ?? StudyGoalPeriod.daily,
        target: target,
        // 旧偏好只按主语言匹配：整门语言（`zh-Hans` → `zh`）。
        language: studyGoalCombinedLanguageTag(language),
      ),
    );
  }

  add(StudyGoalId.total, totalMinutes);
  add(StudyGoalId.reading, readingMinutes);
  add(StudyGoalId.listening, listeningMinutes);
  add(StudyGoalId.watching, videoMinutes);
  add(StudyGoalId.reviews, reviews);
  add(StudyGoalId.mined, minedCards);
  final bool weekly = charsPeriod == StudyGoalPeriod.weekly;
  add(
    StudyGoalId.chars,
    weekly ? weeklyChars : dailyChars,
    period: weekly ? StudyGoalPeriod.weekly : StudyGoalPeriod.daily,
  );
  return out;
}

/// 复习目标为什么在首页 / 小组件上不出现：复习数只有内置复习（Fushi SRS）给得出，
/// 与 `studyGoalsUseBuiltInSrs` 同一判据。设置 › 目标与目标面板据此写一句说明。
enum StudyGoalReviewsHidden {
  /// 复习模块关着。
  srsModuleOff,

  /// 挖词目标是 Anki（Anki 的接口不给复习数）。
  cardsGoToAnki,
}

/// 复习目标此刻是否被藏起来、为什么；null = 正常出现。
StudyGoalReviewsHidden? studyGoalReviewsHiddenFor({
  required bool srsModuleEnabled,
  required bool miningToAnki,
}) {
  if (!srsModuleEnabled) return StudyGoalReviewsHidden.srsModuleOff;
  if (miningToAnki) return StudyGoalReviewsHidden.cardsGoToAnki;
  return null;
}

/// 首页「今日」格左右滑显示哪些目标（偏好 `home_today_swipe_goals`）。
enum StudyGoalSwipeScope {
  /// 只有每日目标（缺省）。
  daily('daily'),

  /// 全部目标。
  all('all');

  const StudyGoalSwipeScope(this.wire);
  final String wire;

  static StudyGoalSwipeScope fromWire(String? wire) =>
      wire == all.wire ? all : daily;
}

/// 首页「今日」格聚焦版式翻哪些页——「主目标」与「左右滑动」两项设置的**唯一**
/// 选择规则（首页翻页、设置「主目标」候选都按它，HBK-AUDIT-021）。
///
/// 页 = 「左右滑动」范围内的目标（[StudyGoalSwipeScope.daily] 只取每日目标，一个
/// 每日目标都没有时退回全部，不让格子空着），再并上主目标 [mainGoalId]：设置里任何
/// 目标都能选作主目标，选了周 / 月目标而范围是「每日」时，它按记录顺序插回原位，
/// 与每日目标共存——不会因为过滤掉了主目标而换成第一条每日目标。[goalOf] 取每项
/// 的目标记录（首页传进度项，设置传记录本身）。页序 = 记录顺序。
List<T> studyGoalTodayPages<T>(
  List<T> goals, {
  required StudyGoal Function(T item) goalOf,
  required String mainGoalId,
  required StudyGoalSwipeScope scope,
}) {
  if (scope == StudyGoalSwipeScope.all) return goals;
  final List<T> pages = <T>[
    for (final T g in goals)
      if (goalOf(g).period == StudyGoalPeriod.daily ||
          goalOf(g).id == mainGoalId)
        g,
  ];
  final bool hasDaily = pages.any(
    (T g) => goalOf(g).period == StudyGoalPeriod.daily,
  );
  return hasDaily ? pages : goals;
}

/// [studyGoalTodayPages] 给出的 [pages] 里从哪页开始：主目标 [mainGoalId] 那页；
/// 指不到（'' =「第一个目标」，或主目标已删）就是第一页。
int studyGoalTodayPageIndex<T>(
  List<T> pages, {
  required StudyGoal Function(T item) goalOf,
  required String mainGoalId,
}) => math.max(0, pages.indexWhere((T g) => goalOf(g).id == mainGoalId));

/// 首页「今日」格的版式（偏好 `home_today_layout`）。
enum StudyGoalTodayLayout {
  /// 聚焦（缺省）：一条目标大环 + 大字，左右滑看其余目标。
  focus('focus'),

  /// 总览：「今日目标」列表，每条一行（语言 · 度量、数值 / 目标、进度条）。
  overview('overview');

  const StudyGoalTodayLayout(this.wire);
  final String wire;

  static StudyGoalTodayLayout fromWire(String? wire) =>
      wire == overview.wire ? overview : focus;
}

/// 按语言的首页格 / 设置页里排序目标：每日 → 每周 → 每月，同周期保持列表顺序。
List<StudyGoal> sortStudyGoalsByPeriod(Iterable<StudyGoal> goals) {
  final List<StudyGoal> list = goals.toList();
  final List<int> order = <int>[for (int i = 0; i < list.length; i++) i]
    ..sort((int a, int b) {
      final int byPeriod = list[a].period.index.compareTo(list[b].period.index);
      return byPeriod != 0 ? byPeriod : a.compareTo(b);
    });
  return <StudyGoal>[for (final int i in order) list[i]];
}
