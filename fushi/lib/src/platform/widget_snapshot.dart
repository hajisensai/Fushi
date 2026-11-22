import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

import 'package:fushi/src/pages/implementations/stat_summary.dart'
    show computeWeekOverWeekPercent;
import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/platform/widget_progress.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi_engine/stats/study_goal_language.dart'
    show StudyGoalUnit, StudyGoalUnitChoice, studyGoalUnitFor;

export 'package:fushi/src/stats/study_goal_record.dart'
    show StudyGoal, StudyGoalId, StudyGoalPeriod;
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// 快照契约版本（见 docs/agent/android-widgets.md）。
const int kWidgetSnapshotVersion = 2;

/// 快照里最多带几张「书架」卡（含「继续」那张）。
const int kWidgetShelfLimit = 4;

/// 周图表的天数（最旧 → 今天）。
const int kWidgetWeekDays = 7;

/// 月热力图的天数（5 行 × 7，最旧 → 今天）。
const int kWidgetMonthDays = 35;

/// 长热力图（快照 `heatmap`，Apple 中号「学习热力图」）的天数：16 周 × 7，最旧 → 今天。
const int kWidgetHeatmapDays = 112;

/// 复习到期预排（`srs.timeline`）往后看多远：WidgetKit 一次 timeline 的跨度。
const Duration kWidgetSrsTimelineHorizon = Duration(hours: 24);

/// 复习到期预排最多几个变化点（不含「现在」那一项）。
const int kWidgetSrsTimelineMaxSteps = 40;

/// 每日词汇最多带几条。
const int kWidgetVocabLimit = 12;

/// 词汇释义纯文本的最大长度（码点）。
const int kWidgetDefinitionMaxChars = 200;

/// 快照 `labels` 的**全部**键（稳定契约，改名要和原生侧 `WidgetSnapshot.kt`、
/// `fushi/apple/HomeWidgets/Shared/FushiWidgetSnapshot.swift` 同步）。
///
/// 值已按 app 内语言本地化；`updatedAgo` / `agoMinutes` /
/// `agoHours` / `agoDays` 是**模板**（`{n}` / `{age}` 由原生侧在显示时刻替换，
/// 因为「几分钟前」只有显示时才算得准）。
const List<String> kWidgetLabelKeys = <String>[
  // v1
  'kind_book',
  'kind_manga',
  'kind_video',
  'resume',
  'today',
  'streak',
  'srsDue',
  'srsOff',
  'review',
  'srsDone',
  'recent',
  'weekly',
  'books',
  'manga',
  'video',
  'lookup',
  'openToSetUp',
  // 沉浸看板
  'dashboardTitle',
  'reading',
  'listening',
  'watching',
  'games',
  'goal',
  'ofGoal',
  'longest',
  'vsLastWeek',
  'thisMonth',
  'activeDays',
  // 复习
  'providerFushi',
  'providerAnki',
  'srsNew',
  'srsLearn',
  'reviewedToday',
  'dueTomorrow',
  'reviewNow',
  'openAnki',
  'allCaughtUp',
  'srsSetup',
  'ankiPermission',
  // 词汇 / 目标 / 快捷入口
  'vocabTitle',
  'nextWord',
  'lookUp',
  'noVocab',
  'goalsTitle',
  'goalsTitleMixed',
  'goalsMore',
  'noGoals',
  'vocab',
  'stats',
  'settings',
  // 更新时间
  'updatedAgo',
  'openToRefresh',
  'agoNow',
  'agoMinutes',
  'agoHours',
  'agoDays',
  'zeroTime',
  'streakSrs',
  'weekReviews',
  'weekGoalDays',
  'recentDays',
  // 正在播放
  'nowPlaying',
  'nothingPlaying',
  'play',
  'pause',
  'previous',
  'next',
  'skipBack',
  'skipForward',
  'kind_audiobook',
  'kind_music',
  // 下载 / 接下来（服务器条目）
  'downloadsTitle',
  'noDownloads',
  'downloadQueued',
  'downloadPaused',
  'downloadFailed',
  'downloadsActive',
  'onDeckTitle',
  'onDeckNoServers',
  'onDeckEmpty',
  'onDeckOff',
  // Apple 小组件（WidgetKit）额外用到的文案；Android 不读，原生侧缺键有英文兜底。
  'continueEmpty',
  'streakDays',
  'lookupHint',
  'lookupCamera',
  'lookupClipboard',
  // 「继续」里的游戏卡（隐私开关打开时代替标题）/ 16 周热力图标题
  'kind_game',
  'recentHeatmapDays',
];

/// 小组件上所有文案（已按 app 内语言本地化）。键集合见 [kWidgetLabelKeys]；
/// 原生侧缺键时有自己的英文兜底，所以这里不强制每个键都在。
class WidgetSnapshotLabels {
  const WidgetSnapshotLabels(this.values);

  final Map<String, String> values;

  Map<String, String> toJson() => Map<String, String>.of(values);
}

/// 沉浸四类（固定顺序，对应快照 `today.categories`）。
enum WidgetImmersionCategory {
  reading('reading', WidgetTab.books),
  listening('listening', WidgetTab.music),
  watching('watching', WidgetTab.video),
  games('games', WidgetTab.games);

  const WidgetImmersionCategory(this.wire, this.tab);

  final String wire;

  /// 点这一格打开的 tab（`fushi://widget/tab/...`）。
  final WidgetTab tab;

  /// 统计事实的 `mediaKind` → 类别。阅读 = 全部书（含漫画 / 有声书），听力 = 音乐，
  /// 观看 = 视频，游戏 = 游戏；复习（`review`）与未知种类不算沉浸，返回 null。
  static WidgetImmersionCategory? fromMediaKind(String mediaKind) =>
      switch (mediaKind) {
        'book' => reading,
        'music' => listening,
        'video' => watching,
        'game' => games,
        _ => null,
      };
}

/// 一条可「继续」的媒体（书 / 漫画 / 视频），数值是未清洗的原始输入。
class WidgetMediaInput {
  const WidgetMediaInput({
    required this.kind,
    required this.id,
    required this.title,
    required this.recentAt,
    this.subtitle = '',
    this.progress = 0,
    this.coverPath = '',
    this.remainingMs,
    this.link = '',
  });

  final WidgetMediaKind kind;

  /// 书 / 漫画 = `MediaItem.mediaIdentifier`，视频 = `VideoBookRow.bookUid`，
  /// 游戏 = `GalgameEntry.id`；服务器 / 互联远端条目是各自来源的稳定键（只作身份，
  /// 打开走 [link]）。
  final String id;

  /// 点卡片打开的深链。空串 = 本机条目，由 [buildWidgetSnapshot] 填成
  /// `WidgetContinueLink(kind, id)`；服务器条目给 `WidgetServerLink`，互联远端条目给
  /// 对应 tab（与首页「继续」点卡同一落地）。
  final String link;
  final String title;

  /// 作者；没有就空串。
  final String subtitle;

  /// 进度分数；越界或 NaN 由 [buildWidgetSnapshot] 夹到 0..1。
  final double progress;

  /// 本机封面图文件的绝对路径；调用方已确认存在、可读，不确定就传空串。
  final String coverPath;

  /// 最近活动时刻（epoch 毫秒），排序与「几小时前」用；0 = 未知。
  final int recentAt;

  /// 预计还需多久读完 / 看完（毫秒）；null = 估不出来（没速度数据、没总长度），
  /// 此时快照里 `remaining` 是空串。绝不编造，算法见 `widget_progress.dart`。
  final int? remainingMs;
}

/// 沉浸统计的原始输入（调用方已按统计日 key 聚合，窗口至少含最近 14 天）。
class WidgetImmersionInput {
  const WidgetImmersionInput({
    this.msByDay = const <String, Map<WidgetImmersionCategory, int>>{},
    this.charsByDay = const <String, int>{},
    this.activeDays = const <String>{},
  });

  /// 统计日 key → 各类别当天毫秒。
  final Map<String, Map<WidgetImmersionCategory, int>> msByDay;

  /// 统计日 key → 当天字数（全部沉浸种类）。
  final Map<String, int> charsByDay;

  /// 全部历史里「有沉浸活动」的统计日（ms>0 || chars>0 || pages>0），连续天数用。
  final Set<String> activeDays;

