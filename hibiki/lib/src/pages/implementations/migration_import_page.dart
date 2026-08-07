import 'dart:io';

import 'package:external_path/external_path.dart';
import 'package:flutter/material.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/migration/migration_exporter.dart';
import 'package:fushi/src/migration/migration_importer.dart';
import 'package:fushi/src/migration/migration_readonly.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show backupImportRestart;
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart' show fushiDatabaseFileName;
import 'package:path/path.dart' as p;

/// 「从 Hibiki 导入」页（改名迁移计划 P2-2/P2-3，Fushi 侧）。
///
/// 扫描老包写下的中转目录 → 逐批校验（清单 sha256+size）→ 走
/// [BackupService.mergeRestoreBackup] 逐批合并（关库一次、批间不重启）→
/// 行数聚合校验 → 删除已导入批文件 → 重启。**任一批校验不符：保留文件、
/// 提示回老包重传、绝不进入卸载流程**。
///
/// 卸载引导（P2-3）在导入完成重启后的 dashboard banner 上：ACTION_DELETE 弹
/// 系统确认框，之后重新 getPackageInfo 复查——用户可能点了「取消」。
class MigrationImportPage extends StatefulWidget {
  const MigrationImportPage({super.key, required this.appModel});

  final AppModel appModel;

  @override
  State<MigrationImportPage> createState() => _MigrationImportPageState();
}

/// Fushi 侧「迁移导入已完成」标志（触发卸载引导 banner；与老包的只读标志
/// [kMigrationReadonlyPrefKey] 相互独立）。
const String kMigrationImportDonePrefKey = 'migration_import_done_v1';

/// 老包中转目录（`<共享 Documents>/Hibiki/migration`；与导出侧同一约定）。
Future<Directory> migrationTransferDir() async {
  final String documents = await ExternalPath.getExternalStoragePublicDirectory(
      ExternalPath.DIRECTORY_DOCUMENTS);
  return Directory(p.join(documents, 'Hibiki', 'migration'));
}

class _MigrationImportPageState extends State<MigrationImportPage> {
  static const MigrationImporter _importer = MigrationImporter();

