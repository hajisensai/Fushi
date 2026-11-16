/// 复习库换代迁移（协议 3 `srs.db` → 新代 `srs4.db`）的进程级控制器：迁移页（srs_generation_view.dart）只看它。
///
/// 顺序（交接说明 §8.1）：开库 → [SrsStoreNotMigrated] 且 [SrsGenState.needsMigration] → 用户点「开始升级」→
/// [SrsGen4Migration.run]（后台 isolate，阻塞到结论）→ 提交了就让存储重开（[SrsGen4MigrationController.onCommitted]）。
/// S1 之后进程里不会有协议 3 的句柄（`ffsrs_store_open` 已删），不用另关。[SrsGenState.sealedOldOnly] /
/// [SrsGenState.migrationFailed] 由页面给恢复说明，这里不自动重跑。
///
/// 迁移无损：旧库提交后原位封存、不删；提交点之前失败或取消，目录回到迁移前的样子。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show ProfileRow;
import 'package:fushi_engine/srs/srs_db_store.dart' show srsCacheConfigFor;
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 迁移命令的执行端（测试换成假的）。
abstract interface class SrsGen4MigrationBackend {
  SrsGen4MigrationStatus status(String dir);

  Future<SrsGen4MigrationOutcome> run(
    String dir, {
    required Map<String, Map<String, Object?>> caches,
    required int nowMs,
    required String runId,
  });

  bool cancel(String dir, {String? runId});
}

/// 真实的执行端：原生库的三条全局命令（[SrsGen4Migration]）。
final class SrsNativeGen4MigrationBackend implements SrsGen4MigrationBackend {
  const SrsNativeGen4MigrationBackend();

  @override
  SrsGen4MigrationStatus status(String dir) => SrsGen4Migration.status(dir);

  @override
  Future<SrsGen4MigrationOutcome> run(
    String dir, {
    required Map<String, Map<String, Object?>> caches,
    required int nowMs,
    required String runId,
  }) => SrsGen4Migration.run(dir, caches: caches, nowMs: nowMs, runId: runId);

  @override
  bool cancel(String dir, {String? runId}) =>
      SrsGen4Migration.cancel(dir, runId: runId);
}

/// 控制器所处的阶段。
enum SrsGen4MigrationPhase {
  /// 没在跑（还没开始，或上一次有了结论 / 出了错）。
  idle,

  /// 正在跑（[SrsGen4MigrationController.progress] 是最近一次轮询到的进度）。
  running,

  /// 已提交、存储已重开：页面随存储重开换成正常内容。
  committed,
}

