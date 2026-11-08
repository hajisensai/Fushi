/// 复习统计页的校准图与 UM+：每次复习**作答前**的预测回忆概率 vs 实际是否记住，FSRS 与 RWKV 两个模型对比。
///
/// 移植自 JSchoreels/Anki-Search-Stats-Extended @ 526a4f9（kuma3-anki-app 把同一份页面搬上 AnkiDroid）。分箱、
/// 自助法区间、UM+ 的数学在 Rust（native/fushi_fsrs/src/calibration.rs），这里只编排：
///
/// 1. 每个参数组一份训练集（[SrsDbStore.calibrationItems]），后台 isolate 里做**时间序列切分的留出预测**
///    （[FfiFsrsEngine.predictTimeSeries]）：第 k 段只用之前的复习训练参数，预测的那些复习 FSRS 没见过——
///    这才是诚实的校准（拿全量训练出的参数去「预测」训练集本身，曲线会好看得失真）；
/// 2. RWKV：临时 runtime 把全部保留评分从头回放一遍，记下每条作答前的 R（[srsRwkvReplayPredictions]）。RWKV 是
///    在别的用户上预训练的模型，回放时每条都只用到它之前的历史，本身就是留出的；
/// 3. [srsCalibrationReport]：按统计页的牌组 / 时间范围筛样本、配对、分箱、自助法区间与 UM+。
///
/// 1、2 与牌组 / 时间范围无关（[SrsCalibrationData]）：统计页换筛选只重做 3。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_projections.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';

/// 进行到哪一步（进度条文案用）。
enum SrsCalibrationPhase {
  /// FSRS 各折训练（`done / total` 是原生训练进度，按参数组依次累加）。
  fsrs,

  /// RWKV 回放（`done / total` 是回放行数）。
  rwkv,
}

typedef SrsCalibrationProgress =
    void Function(SrsCalibrationPhase phase, int done, int total);

/// 一份校准原料：每个可进校准的复习一条（与牌组 / 时间范围无关）。各列等长，交给 [srsCalibrationReport]。
class SrsCalibrationData {
  const SrsCalibrationData({
    required this.cards,
    required this.tags,
    required this.ats,
    required this.elapsed,
    required this.actual,
    required this.fsrs,
    required this.rwkvTags,
    required this.rwkvPredictions,
  });

  /// 空（没有可训练的复习）。
  factory SrsCalibrationData.empty() => SrsCalibrationData(
    cards: Int64List(0),
    tags: Int64List(0),
    ats: Int64List(0),
    elapsed: Int64List(0),
    actual: Int64List(0),
    fsrs: Float32List(0),
    rwkvTags: Int64List(0),
    rwkvPredictions: Float32List(0),
  );

  /// 卡的数字 id（[SrsIds.ankiNumericIds]）。
  final Int64List cards;

  /// 复习日志数字 id（与 RWKV 回放行的标签同一个）。
  final Int64List tags;
  final Int64List ats;

  /// 距上一次评分的复习日天数。
  final Int64List elapsed;

  /// 1 = 记住（评分 > 1）。
  final Int64List actual;

  /// FSRS 留出预测；NaN = 没有（第一段只训练、或数据不够训练）。
  final Float32List fsrs;

  /// RWKV 回放预测（按日志数字 id 配对）；空 = 没有 RWKV（模型没下载）。
  final Int64List rwkvTags;
  final Float32List rwkvPredictions;

  int get length => cards.length;
  bool get hasRwkv => rwkvTags.isNotEmpty;
}

/// 主 isolate 实际加载的 fushi_fsrs 路径（iOS 静态链接时为 null，子 isolate 按默认规则重新解析）。
String? srsFsrsLibraryPath() => FushiFsrs.instance?.libraryPath;

