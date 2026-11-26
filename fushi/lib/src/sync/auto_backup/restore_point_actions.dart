/// 还原点页与控制通道共用的动作：补回缺少的内容、替换、导出、删除。
///
/// - **补回缺少的内容**：任意一份主库副本（原始库，或从定时备份 zip 里解出的主库）走覆盖前快照
///   同一套「只补缺」合并（[BackupRestoreService.mergeFromOverwriteSnapshot]），已有的行一律不动。
/// - **替换**：先拍一个操作前还原点（拍不成就不替换），再
///   - 原始库还原点：离线换文件（[RestorePointActionsHost.rollbackToRestorePoint]，当前库另存为回滚前
///     还原点）；
///   - 定时备份：走备份导入的覆盖路径（[RestorePointUiFlows.overwriteImportArchive]：覆盖、导入设置）。
///     定时备份是整库（[BackupMeta.fullDatabase]）：整库换回，包里带着的文件树换回，没带的文件树
///     与本机文件原样不动、对应的书库行照样留着；设备本地层（同步凭据、配对等）照导入规则保留。
///   两条都在全屏遮罩下关库（同步随关库停下），完成后重启。
///
/// 两个动作从查锁那一刻起占住 [RestorePointActionsHost.beginRestoreFlow]（自动备份这期间不开跑），并钉住目标
/// 还原点（[RestorePointStore.hold]），拍操作前还原点时的修剪删不掉它。有备份在导出时直接拒绝
/// （[RestorePointBusyException]），什么都不动。
///
/// 本文件不 import AppModel：app 能力走窄接口 [RestorePointActionsHost]（AppModel 实现），设置页的
/// 导入流程与重启由调用方经 [RestorePointUiFlows] 注入，所以它不进 import 大环
/// （`test/build/import_cycle_guard_test.dart`）。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_controller.dart'
    show AutoBackupController, kRestorePointReasonReplace;
import 'package:fushi/src/sync/auto_backup/restore_point_catalog.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_error_messages.dart'
    show friendlySyncErrorDetail;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 还原点动作要用的 app 能力（AppModel 实现）。
abstract interface class RestorePointActionsHost {
  /// 活库目录。
  Directory get databaseDirectory;

  /// 活库（预览「补回」时只读）。
  FushiDatabase get database;

  /// 有备份正在导出（手动 / 控制通道 / 自动备份）。
  bool get backupExportActive;

  /// 占住还原流程（自动备份这期间不开跑）；返回的回调放掉它。
  void Function() beginRestoreFlow();

  /// 全屏遮罩：开始 / 成功 / 失败。
  void beginBackupImport();
  void completeBackupImport(String message);
  void failBackupImport(String message);

  /// 关库（同步随之停下）。
  Future<void> closeDatabase();

  /// 离线换回原始库还原点（库已关）。
  Future<void> rollbackToRestorePoint(RestorePoint point);

  /// 自动备份控制器（拍操作前还原点）。
  AutoBackupController get autoBackup;
}

/// 还原点动作要走的两段 UI 流程，由调用方注入（它们属于设置页的导入流程）。
class RestorePointUiFlows {
  const RestorePointUiFlows({
    required this.restart,
    required this.overwriteImportArchive,
  });

  /// 换完 / 补完之后重启 app。
  final Future<void> Function() restart;

  /// 定时备份 zip 走备份导入的覆盖路径（覆盖、导入设置；自带遮罩、关库与重启）。
  final Future<void> Function(String zipPath) overwriteImportArchive;
}

/// 有备份正在导出（手动 / 控制通道 / 自动备份）时拒绝补回 / 替换：什么都没动。
class RestorePointBusyException implements Exception {
  const RestorePointBusyException();

  @override
  String toString() => t.restore_points_busy_backup;
}

/// 定时备份 zip 里的主库解出来暂放的位置（活库目录下；不命中快照白名单，用完即删）。
String _extractedMainDatabasePath(String dbDirectory) => p.join(
  dbDirectory,
  '${RestorePointDatabase.fushi.fileName}.restore-point-src',
);

