import 'package:fushi_srs/fushi_srs.dart';

/// 协议测试用的确定性假引擎（不是 FSRS）：只需要「同输入同输出」与间隔单调。
/// 真实数值由 ffi_fsrs_engine_test.dart 对 native/fushi_fsrs 测。
class FakeFsrsEngine implements FsrsEngine {
  const FakeFsrsEngine();

  @override
  String get fsrsRev => 'fake';

  @override
  List<double> defaultParams(SrsAlgorithm algorithm) =>
      List<double>.filled(algorithm.paramCount, 1);

  @override
  String? validateParams(SrsAlgorithm algorithm, List<double> params) =>
      params.isEmpty || params.length == algorithm.paramCount
      ? null
      : 'bad count';

  SrsMemory _step(SrsMemory? m, int rating, double elapsed) {
    final double s = m?.stability ?? 0;
    final double d = m?.difficulty ?? 5;
    final double ns = switch (rating) {
      1 => 0.2 + s * 0.1,
      2 => 1 + s * 1.2 + elapsed * 0.05,
      3 => 2 + s * 2.5 + elapsed * 0.1,
      _ => 4 + s * 4 + elapsed * 0.2,
    };
    final double nd = (d + (3 - rating) * 0.5).clamp(1, 10);
    return SrsMemory(stability: ns, difficulty: nd);
  }

  @override
  SrsNextStates nextStates({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double desiredRetention,
    required SrsMemory? memory,
    required double elapsedDays,
  }) {
    SrsItemState st(int r) {
      final SrsMemory m = _step(memory, r, elapsedDays);
      return SrsItemState(memory: m, interval: m.stability);
    }

    return SrsNextStates(again: st(1), hard: st(2), good: st(3), easy: st(4));
  }

  @override
  SrsMemory? memoryState({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<SrsFsrsReview> reviews,
    SrsMemory? starting,
  }) {
    SrsMemory? m = starting;
    for (final SrsFsrsReview r in reviews) {
      m = _step(m, r.rating, r.deltaDays);
    }
    return m;
  }

  @override
  SrsMemory memoryStateFromSm2({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double easeFactor,
    required double intervalDays,
    required double sm2Retention,
  }) => SrsMemory(stability: intervalDays, difficulty: 11 - easeFactor * 2);

  @override
  double retrievability({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsMemory memory,
    required double elapsedDays,
  }) => 1 / (1 + elapsedDays / (memory.stability + 0.01));

  @override
  List<double> computeParameters({
    required SrsAlgorithm algorithm,
    required List<List<SrsFsrsReview>> items,
    List<int>? cardIds,
    SrsOptimizerControl? control,
  }) => List<double>.filled(algorithm.paramCount, items.length.toDouble());

  @override
  SrsEvaluation evaluateTimeSeries({
    required SrsAlgorithm algorithm,
    required List<List<SrsFsrsReview>> items,
  }) => SrsEvaluation(
    logLoss: algorithm == SrsAlgorithm.fsrs7 ? 0.3 : 0.4,
    rmseBins: 0.1,
  );

  @override
  SrsEvaluation evaluate({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<List<SrsFsrsReview>> items,
  }) => const SrsEvaluation(logLoss: 0.35, rmseBins: 0.1);
}
