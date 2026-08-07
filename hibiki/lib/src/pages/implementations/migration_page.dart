import 'dart:io';

import 'package:external_path/external_path.dart';
import 'package:flutter/material.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/migration/migration_exporter.dart';
import 'package:fushi/src/migration/migration_readonly.dart';
import 'package:fushi/src/migration/migration_target_channel.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/utils.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

/// 「迁移到 Fushi」页（改名迁移计划 P1-3）。
///
/// 三态引导（依据 Fushi 是否已安装）：未装 → 下载；已装 → 开始迁移；
/// 全部批次导出完成 → 打开 Fushi + 本应用进入只读态（P1-4 标志位落
/// [kMigrationReadonlyPrefKey]，注销 PROCESS_TEXT 系统入口；重传通道保留——
/// 本页随时可「重新导出」）。
///
/// 仅 Android 挂入口（跨包名迁移只存在于 Android；桌面端数据可直接搬）。
class MigrationPage extends StatefulWidget {
  const MigrationPage({super.key, required this.appModel});

  final AppModel appModel;

  @override
  State<MigrationPage> createState() => _MigrationPageState();
}

/// Fushi 发布页（下载引导用；与更新检查同仓）。
const String kFushiReleasesUrl =
    'https://github.com/hajisensai/hibiki/releases';

enum _TargetState { checking, missing, installed }

class _MigrationPageState extends State<MigrationPage> {
  static const MigrationTargetChannel _channel = MigrationTargetChannel();

  _TargetState _target = _TargetState.checking;
  bool _running = false;
  bool _includeLocalAudio = false;
  bool _allDone = false;
  String? _error;

  /// 已完成批次名 → 显示为勾。
  final Set<String> _doneBatches = <String>{};
  String? _currentBatch;

  @override
  void initState() {
    super.initState();
    _refreshTarget();
    _allDone =
        widget.appModel.prefsRepo.getPref(kMigrationReadonlyPrefKey) == true;
  }

  Future<void> _refreshTarget() async {
    final bool installed = await _channel.isFushiInstalled();
    if (!mounted) return;
    setState(() {
      _target = installed ? _TargetState.installed : _TargetState.missing;
    });
  }

  String _batchLabel(MigrationBatch batch) => switch (batch) {
        MigrationBatch.core => t.migration_batch_core_label,
        MigrationBatch.dictionaries => t.backup_category_dictionary,
        MigrationBatch.books => t.backup_category_books,
        MigrationBatch.audiobooks => t.backup_category_audiobooks,
        MigrationBatch.fonts => t.backup_category_fonts,
        MigrationBatch.localAudio => t.backup_category_local_audio,
      };

  Future<Directory> _transferDir() async {
    final String documents =
        await ExternalPath.getExternalStoragePublicDirectory(
            ExternalPath.DIRECTORY_DOCUMENTS);
    // 计划 P1-1 定值：不在 /Android/data 下，卸载老版不会被系统清掉。
    return Directory(p.join(documents, 'Hibiki', 'migration'));
  }

  Future<void> _run({required bool fresh}) async {
    if (_running) return;
    setState(() {
      _running = true;
      _error = null;
      if (fresh) {
        _doneBatches.clear();
        _allDone = false;
      }
    });
    final AppModel appModel = widget.appModel;
    try {
      final Directory transferDir = await _transferDir();
      if (fresh && transferDir.existsSync()) {
        transferDir.deleteSync(recursive: true);
      }
      final BackupService service = BackupService(
        db: appModel.database,
        dbDirectory: appModel.databaseDirectory.path,
        dictionaryResourceDirectory: appModel.dictionaryResourceDirectory.path,
        appVersion: appModel.packageInfo.version,
        booksRootDirectory: p.join(appModel.appDirectory.path, 'hoshi_books'),
        audiobooksRootDirectory:
            p.join(appModel.appDirectory.path, 'audiobooks'),
        fontsRootDirectory: p.join(appModel.appDirectory.path, 'custom_fonts'),
      );
      final MigrationExporter exporter = MigrationExporter(
        backupService: service,
        transferDir: transferDir,
        sourcePackage: kHibikiPackageName,
        sourceAppVersion: appModel.packageInfo.version,
        nowMs: () => DateTime.now().millisecondsSinceEpoch,
      );
      final MigrationPlan plan =
          exporter.planBatches(includeLocalAudio: _includeLocalAudio);
      for (final MigrationBatch batch in plan.batches) {
        if (!mounted) return;
        setState(() => _currentBatch = batch.name);
        await exporter.exportBatch(batch);
        if (!mounted) return;
        setState(() => _doneBatches.add(batch.name));
      }
      // 全批完成：置只读标志（每次启动生效）+ 注销系统取词入口（P1-4）。
      await appModel.prefsRepo.setPref(kMigrationReadonlyPrefKey, true);
      await _channel.setProcessTextEnabled(false);
      if (!mounted) return;
      setState(() => _allDone = true);
      // 前台拉起 Fushi 开始导入（用户点按钮触发的流程末端，属前台启动）。
      await _channel.launchFushi();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _currentBatch = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<MigrationBatch> batches = <MigrationBatch>[
      MigrationBatch.core,
      MigrationBatch.dictionaries,
      MigrationBatch.books,
      MigrationBatch.audiobooks,
      MigrationBatch.fonts,
      if (_includeLocalAudio) MigrationBatch.localAudio,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(t.migration_settings_entry)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(t.migration_intro),
          const SizedBox(height: 16),
          if (_allDone)
            HibikiCard(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(t.migration_readonly_note),
              ),
            ),
          if (_target == _TargetState.missing) ...<Widget>[
            Text(t.migration_target_missing),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => launchUrl(Uri.parse(kFushiReleasesUrl),
                  mode: LaunchMode.externalApplication),
              child: Text(t.migration_download_fushi),
            ),
            TextButton(
              onPressed: _refreshTarget,
              child: Text(t.retry),
            ),
          ],
          if (_target == _TargetState.installed) ...<Widget>[
            AdaptiveSettingsSwitchRow(
              title: t.migration_include_local_audio,
              value: _includeLocalAudio,
              onChanged: _running
                  ? null
                  : (bool v) => setState(() => _includeLocalAudio = v),
            ),
            const SizedBox(height: 8),
            for (final MigrationBatch batch in batches)
              HibikiListItem(
                density: HibikiListDensity.compact,
                leading: _doneBatches.contains(batch.name)
                    ? const Icon(Icons.check_circle_outline)
                    : (_currentBatch == batch.name
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.radio_button_unchecked)),
                title: Text(_batchLabel(batch)),
              ),
            const SizedBox(height: 8),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  t.migration_export_failed(error: _error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_allDone) ...<Widget>[
              Text(t.migration_export_done),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _running ? null : () => _channel.launchFushi(),
                child: Text(t.migration_open_fushi),
              ),
              TextButton(
                onPressed: _running ? null : () => _run(fresh: true),
                child: Text(t.migration_reexport),
              ),
            ] else
              FilledButton(
                onPressed: _running ? null : () => _run(fresh: false),
                child: _running
                    ? Text(
                        t.migration_batch_running(batch: _currentBatch ?? ''))
                    : Text(t.migration_start),
              ),
          ],
        ],
      ),
    );
  }
}