  int msOf(String dateKey, [WidgetImmersionCategory? category]) {
    final Map<WidgetImmersionCategory, int>? day = msByDay[dateKey];
    if (day == null) return 0;
    if (category != null) return _nonNegative(day[category] ?? 0);
    int total = 0;
    for (final int v in day.values) {
      total += _nonNegative(v);
    }
    return total;
  }
}

/// 复习到期预排的一个节点：从 [at]（epoch 毫秒）起待复习数是 [due]。
typedef WidgetSrsDueStep = ({int at, int due});

/// 不打开 app 时待复习数怎么变（纯函数，给 `srs.timeline` 用）：
///
/// - 第一项 = 现在，[dueNow] 原样（与首页复习条同一份牌组汇总，含每日上限）。
/// - 学习中 / 重学卡按各自精确到毫秒的 `dueAt` 陆续到期，逐张加上。
/// - 跨过 SRS 日边界（[dayIndexOf] 换日的那一刻，二分到分钟）时再加上新一天到期的
///   复习卡 [reviewsDueNextDay]——日边界按 store 的口径（可配重置时刻），不假设零点。
///
/// 节点只在计数变化时产生，同一分钟到期的合成一个；超过 [maxSteps] 个时合并到整点，
/// 仍超出就截断（日边界那一点总保留）。到期时刻都向上取整：小组件宁可晚一分钟显示，
/// 不提前显示还没到期的卡。
List<WidgetSrsDueStep> buildWidgetSrsDueTimeline({
  required int nowMs,
  required int dueNow,
  required Iterable<int> learningDueAts,
  required int Function(int ms) dayIndexOf,
  required int reviewsDueNextDay,
  Duration horizon = kWidgetSrsTimelineHorizon,
  int maxSteps = kWidgetSrsTimelineMaxSteps,
}) {
  final int end = nowMs + horizon.inMilliseconds;
  final int? boundary = _nextSrsDayBoundary(nowMs, end, dayIndexOf);
  final List<int> ripening = <int>[
    for (final int at in learningDueAts)
      if (at > nowMs && at <= end) at,
  ]..sort();

  int roundUp(int at, int unit) => ((at + unit - 1) ~/ unit) * unit;
  List<int> stepTimes(int unit) {
    final Set<int> times = <int>{
      for (final int at in ripening) roundUp(at, unit),
    };
    if (boundary != null) times.add(boundary);
    return times.toList()..sort();
  }

  List<int> times = stepTimes(60 * 1000);
  if (times.length > maxSteps) times = stepTimes(3600 * 1000);
  if (times.length > maxSteps) {
    times = times.take(maxSteps).toList();
    if (boundary != null && !times.contains(boundary)) {
      times = <int>[...times.take(maxSteps - 1), boundary]..sort();
    }
  }

  final int base = _nonNegative(dueNow);
  final int nextDay = _nonNegative(reviewsDueNextDay);
  final List<WidgetSrsDueStep> out = <WidgetSrsDueStep>[(at: nowMs, due: base)];
  int ripeIndex = 0;
  for (final int t in times) {
    if (t <= nowMs) continue;
    while (ripeIndex < ripening.length && ripening[ripeIndex] <= t) {
      ripeIndex++;
    }
    final bool pastBoundary = boundary != null && t >= boundary;
    final int due = base + ripeIndex + (pastBoundary ? nextDay : 0);
    if (due != out.last.due) out.add((at: t, due: due));
  }
  return out;
}

