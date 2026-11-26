/// 服务端整机备份的调度核心：手动、自动（计划任务）与远程更新前三种备份共用**一把作业锁**
/// （同一时刻只跑一份），共用 `<data>/backups/` 与保留规则（spec
/// `docs/specs/2026-11-25-auto-backup-restore-points.md` 第 4B 期，D14–D16）。
///
/// - **自动备份**（[startAutomatic] / [runAutomatic]）：到期判定用 fushi_core `isBackupSlotDue`（与 app 的
///   定时还原点同一条规则：偏好时刻、错过补跑、按日历日的间隔、时钟回拨到期一次、被打断的时段不重跑）。
///   数据指纹（[fingerprint]：库文件与数据目录清单的大小 + 修改时间）与上次成功那份相同、且那份还在 →
///   记「没变化、跳过」（算满足）。复习库正在换代迁移 → 记「跳过」（不算满足，下次检查重试），不是失败。
///   成功后按 [planServerBackupPrune] 修剪：只动自动备份与更新前备份，手动备份永不删。
/// - **更新前备份**（[runPreUpdate]）：远程自更新换包之前调；设置 + 数据，不带 documents/。等正在跑的
///   那份结束再开始；失败只记进状态与日志，**更新照样进行**（D16，同 app 第 1 期）。
/// - **中断检测**（[recoverInterrupted]）：状态里的 `runningSinceMs` 在下次启动时还在 = 上次写到一半进程没了：
///   记失败 `interrupted`，删半截的 `.partial`。只能由持有数据目录锁的进程调（serve 启动 / 离线命令）。
///
/// 这里不碰数据目录锁：serve 整个生命周期持锁，离线命令经 `withServerRuntime` 持锁，所以自动备份永远
/// 不会与离线还原（也要拿锁）或另一个进程同时跑。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        FushiDatabase,
        NotEnoughSpaceException,
        VolumeFreeBytes,
        VolumeIdProbe,
        isBackupSlotDue,
        kNotEnoughSpaceError;
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_server/src/backup/server_backup.dart';
import 'package:fushi_server/src/backup/server_backup_status.dart';
import 'package:fushi_server/src/backup/server_backup_store.dart';
import 'package:fushi_server/src/config/server_backup_config.dart';
import 'package:fushi_server/src/server_srs.dart'
    show ServerSrs, ServerSrsBackupHold;
import 'package:path/path.dart' as p;

/// 写一份备份到 [output]（测试缝；生产 = [createServerBackup]）。
typedef ServerBackupWriter =
    Future<File> Function({
      required File output,
      required bool includeDocuments,
    });

/// 占住复习库（备份期间迁移不开始）。返回 null = 复习库正在换代迁移，拒绝备份；
/// 返回的回调在备份结束时调（放掉占位）。复习关着 = 不用占，返回空回调。
typedef ServerBackupSrsHold = void Function()? Function();

/// 为什么没开始。
enum ServerBackupRefusal {
  /// 已有一份在跑（任何来源）。
  busy,

  /// 复习库正在换代迁移。
  srsMigration,

  /// 自动备份关着。
  disabled,

  /// 还没到期。
  notDue,
}

/// 自动 / 更新前备份的结局。
enum ServerBackupOutcome { succeeded, skippedUnchanged, failed }

/// 一次自动 / 更新前备份的结果。
class ServerBackupResult {
  const ServerBackupResult({
    this.outcome,
    this.refusal,
    this.name,
    this.error,
    this.pruned = const <String>[],
  });

  /// 跑了的结局；没开始时为 null（看 [refusal]）。
  final ServerBackupOutcome? outcome;
  final ServerBackupRefusal? refusal;
  final String? name;
  final String? error;

  /// 修剪删掉的文件名。
  final List<String> pruned;
}

/// 开始一份（[ServerBackupService.startManual] / [ServerBackupService.startAutomatic]）的回执：同步决定
/// 开没开始（admin API 据此回 202 / 409），[done] 是后台作业。
class ServerBackupStart {
  ServerBackupStart._(
    this.refusal,
    this.name,
    this.done, [
    Future<String?>? preflight,
  ]) : preflight = preflight ?? Future<String?>.value();

