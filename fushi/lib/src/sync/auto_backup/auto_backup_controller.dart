/// 自动备份（定时还原点）与操作前还原点的编排
/// （docs/specs/2026-11-25-auto-backup-restore-points.md 第二层）。
///
/// - **定时备份**：到期（[isAutoBackupDue]）且数据有变化（[computeAutoBackupFingerprint]）时，用
///   手动导出同一个 [BackupService.createBackup] 打一份压缩的整包备份，写进还原点存储的新
///   `scheduled` 点（`<root>/<id>/backup.zip` + `restore_point.json`），再按
///   [kRestorePointScheduledRetention] 修剪（刚写好的那份不删）。一次只跑一份，与手动导出共用
///   [AutoBackupHost.backupExportActive] 这把锁；失败记进状态文件并提示一次，不重试循环。
/// - **操作前还原点**：[createPreOperationPoint]（主库 `VACUUM INTO` + 复习库内核快照），在覆盖本机
///   数据的操作之前由调用方显式调用。
/// - **调度**：[start] 在首页就绪后挂一个空闲任务查一次、桌面端每
///   [kAutoBackupDesktopCheckInterval] 查一次；[onResumed] 回前台查一次。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_progress.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_schedule.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_settings.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_status.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 操作前还原点的 `reason`：从还原点页 / 控制通道「替换」之前。
const String kRestorePointReasonReplace = 'replace';

/// 操作前还原点的 `reason`：同步对比里选了「用远端」覆盖本机之前。
const String kRestorePointReasonSyncDownload = 'sync_download';

/// 操作前还原点的 `reason`：从 Anki 迁移复习数据之前。
const String kRestorePointReasonSrsMigration = 'srs_migration';

/// 自动备份对宿主（app）的全部依赖；测试注入假宿主。
abstract interface class AutoBackupHost {
  /// 活库目录（`fushi.db` / `srs4.db` 与默认还原点目录都在这里）。
  String get databaseDirectory;

  /// 当前设置。
  AutoBackupSettings readSettings();

  /// 平台支不支持自定义文件夹（第二期只有桌面端）。
  bool get supportsCustomFolder;

  /// 与手动导出同一份构造的备份服务。
  BackupService createBackupService();

  /// 各内容类别在盘上的文件树根（指纹用）；不在里面的类别不进指纹。
  Map<BackupCategory, String> get contentTreeRoots;

  /// 复习媒体根（`<support>/srs_media`）。
  String get srsMediaRoot;

  /// 备份导出的所有权（手动导出 / 控制通道导出 / 自动备份共用一把锁）。
  bool get backupExportActive;
  void beginBackupExport();
  void endBackupExport();
  void reportBackupExportProgress(double fraction);

  /// 复习库开着时把它一致地快照到 [destPath]（内核的 `VACUUM INTO`）；复习库没开（模块关 /
  /// 从没用过）返回 null，操作前还原点就只带主库。
  Future<Future<void> Function(String destPath)?> srsSnapshotWriter();

  /// 定时备份失败：提示用户一次（状态页的告警行另外常驻）。
  void notifyFailure(String reason);

  /// 操作前还原点没拍成、操作照常继续（[takePreOperationRestorePoint]）：提示用户一次。
  void notifyPreOperationFailure(String reason);
}

AutoBackupController? _registeredController;

/// 登记进程里的自动备份控制器（AppModel 首页就绪时）。不持有 AppModel 的流程（同步对比里
/// 「用远端」覆盖本机、复习迁移任务）经 [takePreOperationRestorePoint] 拍操作前还原点。
void registerAutoBackupController(AutoBackupController? controller) =>
    _registeredController = controller;

/// 在覆盖本机数据的操作之前拍一个操作前还原点。还没登记控制器（测试 / 非主进程）返回 null；
/// 拍不成时提示一次并返回 null，操作照常继续（磁盘满之类不该把同步 / 迁移卡死）。要求
/// 「拍不成就不做」的调用方（还原点页的替换）直接调 [AutoBackupController.createPreOperationPoint]。
Future<RestorePoint?> takePreOperationRestorePoint(String reason) async {
  final AutoBackupController? controller = _registeredController;
  if (controller == null) return null;
  try {
    return await controller.createPreOperationPoint(reason);
  } catch (e, st) {
    debugPrint('AutoBackup: pre-operation point ($reason) failed: $e\n$st');
    controller.host.notifyPreOperationFailure('$e');
    return null;
  }
}

/// 一次检查 / 运行的结局。
enum AutoBackupOutcome {
  /// 建好了一个定时还原点。
  created,