/// 第 1、2 步（见库注释）。[rwkv] 为 null 或模型没下载时只有 FSRS。[control] 的取消对 FSRS 各折与 RWKV 回放都生效。
Future<SrsCalibrationData> srsCalibrationData(
  SrsDbStore store, {
  SrsRwkvService? rwkv,
  String? fsrsLibraryPath,
  SrsCalibrationProgress? onProgress,
  NativeSrsOptimizerControl? control,
}) async {
  final SrsDeckTree tree = await store.deckTree();
  final SrsDayContext day = await store.dayContext();
  final Map<String, SrsDeckView> owners = <String, SrsDeckView>{
    for (final SrsDeckView d in tree.decks)
      tree.paramsOwner(d.id).id: tree.paramsOwner(d.id),
  };
  final List<(SrsCalibrationItems, Float32List)> parts =
      <(SrsCalibrationItems, Float32List)>[];
  final List<String> ownerIds = owners.keys.toList()..sort();
  for (int o = 0; o < ownerIds.length; o++) {
    final SrsDeckView owner = owners[ownerIds[o]]!;
    final List<String> cards = await store.cardIdsInDecks(
      tree.paramsScope(owner.id).toSet(),
    );
    if (cards.isEmpty) continue;
    final SrsCalibrationItems items = await store.calibrationItems(
      cards,
      algorithm: owner.localAlgorithm.memoryAlgorithm,
      day: day,
    );
    if (items.length == 0) continue;
    if (control?.cancelled ?? false) {
      throw const SrsFsrsException('cancelled');
    }
    final Float32List fsrs = await _predictInIsolate(
      items.training,
      owner.localAlgorithm.memoryAlgorithm,
      fsrsLibraryPath,
      control,
      onProgress == null
          ? null
          : (int done, int total) => onProgress(
              SrsCalibrationPhase.fsrs,
              o * 1000 + (total == 0 ? 0 : done * 1000 ~/ total),
              ownerIds.length * 1000,
            ),
    );
    parts.add((items, fsrs));
  }
  final SrsRwkvPredictions? rw = rwkv == null || !rwkv.models.isReady
      ? null
      : await srsRwkvReplayPredictions(
          rwkv,
          control: control,
          onProgress: onProgress == null
              ? null
              : (int done, int total) =>
                    onProgress(SrsCalibrationPhase.rwkv, done, total),
        );
  return _concat(parts, rw);
}

SrsCalibrationData _concat(
  List<(SrsCalibrationItems, Float32List)> parts,
  SrsRwkvPredictions? rwkv,
) {
  final int n = parts.fold<int>(
    0,
    (int s, (SrsCalibrationItems, Float32List) p) => s + p.$1.length,
  );
  final Int64List cards = Int64List(n);
  final Int64List tags = Int64List(n);
  final Int64List ats = Int64List(n);
  final Int64List elapsed = Int64List(n);
  final Int64List actual = Int64List(n);
  final Float32List fsrs = Float32List(n);
  int at = 0;
  for (final (SrsCalibrationItems items, Float32List pred) in parts) {
    final int end = at + items.length;
    cards.setRange(at, end, items.cards);
    tags.setRange(at, end, items.tags);
    ats.setRange(at, end, items.ats);
    elapsed.setRange(at, end, items.elapsed);
    actual.setRange(at, end, items.actual);
    fsrs.setRange(at, end, pred);
    at = end;
  }
  return SrsCalibrationData(
    cards: cards,
    tags: tags,
    ats: ats,
    elapsed: elapsed,
    actual: actual,
    fsrs: fsrs,
    rwkvTags: rwkv?.tags ?? Int64List(0),
    rwkvPredictions: rwkv?.predictions ?? Float32List(0),
  );
}

/// 留出预测在后台 isolate 里跑（参数训练要几秒到几分钟），取消 / 进度经原生内存共享。
Future<Float32List> _predictInIsolate(
  SrsTrainingSet items,
  SrsAlgorithm algorithm,
  String? libraryPath,
  NativeSrsOptimizerControl? outer,
  void Function(int done, int total)? onProgress,
) async {
  final NativeSrsOptimizerControl control = NativeSrsOptimizerControl();
  final int cancelAddress = control.cancelAddress;
  final int progressAddress = control.progressAddress;
  final Timer ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
    if (outer?.cancelled ?? false) control.cancel();
    final (int done, int total) = control.progress;
    onProgress?.call(done, total);
  });
  try {
    return await Isolate.run<Float32List>(
      _predictBody(
        items,
        algorithm,
        libraryPath,
        cancelAddress,
        progressAddress,
      ),
    );
  } finally {
    ticker.cancel();
    // 预测调用已返回（或抛出）：原生侧不会再写这块内存。
    control.dispose();
  }
}

