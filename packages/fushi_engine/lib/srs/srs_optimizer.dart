/// FSRS 自动优化（PR6，含第六轮审查第 10、11 条的修正）。
///
/// 三段：[srsPrepareOptimization]（取训练集：Rust 在 srs.db 上直读日志并选取，结果是一块字节）→
/// [srsRunOptimization]（纯计算，可放后台 isolate，支持取消；训练集在那边才展开）→ [srsApplyOptimization]
/// （写回牌组这一行，主 isolate）。
///
/// - 训练数据：own 牌组整棵 inherit 子树里全部卡片的有效评分日志（被撤销的、被判等价的导入日志已排除），
///   从最近一次重置算起；历史不完整（第一条不是学习类）的卡不进训练集；可证明时间有错（timeUncertain）的日志不进。
/// - 门槛按「过滤之后真正进训练集的条数」（#2999）。
/// - 采用判定：新参数在同一份数据上的 log loss 不高于当前参数才写入。**删掉修订版 8 的「训练条数 ≥ 当前参数组条数」**
///   （第六轮审查第 11 条：删子牌组 / 改 paramsMode 之后条数变少，参数就再也更新不了）。
/// - 跨算法比较（fsrs6 牌组且 algorithmAuto）：用时间序列切分的**外样本**评估（evaluateTimeSeries），
///   不用训练集内评估——FSRS-7 的 34 个参数在训练集内天然占便宜（第六轮审查第 11 条）。
/// - 写回的参数组标为机器产出（machine = true）：两台设备各自优化出的结果并发时，不进「同步冲突记录」（第 10 条）。
library;

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_projections.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// 首次优化的样本门槛（进训练集的评分条数）。
const int kSrsOptimizeMinItems = 400;

/// 之后每新增这个比例的复习、或距基线满 30 天，再跑一次。
const double kSrsOptimizeGrowth = 0.2;
const int kSrsOptimizeIntervalMs = 30 * 24 * 60 * 60 * 1000;

/// 一次优化的输入（可跨 isolate 传递：只含基本类型）。
class SrsOptimizationInput {
  const SrsOptimizationInput({
    required this.deckId,
    required this.algorithm,
    required this.algorithmAuto,
    required this.currentParams,
    required this.trainingSet,
  });

  final String deckId;
  final SrsAlgorithm algorithm;
  final bool algorithmAuto;

  /// 当前参数（空 = 默认）。
  final List<double> currentParams;

  /// 训练集（列式字节，跨 isolate 只拷一块）。
  final SrsTrainingSet trainingSet;

  /// 训练集：每条是一张卡到某次评分为止的历史前缀（按最后一次评分时刻排序，供时间序列切分），
  /// 带每张卡的数字 ID。打包成 TypedData，每张卡只存一份完整历史，前缀在原生侧展开（BUG-3745）。
  /// 第一次读时由 [trainingSet] 转换。
  SrsFsrsTrainingSet get items => trainingSet.fsrs;

  /// 进训练集的评分条数（门槛与基线用）。
  int get reviewCount => trainingSet.itemCount;
}

/// 一次优化的结果。
class SrsOptimizationResult {
  const SrsOptimizationResult({
    required this.deckId,
    required this.algorithm,
    required this.params,
    required this.logLoss,
    required this.previousLogLoss,
    required this.adopted,
    required this.switchedToFsrs7,
    required this.reviewCount,
  });

  final String deckId;
  final SrsAlgorithm algorithm;
  final List<double> params;
  final double logLoss;
  final double previousLogLoss;
  final bool adopted;
  final bool switchedToFsrs7;
  final int reviewCount;
}

/// 是否该跑（门槛与触发基线）。
bool srsShouldOptimize({
  required SrsDeckView owner,
  required int reviewCount,
  required int nowMs,
  required bool knownAlgorithmRev,
}) {
  if (!owner.autoOptimize || !knownAlgorithmRev) return false;
  if (reviewCount < kSrsOptimizeMinItems) return false;
  final int? baseAt = owner.optimizeBaselineAt;
  final int? baseN = owner.optimizeBaselineCount;
  if (baseAt == null || baseN == null) return true;
  if (reviewCount >= baseN * (1 + kSrsOptimizeGrowth)) return true;
  return nowMs - baseAt >= kSrsOptimizeIntervalMs;
}

/// 组训练数据。只对 own 牌组有意义（inherit 子牌组用祖先的参数）。
///
/// 训练范围 = own 牌组整棵 inherit 子树里的可见卡；有效评分的选取、记忆状态输入（历史完整才进）、
/// 「时间不确定」过滤都在 Rust 里（native/fushi_fsrs/src/projection.rs `optimizer_card`），日志不经 Dart。
Future<SrsOptimizationInput?> srsPrepareOptimization(
  SrsDbStore store,
  String deckId,
) async {
  final SrsDeckTree tree = await store.deckTree();
  final SrsDeckView? deck = tree[deckId];
  if (deck == null) return null;
  final SrsDeckView owner = tree.paramsOwner(deckId);
  final Set<String> scope = tree.paramsScope(owner.id).toSet();
  final SrsDayContext day = await store.dayContext();
  // RWKV 牌组优化的是它的影子记忆状态（FSRS-7）参数。
  final SrsAlgorithm alg = owner.localAlgorithm.memoryAlgorithm;
  final SrsParamSet? set = owner.paramSetFor(alg);
  return SrsOptimizationInput(
    deckId: owner.id,
    algorithm: alg,
    algorithmAuto: owner.algorithmAuto,
    currentParams: set?.params ?? const <double>[],
    trainingSet: await store.optimizerTrainingSet(
      await store.cardIdsInDecks(scope),
      algorithm: alg,
      day: day,
    ),
  );
}