  /// 到期了但数据没变，记成「跳过」。
  skippedNoChanges,

  /// 还没到期。
  notDue,

  /// 自动备份关着。
  disabled,

  /// 已有备份在跑（自动或手动导出），这次不跑，下次到期检查再看。
  busy,

  /// 失败（已记状态、已提示）。
  failed,
}

/// 自动备份控制器：AppModel 持有一个，设置页 / 还原点页 / 控制通道都经它。
class AutoBackupController {
  AutoBackupController({required this.host, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AutoBackupHost host;
  final DateTime Function() _clock;

  late final ValueNotifier<AutoBackupStatus> _status =
      ValueNotifier<AutoBackupStatus>(
        readAutoBackupStatus(host.databaseDirectory),
      );

  /// 状态文件的最新内容（设置页状态行听它）。
  ValueListenable<AutoBackupStatus> get status => _status;

  bool _running = false;
  bool _started = false;
  Timer? _timer;

  /// 有没有一次定时备份在跑。
  bool get running => _running;

  /// 默认还原点存储（操作前 / 更新前 / 回滚前还原点、状态文件）。
  RestorePointStore get defaultStore =>
      RestorePointStore(host.databaseDirectory);

  /// 定时还原点所在的存储：设了自定义文件夹（且平台支持）就是那个文件夹。
  RestorePointStore scheduledStore([AutoBackupSettings? settings]) {
    final String? folder = (settings ?? host.readSettings()).effectiveFolder(
      supportsCustomFolder: host.supportsCustomFolder,
    );
    return RestorePointStore(host.databaseDirectory, rootDirectory: folder);
  }

  /// 现存的定时还原点（新的在前）。
  List<RestorePoint> scheduledPoints([AutoBackupSettings? settings]) =>
      <RestorePoint>[
        for (final RestorePoint point in scheduledStore(settings).list())
          if (point.kind == RestorePointKind.scheduled) point,
      ];

  /// 首页就绪后调用：等这一帧画完、挂一个空闲优先级的任务查一次；桌面端起周期检查。
  /// 幂等。
  void start() {
    if (_started) return;
    _started = true;
    unawaited(_checkWhenIdle());
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      _timer = Timer.periodic(
        kAutoBackupDesktopCheckInterval,
        (_) => unawaited(checkNow()),
      );
    }
  }

  /// 停掉周期检查（换库 / 关库前）。在跑的那一次不打断。
  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
  }

  /// 回到前台：查一次。
  void onResumed() {
    if (!_started) return;
    unawaited(_checkWhenIdle());
  }

  Future<void> _checkWhenIdle() async {
    await SchedulerBinding.instance.endOfFrame;
    await SchedulerBinding.instance.scheduleTask<Future<AutoBackupOutcome>>(
      checkNow,
      Priority.idle,
    );
  }

  /// 到期就跑一次（没变化则记跳过）。
  Future<AutoBackupOutcome> checkNow() async {
    final AutoBackupSettings settings = host.readSettings();
    if (!settings.enabled) return AutoBackupOutcome.disabled;
    if (!isAutoBackupDue(
      settings: settings,
      now: _clock(),
      lastSatisfied: _status.value.lastSatisfied,
    )) {
      return AutoBackupOutcome.notDue;
    }
    return _run(settings, force: false);
  }

  /// 「立即备份」：不看到期、也不因没变化跳过，直接建一个定时还原点。
  Future<AutoBackupOutcome> backUpNow() =>
      _run(host.readSettings(), force: true);

  /// 重读状态文件（还原点页删点之后等）。
  void reloadStatus() =>
      _status.value = readAutoBackupStatus(host.databaseDirectory);

  Future<AutoBackupOutcome> _run(
    AutoBackupSettings settings, {
    required bool force,
  }) async {
    if (_running || host.backupExportActive) return AutoBackupOutcome.busy;
    _running = true;
    try {
      final String fingerprint = await _fingerprint(settings);
      final int startedMs = _clock().millisecondsSinceEpoch;
      if (!force && fingerprint == _status.value.fingerprint) {
        _writeStatus(_status.value.skipped(atMs: startedMs));
        return AutoBackupOutcome.skippedNoChanges;
      }
      return await _createScheduledPoint(
        settings,
        fingerprint: fingerprint,
        startedMs: startedMs,
      );
    } catch (e, st) {
      // 指纹本身失败（极少见）：同样按失败记、提示一次。
      debugPrint('AutoBackup: run failed: $e\n$st');
      _writeStatus(
        _status.value.failed(
          atMs: _clock().millisecondsSinceEpoch,
          error: '$e',
        ),
      );
      host.notifyFailure('$e');
      return AutoBackupOutcome.failed;
    } finally {
      _running = false;
    }
  }