class SrsGen4MigrationController extends ChangeNotifier {
  SrsGen4MigrationController({
    required this.directory,
    required this.profileUids,
    required this.onCommitted,
    this.backend = const SrsNativeGen4MigrationBackend(),
    this.pollInterval = const Duration(milliseconds: 250),
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 库目录（`<数据库目录>`）。
  final String directory;

  /// 本机全部 profile 的 uid（主库的 profile 表）：每个都按 [srsCacheConfigFor] 交一份缓存配置。协议 3 库里另有
  /// 主库里没有的 profile（删除时没清干净、备份并入留下的孤儿 uid）时迁移报前提不满足（[SrsGen4MigrationVerdict.blocked]
  /// + [SrsGen4BlockedReason.precondition]，旧库没动）：旧库的 profile 列表要内核给（上游缺口，交接说明 §9.5）。
  final Future<List<String>> Function() profileUids;

  /// 提交之后：让存储重开、作废缓存着错误的 provider。
  final Future<void> Function() onCommitted;

  final SrsGen4MigrationBackend backend;
  final Duration pollInterval;
  final int Function() _nowMs;

  SrsGen4MigrationPhase _phase = SrsGen4MigrationPhase.idle;
  SrsGen4MigrationProgress? _progress;
  SrsGen4MigrationOutcome? _outcome;
  Object? _error;
  String? _runId;
  bool _cancelRequested = false;
  Timer? _poll;
  Completer<void>? _finished;
  bool _disposed = false;

  SrsGen4MigrationPhase get phase => _phase;

  /// 正在跑时最近一次轮询到的进度（还没轮询到 = null）。
  SrsGen4MigrationProgress? get progress => _progress;

  /// 上一次的结论（提交以外的：没开始 / 放弃 / 取消 / 空间不够）。
  SrsGen4MigrationOutcome? get outcome => _outcome;

  /// 上一次跑出的错误（内核报错，例如上次失败留下的半成品让迁移拒绝开始）。
  Object? get error => _error;

  /// 已请求取消、还没有结论。
  bool get cancelRequested => _cancelRequested;

  /// 现在还能取消：在跑、没请求过、还没到提交点。
  bool get canCancel =>
      _phase == SrsGen4MigrationPhase.running &&
      !_cancelRequested &&
      (_progress?.step.cancellable ?? true);

  /// 开始一次迁移（已在跑时无操作）。结论落在 [outcome] / [error]，提交了就调 [onCommitted]。
  Future<void> start() async {
    if (_phase == SrsGen4MigrationPhase.running) return;
    final String runId = 'gen4-${_nowMs()}';
    final Completer<void> finished = _finished = Completer<void>();
    _runId = runId;
    _phase = SrsGen4MigrationPhase.running;
    _progress = null;
    _outcome = null;
    _error = null;
    _cancelRequested = false;
    _notify();
    _poll = Timer.periodic(pollInterval, (_) => _pollStatus());
    try {
      final Map<String, Map<String, Object?>> caches =
          <String, Map<String, Object?>>{
            for (final String uid in await profileUids())
              uid: srsCacheConfigFor(uid),
          };
      final SrsGen4MigrationOutcome o = await backend.run(
        directory,
        caches: caches,
        nowMs: _nowMs(),
        runId: runId,
      );
      _stopPolling();
      if (o.verdict == SrsGen4MigrationVerdict.committed) {
        await onCommitted();
        _phase = SrsGen4MigrationPhase.committed;
      } else {
        _outcome = o;
        _phase = SrsGen4MigrationPhase.idle;
      }
    } catch (e, stack) {
      _stopPolling();
      ErrorLogService.instance.log('SrsGen4Migration.run', e, stack);
      _error = e;
      _phase = SrsGen4MigrationPhase.idle;
    } finally {
      _runId = null;
      _cancelRequested = false;
      _finished = null;
      finished.complete();
      _notify();
    }
  }

  /// 关库前（覆盖恢复、换数据根、退出；登记在 [AppModel.addDatabaseCloseQuiescer]）：没在跑直接返回；提交点之前
  /// 叫停并等结论（目录回到迁移前的样子）；已过提交点就等它跑完（改名 / 封存不能被删文件、换目录打断）。
  Future<void> quiesce() async {
    final Completer<void>? finished = _finished;
    if (finished == null) return;
    cancel();
    await finished.future;
  }

  /// 叫停正在跑的迁移（提交点之前有效；之后的结论是 [SrsGen4MigrationVerdict.cancelled]）。
  void cancel() {
    if (!canCancel) return;
    _cancelRequested = true;
    backend.cancel(directory, runId: _runId);
    _notify();
  }

  void _pollStatus() {
    if (_phase != SrsGen4MigrationPhase.running) return;
    try {
      final SrsGen4MigrationProgress? p = backend.status(directory).running;
      if (p != null && p != _progress) {
        _progress = p;
        _notify();
      }
    } catch (e, stack) {
      // 进度只是显示：读不到就保留上一次的，结论以 run 的返回为准。
      ErrorLogService.instance.log('SrsGen4Migration.status', e, stack);
    }
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPolling();
    super.dispose();
  }
}

/// 本进程是不是主进程：只有主进程迁移；弹窗 / 查词窗（Secondary 打开）只提示去主窗口。
final Provider<bool> srsGen4IsMainProcessProvider = Provider<bool>(
  (Ref ref) => ref.read(appProvider).srsStorage.isMainProcess,
);

/// 进程级的迁移控制器：换页不丢进度（迁移在后台 isolate 里跑，页面只是看它）。只有主进程迁移。
final Provider<SrsGen4MigrationController> srsGen4MigrationProvider =
    Provider<SrsGen4MigrationController>((Ref ref) {
      final AppModel app = ref.read(appProvider);
      final SrsGen4MigrationController c = SrsGen4MigrationController(
        directory: app.srsStorage.directory,
        profileUids: () async => <String>[
          for (final ProfileRow row in await app.database.getAllProfiles())
            if (row.uid case final String uid) uid,
        ],
        onCommitted: () async {
          await app.srsStorage.reopen();
          ref.invalidate(srsStorageProvider);
          ref.invalidate(srsStoreProvider);
        },
      );
      // 迁移在后台 isolate 里跑几十秒到几分钟：关库（恢复 / 换数据根 / 退出）要先等它停在一个完整的状态。
      app.addDatabaseCloseQuiescer(c.quiesce);
      ref.onDispose(() {
        app.removeDatabaseCloseQuiescer(c.quiesce);
        c.dispose();
      });
      return c;
    });