/// (from, to] 之后第一个 [dayIndexOf] 比 from 大的**整分钟**时刻；区间内不换日为 null。
///
/// 只在整分钟网格（epoch 分钟）上二分，所以结果只取决于真实换日点本身——真实换日
/// 点向上取整到分钟（与学习步的 roundUp 同一口径），不随 [from] 漂移。否则每次采集
/// 的 nowMs 不同，`srs.timeline` 就会不同，快照签名去重随之失效。
int? _nextSrsDayBoundary(int from, int to, int Function(int ms) dayIndexOf) {
  final int today = dayIndexOf(from);
  if (dayIndexOf(to) <= today) return null;
  const int minute = 60 * 1000;
  // 不变量：dayIndexOf(lo * minute) <= today < dayIndexOf(hi * minute)。
  // lo * minute <= from（向下取整），hi * minute >= to（向上取整）。
  int lo = from ~/ minute;
  int hi = (to + minute - 1) ~/ minute;
  while (hi - lo > 1) {
    final int mid = lo + (hi - lo) ~/ 2;
    if (dayIndexOf(mid * minute) > today) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return hi * minute;
}

/// 热力图一格的档位（0…4）：没学 0；学了但没计时（只有字数 / 页数）1；
/// 否则 <15 分钟 1、<30 分钟 2、<60 分钟 3、其余 4。固定阈值（不随窗口最大值变），
/// 同一天在不同快照里颜色一致。
int widgetHeatLevel(int ms, {bool active = false}) {
  const int minute = 60 * 1000;
  if (ms <= 0) return active ? 1 : 0;
  if (ms < 15 * minute) return 1;
  if (ms < 30 * minute) return 2;
  if (ms < 60 * minute) return 3;
  return 4;
}

/// 学习目标记录 + 算分子要的预聚合数据（纯数据；装配在 `study_goals.dart`）。
class WidgetGoalsInput {
  const WidgetGoalsInput({
    this.goals = const <StudyGoal>[],
    this.languageImmersion = const <String, WidgetImmersionInput>{},
    this.minedByDay = const <String, int>{},
    this.unitChoice = StudyGoalUnitChoice.auto,
    this.labelOf,
    this.formatWords,
    this.compactOf,
  });

  /// 目标记录，按用户列表顺序。
  final List<StudyGoal> goals;

  /// 按语言过滤后的沉浸量，键 = [StudyGoal.language]（原样）。全部语言的目标用
  /// 快照那份沉浸量；某语言缺这一项 = 该语言没有任何计入的内容（分子 0）。
  final Map<String, WidgetImmersionInput> languageImmersion;

  /// 统计日 key → 当天制卡数（`mining_statistics`，覆盖到月窗口）。
  final Map<String, int> minedByDay;

  /// 文字目标单位（全局）：auto = 按目标语言。
  final StudyGoalUnitChoice unitChoice;

  /// 一条目标的外显标签（走 i18n，调用方注入）；null = 空串。
  final String Function(StudyGoal goal, {required bool restDay})? labelOf;

  /// 「词」单位的文字目标的值外显；null = 用快照的 `formatChars`。
  final String Function(int words)? formatWords;

  /// 一条进度的紧凑文案（语言 / 度量 / 周期分开、「14.8K / 10K」、状态与剩余量；
  /// 走 i18n，调用方注入，装配见 `study_goals.dart` 的 `studyGoalCompactText`）。
  /// null = 快照里这些字段退回空串（数值对仍由本库的格式化回调拼出）。
  final StudyGoalCompactText Function(StudyGoalProgress g)? compactOf;

  /// [goal] 的文字单位（只对 [StudyGoalId.chars] 有意义）。
  StudyGoalUnit unitOf(StudyGoal goal) =>
      unitChoice.fixed ?? studyGoalUnitFor(goal.language);

  /// [goal] 分子用的沉浸量。
  WidgetImmersionInput immersionFor(StudyGoal goal, WidgetImmersionInput all) {
    final String? language = goal.language;
    if (language == null) return all;
    return languageImmersion[language] ?? const WidgetImmersionInput();
  }
}

/// 复习卡片去向（`SrsMiningTarget` + 模块开关的合成结果）。
enum WidgetSrsProvider {
  fushi,
  anki,
  none;

  String get wire => name;
}

/// 复习输入。**只有 [WidgetSrsProvider.fushi] 的计数字段会进快照**：anki / none
/// 时即使调用方误传了数字也被丢弃，两个 provider 的数永不混。
class WidgetSrsInput {
  const WidgetSrsInput({
    this.provider = WidgetSrsProvider.none,
    this.label = '',
    this.ankiPackage = 'com.ichi2.anki',
    this.newCount = 0,
    this.learnCount = 0,
    this.reviewCount = 0,
    this.reviewedToday = 0,
    this.dueTomorrow = 0,
    this.streakCurrent = 0,
    this.streakLongest = 0,
    this.reviewsByDay = const <int>[],
    this.timeline = const <WidgetSrsDueStep>[],
  });

  final WidgetSrsProvider provider;

  /// provider 的展示名（"Fushi SRS" / "AnkiDroid"），none 传空。
  final String label;
  final String ankiPackage;
  final int newCount;
  final int learnCount;
  final int reviewCount;
  final int reviewedToday;
  final int dueTomorrow;
  final int streakCurrent;
  final int streakLongest;

  /// 每天复习数，最旧 → 今天；不足 [kWidgetMonthDays] 前面补 0，多了取最近的。
  final List<int> reviewsByDay;

  /// 待复习数的预排（[buildWidgetSrsDueTimeline]）；空 = 不会自己变。快照里只留晚于
  /// 生成时刻、且与前一个计数不同的点（「现在」就是 `srs.due`）。
  final List<WidgetSrsDueStep> timeline;
}

/// 每日词汇的原始输入（释义是未清洗的 HTML / 文本）。
class WidgetVocabInput {
  const WidgetVocabInput({
    required this.term,
    required this.createdAt,
    required this.origin,
    this.reading = '',
    this.definition = '',
    this.sentence = '',
    this.source = '',
  });

  final String term;
  final String reading;
  final String definition;
  final String sentence;

  /// 出处标题（书 / 视频名）。
  final String source;

  /// `mined` | `favorite`。
  final String origin;

  /// 创建时刻（epoch 毫秒），排序用。
  final int createdAt;
}

/// 各模块是否开着（关着的模块相关内容不进快照）。
class WidgetModulesInput {
  const WidgetModulesInput({
    this.books = true,
    this.manga = true,
    this.video = true,
    this.lookup = true,
    this.srs = true,
    this.music = true,
    this.games = true,
  });

  final bool books;
  final bool manga;
  final bool video;
  final bool lookup;
  final bool srs;
  final bool music;
  final bool games;

  bool enabled(WidgetMediaKind kind) => switch (kind) {
    WidgetMediaKind.book => books,
    WidgetMediaKind.manga => manga,
    WidgetMediaKind.video => video,
    WidgetMediaKind.game => games,
  };

  Map<String, bool> toJson() => <String, bool>{
    'books': books,
    'manga': manga,
    'video': video,
    'lookup': lookup,
    'srs': srs,
    'music': music,
    'games': games,
  };
}

/// 「正在播放」小组件的媒体种类（快照 `nowPlaying.kind`）。
enum WidgetNowPlayingKind {
  music,
  audiobook;

  String get wire => name;
}

/// 正在播放（或最近播放）的一首歌 / 一本有声书，数值是未清洗的原始输入。
class WidgetNowPlayingInput {
  const WidgetNowPlayingInput({
    required this.kind,
    required this.title,
    required this.link,
    required this.updatedAt,
    this.subtitle = '',
    this.coverPath = '',
    this.positionMs = 0,
    this.durationMs = 0,
    this.playing = false,
    this.canSkipTrack = false,
    this.skipSeconds = 0,
  });

  final WidgetNowPlayingKind kind;
  final String title;

  /// 歌手 / 作者；没有就空串。
  final String subtitle;

  /// 本机封面图文件的绝对路径（调用方已确认存在），没有就空串。
  final String coverPath;
  final int positionMs;
  final int durationMs;
  final bool playing;

  /// 取样时刻（epoch 毫秒）：原生侧用 `positionMs + (now - updatedAt)` 外推进度。
  final int updatedAt;

  /// 点按小组件主体打开的深链。
  final String link;

  /// 音乐：队列里有上一首 / 下一首可跳。有声书恒为 true（跳句 / 跳秒总是可用）。
  final bool canSkipTrack;

  /// 有声书「上一句 / 下一句」键的步长：0 = 按句，其余 = 秒数（沿用阅读器的跳句设置）。
  final int skipSeconds;
}

/// `nowPlaying` 块（纯函数）：没有输入 / 对应模块已关 = null。位置夹到 `0..时长`
/// （时长未知时只保证非负）。隐私开关不在这里生效（标题照常带，原生侧按开关隐藏）。
Map<String, Object?>? buildWidgetNowPlaying(
  WidgetNowPlayingInput? input,
  WidgetModulesInput modules,
) {
  if (input == null || input.title.trim().isEmpty) return null;
  final bool enabled = switch (input.kind) {
    WidgetNowPlayingKind.music => modules.music,
    WidgetNowPlayingKind.audiobook => modules.books,
  };
  if (!enabled) return null;
  final int duration = _nonNegative(input.durationMs);
  int position = _nonNegative(input.positionMs);
  if (duration > 0 && position > duration) position = duration;
  return <String, Object?>{
    'kind': input.kind.wire,
    'title': input.title.trim(),
    'subtitle': input.subtitle.trim(),
    'cover': input.coverPath,
    'positionMs': position,
    'durationMs': duration,
    'playing': input.playing,
    'updatedAt': _nonNegative(input.updatedAt),
    'link': input.link,
    'canSkipTrack': input.canSkipTrack,
    'skipSeconds': _nonNegative(input.skipSeconds),
  };
}

/// 夹到 0..1；NaN / 无穷当 0。
double clampWidgetFraction(double value) {
  if (value.isNaN || value.isInfinite) return 0;
  if (value < 0) return 0;
  if (value > 1) return 1;
  return value;
}

/// 当前连续天数：今天没记录但昨天有，从昨天起算（今天还没学不中断连击）。
/// 全走统计日 key 算术，不合成午夜（见 docs/agent/statistics.md）。
int computeCurrentStreak(Set<String> activeDays, String todayKey) {
  if (activeDays.isEmpty) return 0;
  String cursor = todayKey;
  if (!activeDays.contains(cursor)) {
    cursor = FushiDatabase.statDateKeyPlusDays(todayKey, -1);
    if (!activeDays.contains(cursor)) return 0;
  }
  int streak = 0;
  while (activeDays.contains(cursor)) {
    streak++;
    cursor = FushiDatabase.statDateKeyPlusDays(cursor, -1);
  }
  return streak;
}

/// 历史最长连续天数（统计日 key 集合；空 = 0）。
int computeLongestStreak(Set<String> dayKeys) {
  if (dayKeys.isEmpty) return 0;
  final List<String> sorted = dayKeys.toList()..sort();
  int longest = 1;
  int run = 1;
  for (int i = 1; i < sorted.length; i++) {
    if (FushiDatabase.statDateKeyPlusDays(sorted[i - 1], 1) == sorted[i]) {
      run++;
    } else {
      run = 1;
    }
    if (run > longest) longest = run;
  }
  return longest;
}

final RegExp _htmlTag = RegExp(r'<[^>]*>');
final RegExp _htmlBreak = RegExp(
  r'<\s*(br|/p|/div|/li|/tr|/ul|/ol|/h[1-6])\b[^>]*>',
  caseSensitive: false,
);
final RegExp _htmlStyleBlock = RegExp(
  r'<\s*(style|script)\b[^>]*>.*?<\s*/\s*\1\s*>',
  caseSensitive: false,
  dotAll: true,
);
final RegExp _whitespaceRun = RegExp(r'\s+');

/// 词典释义（HTML / 带标记文本）→ 小组件用纯文本：去标签与样式块、解常见实体、
/// 压空白，超过 [maxChars] 个码点截断并补省略号。多语言 / RTL 文本原样透传。
String widgetPlainText(String raw, {int maxChars = kWidgetDefinitionMaxChars}) {
  if (raw.isEmpty) return '';
  String text = raw
      .replaceAll(_htmlStyleBlock, ' ')
      .replaceAll(_htmlBreak, ' ')
      .replaceAll(_htmlTag, '');
  text = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
  text = text.replaceAll(_whitespaceRun, ' ').trim();
  final List<int> runes = text.runes.toList();
  if (runes.length <= maxChars) return text;
  return '${String.fromCharCodes(runes.take(maxChars)).trimRight()}…';
}

/// 把原始输入收成原生侧约定的 JSON 对象（纯函数，不碰 IO / provider）。契约见
/// docs/agent/android-widgets.md。
///
/// - 关掉的模块：对应媒体先出局，再取「继续」与书架。「继续」= 按
///   [WidgetMediaInput.recentAt] 倒序第一条；书架 = 前 [kWidgetShelfLimit] 条。
/// - 沉浸四类固定顺序；`today.goal*` / `goals` 只含用户设了目标（> 0）的项。
/// - 复习：provider 为 anki / none 时**不带任何 Fushi 计数**（含 `timeline`）。
/// - 零点切换：[nextDayAt]（下一个统计日边界，epoch 毫秒）给了且晚于 [generatedAt]
///   时带 `rollover`：同一批按天计算的块（`today` / `goals` / `week` / `month` /
///   `streak` / `heatmap`）按**下一个统计日**再算一遍，原生侧过了 `rollover.at` 就整块
///   换上，不开 app 也会在零点清零今日、按规则延续或中断连续天数。
/// - 数据缺失（空输入）= 全 0 / 空数组 / `deltaPct: null`，不抛。
/// - [formatTime] / [formatChars] / [formatCount] / [formatAge] / [weekdayLabel]
///   由调用方注入（走 i18n），这里不依赖 slang。
Map<String, Object?> buildWidgetSnapshot({
  required String day,
  required int generatedAt,
  required WidgetSnapshotLabels labels,
  required WidgetModulesInput modules,
  required List<WidgetMediaInput> media,
  required WidgetImmersionInput immersion,
  required WidgetGoalsInput goals,
  required WidgetSrsInput srs,
  required List<WidgetVocabInput> vocab,
  required String Function(int ms) formatTime,
  required String Function(int chars) formatChars,
  required String Function(int count) formatCount,
  required String Function(int epochMs) formatAge,
  required String Function(String dateKey) weekdayLabel,
  String Function(int ms)? formatTimeLeft,
  WidgetDownloadsInput downloads = const WidgetDownloadsInput(),
  WidgetOnDeckInput onDeck = const WidgetOnDeckInput(),
  Map<WidgetImmersionCategory, String> categoryLabels =
      const <WidgetImmersionCategory, String>{},
  WidgetNowPlayingInput? nowPlaying,
  String profileName = '',
  bool multiProfile = false,
  bool hideTitles = false,
  bool hideDefinitions = false,
  bool hideProfile = false,
  int? nextDayAt,
}) {
  final List<WidgetMediaInput> visible = <WidgetMediaInput>[
    for (final WidgetMediaInput m in media)
      if (modules.enabled(m.kind) && m.id.isNotEmpty) m,
  ];
  // List.sort 不稳定：带上输入序号做平局决胜。
  final List<int> order = <int>[for (int i = 0; i < visible.length; i++) i]
    ..sort((int a, int b) {
      final int byRecent = visible[b].recentAt.compareTo(visible[a].recentAt);
      return byRecent != 0 ? byRecent : a.compareTo(b);
    });
  final List<Map<String, Object?>> shelf = <Map<String, Object?>>[
    for (final int i in order.take(kWidgetShelfLimit))
      _mediaJson(visible[i], formatAge, formatTimeLeft),
  ];

  final bool fushi = srs.provider == WidgetSrsProvider.fushi;
  final List<int> reviewsMonth = _fitTo<int>(
    <int>[for (final int r in srs.reviewsByDay) _nonNegative(r)],
    kWidgetMonthDays,
    0,
  );
  final int reviewedToday = fushi ? _nonNegative(srs.reviewedToday) : 0;
  final int due = fushi
      ? _nonNegative(srs.newCount) +
            _nonNegative(srs.learnCount) +
            _nonNegative(srs.reviewCount)
      : 0;

  Map<String, Object?> dayBlocks({
    required String key,
    required WidgetGoalsInput dayGoals,
    required List<int> dayReviews,
    required int dayReviewed,
    required int srsStreakCurrent,
  }) => _dayBlocks(
    day: key,
    immersion: immersion,
    goals: dayGoals,
    fushi: fushi,
    reviewsMonth: dayReviews,
    reviewedToday: dayReviewed,
    srsStreakCurrent: srsStreakCurrent,
    srsStreakLongest: _nonNegative(srs.streakLongest),
    categoryLabels: categoryLabels,
    formatTime: formatTime,
    formatChars: formatChars,
    formatCount: formatCount,
    weekdayLabel: weekdayLabel,
  );

  final Map<String, Object?> todayBlocks = dayBlocks(
    key: day,
    dayGoals: goals,
    dayReviews: reviewsMonth,
    dayReviewed: reviewedToday,
    srsStreakCurrent: _nonNegative(srs.streakCurrent),
  );
  final int? rolloverAt = nextDayAt != null && nextDayAt > generatedAt
      ? nextDayAt
      : null;
  final String nextDay = FushiDatabase.statDateKeyPlusDays(day, 1);

  return <String, Object?>{
    'v': kWidgetSnapshotVersion,
    'day': day,
    'generatedAt': generatedAt,
    'profile': <String, Object?>{'name': profileName, 'multi': multiProfile},
    'privacy': <String, bool>{
      'hideTitles': hideTitles,
      'hideDefinitions': hideDefinitions,
      'hideProfile': hideProfile,
    },
    'labels': labels.toJson(),
    'modules': modules.toJson(),
    'continue': shelf.isEmpty ? null : shelf.first,
    'shelf': shelf,
    ...todayBlocks,
    'srs': <String, Object?>{
      'provider': srs.provider.wire,
      'label': srs.label,
      'enabled': fushi,
      'due': due,
      if (fushi) ...<String, Object?>{
        'new': _nonNegative(srs.newCount),
        'learn': _nonNegative(srs.learnCount),
        'review': _nonNegative(srs.reviewCount),
        'reviewedToday': reviewedToday,
        'dueTomorrow': _nonNegative(srs.dueTomorrow),
        'timeline': _srsTimelineJson(srs.timeline, generatedAt, due),
      },
      if (srs.provider == WidgetSrsProvider.anki)
        'ankiPackage': srs.ankiPackage,
    },
    'vocab': _vocabJson(vocab),
    'nowPlaying': buildWidgetNowPlaying(nowPlaying, modules),
    'downloads': buildWidgetDownloadsJson(downloads),
    'onDeck': buildWidgetOnDeckJson(onDeck, formatAge: formatAge),
    'rollover': rolloverAt == null
        ? null
        : <String, Object?>{
            'at': rolloverAt,
            'day': nextDay,
            // 新的一天：今日 / 本周 / 本月 / 热力图按下一个统计日重算（今天的数据自然
            // 落到「昨天」那格）；制卡 / 复习按日表自然落到「昨天」（每日目标清零，
            // 周 / 月目标照算），复习连续天数今天没复习就中断（复习有自己的日界，
            // 这里只是零点前后的近似，app 一开就会重算）。
            ...dayBlocks(
              key: nextDay,
              dayGoals: goals,
              dayReviews: <int>[...reviewsMonth.skip(1), 0],
              dayReviewed: 0,
              srsStreakCurrent: reviewedToday > 0
                  ? _nonNegative(srs.streakCurrent)
                  : 0,
            ),
          },
  };
}

/// `srs.timeline`：只留晚于生成时刻、与前一个计数不同的变化点（「现在」= `srs.due`，
/// 不进数组）。不带生成时刻：否则每次采集签名都变，发布器去重失效。原生侧取
/// `at <= now` 的最后一点，一点都没过就显示 `srs.due`。
List<Map<String, int>> _srsTimelineJson(
  List<WidgetSrsDueStep> steps,
  int generatedAt,
  int due,
) {
  final List<Map<String, int>> out = <Map<String, int>>[];
  int last = due;
  final List<WidgetSrsDueStep> later = <WidgetSrsDueStep>[
    for (final WidgetSrsDueStep s in steps)
      if (s.at > generatedAt) s,
  ]..sort((WidgetSrsDueStep a, WidgetSrsDueStep b) => a.at.compareTo(b.at));
  for (final WidgetSrsDueStep s in later) {
    final int value = _nonNegative(s.due);
    if (value == last) continue;
    last = value;
    out.add(<String, int>{'at': s.at, 'due': value});
  }
  return out;
}

/// 只依赖「哪一天」的块：`today` / `goals` / `week` / `month` / `streak` / `heatmap`。
/// 快照顶层与 `rollover` 共用这一份（零点切换不是第二套算法）。
Map<String, Object?> _dayBlocks({
  required String day,
  required WidgetImmersionInput immersion,
  required WidgetGoalsInput goals,
  required bool fushi,
  required List<int> reviewsMonth,
  required int reviewedToday,
  required int srsStreakCurrent,
  required int srsStreakLongest,
  required Map<WidgetImmersionCategory, String> categoryLabels,
  required String Function(int ms) formatTime,
  required String Function(int chars) formatChars,
  required String Function(int count) formatCount,
  required String Function(String dateKey) weekdayLabel,
}) {
  final List<String> heatKeys = _lastDayKeys(day, kWidgetHeatmapDays);
  final List<String> monthKeys = heatKeys.sublist(
    heatKeys.length - kWidgetMonthDays,
  );
  final List<String> weekKeys = monthKeys.sublist(
    monthKeys.length - kWidgetWeekDays,
  );
  final List<String> prevWeekKeys = _lastDayKeys(
    FushiDatabase.statDateKeyPlusDays(day, -kWidgetWeekDays),
    kWidgetWeekDays,
  );

  final int todayMs = immersion.msOf(day);
  final int todayChars = _nonNegative(immersion.charsByDay[day] ?? 0);
  int sumMs(Iterable<String> keys) =>
      keys.fold<int>(0, (int a, String k) => a + immersion.msOf(k));
  final int weekMs = sumMs(weekKeys);
  final int prevWeekMs = sumMs(prevWeekKeys);
  final int monthMs = sumMs(monthKeys);
  final int weekChars = weekKeys.fold<int>(
    0,
    (int a, String k) => a + _nonNegative(immersion.charsByDay[k] ?? 0),
  );
  // 复习日表（最旧 → [day]）：复习目标的分子（周 / 月目标要往前加）。
  final Map<String, int> reviewsByDay = <String, int>{
    for (int i = 0; i < reviewsMonth.length; i++)
      FushiDatabase.statDateKeyPlusDays(day, i - reviewsMonth.length + 1):
          reviewsMonth[i],
    // 当天以「今日已复习」为准（与复习首页同一个数）。
    day: reviewedToday,
  };
  final List<StudyGoalProgress> goalProgress = computeStudyGoals(
    goals: goals,
    immersion: immersion,
    day: day,
    reviewsByDay: fushi ? reviewsByDay : null,
  );
  // 「今日」卡的两个环（原生侧 `today.goal` / `today.goalMs`）：时长环 = 全部语言的
  // 每日学习时长目标；字数环 = 全部语言的每日字数目标，没有就取第一个每日字数目标。
  final StudyGoalProgress? timeRing = _firstWhereOrNull(
    goalProgress,
    (StudyGoalProgress g) =>
        g.id == StudyGoalId.total &&
        g.goal.period == StudyGoalPeriod.daily &&
        g.goal.language == null,
  );
  bool dailyChars(StudyGoalProgress g) =>
      g.id == StudyGoalId.chars && g.goal.period == StudyGoalPeriod.daily;
  final StudyGoalProgress? charsRing =
      _firstWhereOrNull(
        goalProgress,
        (StudyGoalProgress g) => dailyChars(g) && g.goal.language == null,
      ) ??
      _firstWhereOrNull(goalProgress, dailyChars);
  final int currentStreak = computeCurrentStreak(immersion.activeDays, day);
  bool activeOn(String key) =>
      immersion.activeDays.contains(key) || immersion.msOf(key) > 0;

  final int goalMs = timeRing?.target ?? 0;
  final double? deltaPct = prevWeekMs == 0
      ? null
      : computeWeekOverWeekPercent(weekMs, prevWeekMs);

  return <String, Object?>{
    'today': <String, Object?>{
      'time': formatTime(todayMs),
      'chars': formatChars(todayChars),
      'goal': charsRing?.fraction ?? 0,
      'streak': currentStreak,
      'totalMs': todayMs,
      'categories': <Map<String, Object?>>[
        for (final WidgetImmersionCategory c in WidgetImmersionCategory.values)
          <String, Object?>{
            'id': c.wire,
            'label': categoryLabels[c] ?? '',
            'ms': immersion.msOf(day, c),
            'time': formatTime(immersion.msOf(day, c)),
            'link': c.tab.link,
          },
      ],
      'goalMs': goalMs,
      'goalTime': goalMs > 0 ? formatTime(goalMs) : '',
      'goalFrac': goalMs > 0 ? clampWidgetFraction(todayMs / goalMs) : 0,
    },
    'goals': _goalsJson(
      progress: goalProgress,
      goals: goals,
      formatTime: formatTime,
      formatChars: formatChars,
      formatCount: formatCount,
    ),
    'week': <String, Object?>{
      'minutes': <int>[
        for (final String k in weekKeys) immersion.msOf(k) ~/ 60000,
      ],
      'days': <String>[for (final String k in weekKeys) weekdayLabel(k)],
      'time': formatTime(weekMs),
      'chars': formatChars(weekChars),
      'prevTime': formatTime(prevWeekMs),
      'deltaPct': deltaPct?.round(),
      'reviews': fushi
          ? reviewsMonth
                .sublist(reviewsMonth.length - kWidgetWeekDays)
                .fold<int>(0, (int a, int b) => a + b)
          : null,
      'goalDays': goalMs > 0
          ? weekKeys.where((String k) => immersion.msOf(k) >= goalMs).length
          : null,
    },
    'month': <String, Object?>{
      'minutes': <int>[
        for (final String k in monthKeys) immersion.msOf(k) ~/ 60000,
      ],
      'reviews': fushi ? reviewsMonth : null,
      'time': formatTime(monthMs),
      'activeDays': monthKeys.where(activeOn).length,
      'firstWeekday': _isoWeekday(monthKeys.first),
      'weekStart': StatWindow.weekStartDay,
    },
    'streak': <String, Object?>{
      'current': currentStreak,
      'longest': computeLongestStreak(immersion.activeDays),
      'srsCurrent': fushi ? srsStreakCurrent : null,
      'srsLongest': fushi ? srsStreakLongest : null,
      'week': <bool>[for (final String k in weekKeys) activeOn(k)],
    },
    'heatmap': <String, Object?>{
      'levels': <int>[
        for (final String k in heatKeys)
          widgetHeatLevel(immersion.msOf(k), active: activeOn(k)),
      ],
      'firstWeekday': _isoWeekday(heatKeys.first),
      'weekStart': StatWindow.weekStartDay,
      'time': formatTime(sumMs(heatKeys)),
      'activeDays': heatKeys.where(activeOn).length,
    },
  };
}

/// 一条目标记录在某一天的进度。时长类的 [value] / [target] 是毫秒，其余是条数 / 字数。
class StudyGoalProgress {
  const StudyGoalProgress({
    required this.goal,
    required this.value,
    required this.target,
    this.restDay = false,
    int? todayValue,
    int? todayShare,
    this.todayRest = false,
    this.pace = 0,
    this.periodDaysLeft = 0,
    this.days = const <StudyGoalDay>[],
  }) : todayValue = todayValue ?? value,
       todayShare = todayShare ?? target;

  final StudyGoal goal;
  final int value;
  final int target;

  /// 每日目标限定了生效日、这天不在其中：照常显示进度，但不算欠着（标签带「休息日」）。
  /// 周 / 月目标恒 false（周期本身不休息；今天休息看 [todayRest]）。
  final bool restDay;

  /// 今天做了多少（与 [value] 同单位、同语言过滤）。每日目标 = [value]。
  final int todayValue;

  /// 今天该做多少（与 [value] 同单位）。每日目标 = [target]；周 / 月目标 =
  /// `ceil(max(0, 目标 − 今天之前已做) / 今天起剩下的生效日)`，今天不是生效日或周期
  /// 目标已达成时为 0。时长向上取整到整分钟。漏掉的日子会抬高后面的份额，多做会压低。
  final int todayShare;

  /// 今天不是这条目标的生效日（任何周期；周 / 月目标今日份额因此为 0）。
  final bool todayRest;

  /// 周 / 月目标的进度差：周期已做 − 按生效日线性摊到今天结束时应做的量（与 [value]
  /// 同单位）。正 = 超前，负 = 落后。每日目标恒 0。
  final int pace;

  /// 周 / 月目标从今天（含）到周期末还剩几个生效日（今天不生效则不算今天）。每日为 0。
  final int periodDaysLeft;

  /// 周 / 月目标「本周」的逐日数据（本周起始日起 7 格，见 [StatWindow.weekStartOf]）：
  /// 首页「今日」格的柱条。每日目标为空。
  final List<StudyGoalDay> days;

  /// 周 / 月目标：要按天摊「今日份额」。
  bool get splitsPeriod => goal.period != StudyGoalPeriod.daily;

  /// 周期目标已达成（周 / 月目标今天不用再做）。
  bool get periodReached => target > 0 && value >= target;

  /// 今天这一环的完成比例（封顶 1）。份额为 0（休息日 / 周期已达成）时：周期达成 = 满，
  /// 否则 0。
  double get todayFraction {
    if (todayShare <= 0) return periodReached ? 1 : 0;
    return clampWidgetFraction(todayValue / todayShare);
  }

  /// 今天这一环的状态：周期已达成 = 完成；休息日 = 休息；否则按今日量对份额。
  StudyGoalState get todayState {
    if (!splitsPeriod) return state;
    if (periodReached) return StudyGoalState.completed;
    if (todayRest) return StudyGoalState.restDay;
    if (todayShare > 0 && todayValue > todayShare) {
      return StudyGoalState.exceeded;
    }
    if (todayValue >= todayShare) return StudyGoalState.completed;
    if (todayValue <= 0) return StudyGoalState.notStarted;
    return StudyGoalState.inProgress;
  }

  /// 进度差的三档：差距不超过目标的 5% 算「按计划」。每日目标恒按计划。
  StudyGoalPace get paceStatus {
    if (!splitsPeriod || pace.abs() * 20 <= target) {
      return StudyGoalPace.onTrack;
    }
    return pace > 0 ? StudyGoalPace.ahead : StudyGoalPace.behind;
  }

  StudyGoalId get id => goal.metric;
  double get fraction => target <= 0 ? 0 : clampWidgetFraction(value / target);
  bool get done => value >= target;

  /// 完成百分比，**向下取整**并封顶 100：没完成时永远 ≤ 99（99.8% 不显示成 100%）。
  int get percent {
    if (target <= 0) return 0;
    if (value >= target) return 100;
    return (value * 100 ~/ target).clamp(0, 99);
  }

  /// 还差多少（与 [value] 同单位）；完成了为 0。
  int get remaining => value >= target ? 0 : target - value;

  /// 超出多少（与 [value] 同单位）；没超为 0。
  int get excess => value > target ? value - target : 0;

  /// 这一天的状态。休息日只在**没完成**时生效（休息日照样完成了就算完成）。
  StudyGoalState get state {
    if (target > 0 && value > target) return StudyGoalState.exceeded;
    if (value >= target) return StudyGoalState.completed;
    if (restDay) return StudyGoalState.restDay;
    if (value <= 0) return StudyGoalState.notStarted;
    return StudyGoalState.inProgress;
  }
}

/// 周 / 月目标的进度差三档（[StudyGoalProgress.paceStatus]；wire = 枚举名，进快照）。
enum StudyGoalPace {
  onTrack,
  behind,
  ahead;

  String get wire => name;
}

/// 周 / 月目标「本周」里的一天（[StudyGoalProgress.days]）。
class StudyGoalDay {
  const StudyGoalDay({
    required this.dayKey,
    required this.value,
    required this.share,
    required this.active,
    required this.inPeriod,
    required this.isToday,
    required this.future,
  });

  /// 统计日 key。
  final String dayKey;

  /// 这一天做了多少（与目标同单位；今天之后为 0）。
  final int value;

  /// 这一天的份额：过去的日子 = **当天**算出的份额（由那天之前已做多少决定），今天 =
  /// 今日份额，之后的日子 = 按今天结束时的进度把剩余量摊给剩下生效日的预估。不生效 /
  /// 不在周期里 = 0。
  final int share;

  /// 生效日（且在周期里）。
  final bool active;

  /// 在目标周期里（月目标的「本周」可能跨月：跨出去的日子为 false）。
  final bool inPeriod;
  final bool isToday;
  final bool future;
}

/// 一条目标在某一天的状态（小组件 / 设置 / 首页共用；wire = 枚举名，进快照）。
enum StudyGoalState {
  notStarted,
  inProgress,
  completed,
  exceeded,
  restDay;

  String get wire => name;

  /// 完成或超额（环画勾）。
  bool get reached =>
      this == StudyGoalState.completed || this == StudyGoalState.exceeded;
}

/// 一条目标进度的紧凑文案（纯数据；i18n 装配在 `study_goals.dart`）。系统小组件与
/// 设置行共用，同一条目标几处写法一致。
class StudyGoalCompactText {
  const StudyGoalCompactText({
    required this.language,
    required this.metric,
    required this.period,
    required this.caption,
    required this.value,
    required this.target,
    required this.status,
    required this.remaining,
    this.todayValue = '',
    this.todayShare = '',
    this.todayLine = '',
    this.todayShort = '',
    this.periodLine = '',
    this.pace = '',
    this.daysLeft = '',
  });

  /// 语言名；全部语言的目标是「全部语言」；不分语言的度量（制卡 / 复习）为空串。
  final String language;

  /// 度量名（「字数」「词数」「阅读」「制卡」…，文字目标的单位体现在这里）。
  final String metric;

  /// 周期短名（「周」「月」）；每日为空串。
  final String period;

  /// 「度量 · 周期」（每日只有度量）：「字数 · 周」。
  final String caption;

  /// 已完成量的紧凑写法，不带单位（「14.8K」「1h 36m」）。
  final String value;

  /// 目标量的紧凑写法，不带单位（「10K」「30m」）。
  final String target;

  /// 状态短句：「已完成」/「还差 400」/「+4.8K」/「休息日」。
  final String status;

  /// 剩余量的紧凑写法（「400」「24m」）；完成了为空串。
  final String remaining;

  /// 周 / 月目标今天做了多少的紧凑写法（「12」）；每日目标为空串。
  final String todayValue;

  /// 周 / 月目标的今日份额（「20」）；每日目标为空串。
  final String todayShare;

  /// 周 / 月目标「今天」一行，最短能读懂的写法：「12 / 20 today · On track」、
  /// 「Rest day · 40 behind」、「Week done」。每日目标为空串。首页小格、总览行、
  /// 语言目标格、设置行与系统小组件共用。
  final String todayLine;

  /// [todayLine] 去掉进度差的短写法：「12 / 20 today」/「Rest day」/「Week done」
  /// （窄处放不下整行时用）。每日目标为空串。
  final String todayShort;

  /// 周 / 月目标的周期一行：「Week 99 / 100 · 3 days left」（周期已达成不写剩余天数）。
  /// 每日目标为空串。
  final String periodLine;

  /// 进度差短句：「On track」/「40 behind」/「Ahead by 15」。每日目标为空串。
  final String pace;

  /// 剩余生效日：「3 days left」。每日目标为空串。
  final String daysLeft;

  /// 「14.8K / 10K」。
  String get valueTarget => '$value / $target';

  /// 「12 / 20」（周 / 月目标的今日量 / 今日份额）。
  String get todayPair => '$todayValue / $todayShare';
}

T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T item) test) {
  for (final T item in items) {
    if (test(item)) return item;
  }
  return null;
}