/// 后台 isolate 的入口（顶层函数：只捕获可跨 isolate 发送的值）。
Float32List Function() _predictBody(
  SrsTrainingSet items,
  SrsAlgorithm algorithm,
  String? libraryPath,
  int cancelAddress,
  int progressAddress,
) => () {
  final FfiFsrsEngine? engine = FfiFsrsEngine.tryCreate(
    libraryPath: libraryPath,
  );
  if (engine == null) {
    throw const SrsFsrsException('scheduling engine unavailable');
  }
  // 条目太少切不出一段（每段至少一条）：没有留出预测。
  if (items.itemCount < 6) {
    return Float32List(items.itemCount)
      ..fillRange(0, items.itemCount, double.nan);
  }
  return engine.predictTimeSeries(
    algorithm: algorithm,
    items: items.fsrs,
    control: NativeSrsOptimizerControl.fromAddress(
      cancelAddress: cancelAddress,
      progressAddress: progressAddress,
    ),
  );
};

/// RWKV 回放预测：每条保留评分作答前的 R 与它的日志数字 id。
class SrsRwkvPredictions {
  const SrsRwkvPredictions(this.tags, this.predictions);

  final Int64List tags;
  final Float32List predictions;
}

/// 第 2 步：临时 runtime（与排程同一个模型、同一个精度）把全部保留评分从头回放，记下每条作答前的 R。
/// 不碰排程用的常驻状态。[spawn] 供测试替换。
Future<SrsRwkvPredictions> srsRwkvReplayPredictions(
  SrsRwkvService rwkv, {
  NativeSrsOptimizerControl? control,
  void Function(int done, int total)? onProgress,
  Future<RwkvWorker> Function(File weights)? spawn,
}) async {
  final SrsRwkvReplay replay = await rwkv.calibrationReplay();
  final int n = replay.rows.length;
  final Float32List out = Float32List(n);
  if (n == 0) return SrsRwkvPredictions(replay.tags, out);
  final RwkvWorker worker =
      await (spawn ??
          (File w) => RwkvWorker.spawn(
            modelPath: w.path,
            precision: SrsRwkvService.precision,
          ))(rwkv.models.weightsFile);
  try {
    final Uint8List bytes = replay.rows.bytes;
    const int block = 65536;
    onProgress?.call(0, n);
    for (int start = 0; start < n; start += block) {
      if (control?.cancelled ?? false) {
        throw const SrsFsrsException('cancelled');
      }
      final int end = math.min(start + block, n);
      final Float32List? p = await worker.replay(
        RwkvRows.fromBytes(
          Uint8List.sublistView(
            bytes,
            start * kFrwkvReviewSize,
            end * kFrwkvReviewSize,
          ),
        ),
        predictions: true,
      );
      if (p != null) out.setRange(start, end, p);
      onProgress?.call(end, n);
    }
    return SrsRwkvPredictions(replay.tags, out);
  } finally {
    await worker.close();
  }
}

/// 第 3 步：按牌组（[scopeCardIds]，null = 全部）与时间范围 `[fromMs, toMs)` 出一份校准图 + UM+。阻塞（自助法
/// 500 次），大集合放后台 isolate。
SrsCalibrationReport srsCalibrationReport(
  FfiFsrsEngine engine,
  SrsCalibrationData data, {
  List<String>? scopeCardIds,
  int? fromMs,
  int? toMs,
}) => SrsCalibrationReport.fromJson(
  engine.calibrationReport(
    cards: data.cards,
    tags: data.tags,
    ats: data.ats,
    elapsed: data.elapsed,
    actual: data.actual,
    fsrs: data.fsrs,
    rwkvTags: data.rwkvTags,
    rwkvPreds: data.rwkvPredictions,
    scopeCards: scopeCardIds == null
        ? Int64List(0)
        : Int64List.fromList(SrsIds.ankiNumericIds(scopeCardIds)),
    fromMs: fromMs,
    toMs: toMs,
  ),
  hasRwkv: data.hasRwkv,
);

