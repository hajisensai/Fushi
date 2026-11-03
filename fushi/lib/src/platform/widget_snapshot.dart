import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

import 'package:fushi/src/pages/implementations/stat_summary.dart'
    show computeWeekOverWeekPercent;
import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// 快照契约版本（见 docs/agent/android-widgets.md）。
const int kWidgetSnapshotVersion = 2;

/// 快照里最多带几张「书架」卡（含「继续」那张）。
const int kWidgetShelfLimit = 4;

/// 周图表的天数（最旧 → 今天）。
const int kWidgetWeekDays = 7;

/// 月热力图的天数（5 行 × 7，最旧 → 今天）。
const int kWidgetMonthDays = 35;

/// 每日词汇最多带几条。
const int kWidgetVocabLimit = 12;

/// 词汇释义纯文本的最大长度（码点）。
const int kWidgetDefinitionMaxChars = 200;

/// 快照 `labels` 的**全部**键（稳定契约，改名要和原生侧 `WidgetSnapshot.kt` 同步）。
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
  });

  final WidgetMediaKind kind;

  /// 书 / 漫画 = `MediaItem.mediaIdentifier`，视频 = `VideoBookRow.bookUid`。
  final String id;
  final String title;

  /// 作者；没有就空串。
  final String subtitle;

  /// 进度分数；越界或 NaN 由 [buildWidgetSnapshot] 夹到 0..1。
  final double progress;

  /// 本机封面图文件的绝对路径；调用方已确认存在、可读，不确定就传空串。
  final String coverPath;

  /// 最近活动时刻（epoch 毫秒），排序与「几小时前」用；0 = 未知。
  final int recentAt;
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

/// 每日目标（<= 0 = 没设）与「今日制卡数」。
class WidgetGoalsInput {
  const WidgetGoalsInput({
    this.totalMinutes = 0,
    this.readingMinutes = 0,
    this.listeningMinutes = 0,
    this.videoMinutes = 0,
    this.reviews = 0,
    this.minedCards = 0,
    this.chars = 0,
    this.minedToday = 0,
  });

  final int totalMinutes;
  final int readingMinutes;
  final int listeningMinutes;
  final int videoMinutes;
  final int reviews;
  final int minedCards;
  final int chars;

  /// 今天制了多少张卡（统计口径，见 `StatFacts.minedEvents`）。
  final int minedToday;
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
/// - 复习：provider 为 anki / none 时**不带任何 Fushi 计数**。
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
  Map<WidgetImmersionCategory, String> categoryLabels =
      const <WidgetImmersionCategory, String>{},
  Map<String, String> goalLabels = const <String, String>{},
  String profileName = '',
  bool multiProfile = false,
  bool hideTitles = false,
  bool hideDefinitions = false,
  bool hideProfile = false,
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
      _mediaJson(visible[i], formatAge),
  ];

  final List<String> monthKeys = _lastDayKeys(day, kWidgetMonthDays);
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
  final int currentStreak = computeCurrentStreak(immersion.activeDays, day);
  bool activeOn(String key) =>
      immersion.activeDays.contains(key) || immersion.msOf(key) > 0;

  final int goalMs = _nonNegative(goals.totalMinutes) * 60000;
  final double? deltaPct = prevWeekMs == 0
      ? null
      : computeWeekOverWeekPercent(weekMs, prevWeekMs);

  final bool fushi = srs.provider == WidgetSrsProvider.fushi;
  final List<int> reviewsMonth = _fitTo<int>(
    <int>[for (final int r in srs.reviewsByDay) _nonNegative(r)],
    kWidgetMonthDays,
    0,
  );
  final int reviewedToday = fushi ? _nonNegative(srs.reviewedToday) : 0;

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
    'today': <String, Object?>{
      'time': formatTime(todayMs),
      'chars': formatChars(todayChars),
      'goal': goals.chars > 0
          ? clampWidgetFraction(todayChars / goals.chars)
          : 0,
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
      goals: goals,
      immersion: immersion,
      day: day,
      reviewedToday: fushi ? reviewedToday : null,
      todayChars: todayChars,
      labels: goalLabels,
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
    },
    'streak': <String, Object?>{
      'current': currentStreak,
      'longest': computeLongestStreak(immersion.activeDays),
      'srsCurrent': fushi ? _nonNegative(srs.streakCurrent) : null,
      'srsLongest': fushi ? _nonNegative(srs.streakLongest) : null,
      'week': <bool>[for (final String k in weekKeys) activeOn(k)],
    },
    'srs': <String, Object?>{
      'provider': srs.provider.wire,
      'label': srs.label,
      'enabled': fushi,
      'due': fushi
          ? _nonNegative(srs.newCount) +
                _nonNegative(srs.learnCount) +
                _nonNegative(srs.reviewCount)
          : 0,
      if (fushi) ...<String, Object?>{
        'new': _nonNegative(srs.newCount),
        'learn': _nonNegative(srs.learnCount),
        'review': _nonNegative(srs.reviewCount),
        'reviewedToday': reviewedToday,
        'dueTomorrow': _nonNegative(srs.dueTomorrow),
      },
      if (srs.provider == WidgetSrsProvider.anki)
        'ankiPackage': srs.ankiPackage,
    },
    'vocab': _vocabJson(vocab),
  };
}

