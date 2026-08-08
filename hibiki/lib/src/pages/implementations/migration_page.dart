import 'dart:io';

import 'package:external_path/external_path.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/migration/migration_exporter.dart';
import 'package:hibiki/src/migration/migration_readonly.dart';
import 'package:hibiki/src/migration/migration_space.dart';
import 'package:hibiki/src/migration/migration_target_channel.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/utils.dart';
import 'package:path/path.dart' as p;

/// 「迁移到 Fushi」页（改名迁移计划 P1-3）。
///
/// **一键迁移**：用户只按一个按钮，页面依次完成
/// 空间闸门 → 下载并安装 Fushi → 导出全部批次 → 拉起 Fushi 导入。
/// 中途任一步失败都停在原地并说明原因，绝不假装成功、绝不让用户自己去找安装包。
///
/// 仅 Android 挂入口（跨包名迁移只存在于 Android；桌面端数据可直接搬）。
class MigrationPage extends StatefulWidget {
  const MigrationPage({super.key, required this.appModel});

  final AppModel appModel;

  @override
  State<MigrationPage> createState() => _MigrationPageState();
}

/// 迁移流程当前停在哪一步（决定按钮文案与进度显示）。
enum _Step {
  /// 查 Fushi 是否已装。
  checking,

  /// 空闲，等用户按「迁移」。
  idle,

  /// 正在实测各批体积 + 查可用空间。
  measuring,

  /// 空间闸门未过——**硬拦**，不允许开始（用户已定：不给「仍要继续」）。
  blocked,

  /// 正在下载并安装 Fushi。
  installing,

  /// 正在导出批次。
  exporting,

  /// 全部批次已导出。
  done,
}