/// 校准图的一箱（20 个对数分箱，见 calibration.rs）。
class SrsCalibrationBin {
  const SrsCalibrationBin({
    required this.index,
    required this.count,
    required this.predicted,
    required this.actual,
    this.lower,
    this.upper,
  });

  final int index;
  final int count;

  /// 箱均预测。
  final double predicted;

  /// 箱均实际（记住率）。
  final double actual;

  /// 实际记住率的 95% 卡级自助法区间。
  final double? lower;
  final double? upper;
}

/// 一条校准曲线。
class SrsCalibrationSeries {
  const SrsCalibrationSeries({
    required this.count,
    required this.logLoss,
    required this.rmse,
    required this.bins,
  });

  final int count;
  final double logLoss;

  /// 校准箱「箱均预测 − 箱均实际」按条数加权的 RMSE。
  final double rmse;

  /// 非空的箱（按箱序）。
  final List<SrsCalibrationBin> bins;

  static SrsCalibrationSeries? fromJson(Object? json) {
    if (json is! Map) return null;
    final List<Object?> raw = (json['bins'] as List<Object?>?) ?? <Object?>[];
    return SrsCalibrationSeries(
      count: (json['count'] as num).toInt(),
      logLoss: (json['logLoss'] as num).toDouble(),
      rmse: (json['rmse'] as num).toDouble(),
      bins: <SrsCalibrationBin>[
        for (int i = 0; i < raw.length; i++)
          if (raw[i] case final Map<Object?, Object?> b)
            SrsCalibrationBin(
              index: i,
              count: (b['count'] as num).toInt(),
              predicted: (b['predicted'] as num).toDouble(),
              actual: (b['actual'] as num).toDouble(),
              lower: (b['lower'] as num?)?.toDouble(),
              upper: (b['upper'] as num?)?.toDouble(),
            ),
      ],
    );
  }
}

/// UM+ 的一箱（按分歧 FSRS − RWKV 分 41 箱）。
class SrsUmPlusBin {
  const SrsUmPlusBin({
    required this.index,
    required this.count,
    required this.disagreement,
    required this.fsrsError,
    required this.rwkvError,
  });

  final int index;
  final int count;
  final double disagreement;

  /// 箱内平均预测误差（预测 − 实际）。
  final double fsrsError;
  final double rwkvError;
}

/// 少于这么多条配对复习的箱默认不画（`UM_PLUS_SMALL_BUCKET_THRESHOLD`）；分数照样算全部箱。
const int kSrsUmPlusSmallBucket = 200;

class SrsUmPlus {
  const SrsUmPlus({
    required this.count,
    required this.fsrsScore,
    required this.rwkvScore,
    required this.bins,
  });

  final int count;

  /// 按条数加权的箱均误差 RMSE（越小越好）。
  final double fsrsScore;
  final double rwkvScore;
  final List<SrsUmPlusBin> bins;

  static SrsUmPlus? fromJson(Object? json) {
    if (json is! Map) return null;
    return SrsUmPlus(
      count: (json['count'] as num).toInt(),
      fsrsScore: (json['fsrsScore'] as num).toDouble(),
      rwkvScore: (json['rwkvScore'] as num).toDouble(),
      bins: <SrsUmPlusBin>[
        for (final Object? b in (json['bins'] as List<Object?>))
          if (b case final Map<Object?, Object?> m)
            SrsUmPlusBin(
              index: (m['index'] as num).toInt(),
              count: (m['count'] as num).toInt(),
              disagreement: (m['disagreement'] as num).toDouble(),
              fsrsError: (m['fsrsError'] as num).toDouble(),
              rwkvError: (m['rwkvError'] as num).toDouble(),
            ),
      ],
    );
  }

  /// 要画的箱（`visibleUmPlusBins`）。
  List<SrsUmPlusBin> visibleBins({required bool showSmall}) => showSmall
      ? bins
      : <SrsUmPlusBin>[
          for (final SrsUmPlusBin b in bins)
            if (b.count >= kSrsUmPlusSmallBucket) b,
        ];
}

