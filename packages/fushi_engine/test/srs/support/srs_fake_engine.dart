/// 复习备份 / 恢复测试共用：确定性假排程内核与内存同步目录（与 srs_db_store_test.dart 同一套）。
library;

import 'dart:typed_data';

import 'package:fushi_srs/fushi_srs.dart';

/// 协议测试用的确定性假引擎（真实数值见 packages/fushi_srs 的 FFI 测试）。
class SrsFakeEngine implements FsrsEngine {
  const SrsFakeEngine();

  @override
  String get fsrsRev => 'fake';
  @override
  List<double> defaultParams(SrsAlgorithm a) =>
      List<double>.filled(a.paramCount, 1);
  @override
  String? validateParams(SrsAlgorithm a, List<double> p) => null;
  SrsMemory _step(SrsMemory? m, int r) => SrsMemory(
    stability: switch (r) {
      1 => 0.3,
      2 => 1.5 + (m?.stability ?? 0),
      3 => 3 + (m?.stability ?? 0) * 2,
      _ => 6 + (m?.stability ?? 0) * 3,
    },
    difficulty: 5,
  );
  @override
  SrsNextStates nextStates({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double desiredRetention,
    required SrsMemory? memory,
    required double elapsedDays,
  }) {
    SrsItemState st(int r) {
      final SrsMemory m = _step(memory, r);
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
      m = _step(m, r.rating);
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
  }) => SrsMemory(stability: intervalDays, difficulty: 5);
  @override
  double retrievability({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsMemory memory,
    required double elapsedDays,
  }) => 0.9;
  @override
  List<double> computeParameters({
    required SrsAlgorithm algorithm,
    required List<List<SrsFsrsReview>> items,
    List<int>? cardIds,
    SrsOptimizerControl? control,
  }) => defaultParams(algorithm);
  @override
  SrsEvaluation evaluateTimeSeries({
    required SrsAlgorithm algorithm,
    required List<List<SrsFsrsReview>> items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
  @override
  SrsEvaluation evaluate({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<List<SrsFsrsReview>> items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
}

class SrsMemoryDir implements SrsSyncDirectory {
  SrsMemoryDir(this.now);
  final int Function() now;
  final Map<String, Map<String, Uint8List>> files =
      <String, Map<String, Uint8List>>{};
  @override
  Future<List<String>> listWriters() async => files.keys.toList()..sort();
  @override
  Future<List<String>?> listFiles(String w) async => files[w]?.keys.toList();
  @override
  Future<Uint8List?> read(String w, String n) async => files[w]?[n];
  @override
  Future<void> write(String w, String n, Uint8List b) async =>
      (files[w] ??= <String, Uint8List>{})[n] = b;
  @override
  Future<void> delete(String w, String n) async => files[w]?.remove(n);
  @override
  Future<void> deleteWriter(String w) async => files.remove(w);
  @override
  Future<int?> serverTime(String w) async {
    await write(w, srsProbeName, Uint8List(0));
    return now();
  }
}
