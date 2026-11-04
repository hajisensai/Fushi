import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

import 'package:fushi/src/pages/implementations/stat_summary.dart'
    show computeWeekOverWeekPercent;
import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/platform/widget_progress.dart';
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

/// (from, to] 里第一个 [dayIndexOf] 比 from 大的时刻（分钟精度）；区间内不换日为 null。
int? _nextSrsDayBoundary(int from, int to, int Function(int ms) dayIndexOf) {
  final int today = dayIndexOf(from);
  if (dayIndexOf(to) <= today) return null;
  int lo = from;
  int hi = to;
  const int minute = 60 * 1000;
  while (hi - lo > minute) {
    final int mid = lo + (hi - lo) ~/ 2;
    if (dayIndexOf(mid) > today) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return hi;
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
  Map<String, String> goalLabels = const <String, String>{},
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
    goalLabels: goalLabels,
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
            // 落到「昨天」那格）；制卡 / 复习的「今日」计数清零，复习连续天数今天没复习
            // 就中断（复习有自己的日界，这里只是零点前后的近似，app 一开就会重算）。
            ...dayBlocks(
              key: nextDay,
              dayGoals: WidgetGoalsInput(
                totalMinutes: goals.totalMinutes,
                readingMinutes: goals.readingMinutes,
                listeningMinutes: goals.listeningMinutes,
                videoMinutes: goals.videoMinutes,
                reviews: goals.reviews,
                minedCards: goals.minedCards,
                chars: goals.chars,
              ),
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
  required Map<String, String> goalLabels,
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
  final int currentStreak = computeCurrentStreak(immersion.activeDays, day);
  bool activeOn(String key) =>
      immersion.activeDays.contains(key) || immersion.msOf(key) > 0;

  final int goalMs = _nonNegative(goals.totalMinutes) * 60000;
  final double? deltaPct = prevWeekMs == 0
      ? null
      : computeWeekOverWeekPercent(weekMs, prevWeekMs);

  return <String, Object?>{
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
      'time': formatTime(sumMs(heatKeys)),
      'activeDays': heatKeys.where(activeOn).length,
    },
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