/// 纯计算（可在后台 isolate 跑）。被取消时抛 [SrsFsrsException]（isCancelled）。
SrsOptimizationResult srsRunOptimization(
  FsrsEngine engine,
  SrsOptimizationInput input, {
  SrsOptimizerControl? control,
}) {
  final SrsAlgorithm alg = input.algorithm;
  final List<double> fresh = engine.computeParameters(
    algorithm: alg,
    items: input.items,
    control: control,
  );
  final List<double> current = input.currentParams.isEmpty
      ? engine.defaultParams(alg)
      : input.currentParams;
  final double newLoss = engine
      .evaluate(algorithm: alg, params: fresh, items: input.items)
      .logLoss;
  final double oldLoss = engine
      .evaluate(algorithm: alg, params: current, items: input.items)
      .logLoss;

  if (alg == SrsAlgorithm.fsrs6 && input.algorithmAuto) {
    if (control?.cancelled ?? false) {
      throw const SrsFsrsException('cancelled');
    }
    final double six = engine
        .evaluateTimeSeries(algorithm: SrsAlgorithm.fsrs6, items: input.items)
        .logLoss;
    final double seven = engine
        .evaluateTimeSeries(algorithm: SrsAlgorithm.fsrs7, items: input.items)
        .logLoss;
    if (seven < six) {
      final List<double> p7 = engine.computeParameters(
        algorithm: SrsAlgorithm.fsrs7,
        items: input.items,
        control: control,
      );
      return SrsOptimizationResult(
        deckId: input.deckId,
        algorithm: SrsAlgorithm.fsrs7,
        params: p7,
        logLoss: seven,
        previousLogLoss: six,
        adopted: true,
        switchedToFsrs7: true,
        reviewCount: input.reviewCount,
      );
    }
  }
  return SrsOptimizationResult(
    deckId: input.deckId,
    algorithm: alg,
    params: fresh,
    logLoss: newLoss,
    previousLogLoss: oldLoss,
    adopted: newLoss <= oldLoss,
    switchedToFsrs7: false,
    reviewCount: input.reviewCount,
  );
}

/// 写回：参数组、（切换时）算法、触发基线在同一次修改里写（同一个 ctx），标为机器产出。
/// 没采用时只更新基线，免得下一次空闲时立刻重跑。
Future<void> srsApplyOptimization(
  SrsDbStore store,
  SrsOptimizationResult r, {
  required String fsrsRev,
}) async {
  final (int nowMs, _) = store.now();
  final Map<String, Object?> values = <String, Object?>{
    SrsFieldKeys.deckOptimizeBaseline: <String, Object?>{
      'at': nowMs,
      'n': r.reviewCount,
    },
  };
  if (r.adopted) {
    final String key = r.algorithm == SrsAlgorithm.fsrs7
        ? SrsFieldKeys.deckFsrs7Params
        : SrsFieldKeys.deckFsrs6Params;
    values[key] = SrsParamSet(
      params: r.params,
      algorithmRev: fsrsRev,
      optimizedAt: nowMs,
      trainCount: r.reviewCount,
      logLoss: r.logLoss,
    ).toValue();
    if (r.switchedToFsrs7) {
      values[SrsFieldKeys.deckAlgorithm] = <String, Object?>{
        'alg': SrsAlgorithm.fsrs7.wire,
        'auto': true,
      };
    }
  }
  await store.editFields(SrsEntityKind.deck, r.deckId, values, machine: true);
}

/// 「恢复默认参数」/ 手动改参数：同时把触发基线重置为「此刻 + 当前有效复习条数」，
/// 下一轮自动优化要等再新增一定比例的复习或满 30 天才跑，不会立刻覆盖用户的选择。用户操作，不是机器产出。
Future<void> srsResetParams(
  SrsDbStore store,
  String deckId,
  SrsAlgorithm algorithm, {
  required int reviewCount,
}) async {
  final (int nowMs, _) = store.now();
  await store.editFields(SrsEntityKind.deck, deckId, <String, Object?>{
    algorithm.memoryAlgorithm == SrsAlgorithm.fsrs7
            ? SrsFieldKeys.deckFsrs7Params
            : SrsFieldKeys.deckFsrs6Params:
        null,
    SrsFieldKeys.deckOptimizeBaseline: <String, Object?>{
      'at': nowMs,
      'n': reviewCount,
    },
  });
}