/// [byDay] 在 [period] 包含 [day] 的窗口里的合计（负数按 0）。
int _sumWindow(Map<String, int> byDay, StudyGoalPeriod period, String day) {
  int total = 0;
  byDay.forEach((String k, int v) {
    if (studyGoalWindowContains(period, day, k)) total += _nonNegative(v);
  });
  return total;
}

/// [goal] 在 [day]（统计日 key）的分子：时长 = 毫秒、字数、复习数、制卡数。窗口按
/// 目标周期（[studyGoalWindowStart]），字数与时长按目标语言过滤
/// （[WidgetGoalsInput.immersionFor]）。[reviewsByDay] 为 null = 复习数不可得。
int studyGoalNumerator({
  required StudyGoal goal,
  required WidgetGoalsInput goals,
  required WidgetImmersionInput immersion,
  required String day,
  required Map<String, int>? reviewsByDay,
}) {
  final WidgetImmersionInput source = goals.immersionFor(goal, immersion);
  int sumMs([WidgetImmersionCategory? category]) {
    int total = 0;
    for (final String k in source.msByDay.keys) {
      if (studyGoalWindowContains(goal.period, day, k)) {
        total += source.msOf(k, category);
      }
    }
    return total;
  }

  return switch (goal.metric) {
    StudyGoalId.total => sumMs(),
    StudyGoalId.reading => sumMs(WidgetImmersionCategory.reading),
    StudyGoalId.listening => sumMs(WidgetImmersionCategory.listening),
    StudyGoalId.watching => sumMs(WidgetImmersionCategory.watching),
    StudyGoalId.chars => _sumWindow(source.charsByDay, goal.period, day),
    StudyGoalId.mined => _sumWindow(goals.minedByDay, goal.period, day),
    StudyGoalId.reviews => _sumWindow(
      reviewsByDay ?? const <String, int>{},
      goal.period,
      day,
    ),
  };
}

