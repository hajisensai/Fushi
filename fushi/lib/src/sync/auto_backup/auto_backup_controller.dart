/// 自动备份（定时还原点）与操作前还原点的编排
/// （docs/specs/2026-11-25-auto-backup-restore-points.md 第二层）。
///
/// - **定时备份**：到期（[isAutoBackupDue]）且数据有变化（[computeAutoBackupFingerprint]）时，用
///   手动导出同一个 [BackupService.createBackup] 打一份压缩的**整库**备份（`fullDatabase`：库里
///   每一类数据都在，设置里只挑带哪些文件树），写进还原点存储的新 `scheduled` 点
///   （`<root>/<id>/backup.zip` + `restore_point.json`），再按 [kRestorePointScheduledRetention]
///   修剪（刚写好的那份不删）。一次只跑一份：一进 [AutoBackupController._run] 就拿
///   [AutoBackupHost.beginBackupExport] 这把导出锁（与手动导出、替换 / 补回 / 导入互斥）；库不可用
///   （导入 / 替换中、已关库）时不跑。失败记进状态文件并提示一次，不重试循环；写到一半进程没了，
///   下次启动认出来记成「被打断」。
/// - **操作前还原点**：[AutoBackupController.createPreOperationPoint]（主库 `VACUUM INTO` + 复习库
///   内核快照），在覆盖本机数据的操作之前由调用方显式调用。
/// - **用户文件夹（第三期，移动端）**：定时还原点照旧写进本机存储；设了用户文件夹
///   （[AutoBackupSettings.mirrorFolder]）时，写好的点再复制一份进去（[BackupFolderMirror]），文件夹里
///   本机写的副本按同一套保留规则修剪（[planMirrorRetention]，别的设备的副本不动）。复制失败不算
///   备份失败：单独记在 [AutoBackupStatus.mirror]、提示一次。没复制上的（被打断、换了文件夹）在下次
///   检查时补上；明确失败过的等下一个到期时段或「立即备份」再试，不每次回前台都重试。
/// - **调度**：[AutoBackupController.start] 在首页就绪后挂一个空闲任务查一次、桌面端每
///   [kAutoBackupDesktopCheckInterval] 查一次；[AutoBackupController.onResumed] 回前台查一次。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_progress.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_schedule.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_settings.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_status.dart';
import 'package:fushi/src/sync/auto_backup/backup_folder_mirror.dart';
import 'package:fushi/src/sync/auto_backup/backup_folder_platform.dart';
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

  /// 移动端的用户文件夹（第三期：Android SAF / iOS 书签）；不支持的平台 [BackupFolderPlatform.supported]
  /// 为 false。
  BackupFolderPlatform get mirrorPlatform;

  /// 这台设备的 id 与显示名（写进文件夹副本：保留规则只修剪本机写的副本）。
  Future<({String id, String name})> deviceIdentity();

  /// 系统重建了文件夹授权（iOS 书签过期）：存回设置。
  Future<void> saveMirrorFolder(AutoBackupMirrorFolder folder);

  /// 与手动导出同一份构造的备份服务。
  BackupService createBackupService();

  /// 主库现在能不能用来备份：导入 / 替换 / 补回进行中（已经或即将关库）、库已关时为 false，
  /// 这时定时备份不跑（[AutoBackupOutcome.busy]）。
  bool get databaseAvailable;

  /// 各内容类别在盘上的文件树根（指纹用）；不在里面的类别不进指纹。
  Map<BackupCategory, String> get contentTreeRoots;

  /// 复习媒体根（`<support>/srs_media`）。
  String get srsMediaRoot;

  /// 备份导出的所有权（手动导出 / 控制通道导出 / 自动备份共用一把锁）。
  bool get backupExportActive;

  /// 拿锁：成功返回这次持有的凭据，已被别人持有返回 null。
  Object? beginBackupExport();

  /// 放锁：只有 [token] 是当前持有者才放（别人的锁不会被误放）。
  void endBackupExport(Object token);

  void reportBackupExportProgress(double fraction);

  /// 复习库这会儿不能备份的原因（`SrsGenState.wire`：还在等升级、别的进程在迁、只剩封存旧库、上次
  /// 迁移失败）；能备份（或根本没有复习库）返回 null。只看磁盘上的代际状态，不开库。
  String? srsUnavailableReason();

  /// 复习库开着时把它一致地快照到 [destPath]（内核的 `VACUUM INTO`）；复习库没开（模块关 /
  /// 从没用过）返回 null，操作前还原点就只带主库。
  Future<Future<void> Function(String destPath)?> srsSnapshotWriter();

  /// 定时备份失败：提示用户一次（状态页的告警行另外常驻）。[reason] 是状态里的错误
  /// （认识的错误码见 `auto_backup_status.dart`，文案用 `autoBackupErrorText`）。
  void notifyFailure(String reason);

  /// 定时还原点写好了，复制进用户文件夹失败：提示用户一次（设置页另有常驻告警行）。
  void notifyMirrorFailure(String reason);

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

  /// 已有备份在跑（自动或手动导出），或库正在导入 / 替换（不可用），这次不跑，下次到期检查再看。
  busy,

  /// 失败（已记状态、已提示）。
  failed,
}

