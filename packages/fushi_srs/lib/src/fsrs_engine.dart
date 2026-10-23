/// FSRS 计算接口：排程（next_states）、由历史重建记忆状态、SM-2 起点换算、
/// 参数优化与评估。唯一的生产实现是 native/fushi_fsrs（fsrs-rs）的 FFI 绑定
/// [FfiFsrsEngine]；本包不维护第二套公式（计划「前提 4」）。
///
/// elapsed 一律是**小数天**：FSRS-7 的优势来自当天内复习，传整数天会把它抹掉
/// （第六轮审查第 12 条）。
library;

import 'dart:typed_data';

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

/// 参数优化 / 评估的训练集，打包成 TypedData（BUG-3662）。
///
/// 优化器的训练条目是「一张卡到某次评分为止的历史前缀」，一张 n 次评分的卡贡献 n-1 条。
/// 这里每张卡只存一份完整历史（[ratings] / [deltaDays] 按 [cardOffsets] 切段），条目只记
/// `(卡序号, 前缀长度)`（[itemCards] / [itemLengths]，顺序即训练顺序：按评分时刻排好，供时间序列切分
/// 与 fsrs-rs 的按序近期权重）。前缀由原生侧展开，Dart 侧与 FFI 边界只有 O(总评分数) 的数据。
/// 全是 TypedData，跨 isolate 发送是一次内存拷贝。
class SrsFsrsTrainingSet {
  SrsFsrsTrainingSet({
    required this.ratings,
    required this.deltaDays,
    required this.cardOffsets,
    required this.itemCards,
    required this.itemLengths,
    this.cardIds,
  }) {
    if (deltaDays.length != ratings.length ||
        cardOffsets.isEmpty ||
        cardOffsets.last != ratings.length ||
        itemLengths.length != itemCards.length ||
        (cardIds != null && cardIds!.length != cardOffsets.length - 1)) {
      throw ArgumentError('inconsistent SrsFsrsTrainingSet buffers');
    }
  }

  /// 所有卡的评分拼在一起（1..4）。
  final Uint8List ratings;

  /// 与 [ratings] 一一对应：距上一次评分的小数天（每张卡第一条为 0）。
  final Float32List deltaDays;

  /// 卡 c 的历史 = `[cardOffsets[c], cardOffsets[c + 1])`，长度 = 卡数 + 1。
  final Uint32List cardOffsets;

  /// 每张卡的数字 ID（可空）。非空时参数优化按条目对齐传给 fsrs-rs（FSRS-7 同卡前缀按扩展窗口训练）；
  /// 两种评估不用它（与 fsrs-rs 的 evaluate / 时间序列切分口径一致）。
  final Int64List? cardIds;

  /// 第 i 条训练条目所属的卡序号。
  final Uint32List itemCards;

  /// 第 i 条训练条目的前缀长度（≥ 1，不超过该卡评分数）。
  final Uint32List itemLengths;

  /// 训练条目数。
  int get length => itemCards.length;

  int get cardCount => cardOffsets.length - 1;

  /// 第 [i] 条训练条目展开成的历史（测试替身与调试用；生产路径不展开）。
  List<SrsFsrsReview> item(int i) {
    final int from = cardOffsets[itemCards[i]];
    return <SrsFsrsReview>[
      for (int k = from; k < from + itemLengths[i]; k++)
        SrsFsrsReview(rating: ratings[k], deltaDays: deltaDays[k]),
    ];
  }
}

/// 逐卡拼装 [SrsFsrsTrainingSet]：先 [addCard] 登记每张卡的完整历史，再按训练顺序 [addItem]。
class SrsFsrsTrainingSetBuilder {
  final List<int> _ratings = <int>[];
  final List<double> _deltas = <double>[];
  final List<int> _offsets = <int>[0];
  final List<int> _ids = <int>[];
  final List<int> _itemCards = <int>[];
  final List<int> _itemLengths = <int>[];
  bool? _withIds;

