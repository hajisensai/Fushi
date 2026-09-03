/// 订阅检查节奏：把「这条订阅什么时候更新」翻译成「下一次什么时候查」。
///
/// 背景：订阅检查此前是不分时段的均匀轮询（固定 15 分钟）。连载条目的发布
/// 其实每周只落在一个固定点附近，均匀轮询的代价不在延迟——字幕组发布本来就
/// 滞后放送数小时，几分钟的检查延迟不可感知——而在于**冷窗里 99% 的请求都是
/// 空转**，白白砸向 Nyaa / Torznab，换来限流风险和移动端耗电。
///
/// 这里的做法是从订阅**自己的历史发布时刻**学出周内相位，热窗加密、冷窗拉长。
/// 不依赖 AniList 放送表：放送时刻不等于发布时刻，字幕组滞后多少每组不同，
/// 拿放送时刻当窗口中心必然错位；而历史相位天然吃掉了滞后、时区与换季改档。
///
/// 相位一律按绝对 epoch 取模一周计算，不落地成本地星期几——源样本是绝对时刻，
/// 模运算对夏令时和时区切换免疫，这样就不存在「本地时刻漂了一小时」这类特例。
library;

import 'dart:math' as math;

/// 一周的毫秒数。相位的模。
const int kSubscriptionWeekMs = 7 * 24 * 60 * 60 * 1000;

/// 检查节奏的参数集。默认值即生产取值。
class SubscriptionCheckCadence {
  const SubscriptionCheckCadence({
    this.baseInterval = const Duration(minutes: 15),
    this.hotInterval = const Duration(minutes: 5),
    this.coldInterval = const Duration(hours: 2),
    this.hotLead = const Duration(minutes: 30),
    this.hotTrail = const Duration(hours: 4),
    this.maxSpread = const Duration(hours: 6),
    this.minInterval = const Duration(minutes: 1),
    this.minSamples = 3,
    this.maxSamples = 5,
  });

  /// 样本不足或相位不稳时的均匀间隔，等于改动前的固定行为。
  final Duration baseInterval;

  /// 热窗内的间隔。
  final Duration hotInterval;

  /// 冷窗内的间隔上限，同时也是任何情况下的睡眠封顶——预测点即使完全错了，
  /// 最坏也只迟这么久就会重新探到，命中后新样本自动把相位拉回来。
  final Duration coldInterval;

  /// 热窗从预测点往前多久开始。
  final Duration hotLead;

  /// 热窗在预测点之后持续多久。覆盖字幕组相对上游放送的滞后抖动。
  final Duration hotTrail;

  /// 样本相位的最大离散度。超过即认为这条订阅没有稳定周期，退回均匀间隔。
  ///
  /// 它拦得住的是**样本散开**的情况：一周多集（间隔 3.5 天必然超限）、乱序补档、
  /// 换档期新旧相位混在一起。
  ///
  /// 它**拦不住样本挤成一团**：整季批量掉落（一个 batch 的种子同时上传）或索引器
  /// 把 pubDate 截断到整天，都会给出 spread≈0 的高置信度相位，而那个相位其实毫无
  /// 预测力。这是已知的退化形状，没有在这里加判据去堵——真正兜住它的是
  /// [coldInterval] 封顶（预测再错也最多迟这么久）加上滑动窗口自愈（真正的周更
  /// 样本进来后相位自己会回正）。加一道「样本挤太紧就拒绝」的闸门反而会误伤
  /// 正常周更里两集间隔恰好很近的合法情形。
  final Duration maxSpread;

  /// 任何睡眠的下限，防止「就快到热窗了」退化成忙循环。刻意小于 [hotInterval]：
  /// 冷窗尾巴要能精确停在热窗起点上，抬到 [hotInterval] 会越过起点。
  final Duration minInterval;

  /// 判定相位所需的最少样本数。
  final int minSamples;

  /// 参与判定的最近样本数。取小值是为了让改档在两三周内自愈。
  final int maxSamples;
}

/// 从历史样本推断出的每周发布相位。
class WeeklyReleasePhase {
  const WeeklyReleasePhase({required this.phaseMs, required this.spread});

  /// 周内相位，落在 `[0, kSubscriptionWeekMs)`。
  final int phaseMs;

  /// 参与判定的样本相位离散度。
  final Duration spread;
}

/// 把绝对时刻归一到周内相位。
///
/// Dart 的 `%` 对正除数恒返回非负（`(-1) % 7 == 6`，与 C 不同），所以 1970 年
/// 之前的负 epoch 也不需要额外折回。
int subscriptionWeekPhase(int epochMs) => epochMs % kSubscriptionWeekMs;