  final ServerBackupRefusal? refusal;

  /// 开始之后、真正动笔之前的检查结局：null = 通过（或没开始），否则是错误码（目前只有空间不够
  /// `not_enough_space`，见第五期）。admin API 的「立即备份」等它再回应（507 / 202），不用等整份写完。
  final Future<String?> preflight;

  /// 要写的文件名（开始了才有）。
  final String? name;
  final Future<ServerBackupResult> done;

  bool get started => refusal == null;
}

class ServerBackupService {
  ServerBackupService({
    required this.dataDir,
    required ServerBackupConfig Function() settings,
    required ServerBackupWriter write,
    ServerBackupSrsHold? holdSrs,
    this.configFile,
    DateTime Function()? now,
    Future<String>? Function({required bool includeDocuments})? fingerprinter,
    VolumeFreeBytes? freeBytes,
    VolumeIdProbe? volumeId,
  }) : _settings = settings,
       _freeBytes = freeBytes,
       _volumeId = volumeId,
       _write = write,
       _fingerprinter = fingerprinter,
       _holdSrs = holdSrs ?? _noSrs,
       _now = now ?? DateTime.now;

  /// 生产装配：快照走 [db]（serve 在跑时就是它那份连接），复习库有在跑的 [ServerSrs] 就走它的连接并占住
  /// 迁移（[ServerSrs.holdForBackup]），否则离线快照。
  factory ServerBackupService.forServer({
    required FushiDatabase db,
    required String dataDir,
    required File? configFile,
    required ServerBackupConfig Function() settings,
    ServerSrs? Function()? srs,
    DateTime Function()? now,
  }) => ServerBackupService(
    dataDir: dataDir,
    configFile: configFile,
    settings: settings,
    now: now,
    holdSrs: () {
      final ServerSrs? s = srs?.call();
      if (s == null) return _noop;
      final ServerSrsBackupHold? hold = s.holdForBackup();
      return hold?.release;
    },
    write: ({required File output, required bool includeDocuments}) =>
        createServerBackup(
          db: db,
          dataDir: dataDir,
          configFile: configFile,
          output: output,
          includeDocuments: includeDocuments,
          snapshotSrs: srs?.call()?.snapshotFn,
        ),
  );

  final String dataDir;

  /// 配置文件（进包，也进指纹：改了设置也算有变化）。
  final File? configFile;
  final ServerBackupConfig Function() _settings;
  final ServerBackupWriter _write;
  final ServerBackupSrsHold _holdSrs;
  final DateTime Function() _now;

  /// 测试缝：替换 [fingerprint]（测遍历数据目录失败）；返回 null = 照常算。
  final Future<String>? Function({required bool includeDocuments})?
  _fingerprinter;

  /// 测试缝：卷的可用空间（缺省 = 进程登记的探针，CLI 入口登记 fushi_fsrs 的实现）。
  final VolumeFreeBytes? _freeBytes;

  /// 测试缝：卷身份（只在注入了 [_freeBytes] 时用；缺省走登记的那一对探针）。
  final VolumeIdProbe? _volumeId;

  String? _running;
  ServerBackupKind? _runningKind;
  Future<ServerBackupResult>? _job;
  String? _lastManualError;

  /// 当前的计划设置。
  ServerBackupConfig get settings => _settings();

  Directory get dir => Directory(p.join(dataDir, kServerBackupDirName));

  /// 正在写的文件名（任何来源；没在跑为 null）。
  String? get running => _running;
  ServerBackupKind? get runningKind => _runningKind;

  /// 进行中的那份（测试用来等它跑完）。
  Future<ServerBackupResult>? get pending => _job;

  /// 上次手动备份的失败原因（成功或新开一份时清空；只在内存里）。
  String? get lastManualError => _lastManualError;

  ServerBackupStatus get status => ServerBackupStatus.load(dir);

  /// 列出备份（不含正在写的那份）。
  List<ServerBackupEntry> list() =>
      listServerBackups(dir, skip: <String>{if (_running != null) _running!});

  /// 等手上的作业（任何来源）都结束。停机时调：库要等备份写完才关。
  Future<void> idle() async {
    while (_job != null) {
      try {
        await _job;
      } on Object {
        // 作业自己记了失败。
      }
    }
  }