  /// 登记一张卡的完整历史，返回卡序号。[cardId] 要么每张卡都给、要么都不给。
  int addCard(List<SrsFsrsReview> history, {int? cardId}) {
    final bool withId = cardId != null;
    if (_withIds != null && _withIds != withId) {
      throw ArgumentError('cardId must be given for every card or none');
    }
    _withIds = withId;
    for (final SrsFsrsReview r in history) {
      _ratings.add(r.rating);
      _deltas.add(r.deltaDays);
    }
    _offsets.add(_ratings.length);
    if (cardId != null) _ids.add(cardId);
    return _offsets.length - 2;
  }

  /// 追加一条训练条目：卡 [card] 的前 [length] 次评分。
  void addItem(int card, int length) {
    if (card < 0 || card >= _offsets.length - 1) {
      throw RangeError.range(card, 0, _offsets.length - 2, 'card');
    }
    final int history = _offsets[card + 1] - _offsets[card];
    if (length < 1 || length > history) {
      throw RangeError.range(length, 1, history, 'length');
    }
    _itemCards.add(card);
    _itemLengths.add(length);
  }

  SrsFsrsTrainingSet build() => SrsFsrsTrainingSet(
    ratings: Uint8List.fromList(_ratings),
    deltaDays: Float32List.fromList(_deltas),
    cardOffsets: Uint32List.fromList(_offsets),
    cardIds: (_withIds ?? false) ? Int64List.fromList(_ids) : null,
    itemCards: Uint32List.fromList(_itemCards),
    itemLengths: Uint32List.fromList(_itemLengths),
  );
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

  /// 参数优化（阻塞；调用方放后台 isolate）。[items] 每条是一张卡到某次评分为止的历史前缀，
  /// 按评分时刻排好序；带 card ID 时按卡对齐传给 fsrs-rs。
  List<double> computeParameters({
    required SrsAlgorithm algorithm,
    required SrsFsrsTrainingSet items,
    SrsOptimizerControl? control,
  });

  /// 时间序列切分的外样本评估（[items] 按复习时间排好序）。
  /// 跨算法比较与新旧参数采用判定用这个，不用训练集内评估（第六轮审查第 11 条）。
  SrsEvaluation evaluateTimeSeries({
    required SrsAlgorithm algorithm,
    required SrsFsrsTrainingSet items,
  });

  /// 给定参数在 [items] 上的评估（训练集内，只用于展示）。
  SrsEvaluation evaluate({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsFsrsTrainingSet items,
  });
}

/// 能一次算完一批卡可提取度的引擎（[FfiFsrsEngine]）。单独成接口，测试替身照旧只实现
/// [FsrsEngine]，经 [srsRetrievabilityBatch] 退回逐张调用。
abstract interface class FsrsBatchEngine implements FsrsEngine {
  /// 同一组参数下逐张的可提取度，与逐张调 [FsrsEngine.retrievability] 结果一致。
  /// [memories] 与 [elapsedDays] 等长。
  List<double> retrievabilityBatch({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<SrsMemory> memories,
    required List<double> elapsedDays,
  });
}

/// 批量可提取度：[engine] 支持批量就一次调用，否则逐张调用。
List<double> srsRetrievabilityBatch(
  FsrsEngine engine, {
  required SrsAlgorithm algorithm,
  required List<double> params,
  required List<SrsMemory> memories,
  required List<double> elapsedDays,
}) {
  if (memories.length != elapsedDays.length) {
    throw ArgumentError('memories and elapsedDays differ in length');
  }
  if (engine is FsrsBatchEngine) {
    return engine.retrievabilityBatch(
      algorithm: algorithm,
      params: params,
      memories: memories,
      elapsedDays: elapsedDays,
    );
  }
  return <double>[
    for (int i = 0; i < memories.length; i++)
      engine.retrievability(
        algorithm: algorithm,
        params: params,
        memory: memories[i],
        elapsedDays: elapsedDays[i],
      ),
  ];
}
