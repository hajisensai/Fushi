/// 小组件快照各段的纯计算（无 IO、无 i18n 全局：文案经参数注入，测试直接断言）。
library;

import 'dart:math' as math;

/// 复习计数的一个预排节点：从 [at] 起小组件显示 [due]。
typedef SrsDueStep = ({int at, int due});

/// 不打开 app 时待复习数怎么变：
///
/// - 第一项 = 现在，[dueNow] 原样（与首页复习条同一份牌组汇总，含每日上限）。
/// - 学习中 / 重学卡按各自的 `dueAt`（精确到毫秒的学习步）陆续到期，逐个加上。
/// - 跨过 SRS 日边界（[dayIndexOf] 换日的那一刻，二分到分钟）时再加上新一天到期的
///   复习卡 [reviewsDueNextDay]——日边界按 store 的口径（可配重置时刻），不假设零点。
///
/// 节点只在计数变化时产生，最多 [maxSteps] 个（WidgetKit 一次 timeline 不宜过长）；
/// 超出时合并到整点。
List<SrsDueStep> buildSrsDueTimeline({
  required int nowMs,
  required int dueNow,
  required Iterable<int> learningDueAts,
  required int Function(int ms) dayIndexOf,
  required int reviewsDueNextDay,
  Duration horizon = const Duration(hours: 24),
  int maxSteps = 40,
}) {
  final int end = nowMs + horizon.inMilliseconds;
  final int? boundary = _nextDayBoundary(nowMs, end, dayIndexOf);
  final List<int> ripening =
      learningDueAts.where((int at) => at > nowMs && at <= end).toList()
        ..sort();

  // 合并到「下一整分钟」：同一分钟到期的卡一个节点。
  int roundUp(int at, int unit) => ((at + unit - 1) ~/ unit) * unit;
  int unit = 60 * 1000;
  List<int> times() => <int>{
    for (final int at in ripening) roundUp(at, unit),
    ?boundary,
  }.toList()..sort();
  List<int> stepTimes = times();
  if (stepTimes.length > maxSteps) {
    unit = 3600 * 1000;
    stepTimes = times();
  }
  if (stepTimes.length > maxSteps) {
    stepTimes = stepTimes.take(maxSteps).toList();
  }

  final List<SrsDueStep> out = <SrsDueStep>[(at: nowMs, due: dueNow)];
  int ripeIndex = 0;
  int ripened = 0;
  for (final int t in stepTimes) {
    if (t <= nowMs) continue;
    while (ripeIndex < ripening.length && ripening[ripeIndex] <= t) {
      ripeIndex++;
      ripened++;
    }
    final bool pastBoundary = boundary != null && t >= boundary;
    final int due = dueNow + ripened + (pastBoundary ? reviewsDueNextDay : 0);
    if (due != out.last.due) out.add((at: t, due: due));
  }
  return out;
}