/// 每条目标记录在 [day] 的进度，顺序 = 记录顺序。**小组件「目标」卡与首页「今日」格
/// 共用这一份**：两处各算一遍迟早对不上。[reviewsByDay] 为 null = 复习不是内置 SRS
/// （Anki 的 API 没有复习数），复习目标不出现。
List<StudyGoalProgress> computeStudyGoals({
  required WidgetGoalsInput goals,
  required WidgetImmersionInput immersion,
  required String day,
  required Map<String, int>? reviewsByDay,
}) {
  const int minute = 60000;
  final List<StudyGoalProgress> out = <StudyGoalProgress>[];
  for (final StudyGoal g in goals.goals) {
    if (g.metric == StudyGoalId.reviews && reviewsByDay == null) continue;
    final int value = studyGoalNumerator(
      goal: g,
      goals: goals,
      immersion: immersion,
      day: day,
      reviewsByDay: reviewsByDay,
    );
    final int target = g.metric.isTime ? g.target * minute : g.target;
    if (g.period == StudyGoalPeriod.daily) {
      out.add(
        StudyGoalProgress(
          goal: g,
          value: value,
          target: target,
          restDay: g.isRestDay(day),
          todayRest: g.isRestDay(day),
        ),
      );
      continue;
    }
    final StudyGoal daily = g.copyWith(period: StudyGoalPeriod.daily);
    out.add(
      _splitPeriodGoal(
        goal: g,
        value: value,
        target: target,
        day: day,
        dayValue: (String key) => studyGoalNumerator(
          goal: daily,
          goals: goals,
          immersion: immersion,
          day: key,
          reviewsByDay: reviewsByDay,
        ),
      ),
    );
  }
  return out;
}

