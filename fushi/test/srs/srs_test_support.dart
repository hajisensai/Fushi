// 复习模块 app 侧测试的共用件：确定性假排程内核 + 可拨的可信时钟 + 内存库 store。
//
// 假内核与 test/srs/srs_pages_test.dart、packages/fushi_engine/test/srs/srs_db_store_test.dart
// 同一套数值（真实数值由 packages/fushi_srs 的 FFI 测试覆盖）。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi/models.dart' show AppModel;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:flutter_test/flutter_test.dart' show addTearDown;
import 'package:fushi_srs/fushi_srs.dart';

import '../helpers/test_platform_services.dart';

/// 页面测试用的 AppModel（偏好层没初始化）：「首次 v2 同步」视为已确认。
///
/// 牌组列表首帧会问一次首次同步（`ensureSrsFirstSyncConfirmed`）：偏好层没初始化时 getter 恒为 false，
/// 有笔记就弹确认框挡住后续点按、没笔记则写偏好失败——与被测功能无关，在这里钉成已确认。
/// 专门测这个确认框的用例自己装真偏好层。
class SrsTestAppModel extends AppModel {
  SrsTestAppModel() : super(testPlatformServices());

  @override
  bool get srsSync2MergeConfirmed => true;
}

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
    required SrsFsrsTrainingSet items,
    SrsOptimizerControl? control,
  }) => defaultParams(algorithm);
  @override
  SrsEvaluation evaluateTimeSeries({
    required SrsAlgorithm algorithm,
    required SrsFsrsTrainingSet items,
  }) => const SrsEvaluation(logLoss: 0.3, rmseBins: 0.1);
  @override
  SrsEvaluation evaluate({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsFsrsTrainingSet items,
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
    bootClockMs: () => nowMs,
    bootId: 'test-boot',
  );
}

/// 临时目录里的一份 srs.db（Rust 独占连接，Drift 执行器跑在当前 isolate）。注册
/// [addTearDown]：关存储、删目录（Windows 句柄滞后时删除失败吞掉，临时目录留给系统清理）。
Future<SrsStorage> openSrsTestStorage() async {
  final Directory dir = Directory.systemTemp.createTempSync('fushi_srs_test_');
  final SrsStorage storage = await SrsStorage.open(
    path: SrsStorage.pathIn(dir.path),
    inline: true,
  );
  addTearDown(() async {
    await storage.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄尚未释放；临时目录留给系统清理。
    }
  });
  return storage;
}

/// 内存主库 + 临时 srs.db 上的一个 store（主库由调用方关；srs.db 随 [addTearDown] 关）。
/// [storage] 给了就用它（同一份 srs.db 上开多个 profile 的 store）。
Future<(FushiDatabase, SrsDbStore)> openSrsTestStore({
  String profileUid = kSrsTestProfile,
  String deviceId = 'dev',
  FsrsEngine? engine = const SrsTestEngine(),
  SrsTestClock? clock,
  SrsStyleStore? styles,
  SrsStorage? storage,
}) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  final SrsStorage srs = storage ?? await openSrsTestStorage();
  final SrsDbStore store = await SrsDbStore.open(
    db: srs.db,
    core: srs.core,
    profileUid: profileUid,
    deviceId: deviceId,
    engine: engine,
    trustedClock: clock?.trusted(),
    styles: styles,
  );
  return (db, store);
}