  // ── 作业锁 ──────────────────────────────────────────────────────────

  /// 同步占位：成功返回 (文件名, 放掉复习库占位的回调)，否则返回拒绝原因。
  ({ServerBackupRefusal? refusal, String? name, void Function()? release})
  _claim(ServerBackupKind kind) {
    if (_running != null) {
      return (refusal: ServerBackupRefusal.busy, name: null, release: null);
    }
    final void Function()? release = _holdSrs();
    if (release == null) {
      return (
        refusal: ServerBackupRefusal.srsMigration,
        name: null,
        release: null,
      );
    }
    final String name = nextServerBackupFileName(dir, kind, _now());
    _running = name;
    _runningKind = kind;
    return (refusal: null, name: name, release: release);
  }

  /// 跑一份作业并占着作业锁直到它结束。返回的 future **从不以错误结束**：调用方（admin API 的
  /// 「立即备份」、计划任务）常常不 await 它，作业体里漏掉的异常要是从这里冒出去，就成了没人接的异步错误，
  /// 会把 serve 整个带走。作业体自己记失败；漏网的在这里记日志、按失败返回。
  Future<ServerBackupResult> _track(
    ServerBackupKind kind,
    String name,
    Future<ServerBackupResult> Function() body,
    void Function() release,
  ) {
    late final Future<ServerBackupResult> job;
    job = () async {
      try {
        return await body();
      } catch (e, stack) {
        engineLog.log('ServerBackup.${kind.wire}', e, stack);
        return ServerBackupResult(
          outcome: ServerBackupOutcome.failed,
          name: name,
          error: _oneLine(e),
        );
      } finally {
        _running = null;
        _runningKind = null;
        release();
        if (identical(_job, job)) _job = null;
      }
    }();
    _job = job;
    return job;
  }

  Future<File> _writeTo(String name, {required bool includeDocuments}) async {
    // 备份目录只给属主：里面每份包都含全部凭据。
    await dir.create(recursive: true);
    await restrictServerBackupPath(dir.path, '700');
    return _write(
      output: File(p.join(dir.path, name)),
      includeDocuments: includeDocuments,
    );
  }

  /// 动笔之前查空间（第五期）：不够抛 [NotEnoughSpaceException]，细节写进诊断日志（状态 / 回应里只放错误码）。
  Future<void> _ensureSpace(
    String label, {
    required bool includeDocuments,
  }) async {
    final int? forced = _freeBytes == null ? serverFreeBytesOverride() : null;
    if (forced != null) {
      engineLog.logDiagnostic(
        label,
        'WARNING: $kServerFreeBytesOverrideEnv=$forced is set (test only); '
        'free space is not measured',
      );
    }
    try {
      await ensureServerBackupSpace(
        dataDir: dataDir,
        outputDir: dir.path,
        includeDocuments: includeDocuments,
        configPath: configFile?.path,
        probe: _freeBytes,
        volumeId: _volumeId,
      );
    } on NotEnoughSpaceException catch (e) {
      engineLog.logDiagnostic(label, 'not started: ${e.detail}');
      rethrow;
    }
  }

  // ── 手动 ────────────────────────────────────────────────────────────

  /// 开始一份手动备份（永不被自动删）。
  ServerBackupStart startManual({required bool includeDocuments}) {
    final c = _claim(ServerBackupKind.manual);
    if (c.refusal != null) return _refused(c.refusal!);
    _lastManualError = null;
    final String name = c.name!;
    final Completer<String?> preflight = Completer<String?>();
    final Future<ServerBackupResult> done = _track(
      ServerBackupKind.manual,
      name,
      () async {
        try {
          final String? early = await _preflight(
            'ServerBackup.manual',
            preflight,
            includeDocuments: includeDocuments,
          );
          if (early != null) {
            _lastManualError = early;
            return ServerBackupResult(
              outcome: ServerBackupOutcome.failed,
              name: name,
              error: early,
            );
          }
          await _writeTo(name, includeDocuments: includeDocuments);
          return ServerBackupResult(
            outcome: ServerBackupOutcome.succeeded,
            name: name,
          );
        } catch (e, stack) {
          _lastManualError = _oneLine(e);
          engineLog.log('ServerBackup.manual', e, stack);
          return ServerBackupResult(
            outcome: ServerBackupOutcome.failed,
            name: name,
            error: _lastManualError,
          );
        }
      },
      c.release!,
    );
    return ServerBackupStart._(
      null,
      name,
      done,
      _releaseWhenDone(preflight, done),
    );
  }

