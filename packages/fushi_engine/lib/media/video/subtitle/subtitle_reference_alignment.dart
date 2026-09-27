/// 外挂字幕 ↔ 参考字幕的时间轴对齐：**只看 cue 开始时刻，不读文本**。
///
/// 用途：Jimaku 下来的日字是给别的压制版做的，常常整体差几秒、或者在 CM 断点前后
/// 差不同的量。视频里若带一条（任意语言的）文本字幕轨，它的开始时刻就是这部片子的
/// 真时间轴——两边台词在同一时刻开口，语言不同也无所谓。
///
/// 算法与每一个常数都参照 tsubasa（SonicSandbox/Tsubasa-sync，GPL-3.0，
/// `tsubasa/align/objective.py` + `fit.py`），那边每个阈值都落在「真对齐」与「对照组」
/// 之间实测出来的空档里。本文件是按其思路的 Dart 重写，不是逐行移植。
///
/// 三件事：
/// 1. [fitSubtitleToReference]：候选偏移（配对差直方图全局 + 分桶取峰）→ 贪心分段
///    （CM 断点）→ 每段在自己的 cue 上精修 → 逐 2 分钟分桶复核整段都认这个答案。
/// 2. [judgeSubtitleReferenceFit]：统计门（超出瞎碰概率的倍数 + 噪声地板）、分桶复核、
///    参考覆盖度 → 接受 / 待确认 / 拒绝。
/// 3. [decideSubtitleSync]：多条参考轨各自独立对齐，按时间模板去重后**投票**。
///
/// 帧率漂移（23.976 vs 25）**不修**：分桶复核会让它失败，于是整体拒绝。
///
/// 全部纯函数，时间单位是秒（double）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// 常数（出处见 tsubasa objective.py / fit.py 的实测说明）
// ---------------------------------------------------------------------------

/// 一条参考 cue 的开始时刻与某条目标 cue 相差不超过它，就算「落上了」。
const double kAlignMatchTolerance = 0.35;

/// 相距不超过它的两个开始时刻算同一时刻（双语轨每句出现两次，相隔 ~0.1s）。
const double kAlignClusterTolerance = 0.15;

/// 可信的最小 / 最大 CM 断点跳变（秒）。上界挡住「用缺失数据凑出的假断点」。
const double kAlignMinBreak = 1.0;
const double kAlignMaxBreak = 60.0;

/// 一次切分必须给整体匹配率带来的最小增益。
const double kAlignMinSplitGain = 0.02;

/// 较小那段用自己的偏移比用对方偏移至少多出的匹配率——让早期断点也能被看见。
const double kAlignMinLocalMargin = 0.35;

/// 每一段都必须达到的「超出瞎碰概率的倍数」。
const double kAlignMinSegmentExcess = 2.5;

/// 每段最少参考 cue 数。
const int kAlignMinSegmentCues = 12;

/// 任一侧少于它就根本不对齐：cue 太少时「超出概率倍数」不是弱，是**反的**
/// （tsubasa 实测：一条 cue 的字幕能打出 5.15 倍）。
const int kAlignMinAlignableCues = 5;

/// 分桶复核的桶宽（秒）、桶内最少 cue 数、桶只在当前偏移附近找更好的答案的半径。
const double kAlignBucketSeconds = 120.0;
const int kAlignMinBucketCues = 8;
const double kAlignBucketLocalWindow = 15.0;

/// 一个桶只有**同时**多出这么多匹配率、又想要离当前偏移这么远的偏移，才算失败。
const double kAlignBucketRateSlack = 0.15;
const double kAlignMaxBucketDrift = 0.75;

/// 噪声地板的标准差倍数。
const double kAlignNoiseZ = 4.0;

/// 偏移搜索半径（秒）。
const double kAlignSearchWindow = 120.0;

const double _histogramBin = 0.01;
const int _globalPeaks = 6;
const int _bucketPeaks = 2;
const double _candidateSeparation = 0.5;
const int _refinePasses = 3;
const double _tieSlack = 1.0;
const double _refineWindow = 0.60;
const double _refineStep = 0.01;

/// 判定分档：超出瞎碰概率 ≥ 2.5 倍才接受，< 1.5 倍拒绝，中间待确认。
const double kAlignAcceptExcess = 2.5;
const double kAlignRefuseExcess = 1.5;

// ---------------------------------------------------------------------------
// 基础量
// ---------------------------------------------------------------------------

/// 去重后的开始时刻（升序）：先取到毫秒，再把相距 ≤ [tolerance] 的合成一个。
List<double> uniqueCueStarts(
  Iterable<double> starts, {
  double tolerance = kAlignClusterTolerance,
}) {
  final List<double> xs = <double>{
    for (final double t in starts) (t * 1000).roundToDouble() / 1000,
  }.toList()..sort();
  final List<double> out = <double>[];
  for (final double x in xs) {
    if (out.isEmpty || x - out.last > tolerance) out.add(x);
  }
  return out;
}

/// 只凭 cue 密度、没有任何真实对齐时能达到的匹配率。
double alignChanceRate(int subtitleCueCount, double spanSeconds) {
  if (spanSeconds <= 0) return 1.0;
  return math.min(
    1.0,
    2.0 * kAlignMatchTolerance * subtitleCueCount / spanSeconds,
  );
}

/// 在 [n] 条 cue 上「从很多候选里挑最好的」时，光靠运气能达到的匹配率。
double alignNoiseFloor(double chance, int n) {
  if (n <= 0 || chance <= 0) return 1.0;
  final double variance = math.max(chance * (1.0 - chance), 0.0) / n;
  return math.min(1.0, chance + kAlignNoiseZ * math.sqrt(variance));
}

