/// 复习库换代迁移（协议 3 `srs.db` → 新代 `srs4.db`）的进程级控制器：迁移页（srs_generation_view.dart）只看它。
///
/// 顺序（交接说明 §8.1）：开库 → [SrsStoreNotMigrated] 且 [SrsGenState.needsMigration] → 用户点「开始升级」→
/// [SrsGen4Migration.run]（后台 isolate，阻塞到结论）→ 提交了就让存储重开（[SrsGen4MigrationController.onCommitted]）。
/// S1 之后进程里不会有协议 3 的句柄（`ffsrs_store_open` 已删），不用另关。[SrsGenState.sealedOldOnly] /
/// [SrsGenState.migrationFailed] 由页面给恢复说明，这里不自动重跑。
///
/// 迁移无损：旧库提交后原位封存、不删；旧库没做完的协议 3 收尾在它的副本上补（G7-2b），提交点之前失败或取消，旧库
/// 逐字节不变、目录回到迁移前的样子。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier, Listenable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show ProfileRow;
import 'package:fushi_engine/srs/srs_db_store.dart' show srsCacheConfigFor;
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

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
    bool Function()? databaseOpen,
    Listenable? databaseClosing,
    Listenable? databaseChanged,
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _databaseOpen = databaseOpen ?? (() => true),
       _databaseClosing = databaseClosing,
       _databaseChanged = databaseChanged {
    _lastCanStart = canStart;
    _databaseClosing?.addListener(_onClosing);
    _databaseChanged?.addListener(_onDatabaseChanged);
  }

  /// 库目录（`<数据库目录>`）。
  final String directory;

  /// 本机全部 profile 的 uid（主库的 profile 表）。迁移给缓存配置的是它与内核列出的旧库 profile
  /// （[SrsGen4MigrationStatus.profiles]，含主库里没有的孤儿 uid：删除没清干净、备份并入留下的）的并集，每个按
  /// [srsCacheConfigFor] 交一份（只取决于 uid）：孤儿 profile 的卡片与日志照样迁过去，不丢。
  final Future<List<String>> Function() profileUids;

  /// 提交之后：让存储重开、作废缓存着错误的 provider。
  final Future<void> Function() onCommitted;

  final SrsGen4MigrationBackend backend;
  final Duration pollInterval;
  final int Function() _nowMs;

  /// 主库此刻开着（[AppModel.isDatabaseOpen]）。关库（覆盖恢复 / 换数据根 / 退出）一开始就置假、先于等关库前的写手：
  /// 之后不再开始新的迁移（交接说明 §9.5 第 7 条）。启动初始化完成之前也是假。
  final bool Function() _databaseOpen;

  /// 关库开始的信号（[AppModel.databaseCloseNotifier]）：之后到主库重新开好之前算「正在关」（[databaseClosing]）。
  final Listenable? _databaseClosing;

  /// 主库状态可能变了（[AppModel] 本身：初始化 / 重新开库完成时通知）：「开始升级」能不能点随之重算，变了才通知页面。
  final Listenable? _databaseChanged;

  /// 收到过关库信号、主库还没重新开好。
  bool _closeSignalled = false;

  /// 上次通知页面时的 [canStart]（[_onDatabaseChanged] 只在它变了时通知，[AppModel] 的通知很频繁）。
  bool _lastCanStart = true;

  SrsGen4MigrationPhase _phase = SrsGen4MigrationPhase.idle;
  SrsGen4MigrationProgress? _progress;
  SrsGen4MigrationOutcome? _outcome;
  Object? _error;
  String? _errorReportPath;
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

  /// 这次出错时内核写下的错误报告（库目录里的 [SrsGen4Migration.reportFileName]，`verdict` 为 `error`、
  /// `startedAtMs` 正是这次的）：页面据此同样给「发给开发者」与「分享 / 保存」，出错的步骤、错误原文与库的环境随反馈
  /// 附上。没出错、或内核没写出这一次的报告 = null。
  String? get errorReportPath => _error == null ? null : _errorReportPath;

  /// 页面此刻要说明的那次失败（原因与报告都由内核判定，这里不读报告文件）：
  /// - 在跑 = null；
  /// - 本进程这次有了结论：以结论为准，中止的是它带的 [SrsGen4MigrationOutcome.failure]，其余结论 = null；
  /// - 本次出错（内核报错）= null（页面说「出错停止了」，不再拿上一次的原因说事）；
  /// - 还没有结论：[previous]，即打开错误里内核与 [SrsGenState.migrationFailed] 同一次判定的上次原因
  ///   （[SrsStoreNotMigrated.failure]）。
  /// 有 [SrsGen4MigrationFailure.reportPath] 时页面给「发给开发者」与「分享 / 保存」。
  SrsGen4MigrationFailure? failureFor(SrsGen4MigrationFailure? previous) {
    if (_phase != SrsGen4MigrationPhase.idle) return null;
    final SrsGen4MigrationOutcome? o = _outcome;
    if (o != null) {
      return o.verdict == SrsGen4MigrationVerdict.aborted ? o.failure : null;
    }
    if (_error != null) return null;
    return previous;
  }

  /// 已请求取消、还没有结论。
  bool get cancelRequested => _cancelRequested;

  /// 现在能开始一次迁移：没在跑、主库开着。关库开始之后（关库前的静默已经等过 / 正在等这个控制器）不再开始：不然
  /// 迁移会跑在已关的主库与正被换掉的目录上。启动初始化完成之前也不能开始（主库的 profile 表还读不了）。
  bool get canStart =>
      _phase != SrsGen4MigrationPhase.running && _databaseOpen();

  /// 主库正在关（收到关库信号之后、重新开好之前）：页面说明「正在关闭数据库」。只是还没初始化完（启动中）不算。
  bool get databaseClosing => _closeSignalled && !_databaseOpen();

  /// 现在还能取消：在跑、没请求过、还没到提交点。
  bool get canCancel =>
      _phase == SrsGen4MigrationPhase.running &&
      !_cancelRequested &&
      (_progress?.step.cancellable ?? true);

  /// 开始一次迁移（已在跑、或主库已关 / 正在关时无操作，见 [canStart]）。结论落在 [outcome] / [error]，提交了就调
  /// [onCommitted]。
  Future<void> start() async {
    if (!canStart) return;
    final int startedAt = _nowMs();
    final String runId = 'gen4-$startedAt';
    final Completer<void> finished = _finished = Completer<void>();
    _runId = runId;
    _phase = SrsGen4MigrationPhase.running;
    _progress = null;
    _outcome = null;
    _error = null;
    _errorReportPath = null;
    _cancelRequested = false;
    _notify();
    _poll = Timer.periodic(pollInterval, (_) => _pollStatus());
    try {
      // 主库的 profile ∪ 旧库里的（内核列，含孤儿 uid；读旧库的大表，后台 isolate）。列表读不到只记日志、按主库的
      // 给：结论以 run 为准，真缺了哪个 profile 的配置，内核拦下并点名（missingCacheConfig），旧库不动。
      List<String> legacy = const <String>[];
      try {
        legacy = await backend.legacyProfiles(directory);
      } catch (e, stack) {
        ErrorLogService.instance.log(
          'SrsGen4Migration.legacyProfiles',
          e,
          stack,
        );
      }
      final Map<String, Map<String, Object?>> caches =
          <String, Map<String, Object?>>{
            for (final String uid in <String>{
              ...await profileUids(),
              ...legacy,
            })
              uid: srsCacheConfigFor(uid),
          };
      final SrsGen4MigrationOutcome o = await backend.run(
        directory,
        caches: caches,
        nowMs: startedAt,
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
      _errorReportPath = await _errorReportOf(startedAt);
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

  /// 这一次（[startedAt]）出错时内核写下的错误报告的路径；没有、读不了或不是这一次的 = null。
  Future<String?> _errorReportOf(int startedAt) async {
    final String path = p.join(directory, SrsGen4Migration.reportFileName);
    try {
      final Object? report = jsonDecode(await File(path).readAsString());
      if (report is Map<String, Object?> &&
          report['verdict'] == 'error' &&
          report['startedAtMs'] == startedAt) {
        return path;
      }
    } on Object catch (e, stack) {
      if (e is! PathNotFoundException) {
        ErrorLogService.instance.log('SrsGen4Migration.errorReport', e, stack);
      }
    }
    return null;
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  void _onClosing() {
    _closeSignalled = true;
    _notify();
  }

  void _onDatabaseChanged() {
    if (_closeSignalled && _databaseOpen()) _closeSignalled = false;
    if (canStart != _lastCanStart) _notify();
  }

  void _notify() {
    _lastCanStart = canStart;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _databaseClosing?.removeListener(_onClosing);
    _databaseChanged?.removeListener(_onDatabaseChanged);
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
        // 关库一开始 isDatabaseOpen 就为假（先于等关库前的写手）：provider 晚于关库才建、或关库之后页面还在，都开始
        // 不了，所以只在这里登记静默就够——能开始迁移的控制器一定已经建好、登记过。重新开库完成时 AppModel 通知，
        // 按钮随之恢复。
        databaseOpen: () => app.isDatabaseOpen,
        databaseClosing: app.databaseCloseNotifier,
        databaseChanged: app,
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