/// 周 / 月目标按生效日摊开：今日量 / 今日份额 / 进度差 / 剩余生效日 / 本周逐日。
/// [dayValue] = 某一天的单日量（与 [value] 同一套分子）。
StudyGoalProgress _splitPeriodGoal({
  required StudyGoal goal,
  required int value,
  required int target,
  required String day,
  required int Function(String key) dayValue,
}) {
  final int unit = goal.metric.isTime ? 60000 : 1;
  final List<String> window = studyGoalWindowDays(goal.period, day);
  final List<bool> active = <bool>[
    for (final String k in window) goal.isActiveOn(k),
  ];
  final List<int> amounts = <int>[
    for (final String k in window) k.compareTo(day) > 0 ? 0 : dayValue(k),
  ];
  final int todayIndex = window.indexOf(day);

  /// 份额：剩余量摊给 [from] 起（含）的生效日，向上取整（时长到整分钟）。
  int shareFrom(int from, int doneBefore) {
    final int rest = target - doneBefore;
    if (rest <= 0) return 0;
    int left = 0;
    for (int i = from; i < window.length; i++) {
      if (active[i]) left++;
    }
    if (left == 0) return 0;
    final int per = left * unit;
    return (rest + per - 1) ~/ per * unit;
  }

  final Map<String, int> shares = <String, int>{};
  int doneBefore = 0;
  for (int i = 0; i <= todayIndex; i++) {
    shares[window[i]] = active[i] ? shareFrom(i, doneBefore) : 0;
    doneBefore += amounts[i];
  }
  // 今天之后：按今天结束时的进度预估（今天多做 / 少做都会反映出来）。
  final int projected = shareFrom(todayIndex + 1, doneBefore);
  for (int i = todayIndex + 1; i < window.length; i++) {
    shares[window[i]] = active[i] ? projected : 0;
  }

  final int activeTotal = active.where((bool a) => a).length;
  int activeElapsed = 0;
  int daysLeft = 0;
  for (int i = 0; i < window.length; i++) {
    if (!active[i]) continue;
    if (i <= todayIndex) activeElapsed++;
    if (i >= todayIndex) daysLeft++;
  }
  final int expected = activeTotal == 0
      ? target
      : target * activeElapsed ~/ activeTotal;

  final Map<String, int> amountOf = <String, int>{
    for (int i = 0; i < window.length; i++) window[i]: amounts[i],
  };
  final String weekStart = StatWindow.weekStartOf(day);
  final List<StudyGoalDay> days = <StudyGoalDay>[];
  for (int i = 0; i < 7; i++) {
    final String k = FushiDatabase.statDateKeyPlusDays(weekStart, i);
    final bool inPeriod = shares.containsKey(k);
    days.add(
      StudyGoalDay(
        dayKey: k,
        value: amountOf[k] ?? 0,
        share: shares[k] ?? 0,
        active: inPeriod && goal.isActiveOn(k),
        inPeriod: inPeriod,
        isToday: k == day,
        future: k.compareTo(day) > 0,
      ),
    );
  }

  return StudyGoalProgress(
    goal: goal,
    value: value,
    target: target,
    todayValue: todayIndex < 0 ? 0 : amounts[todayIndex],
    todayShare: shares[day] ?? 0,
    todayRest: !goal.isActiveOn(day),
    pace: value - expected,
    periodDaysLeft: daysLeft,
    days: days,
  );
}