  /// 动笔之前的检查（目前是查空间），结局交给 [preflight]（admin API 据此回 202 / 507 / 500）：通过 = null；
  /// 空间不够 = [kNotEnoughSpaceError]；估算本身失败（遍历数据目录读不了、后台 isolate 出错）=
  /// [kServerBackupErrorPreflightFailed]，原文只进日志、不进回应。返回同一个结局。
  Future<String?> _preflight(
    String label,
    Completer<String?> preflight, {
    required bool includeDocuments,
  }) async {
    String? early;
    try {
      await _ensureSpace(label, includeDocuments: includeDocuments);
    } on NotEnoughSpaceException {
      early = kNotEnoughSpaceError;
    } catch (e, stack) {
      engineLog.log(label, e, stack);
      early = kServerBackupErrorPreflightFailed;
    }
    if (!preflight.isCompleted) preflight.complete(early);
    return early;
  }

  /// 作业体在走到检查之前就结束了（没变化跳过、极少见的早退）也让等 [ServerBackupStart.preflight] 的一方放行。
  static Future<String?> _releaseWhenDone(
    Completer<String?> preflight,
    Future<ServerBackupResult> done,
  ) {
    unawaited(
      done.whenComplete(() {
        if (!preflight.isCompleted) preflight.complete(null);
      }),
    );
    return preflight.future;
  }

  // ── 自动 ────────────────────────────────────────────────────────────

  /// 现在到没到期（不看作业锁）。
  bool isDue() {
    final ServerBackupConfig s = _settings();
    final ServerBackupStatus st = status;
    return isBackupSlotDue(
      intervalDays: s.interval.days,
      preferredMinuteOfDay: s.minuteOfDay,
      now: _now(),
      lastSatisfied: _at(st.lastSatisfiedAtMs),
      lastInterrupted: _at(st.lastInterruptedAtMs),
    );
  }

  /// 开始一份自动备份。[force]（WebUI / ctl「立即跑一次」、离线 `backup run`）= 不看开关、不看到期、
  /// 不因「没变化」跳过。
  ServerBackupStart startAutomatic({bool force = false}) {
    if (!force) {
      if (!_settings().enabled) return _refused(ServerBackupRefusal.disabled);
      if (!isDue()) return _refused(ServerBackupRefusal.notDue);
    }
    final c = _claim(ServerBackupKind.auto);
    if (c.refusal == ServerBackupRefusal.srsMigration) {
      // 不算满足：下次检查（15 分钟后）再试。
      unawaited(
        _update(
          (ServerBackupStatus s) => s.copyWith(
            lastSkippedAtMs: _now().millisecondsSinceEpoch,
            lastSkipReason: kServerBackupSkipSrsMigration,
          ),
        ),
      );
    }
    if (c.refusal != null) return _refused(c.refusal!);
    final String name = c.name!;
    final Completer<String?> preflight = Completer<String?>();
    final Future<ServerBackupResult> done = _track(
      ServerBackupKind.auto,
      name,
      () => _runAutomatic(name, force: force, preflight: preflight),
      c.release!,
    );
    return ServerBackupStart._(
      null,
      name,
      done,
      _releaseWhenDone(preflight, done),
    );
  }

  /// [startAutomatic] 并等它跑完。
  Future<ServerBackupResult> runAutomatic({bool force = false}) =>
      startAutomatic(force: force).done;