  MigrationScanResult? _scan;
  bool _running = false;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rescan();
  }

  Future<void> _rescan() async {
    final Directory dir = await migrationTransferDir();
    final MigrationScanResult r = await _importer.scan(dir);
    if (!mounted) return;
    setState(() => _scan = r);
  }

  String _batchLabel(MigrationBatch batch) => switch (batch) {
        MigrationBatch.core => t.migration_batch_core_label,
        MigrationBatch.dictionaries => t.backup_category_dictionary,
        MigrationBatch.books => t.backup_category_books,
        MigrationBatch.audiobooks => t.backup_category_audiobooks,
        MigrationBatch.fonts => t.backup_category_fonts,
        MigrationBatch.localAudio => t.backup_category_local_audio,
      };

  Future<void> _runImport() async {
    if (_running) return;
    final MigrationScanResult? scan = _scan;
    if (scan == null || scan.ready.isEmpty) return;
    setState(() {
      _running = true;
      _error = null;
    });
    final AppModel appModel = widget.appModel;
    final Directory transferDir = await migrationTransferDir();
    try {
      // 与备份导入同一遮罩协议：上遮罩 → 等首帧 → 关库 → 逐批合并 → 重启。
      appModel.beginBackupImport();
      await WidgetsBinding.instance.endOfFrame;
      await appModel.closeDatabase();
      final String booksRoot =
          p.join(appModel.appDirectory.path, 'hoshi_books');
      final String audiobooksRoot =
          p.join(appModel.appDirectory.path, 'audiobooks');
      final String fontsRoot =
          p.join(appModel.appDirectory.path, 'custom_fonts');
      final String videosRoot = p.join(appModel.appDirectory.path, 'videos');
      for (final MigrationImportBatch batch in scan.ready) {
        setState(() => _status =
            t.migration_import_running(batch: _batchLabel(batch.batch)));
        await BackupService.mergeRestoreBackup(
          dbDirectory: appModel.databaseDirectory.path,
          zipPath: batch.archivePath,
          dictionaryResourceDirectory:
              appModel.dictionaryResourceDirectory.path,
          booksRootDirectory: booksRoot,
          audiobooksRootDirectory: audiobooksRoot,
          fontsRootDirectory: fontsRoot,
          videosRootDirectory: videosRoot,
          onProgress: appModel.reportBackupImportProgress,
        );
      }
      // 合并后聚合校验：逐表行数不得低于各批清单最大值。
      final Map<String, int> expected =
          MigrationImporter.aggregateExpectedCounts(scan.ready);
      // 合并导入落到的是活库（mergeRestoreBackup 内部开库时 fushi_core 已把
      // legacy hibiki.db 改名），所以行数校验必须查新文件名。
      final String dbPath =
          p.join(appModel.databaseDirectory.path, fushiDatabaseFileName);
      final List<String> countProblems = MigrationImporter.verifyImportedCounts(
          dbPath: dbPath, expected: expected);
      if (countProblems.isNotEmpty) {
        // 行数不足：不删中转文件、不置完成标志（绝不进卸载流程），重启后可重试。
        appModel.failBackupImport(
            t.migration_import_counts_failed(detail: countProblems.join('; ')));
        await Future<void>.delayed(const Duration(seconds: 2));
        await backupImportRestart(appModel);
        return;
      }
      // 校验通过：删已导入批文件；问题批保留（重传通道）。
      for (final MigrationImportBatch batch in scan.ready) {
        _importer.deleteBatchFiles(transferDir, batch.batch);
      }
      _importer.cleanupTransferDirIfEmpty(transferDir);
      // 完成标志（重启后 dashboard 出卸载引导）；同时清掉随迁移带来的老包
      // 只读标志（包名门已挡，这里是 belt+suspenders）。
      await appModel.prefsRepo.setPref(kMigrationImportDonePrefKey, true);
      await appModel.prefsRepo.setPref(kMigrationReadonlyPrefKey, false);
      appModel.completeBackupImport(t.migration_import_success);
      await Future<void>.delayed(const Duration(seconds: 1));
      await backupImportRestart(appModel);
    } catch (e) {
      appModel.failBackupImport(
          t.migration_import_verify_failed(batch: '', detail: '$e'));
      await Future<void>.delayed(const Duration(seconds: 2));
      await backupImportRestart(appModel);
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _status = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final MigrationScanResult? scan = _scan;
    return Scaffold(
      appBar: AppBar(title: Text(t.migration_import_entry)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(t.migration_import_entry_subtitle),
          const SizedBox(height: 16),
          if (scan == null)
            const Center(child: CircularProgressIndicator())
          else if (!scan.hasAnything)
            Text(t.migration_import_nothing)
          else ...<Widget>[
            for (final MigrationImportBatch batch in scan.ready)
              FushiListItem(
                density: FushiListDensity.compact,
                leading: const Icon(Icons.inventory_2_outlined),
                title: Text(_batchLabel(batch.batch)),
              ),
            for (final MapEntry<String, List<String>> e
                in scan.problems.entries)
              FushiListItem(
                density: FushiListDensity.compact,
                leading: Icon(Icons.error_outline,
                    color: Theme.of(context).colorScheme.error),
                title: Text(t.migration_import_verify_failed(
                    batch: e.key, detail: e.value.join('; '))),
                titleMaxLines: 3,
              ),
            const SizedBox(height: 8),
            if (_error != null)
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (_status != null) Text(_status!),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _running || scan.ready.isEmpty ? null : _runImport,
              child: Text(t.migration_import_start),
            ),
            TextButton(
              onPressed: _running ? null : _rescan,
              child: Text(t.retry),
            ),
          ],
        ],
      ),
    );
  }
}
