import 'package:fushi_srs/fushi_srs.dart';

/// 协议测试用的确定性假引擎（不是 FSRS）：只需要「同输入同输出」。排程不经它（内核自己算）。
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
    required SrsFsrsTrainingSet items,
    SrsOptimizerControl? control,
  }) => List<double>.filled(algorithm.paramCount, items.length.toDouble());

  @override
  SrsEvaluation evaluateTimeSeries({
    required SrsAlgorithm algorithm,
    required SrsFsrsTrainingSet items,
  }) => SrsEvaluation(
    logLoss: algorithm == SrsAlgorithm.fsrs7 ? 0.3 : 0.4,
    rmseBins: 0.1,
  );

  @override
  SrsEvaluation evaluate({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsFsrsTrainingSet items,
  }) => const SrsEvaluation(logLoss: 0.35, rmseBins: 0.1);
}