  Future<ServerBackupResult> _runAutomatic(
    String name, {
    required bool force,
    required Completer<String?> preflight,
  }) async {
    final ServerBackupConfig s = _settings();
    final DateTime started = _now();
    try {
      // 指纹也在 try 里：遍历数据目录读不了（权限）时照样记成这一轮失败，而不是没人接的异常。
      final String print = await fingerprint(
        includeDocuments: s.includeDocuments,
      );
      final ServerBackupStatus before = status;
      final String? lastName = before.lastSuccessName;
      if (!force &&
          before.fingerprint == print &&
          lastName != null &&
          File(p.join(dir.path, lastName)).existsSync()) {
        await _update(
          (ServerBackupStatus st) => st.copyWith(
            lastSkippedAtMs: started.millisecondsSinceEpoch,
            lastSkipReason: kServerBackupSkipUnchanged,
            lastSatisfiedAtMs: started.millisecondsSinceEpoch,
          ),
        );
        engineLog.logDiagnostic(
          'ServerBackup.auto',
          'skipped: nothing changed since $lastName',
        );
        return const ServerBackupResult(
          outcome: ServerBackupOutcome.skippedUnchanged,
        );
      }
      // 空间不够：记成这一轮失败 `not_enough_space`（状态 + 日志，WebUI 显示），不写半截；估算本身失败记
      // `preflight_failed`。「立即跑」的 admin API 等这一步的结局回 202 / 507 / 500。
      final String? early = await _preflight(
        'ServerBackup.auto',
        preflight,
        includeDocuments: s.includeDocuments,
      );
      if (early != null) {
        await _update(
          (ServerBackupStatus st) => st.notRunning().copyWith(
            lastFailureAtMs: _now().millisecondsSinceEpoch,
            lastError: early,
          ),
        );
        return ServerBackupResult(
          outcome: ServerBackupOutcome.failed,
          name: name,
          error: early,
        );
      }
      await _update(
        (ServerBackupStatus st) => st.copyWith(
          runningSinceMs: () => started.millisecondsSinceEpoch,
          runningName: () => name,
          runningKind: () => ServerBackupKind.auto.wire,
        ),
      );
      final File written = await _writeTo(
        name,
        includeDocuments: s.includeDocuments,
      );
      final int bytes = await written.length();
      final List<String> pruned = await prune(protect: <String>{name});
      final int doneAt = _now().millisecondsSinceEpoch;
      await _update(
        (ServerBackupStatus st) => st.notRunning().copyWith(
          lastSuccessAtMs: doneAt,
          lastSuccessName: name,
          lastSuccessBytes: bytes,
          lastSatisfiedAtMs: started.millisecondsSinceEpoch,
          fingerprint: print,
          lastPrunedCount: pruned.length,
        ),
      );
      engineLog.logDiagnostic(
        'ServerBackup.auto',
        'wrote $name ($bytes bytes), pruned ${pruned.length}',
      );
      return ServerBackupResult(
        outcome: ServerBackupOutcome.succeeded,
        name: name,
        pruned: pruned,
      );
    } catch (e, stack) {
      engineLog.log('ServerBackup.auto', e, stack);
      // 写之前就失败（指纹遍历数据目录读不了）：「立即跑」回 500 + 安全的错误码，原文只进日志与状态。
      if (!preflight.isCompleted) {
        preflight.complete(kServerBackupErrorPreflightFailed);
      }
      final String error = _oneLine(e);
      await _update(
        (ServerBackupStatus st) => st.notRunning().copyWith(
          lastFailureAtMs: _now().millisecondsSinceEpoch,
          lastError: error,
        ),
      );
      return ServerBackupResult(
        outcome: ServerBackupOutcome.failed,
        name: name,
        error: error,
      );
    }
  }

  // ── 更新前 ──────────────────────────────────────────────────────────