  Future<AutoBackupOutcome> _createScheduledPoint(
    AutoBackupSettings settings, {
    required String fingerprint,
    required int startedMs,
  }) async {
    final RestorePointStore store = scheduledStore(settings);
    RestorePointDraft? draft;
    host.beginBackupExport();
    autoBackupProgress.value = const AutoBackupProgress();
    try {
      draft = store.begin(kind: RestorePointKind.scheduled, nowMs: startedMs);
      final BackupMeta meta = await host.createBackupService().createBackup(
        p.join(draft.directory, kRestorePointArchiveFileName),
        categories: settings.categories,
        compress: true,
        includeSrsMedia: settings.includeSrsMedia,
        onProgress: (double fraction) {
          host.reportBackupExportProgress(fraction);
          autoBackupProgress.value = AutoBackupProgress(fraction: fraction);
        },
      );
      final RestorePoint point = store.commit(
        draft,
        fromSchema: meta.schemaVersion,
        toSchema: meta.schemaVersion,
        categories: <String>[
          for (final BackupCategory c in BackupCategory.values)
            if (settings.categories.contains(c)) c.name,
        ],
        excludedCategories: <String>[
          for (final BackupCategory c in BackupCategory.values)
            if (!settings.categories.contains(c)) c.name,
        ],
        includesSrsMedia:
            settings.categories.contains(BackupCategory.srs) &&
            settings.includeSrsMedia,
      );
      draft = null;
      store.pruneScheduled(protectId: point.id, now: _clock());
      _writeStatus(
        _status.value.succeeded(
          atMs: startedMs,
          pointId: point.id,
          bytes: point.totalBytes,
          fingerprint: fingerprint,
        ),
      );
      return AutoBackupOutcome.created;
    } catch (e, st) {
      debugPrint('AutoBackup: scheduled backup failed: $e\n$st');
      if (draft != null) store.discard(draft);
      _writeStatus(
        _status.value.failed(
          atMs: _clock().millisecondsSinceEpoch,
          error: '$e',
        ),
      );
      host.notifyFailure('$e');
      return AutoBackupOutcome.failed;
    } finally {
      autoBackupProgress.value = null;
      host.endBackupExport();
    }
  }

  Future<String> _fingerprint(AutoBackupSettings settings) {
    final String dbDir = host.databaseDirectory;
    final List<String> files = <String>[
      for (final RestorePointDatabase db
          in RestorePointDatabase.values) ...<String>[
        p.join(dbDir, db.fileName),
        p.join(dbDir, '${db.fileName}-wal'),
      ],
    ];
    final Map<BackupCategory, String> roots = host.contentTreeRoots;
    final List<String> directories = <String>[
      for (final BackupCategory c in BackupCategory.values)
        if (settings.categories.contains(c) && roots[c] != null) roots[c]!,
      if (settings.categories.contains(BackupCategory.srs) &&
          settings.includeSrsMedia)
        host.srsMediaRoot,
    ];
    return computeAutoBackupFingerprint(
      files: files,
      directories: directories,
      contentSignature: settings.contentSignature,
    );
  }

  void _writeStatus(AutoBackupStatus next) {
    try {
      writeAutoBackupStatus(host.databaseDirectory, next);
    } catch (e) {
      debugPrint('AutoBackup: status write failed: $e');
    }
    _status.value = next;
  }

  /// 操作前还原点（[reason]：`sync_download` / `srs_migration` / `replace` …）：主库
  /// `VACUUM INTO` + 复习库开着时的内核快照，写进默认还原点存储，留最新
  /// [kRestorePointKeepPreOperation] 份。失败抛出，由调用方决定要不要继续。
  Future<RestorePoint> createPreOperationPoint(
    String reason, {
    bool includeMainDatabase = true,
    bool includeSrs = true,
  }) async {
    final Future<void> Function(String destPath)? srs = includeSrs
        ? await host.srsSnapshotWriter()
        : null;
    return defaultStore.createPreOperationPoint(
      reason: reason,
      fushiDbPath: includeMainDatabase
          ? p.join(host.databaseDirectory, RestorePointDatabase.fushi.fileName)
          : null,
      snapshotSrs: srs,
    );
  }

  void dispose() {
    stop();
    _status.dispose();
  }
}
