/// 还原点页与控制通道共用的动作：补回缺少的内容、替换、导出、删除。
///
/// - **补回缺少的内容**：任意一份主库副本（原始库，或从定时备份 zip 里解出的主库）走覆盖前快照
///   同一套「只补缺」合并（[BackupRestoreService.mergeFromOverwriteSnapshot]），已有的行一律不动。
/// - **替换**：先拍一个操作前还原点（拍不成就不替换），再
///   - 原始库还原点：离线换文件（[AppModel.rollbackToRestorePoint]，当前库另存为回滚前还原点）；
///   - 定时备份：走备份导入的覆盖路径（[runBackupImportFlowForFile] + 预设：覆盖、导入设置），
///     设备本地层（同步凭据、配对等）照导入规则保留。
///   两条都在全屏遮罩下关库（同步随关库停下），完成后重启。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_controller.dart'
    show kRestorePointReasonReplace;
import 'package:fushi/src/sync/auto_backup/restore_point_catalog.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_error_messages.dart'
    show friendlySyncErrorDetail;
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show
        BackupImportMode,
        BackupImportPreset,
        backupImportRestart,
        runBackupImportFlowForFile;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

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
  await BackupRestoreService.extractBackupDatabase(
    zipPath: archive,
    destPath: dest,
  );
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

/// 预览「补回缺少的内容」会补回什么（不改任何库）。
Future<OverwriteSnapshotPreview?> previewRestorePointFillIn(
  AppModel app,
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

/// 「补回缺少的内容」：只补缺合并进当前库，全屏遮罩下关库、完成后重启。失败画在遮罩上
/// （库已关，无论成败都要重启）。
Future<void> fillInFromRestorePoint(
  AppModel app,
  RestorePointEntry entry,
) async {
  final String dbDir = app.databaseDirectory.path;
  // 解 zip 不需要关库：先解，失败时 app 原样可用。
  final ({String path, bool temporary}) copy = await _mainDatabaseCopy(
    dbDir,
    entry,
  );
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
    await backupImportRestart(app);
  } catch (e, st) {
    ErrorLogService.instance.log('RestorePoints.fillIn', e, st);
    await ErrorLogService.instance.flush();
    app.failBackupImport(
      t.restore_points_fill_failed(reason: friendlySyncErrorDetail(e)),
    );
  } finally {
    if (copy.temporary) await _deleteQuietly(copy.path);
  }
}

/// 「替换」：先拍操作前还原点（失败直接抛出，什么都没动），再按种类替换并重启。
/// [preOperationPointTaken]：调用方已经拍过（控制通道要把拍点失败同步回终端）。
Future<void> replaceFromRestorePoint(
  AppModel app,
  RestorePointEntry entry, {
  bool preOperationPointTaken = false,
}) async {
  if (!entry.canReplace) {
    throw StateError('restore point ${entry.id} cannot replace current data');
  }
  if (app.backupExportActive) {
    throw StateError('a backup is being created');
  }
  if (!preOperationPointTaken) {
    await app.autoBackup.createPreOperationPoint(kRestorePointReasonReplace);
  }
  final String? archive = entry.archivePath;
  if (archive != null) {
    await runBackupImportFlowForFile(
      appModel: app,
      filePath: archive,
      preset: const BackupImportPreset(
        mode: BackupImportMode.overwrite,
        importSettings: true,
      ),
    );
    return;
  }
  try {
    app.beginBackupImport();
    await WidgetsBinding.instance.endOfFrame;
    await app.closeDatabase();
    await app.rollbackToRestorePoint(entry.point!);
    app.completeBackupImport(t.restore_points_replace_success);
    await Future<void>.delayed(const Duration(seconds: 1));
    await backupImportRestart(app);
  } catch (e, st) {
    ErrorLogService.instance.log('RestorePoints.replace', e, st);
    await ErrorLogService.instance.flush();
    app.failBackupImport(
      t.restore_points_replace_failed(reason: friendlySyncErrorDetail(e)),
    );
  }
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