/// 横轴（分歧）范围：可见箱的分歧向外取整到 0.1（`umPlusDisagreementDomain`）。
(double, double) srsUmPlusDisagreementDomain(List<SrsUmPlusBin> bins) =>
    _tenthDomain(
      <double>[for (final SrsUmPlusBin b in bins) b.disagreement],
      (-1, 1),
    );

/// 纵轴（误差）范围：可见箱两个模型的误差与 0 向外取整到 0.1，0 恒在图内（`umPlusErrorDomain`）。
(double, double) srsUmPlusErrorDomain(List<SrsUmPlusBin> bins) {
  if (bins.isEmpty) return (-0.1, 0.1);
  var (double lo, double hi) = _tenthDomain(
    <double>[
      0,
      for (final SrsUmPlusBin b in bins) ...<double>[b.fsrsError, b.rwkvError],
    ],
    (-0.1, 0.1),
  );
  if (lo == 0) lo = -0.1;
  if (hi == 0) hi = 0.1;
  return (lo, hi);
}

(double, double) _tenthDomain(List<double> values, (double, double) fallback) {
  if (values.isEmpty) return fallback;
  const double step = 0.1;
  const double tolerance = 1e-10;
  final double minV = values.reduce(math.min);
  final double maxV = values.reduce(math.max);
  double lo = math.max(-1, ((minV + tolerance) / step).floorToDouble() * step);
  double hi = math.min(1, ((maxV - tolerance) / step).ceilToDouble() * step);
  if ((hi - lo).abs() < tolerance) {
    lo = math.max(-1, lo - step);
    hi = math.min(1, hi + step);
  }
  return (
    double.parse(lo.toStringAsFixed(1)),
    double.parse(hi.toStringAsFixed(1)),
  );
}

/// 可见箱上「误差 ~ 分歧」按条数加权的线性回归斜率（`weightedRegressionSlope`）；分歧几乎没有变化时 null。
/// 越接近 0 越好：分歧变大时这个模型的误差不跟着变。
double? srsUmPlusSlope(
  List<SrsUmPlusBin> bins,
  double Function(SrsUmPlusBin b) value,
) {
  final int count = bins.fold<int>(0, (int s, SrsUmPlusBin b) => s + b.count);
  if (count == 0) return null;
  double sum(double Function(SrsUmPlusBin b) f) =>
      bins.fold<double>(0, (double s, SrsUmPlusBin b) => s + b.count * f(b));
  final double meanX = sum((SrsUmPlusBin b) => b.disagreement) / count;
  final double meanY = sum(value) / count;
  final double cov = sum(
    (SrsUmPlusBin b) => (b.disagreement - meanX) * (value(b) - meanY),
  );
  final double variance = sum(
    (SrsUmPlusBin b) => math.pow(b.disagreement - meanX, 2).toDouble(),
  );
  return variance > 1e-12 ? cov / variance : null;
}

/// 一份校准图 + UM+（[srsCalibrationReport]）。
class SrsCalibrationReport {
  const SrsCalibrationReport({
    required this.eligible,
    required this.hasRwkv,
    this.fsrs,
    this.rwkv,
    this.umPlus,
  });

  factory SrsCalibrationReport.fromJson(
    Map<String, Object?> json, {
    required bool hasRwkv,
  }) => SrsCalibrationReport(
    eligible: (json['eligible'] as num?)?.toInt() ?? 0,
    hasRwkv: hasRwkv,
    fsrs: SrsCalibrationSeries.fromJson(json['fsrs']),
    rwkv: SrsCalibrationSeries.fromJson(json['rwkv']),
    umPlus: SrsUmPlus.fromJson(json['umPlus']),
  );

  /// 范围内可进校准的复习数（不论有没有预测）。
  final int eligible;

  /// 这份数据带 RWKV 预测（模型已下载）。
  final bool hasRwkv;
  final SrsCalibrationSeries? fsrs;
  final SrsCalibrationSeries? rwkv;
  final SrsUmPlus? umPlus;
}