List<Map<String, Object?>> _goalsJson({
  required WidgetGoalsInput goals,
  required WidgetImmersionInput immersion,
  required String day,
  required int? reviewedToday,
  required int todayChars,
  required Map<String, String> labels,
  required String Function(int ms) formatTime,
  required String Function(int chars) formatChars,
  required String Function(int count) formatCount,
}) {
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  void add(
    String id,
    int value,
    int target,
    String Function(int) format, {
    int unit = 1,
  }) {
    if (target <= 0) return;
    final int scaled = target * unit;
    out.add(<String, Object?>{
      'id': id,
      'label': labels[id] ?? '',
      'value': format(value),
      'target': format(scaled),
      'frac': clampWidgetFraction(value / scaled),
      'done': value >= scaled,
    });
  }

  add(
    'total',
    immersion.msOf(day),
    goals.totalMinutes,
    formatTime,
    unit: 60000,
  );
  add(
    'reading',
    immersion.msOf(day, WidgetImmersionCategory.reading),
    goals.readingMinutes,
    formatTime,
    unit: 60000,
  );
  add(
    'listening',
    immersion.msOf(day, WidgetImmersionCategory.listening),
    goals.listeningMinutes,
    formatTime,
    unit: 60000,
  );
  add(
    'watching',
    immersion.msOf(day, WidgetImmersionCategory.watching),
    goals.videoMinutes,
    formatTime,
    unit: 60000,
  );
  // 复习目标只在内置 SRS 时有今日已复习数；Anki 的 API 没有这个数，宁可不画。
  if (reviewedToday != null) {
    add('reviews', reviewedToday, goals.reviews, formatCount);
  }
  add('mined', _nonNegative(goals.minedToday), goals.minedCards, formatCount);
  add('chars', todayChars, goals.chars, formatChars);
  return out;
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
) {
  final double progress = clampWidgetFraction(m.progress);
  return <String, Object?>{
    'kind': m.kind.wire,
    'id': m.id,
    'title': m.title.trim(),
    'subtitle': m.subtitle.trim(),
    'progress': progress,
    'cover': m.coverPath,
    'position': progress > 0 ? '${(progress * 100).round()}%' : '',
    'lastActive': m.recentAt > 0 ? formatAge(m.recentAt) : '',
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

/// 把快照 JSON 发给原生侧（Android 桌面小组件）。只在 Android 上生效，其余平台
/// no-op；原生侧存下来并重绘小组件。
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
    platformSupported: !kIsWeb && Platform.isAndroid,
  );

  /// 只有 Android 有原生侧；其余平台发了也是 MissingPluginException。
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
    final String signature = jsonEncode(<String, Object?>{
      for (final MapEntry<String, Object?> e in snapshot.entries)
        if (e.key != 'generatedAt') e.key: e.value,
    });
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