/// [goal] 在 [dayKeys] 每一天的**单日**量（与目标同一个度量、同一种语言、同一套
/// 分子：时长 = 毫秒、字数、复习数、制卡数）。周 / 月目标也按天给（首页「今日」格的
/// 近 7 天柱条跟着当前目标走）。[reviewsByDay] 为 null = 复习数不可得（全 0）。
List<int> studyGoalDailySeries({
  required StudyGoal goal,
  required WidgetGoalsInput goals,
  required WidgetImmersionInput immersion,
  required List<String> dayKeys,
  required Map<String, int>? reviewsByDay,
}) {
  final StudyGoal daily = goal.period == StudyGoalPeriod.daily
      ? goal
      : goal.copyWith(period: StudyGoalPeriod.daily);
  return <int>[
    for (final String day in dayKeys)
      studyGoalNumerator(
        goal: daily,
        goals: goals,
        immersion: immersion,
        day: day,
        reviewsByDay: reviewsByDay,
      ),
  ];
}

/// [goal] 摊到一天的目标量（与 [studyGoalDailySeries] 同单位：时长 = 毫秒）：每日 =
/// 目标本身，每周 = 目标 / 7，每月 = 目标 / 包含 [day] 的那个月的天数。柱条的参考线。
double studyGoalDailyShare(StudyGoal goal, String day) {
  final int target = goal.metric.isTime ? goal.target * 60000 : goal.target;
  return switch (goal.period) {
    StudyGoalPeriod.daily => target.toDouble(),
    StudyGoalPeriod.weekly => target / 7,
    StudyGoalPeriod.monthly => target / _daysInMonthOf(day),
  };
}

int _daysInMonthOf(String dateKey) {
  final DateTime d = FushiDatabase.statDateKeyToDay(dateKey);
  return DateTime(d.year, d.month + 1, 0).day;
}

