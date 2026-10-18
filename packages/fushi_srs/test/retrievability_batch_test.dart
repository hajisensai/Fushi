// srsRetrievabilityBatch 的分派：不支持批量的引擎退回逐张调用，长度不符直接报错。
// 原生批量与逐张逐位一致由 ffi_fsrs_engine_test.dart 对真实库测。
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/fake_engine.dart';

void main() {
  const FakeFsrsEngine engine = FakeFsrsEngine();
  const List<SrsMemory> memories = <SrsMemory>[
    SrsMemory(stability: 1, difficulty: 5),
    SrsMemory(stability: 10, difficulty: 3),
    SrsMemory(stability: 40, difficulty: 8),
  ];
  const List<double> elapsed = <double>[0, 2.5, 30];

  test('non-batch engine falls back to per-card retrievability', () {
    final List<double> r = srsRetrievabilityBatch(
      engine,
      algorithm: SrsAlgorithm.fsrs7,
      params: const <double>[],
      memories: memories,
      elapsedDays: elapsed,
    );
    expect(r, <double>[
      for (int i = 0; i < memories.length; i++)
        engine.retrievability(
          algorithm: SrsAlgorithm.fsrs7,
          params: const <double>[],
          memory: memories[i],
          elapsedDays: elapsed[i],
        ),
    ]);
  });

  test('length mismatch is an ArgumentError', () {
    expect(
      () => srsRetrievabilityBatch(
        engine,
        algorithm: SrsAlgorithm.fsrs6,
        params: const <double>[],
        memories: memories,
        elapsedDays: const <double>[1],
      ),
      throwsArgumentError,
    );
  });
}