/// [entry] 的主库副本路径：原始库直接用；定时备份先从 zip 里解出来。返回值与「用完要不要删」。
Future<({String path, bool temporary})> _mainDatabaseCopy(
  String dbDirectory,
  RestorePointEntry entry,
) async {
  final String? raw = entry.rawMainDatabasePath;
  if (raw != null) return (path: raw, temporary: false);
  final String? archive = entry.archivePath;
  if (archive == null) {
    throw StateError('restore point ${entry.id} holds no main database');
  }
  final String dest = _extractedMainDatabasePath(dbDirectory);
  try {
    await BackupRestoreService.extractBackupDatabase(
      zipPath: archive,
      destPath: dest,
    );
  } catch (_) {
    await _deleteQuietly(dest);
    rethrow;
  }
  return (path: dest, temporary: true);
}

Future<void> _deleteQuietly(String path) async {
  for (final String suffix in const <String>['', '-wal', '-shm']) {
    try {
      final File f = File('$path$suffix');
      if (f.existsSync()) await f.delete();
    } on FileSystemException {
      // 临时副本删不掉只占空间，下次解出时覆盖。
    }
  }
}

/// 查锁 + 占住还原流程 + 钉住目标点，三步之间没有 await（与自动备份的「查库可用 + 拿锁」互斥）。
/// 返回的回调把三样一起放掉。有备份在导出时抛 [RestorePointBusyException]。
void Function() _claimRestore(
  RestorePointActionsHost app,
  RestorePointEntry entry,
) {
  if (app.backupExportActive) throw const RestorePointBusyException();
  final void Function() endFlow = app.beginRestoreFlow();
  final void Function() release = RestorePointStore.hold(entry.path);
  return () {
    release();
    endFlow();
  };
}

/// 预览「补回缺少的内容」会补回什么（不改任何库）。
Future<OverwriteSnapshotPreview?> previewRestorePointFillIn(
  RestorePointActionsHost app,
  RestorePointEntry entry,
) async {
  final String dbDir = app.databaseDirectory.path;
  final ({String path, bool temporary}) copy = await _mainDatabaseCopy(
    dbDir,
    entry,
  );
  try {
    return await BackupRestoreService.previewOverwriteSnapshot(
      dbDirectory: dbDir,
      liveDb: app.database,
      snapshotPath: copy.path,
      createdAt: entry.createdAt,
    );
  } finally {
    if (copy.temporary) await _deleteQuietly(copy.path);
  }
}

/// 「补回缺少的内容」：只补缺合并进当前库，全屏遮罩下关库、完成后重启。
///
/// 关库之前的失败（有备份在导出、从 zip 解主库失败）原样抛给调用方，app 照常可用，由调用方
/// 提示；关库之后的失败画在遮罩上（库已关，无论成败都要重启）。
Future<void> fillInFromRestorePoint(
  RestorePointActionsHost app,
  RestorePointEntry entry,
  RestorePointUiFlows flows,
) async {
  final String dbDir = app.databaseDirectory.path;
  final void Function() release = _claimRestore(app, entry);
  ({String path, bool temporary})? copy;
  try {
    // 解 zip 不需要关库：先解，失败时 app 原样可用。
    copy = await _mainDatabaseCopy(dbDir, entry);
    try {
      app.beginBackupImport();
      await WidgetsBinding.instance.endOfFrame;
      await app.closeDatabase();
      await BackupRestoreService.mergeFromOverwriteSnapshot(
        dbDirectory: dbDir,
        snapshotPath: copy.path,
      );
      app.completeBackupImport(t.restore_points_fill_success);
      await Future<void>.delayed(const Duration(seconds: 1));
      await flows.restart();
    } catch (e, st) {
      ErrorLogService.instance.log('RestorePoints.fillIn', e, st);
      await ErrorLogService.instance.flush();
      app.failBackupImport(
        t.restore_points_fill_failed(reason: friendlySyncErrorDetail(e)),
      );
    }
  } finally {
    final ({String path, bool temporary})? used = copy;
    if (used != null && used.temporary) await _deleteQuietly(used.path);
    release();
  }
}

