/// 存储换代的预演（设计 §8 G4b、§9 第 8 项）：换代前的版本在 app 空闲时，对正在用的 srs.db 只读地走一遍换代的
/// 前五步（灌入 → 重建 → 对拍），报告留在库旁边的 `gen4-rehearsal/report.json`。
///
/// 全部计算在内核（native/fushi_fsrs/src/store/gen4/dryrun.rs `rehearse`）：它另开只读连接，不写旧库、不占内核的读写
/// 连接，临时新库跑完即删；中断只置开关、打断正在跑的语句。Dart 只管什么时候跑（空闲、每个版本一次）、什么时候停
/// （进复习页、进后台、关库），以及把报告交给界面。报告只含 ID 与计数、不含卡片内容（诊断包导出的就是它）。
library;

import 'dart:async';
import 'dart:isolate';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_data.dart'
    show SrsStoredProfiles, srsStoredProfiles;
import 'package:fushi_srs/fushi_srs.dart' show SrsCore;

/// 空闲探测的节拍（满足条件且这个版本还没跑出结论才真跑）。
const Duration kSrsGen4RehearsalTick = Duration(minutes: 10);

/// 预演报告的结论（内核 `verdict`）。
enum SrsGen4RehearsalVerdict {
  /// 各项对拍都没有差异：这个库可以换代。
  pass,

  /// 对拍有差异：换代会改变用户看到的东西，诊断包给开发者看。
  fail,

  /// 换代的前提（协议 3 的迁移、待重放的收尾）还没在旧代码上做完。
  blocked,

  /// 库里没有可换代的数据。
  empty,

  /// 磁盘空间不够放临时新库，没跑。
  skipped,

  /// 中途被停下（进复习页、进后台、关库）。
  cancelled,

  /// 跑的过程中出错。
  error;

  static SrsGen4RehearsalVerdict parse(Object? v) => values.firstWhere(
    (SrsGen4RehearsalVerdict e) => e.name == v,
    orElse: () => SrsGen4RehearsalVerdict.error,
  );

  /// 这个结论算不算「这个版本跑完了」：没跑完的（停下、没空间、出错）下次空闲再试。
  bool get settled => switch (this) {
    pass || fail || blocked || empty => true,
    skipped || cancelled || error => false,
  };
}

/// 一份预演报告（内核写的 JSON 原样留在 [raw] 里，诊断包导出它）。
class SrsGen4RehearsalReport {
  const SrsGen4RehearsalReport({
    required this.verdict,
    required this.finishedAt,
    required this.appVersion,
    required this.raw,
  });

  factory SrsGen4RehearsalReport.fromJson(Map<String, Object?> m) =>
      SrsGen4RehearsalReport(
        verdict: SrsGen4RehearsalVerdict.parse(m['verdict']),
        finishedAt: switch (m['finishedAtMs']) {
          final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
          _ => null,
        },
        appVersion: m['appVersion'] as String?,
        raw: m,
      );

  final SrsGen4RehearsalVerdict verdict;
  final DateTime? finishedAt;

  /// 跑这次预演的 app 版本（`version+build`）。
  final String? appVersion;
  final Map<String, Object?> raw;
}

/// 预演的缓存配置：库里每个出现过数据的 profile 一份，与 app 交给旧内核的同一份（[srsCacheConfigOf]）。
Future<Map<String, Object?>> _rehearsalCaches(SrsCore core) async {
  final SrsStoredProfiles stored = await srsStoredProfiles(core);
  return <String, Object?>{
    for (final String uid in stored.uids) uid: srsCacheConfigOf(uid),
  };
}

/// 在一个专用的后台 isolate 里跑一条内核命令（预演一跑几十秒到几分钟，不占内核 worker 池的道）。
Future<Map<String, Object?>> _runInIsolate(
  SrsCore core,
  Map<String, Object?> request,
) {
  final int address = core.address;
  final String? libraryPath = core.libraryPath;
  return Isolate.run<Map<String, Object?>>(
    () => SrsCore.fromAddress(
      address,
      libraryPath: libraryPath,
    ).sync2(request).map,
  );
}

/// 对 [core] 的库跑一次预演（后台 isolate），返回报告。报告同时写进库旁边的 `gen4-rehearsal/report.json`。
Future<SrsGen4RehearsalReport> srsGen4Rehearse(
  SrsCore core, {
  required String appVersion,
}) async {
  final Map<String, Object?> caches = await _rehearsalCaches(core);
  final Map<String, Object?> r = await _runInIsolate(core, <String, Object?>{
    'op': 'gen4_rehearse',
    'caches': caches,
    'appVersion': appVersion,
  });
  return SrsGen4RehearsalReport.fromJson(r);
}

/// 请 [core] 的库上在跑的预演停下（同步调：只置开关、打断语句，不等）。没在跑就什么都不做。
void srsGen4RehearsalCancel(SrsCore core) {
  core.sync2(const <String, Object?>{'op': 'gen4_rehearse_cancel'});
}

