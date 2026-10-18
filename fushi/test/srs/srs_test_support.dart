// 复习模块 app 侧测试的共用件：确定性假排程内核 + 可拨的可信时钟 + 内存库 store。
//
// 假内核与 test/srs/srs_pages_test.dart、packages/fushi_engine/test/srs/srs_db_store_test.dart
// 同一套数值（真实数值由 packages/fushi_srs 的 FFI 测试覆盖）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

const String kSrsTestProfile = '01928c3e-0000-7000-8000-0000000000cd';

/// 确定性假引擎。
class SrsTestEngine implements FsrsEngine {
  const SrsTestEngine();

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

/// 可以拨快的时钟（墙钟与单调钟同步前进）。
class SrsTestClock {
  SrsTestClock([int? startMs])
    : nowMs = startMs ?? DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch;

  int nowMs;

  void advance(Duration d) => nowMs += d.inMilliseconds;

  SrsTrustedClock trusted() => SrsTrustedClock(
    wallClockMs: () => nowMs,
    monotonicMs: () => nowMs,
    bootId: 'test-boot',
  );
}

/// 内存库上的一个 store（调用方负责关库）。
Future<(FushiDatabase, SrsDbStore)> openSrsTestStore({
  String profileUid = kSrsTestProfile,
  String deviceId = 'dev',
  FsrsEngine? engine = const SrsTestEngine(),
  SrsTestClock? clock,
  SrsStyleStore? styles,
}) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  final SrsDbStore store = await SrsDbStore.open(
    db: db,
    profileUid: profileUid,
    deviceId: deviceId,
    engine: engine,
    trustedClock: clock?.trusted(),
    styles: styles,
  );
  return (db, store);
}