  /// 远程自更新换包之前：设置 + 数据（不带 documents/）。有别的备份在跑就等它结束再开始。
  /// 从不抛：失败记进状态（`preUpdateError`）与日志，调用方照样换包（D16）。
  Future<ServerBackupResult> runPreUpdate() async {
    // 等别的作业结束；结束与占位之间又被别人抢先（手动备份刚好开始）就再等一轮。
    ({ServerBackupRefusal? refusal, String? name, void Function()? release}) c;
    do {
      await idle();
      c = _claim(ServerBackupKind.preUpdate);
    } while (c.refusal == ServerBackupRefusal.busy);
    if (c.refusal != null) {
      final String error = c.refusal == ServerBackupRefusal.srsMigration
          ? kServerBackupSkipSrsMigration
          : c.refusal!.name;
      await _update(
        (ServerBackupStatus st) => st.copyWith(
          preUpdateAtMs: _now().millisecondsSinceEpoch,
          preUpdateName: () => null,
          preUpdateError: () => error,
        ),
      );
      engineLog.logDiagnostic(
        'ServerBackup.preUpdate',
        'not taken ($error); the update goes ahead without it',
      );
      return ServerBackupResult(refusal: c.refusal, error: error);
    }
    final String name = c.name!;
    return _track(ServerBackupKind.preUpdate, name, () async {
      final DateTime started = _now();
      await _update(
        (ServerBackupStatus st) => st.copyWith(
          runningSinceMs: () => started.millisecondsSinceEpoch,
          runningName: () => name,
          runningKind: () => ServerBackupKind.preUpdate.wire,
        ),
      );
      try {
        // 空间不够：记成 `preUpdateError: not_enough_space`，更新照样进行（D16）。
        final String? early = await _preflight(
          'ServerBackup.preUpdate',
          Completer<String?>(),
          includeDocuments: false,
        );
        if (early != null) throw _PreflightFailure(early);
        await _writeTo(name, includeDocuments: false);
        final List<String> pruned = await prune(protect: <String>{name});
        await _update(
          (ServerBackupStatus st) => st.notRunning().copyWith(
            preUpdateAtMs: started.millisecondsSinceEpoch,
            preUpdateName: () => name,
            preUpdateError: () => null,
          ),
        );
        engineLog.logDiagnostic('ServerBackup.preUpdate', 'wrote $name');
        return ServerBackupResult(
          outcome: ServerBackupOutcome.succeeded,
          name: name,
          pruned: pruned,
        );
      } catch (e, stack) {
        engineLog.log('ServerBackup.preUpdate', e, stack);
        final String error = _oneLine(e);
        await _update(
          (ServerBackupStatus st) => st.notRunning().copyWith(
            preUpdateAtMs: started.millisecondsSinceEpoch,
            preUpdateName: () => null,
            preUpdateError: () => error,
          ),
        );
        return ServerBackupResult(
          outcome: ServerBackupOutcome.failed,
          name: name,
          error: error,
        );
      }
    }, c.release!);
  }

  // ── 修剪 / 删除 / 中断 ──────────────────────────────────────────────

  /// 按保留规则删自动备份与更新前备份（手动备份不动）；逐份尽力，删不掉的留到下次。返回删掉的文件名。
  Future<List<String>> prune({Set<String> protect = const <String>{}}) async {
    // 正在写的那份不参与；刚写完、还占着作业锁的那份（在 [protect] 里）要参与：它占着「最新」的位置，
    // 更新前备份的「留 3 份」、自动备份的「最新一份」都按它算。
    final List<ServerBackupEntry> doomed = planServerBackupPrune(
      listServerBackups(
        dir,
        skip: <String>{
          if (_running != null && !protect.contains(_running)) _running!,
        },
      ),
      now: _now(),
      maxTotalBytes: _settings().maxTotalBytes,
      protect: protect,
    );
    final List<String> out = <String>[];
    for (final ServerBackupEntry e in doomed) {
      try {
        await File(p.join(dir.path, e.name)).delete();
        out.add(e.name);
      } on FileSystemException catch (x) {
        engineLog.logDiagnostic(
          'ServerBackup.prune',
          '${e.name}: ${x.message}',
        );
      }
    }
    return out;
  }

  /// 删一份备份。名字必须是备份文件名（三种来源之一），正在写的那份不能删。返回是否删了。
  Future<bool> delete(String name) async {
    if (!isServerBackupFileName(name) || name == _running) return false;
    final File f = File(p.join(dir.path, name));
    if (!f.existsSync()) return false;
    await f.delete();
    return true;
  }

