// 复习模块 app 侧测试的共用件：确定性假排程内核 + 可拨的可信时钟 + 内存库 store。
//
// 假内核与 test/srs/srs_pages_test.dart、packages/fushi_engine/test/srs/srs_db_store_test.dart
// 同一套数值（真实数值由 packages/fushi_srs 的 FFI 测试覆盖）。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart' show Override;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/donation/srs_donation_client.dart';
import 'package:fushi/src/srs/donation/srs_donation_eligibility.dart';
import 'package:fushi/src/srs/donation/srs_donation_providers.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_op_ledger.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:flutter_test/flutter_test.dart' show WidgetTester, addTearDown;
import 'package:fushi_srs/fushi_srs.dart';

import '../helpers/test_platform_services.dart';

/// 页面测试用的 AppModel（偏好层没初始化）：「首次 v2 同步」视为已确认。
///
/// 牌组列表首帧会问一次首次同步（`ensureSrsFirstSyncConfirmed`）：偏好层没初始化时 getter 恒为 false，
/// 有笔记就弹确认框挡住后续点按、没笔记则写偏好失败——与被测功能无关，在这里钉成已确认。
/// 专门测这个确认框的用例自己装真偏好层。
///
/// 快捷键注册表装出厂默认（真 app 在 `initialise` 里装）：复习页的键盘 / 手柄按
/// `ShortcutScope.srsReview` 解析，未装载的注册表对每个动作都是空绑定。
/// widget 测试里推进到 SRS 内核往返全部落地：每轮放一小段真实时间（[real]）让查询 / 写工作 isolate 回包，
/// 再 pump 一帧（[frame]）让 fake zone 里的后续跑起来。至少 [minRounds] 轮；之后连续 3 轮既没有在途的内核操作
/// （[SrsOpLedger.inflightCount]，读命令与写命令都记账）、也没有排着的帧（数据到了之后的切换动画还在走）就停，
/// 最多 [maxRounds] 轮。
///
/// 读命令在查询工作 isolate 上跑（store/reads.rs），每次往返都要一段真实时间；页面一次加载串着好几次读，
/// 固定轮数在慢机器上不够（G5 删掉 srs.db 的同步 Drift 读之后）。
Future<void> srsSettle(
  WidgetTester tester, {
  int minRounds = 12,
  int maxRounds = 400,
  Duration real = const Duration(milliseconds: 5),
  Duration frame = const Duration(milliseconds: 60),
}) async {
  int quiet = 0;
  for (int i = 0; i < maxRounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(real));
    await tester.pump(frame);
    quiet = SrsOpLedger.inflightCount == 0 && !tester.binding.hasScheduledFrame
        ? quiet + 1
        : 0;
    if (i + 1 >= minRounds && quiet >= 3) return;
  }
}

class SrsTestAppModel extends AppModel {
  SrsTestAppModel() : super(testPlatformServices()) {
    shortcutRegistry.loadDefaults(TargetPlatform.windows);
  }

  @override
  bool get srsSync2MergeConfirmed => true;
}

/// 挂复习首页（牌组列表）的 ProviderScope 都要带上：首页横幅判据
/// [srsDonationPromptProvider] 读当前 profile 的捐赠偏好（[srsDonationPrefsProvider] → 偏好层 +
/// Profile 视图 → 数据库），而 [SrsTestAppModel] 刻意不接偏好层与数据库，不带就在首帧抛
/// `LateInitializationError: _database`。偏好给「从没设过」的初值，服务端状态给「没捐过」
/// （[srsDonationStatusProvider] 不走网络），横幅出不出仍按真实统计（复习数 / 天数）判；
/// 专测横幅的用例见 test/srs/donation/。
final List<Override> srsTestDonationOverrides = <Override>[
  srsDonationPrefsProvider.overrideWithValue(const SrsDonationPrefsState()),
  srsDonationStatusProvider.overrideWith(_SrsTestNoDonation.new),
];

class _SrsTestNoDonation extends SrsDonationStatusNotifier {
  @override
  Future<SrsDonationStatus?> build() async => const SrsDonationStatus.none();
}

const String kSrsTestProfile = '01928c3e-0000-7000-8000-0000000000cd';

/// 确定性假引擎。
class SrsTestEngine implements FsrsEngine {
  const SrsTestEngine();

  @override
  String get fsrsRev => 'fake';
  @override
  bool isKnownFsrsRev(String rev) => rev == fsrsRev;
  @override
  List<double> defaultParams(SrsAlgorithm a) =>
      List<double>.filled(a.paramCount, 1);
  @override
  String? validateParams(SrsAlgorithm a, List<double> p) => null;
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

  SrsTrustedClock trusted() =>
      SrsTrustedClock(wallClockMs: () => nowMs, bootClockMs: () => nowMs);
}

/// 临时目录里的一份 srs.db（Rust 独占连接，Drift 执行器跑在当前 isolate）。注册
/// [addTearDown]：关存储、删目录（Windows 句柄滞后时删除失败吞掉，临时目录留给系统清理）。
Future<SrsStorage> openSrsTestStorage() async {
  final Directory dir = Directory.systemTemp.createTempSync('fushi_srs_test_');
  final SrsStorage storage = await SrsStorage.open(directory: dir.path);
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
    core: srs.core,
    profileUid: profileUid,
    deviceId: deviceId,
    engine: engine,
    trustedClock: clock?.trusted(),
    styles: styles,
  );
  return (db, store);
}