/// 上一次预演的报告；没跑过就是 null。
Future<SrsGen4RehearsalReport?> srsGen4RehearsalLastReport(SrsCore core) async {
  final Map<String, Object?> m = await _runInIsolate(
    core,
    const <String, Object?>{'op': 'gen4_rehearsal_report'},
  );
  final Object? report = m['report'];
  return report is Map
      ? SrsGen4RehearsalReport.fromJson(report.cast<String, Object?>())
      : null;
}

/// 一个库上的预演执行端（生产：上面三个内核命令；测试注入假实现）。
abstract interface class SrsGen4RehearsalRunner {
  Future<SrsGen4RehearsalReport?> lastReport();
  Future<SrsGen4RehearsalReport> run(String appVersion);
  void cancel();
}

/// 生产实现：[core] 那个库上的内核命令。
class SrsKernelGen4RehearsalRunner implements SrsGen4RehearsalRunner {
  const SrsKernelGen4RehearsalRunner(this.core);

  final SrsCore core;

  @override
  Future<SrsGen4RehearsalReport?> lastReport() =>
      srsGen4RehearsalLastReport(core);

  @override
  Future<SrsGen4RehearsalReport> run(String appVersion) =>
      srsGen4Rehearse(core, appVersion: appVersion);

  @override
  void cancel() => srsGen4RehearsalCancel(core);
}

/// 从「当前的复习库」取执行端（库没开 = null）。
Future<SrsGen4RehearsalRunner?> Function() srsGen4RehearsalRunnerOf(
  Future<SrsDbStore?> Function() readStore,
) => () async {
  final SrsDbStore? store = await readStore();
  return store == null ? null : SrsKernelGen4RehearsalRunner(store.core);
};

/// 预演的空闲调度：每 [kSrsGen4RehearsalTick] 看一次，app 空闲（[canRunNow]：前台、不在复习页）且这个 app 版本还没
/// 跑出结论（上一份报告不是本版本的，或本版本的那次没跑完）才跑。进复习页 / 进后台 / 关库时 [cancel]。跑的过程中
/// 内核报错（不是结论，是命令本身失败）就记一次、本进程不再试，免得每个节拍重复撞同一个错。
class SrsGen4RehearsalScheduler {
  SrsGen4RehearsalScheduler({
    required Future<SrsGen4RehearsalRunner?> Function() readRunner,
    required String Function() appVersion,
    required bool Function() canRunNow,
    void Function(Object error, StackTrace stack)? onError,
    void Function(SrsGen4RehearsalReport report)? onReport,
  }) : _readRunner = readRunner,
       _appVersion = appVersion,
       _canRunNow = canRunNow,
       _onError = onError,
       _onReport = onReport;

  final Future<SrsGen4RehearsalRunner?> Function() _readRunner;
  final String Function() _appVersion;
  final bool Function() _canRunNow;
  final void Function(Object error, StackTrace stack)? _onError;
  final void Function(SrsGen4RehearsalReport report)? _onReport;

  Timer? _timer;
  bool _disposed = false;
  bool _done = false;
  bool _failed = false;
  SrsGen4RehearsalRunner? _runner;
  Future<SrsGen4RehearsalReport?>? _running;

  /// 是否有一次正在跑。
  bool get isRunning => _running != null;

  /// 开始空闲节拍。
  void start() {
    _timer ??= Timer.periodic(
      kSrsGen4RehearsalTick,
      (_) => unawaited(maybeRun()),
    );
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    cancel();
  }

  /// 停下在跑的那一次（不等）。
  void cancel() {
    final SrsGen4RehearsalRunner? runner = _runner;
    if (_running == null || runner == null) return;
    try {
      runner.cancel();
    } catch (e, stack) {
      _onError?.call(e, stack);
    }
  }

  /// 停下在跑的那一次并等它收尾（关库前）。
  Future<void> quiesce() async {
    cancel();
    await _running;
  }

  /// 条件满足时跑一次；返回这次的报告，没跑返回 null。
  Future<SrsGen4RehearsalReport?> maybeRun() {
    if (_disposed || _done || _failed || _running != null || !_canRunNow()) {
      return Future<SrsGen4RehearsalReport?>.value();
    }
    final Future<SrsGen4RehearsalReport?> f = _attempt();
    _running = f;
    return f.whenComplete(() {
      if (identical(_running, f)) _running = null;
      _runner = null;
    });
  }

  Future<SrsGen4RehearsalReport?> _attempt() async {
    try {
      final SrsGen4RehearsalRunner? runner = await _readRunner();
      if (runner == null) return null;
      final String version = _appVersion();
      final SrsGen4RehearsalReport? last = await runner.lastReport();
      if (last != null && last.appVersion == version && last.verdict.settled) {
        _done = true;
        return null;
      }
      if (_disposed || !_canRunNow()) return null;
      _runner = runner;
      final SrsGen4RehearsalReport report = await runner.run(version);
      if (report.verdict.settled) _done = true;
      _onReport?.call(report);
      return report;
    } catch (e, stack) {
      _failed = true;
      _onError?.call(e, stack);
      return null;
    }
  }
}