  /// 进程启动（已持数据目录锁）时调：清掉上次留下的半截 `.partial`；状态里的「在跑」标记还在 =
  /// 上次写到一半进程没了，记成中断。返回是否发现了中断。
  Future<bool> recoverInterrupted() async {
    if (_running != null) return false;
    if (dir.existsSync()) {
      for (final FileSystemEntity e in dir.listSync(followLinks: false)) {
        final String name = p.basename(e.path);
        if (e is File &&
            name.endsWith('.partial') &&
            isServerBackupFileName(name.substring(0, name.length - 8))) {
          try {
            await e.delete();
          } on FileSystemException {
            // 下次再清。
          }
        }
      }
    }
    final ServerBackupStatus st = status;
    final int? since = st.runningSinceMs;
    if (since == null) return false;
    final bool auto = st.runningKind != ServerBackupKind.preUpdate.wire;
    final int now = _now().millisecondsSinceEpoch;
    await _update(
      (ServerBackupStatus s) => auto
          ? s.notRunning().copyWith(
              lastFailureAtMs: now,
              lastError: kServerBackupErrorInterrupted,
              lastInterruptedAtMs: since,
            )
          : s.notRunning().copyWith(
              preUpdateAtMs: since,
              preUpdateName: () => null,
              preUpdateError: () => kServerBackupErrorInterrupted,
            ),
    );
    engineLog.logDiagnostic(
      'ServerBackup',
      'the previous ${st.runningKind ?? 'auto'} backup (${st.runningName}) '
          'was interrupted; cleaned up',
    );
    return true;
  }

  // ── 指纹 ────────────────────────────────────────────────────────────

  /// 这份数据现在的指纹：要进包的每个源文件（库文件、`-wal`、数据目录清单，[includeDocuments] 时含
  /// documents/）的相对路径 + 大小 + 修改时间，加上配置文件与 documents 开关，取 sha1。只用来判断
  /// 「跟上次成功那份比有没有变」，便宜（只 stat，不读内容），在后台 isolate 里算。
  Future<String> fingerprint({required bool includeDocuments}) =>
      _fingerprinter?.call(includeDocuments: includeDocuments) ??
      _fingerprintInIsolate(dataDir, configFile?.path, includeDocuments);

  // ── 内部 ────────────────────────────────────────────────────────────

  /// 状态读改写串行化（作业与修剪 / 中断检测可能交错）。
  Future<void> _statusChain = Future<void>.value();

  Future<void> _update(ServerBackupStatus Function(ServerBackupStatus) f) {
    final Future<void> next = _statusChain.then((_) async {
      try {
        await f(status).save(dir);
      } on Object catch (e, stack) {
        engineLog.log('ServerBackup.status', e, stack);
      }
    });
    _statusChain = next;
    return next;
  }

  ServerBackupStart _refused(ServerBackupRefusal r) => ServerBackupStart._(
    r,
    null,
    Future<ServerBackupResult>.value(ServerBackupResult(refusal: r)),
  );
}

/// 后台 isolate 算指纹。只传字符串 / 布尔：闭包别捕获服务对象（同 server_backup.dart 的解包）。
Future<String> _fingerprintInIsolate(
  String data,
  String? config,
  bool includeDocuments,
) => Isolate.run(() => _fingerprintSync(data, config, includeDocuments));

String _fingerprintSync(String data, String? config, bool includeDocuments) {
  final List<String> lines = <String>['documents=$includeDocuments'];
  void add(String path, String label) {
    final FileStat st = FileStat.statSync(path);
    if (st.type == FileSystemEntityType.notFound) return;
    lines.add('$label\t${st.size}\t${st.modified.millisecondsSinceEpoch}');
  }

  for (final String f in serverBackupSourceFiles(
    data,
    includeDocuments: includeDocuments,
  )) {
    add(f, p.relative(f, from: data).replaceAll(r'\', '/'));
  }
  if (config != null) add(config, 'config');
  lines.sort();
  return sha1.convert(utf8.encode(lines.join('\n'))).toString();
}

void Function()? _noSrs() => _noop;
void _noop() {}

DateTime? _at(int? ms) =>
    ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);

/// 一行、限长的原因（状态文件与 WebUI 用；异常文本里只有路径与原因，没有配置内容）。
String _oneLine(Object e) {
  final String s = '$e'.split('\n').first.trim();
  return s.length > 300 ? '${s.substring(0, 300)}…' : s;
}

/// 更新前备份动笔前检查没过：把安全的错误码（`toString`）交给外层的失败记录。
class _PreflightFailure implements Exception {
  const _PreflightFailure(this.code);

  final String code;

  @override
  String toString() => code;
}