/// 一次「替换」的准备结果（[prepareRestorePointReplace]）：已查过锁、已占住还原流程、已钉住
/// 目标点、已拍好操作前还原点。交给 [runRestorePointReplace]；不用了要 [dispose]。
class RestorePointReplaceTicket {
  RestorePointReplaceTicket._(
    this.entry,
    this.preOperationPoint,
    this._release,
  );

  final RestorePointEntry entry;

  /// 替换之前拍下的当前数据。
  final RestorePoint preOperationPoint;
  final void Function() _release;

  /// 放掉占住的还原流程与钉住的目标点（可重复调）。
  void dispose() => _release();
}

/// 「替换」的第一步：查锁、占住还原流程、钉住目标点，再拍操作前还原点（目标点受保护，不会被
/// 这次修剪删掉）。拍不成 / 有备份在导出时抛出，什么都没动。
Future<RestorePointReplaceTicket> prepareRestorePointReplace(
  RestorePointActionsHost app,
  RestorePointEntry entry,
) async {
  if (!entry.canReplace) {
    throw StateError('restore point ${entry.id} cannot replace current data');
  }
  final void Function() release = _claimRestore(app, entry);
  try {
    final RestorePoint point = await app.autoBackup.createPreOperationPoint(
      kRestorePointReasonReplace,
      protectIds: <String>{entry.id},
    );
    return RestorePointReplaceTicket._(entry, point, release);
  } catch (_) {
    release();
    rethrow;
  }
}

/// 「替换」的第二步：按种类替换并重启（失败画在遮罩上）。结束时放掉 [ticket]。
Future<void> runRestorePointReplace(
  RestorePointActionsHost app,
  RestorePointReplaceTicket ticket,
  RestorePointUiFlows flows,
) async {
  final RestorePointEntry entry = ticket.entry;
  try {
    final String? archive = entry.archivePath;
    if (archive != null) {
      await flows.overwriteImportArchive(archive);
      return;
    }
    try {
      app.beginBackupImport();
      await WidgetsBinding.instance.endOfFrame;
      await app.closeDatabase();
      await app.rollbackToRestorePoint(entry.point!);
      app.completeBackupImport(t.restore_points_replace_success);
      await Future<void>.delayed(const Duration(seconds: 1));
      await flows.restart();
    } catch (e, st) {
      ErrorLogService.instance.log('RestorePoints.replace', e, st);
      await ErrorLogService.instance.flush();
      app.failBackupImport(
        t.restore_points_replace_failed(reason: friendlySyncErrorDetail(e)),
      );
    }
  } finally {
    ticket.dispose();
  }
}

/// 「替换」：[prepareRestorePointReplace]（失败直接抛出，什么都没动）+ [runRestorePointReplace]。
Future<void> replaceFromRestorePoint(
  RestorePointActionsHost app,
  RestorePointEntry entry,
  RestorePointUiFlows flows,
) async {
  final RestorePointReplaceTicket ticket = await prepareRestorePointReplace(
    app,
    entry,
  );
  await runRestorePointReplace(app, ticket, flows);
}

/// 导出时的文件名：`fushi-restore-point-<id>.<zip|db>`。
String restorePointExportFileName(RestorePointEntry entry) {
  final String? archive = entry.archivePath;
  final String base = 'fushi-restore-point-${entry.id}';
  if (archive != null) return '$base.zip';
  return '$base.db';
}

/// 导出要复制的那个文件（定时备份 = zip，其余 = 主库副本；只有复习库副本时是它）。
String? restorePointExportSource(RestorePointEntry entry) =>
    entry.archivePath ??
    entry.rawMainDatabasePath ??
    entry.point?.rawDatabasePath(RestorePointDatabase.srs);
