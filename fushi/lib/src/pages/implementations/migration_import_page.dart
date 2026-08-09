import 'dart:async';
import 'dart:io';

import 'package:external_path/external_path.dart';
import 'package:flutter/material.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/migration/migration_exporter.dart';
import 'package:fushi/src/migration/migration_importer.dart';
import 'package:fushi/src/migration/migration_readonly.dart';
import 'package:fushi/src/migration/migration_target_channel.dart';
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

class _MigrationImportPageState extends State<MigrationImportPage>
    with WidgetsBindingObserver {
  static const MigrationImporter _importer = MigrationImporter();
  static const MigrationTargetChannel _channel = MigrationTargetChannel();

  MigrationScanResult? _scan;
  bool _running = false;
  String? _status;
  String? _error;

  /// 扫描进度（校验哪一批 / 已完成几批）。11GB 库的全量 SHA-256 要好几分钟，
  /// 这段时间必须让用户看得见在动，否则和卡死没有区别。
  String? _scanningLabel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_rescan());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统授权页回来时自动重扫：这个权限只能跳设置页手动开，没有回调，
    // 不在 resume 复查的话用户开完权限回来还是那句「没权限」。
    if (state == AppLifecycleState.resumed &&
        !_running &&
        _scan?.storagePermissionGranted == false) {
      unawaited(_rescan());
    }
  }

  Future<void> _rescan() async {
    final Directory dir = await migrationTransferDir();
    final bool granted = await _channel.hasAllFilesAccess();
    if (!mounted) return;
    setState(() {
      _scan = null;
      _scanningLabel = granted ? '' : null;
    });
    final MigrationScanResult r = await _importer.scan(
      dir,
      permissionGranted: granted,
      onProgress: (MigrationBatch batch, int done, int total) {
        if (!mounted) return;
        setState(() => _scanningLabel = t.migration_import_verifying(
              batch: _batchLabel(batch),
              done: done + 1,
              total: total,
            ));
      },
    );
    if (!mounted) return;
    setState(() {
      _scan = r;
      _scanningLabel = null;
    });
    // 校验不过是终止性结果，必须打断——只在列表里堆几行，用户等了几分钟
    // 校验之后看到的是一屏静默的红字，很容易以为还在跑。
    if (r.problems.isNotEmpty) await _showProblemsDialog(r);
  }

  /// 逐批问题的弹窗。列表仍留在页面上供反复查看。
  Future<void> _showProblemsDialog(MigrationScanResult scan) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.migration_import_entry),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final MapEntry<String, List<String>> e
                  in scan.problems.entries) ...<Widget>[
                Text(t.migration_import_verify_failed(
                    batch: e.key, detail: e.value.join('; '))),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.dialog_close),
          ),
        ],
      ),
    );
  }

  /// 跳系统授权页。回来后由 [didChangeAppLifecycleState] 复查并重扫。
  Future<void> _requestPermission() async {
    await _channel.requestAllFilesAccess();
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
          p.join(appModel.appDirectory.path, 'fushi_books');
      final String audiobooksRoot =
          p.join(appModel.appDirectory.path, 'audiobooks');
      final String fontsRoot =
          p.join(appModel.appDirectory.path, 'custom_fonts');
      final String videosRoot = p.join(appModel.appDirectory.path, 'videos');
      for (final MigrationImportBatch batch in scan.ready) {
        // **不能裸调 setState**：beginBackupImport() 上的是全屏遮罩，本页已被
        // 移出 widget 树（State 进入 defunct）。循环第一句就会抛
        // 「called after dispose」→ 落进下面的 catch → 2 秒后
        // System.exit 重启，于是 mergeRestoreBackup 一次都没被调用过——用户看到
        // 的是「校验全过、导入却瞬间失败、中转文件原封不动、库还是空的」。
        // 进度归遮罩管（reportBackupImportProgress 已在下面传给它）；本页的
        // _status 只在页面还活着时有意义。
        if (mounted) {
          setState(() => _status =
              t.migration_import_running(batch: _batchLabel(batch.batch)));
        }
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
          // 同机换包名：用户期望「一切原样搬过来」，而 merge 默认只搬内容、
          // 不搬设置（那是给「另一台设备的备份」用的语义）。不开这个开关，
          // 迁移完成后阅读器/视频/Anki/快捷键/界面/互联/同步后端全是默认值。
          adoptSourcePreferences: true,
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
        // 同上：重启会带走屏幕上的说明，先落日志。
        debugPrint(
            '[Fushi][migration] count verification failed: ${countProblems.join("; ")}');
        ErrorLogService.instance.log('MigrationImportPage.verifyCounts',
            StateError(countProblems.join('; ')), StackTrace.current);
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
    } catch (e, st) {
      // **必须落日志**：这条 detail 此前只塞进 UI 文案，而失败路径 2 秒后就
      // System.exit 重启，于是唯一有诊断价值的信息随进程一起消失——release 抓
      // 不到，debug 也抓不到（压根没有日志语句）。实测三次复现都拿不到原因。
      ErrorLogService.instance.log('MigrationImportPage.runImport', e, st);
      debugPrint('[Fushi][migration] import failed: $e\n$st');
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
            Column(
              children: <Widget>[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 12),
                // 只给转圈＝用户无法把「正在校验」和「卡死」区分开。
                Text(_scanningLabel ?? t.migration_import_verifying_hint,
                    textAlign: TextAlign.center),
                if (_scanningLabel != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    t.migration_import_verifying_hint,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            )
          else if (!scan.storagePermissionGranted)
            // 根因面：没权限时该请求权限，不是报「清单损坏」再让用户自己去翻设置。
            FushiCard(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      t.migration_import_permission_title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(t.migration_import_permission_body),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _requestPermission,
                      child: Text(t.migration_import_permission_grant),
                    ),
                  ],
                ),
              ),
            )
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
