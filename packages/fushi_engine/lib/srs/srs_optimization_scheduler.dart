/// 复习（SRS）自动优化的调度（计划 PR6）。
///
/// app 空闲时（前台、不在复习页；最多每 [kSrsOptimizeCheckInterval] 检查一次）对每个
/// 自己管参数的牌组：`srsPrepareOptimization`（主 isolate 读库）→ `srsShouldOptimize`
/// 判门槛 → 后台 isolate 里 `srsRunOptimization`（排程内核的参数拟合，可取消）→
/// `srsApplyOptimization` 写回。进入复习页或 app 进后台时立即取消在跑的那一轮。
///
/// 只有复习模块开着时才会构造本类（`srs_app_runtime.dart`）；模块关着时没有任何定时器。
library;

import 'dart:async';
import 'dart:isolate';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_optimizer.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// 两次自动检查之间的最小间隔。
const Duration kSrsOptimizeCheckInterval = Duration(hours: 6);

/// 空闲探测的节拍（满足条件且距上次检查够久才真跑）。
const Duration kSrsOptimizeTick = Duration(minutes: 10);

/// 一次可取消的优化计算（生产：后台 isolate + 原生取消标志；测试注入假实现）。
abstract interface class SrsOptimizationJob {
  Future<SrsOptimizationResult> run(SrsOptimizationInput input);
  void cancel();
}

/// 造一个计算任务（每轮一个）。
typedef SrsOptimizationJobFactory = SrsOptimizationJob Function();

/// 生产实现：[Isolate.run] 里用同一个原生库重建引擎，取消 / 进度经原生内存共享。
class SrsIsolateOptimizationJob implements SrsOptimizationJob {
  SrsIsolateOptimizationJob({required this.libraryPath});

  /// 主 isolate 实际加载的原生库路径（iOS 静态链接 / 裸名时为 null，子 isolate 按默认规则重新解析）。
  final String? libraryPath;

  NativeSrsOptimizerControl? _control;
  bool _cancelled = false;

  @override
  Future<SrsOptimizationResult> run(SrsOptimizationInput input) async {
    if (_cancelled) throw const SrsFsrsException('cancelled');
    final NativeSrsOptimizerControl control = NativeSrsOptimizerControl();
    _control = control;
    final int cancelAddress = control.cancelAddress;
    final int progressAddress = control.progressAddress;
    final String? path = libraryPath;
    try {
      return await Isolate.run<SrsOptimizationResult>(
        _isolateBody(input, path, cancelAddress, progressAddress),
      );
    } finally {
      // 优化调用已返回（或抛出）：原生侧不会再写这块内存，可以释放。
      _control = null;
      control.dispose();
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    _control?.cancel();
  }
}

/// 后台 isolate 的入口闭包。写成顶层函数：只捕获这几个可跨 isolate 发送的值，
/// 不会把宿主对象（持有原生指针）一起带过去。
SrsOptimizationResult Function() _isolateBody(
  SrsOptimizationInput input,
  String? libraryPath,
  int cancelAddress,
  int progressAddress,
) => () {
  final FfiFsrsEngine? engine = FfiFsrsEngine.tryCreate(
    libraryPath: libraryPath,
  );
  if (engine == null) {
    throw const SrsFsrsException('scheduling engine unavailable');
  }
  return srsRunOptimization(
    engine,
    input,
    control: NativeSrsOptimizerControl.fromAddress(
      cancelAddress: cancelAddress,
      progressAddress: progressAddress,
    ),
  );
};

/// 一轮检查的结果（测试与日志用）。
class SrsOptimizationRound {
  SrsOptimizationRound();

  final List<String> checkedDecks = <String>[];
  final List<SrsOptimizationResult> applied = <SrsOptimizationResult>[];
  bool cancelled = false;
}

class SrsOptimizationScheduler {
  SrsOptimizationScheduler({
    required Future<SrsDbStore?> Function() readStore,
    required FsrsEngine? Function() engine,
    required SrsOptimizationJobFactory jobFactory,
    required bool Function() canRunNow,
    void Function()? onApplied,
    DateTime Function()? clock,
  }) : _readStore = readStore,
       _engine = engine,
       _jobFactory = jobFactory,
       _canRunNow = canRunNow,
       _onApplied = onApplied,
       _clock = clock ?? DateTime.now;