class _MigrationPageState extends State<MigrationPage>
    with WidgetsBindingObserver {
  static const MigrationTargetChannel _channel = MigrationTargetChannel();

  _Step _step = _Step.checking;
  bool _fushiInstalled = false;
  bool _includeLocalAudio = false;
  String? _error;

  MigrationSpaceEstimate? _estimate;
  MigrationSpaceVerdict? _verdict;

  /// 已完成批次名 → 显示为勾。
  final Set<String> _doneBatches = <String>{};
  String? _currentBatch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.appModel.prefsRepo.getPref(kMigrationReadonlyPrefKey) == true) {
      _step = _Step.done;
    }
    _refreshTarget();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 系统安装器是独立 Activity：用户装完 Fushi 回到本页时，必须**重新探测包**再
    // 判断是否已装，不能因为「我们发起过安装」就乐观标记成功（用户可能点了取消，
    // 或安装被系统拒绝）。计划 P2-3 的同一条纪律。
    if (state == AppLifecycleState.resumed && _step != _Step.done) {
      _refreshTarget();
    }
  }

  Future<void> _refreshTarget() async {
    final bool installed = await _channel.isFushiInstalled();
    if (!mounted) return;
    setState(() {
      _fushiInstalled = installed;
      if (_step == _Step.checking) _step = _Step.idle;
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

  MigrationContentRoots _contentRoots() {
    final AppModel appModel = widget.appModel;
    return MigrationContentRoots(
      databaseFilePath: p.join(appModel.databaseDirectory.path, 'hibiki.db'),
      databaseDirectoryPath: appModel.databaseDirectory.path,
      dictionaryResourceDirectoryPath:
          appModel.dictionaryResourceDirectory.path,
      booksRootDirectoryPath: p.join(appModel.appDirectory.path, 'hoshi_books'),
      audiobooksRootDirectoryPath:
          p.join(appModel.appDirectory.path, 'audiobooks'),
      fontsRootDirectoryPath:
          p.join(appModel.appDirectory.path, 'custom_fonts'),
    );
  }

  List<MigrationBatch> get _plannedBatches => <MigrationBatch>[
        MigrationBatch.core,
        MigrationBatch.dictionaries,
        MigrationBatch.books,
        MigrationBatch.audiobooks,
        MigrationBatch.fonts,
        if (_includeLocalAudio) MigrationBatch.localAudio,
      ];

  UpdateChannel get _channelForFushi {
    if (widget.appModel.updateDebugChannel) return UpdateChannel.debug;
    if (widget.appModel.updateBetaChannel) return UpdateChannel.beta;
    return UpdateChannel.stable;
  }

  bool get _busy =>
      _step == _Step.measuring ||
      _step == _Step.installing ||
      _step == _Step.exporting;

  // ── 一键迁移 ───────────────────────────────────────────────────────────

  /// 用户诉求：「点击就下载并且迁移」。这里是那一个点击的全部。
  Future<void> _migrateNow({bool fresh = false}) async {
    if (_busy) return;
    setState(() {
      _error = null;
      if (fresh) {
        _doneBatches.clear();
      }
    });

    // 1) 空间闸门。**必须在删中转目录之前**——旧实现开头就 deleteSync，空间不够
    //    的结局是「导到一半炸 + 旧中转目录已被删」，用户两头落空。
    final Directory transferDir = await _transferDir();
    if (!await _passesSpaceGate(transferDir)) return;

    // 2) 没装 Fushi 就替用户下载安装。装完系统会把用户送回本页，
    //    didChangeAppLifecycleState 重新探测包状态；这里再确认一次。
    if (!_fushiInstalled) {
      if (!await _downloadAndInstallFushi()) return;
      await _refreshTarget();
      if (!mounted) return;
      if (!_fushiInstalled) {
        setState(() {
          _step = _Step.idle;
          _error = t.migration_install_incomplete;
        });
        return;
      }
    }

    // 3) 导出。
    await _export(transferDir: transferDir, fresh: fresh);
  }

  /// 实测 + 裁决。返回 false 表示已拦下（[_step] 置 [_Step.blocked]）。
  Future<bool> _passesSpaceGate(Directory transferDir) async {
    setState(() => _step = _Step.measuring);
    try {
      // StatFs 要求路径真实存在。建空目录是幂等且无损的——**不清内容**，
      // 清理只发生在闸门通过之后。
      transferDir.createSync(recursive: true);

      final MigrationSpaceEstimate estimate =
          await measureBatchBytesInBackground(
        _contentRoots(),
        // 本地发音库即使本轮不导，也要测出体积，好在拦下时告诉用户
        // 「关掉它能省多少」。
        <MigrationBatch>{..._plannedBatches, MigrationBatch.localAudio}
            .toList(growable: false),
      );
      final int? freeBytes = await _channel.getFreeSpace(transferDir.path);
      final MigrationSpaceVerdict verdict = MigrationSpaceVerdict.decide(
        estimatedBytes: estimate.totalBytesFor(_plannedBatches),
        freeBytes: freeBytes,
        // 已装 Fushi 就不必再为 APK 留空间。
        includeApkReserve: !_fushiInstalled,
      );
      if (!mounted) return false;
      setState(() {
        _estimate = estimate;
        _verdict = verdict;
        _step = verdict.sufficient ? _Step.idle : _Step.blocked;
      });
      return verdict.sufficient;
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _step = _Step.idle;
        _error = e.toString();
      });
      return false;
    }
  }

  /// 下载并安装 Fushi。返回 false 表示没走到安装那一步（已置 [_error]）。
  Future<bool> _downloadAndInstallFushi() async {
    setState(() => _step = _Step.installing);
    final MigrationTargetAsset? target =
        await resolveMigrationTargetAsset(channel: _channelForFushi);
    if (!mounted) return false;
    if (target == null) {
      setState(() {
        _step = _Step.idle;
        _error = t.migration_target_resolve_failed;
      });
      return false;
    }
    // 复用自更新的下载浮层：多镜像回退、断点续传、取消、安装权限回跳全部照旧。
    await downloadAndInstallMigrationTarget(context, target);
    return mounted;
  }

  Future<void> _export({
    required Directory transferDir,
    required bool fresh,
  }) async {
    setState(() => _step = _Step.exporting);
    final AppModel appModel = widget.appModel;
    try {
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
      setState(() {
        _step = _Step.done;
        _currentBatch = null;
      });
      // 前台拉起 Fushi 开始导入（用户点按钮触发的流程末端，属前台启动）。
      await _channel.launchFushi();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.idle;
        _currentBatch = null;
        _error = t.migration_export_failed(error: e.toString());
      });
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────

  String get _primaryLabel => switch (_step) {
        _Step.measuring => t.migration_space_measuring,
        _Step.installing => t.migration_step_install,
        _Step.exporting =>
          t.migration_batch_running(batch: _currentBatch ?? ''),
        _ => _fushiInstalled ? t.migration_start : t.migration_prompt_action,
      };

  Widget _spaceCard(BuildContext context) {
    final MigrationSpaceVerdict verdict = _verdict!;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int localAudioBytes =
        _estimate?.perBatchBytes[MigrationBatch.localAudio] ?? 0;
    return HibikiCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              verdict.measurable
                  ? t.migration_space_blocked(
                      shortfall: formatMigrationBytes(verdict.shortfallBytes))
                  : t.migration_space_unknown,
              style: TextStyle(color: scheme.error),
            ),
            if (verdict.measurable) ...<Widget>[
              const SizedBox(height: 8),
              Text(t.migration_space_summary(
                required: formatMigrationBytes(verdict.requiredBytes),
                free: formatMigrationBytes(verdict.freeBytes),
              )),
            ],
            if (_includeLocalAudio && localAudioBytes > 0) ...<Widget>[
              const SizedBox(height: 8),
              Text(t.migration_space_tip_local_audio(
                size: formatMigrationBytes(localAudioBytes),
              )),
            ],
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : () => _migrateNow(),
              child: Text(t.migration_space_recheck),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool done = _step == _Step.done;
    return Scaffold(
      appBar: AppBar(title: Text(t.migration_settings_entry)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(t.migration_intro),
          const SizedBox(height: 16),
          if (done)
            HibikiCard(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(t.migration_readonly_note),
              ),
            ),
          if (_step == _Step.checking)
            const Center(child: CircularProgressIndicator())
          else ...<Widget>[
            AdaptiveSettingsSwitchRow(
              title: t.migration_include_local_audio,
              value: _includeLocalAudio,
              onChanged: _busy
                  ? null
                  : (bool v) => setState(() {
                        _includeLocalAudio = v;
                        // 勾选面变了，旧裁决作废——绝不拿上一次的结论放行。
                        _verdict = null;
                        if (_step == _Step.blocked) _step = _Step.idle;
                      }),
            ),
            const SizedBox(height: 8),
            for (final MigrationBatch batch in _plannedBatches)
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
                subtitle: _estimate?.perBatchBytes[batch] == null
                    ? null
                    : Text(
                        formatMigrationBytes(_estimate!.perBatchBytes[batch]!)),
              ),
            const SizedBox(height: 8),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_step == _Step.blocked && _verdict != null)
              _spaceCard(context)
            else if (done) ...<Widget>[
              Text(t.migration_export_done),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busy ? null : () => _channel.launchFushi(),
                child: Text(t.migration_open_fushi),
              ),
              TextButton(
                onPressed: _busy ? null : () => _migrateNow(fresh: true),
                child: Text(t.migration_reexport),
              ),
            ] else
              FilledButton(
                onPressed: _busy ? null : () => _migrateNow(),
                child: Text(_primaryLabel),
              ),
          ],
        ],
      ),
    );
  }
}