List<Map<String, Object?>> _goalsJson({
  required List<StudyGoalProgress> progress,
  required WidgetGoalsInput goals,
  required String Function(int ms) formatTime,
  required String Function(int chars) formatChars,
  required String Function(int count) formatCount,
}) {
  return <Map<String, Object?>>[
    for (final StudyGoalProgress g in progress)
      () {
        final String Function(int) format = switch (g.id) {
          _ when g.id.isTime => formatTime,
          StudyGoalId.chars when goals.unitOf(g.goal) == StudyGoalUnit.words =>
            goals.formatWords ?? formatChars,
          StudyGoalId.chars => formatChars,
          _ => formatCount,
        };
        final StudyGoalCompactText? text = goals.compactOf?.call(g);
        return <String, Object?>{
          'id': g.id.wire,
          'label': goals.labelOf?.call(g.goal, restDay: g.restDay) ?? '',
          'value': format(g.value),
          'target': format(g.target),
          'frac': g.fraction,
          'done': g.done,
          // v2 紧凑字段（旧字段保留给已装的旧原生侧）：语言 / 度量 / 周期分开，
          // 数值对不重复单位，状态与剩余量由这里定，原生侧不重算。
          'period': g.goal.period.wire,
          'language': text?.language ?? '',
          'metric': text?.metric ?? '',
          'periodLabel': text?.period ?? '',
          'caption': text?.caption ?? '',
          'compact':
              text?.valueTarget ?? '${format(g.value)} / ${format(g.target)}',
          'valueShort': text?.value ?? format(g.value),
          'targetShort': text?.target ?? format(g.target),
          'state': g.state.wire,
          'status': text?.status ?? '',
          'remaining': text?.remaining ?? '',
          'pct': g.percent,
          // v3「今日份额」字段（周 / 月目标按生效日摊开；每日目标 splits = false，
          // 文案为空串）。原生侧只显示，不重算。
          'splits': g.splitsPeriod,
          'todayFrac': g.todayFraction,
          'todayState': g.todayState.wire,
          'todayValue': text?.todayValue ?? format(g.todayValue),
          'todayShare': text?.todayShare ?? format(g.todayShare),
          'todayLine': text?.todayLine ?? '',
          'todayShort': text?.todayShort ?? '',
          'periodLine': text?.periodLine ?? '',
          'pace': g.paceStatus.wire,
          'paceText': text?.pace ?? '',
          'daysLeft': g.periodDaysLeft,
          'daysLeftText': text?.daysLeft ?? '',
        };
      }(),
  ];
}

List<Map<String, Object?>> _vocabJson(List<WidgetVocabInput> vocab) {
  final List<WidgetVocabInput> items = <WidgetVocabInput>[
    for (final WidgetVocabInput v in vocab)
      if (v.term.trim().isNotEmpty) v,
  ];
  final List<int> order = <int>[for (int i = 0; i < items.length; i++) i]
    ..sort((int a, int b) {
      final int byTime = items[b].createdAt.compareTo(items[a].createdAt);
      return byTime != 0 ? byTime : a.compareTo(b);
    });
  final Set<String> seen = <String>{};
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  for (final int i in order) {
    final WidgetVocabInput v = items[i];
    // 同一个词既制卡又收藏只展示一次（取最新的那条）。
    if (!seen.add('${v.term.trim()}\u0000${v.reading.trim()}')) continue;
    out.add(<String, Object?>{
      'term': v.term.trim(),
      'reading': v.reading.trim(),
      'definition': widgetPlainText(v.definition),
      'sentence': widgetPlainText(v.sentence),
      'source': v.source.trim(),
      'origin': v.origin == 'favorite' ? 'favorite' : 'mined',
    });
    if (out.length >= kWidgetVocabLimit) break;
  }
  return out;
}

Map<String, Object?> _mediaJson(
  WidgetMediaInput m,
  String Function(int epochMs) formatAge,
  String Function(int ms)? formatTimeLeft,
) {
  final double progress = clampWidgetFraction(m.progress);
  final int? left = m.remainingMs;
  return <String, Object?>{
    'kind': m.kind.wire,
    'id': m.id,
    'link': m.link.isNotEmpty
        ? m.link
        : WidgetContinueLink(kind: m.kind, id: m.id).toUri(),
    'title': m.title.trim(),
    'subtitle': m.subtitle.trim(),
    'progress': progress,
    'cover': m.coverPath,
    'position': progress > 0 ? '${(progress * 100).round()}%' : '',
    'lastActive': m.recentAt > 0 ? formatAge(m.recentAt) : '',
    'remaining': left != null && left > 0 && formatTimeLeft != null
        ? formatTimeLeft(left)
        : '',
  };
}

int _nonNegative(int value) => value < 0 ? 0 : value;

/// 含 [endKey] 在内最近 [n] 个统计日 key，升序（纯 key 算术）。
List<String> _lastDayKeys(String endKey, int n) => <String>[
  for (int i = n - 1; i >= 0; i--)
    FushiDatabase.statDateKeyPlusDays(endKey, -i),
];

/// ISO 星期（周一 = 1）。统计日 key → 日历日只用于求星期几。
int _isoWeekday(String dateKey) {
  try {
    return FushiDatabase.statDateKeyToDay(dateKey).weekday;
  } on FormatException {
    return 1;
  }
}

List<T> _fitTo<T>(List<T> values, int length, T filler) {
  if (values.length >= length) {
    return values.sublist(values.length - length);
  }
  return <T>[for (int i = values.length; i < length; i++) filler, ...values];
}

/// 有桌面小组件原生侧的平台：Android（Glance）、iOS / macOS（WidgetKit 扩展）。
bool widgetSnapshotPlatformSupported() =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

/// 去重签名：不含 `generatedAt`，也不含 `nowPlaying` 的进度 / 取样时刻（播放中它们
/// 每次采集都变，原生侧靠它们外推，不该因此重发）。曲目、播放 / 暂停、封面等变了仍
/// 会改变签名。
String widgetSnapshotSignature(Map<String, Object?> snapshot) {
  final Object? playing = snapshot['nowPlaying'];
  return jsonEncode(<String, Object?>{
    for (final MapEntry<String, Object?> e in snapshot.entries)
      if (e.key == 'nowPlaying' && playing is Map<String, Object?>)
        e.key: <String, Object?>{
          for (final MapEntry<String, Object?> n in playing.entries)
            if (n.key != 'positionMs' && n.key != 'updatedAt') n.key: n.value,
        }
      else if (e.key != 'generatedAt')
        e.key: e.value,
  });
}

/// 把快照 JSON 发给原生侧（Android Glance 小组件 / iOS·macOS WidgetKit 小组件）。
/// 只在这三个平台生效，其余平台 no-op；原生侧存下来并重绘小组件。
///
/// 两端吃**同一份** JSON、同一个 `updateSnapshot` 方法：Android 见
/// `widgets/WidgetChannel.kt`；Apple 见 `fushi/apple/HomeWidgets/FushiHomeWidgets.swift`
/// （主 app 进程里把 JSON 与 `cover` 指向的本机封面缩略后写进 App Group，扩展进程读不到
/// app 沙盒）。
///
/// 调用方可以随便高频调，本类按 JSON 签名去重（签名**不含** `generatedAt`，否则
/// 每次采集都不同），数据没变就不过通道；但距上次真正发送超过 [refreshInterval]
/// 时即使没变也重发一次，让原生侧的 `generatedAt`（「更新于 N 前」）不无限变旧。
class WidgetSnapshotPublisher {
  @visibleForTesting
  WidgetSnapshotPublisher({
    required this.platformSupported,
    MethodChannel channel = FushiChannels.widgets,
    DateTime Function()? now,
    this.refreshInterval = const Duration(minutes: 10),
  }) : _channel = channel,
       _now = now ?? DateTime.now;

  static final WidgetSnapshotPublisher instance = WidgetSnapshotPublisher(
    platformSupported: widgetSnapshotPlatformSupported(),
  );

  /// 只有 Android / iOS / macOS 有原生侧；其余平台发了也是 MissingPluginException。
  final bool platformSupported;

  final Duration refreshInterval;
  final MethodChannel _channel;
  final DateTime Function() _now;

  String? _lastSignature;
  DateTime? _lastSentAt;

  /// 签名没变（且未到 [refreshInterval]）/ 平台不支持时直接返回；否则返回的 Future
  /// 在原生侧应答（或失败）后完成，调用方可以不等。
  Future<void> publish(Map<String, Object?> snapshot) async {
    if (!platformSupported) return;
    final String signature = widgetSnapshotSignature(snapshot);
    final DateTime now = _now();
    final DateTime? sentAt = _lastSentAt;
    if (signature == _lastSignature &&
        sentAt != null &&
        now.difference(sentAt) < refreshInterval) {
      return;
    }
    _lastSignature = signature;
    _lastSentAt = now;
    try {
      await _channel.invokeMethod<void>('updateSnapshot', jsonEncode(snapshot));
    } on Object catch (error) {
      // 发布失败只影响小组件，不影响 app 本身；清掉签名让下一次触发重试。
      if (_lastSignature == signature) {
        _lastSignature = null;
        _lastSentAt = null;
      }
      debugPrint('WidgetSnapshotPublisher: updateSnapshot failed: $error');
    }
  }
}