int _lowerBound(List<double> sorted, double x) {
  int lo = 0;
  int hi = sorted.length;
  while (lo < hi) {
    final int mid = (lo + hi) >> 1;
    if (sorted[mid] < x) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// [sorted] 里离 [x] 最近的距离；空表返回无穷大。
double nearestDistance(List<double> sorted, double x) {
  if (sorted.isEmpty) return double.infinity;
  final int k = _lowerBound(sorted, x);
  final double hi = (sorted[math.min(k, sorted.length - 1)] - x).abs();
  final double lo = (sorted[math.max(k - 1, 0)] - x).abs();
  return math.min(lo, hi);
}

/// 每条参考 cue 在偏移 [offset]（加到目标字幕上）下是否落上。
Uint8List alignmentHits(List<double> ref, List<double> sub, double offset) {
  final Uint8List out = Uint8List(ref.length);
  for (int i = 0; i < ref.length; i++) {
    if (nearestDistance(sub, ref[i] - offset) <= kAlignMatchTolerance) {
      out[i] = 1;
    }
  }
  return out;
}

double _mean(Uint8List row, [int start = 0, int? end]) {
  final int e = end ?? row.length;
  if (e <= start) return 0.0;
  int sum = 0;
  for (int i = start; i < e; i++) {
    sum += row[i];
  }
  return sum / (e - start);
}

/// 偏移 [offset] 下的匹配率。
double alignmentMatchRate(List<double> ref, List<double> sub, double offset) =>
    _mean(alignmentHits(ref, sub, offset));

double _median(List<double> values) {
  final List<double> s = List<double>.of(values)..sort();
  final int n = s.length;
  return n.isOdd ? s[n >> 1] : (s[(n >> 1) - 1] + s[n >> 1]) / 2;
}

// ---------------------------------------------------------------------------
// 分段偏移 → 目标字幕时间的映射
// ---------------------------------------------------------------------------

/// 一段常数偏移。[splitSeconds] 是这段在**参考（视频）时间**上的结束点；
/// 最后一段为 null。
class AlignmentSegment {
  const AlignmentSegment({
    required this.splitSeconds,
    required this.offsetSeconds,
  });

  final double? splitSeconds;
  final double offsetSeconds;

  @override
  String toString() =>
      'AlignmentSegment(split: $splitSeconds, offset: $offsetSeconds)';
}

/// 各断点换算到**目标字幕时间**：第 i 段覆盖目标时间 `< split_i - offset_i`。
List<({double subtitleTime, double fromOffset, double toOffset})>
alignmentSubtitleBoundaries(List<AlignmentSegment> segments) {
  final List<({double subtitleTime, double fromOffset, double toOffset})> out =
      <({double subtitleTime, double fromOffset, double toOffset})>[];
  for (int i = 0; i < segments.length - 1; i++) {
    final double? split = segments[i].splitSeconds;
    if (split == null) {
      throw ArgumentError('segments[$i] 不是最后一段却没有断点');
    }
    out.add((
      subtitleTime: split - segments[i].offsetSeconds,
      fromOffset: segments[i].offsetSeconds,
      toOffset: segments[i + 1].offsetSeconds,
    ));
  }
  return out;
}

/// 目标字幕时刻 [seconds] 应加的偏移。
double alignmentOffsetAt(List<AlignmentSegment> segments, double seconds) {
  if (segments.isEmpty) return 0.0;
  double offset = segments.first.offsetSeconds;
  for (final ({double subtitleTime, double fromOffset, double toOffset}) b
      in alignmentSubtitleBoundaries(segments)) {
    if (seconds >= b.subtitleTime) offset = b.toOffset;
  }
  return offset;
}

/// 负跳变（CM 块被剪掉）处无家可归的目标时间区间 `[lo, hi)`：落在里面的 cue
/// 在任何偏移下都会和下一段开头重叠，只能丢弃。
List<({double lo, double hi})> alignmentRemovedSpans(
  List<AlignmentSegment> segments,
) {
  return <({double lo, double hi})>[
    for (final ({double subtitleTime, double fromOffset, double toOffset}) b
        in alignmentSubtitleBoundaries(segments))
      if (b.toOffset < b.fromOffset)
        (lo: b.subtitleTime, hi: b.subtitleTime + (b.fromOffset - b.toOffset)),
  ];
}

bool alignmentIsRemoved(List<AlignmentSegment> segments, double seconds) =>
    alignmentRemovedSpans(
      segments,
    ).any((({double lo, double hi}) s) => s.lo <= seconds && seconds < s.hi);

// ---------------------------------------------------------------------------
// 候选偏移
// ---------------------------------------------------------------------------

/// 每对 |r - a| ≤ window 的差 r - a，以及它来自哪条参考 cue。
({List<double> diffs, List<int> refIndex}) _differences(
  List<double> ref,
  List<double> sub,
  double window,
) {
  final List<double> diffs = <double>[];
  final List<int> refIndex = <int>[];
  for (int i = 0; i < ref.length; i++) {
    final int lo = _lowerBound(sub, ref[i] - window);
    for (int j = lo; j < sub.length && sub[j] <= ref[i] + window; j++) {
      diffs.add(ref[i] - sub[j]);
      refIndex.add(i);
    }
  }
  return (diffs: diffs, refIndex: refIndex);
}

/// 盒式平滑后的直方图：bin `o` 的值 = 偏移 `o` 下的配对数。
Float64List _smoothedHistogram(Iterable<double> diffs, double window) {
  final int bins = (2 * window / _histogramBin).floor() + 1;
  final Float64List hist = Float64List(bins);
  for (final double d in diffs) {
    final int idx = ((d + window) / _histogramBin).floor();
    if (idx >= 0 && idx < bins) hist[idx] += 1;
  }
  final int half = (2 * kAlignMatchTolerance / _histogramBin).round() ~/ 2;
  final Float64List prefix = Float64List(bins + 1);
  for (int i = 0; i < bins; i++) {
    prefix[i + 1] = prefix[i] + hist[i];
  }
  final Float64List smooth = Float64List(bins);
  for (int i = 0; i < bins; i++) {
    smooth[i] =
        prefix[math.min(bins, i + half + 1)] - prefix[math.max(0, i - half)];
  }
  return smooth;
}

int _argmax(Float64List xs) {
  int best = 0;
  for (int i = 1; i < xs.length; i++) {
    if (xs[i] > xs[best]) best = i;
  }
  return best;
}

/// 窄峰用原始差做中位数精修；宽平台（同源时间模板）取平台中心，中位数会被
/// 失配的剩余差带偏。
double _refinePeak(List<double> diffs, double offset, double plateauWidth) {
  if (plateauWidth >= kAlignMatchTolerance) return offset;
  double o = offset;
  for (int pass = 0; pass < _refinePasses; pass++) {
    final List<double> near = <double>[
      for (final double d in diffs)
        if ((d - o).abs() <= kAlignMatchTolerance) d,
    ];
    if (near.isEmpty) break;
    o = _median(near);
  }
  return o;
}

/// 直方图的前 [k] 个峰；峰值取平台中心而不是 argmax 的左边缘。
List<double> _peaks(List<double> diffs, int k, double window) {
  if (diffs.isEmpty) return const <double>[];
  final Float64List smooth = _smoothedHistogram(diffs, window);
  final int sep = math.max(1, (_candidateSeparation / _histogramBin).floor());
  final List<double> out = <double>[];
  for (int n = 0; n < k; n++) {
    final int i = _argmax(smooth);
    final double top = smooth[i];
    if (top <= 0) break;
    int j = i;
    while (j + 1 < smooth.length && smooth[j + 1] >= top - 1e-9) {
      j++;
    }
    final double centre = ((i + j) ~/ 2) * _histogramBin - window;
    out.add(_refinePeak(diffs, centre, (j - i) * _histogramBin));
    smooth.fillRange(
      math.max(0, i - sep),
      math.min(smooth.length, j + sep + 1),
      0,
    );
  }
  return out;
}

/// 值得考虑的偏移：全片的峰 + 每个 2 分钟桶自己的峰。后者让 CM 断点前那一小段
/// 可见——全局直方图里它淹没在噪声里，在自己的桶里它是多数。
List<double> alignmentCandidates(
  List<double> ref,
  List<double> sub, {
  double window = kAlignSearchWindow,
}) {
  final ({List<double> diffs, List<int> refIndex}) d = _differences(
    ref,
    sub,
    window,
  );
  if (d.diffs.isEmpty) return const <double>[];
  final List<double> found = List<double>.of(
    _peaks(d.diffs, _globalPeaks, window),
  );
  final Map<int, List<double>> byBucket = <int, List<double>>{};
  for (int n = 0; n < d.diffs.length; n++) {
    final int bucket = (ref[d.refIndex[n]] / kAlignBucketSeconds).floor();
    (byBucket[bucket] ??= <double>[]).add(d.diffs[n]);
  }
  final List<int> buckets = byBucket.keys.toList()..sort();
  for (final int b in buckets) {
    final List<double> diffs = byBucket[b]!;
    if (diffs.length < kAlignMinSegmentCues) continue;
    for (final double o in _peaks(diffs, _bucketPeaks, window)) {
      if (found.every((double c) => (o - c).abs() > _candidateSeparation)) {
        found.add(o);
      }
    }
  }
  return found;
}

// ---------------------------------------------------------------------------
// 分段搜索
// ---------------------------------------------------------------------------

/// 命中矩阵的前缀和：`prefix[c][k]` = 候选 c 在参考 cue [0, k) 上的命中数。
List<Int32List> _prefixHits(List<Uint8List> hits) {
  return <Int32List>[
    for (final Uint8List row in hits)
      () {
        final Int32List p = Int32List(row.length + 1);
        for (int i = 0; i < row.length; i++) {
          p[i + 1] = p[i] + row[i];
        }
        return p;
      }(),
  ];
}

typedef _Boundary = ({int cut, int c1, int c2});

/// 参考 cue [i0, i1) 上最好的单次切分：前段用 c1、后段用 c2（c1 ≠ c2）。
_Boundary? _bestBoundary(List<Int32List> prefix, int i0, int i1) {
  if (i1 - i0 < 2 * kAlignMinSegmentCues) return null;
  double best = -1;
  _Boundary? pick;
  for (int k = i0 + kAlignMinSegmentCues; k <= i1 - kAlignMinSegmentCues; k++) {
    int c1 = 0;
    int c2 = 0;
    for (int c = 1; c < prefix.length; c++) {
      if (prefix[c][k] - prefix[c][i0] > prefix[c1][k] - prefix[c1][i0]) c1 = c;
      if (prefix[c][i1] - prefix[c][k] > prefix[c2][i1] - prefix[c2][k]) c2 = c;
    }
    if (c1 == c2) continue;
    final double total =
        (prefix[c1][k] - prefix[c1][i0] + prefix[c2][i1] - prefix[c2][k])
            .toDouble();
    if (total > best) {
      best = total;
      pick = (cut: k, c1: c1, c2: c2);
    }
  }
  return pick;
}

/// 每一段的匹配率；任何一道防护不过就返回 null。
List<double>? _earnsItself(
  List<Uint8List> hits,
  List<int> bounds,
  List<int> labels,
  List<double> offsets,
  double chance,
) {
  final List<double> rates = <double>[
    for (int i = 0; i < labels.length; i++)
      _mean(hits[labels[i]], bounds[i], bounds[i + 1]),
  ];
  if (chance > 0 && rates.reduce(math.min) < kAlignMinSegmentExcess * chance) {
    return null;
  }
  for (int i = 0; i < offsets.length - 1; i++) {
    final double jump = (offsets[i + 1] - offsets[i]).abs();
    if (jump < kAlignMinBreak || jump > kAlignMaxBreak) return null;
    final bool firstSmaller =
        bounds[i + 1] - bounds[i] <= bounds[i + 2] - bounds[i + 1];
    final int s = firstSmaller ? bounds[i] : bounds[i + 1];
    final int e = firstSmaller ? bounds[i + 1] : bounds[i + 2];
    final int own = firstSmaller ? labels[i] : labels[i + 1];
    final int other = firstSmaller ? labels[i + 1] : labels[i];
    if (_mean(hits[own], s, e) - _mean(hits[other], s, e) <
        kAlignMinLocalMargin) {
      return null;
    }
  }
  return rates;
}

/// 断点位置：与最优只差不超过 [_tieSlack] 次命中的切点都算平手（断点落在 OP 静音里，
/// 静音里每个位置得分相同），取最早的那个，同时报告整段不确定区间。
({double at, double lo, double hi}) _boundaryTime(
  List<double> ref,
  List<Int32List> prefix,
  int i0,
  int i1,
  int c1,
  int c2,
  int fallbackCut,
) {
  final List<int> ties = <int>[];
  if (i1 - i0 >= 2 * kAlignMinSegmentCues) {
    double best = -1;
    final List<double> totals = <double>[];
    for (
      int k = i0 + kAlignMinSegmentCues;
      k <= i1 - kAlignMinSegmentCues;
      k++
    ) {
      final double t =
          (prefix[c1][k] - prefix[c1][i0] + prefix[c2][i1] - prefix[c2][k])
              .toDouble();
      totals.add(t);
      best = math.max(best, t);
    }
    for (int n = 0; n < totals.length; n++) {
      if (totals[n] >= best - _tieSlack - 1e-9) {
        ties.add(i0 + kAlignMinSegmentCues + n);
      }
    }
  }
  final List<int> ks = ties.where((int k) => k > 0 && k < ref.length).toList();
  if (ks.isEmpty) {
    final double t = ref[fallbackCut.clamp(0, ref.length - 1)];
    return (at: t, lo: t, hi: t);
  }
  return (at: ref[ks.first], lo: ref[ks.first], hi: ref[ks.last]);
}

/// 用真实目标函数在 ±0.6s 上逐 0.01s 精修一段的偏移，取平台中心。
///
/// **比参考自身精度还小的偏移不动**：参考是另一种语言的轨，它与日字真时间轴之间本就
/// 有零点几秒的系统差。实测（高木同学 2，内嵌日文轨当标准答案）：本来就对齐的
/// `.ja.ass`（对标准答案偏 -0.01s）按 Netflix 各语言轨被推了 0.10–0.29s，对标准答案
/// 的命中率一分没涨——那是参考的误差，不是字幕的误差。|偏移| < [kAlignMatchTolerance]
/// 一律当 0：它既在目标函数分辨率以内，也在观众可察觉的量级以下（tsubasa 同一判断，
/// 见 [kAlignMaxBucketDrift] 的由来）。
double _refineSegment(List<double> ref, List<double> sub, double offset) {
  if (ref.isEmpty || sub.isEmpty) return offset;
  final int steps = (2 * _refineWindow / _refineStep).round();
  final List<double> rates = <double>[
    for (int i = 0; i <= steps; i++)
      alignmentMatchRate(ref, sub, offset - _refineWindow + i * _refineStep),
  ];
  final double top = rates.reduce(math.max);
  if (top <= 0) return offset;
  final int first = rates.indexWhere((double r) => r >= top - 1e-12);
  final int last = rates.lastIndexWhere((double r) => r >= top - 1e-12);
  final double refined =
      offset - _refineWindow + (first + last) / 2 * _refineStep;
  return refined.abs() < kAlignMatchTolerance ? 0.0 : refined;
}

// ---------------------------------------------------------------------------
// 分桶复核
// ---------------------------------------------------------------------------

/// 一个 2 分钟桶的复核记录。
class AlignmentBucket {
  const AlignmentBucket({
    required this.startSeconds,
    required this.cueCount,
    required this.appliedRate,
    required this.wantedOffset,
    required this.wantedRate,
  });

  final double startSeconds;
  final int cueCount;
  final double? appliedRate;
  final double? wantedOffset;
  final double? wantedRate;
}

({List<AlignmentBucket> rows, List<AlignmentBucket> failing}) _walkBuckets(
  List<double> ref,
  List<Uint8List> hits,
  List<double> cands,
  List<int> bounds,
  List<int> labels,
  double chance,
) {
  final List<AlignmentBucket> rows = <AlignmentBucket>[];
  final List<AlignmentBucket> failing = <AlignmentBucket>[];
  if (ref.isEmpty) return (rows: rows, failing: failing);
  final List<int> applied = List<int>.filled(ref.length, 0);
  for (int i = 0; i < labels.length; i++) {
    applied.fillRange(bounds[i], bounds[i + 1], labels[i]);
  }
  final Map<int, List<int>> members = <int, List<int>>{};
  for (int i = 0; i < ref.length; i++) {
    (members[(ref[i] / kAlignBucketSeconds).floor()] ??= <int>[]).add(i);
  }
  final int lastBucket = (ref.last / kAlignBucketSeconds).floor();
  for (int b = 0; b <= lastBucket; b++) {
    final List<int> idx = members[b] ?? const <int>[];
    final AlignmentBucket row = _judgeBucket(
      b,
      idx,
      hits,
      cands,
      applied,
      chance,
    );
    rows.add(row);
    if (_bucketFails(row, idx, cands, applied, chance)) failing.add(row);
  }
  return (rows: rows, failing: failing);
}

double _bucketCentre(List<int> idx, List<double> cands, List<int> applied) =>
    _median(<double>[for (final int i in idx) cands[applied[i]]]);

AlignmentBucket _judgeBucket(
  int bucket,
  List<int> idx,
  List<Uint8List> hits,
  List<double> cands,
  List<int> applied,
  double chance,
) {
  final double t0 = bucket * kAlignBucketSeconds;
  if (idx.length < kAlignMinBucketCues) {
    return AlignmentBucket(
      startSeconds: t0,
      cueCount: idx.length,
      appliedRate: null,
      wantedOffset: null,
      wantedRate: null,
    );
  }
  double rateOf(int c) =>
      idx.where((int i) => hits[c][i] == 1).length / idx.length;
  final double appliedRate =
      idx.where((int i) => hits[applied[i]][i] == 1).length / idx.length;
  final double centre = _bucketCentre(idx, cands, applied);
  int? want;
  for (int c = 0; c < cands.length; c++) {
    if ((cands[c] - centre).abs() > kAlignBucketLocalWindow) continue;
    if (want == null || rateOf(c) > rateOf(want)) want = c;
  }
  return AlignmentBucket(
    startSeconds: t0,
    cueCount: idx.length,
    appliedRate: appliedRate,
    wantedOffset: want == null ? null : cands[want],
    wantedRate: want == null ? null : rateOf(want),
  );
}

/// 桶失败 = 同时：多出足够匹配率、想要足够远的偏移、且想要的高于它自己的噪声地板。
bool _bucketFails(
  AlignmentBucket row,
  List<int> idx,
  List<double> cands,
  List<int> applied,
  double chance,
) {
  final double? applied0 = row.appliedRate;
  final double? wantOff = row.wantedOffset;
  final double? wantRate = row.wantedRate;
  if (applied0 == null || wantOff == null || wantRate == null) return false;
  final double centre = _bucketCentre(idx, cands, applied);
  return wantRate - applied0 > kAlignBucketRateSlack &&
      (wantOff - centre).abs() > kAlignMaxBucketDrift &&
      wantRate > alignNoiseFloor(chance, row.cueCount);
}

// ---------------------------------------------------------------------------
// 对齐入口
// ---------------------------------------------------------------------------

/// 对齐结果与证据。
class SubtitleReferenceFit {
  const SubtitleReferenceFit({
    required this.segments,
    required this.score,
    required this.chance,
    required this.buckets,
    required this.failingBuckets,
    required this.referenceCueCount,
    required this.subtitleCueCount,
    required this.breakSpans,
  });

  /// 分段偏移（加到目标字幕上）。
  final List<AlignmentSegment> segments;

  /// 整体匹配率（被落上的参考 cue 占比）。
  final double score;

  /// 瞎碰概率。
  final double chance;

  final List<AlignmentBucket> buckets;

  /// 认为另有更好偏移的桶——非空即「整段并不都认这个答案」。
  final List<AlignmentBucket> failingBuckets;

  final int referenceCueCount;
  final int subtitleCueCount;

  /// 每个断点在参考时间上的不确定区间。
  final List<({double lo, double hi})> breakSpans;

  /// 样本够不够让分数有意义：两侧都 ≥ [kAlignMinAlignableCues]，且分数高于
  /// 以较少一侧 cue 数计的噪声地板。
  bool get measurable {
    final int n = math.min(referenceCueCount, subtitleCueCount);
    if (n < kAlignMinAlignableCues) return false;
    return score > alignNoiseFloor(chance, n);
  }

  /// 超出瞎碰概率的倍数；不可测时恒为 0，调用方拿不到由一两条 cue 编出的「高分」。
  double get excess => measurable && chance > 0 ? score / chance : 0.0;

  bool get holdsThroughout => failingBuckets.isEmpty;

  bool get hasBreaks => segments.length > 1;
}

/// 对齐参考开始时刻 [ref] 与目标开始时刻 [sub]（都须先经 [uniqueCueStarts]）。
/// [durationSeconds] 是瞎碰概率摊开的片长；未知时用目标自己的跨度。
SubtitleReferenceFit fitSubtitleToReference(
  List<double> ref,
  List<double> sub, {
  double? durationSeconds,
  double window = kAlignSearchWindow,
}) {
  final double subSpan = sub.isEmpty ? 0.0 : sub.last - sub.first;
  final double span = durationSeconds == null || durationSeconds <= 0
      ? subSpan
      : math.max(durationSeconds, subSpan);
  final double chance = alignChanceRate(sub.length, span);
  final List<double> cands = alignmentCandidates(ref, sub, window: window);
  if (ref.isEmpty || sub.isEmpty || cands.isEmpty) {
    return SubtitleReferenceFit(
      segments: const <AlignmentSegment>[
        AlignmentSegment(splitSeconds: null, offsetSeconds: 0),
      ],
      score: 0,
      chance: chance,
      buckets: const <AlignmentBucket>[],
      failingBuckets: const <AlignmentBucket>[],
      referenceCueCount: ref.length,
      subtitleCueCount: sub.length,
      breakSpans: const <({double lo, double hi})>[],
    );
  }
  final List<Uint8List> hits = <Uint8List>[
    for (final double o in cands) alignmentHits(ref, sub, o),
  ];
  final List<Int32List> prefix = _prefixHits(hits);
  final ({List<int> bounds, List<int> labels, double score}) split =
      _greedySplit(ref.length, hits, prefix, cands, chance);
  return _assembleFit(ref, sub, hits, prefix, cands, chance, split);
}

({List<int> bounds, List<int> labels, double score}) _greedySplit(
  int n,
  List<Uint8List> hits,
  List<Int32List> prefix,
  List<double> cands,
  double chance,
) {
  int best = 0;
  for (int c = 1; c < prefix.length; c++) {
    if (prefix[c][n] > prefix[best][n]) best = c;
  }
  List<int> bounds = <int>[0, n];
  List<int> labels = <int>[best];
  double combined = prefix[best][n] / n;
  while (true) {
    ({List<int> bounds, List<int> labels, double score})? pick;
    for (int si = 0; si < bounds.length - 1; si++) {
      final ({List<int> bounds, List<int> labels, double score})? trial =
          _trySplit(si, bounds, labels, hits, prefix, cands, chance, n);
      if (trial == null || trial.score - combined < kAlignMinSplitGain) {
        continue;
      }
      if (pick == null || trial.score > pick.score) pick = trial;
    }
    if (pick == null) break;
    bounds = pick.bounds;
    labels = pick.labels;
    combined = pick.score;
  }
  return (bounds: bounds, labels: labels, score: combined);
}

({List<int> bounds, List<int> labels, double score})? _trySplit(
  int si,
  List<int> bounds,
  List<int> labels,
  List<Uint8List> hits,
  List<Int32List> prefix,
  List<double> cands,
  double chance,
  int n,
) {
  final _Boundary? found = _bestBoundary(prefix, bounds[si], bounds[si + 1]);
  if (found == null) return null;
  final List<int> b = <int>[
    ...bounds.sublist(0, si + 1),
    found.cut,
    ...bounds.sublist(si + 1),
  ];
  final List<int> l = <int>[
    ...labels.sublist(0, si),
    found.c1,
    found.c2,
    ...labels.sublist(si + 1),
  ];
  final List<double>? rates = _earnsItself(hits, b, l, <double>[
    for (final int c in l) cands[c],
  ], chance);
  if (rates == null) return null;
  double score = 0;
  for (int i = 0; i < rates.length; i++) {
    score += rates[i] * (b[i + 1] - b[i]);
  }
  return (bounds: b, labels: l, score: score / n);
}

SubtitleReferenceFit _assembleFit(
  List<double> ref,
  List<double> sub,
  List<Uint8List> hits,
  List<Int32List> prefix,
  List<double> cands,
  double chance,
  ({List<int> bounds, List<int> labels, double score}) split,
) {
  final List<int> bounds = split.bounds;
  final List<int> labels = split.labels;
  final List<AlignmentSegment> segments = <AlignmentSegment>[];
  final List<({double lo, double hi})> spans = <({double lo, double hi})>[];
  for (int i = 0; i < labels.length; i++) {
    final double offset = _refineSegment(
      ref.sublist(bounds[i], bounds[i + 1]),
      sub,
      cands[labels[i]],
    );
    if (i == labels.length - 1) {
      segments.add(AlignmentSegment(splitSeconds: null, offsetSeconds: offset));
      continue;
    }
    final ({double at, double lo, double hi}) t = _boundaryTime(
      ref,
      prefix,
      bounds[i],
      bounds[i + 2],
      labels[i],
      labels[i + 1],
      bounds[i + 1],
    );
    segments.add(AlignmentSegment(splitSeconds: t.at, offsetSeconds: offset));
    spans.add((lo: t.lo, hi: t.hi));
  }
  final ({List<AlignmentBucket> rows, List<AlignmentBucket> failing}) walk =
      _walkBuckets(ref, hits, cands, bounds, labels, chance);
  return SubtitleReferenceFit(
    segments: segments,
    score: split.score,
    chance: chance,
    buckets: walk.rows,
    failingBuckets: walk.failing,
    referenceCueCount: ref.length,
    subtitleCueCount: sub.length,
    breakSpans: spans,
  );
}

// ---------------------------------------------------------------------------
// 单条参考的判定
// ---------------------------------------------------------------------------

/// 单条参考对齐的强度。
enum AlignmentStrength { refused, uncertain, accepted }

/// 拒绝 / 降级的原因（给日志与界面，不参与判定）。
enum AlignmentIssue {
  none,

  /// 任一侧 cue 太少，分数无意义。
  tooFewCues,

  /// 分数不高于噪声地板：错集、别的番、倒序字幕基本落在这里。
  notMeasurable,

  /// 超出瞎碰概率的倍数太低。
  weakMatch,

  /// 有时段认另一个偏移：帧率漂移、不同剪辑、只对上了一半。
  doesNotHoldThroughout,

  /// 参考只覆盖了目标字幕的一部分，其余时段从没被检查过。
  partialReferenceCoverage,
}

class SubtitleReferenceJudgement {
  const SubtitleReferenceJudgement({
    required this.fit,
    required this.strength,
    required this.issue,
  });

  final SubtitleReferenceFit fit;
  final AlignmentStrength strength;
  final AlignmentIssue issue;
}

/// 目标 cue 映射到新时间后，离任何参考 cue 超过一个桶宽的连续一串——它们的时间
/// 从没被检查过。返回最长那串在参考时间上的跨度（秒），没有则 0。
double longestUncheckedStretch(
  List<double> ref,
  List<double> sub,
  List<AlignmentSegment> segments,
) {
  double longest = 0;
  double? runStart;
  double? runEnd;
  for (final double s in sub) {
    final double mapped = s + alignmentOffsetAt(segments, s);
    if (nearestDistance(ref, mapped) > kAlignBucketSeconds) {
      runStart ??= mapped;
      runEnd = mapped;
      longest = math.max(longest, runEnd - runStart);
    } else {
      runStart = null;
      runEnd = null;
    }
  }
  return longest;
}

/// 判定一次对齐：接受 / 待确认 / 拒绝。
SubtitleReferenceJudgement judgeSubtitleReferenceFit(
  SubtitleReferenceFit fit, {
  required List<double> ref,
  required List<double> sub,
}) {
  SubtitleReferenceJudgement verdict(AlignmentStrength s, AlignmentIssue i) =>
      SubtitleReferenceJudgement(fit: fit, strength: s, issue: i);
  if (math.min(fit.referenceCueCount, fit.subtitleCueCount) <
      kAlignMinAlignableCues) {
    return verdict(AlignmentStrength.refused, AlignmentIssue.tooFewCues);
  }
  if (!fit.measurable) {
    return verdict(AlignmentStrength.refused, AlignmentIssue.notMeasurable);
  }
  if (!fit.holdsThroughout) {
    return verdict(
      AlignmentStrength.refused,
      AlignmentIssue.doesNotHoldThroughout,
    );
  }
  if (fit.excess < kAlignRefuseExcess) {
    return verdict(AlignmentStrength.refused, AlignmentIssue.weakMatch);
  }
  if (longestUncheckedStretch(ref, sub, fit.segments) >= kAlignBucketSeconds) {
    return verdict(
      AlignmentStrength.refused,
      AlignmentIssue.partialReferenceCoverage,
    );
  }
  if (fit.excess < kAlignAcceptExcess) {
    return verdict(AlignmentStrength.uncertain, AlignmentIssue.weakMatch);
  }
  return verdict(AlignmentStrength.accepted, AlignmentIssue.none);
}

// ---------------------------------------------------------------------------
// 多参考投票
// ---------------------------------------------------------------------------

/// 参考 cue 少于它的轨不当参考（forced / 只有特效字的轨）。
const int kMinReferenceCues = 30;

/// 两条参考在零偏移下互相命中率都 ≥ 它，视为同一份时间模板（一票）。
const double kSameTimingTemplateRate = 0.85;

/// 两个结果在目标 cue 上的映射相差 ≤ 它（秒）算一致……
///
/// 取候选去重的同一个间距：目标函数的匹配容差是 ±0.35s，不同语言的参考断句不同，
/// 各自精修出的偏移差 0.2s 很正常（实测合成数据 +4.43 vs +4.63），那是同一个答案；
/// 真正不同的答案至少差一个最小断点跳变（1s）。
const double kConsensusTolerance = _candidateSeparation;

/// ……且一致的目标 cue 占比 ≥ 它。
const double kConsensusAgreement = 0.9;

/// 只有一票独立参考时，自动写入要求的更高倍数。
const double kSingleReferenceAutoExcess = 3.5;

/// 一条候选参考（通常是视频的一条内嵌文本字幕轨）。
class SubtitleReferenceTrack {
  const SubtitleReferenceTrack({required this.label, required this.starts});

  /// 给日志与界面看的名字（如 `#2 eng "Full Subtitles"`）。
  final String label;

  /// 已去重的开始时刻（秒，升序）。
  final List<double> starts;
}

/// 一组时间模板相同的参考轨，以及对这组代表的判定。
class SubtitleReferenceGroup {
  const SubtitleReferenceGroup({required this.tracks, required this.judgement});

  /// 第一条是代表（cue 最多）。
  final List<SubtitleReferenceTrack> tracks;
  final SubtitleReferenceJudgement judgement;
}

/// 最终决定。
enum SubtitleSyncDecisionKind {
  /// 证据足够：可以不经确认直接写入。
  autoApply,

  /// 有像样的结果但证据不足以自动写：交给人确认。
  needsConfirmation,

  /// 没有可信的结果：原样保留。
  refused,
}

class SubtitleSyncDecision {
  const SubtitleSyncDecision({
    required this.kind,
    required this.groups,
    required this.chosen,
    required this.agreeingGroups,
    required this.conflicting,
  });

  final SubtitleSyncDecisionKind kind;

  /// 每组独立参考的判定（按证据从强到弱）。
  final List<SubtitleReferenceGroup> groups;

  /// 采用的那组；[kind] 为 refused 时为 null。
  final SubtitleReferenceGroup? chosen;

  /// 与 [chosen] 一致的**已接受**组数（含自己）。
  final int agreeingGroups;

  /// 是否有已接受的组与 [chosen] 给出不同的映射。
  final bool conflicting;

  List<AlignmentSegment> get segments =>
      chosen?.judgement.fit.segments ?? const <AlignmentSegment>[];
}

bool _sameTimingTemplate(List<double> a, List<double> b) =>
    alignmentMatchRate(a, b, 0) >= kSameTimingTemplateRate &&
    alignmentMatchRate(b, a, 0) >= kSameTimingTemplateRate;

/// 按时间模板把参考轨分组：同模板的多语言轨本质是同一份证据，只算一票。
List<List<SubtitleReferenceTrack>> groupReferenceTracks(
  List<SubtitleReferenceTrack> tracks,
) {
  final List<SubtitleReferenceTrack> sorted =
      List<SubtitleReferenceTrack>.of(
        tracks.where(
          (SubtitleReferenceTrack t) => t.starts.length >= kMinReferenceCues,
        ),
      )..sort(
        (SubtitleReferenceTrack a, SubtitleReferenceTrack b) =>
            b.starts.length.compareTo(a.starts.length),
      );
  final List<List<SubtitleReferenceTrack>> groups =
      <List<SubtitleReferenceTrack>>[];
  for (final SubtitleReferenceTrack t in sorted) {
    final int at = groups.indexWhere(
      (List<SubtitleReferenceTrack> g) =>
          _sameTimingTemplate(g.first.starts, t.starts),
    );
    if (at < 0) {
      groups.add(<SubtitleReferenceTrack>[t]);
    } else {
      groups[at].add(t);
    }
  }
  return groups;
}

/// 两组分段偏移在目标 cue 上给出的新时间是否一致。
bool alignmentsAgree(
  List<AlignmentSegment> a,
  List<AlignmentSegment> b,
  List<double> sub,
) {
  if (sub.isEmpty) return false;
  int agree = 0;
  for (final double s in sub) {
    final double d = alignmentOffsetAt(a, s) - alignmentOffsetAt(b, s);
    if (d.abs() <= kConsensusTolerance) agree++;
  }
  return agree / sub.length >= kConsensusAgreement;
}

int _byStrengthThenExcess(SubtitleReferenceGroup a, SubtitleReferenceGroup b) {
  final int s = b.judgement.strength.index.compareTo(
    a.judgement.strength.index,
  );
  if (s != 0) return s;
  return b.judgement.fit.excess.compareTo(a.judgement.fit.excess);
}

/// 多条参考轨各自独立对齐、去重、投票，给出最终决定。
///
/// 自动写入的条件（二选一）：
/// - ≥ 2 组**独立**参考都判接受，且映射一致、没有任何已接受的组唱反调；
/// - 只有 1 组独立参考判接受，且超出瞎碰概率 ≥ [kSingleReferenceAutoExcess] 倍。
///
/// 其余有像样结果的情况一律交人确认；什么都不像样就拒绝。
SubtitleSyncDecision decideSubtitleSync({
  required List<double> subtitleStarts,
  required List<SubtitleReferenceTrack> references,
  double? durationSeconds,
}) {
  final List<double> sub = uniqueCueStarts(subtitleStarts);
  final List<SubtitleReferenceGroup> groups = <SubtitleReferenceGroup>[
    for (final List<SubtitleReferenceTrack> g in groupReferenceTracks(
      references,
    ))
      SubtitleReferenceGroup(
        tracks: g,
        judgement: judgeSubtitleReferenceFit(
          fitSubtitleToReference(
            g.first.starts,
            sub,
            durationSeconds: durationSeconds,
          ),
          ref: g.first.starts,
          sub: sub,
        ),
      ),
  ]..sort(_byStrengthThenExcess);
  return _vote(groups, sub);
}

SubtitleSyncDecision _vote(
  List<SubtitleReferenceGroup> groups,
  List<double> sub,
) {
  SubtitleSyncDecision decision(
    SubtitleSyncDecisionKind kind, {
    SubtitleReferenceGroup? chosen,
    int agreeing = 0,
    bool conflicting = false,
  }) => SubtitleSyncDecision(
    kind: kind,
    groups: groups,
    chosen: chosen,
    agreeingGroups: agreeing,
    conflicting: conflicting,
  );
  if (groups.isEmpty ||
      groups.first.judgement.strength == AlignmentStrength.refused) {
    return decision(SubtitleSyncDecisionKind.refused);
  }
  final SubtitleReferenceGroup best = groups.first;
  if (best.judgement.strength != AlignmentStrength.accepted) {
    return decision(SubtitleSyncDecisionKind.needsConfirmation, chosen: best);
  }
  final List<SubtitleReferenceGroup> accepted = groups
      .where(
        (SubtitleReferenceGroup g) =>
            g.judgement.strength == AlignmentStrength.accepted,
      )
      .toList();
  final int agreeing = accepted
      .where(
        (SubtitleReferenceGroup g) => alignmentsAgree(
          best.judgement.fit.segments,
          g.judgement.fit.segments,
          sub,
        ),
      )
      .length;
  final bool conflicting = agreeing < accepted.length;
  final bool auto =
      !conflicting &&
      (agreeing >= 2 ||
          best.judgement.fit.excess >= kSingleReferenceAutoExcess);
  return decision(
    auto
        ? SubtitleSyncDecisionKind.autoApply
        : SubtitleSyncDecisionKind.needsConfirmation,
    chosen: best,
    agreeing: agreeing,
    conflicting: conflicting,
  );
}