/// (from, to] 里第一个 [dayIndexOf] 比 from 大的时刻（分钟精度）；区间内不换日为 null。
int? _nextDayBoundary(int from, int to, int Function(int ms) dayIndexOf) {
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

/// 估算复习用时（分钟，向上取整，至少 1）：用近期每张卡的平均作答时长；没有历史按 10 秒。
int estimateSrsMinutes(int due, {int? averageMsPerCard}) {
  if (due <= 0) return 0;
  final int perCard = (averageMsPerCard == null || averageMsPerCard <= 0)
      ? 10000
      : averageMsPerCard.clamp(3000, 120000);
  return math.max(1, (due * perCard / 60000).ceil());
}

/// 学习日一天的原始量。
typedef StudyDayAmount = ({String dateKey, int ms, int chars});

/// 学习段的原始数字（文案在宿主里套）。
class HomeWidgetStudyNumbers {
  const HomeWidgetStudyNumbers({
    required this.streak,
    required this.studiedToday,
    required this.todayMs,
    required this.todayChars,
    required this.last7,
    required this.heat,
    required this.weekMs,
    required this.weekCards,
  });

  final int streak;
  final bool studiedToday;
  final int todayMs;
  final int todayChars;

  /// 近 7 天强度（0…1，相对 7 天内最大值），今天在最后；今天没学为 -1。
  final List<double> last7;

  /// 近 112 天档位 0…4，今天在最后；今天没学为 -1。
  final List<int> heat;
  final int weekMs;
  final int weekCards;

  /// 过了零点（统计日边界）以后的样子：今天学过 → 连续天数保留、条形左移一格、新的
  /// 「今天」是虚线；没学 → 连续中断为 0。
  int get streakTomorrow => studiedToday ? streak : 0;

  List<double> get last7Tomorrow => <double>[
    ...last7.skip(1).map((double v) => v < 0 ? 0.0 : v),
    -1,
  ];
}

/// [days] 覆盖至少近 112 天的 dateKey（升序，今天在最后，与 `StatWindow.lastDayKeys`
/// 同口径）；[amountOf] 给出某天的学习量；[streakOf] 是统计页同一个连续天数函数。
HomeWidgetStudyNumbers buildStudyNumbers({
  required List<String> last112Keys,
  required StudyDayAmount Function(String dateKey) amountOf,
  required int Function(Set<String> activeDayKeys) streakOf,
  required Set<String> activeDayKeys,
  required bool Function(String dateKey) inWeek,
  required int weekCards,
}) {
  assert(last112Keys.length == 112, 'heatmap expects 16 weeks');
  final String todayKey = last112Keys.last;
  final List<StudyDayAmount> amounts = <StudyDayAmount>[
    for (final String k in last112Keys) amountOf(k),
  ];
  final StudyDayAmount today = amounts.last;
  final bool studiedToday = activeDayKeys.contains(todayKey);

  final List<StudyDayAmount> week7 = amounts.sublist(amounts.length - 7);
  final int maxMs = week7.fold<int>(
    0,
    (int m, StudyDayAmount a) => math.max(m, a.ms),
  );
  final List<double> last7 = <double>[
    for (int i = 0; i < 7; i++)
      if (i == 6 && !studiedToday) -1 else maxMs == 0 ? 0 : week7[i].ms / maxMs,
  ];

  int level(int ms) {
    const int minute = 60 * 1000;
    if (ms <= 0) return 0;
    if (ms < 15 * minute) return 1;
    if (ms < 30 * minute) return 2;
    if (ms < 60 * minute) return 3;
    return 4;
  }

  final List<int> heat = <int>[
    for (int i = 0; i < amounts.length; i++)
      if (i == amounts.length - 1 && !studiedToday)
        -1
      else
        level(amounts[i].ms),
  ];

  int weekMs = 0;
  for (final StudyDayAmount a in amounts) {
    if (inWeek(a.dateKey)) weekMs += a.ms;
  }

  return HomeWidgetStudyNumbers(
    streak: streakOf(activeDayKeys),
    studiedToday: studiedToday,
    todayMs: today.ms,
    todayChars: today.chars,
    last7: last7,
    heat: heat,
    weekMs: weekMs,
    weekCards: weekCards,
  );
}

/// 「今日一词」按日轮换：同一天总是同一张，跨日换一张（不随刷新乱跳）。
int dailyRotationIndex({required String dateKey, required int count}) {
  if (count <= 0) return -1;
  int hash = 0x811c9dc5;
  for (final int unit in dateKey.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash % count;
}

/// 卡片字段里的 HTML（`<b>`、`<br>`、ruby 标签等）压成纯文本。ruby 只留基字——读音
/// 显示只认独立的读音字段，不从别的字段里拆注音。
String stripCardFieldHtml(String value) {
  final String noRt = value.replaceAll(
    RegExp(r'<rt>.*?</rt>|<rp>.*?</rp>', caseSensitive: false, dotAll: true),
    '',
  );
  final String text = noRt
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}