/// 把相位差折算到 `[-半周, +半周)`，用于围绕参考点做圆形统计。
int _wrapToHalfWeek(int deltaMs) {
  const int half = kSubscriptionWeekMs ~/ 2;
  return (deltaMs + half) % kSubscriptionWeekMs - half;
}

/// 从历史发布时刻推断每周相位；样本不足或过于离散时返回 null。
///
/// [publishedAtMs] 允许含重复与乱序；只取最近 [SubscriptionCheckCadence.maxSamples]
/// 条参与判定。
WeeklyReleasePhase? inferWeeklyReleasePhase(
  List<int> publishedAtMs, {
  SubscriptionCheckCadence cadence = const SubscriptionCheckCadence(),
}) {
  if (publishedAtMs.length < cadence.minSamples) return null;
  final List<int> recent = publishedAtMs.toList()
    ..sort((int a, int b) => b.compareTo(a));
  if (recent.length > cadence.maxSamples) {
    recent.removeRange(cadence.maxSamples, recent.length);
  }
  if (recent.length < cadence.minSamples) return null;

  // 以最新一条为圆形原点，其余样本折算成相对偏移后做线性统计。
  final int origin = subscriptionWeekPhase(recent.first);
  final List<int> offsets = <int>[
    for (final int sample in recent)
      _wrapToHalfWeek(subscriptionWeekPhase(sample) - origin),
  ]..sort();
  final int spreadMs = offsets.last - offsets.first;
  if (spreadMs > cadence.maxSpread.inMilliseconds) return null;

  final int medianOffset = offsets.length.isOdd
      ? offsets[offsets.length ~/ 2]
      : (offsets[offsets.length ~/ 2 - 1] + offsets[offsets.length ~/ 2]) ~/ 2;
  return WeeklyReleasePhase(
    phaseMs: subscriptionWeekPhase(origin + medianOffset),
    spread: Duration(milliseconds: spreadMs),
  );
}

/// 距离 [nowMs] 之后（含当下）最近一个落在 [phase] 上的绝对时刻。
int nextSubscriptionPhasePoint(WeeklyReleasePhase phase, int nowMs) =>
    nowMs +
    (phase.phaseMs - subscriptionWeekPhase(nowMs)) % kSubscriptionWeekMs;

/// [nowMs] 是否落在 [phase] 的热窗内。
///
/// 热窗跨预测点两侧：前面是提前量（还没发布就先蹲着），后面是滞后余温——
/// 字幕组相对上游放送滞后数小时是常态，尾巴比提前量长得多。
bool isInsideReleaseHotWindow(
  WeeklyReleasePhase phase,
  int nowMs, {
  SubscriptionCheckCadence cadence = const SubscriptionCheckCadence(),
}) {
  final int next = nextSubscriptionPhasePoint(phase, nowMs);
  final int previous = next - kSubscriptionWeekMs;
  final bool inTrail = nowMs <= previous + cadence.hotTrail.inMilliseconds;
  final bool inLead = next - nowMs <= cadence.hotLead.inMilliseconds;
  return inTrail || inLead;
}

/// 单次检查完成后，这条订阅下一次该隔多久再查。
///
/// [recentPublishedAtMs] 是该订阅历史条目的发布时刻（允许乱序、含重复）。
/// [weekly] 为 false 时（一次性订阅等无周期语义的模式）直接返回均匀间隔。
Duration nextSubscriptionCheckDelay({
  required List<int> recentPublishedAtMs,
  required int nowMs,
  bool weekly = true,
  SubscriptionCheckCadence cadence = const SubscriptionCheckCadence(),
}) {
  if (!weekly) return cadence.baseInterval;
  final WeeklyReleasePhase? phase = inferWeeklyReleasePhase(
    recentPublishedAtMs,
    cadence: cadence,
  );
  if (phase == null) return cadence.baseInterval;

  if (isInsideReleaseHotWindow(phase, nowMs, cadence: cadence)) {
    return cadence.hotInterval;
  }

  // 冷窗：睡到热窗开始，但不超过冷窗封顶——这样预测点错了也有兜底探测。
  final int next = nextSubscriptionPhasePoint(phase, nowMs);
  final int untilHot = next - cadence.hotLead.inMilliseconds - nowMs;
  final int sleep = math.min(untilHot, cadence.coldInterval.inMilliseconds);
  return Duration(
    milliseconds: math.max(sleep, cadence.minInterval.inMilliseconds),
  );
}
