/// FSRS 计算接口：排程（next_states）、由历史重建记忆状态、SM-2 起点换算、
/// 参数优化与评估。唯一的生产实现是 native/fushi_fsrs（fsrs-rs）的 FFI 绑定
/// [FfiFsrsEngine]；本包不维护第二套公式（计划「前提 4」）。
///
/// elapsed 一律是**小数天**：FSRS-7 的优势来自当天内复习，传整数天会把它抹掉
/// （第六轮审查第 12 条）。
library;

import 'algorithm.dart';

/// FSRS 记忆状态。[stabilityFast] 是 FSRS-7 的快速分量，FSRS-6 恒等于 [stability]。
class SrsMemory {
  const SrsMemory({
    required this.stability,
    required this.difficulty,
    double? stabilityFast,
  }) : stabilityFast = stabilityFast ?? stability;

  final double stability;
  final double difficulty;
  final double stabilityFast;

  Map<String, Object?> toJson() => <String, Object?>{
    's': stability,
    'd': difficulty,
    'sf': stabilityFast,
  };

  static SrsMemory? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? s = json['s'];
    final Object? d = json['d'];
    if (s is! num || d is! num) return null;
    final Object? sf = json['sf'];
    return SrsMemory(
      stability: s.toDouble(),
      difficulty: d.toDouble(),
      stabilityFast: sf is num ? sf.toDouble() : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SrsMemory &&
      other.stability == stability &&
      other.difficulty == difficulty &&
      other.stabilityFast == stabilityFast;

  @override
  int get hashCode => Object.hash(stability, difficulty, stabilityFast);

  @override
  String toString() =>
      'SrsMemory(s=$stability, d=$difficulty, sf=$stabilityFast)';
}

/// 某个评分按钮之后的记忆状态与（未取整、未 fuzz 的）间隔天数。
class SrsItemState {
  const SrsItemState({required this.memory, required this.interval});

  final SrsMemory memory;
  final double interval;
}

/// 四个评分按钮各自的下一状态。
class SrsNextStates {
  const SrsNextStates({
    required this.again,
    required this.hard,
    required this.good,
    required this.easy,
  });

  final SrsItemState again;
  final SrsItemState hard;
  final SrsItemState good;
  final SrsItemState easy;

  SrsItemState forRating(int rating) => switch (rating) {
    1 => again,
    2 => hard,
    3 => good,
    4 => easy,
    _ => throw ArgumentError.value(rating, 'rating', 'must be 1..4'),
  };
}

/// 一次评分在 FSRS 历史里的形状：评分与距上一次评分的天数（小数，第一条为 0）。
class SrsFsrsReview {
  const SrsFsrsReview({required this.rating, required this.deltaDays});

  final int rating;
  final double deltaDays;

  Map<String, Object?> toJson() => <String, Object?>{
    'rating': rating,
    'deltaT': deltaDays,
  };
}

/// 优化 / 评估的结果指标。
class SrsEvaluation {
  const SrsEvaluation({required this.logLoss, required this.rmseBins});

  final double logLoss;
  final double rmseBins;
}

/// 优化器的取消与进度通道。[FfiFsrsEngine] 用原生内存实现，可跨 isolate 共享地址。
abstract interface class SrsOptimizerControl {
  bool get cancelled;
  void cancel();

  /// [已处理, 总数]；总数为 0 表示还没开始。
  (int, int) get progress;
}

/// FSRS 计算失败（参数不合法、数据不足、被取消、原生库错误）。
class SrsFsrsException implements Exception {
  const SrsFsrsException(this.message);

  final String message;

  bool get isCancelled => message == 'cancelled';

  @override
  String toString() => 'SrsFsrsException: $message';
}

/// FSRS 计算接口。参数 `params` 为空表示该算法的默认参数。
abstract interface class FsrsEngine {
  /// 原生库的 fsrs-rs 源码版本（写进参数组的 algorithmRev）。
  String get fsrsRev;

  /// 该算法的默认参数。
  List<double> defaultParams(SrsAlgorithm algorithm);

  /// 参数校验：个数与算法一致、取值有限且被 fsrs-rs 接受。不合法返回原因，合法返回 null。
  String? validateParams(SrsAlgorithm algorithm, List<double> params);

  SrsNextStates nextStates({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double desiredRetention,
    required SrsMemory? memory,
    required double elapsedDays,
  });

  /// 由评分历史重建记忆状态；[starting] = 锚点换算出的起点（空 = 新卡）。
  /// [reviews] 为空时返回 [starting]。
  SrsMemory? memoryState({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<SrsFsrsReview> reviews,
    SrsMemory? starting,
  });

  /// 由 SM-2 的 ease / 间隔近似记忆状态（历史不完整的卡，铁律 A ③）。
  SrsMemory memoryStateFromSm2({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double easeFactor,
    required double intervalDays,
    required double sm2Retention,
  });

  /// 当前可提取度（复习排序用）。
  double retrievability({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsMemory memory,
    required double elapsedDays,
  });

  /// 参数优化（阻塞；调用方放后台 isolate）。[items] 每项是一张卡到某次评分为止的历史。
  List<double> computeParameters({
    required SrsAlgorithm algorithm,
    required List<List<SrsFsrsReview>> items,
    List<int>? cardIds,
    SrsOptimizerControl? control,
  });

  /// 时间序列切分的外样本评估（[items] 按复习时间排好序）。
  /// 跨算法比较与新旧参数采用判定用这个，不用训练集内评估（第六轮审查第 11 条）。
  SrsEvaluation evaluateTimeSeries({
    required SrsAlgorithm algorithm,
    required List<List<SrsFsrsReview>> items,
  });

  /// 给定参数在 [items] 上的评估（训练集内，只用于展示）。
  SrsEvaluation evaluate({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<List<SrsFsrsReview>> items,
  });
}