/// 自定义文件夹不在（外接盘没插、网络盘没挂上）：不在本机盘上替它建一个同名目录，按失败记
/// （[kAutoBackupErrorFolderUnavailable]）。
/// 文件夹操作时已有备份在跑（自动 / 手动导出、还原），这次不做。
class AutoBackupBusyException implements Exception {
  const AutoBackupBusyException();

  @override
  String toString() => 'a backup is already running';
}

class AutoBackupFolderUnavailableException implements Exception {
  const AutoBackupFolderUnavailableException(this.folder);

  final String folder;

  @override
  String toString() => 'backup folder unavailable: $folder';
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

  /// 实际生效的用户文件夹（平台不支持 / 没设为 null）。
  AutoBackupMirrorFolder? mirrorFolder([AutoBackupSettings? settings]) =>
      (settings ?? host.readSettings()).effectiveMirrorFolder(
        supportsMirrorFolder: host.mirrorPlatform.supported,
      );

  /// 首页就绪后调用：先认出上次写到一半就被打断的运行，再等这一帧画完、挂一个空闲优先级的
  /// 任务查一次；桌面端起周期检查。幂等。
  void start() {
    if (_started) return;
    _started = true;
    recoverInterruptedRun();
    unawaited(_checkWhenIdle());
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      _timer = Timer.periodic(
        kAutoBackupDesktopCheckInterval,
        (_) => unawaited(checkNow()),
      );
    }
  }

  /// 状态里的「开始」标记还在、本进程又没在跑 = 上次写到一半进程就没了（被系统杀掉 / 崩溃 /
  /// 退出）：记成失败「被打断」、提示一次、清掉半截目录。到期判定据
  /// [AutoBackupStatus.lastInterrupted] 等到下一个时段再试，不在每次启动都重跑、每次都在同一处
  /// 被杀。[start] 里调；返回有没有认出一次被打断的运行。
  bool recoverInterruptedRun() {
    final AutoBackupStatus current = _status.value;
    if (current.runningSinceMs == null || _running) return false;
    _writeStatus(current.interrupted());
    try {
      scheduledStore().cleanIncompleteScheduled();
    } on Object catch (e) {
      debugPrint('AutoBackup: cleaning the interrupted point failed: $e');
    }
    host.notifyFailure(kAutoBackupErrorInterrupted);
    return true;
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
      lastInterrupted: _status.value.lastInterrupted,
    )) {
      await _catchUpMirror(settings);
      return AutoBackupOutcome.notDue;
    }
    return _run(settings, force: false);
  }

  /// 没到期时补复制：最新的定时还原点还不在用户文件夹里（复制被打断、刚选了 / 换了文件夹），且对这个
  /// 文件夹没有明确失败过（失败过的等下一个到期时段或「立即备份」，不每次回前台都重试、都提示）。
  /// 不提示。
  Future<void> _catchUpMirror(AutoBackupSettings settings) async {
    final AutoBackupMirrorFolder? folder = mirrorFolder(settings);
    if (folder == null) return;
    final AutoBackupStatus status = _status.value;
    final String? id = status.lastSuccessPointId;
    if (id == null || status.mirror.holds(folder.key, id)) return;
    if (status.mirror.failedFor(folder.key) &&
        status.mirror.pendingId == null) {
      return;
    }
    if (_running || !host.databaseAvailable) return;
    final Object? lock = host.beginBackupExport();
    if (lock == null) return;
    _running = true;
    try {
      final RestorePoint? point = RestorePoint.tryRead(
        p.join(scheduledStore(settings).root, id),
      );
      if (point == null) return;
      await _mirrorPoint(folder, point, notify: false);
    } finally {
      _running = false;
      host.endBackupExport(lock);
    }
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
    // 一进来就拿锁（任何 await 之前）：指纹要遍历文件树、耗时，拿晚了别的导出 / 替换会在这段
    // 空档里插进来。
    if (_running || !host.databaseAvailable) return AutoBackupOutcome.busy;
    final Object? lock = host.beginBackupExport();
    if (lock == null) return AutoBackupOutcome.busy;
    _running = true;
    try {
      final RestorePointStore store = scheduledStore(settings);
      final String? folder = settings.effectiveFolder(
        supportsCustomFolder: host.supportsCustomFolder,
      );
      if (folder != null && !Directory(folder).existsSync()) {
        throw AutoBackupFolderUnavailableException(folder);
      }
      final String fingerprint = await _fingerprint(settings, store);
      final int startedMs = _clock().millisecondsSinceEpoch;
      // 指纹相同还得上次成功的那份还在当前存储里：被删了（还原点页删除、控制通道撤销）或换了
      // 文件夹，就不能拿「没变化」跳过——否则永远跳过、也永远不告警。
      if (!force &&
          fingerprint == _status.value.fingerprint &&
          _lastSuccessPointExists(store)) {
        _writeStatus(_status.value.skipped(atMs: startedMs));
        // 数据没变，但最新那份可能还没进用户文件夹（上次复制失败 / 换了文件夹）：这一期补上。
        final AutoBackupMirrorFolder? folder = mirrorFolder(settings);
        final String? id = _status.value.lastSuccessPointId;
        if (folder != null &&
            id != null &&
            !_status.value.mirror.holds(folder.key, id)) {
          final RestorePoint? point = RestorePoint.tryRead(
            p.join(store.root, id),
          );
          if (point != null) await _mirrorPoint(folder, point, notify: true);
        }
        return AutoBackupOutcome.skippedNoChanges;
      }
      return await _createScheduledPoint(
        settings,
        store,
        fingerprint: fingerprint,
        startedMs: startedMs,
      );
    } catch (e, st) {
      // 文件夹不在 / 指纹本身失败（极少见）：同样按失败记、提示一次。
      debugPrint('AutoBackup: run failed: $e\n$st');
      final String error = e is AutoBackupFolderUnavailableException
          ? kAutoBackupErrorFolderUnavailable
          : '$e';
      _writeStatus(
        _status.value.failed(
          atMs: _clock().millisecondsSinceEpoch,
          error: error,
        ),
      );
      host.notifyFailure(error);
      return AutoBackupOutcome.failed;
    } finally {
      _running = false;
      host.endBackupExport(lock);
    }
  }

  bool _lastSuccessPointExists(RestorePointStore store) {
    final String? id = _status.value.lastSuccessPointId;
    if (id == null) return false;
    return RestorePoint.tryRead(p.join(store.root, id)) != null;
  }

  Future<AutoBackupOutcome> _createScheduledPoint(
    AutoBackupSettings settings,
    RestorePointStore store, {
    required String fingerprint,
    required int startedMs,
  }) async {
    final Set<BackupCategory> files = <BackupCategory>{
      for (final BackupCategory c in settings.categories)
        if (kBackupFileCategories.contains(c)) c,
    };
    // 复习库还在等升级等：开库会抛。照样备份其余数据，复习记成「没带」（恢复时保留本机那份），
    // 状态行说明原因；不让整份备份因此失败、天天失败。
    final Set<BackupCategory> unavailable = <BackupCategory>{
      if (host.srsUnavailableReason() != null) BackupCategory.srs,
    };
    RestorePointDraft? draft;
    autoBackupProgress.value = const AutoBackupProgress();
    // 「开始」标记：写到一半进程没了，下次启动据此认出来（[recoverInterruptedRun]）。
    _writeStatus(_status.value.started(atMs: startedMs));
    try {
      draft = store.begin(kind: RestorePointKind.scheduled, nowMs: startedMs);
      final BackupMeta meta = await host.createBackupService().createBackup(
        p.join(draft.directory, kRestorePointArchiveFileName),
        categories: files,
        fullDatabase: true,
        unavailableData: unavailable,
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
        // 整库：数据类别都在（读不了的除外），文件类别只有勾着的。
        categories: <String>[
          for (final BackupCategory c in BackupCategory.values)
            if (!unavailable.contains(c) &&
                (!kBackupFileCategories.contains(c) || files.contains(c)))
              c.name,
        ],
        excludedCategories: <String>[
          for (final BackupCategory c in BackupCategory.values)
            if (unavailable.contains(c) ||
                (kBackupFileCategories.contains(c) && !files.contains(c)))
              c.name,
        ],
        includesSrsMedia: settings.includeSrsMedia,
        fullDatabase: true,
      );
      draft = null;
      store.pruneScheduled(protectId: point.id, now: _clock());
      _writeStatus(
        _status.value.succeeded(
          atMs: startedMs,
          pointId: point.id,
          bytes: point.totalBytes,
          fingerprint: fingerprint,
          missingData: <String>[
            for (final BackupCategory c in unavailable) c.name,
          ],
        ),
      );
      final AutoBackupMirrorFolder? folder = mirrorFolder(settings);
      if (folder != null) await _mirrorPoint(folder, point, notify: true);
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
    }
  }

  // ── 用户文件夹（第三期） ───────────────────────────────────────────────────

  /// 把本机定时还原点 [point] 复制进用户文件夹 [folder]，再按保留规则修剪文件夹里本机写的副本。调用方
  /// 持有导出锁。失败只记进 [AutoBackupStatus.mirror]（[notify] 时提示一次），从不抛出：本机那份已经
  /// 写好了。
  Future<void> _mirrorPoint(
    AutoBackupMirrorFolder folder,
    RestorePoint point, {
    required bool notify,
  }) async {
    final String? interrupted = _status.value.mirror.pendingId;
    _writeStatus(
      _status.value.withMirror(
        _status.value.mirror.started(folderKey: folder.key, id: point.id),
      ),
    );
    // 复制期间钉住本机那份：还原点页删点 / 别处的修剪删不到它。
    final void Function() release = RestorePointStore.hold(point.directory);
    BackupFolderSession? session;
    try {
      session = await host.mirrorPlatform.open(folder);
      final AutoBackupMirrorFolder? refreshed = session.refreshedFolder;
      if (refreshed != null) await host.saveMirrorFolder(refreshed);
      final BackupFolderMirror mirror = session.mirror;
      final ({String id, String name}) device = await host.deviceIdentity();
      // 上次复制到一半进程就没了：那份半截副本按 id 精确清掉（同一个 id 下面照样会覆盖重写）。
      if (interrupted != null && interrupted != point.id) {
        await mirror.delete(interrupted);
      }
      final MirrorFolderListing listing = await mirror.list();
      final List<MirroredRestorePoint> copies = <MirroredRestorePoint>[
        ...listing.points,
      ];
      if (!copies.any((MirroredRestorePoint c) => c.id == point.id)) {
        final String meta = mirrorMetaText(
          point,
          deviceId: device.id,
          deviceName: device.name,
        );
        await mirror.upload(point, metaText: meta);
        // 刚复制的那份也参与保留：它占住自己的日 / 周 / 月桶，同桶里更旧的本机副本才会被修剪。
        final RestorePoint? uploaded = RestorePoint.tryParse(
          meta,
          id: point.id,
          directory: point.id,
        );
        if (uploaded != null) {
          copies.add(MirroredRestorePoint(point: uploaded, metaText: meta));
        }
      }
      final List<MirroredRestorePoint> doomed = planMirrorRetention(
        copies,
        deviceId: device.id,
        now: _clock(),
        protectId: point.id,
      );
      for (final MirroredRestorePoint copy in doomed) {
        await mirror.delete(copy.id);
      }
      _writeStatus(
        _status.value.withMirror(
          _status.value.mirror.succeeded(
            folderKey: folder.key,
            id: point.id,
            atMs: _clock().millisecondsSinceEpoch,
          ),
        ),
      );
    } catch (e, st) {
      debugPrint(
        'AutoBackup: copying ${point.id} to the folder failed: $e\n$st',
      );
      final String error = e is BackupFolderUnavailableException
          ? kAutoBackupErrorFolderUnavailable
          : '$e';
      _writeStatus(
        _status.value.withMirror(
          _status.value.mirror.failed(
            folderKey: folder.key,
            error: error,
            atMs: _clock().millisecondsSinceEpoch,
          ),
        ),
      );
      if (notify) host.notifyMirrorFailure(error);
    } finally {
      release();
      await session?.close();
    }
  }

  /// 用户文件夹里的副本（还原点页）；没设文件夹返回 null。打不开时抛
  /// [BackupFolderUnavailableException]。
  Future<MirrorFolderListing?> listMirrorCopies() async {
    final AutoBackupMirrorFolder? folder = mirrorFolder();
    if (folder == null) return null;
    final BackupFolderSession session = await host.mirrorPlatform.open(folder);
    try {
      return await session.mirror.list();
    } finally {
      await session.close();
    }
  }

  /// 把文件夹副本 [copy] 取回本机还原点存储（之后补回 / 替换 / 导出照常）。持有导出锁；有备份在跑抛
  /// [AutoBackupBusyException]。
  Future<RestorePoint> copyMirrorCopyToDevice(MirroredRestorePoint copy) =>
      _withFolder<RestorePoint>(
        (BackupFolderMirror mirror) =>
            copyMirroredPointToStore(mirror, copy, defaultStore),
      );

  /// 删掉文件夹里的副本 [copy]（本机的点不动）。持有导出锁。
  Future<void> deleteMirrorCopy(MirroredRestorePoint copy) =>
      _withFolder<void>((BackupFolderMirror mirror) => mirror.delete(copy.id));

  Future<T> _withFolder<T>(
    Future<T> Function(BackupFolderMirror mirror) action,
  ) async {
    final AutoBackupMirrorFolder? folder = mirrorFolder();
    if (folder == null) {
      throw const BackupFolderUnavailableException('no folder set');
    }
    if (_running) throw const AutoBackupBusyException();
    final Object? lock = host.beginBackupExport();
    if (lock == null) throw const AutoBackupBusyException();
    _running = true;
    BackupFolderSession? session;
    try {
      session = await host.mirrorPlatform.open(folder);
      return await action(session.mirror);
    } finally {
      await session?.close();
      _running = false;
      host.endBackupExport(lock);
    }
  }

  Future<String> _fingerprint(
    AutoBackupSettings settings,
    RestorePointStore store,
  ) {
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
      if (settings.includeSrsMedia) host.srsMediaRoot,
    ];
    return computeAutoBackupFingerprint(
      files: files,
      directories: directories,
      // 存储根也进签名：换了文件夹，新文件夹里还没有这份数据。
      contentSignature:
          '${settings.contentSignature}|root=${p.normalize(store.root)}',
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
  /// `VACUUM INTO` + 复习库开着时的内核快照，写进默认还原点存储，每个 reason 留最新
  /// [kRestorePointKeepPreOperation] 份；[protectIds]（例如「替换」的目标点）这次修剪不删。
  /// 失败抛出，由调用方决定要不要继续。
  Future<RestorePoint> createPreOperationPoint(
    String reason, {
    bool includeMainDatabase = true,
    bool includeSrs = true,
    Set<String> protectIds = const <String>{},
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
      protectIds: protectIds,
    );
  }

  void dispose() {
    stop();
    _status.dispose();
  }
}
