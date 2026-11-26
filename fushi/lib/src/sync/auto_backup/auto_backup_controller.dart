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
import 'dart:isolate';

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

  /// 云端副本的目标（D8–D9）：已配置、在支持名单里（Google Drive / 互联 / Dropbox / WebDAV / FTP /
  /// SFTP）的同步后端，登录好之后返回。**没有支持的后端**返回 null（设置页另有提示）；配置了但登录失效 /
  /// 连不上时抛 [BackupMirrorException]（`cloud_auth` / `cloud_unreachable` …，原文不往外传）。不看
  /// [AutoBackupSettings.cloudCopies]。
  Future<AutoBackupMirrorTarget?> cloudTarget();

  /// 云端副本会用的同步服务名（设置页显示），不登录、不联网；没有支持的后端返回 null。
  Future<String?> cloudBackendLabel();

  /// 服务器副本的目标（第四期 D12）：同步用的互联服务器（已开的互联同步通道），连上之后返回。**没有设置
  /// 互联服务器**返回 null（设置页另有提示）；设置了但配对失效 / 连不上时抛 [BackupMirrorException]（错误码，
  /// 原文不往外传）。不看 [AutoBackupSettings.serverCopies]。
  Future<AutoBackupMirrorTarget?> serverTarget();

  /// 服务器副本会用的互联服务器名（设置页显示：配对记下的设备名，没有就是通用名），不联网；没有设置互联
  /// 服务器返回 null。
  Future<String?> serverLabel();

  /// 当前网络是不是不计流量（Wi-Fi / 以太网 / 桌面）；云端副本缺省只在这时上传（D10）。
  Future<bool> networkUnmetered();

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

  /// 定时还原点写好了，复制进用户文件夹 / 云端（[kind]）失败：提示用户一次（设置页另有常驻告警行）。
  void notifyMirrorFailure(AutoBackupMirrorKind kind, String reason);

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

/// 副本目标的种类：用户文件夹（移动端）/ 云端（已配置的云同步后端）/ 服务器（同步用的互联服务器，第四期
/// D12）。各有一份复制状态（[AutoBackupStatus.mirror] / [AutoBackupStatus.cloud] /
/// [AutoBackupStatus.server]），互不阻塞。
enum AutoBackupMirrorKind {
  folder,
  cloud,
  server;

  /// 经网络上传的目标：缺省只在不计流量的网络上传（D10），宿主解析目标时可能登录不上 / 连不上。
  bool get remote => this != AutoBackupMirrorKind.folder;
}

/// 一个副本目标：怎么打开、状态里用哪个键、按什么规则修剪。
class AutoBackupMirrorTarget {
  const AutoBackupMirrorTarget({
    required this.kind,
    required this.key,
    required this.label,
    required this.open,
    this.policy = kRestorePointScheduledRetention,
  });

  final AutoBackupMirrorKind kind;

  /// 状态文件里认目标用的短键（不含句柄 / 凭据：文件夹是句柄的 sha1 前缀，云端是后端类型 + 账号身份的
  /// 哈希，`cloudBackupTargetKey`）。
  final String key;

  /// 给用户看的名字（文件夹名 / 同步服务名）。
  final String label;

  /// 打开目标；用完 [BackupFolderSession.close]。不可用时抛 [BackupFolderUnavailableException] /
  /// [BackupMirrorException]。
  final Future<BackupFolderSession> Function() open;

  /// 这个目标里本机副本的保留规则（云端更少，D11）。
  final BackupRetentionPolicy policy;
}

/// 副本失败写进状态的错误码：已知原因给码（界面本地化），本机文件读写失败给原文（只有本机路径）。
String autoBackupMirrorErrorCode(Object error) => switch (error) {
  BackupFolderUnavailableException() => kAutoBackupErrorFolderUnavailable,
  NotEnoughSpaceException() => kNotEnoughSpaceError,
  BackupMirrorException(:final String code) => code,
  // 本机 / iOS 文件夹路径上的读写失败：原文带路径，不上界面。
  FileSystemException() => kBackupMirrorErrorFailed,
  _ => kBackupMirrorErrorFailed,
};