  final Future<SrsDbStore?> Function() _readStore;
  final FsrsEngine? Function() _engine;
  final SrsOptimizationJobFactory _jobFactory;
  final bool Function() _canRunNow;
  final void Function()? _onApplied;
  final DateTime Function() _clock;

  DateTime? _lastCheckAt;
  SrsOptimizationJob? _job;
  Future<SrsOptimizationRound?>? _running;
  Timer? _timer;
  bool _disposed = false;
  bool _cancelRequested = false;

  /// 是否有一轮正在跑。
  bool get isRunning => _running != null;

  /// 开始空闲节拍（每 [kSrsOptimizeTick] 看一次条件）。
  void start() {
    _timer ??= Timer.periodic(kSrsOptimizeTick, (_) => unawaited(maybeRun()));
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    cancel();
  }

  /// 取消在跑的那一轮（进入复习页 / app 进后台）。
  void cancel() {
    if (_running == null) return;
    _cancelRequested = true;
    _job?.cancel();
  }

  /// 条件满足（前台、不在复习页、距上次检查够久）时跑一轮；否则返回 null。
  Future<SrsOptimizationRound?> maybeRun() {
    if (_disposed || _running != null || !_canRunNow()) {
      return Future<SrsOptimizationRound?>.value();
    }
    final DateTime now = _clock();
    final DateTime? last = _lastCheckAt;
    if (last != null && now.difference(last) < kSrsOptimizeCheckInterval) {
      return Future<SrsOptimizationRound?>.value();
    }
    return runNow(markChecked: true);
  }

  /// 不看节流直接跑一轮（牌组设置页「立即优化」：只跑 [onlyDeckId] 那个参数组）。
  /// [force] 为真时跳过「样本门槛 / 触发基线」（用户显式要求）。
  Future<SrsOptimizationRound?> runNow({
    String? onlyDeckId,
    bool force = false,
    bool markChecked = false,
  }) {
    final Future<SrsOptimizationRound?>? running = _running;
    if (running != null) return running;
    if (markChecked) _lastCheckAt = _clock();
    _cancelRequested = false;
    final Future<SrsOptimizationRound?> f = _round(onlyDeckId, force);
    _running = f;
    return f.whenComplete(() {
      if (identical(_running, f)) _running = null;
      _job = null;
    });
  }

  Future<SrsOptimizationRound?> _round(String? onlyDeckId, bool force) async {
    final FsrsEngine? engine = _engine();
    if (engine == null) return null;
    final SrsDbStore? store = await _readStore();
    if (store == null) return null;
    final SrsOptimizationRound round = SrsOptimizationRound();
    final SrsDeckTree tree = await store.deckTree();
    final List<String> owners = <String>[
      for (final SrsDeckView d in tree.decks)
        if (tree.paramsOwner(d.id).id == d.id &&
            (onlyDeckId == null || d.id == tree.paramsOwner(onlyDeckId).id))
          d.id,
    ]..sort();
    final String rev = engine.fsrsRev;
    for (final String deckId in owners) {
      if (_disposed || _cancelRequested || (!force && !_canRunNow())) {
        round.cancelled = true;
        break;
      }
      final SrsOptimizationInput? input = await srsPrepareOptimization(
        store,
        deckId,
      );
      if (input == null) continue;
      round.checkedDecks.add(deckId);
      final SrsDeckView owner = (await store.deckTree()).paramsOwner(deckId);
      final String? setRev = owner
          .paramSetFor(owner.localAlgorithm)
          ?.algorithmRev;
      final bool knownRev = setRev == null || setRev == rev;
      final (int nowMs, _) = store.now();
      final bool due = force
          ? input.reviewCount > 0 && knownRev
          : srsShouldOptimize(
              owner: owner,
              reviewCount: input.reviewCount,
              nowMs: nowMs,
              knownAlgorithmRev: knownRev,
            );
      if (!due) continue;
      final SrsOptimizationJob job = _jobFactory();
      _job = job;
      if (_cancelRequested) job.cancel();
      final SrsOptimizationResult result;
      try {
        result = await job.run(input);
      } on SrsFsrsException catch (e) {
        if (_cancelRequested || e.isCancelled) {
          round.cancelled = true;
          break;
        }
        rethrow;
      }
      if (_disposed || _cancelRequested) {
        round.cancelled = true;
        break;
      }
      await srsApplyOptimization(store, result, fsrsRev: rev);
      round.applied.add(result);
      _onApplied?.call();
    }
    return round;
  }
}