/// 自动备份控制器：AppModel 持有一个，设置页 / 还原点页 / 控制通道都经它。
class AutoBackupController {
  AutoBackupController({
    required this.host,
    DateTime Function()? clock,
    VolumeFreeBytes? freeBytes,
  }) : _clock = clock ?? DateTime.now,
       _freeBytes = freeBytes;

  final AutoBackupHost host;
  final DateTime Function() _clock;

  /// 测试缝：卷的可用空间（缺省 = 进程登记的探针，fushi_core [registerVolumeFreeBytes]）。
  final VolumeFreeBytes? _freeBytes;

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
      // 共用的自定义文件夹里只清本机标记的半截目录：这里还拿不到设备 id（异步），先只清私有存储；
      // 共用文件夹里本机的残留由下一次修剪（[RestorePointStore.pruneScheduled]）按标记清掉。
      final AutoBackupSettings settings = host.readSettings();
      if (settings.effectiveFolder(
            supportsCustomFolder: host.supportsCustomFolder,
          ) ==
          null) {
        scheduledStore(settings).cleanIncompleteScheduled();
      }
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

  /// 没到期时补复制：最新的定时还原点还不在某个副本目标里（复制被打断、刚选了 / 换了目标），且对这个目标
  /// 没有明确失败过（失败过的等下一个到期时段或「立即备份」，不每次回前台都重试、都提示）。不提示。
  Future<void> _catchUpMirror(AutoBackupSettings settings) async {
    final String? id = _status.value.lastSuccessPointId;
    if (id == null || _running || !host.databaseAvailable) return;
    final RestorePoint? point = RestorePoint.tryRead(
      p.join(scheduledStore(settings).root, id),
    );
    if (point == null) return;
    await _mirrorEverywhere(settings, point, notify: false, catchUp: true);
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
    // 写好的（或没变化时最新的）那份：放锁之后再复制到用户文件夹 / 云端 / 服务器（复制不拿导出锁）。
    RestorePoint? toMirror;
    final AutoBackupOutcome outcome;
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
        // 数据没变，但最新那份可能还没进某个副本目标（上次复制失败 / 换了目标）：这一期补上。
        final String? id = _status.value.lastSuccessPointId;
        if (id != null) toMirror = RestorePoint.tryRead(p.join(store.root, id));
        outcome = AutoBackupOutcome.skippedNoChanges;
      } else {
        final ({AutoBackupOutcome outcome, RestorePoint? point}) created =
            await _createScheduledPoint(
              settings,
              store,
              fingerprint: fingerprint,
              startedMs: startedMs,
            );
        toMirror = created.point;
        outcome = created.outcome;
      }
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
    if (toMirror != null) {
      await _mirrorEverywhere(settings, toMirror, notify: true, catchUp: false);
    }
    return outcome;
  }

  bool _lastSuccessPointExists(RestorePointStore store) {
    final String? id = _status.value.lastSuccessPointId;
    if (id == null) return false;
    return RestorePoint.tryRead(p.join(store.root, id)) != null;
  }

  Future<({AutoBackupOutcome outcome, RestorePoint? point})>
  _createScheduledPoint(
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
    // 写入设备：保留规则只修剪本机写的点（共用的自定义文件夹、取回本机的副本不动）。查不出来就不标，
    // 这份点在共用文件夹里就当作别人的、不会被自动删（安全的方向）。
    ({String id, String name})? device;
    try {
      device = await host.deviceIdentity();
    } on Object catch (e) {
      debugPrint('AutoBackup: device identity unavailable: $e');
    }
    final bool sharedRoot =
        settings.effectiveFolder(
          supportsCustomFolder: host.supportsCustomFolder,
        ) !=
        null;
    RestorePointDraft? draft;
    autoBackupProgress.value = const AutoBackupProgress();
    // 「开始」标记：写到一半进程没了，下次启动据此认出来（[recoverInterruptedRun]）。
    _writeStatus(_status.value.started(atMs: startedMs));
    try {
      // 写之前先看空间（第五期）：不够就记成失败 `not_enough_space`，不写半截、不把盘写满。
      await _ensureScheduledSpace(settings, store, files, unavailable);
      draft = store.begin(
        kind: RestorePointKind.scheduled,
        nowMs: startedMs,
        ownerDeviceId: device?.id,
      );
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
        deviceId: device?.id,
        deviceName: device?.name,
      );
      draft = null;
      store.pruneScheduled(
        deviceId: device?.id,
        sharedRoot: sharedRoot,
        protectId: point.id,
        now: _clock(),
      );
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
      return (outcome: AutoBackupOutcome.created, point: point);
    } catch (e, st) {
      debugPrint(
        'AutoBackup: scheduled backup failed: '
        '${e is NotEnoughSpaceException ? e.detail : e}\n$st',
      );
      if (draft != null) store.discard(draft);
      // 空间不够在腾出空间之前每次检查都会再失败：同一个原因只提示一次（状态行的告警常驻）。
      final bool repeatSpace =
          e is NotEnoughSpaceException &&
          _status.value.lastError == kNotEnoughSpaceError;
      _writeStatus(
        _status.value.failed(
          atMs: _clock().millisecondsSinceEpoch,
          error: '$e',
        ),
      );
      if (!repeatSpace) host.notifyFailure('$e');
      return (outcome: AutoBackupOutcome.failed, point: null);
    } finally {
      autoBackupProgress.value = null;
    }
  }

  /// 定时还原点要写多少的上界（在后台 isolate 里数）：主库与复习库（含 `-wal`）+ 勾选的文件树 + 复习媒体，
  /// 按不压缩算（zip 只会更小；媒体本来就压不动）。`BackupService.createBackup` 先把两个库 `VACUUM INTO`
  /// 系统临时目录再打包，所以临时目录所在的卷另要放下两个库。空间不够抛 [NotEnoughSpaceException]；
  /// 不知道可用空间就照常写。
  Future<void> _ensureScheduledSpace(
    AutoBackupSettings settings,
    RestorePointStore store,
    Set<BackupCategory> files,
    Set<BackupCategory> unavailable,
  ) async {
    final String dbDir = host.databaseDirectory;
    final List<String> dbFiles = <String>[
      p.join(dbDir, RestorePointDatabase.fushi.fileName),
      if (!unavailable.contains(BackupCategory.srs))
        p.join(dbDir, RestorePointDatabase.srs.fileName),
    ];
    final Map<BackupCategory, String> roots = host.contentTreeRoots;
    final List<String> trees = <String>[
      for (final BackupCategory c in files) ?roots[c],
      if (settings.includeSrsMedia) host.srsMediaRoot,
    ];
    final ({int databases, int files}) size = await Isolate.run(
      () => (
        databases: dbFiles.fold<int>(
          0,
          (int sum, String f) =>
              sum + fileBytesOrZero(f) + fileBytesOrZero('$f-wal'),
        ),
        files: trees.fold<int>(0, (int sum, String d) => sum + treeBytes(d)),
      ),
    );
    ensureFreeSpace(<SpaceNeed>[
      SpaceNeed(store.root, size.databases + size.files),
      SpaceNeed(Directory.systemTemp.path, size.databases),
    ], probe: _freeBytes);
  }

  // ── 副本：用户文件夹 / 云端（第三期） ──────────────────────────────────────────

  /// 这次要复制到的目标：用户文件夹（设了的话）+ 云端 / 服务器（各自开着且宿主给得出目标）。开着、也配置了，
  /// 却登录不上 / 连不上的远端目标记在 `errors` 里（错误码；不是静默地不复制：调用方记进那个目标的状态）。
  Future<
    ({
      List<AutoBackupMirrorTarget> targets,
      Map<AutoBackupMirrorKind, String> errors,
    })
  >
  _resolveTargets(AutoBackupSettings settings) async {
    final AutoBackupMirrorFolder? folder = mirrorFolder(settings);
    final List<AutoBackupMirrorTarget> targets = <AutoBackupMirrorTarget>[
      if (folder != null) _folderTarget(folder),
    ];
    final Map<AutoBackupMirrorKind, String> errors =
        <AutoBackupMirrorKind, String>{};
    for (final AutoBackupMirrorKind kind in <AutoBackupMirrorKind>[
      if (settings.cloudCopies) AutoBackupMirrorKind.cloud,
      if (settings.serverCopies) AutoBackupMirrorKind.server,
    ]) {
      try {
        final AutoBackupMirrorTarget? target = await _remoteTarget(kind);
        if (target != null) {
          targets.add(target);
        } else {
          // 开关开着、目标却不可能有（没有支持的同步后端 / 没设置互联服务器；比如云端早先也认互联，第四期
          // 起不认了）：不能静默地什么都不复制，记成这个目标的「没有服务」，设置页状态行说明原因。开关不替用户关。
          errors[kind] = _noServiceCode(kind);
        }
      } on BackupMirrorException catch (e) {
        errors[kind] = e.code;
      }
    }
    return (targets: targets, errors: errors);
  }

  /// [AutoBackupHost.cloudTarget] / [AutoBackupHost.serverTarget]，宿主漏掉没归类的错误也归成错误码：原文
  /// 可能带服务器地址 / 响应正文，只把类型名写进调试日志（不进状态、不进错误日志）。
  Future<AutoBackupMirrorTarget?> _remoteTarget(
    AutoBackupMirrorKind kind,
  ) async {
    try {
      return await switch (kind) {
        AutoBackupMirrorKind.folder => Future<AutoBackupMirrorTarget?>.value(),
        AutoBackupMirrorKind.cloud => host.cloudTarget(),
        AutoBackupMirrorKind.server => host.serverTarget(),
      };
    } on BackupMirrorException {
      rethrow;
    } on Object catch (e) {
      debugPrint(
        'AutoBackup: resolving the ${kind.name} target failed: '
        '${e.runtimeType}',
      );
      throw const BackupMirrorException(kBackupMirrorErrorCloudFailed);
    }
  }

  /// 远端副本开着、也配置了，却解析不出目标（[error]：登录失效 / 连不上）：记进那个目标的状态；定时 / 立即
  /// 备份那一次（[notify]）提示一次。没到期的补复制不提示，同一个错误已经记着就不重写状态文件。
  ///
  /// 「没有服务」（[_noServiceCode]）只提示一次：那是配置问题，不是这一次的故障，已经记着同一个原因就不再提示。
  void _recordUnavailable(
    AutoBackupMirrorKind kind,
    String error, {
    required bool notify,
  }) {
    final AutoBackupMirrorStatus current = mirrorStatusOf(kind);
    if (current.error == error && error == _noServiceCode(kind)) {
      notify = false;
    }
    if (!notify && current.error == error) return;
    _writeMirrorStatus(
      kind,
      current.unavailable(error: error, atMs: _clock().millisecondsSinceEpoch),
    );
    if (notify) host.notifyMirrorFailure(kind, error);
  }

  /// 远端目标开着却没有可用服务时的错误码。
  static String _noServiceCode(AutoBackupMirrorKind kind) =>
      kind == AutoBackupMirrorKind.server
      ? kBackupMirrorErrorServerNoServer
      : kBackupMirrorErrorCloudNoService;

  AutoBackupMirrorTarget _folderTarget(AutoBackupMirrorFolder folder) =>
      AutoBackupMirrorTarget(
        kind: AutoBackupMirrorKind.folder,
        key: folder.key,
        label: folder.label,
        open: () async {
          final BackupFolderSession session = await host.mirrorPlatform.open(
            folder,
          );
          // iOS 书签过期、系统在访问窗口里重建了一份：存回设置（列表 / 取回 / 删除也一样）。
          final AutoBackupMirrorFolder? refreshed = session.refreshedFolder;
          if (refreshed != null) {
            try {
              await host.saveMirrorFolder(refreshed);
            } on Object catch (e) {
              debugPrint(
                'AutoBackup: saving the refreshed bookmark failed: $e',
              );
            }
          }
          return session;
        },
      );

  /// 某个目标的复制状态。
  AutoBackupMirrorStatus mirrorStatusOf(AutoBackupMirrorKind kind) =>
      switch (kind) {
        AutoBackupMirrorKind.folder => _status.value.mirror,
        AutoBackupMirrorKind.cloud => _status.value.cloud,
        AutoBackupMirrorKind.server => _status.value.server,
      };

  void _writeMirrorStatus(
    AutoBackupMirrorKind kind,
    AutoBackupMirrorStatus next,
  ) => _writeStatus(switch (kind) {
    AutoBackupMirrorKind.folder => _status.value.withMirror(next),
    AutoBackupMirrorKind.cloud => _status.value.withCloud(next),
    AutoBackupMirrorKind.server => _status.value.withServer(next),
  });

  /// 正在复制 / 取回 / 删除副本的目标（每个目标同时只有一个操作；与导出锁无关：复制读的是已经写好、
  /// 不会再变的本机点）。
  final Set<AutoBackupMirrorKind> _mirroring = <AutoBackupMirrorKind>{};

  /// 有没有副本操作在跑（任何目标）。
  bool get mirroring => _mirroring.isNotEmpty;

  /// 把本机定时还原点 [point] 复制到每个目标。**不拿导出锁**：提供者 / 网络卡住时，还原、替换、手动导出
  /// 照常能用；本机那份在复制期间 [RestorePointStore.hold] 钉住（修剪删不到它）。[catchUp]：没到期时
  /// 的补复制，明确失败过的目标跳过。云端缺省只在不计流量的网络上传（D10），不满足就等下次检查。
  ///
  /// 每个目标在判定「没人在用」之后、第一个 await（查网络）之前就占住（[_mirroring]），复制完在 finally
  /// 里放开：两次补复制（回前台 + 桌面定时检查）不会同时往同一个目标写同一份。
  Future<void> _mirrorEverywhere(
    AutoBackupSettings settings,
    RestorePoint point, {
    required bool notify,
    required bool catchUp,
  }) async {
    final void Function() release = RestorePointStore.hold(point.directory);
    try {
      final ({
        List<AutoBackupMirrorTarget> targets,
        Map<AutoBackupMirrorKind, String> errors,
      })
      resolved = await _resolveTargets(settings);
      resolved.errors.forEach(
        (AutoBackupMirrorKind kind, String error) =>
            _recordUnavailable(kind, error, notify: notify),
      );
      for (final AutoBackupMirrorTarget target in resolved.targets) {
        final AutoBackupMirrorKind kind = target.kind;
        if (_mirroring.contains(kind)) continue;
        final AutoBackupMirrorStatus status = mirrorStatusOf(kind);
        if (status.holds(target.key, point.id)) continue;
        if (catchUp &&
            status.failedFor(target.key) &&
            status.pendingId == null) {
          continue;
        }
        _mirroring.add(kind);
        try {
          if (kind.remote &&
              !settings.cloudAllowMetered &&
              !await host.networkUnmetered()) {
            continue;
          }
          await _mirrorPoint(target, point, notify: notify);
        } finally {
          _mirroring.remove(kind);
        }
      }
    } finally {
      release();
    }
  }

  /// 把 [point] 复制进 [target]，再修剪那里本机写的旧副本。失败只记进这个目标的状态（[notify] 时提示一次），
  /// 从不抛出：本机那份已经写好了。调用方已经占住了这个目标（[_mirroring]）。
  ///
  /// - 先清这个目标里本机留下的半截副本（被打断的 [AutoBackupMirrorStatus.pendingId]、上次失败后删不掉的
  ///   [AutoBackupMirrorStatus.leftovers]）：只删列表里**确定没有元数据**的——完整的（被杀在修剪途中、
  ///   元数据已经写好的那份）不删，这次读不出元数据的（[MirrorFolderListing.unreadable]：读失败、iCloud
  ///   占位、云端这一步出错）也不删、留到下次再判；而且只在同一个目标里（换了目标的旧记录不碰）。
  /// - 上传途中失败：尽量删掉这份没写完的 `<id>/`（不然它没有元数据，列表、保留规则、还原点页都看不见它，
  ///   一直占着 SD 卡 / 云端空间）；删不掉就记进 leftovers，下次再清。
  /// - 修剪逐份尽力：删不掉的记进 [AutoBackupMirrorStatus.pruneError]，这一份照样算复制成功、不提示。
  Future<void> _mirrorPoint(
    AutoBackupMirrorTarget target,
    RestorePoint point, {
    required bool notify,
  }) async {
    final AutoBackupMirrorKind kind = target.kind;
    final Set<String> cleanup = <String>{
      ...mirrorStatusOf(kind).cleanupFor(target.key),
    }..remove(point.id);
    final Set<String> leftovers = <String>{...cleanup};
    _writeMirrorStatus(
      kind,
      mirrorStatusOf(kind).started(folderKey: target.key, id: point.id),
    );
    BackupFolderSession? session;
    BackupFolderMirror? mirror;
    bool uploading = false;
    try {
      session = await target.open();
      mirror = session.mirror;
      final ({String id, String name}) device = await host.deviceIdentity();
      final MirrorFolderListing listing = await mirror.list();
      // 只认本机写入位置上的完整副本：按设备分目录的目标里，别的设备碰巧同 id 的那份不算「本机这份已经
      // 完整 / 已经传过」（[MirroredRestorePoint.inOwnSlot]）。
      final Set<String> complete = <String>{
        for (final MirroredRestorePoint c in listing.points)
          if (c.inOwnSlot) c.id,
      };
      for (final String id in cleanup) {
        if (complete.contains(id)) {
          leftovers.remove(id);
          continue;
        }
        // 目录在、元数据这次没读出来：可能是完整的，留在 leftovers 里下次再判。
        if (listing.unreadable.contains(id)) continue;
        try {
          await mirror.delete(id);
          leftovers.remove(id);
        } on Object catch (e) {
          debugPrint(
            'AutoBackup: removing the half-written copy $id failed: $e',
          );
        }
      }
      final List<MirroredRestorePoint> copies = <MirroredRestorePoint>[
        ...listing.points,
      ];
      if (!complete.contains(point.id)) {
        final String meta = mirrorMetaText(
          point,
          deviceId: device.id,
          deviceName: device.name,
        );
        uploading = true;
        await mirror.upload(point, metaText: meta);
        uploading = false;
        // 刚复制的那份也参与保留：它占住自己的桶，同桶里更旧的本机副本才会被修剪。
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
        policy: target.policy,
      );
      final List<String> pruneFailures = <String>[];
      for (final MirroredRestorePoint copy in doomed) {
        try {
          // 按列出来的那一份删：保留规则只挑本机写的（元数据里的设备 id），删的就是那一份。
          await mirror.deleteCopy(copy);
        } on Object catch (e) {
          debugPrint('AutoBackup: pruning the copy ${copy.id} failed: $e');
          pruneFailures.add(copy.id);
        }
      }
      _writeMirrorStatus(
        kind,
        mirrorStatusOf(kind).succeeded(
          folderKey: target.key,
          id: point.id,
          atMs: _clock().millisecondsSinceEpoch,
          leftovers: leftovers.toList()..sort(),
          pruneError: pruneFailures.isEmpty ? null : pruneFailures.join(','),
        ),
      );
    } catch (e, st) {
      debugPrint(
        'AutoBackup: copying ${point.id} (${kind.name}) failed: $e\n$st',
      );
      if (uploading && mirror != null) {
        try {
          await mirror.delete(point.id);
        } on Object catch (cleanupError) {
          debugPrint(
            'AutoBackup: removing the failed copy ${point.id} failed: '
            '$cleanupError',
          );
          leftovers.add(point.id);
        }
      }
      final String error = autoBackupMirrorErrorCode(e);
      _writeMirrorStatus(
        kind,
        mirrorStatusOf(kind).failed(
          folderKey: target.key,
          error: error,
          atMs: _clock().millisecondsSinceEpoch,
          leftovers: leftovers.toList()..sort(),
        ),
      );
      if (notify) host.notifyMirrorFailure(kind, error);
    } finally {
      await _closeQuietly(session);
    }
  }

  /// 关掉副本目标（iOS 停止访问书签等）。关不掉只记调试日志：不让它盖掉操作本身的结果 / 错误，也不让
  /// 「正在用」的标记卡住。
  static Future<void> _closeQuietly(BackupFolderSession? session) async {
    try {
      await session?.close();
    } on Object catch (e) {
      debugPrint('AutoBackup: closing the copy target failed: $e');
    }
  }

  /// 用户文件夹里的副本（还原点页）；没设文件夹返回 null。打不开时抛
  /// [BackupFolderUnavailableException]。
  Future<MirrorFolderListing?> listMirrorCopies() async {
    final AutoBackupMirrorFolder? folder = mirrorFolder();
    if (folder == null) return null;
    return _listTarget(_folderTarget(folder));
  }

  /// 云端的副本（还原点页）；云端副本没开 / 没有支持的同步后端返回 null。登录不上 / 连不上时抛
  /// [BackupMirrorException]（错误码，不带后端原文）。
  Future<MirrorFolderListing?> listCloudCopies() async {
    if (!host.readSettings().cloudCopies) return null;
    final AutoBackupMirrorTarget? target = await _remoteTarget(
      AutoBackupMirrorKind.cloud,
    );
    if (target == null) return null;
    return _listTarget(target);
  }

  /// 服务器上的副本（还原点页，第四期）；服务器副本没开 / 没有设置互联服务器返回 null。配对失效 / 连不上时抛
  /// [BackupMirrorException]。
  Future<MirrorFolderListing?> listServerCopies() async {
    if (!host.readSettings().serverCopies) return null;
    final AutoBackupMirrorTarget? target = await _remoteTarget(
      AutoBackupMirrorKind.server,
    );
    if (target == null) return null;
    return _listTarget(target);
  }

  Future<MirrorFolderListing> _listTarget(AutoBackupMirrorTarget target) async {
    final BackupFolderSession session = await target.open();
    try {
      return await session.mirror.list();
    } finally {
      await _closeQuietly(session);
    }
  }

  /// 把副本 [copy]（来自 [kind] 那个目标）取回本机还原点存储（之后补回 / 替换 / 导出照常）。同一个目标上
  /// 已有操作在跑时抛 [AutoBackupBusyException]。不拿导出锁（卡住的提供者不该挡住还原 / 导出）：取回先
  /// 写进存储外的临时目录，整个改名进来，存储里看不到半截的点。
  Future<RestorePoint> copyMirrorCopyToDevice(
    MirroredRestorePoint copy, {
    AutoBackupMirrorKind kind = AutoBackupMirrorKind.folder,
  }) => _withTarget<RestorePoint>(
    kind,
    (BackupFolderMirror mirror) => copyMirroredPointToStore(
      mirror,
      copy,
      defaultStore,
      nowMs: _clock().millisecondsSinceEpoch,
    ),
  );

  /// 删掉 [kind] 那个目标里的副本 [copy]（本机的点不动）。
  Future<void> deleteMirrorCopy(
    MirroredRestorePoint copy, {
    AutoBackupMirrorKind kind = AutoBackupMirrorKind.folder,
  }) => _withTarget<void>(
    kind,
    (BackupFolderMirror mirror) => mirror.deleteCopy(copy),
  );

  Future<T> _withTarget<T>(
    AutoBackupMirrorKind kind,
    Future<T> Function(BackupFolderMirror mirror) action,
  ) async {
    final AutoBackupMirrorFolder? folder = mirrorFolder();
    final AutoBackupMirrorTarget? target = switch (kind) {
      AutoBackupMirrorKind.folder =>
        folder == null ? null : _folderTarget(folder),
      AutoBackupMirrorKind.cloud ||
      AutoBackupMirrorKind.server => await _remoteTarget(kind),
    };
    if (target == null) {
      throw switch (kind) {
        AutoBackupMirrorKind.folder => const BackupFolderUnavailableException(
          'no folder set',
        ),
        // 云端 / 服务器：没有支持的同步后端 / 没设置互联服务器。
        AutoBackupMirrorKind.cloud || AutoBackupMirrorKind.server =>
          BackupMirrorException(_noServiceCode(kind)),
      };
    }
    if (_mirroring.contains(kind)) throw const AutoBackupBusyException();
    _mirroring.add(kind);
    BackupFolderSession? session;
    try {
      session = await target.open();
      return await action(session.mirror);
    } finally {
      await _closeQuietly(session);
      _mirroring.remove(kind);
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
      freeBytes: _freeBytes,
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
