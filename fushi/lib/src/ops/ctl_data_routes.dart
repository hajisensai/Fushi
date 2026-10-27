import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show Dictionary;
import 'package:fushi_core/fushi_core.dart'
    show
        EpubBookRow,
        FushiPairedPeerRow,
        kLegacySchemaBridgeAppVersion,
        kLegacySchemaBridgeReleaseUrl,
        kMinSupportedSchemaVersion,
        VideoBookRow,
        VideoDownloadJobRow;
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart'
    show VideoBookRepository;
import 'package:fushi_engine/sync/downloads/host_download_host.dart'
    show videoDownloadJobToWire;
import 'package:fushi_engine/sync/interconnect_device_name.dart'
    show resolveInterconnectDeviceName;
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';
import 'package:fushi_engine/sync/sync_backend_type.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/discovery/direct_link_download.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/video_download_jobs_panel.dart'
    show videoDownloadJobCanResume, videoDownloadJobCanSetPriority;
import 'package:fushi/src/ops/ctl_data_wire.dart';
import 'package:fushi/src/ops/ctl_download_subscription_routes.dart';
import 'package:fushi/src/ops/ctl_download_support.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart'
    show HostDownloadJob;
import 'package:fushi/src/sync/interconnect_link_pairing.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart'
    show withoutInterconnectHost;
import 'package:fushi/src/sync/manual_sync_ui.dart'
    show runManualSyncWithFeedback;
import 'package:fushi/src/sync/sync_conflict_decider.dart'
    show SyncConflictPolicy, SyncConflictPolicyDecider;
import 'package:fushi/src/sync/sync_auto_trigger.dart'
    show
        ManualSyncOutcome,
        SyncAssetChannelScope,
        SyncChannel,
        enabledSyncChannelBackends,
        lastFullSweepOutcome,
        syncAssetChannelScopeOf,
        syncInProgress;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show
        // 设置页导出的默认分类集是唯一真相源，CLI 复用而不抄一份。
        // ignore: invalid_use_of_visible_for_testing_member
        defaultBackupExportCategories,
        BackupImportMode,
        BackupImportPreset,
        DataRootMigrationPlan,
        DataRootMigrationPrecheckFailure,
        DataRootMigrationRunOutcome,
        interconnectPairFailureMessage,
        planDataRootMigration,
        runBackupImportFlowForFile,
        runDataRootMigration,
        runInterconnectLinkPairingFlow;

/// data 域控制通道路由（CLI 侧命令见 `packages/fushi_cli/lib/src/commands/data_commands.dart`）。
///
/// 每条路由只做「门控 + 参数解析 + 调 app 既有入口 + 白名单出参」，业务都在
/// 原服务里：备份 [BackupService] / [BackupRestoreService]、同步
/// [runManualSyncWithFeedback]、下载 [AppModel.appDownloadHost] 与下载管线 / 直链队列
/// [AppModel.discoveryDownloadQueue]、媒体
/// 服务器 [MediaServerConfig.buildBrowser]、互联 [FushiSyncServerController]、存储
/// [StorageUsageService]。
List<CtlRoute> buildDataCtlRoutes(OpContext context) {
  final _CtlDataTasks tasks = _CtlDataTasks();
  return <CtlRoute>[
    ..._backupRoutes(context, tasks),
    ..._syncRoutes(context),
    ..._downloadRoutes(context),
    ...buildDownloadSubscriptionCtlRoutes(context),
    ..._mediaServerRoutes(context),
    ..._peerRoutes(context),
    ..._storageRoutes(context, tasks),
  ];
}

/// 控制通道发起、在后台跑的长任务的最近一次结局（`backup status` /
/// `storage migrate-status` 读）。进度本身在 [AppModel] 上（与 app 内遮罩 / 进度条同一
/// 真相源），这里只补「终端发起的那一次最后怎样了」——任务结束后 app 侧状态会被清掉。
class _CtlDataTasks {
  Map<String, Object?>? lastBackup;
  Map<String, Object?>? lastMigration;
}

/// 破坏性动作在 app 侧的第二道门：body / query 必须带 `confirm: true`。
void _requireConfirm(CtlCall call, String what) {
  if (call.optBool('confirm') != true) {
    throw CtlFailure.badRequest('$what 需要确认（confirm: true）');
  }
}

/// 需要界面（确认框 / 提示）的动作：主窗口带到前台，返回全局 navigator 的 context。
Future<BuildContext> _uiContext(OpContext context) async {
  await context.focusMainWindow();
  final BuildContext? ui = context.navigator?.context;
  if (ui == null || !ui.mounted) {
    throw const CtlFailure.conflict('主界面还没就绪，稍后再试');
  }
  return ui;
}

/// 不能 await 的界面流程（等用户点确认）：在后台跑，异常只进日志，不让它变成
/// 未捕获错误。
void _runDetached(String label, Future<Object?> Function() body) {
  unawaited(
    Future<Object?>.sync(body).catchError((Object error, StackTrace stack) {
      debugPrint('ctl[$label] failed: $error\n$stack');
      return null;
    }),
  );
}

// ── 备份 ─────────────────────────────────────────────────────────────

/// 与设置页「导出备份」同一份构造（`backup.part.dart` 的 `_export`）：数据根下的
/// 书 / 有声书 / 字体 / 游戏封面树一起打包。
BackupService _backupServiceFor(AppModel appModel) => BackupService(
  db: appModel.database,
  dbDirectory: appModel.databaseDirectory.path,
  dictionaryResourceDirectory: appModel.dictionaryResourceDirectory.path,
  appVersion: appModel.packageInfo.version,
  booksRootDirectory: p.join(appModel.appDirectory.path, 'fushi_books'),
  audiobooksRootDirectory: p.join(appModel.appDirectory.path, 'audiobooks'),
  fontsRootDirectory: p.join(appModel.appDirectory.path, 'custom_fonts'),
  gameCoversRootDirectory: p.join(appModel.appDirectory.path, 'game_covers'),
  srsStorage: appModel.srsStorageForBackup,
);

Future<Map<String, Object?>> _backupFileToWire(File file) async {
  final BackupMeta? meta = await BackupRestoreService.validateBackup(file.path);
  return <String, Object?>{
    'path': file.path,
    'name': p.basename(file.path),
    'bytes': await file.length(),
    'valid': meta != null,
    if (meta != null) ...backupMetaToWire(meta),
  };
}

List<CtlRoute> _backupRoutes(
  OpContext context,
  _CtlDataTasks tasks,
) => <CtlRoute>[
  // 列出某目录下的备份包（文件名口径 = isBackupArchiveName，与存储页 / 导出前
  // 清扫同一判据），逐个读包内 meta。
  CtlRoute.get('/api/admin/backups', (CtlCall call) async {
    final String dir = call.requireString('dir');
    if (!p.isAbsolute(dir)) {
      throw CtlFailure.badRequest('dir 必须是绝对路径：$dir');
    }
    final Directory directory = Directory(dir);
    if (!await directory.exists()) throw CtlFailure.notFound('目录不存在：$dir');
    final List<File> files = <File>[
      await for (final FileSystemEntity e in directory.list(followLinks: false))
        if (e is File && isBackupArchiveName(p.basename(e.path))) e,
    ]..sort((File a, File b) => a.path.compareTo(b.path));
    return <String, Object?>{
      'dir': dir,
      'backups': <Map<String, Object?>>[
        for (final File file in files) await _backupFileToWire(file),
      ],
    };
  }),
  CtlRoute.get('/api/admin/backups/info', (CtlCall call) async {
    final String path = call.requireString('path');
    if (!await File(path).exists()) throw CtlFailure.notFound('文件不存在：$path');
    final BackupMeta? meta = await BackupRestoreService.validateBackup(path);
    if (meta == null) throw const CtlFailure.rejected('不是有效的 Fushi 备份包');
    final BackupContentSummary summary =
        await BackupRestoreService.summarizeBackupFile(path);
    return <String, Object?>{
      'path': path,
      'bytes': await File(path).length(),
      ...backupMetaToWire(meta),
      'newerThanApp':
          meta.schemaVersion > context.appModel.database.schemaVersion,
      'counts': backupSummaryToWire(summary),
    };
  }),
  // 创建备份：与设置页导出同一个 [BackupService.createBackup]，区别只在落点——
  // 设置页先打到临时目录再弹「另存为」，CLI 已经给了路径，直接写过去。
  // `books` / `videos` = 设置页导出框里「只备份选中的书 / 视频」（bookKeys /
  // videoKeys）；`wait: false` 时后台打包，进度与结局用 `backup status` 查。
  CtlRoute.post('/api/admin/backups', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    if (appModel.backupExportActive) {
      throw const CtlFailure.conflict('已有一个备份导出在进行中');
    }
    final BackupService service = _backupServiceFor(appModel);
    final String output = call.requireString('output');
    final String outputPath = resolveBackupOutputPath(
      output,
      isDirectory: await Directory(output).exists(),
      defaultFilename: service.defaultFilename(),
    );
    if (await File(outputPath).exists()) {
      throw CtlFailure.conflict('文件已存在，不覆盖：$outputPath');
    }
    if (!await Directory(p.dirname(outputPath)).exists()) {
      throw CtlFailure.notFound('目录不存在：${p.dirname(outputPath)}');
    }
    final bool all = call.optBool('all') ?? false;
    final Set<BackupCategory>? explicit = parseBackupCategories(
      call.stringList('categories'),
    );
    Set<BackupCategory>? categories = all
        ? null
        // ignore: invalid_use_of_visible_for_testing_member
        : (explicit ?? defaultBackupExportCategories());
    final Set<String> bookKeys = call.stringList('books').toSet();
    final Set<String> videoKeys = call.stringList('videos').toSet();
    if (bookKeys.isNotEmpty &&
        categories != null &&
        !categories.contains(BackupCategory.books)) {
      throw const CtlFailure.badRequest('--book 要和 books 分类一起用');
    }
    if (videoKeys.isNotEmpty &&
        categories != null &&
        !categories.contains(BackupCategory.videos)) {
      // 视频文件不在默认分类里（太大）；点名了视频就是要带上它们。
      if (explicit != null) {
        throw const CtlFailure.badRequest('--video 要和 videos 分类一起用');
      }
      categories = <BackupCategory>{...categories, BackupCategory.videos};
    }
    for (final String key in bookKeys) {
      final EpubBookRow? row = await appModel.database.getEpubBook(key);
      if (row == null) throw CtlFailure.notFound('没有这本书：$key');
    }
    final VideoBookRepository videos = VideoBookRepository(appModel.database);
    for (final String key in videoKeys) {
      final VideoBookRow? row = await videos.getByBookUid(key);
      if (row == null) throw CtlFailure.notFound('没有这个视频：$key');
    }
    final Set<BackupCategory>? finalCategories = categories;
    final bool wait = call.optBool('wait') ?? true;
    appModel.beginBackupExport();
    Future<Map<String, Object?>> export() async {
      List<String> skippedDictionaries = const <String>[];
      final BackupMeta meta;
      try {
        meta = await service.createBackup(
          outputPath,
          categories: finalCategories,
          bookKeys: bookKeys.isEmpty ? null : bookKeys,
          videoKeys: videoKeys.isEmpty ? null : videoKeys,
          onProgress: appModel.reportBackupExportProgress,
          onDictionariesSkipped: (List<String> names) =>
              skippedDictionaries = names,
        );
      } catch (_) {
        // 半截 zip 不留给用户当成备份。
        try {
          await File(outputPath).delete();
        } catch (_) {}
        rethrow;
      } finally {
        appModel.endBackupExport();
      }
      return <String, Object?>{
        'path': outputPath,
        'bytes': await File(outputPath).length(),
        'categories': finalCategories == null
            ? <String>[
                for (final BackupCategory c in BackupCategory.values) c.name,
              ]
            : <String>[for (final BackupCategory c in finalCategories) c.name],
        if (bookKeys.isNotEmpty) 'books': bookKeys.toList(),
        if (videoKeys.isNotEmpty) 'videos': videoKeys.toList(),
        'skippedDictionaries': skippedDictionaries,
        ...backupMetaToWire(meta),
      };
    }

    if (wait) return export();
    tasks.lastBackup = <String, Object?>{
      'state': 'running',
      'path': outputPath,
      'startedAt': DateTime.now().millisecondsSinceEpoch,
    };
    _runDetached('backup.create', () async {
      try {
        tasks.lastBackup = <String, Object?>{
          'state': 'completed',
          ...await export(),
        };
      } catch (e) {
        tasks.lastBackup = <String, Object?>{
          'state': 'failed',
          'path': outputPath,
          'error': redactCtlSecrets('$e'),
        };
        rethrow;
      }
      return null;
    });
    return <String, Object?>{
      'ok': true,
      'started': true,
      'path': outputPath,
      'message': '已开始打包备份（backup status 查看进度）',
    };
  }),
  // 备份导出进度（与设置页导出共用 AppModel 上的同一个进度源）+ 终端最近一次后台导出的结局。
  CtlRoute.get('/api/admin/backups/status', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    return <String, Object?>{
      'active': appModel.backupExportActive,
      'progress': ?appModel.backupExportProgress.value,
      'last': ?tasks.lastBackup,
    };
  }),
  // 恢复备份：交给 app 既有的导入编排 [runBackupImportFlowForFile]（校验 → 确认框
  // 选覆盖 / 合并与分类 → 关库导入 → 自动重启）。
  //
  // 没给模式：照旧在 app 里弹确认框，由用户选。给了 mode（CLI `--merge` /
  // `--replace`）：以 [BackupImportPreset] 跳过确认框——此时的最终确认就是 CLI 的
  // `--yes` + 这里的 `confirm: true`（与 `dl rm` 等破坏性命令同一套双门），校验 /
  // 版本检查 / 遮罩 / 重启一步不少。预设时版本检查在这里先做一遍，失败直接回
  // 终端，而不是只在 app 里弹一条终端看不到的提示。
  CtlRoute.post('/api/admin/backups/restore', (CtlCall call) async {
    _requireConfirm(call, '恢复备份');
    final String path = call.requireString('path');
    final BackupImportPreset? preset = parseBackupImportPreset(
      mode: call.optString('mode'),
      categories: call.stringList('categories'),
      importSettings: call.optBool('importSettings') ?? false,
    );
    if (!await File(path).exists()) throw CtlFailure.notFound('文件不存在：$path');
    final AppModel appModel = context.appModel;
    if (appModel.backupExportActive) {
      throw const CtlFailure.conflict('备份导出进行中，先等它结束');
    }
    if (preset != null) {
      final BackupMeta? meta = await BackupRestoreService.validateBackup(path);
      if (meta == null) throw const CtlFailure.rejected('不是有效的 Fushi 备份包');
      if (meta.schemaVersion > appModel.database.schemaVersion) {
        throw CtlFailure.rejected(
          '备份来自更新版本的 Fushi（schema ${meta.schemaVersion}），先升级 app',
        );
      }
      if (meta.schemaVersion > 0 &&
          meta.schemaVersion < kMinSupportedSchemaVersion) {
        throw CtlFailure.rejected(
          '备份来自旧版 Hibiki 或早期版本（schema ${meta.schemaVersion}），本版本'
          '已无法直接导入；先装 Fushi v$kLegacySchemaBridgeAppVersion 导入一次再'
          '更新（$kLegacySchemaBridgeReleaseUrl）',
        );
      }
    }
    await _uiContext(context);
    _runDetached(
      'backup.restore',
      () => runBackupImportFlowForFile(
        appModel: appModel,
        filePath: path,
        preset: preset,
      ),
    );
    if (preset == null) {
      return <String, Object?>{
        'ok': true,
        'path': path,
        'message': '已在 Fushi 里打开恢复流程，请在确认框里选择覆盖或合并；完成后 app 会自动重启',
      };
    }
    final bool merge = preset.mode == BackupImportMode.merge;
    return <String, Object?>{
      'ok': true,
      'path': path,
      'mode': merge ? 'merge' : 'replace',
      'message': '已开始${merge ? '合并' : '覆盖'}恢复（进度在 Fushi 里显示），完成后 app 会自动重启',
    };
  }),
];

// ── 云同步 ───────────────────────────────────────────────────────────

List<CtlRoute> _syncRoutes(OpContext context) => <CtlRoute>[
  CtlRoute.get('/api/admin/sync', (CtlCall call) async {
    final SyncRepository repo = SyncRepository(context.appModel.database);
    final SyncBackendType selected = await repo.getBackendType();
    return <String, Object?>{
      // 两条通道各有自动同步开关（反馈 5nWEirdCs2）：autoSync = 云通道，
      // interconnectAutoSync = 互联通道。
      'autoSync': await repo.isAutoSyncEnabled(),
      'interconnectAutoSync': await repo.isInterconnectAutoSyncEnabled(),
      'interconnectEnabled': await repo.isInterconnectEnabled(),
      'running': syncInProgress.value,
      'lastFullSweep': syncOutcomeToWire(lastFullSweepOutcome.value),
      // 「立即同步」会跑的通道（与同步编排同一份枚举），`sync run <通道>` 认这些名。
      'channels': (await enabledSyncChannelBackends(
        repo,
      )).map(syncChannelToWire).toList(),
      'backends': <Map<String, Object?>>[
        for (final SyncBackendType type in SyncBackendType.values)
          syncBackendToWire(
            type: type,
            selected: type == selected,
            configured: await repo.hasStoredBackendConfig(type),
          ),
      ],
    };
  }),
  // 与设置页「立即同步」同一入口：缺省云通道 + 互联通道一起跑；`channels` 只跑
  // 指定的通道（[runManualFullSync] 的 onlyChannels）。鉴权失效的提示在 app 里出现。
  // 同步中途的冲突：缺省照旧在 app 里弹窗让用户选；带 `conflicts` 策略（keep-local /
  // keep-remote / newest / ask）时不弹窗，由 [SyncConflictPolicyDecider] 按策略落地，
  // `ask` 什么都不选、把冲突清单返回（并隐含 wait）。
  CtlRoute.post('/api/admin/sync/run', (CtlCall call) async {
    final Set<SyncAssetChannelScope>? only = parseSyncChannelScopes(
      call.stringList('channels'),
    );
    final String? policyRaw = call.optString('conflicts');
    final SyncConflictPolicy? policy = policyRaw == null
        ? null
        : SyncConflictPolicy.tryParse(policyRaw) ??
              (throw CtlFailure.badRequest(
                'conflicts 只能是 ${SyncConflictPolicy.values.map((SyncConflictPolicy p) => p.wire).join(' / ')}：$policyRaw',
              ));
    final SyncConflictPolicyDecider? decider = policy == null
        ? null
        : SyncConflictPolicyDecider(
            policy,
            tempDir: context.appModel.temporaryDirectory,
          );
    if (syncInProgress.value) {
      throw const CtlFailure.conflict('已有同步在进行中');
    }
    final AppModel appModel = context.appModel;
    if (only != null) {
      // 指定了没启用的通道：说清楚，而不是让它静默以「没配置」收场。
      final Set<SyncAssetChannelScope> enabled = <SyncAssetChannelScope>{
        for (final SyncChannel channel in await enabledSyncChannelBackends(
          SyncRepository(appModel.database),
        ))
          syncAssetChannelScopeOf(channel),
      };
      final List<String> missing = <String>[
        for (final SyncAssetChannelScope s in only)
          if (!enabled.contains(s)) s.name,
      ];
      if (missing.isNotEmpty) {
        throw CtlFailure.rejected(
          '这些通道没有启用：${missing.join(', ')}（sync ls 查看可用通道）',
        );
      }
    }
    final BuildContext ui = await _uiContext(context);
    if (!ui.mounted) throw const CtlFailure.conflict('主界面还没就绪，稍后再试');
    final Future<ManualSyncOutcome> run = runManualSyncWithFeedback(
      context: ui,
      appModel: appModel,
      onlyChannels: only,
      conflictDecider: decider,
    );
    if (call.optBool('wait') != true && policy != SyncConflictPolicy.ask) {
      _runDetached('sync.run', () => run);
      return <String, Object?>{
        'ok': true,
        'started': true,
        if (policy != null) 'conflictPolicy': policy.wire,
      };
    }
    final ManualSyncOutcome outcome = await run;
    final bool unresolved = decider?.unresolved.isNotEmpty ?? false;
    return <String, Object?>{
      'ok': outcome == ManualSyncOutcome.completed && !unresolved,
      'outcome': outcome.name,
      'lastFullSweep': syncOutcomeToWire(lastFullSweepOutcome.value),
      if (decider != null) 'conflicts': decider.toJson(),
    };
  }),
];

// ── 下载 ─────────────────────────────────────────────────────────────

void _requireDownloads(AppModel appModel) => requireCtlDownloadCenter(appModel);

Future<VideoDownloadJobRow> _requireJob(AppModel appModel, String id) async {
  final VideoDownloadJobRow? job = await appModel.database.getVideoDownloadJob(
    id,
  );
  if (job == null) throw CtlFailure.notFound('没有这个下载任务：$id');
  return job;
}

/// 下载中心的直链队列（与下载页「直链下载」分区同一个实例，`AppModel` 懒建、
/// app 生命周期常驻）。库还没开时没有队列可看。
DiscoveryDownloadQueue? _directQueue(AppModel appModel) =>
    appModel.isDatabaseReady ? appModel.discoveryDownloadQueue : null;

DiscoveryDownloadTask _requireDirectTask(AppModel appModel, int taskId) {
  for (final DiscoveryDownloadTask task
      in _directQueue(appModel)?.tasks ?? const <DiscoveryDownloadTask>[]) {
    if (task.taskId == taskId) return task;
  }
  throw CtlFailure.notFound('没有这个直链任务：$kCtlDirectDownloadIdPrefix$taskId');
}

VideoDownloadPipelineService _requirePipeline(AppModel appModel) =>
    appModel.videoDownloadPipelineService ??
    (throw const CtlFailure.rejected('本机下载后端没有配好（浏览 › 下载 里配置）'));

/// 管线拒绝 → 对应状态码；其余异常照常上抛（500）。
Future<T> _mapPipelineErrors<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on VideoDownloadAlreadyQueued catch (e) {
    throw CtlFailure.conflict(e.message);
  } on VideoDownloadPipelineActionRequired catch (e) {
    throw CtlFailure.rejected(e.message);
  } on ArgumentError catch (e) {
    throw CtlFailure.badRequest('${e.message}');
  }
}

/// 远端代下载协议只有列表 / 取消 / 重试 / 删除（与下载页「远端任务」卡一致），
/// 继续 / 优先级 / 详情只对本机任务成立。
void _rejectRemoteOnlyLocal(CtlCall call) {
  final String? device = call.optString('device');
  if (device != null && device != 'local') {
    throw const CtlFailure.badRequest(
      '互联 host 上的任务只支持 ls / get / cancel / retry / rm（远端协议没有这项操作）',
    );
  }
}

List<CtlRoute> _downloadRoutes(OpContext context) => <CtlRoute>[
  // 与无头服务端 `admin_api.dart` 的 GET /api/admin/downloads 同形：能力位 + 任务表。
  // `device` = 互联 host：列它的代下载任务（与下载页「远端任务」段同一个
  // [InterconnectDownloadClient.listJobs]）。
  CtlRoute.get('/api/admin/downloads', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    _requireDownloads(appModel);
    final CtlDownloadDeviceRemote? remote = await resolveCtlRemoteJobDevice(
      appModel,
      call.optString('device'),
    );
    if (remote != null) {
      final List<HostDownloadJob> jobs = await mapCtlHostErrors(
        remote.target,
        () => remote.client.listJobs(remote.target),
      );
      return <String, Object?>{
        'device': remote.target.label,
        'remote': true,
        'backend': remote.target.backend,
        'jobs': <Map<String, Object?>>[
          for (final HostDownloadJob job in jobs)
            hostDownloadJobToWire(job, device: remote.target.label),
        ],
      };
    }
    return <String, Object?>{
      ...await appModel.appDownloadHost.capability(),
      'jobs': <Map<String, Object?>>[
        ...(await appModel.appDownloadHost.listJobs()).map(
          videoDownloadJobToWire,
        ),
        // 直链队列（下载页「直链下载」分区）的任务并进同一张表，id 带 `direct:` 前缀。
        ...?_directQueue(appModel)?.tasks.map(directDownloadTaskToWire),
      ],
    };
  }),
  CtlRoute.get('/api/admin/downloads/:id', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    _requireDownloads(appModel);
    final String id = call.params['id']!;
    final CtlDownloadDeviceRemote? remote = await resolveCtlRemoteJobDevice(
      appModel,
      call.optString('device'),
    );
    if (remote != null) {
      return hostDownloadJobToWire(
        await requireCtlHostJob(remote, id),
        device: remote.target.label,
      );
    }
    final int? directId = parseDirectDownloadTaskId(id);
    if (directId != null) {
      return directDownloadTaskToWire(_requireDirectTask(appModel, directId));
    }
    return videoDownloadJobToWire(await _requireJob(appModel, id));
  }),
  // 磁链 / .torrent：直接入队，参数与下载页「添加任务」对话框一一对应（内容类型、
  // 目标库、字幕策略、执行设备），外加对话框没露出但管线支持的文件选择 / 作品身份 /
  // 优先级，见 [addCtlTorrentDownload]。http(s) 直链进直链队列。
  CtlRoute.post('/api/admin/downloads', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    _requireDownloads(appModel);
    final String target =
        call.optString('magnet') ?? call.requireString('target');
    switch (classifyDownloadTarget(target)) {
      case CtlDownloadTargetKind.magnet:
        return addCtlTorrentDownload(
          appModel: appModel,
          call: call,
          magnet: target,
        );
      case CtlDownloadTargetKind.torrentFile:
        return addCtlTorrentDownload(
          appModel: appModel,
          call: call,
          torrentPath: target,
        );
      case CtlDownloadTargetKind.url:
        // http(s) 直链：进下载中心既有的直链队列（发现页 http 资源同一条
        // [DiscoveryDownloadQueue]：续传、自动重试、下完按内容类型自动入库）。
        final String? device = call.optString('device');
        if (device != null && device != 'local') {
          throw const CtlFailure.badRequest('http 直链只能在本机下（直链队列不经互联 host）');
        }
        final List<String> torrentOnly = <String>[
          if (call.optInt('source') != null) '--source',
          if (call.optString('subtitlePolicy') != null) '--subtitles',
          if (call.stringList('files').isNotEmpty) '--files',
          if (call.optInt('priority') != null) '--priority',
          if (call.optInt('year') != null) '--year',
          if (call.optString('metadataProvider') != null) '--provider',
        ];
        if (torrentOnly.isNotEmpty) {
          throw CtlFailure.badRequest(
            'http 直链不支持 ${torrentOnly.join('、')}（只用于磁链 / 种子任务）',
          );
        }
        if (Uri.tryParse(target)?.path.toLowerCase().endsWith('.torrent') ??
            false) {
          throw const CtlFailure.unsupported(
            '种子文件的 http 地址不能当直链下（会把 .torrent 当内容入库）；'
            '先下载种子文件再 dl add 本地 .torrent',
          );
        }
        final DiscoveryMediaKind kind = parseDirectDownloadKind(
          call.optString('mediaKind'),
        );
        final DiscoveryResourceItem item;
        try {
          item = buildDirectLinkDiscoveryItem(
            url: target,
            kind: kind,
            title: call.optString('title'),
          );
        } on FormatException catch (e) {
          throw CtlFailure.badRequest(e.message);
        }
        final DiscoveryDownloadQueue queue =
            _directQueue(appModel) ??
            (throw const CtlFailure.conflict('数据库还没就绪，稍后再试'));
        final bool added = queue.enqueue(
          item,
          destinationDir: await appModel.discoveryDownloadDirFor(kind),
        );
        final DiscoveryDownloadTask? task = queue.pendingTask(item);
        final String? jobId = task == null
            ? null
            : '$kCtlDirectDownloadIdPrefix${task.taskId}';
        if (!added) {
          throw CtlFailure.conflict(
            '同一地址已在下载队列中${jobId == null ? '' : '：$jobId'}',
          );
        }
        return <String, Object?>{
          'jobId': jobId,
          'title': item.title,
          'kind': kind.name,
        };
    }
  }),
  CtlRoute.post('/api/admin/downloads/:id/cancel', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    _requireDownloads(appModel);
    final String id = call.params['id']!;
    final CtlDownloadDeviceRemote? remote = await resolveCtlRemoteJobDevice(
      appModel,
      call.optString('device'),
    );
    if (remote != null) {
      // 远端任务卡同一判据：只有未结束的任务有「取消」。
      final HostDownloadJob job = await requireCtlHostJob(remote, id);
      if (hostDownloadJobFinished(job)) {
        throw CtlFailure.conflict('任务已结束，不能取消（当前：${job.lifecycle}）');
      }
      await mapCtlHostErrors(
        remote.target,
        () => remote.client.cancel(remote.target, id),
      );
      return null;
    }
    final int? directId = parseDirectDownloadTaskId(id);
    if (directId != null) {
      // 与下载页直链行「取消」同一入口：`.part` 保留，重试即续传。
      _directQueue(appModel)!.cancel(_requireDirectTask(appModel, directId));
      return null;
    }
    await _requireJob(appModel, id);
    await _mapPipelineErrors(() => _requirePipeline(appModel).cancelJob(id));
    return null;
  }),
  CtlRoute.post('/api/admin/downloads/:id/retry', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    _requireDownloads(appModel);
    final String id = call.params['id']!;
    final CtlDownloadDeviceRemote? remote = await resolveCtlRemoteJobDevice(
      appModel,
      call.optString('device'),
    );
    if (remote != null) {
      final HostDownloadJob job = await requireCtlHostJob(remote, id);
      if (!hostDownloadJobRetryable(job)) {
        throw CtlFailure.conflict('只有失败 / 需要处理的任务能重试（当前：${job.lifecycle}）');
      }
      await mapCtlHostErrors(
        remote.target,
        () => remote.client.retry(remote.target, id),
      );
      return null;
    }
    final int? directId = parseDirectDownloadTaskId(id);
    if (directId != null) {
      final DiscoveryDownloadTask task = _requireDirectTask(appModel, directId);
      if (task.status != DiscoveryDownloadStatus.failed &&
          task.status != DiscoveryDownloadStatus.cancelled) {
        throw CtlFailure.conflict('只有失败 / 已取消的任务能重试（当前：${task.status.name}）');
      }
      _directQueue(appModel)!.retry(task);
      return null;
    }
    await _requireJob(appModel, id);
    await _mapPipelineErrors(() => _requirePipeline(appModel).retryJob(id));
    return null;
  }),
  // 恢复已暂停的任务：与下载页任务卡「继续」同一入口（`cancel` 在管线里实为暂停，
  // 已下数据保留，恢复即续传）。判据复用任务卡同款 [videoDownloadJobCanResume]。
  CtlRoute.post('/api/admin/downloads/:id/resume', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    _requireDownloads(appModel);
    final String id = call.params['id']!;
    _rejectRemoteOnlyLocal(call);
    if (parseDirectDownloadTaskId(id) != null) {
      throw const CtlFailure.badRequest('直链任务没有暂停态：已取消的直链用 dl retry 续传');
    }
    final VideoDownloadJobRow job = await _requireJob(appModel, id);
    if (!videoDownloadJobCanResume(job)) {
      throw CtlFailure.conflict('只有已暂停的任务能继续（当前：${job.lifecycle}）');
    }
    await _mapPipelineErrors(() => _requirePipeline(appModel).resumeJob(id));
    return videoDownloadJobToWire(await _requireJob(appModel, id));
  }),
  // 排队优先级：与任务卡「优先级」菜单同一入口（high = 1 / normal = 0 / low = -1，
  // 数值越大越先取），可用判据同 [videoDownloadJobCanSetPriority]。
  CtlRoute.post('/api/admin/downloads/:id/priority', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    _requireDownloads(appModel);
    final String id = call.params['id']!;
    final int priority =
        call.optInt('priority') ??
        (throw const CtlFailure.badRequest('priority 缺失'));
    _rejectRemoteOnlyLocal(call);
    if (parseDirectDownloadTaskId(id) != null) {
      throw const CtlFailure.badRequest('直链队列按添加顺序下载，没有优先级');
    }
    final VideoDownloadJobRow job = await _requireJob(appModel, id);
    if (!videoDownloadJobCanSetPriority(job)) {
      throw CtlFailure.conflict('只有排队中 / 进行中的任务能调优先级（当前：${job.lifecycle}）');
    }
    await _mapPipelineErrors(
      () => _requirePipeline(appModel).setJobPriority(id, priority),
    );
    return videoDownloadJobToWire(await _requireJob(appModel, id));
  }),
  // 任务详情（种子快照 + 文件清单 + 落盘位置）：与任务卡「详情」对话框 / 「打开
  // 位置」同一数据源；没有管线时退回持久化的那一半（与 browse_page 同）。
  CtlRoute.get('/api/admin/downloads/:id/details', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    _requireDownloads(appModel);
    final String id = call.params['id']!;
    _rejectRemoteOnlyLocal(call);
    if (parseDirectDownloadTaskId(id) != null) {
      throw const CtlFailure.badRequest('直链任务没有种子详情（dl get 查看进度）');
    }
    final VideoDownloadJobRow job = await _requireJob(appModel, id);
    final VideoDownloadPipelineService? pipeline =
        appModel.videoDownloadPipelineService;
    final VideoDownloadJobDetails details = pipeline != null
        ? await _mapPipelineErrors(() => pipeline.loadJobDetails(id))
        : buildPersistedVideoDownloadJobDetails(
            job,
            await appModel.database.getVideoDownloadJobFiles(id),
          );
    final String? location = pipeline == null
        ? null
        : await _mapPipelineErrors(() => pipeline.resolveJobLocation(id));
    return <String, Object?>{
      ...videoDownloadJobToWire(job),
      ...downloadJobDetailsToWire(details, location: location),
    };
  }),
  // 任务落点：视频任务可投的目标库 + 执行设备（本机 / 在线的互联 host）。
  CtlRoute.get('/api/admin/download-targets', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    _requireDownloads(appModel);
    return ctlDownloadTargets(appModel);
  }),
  // 与下载页任务面板「删除」同一路径（`browse_page.dart` onDelete）：有管线走
  // [VideoDownloadPipelineService.deleteJob]，没有就只删持久化任务。
  CtlRoute.delete('/api/admin/downloads/:id', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    _requireDownloads(appModel);
    _requireConfirm(call, '删除下载任务');
    final bool deleteFiles = call.optBool('deleteFiles') ?? false;
    final CtlDownloadDeviceRemote? remote = await resolveCtlRemoteJobDevice(
      appModel,
      call.optString('device'),
    );
    if (remote != null) {
      // 远端任务卡同一判据：只有已结束的任务有「删除」。host 宣告 deleteFilesParam
      // 时 --delete-files 按字面生效（不给 = 保留文件，与下载页勾选框同义，
      // BUG-3437）；老 host 不认这个参数，给了就明确拒绝，不给则按它的历史缺省。
      final bool supported = remote.target.deleteFilesParam;
      if (deleteFiles && !supported) {
        throw CtlFailure.rejected(
          'host「${remote.target.label}」版本较旧，不支持选择是否删除文件（--delete-files）；'
          '不加这个参数时按它的缺省处理：Fushi app 当 host 保留文件、无头 fushi_server 连数据一起删',
        );
      }
      final String id = call.params['id']!;
      final HostDownloadJob job = await requireCtlHostJob(remote, id);
      if (!hostDownloadJobFinished(job)) {
        throw CtlFailure.conflict('任务还没结束，先 dl cancel（当前：${job.lifecycle}）');
      }
      await mapCtlHostErrors(
        remote.target,
        () => remote.client.delete(
          remote.target,
          id,
          deleteFiles: supported ? deleteFiles : null,
        ),
      );
      return <String, Object?>{
        'ok': true,
        'jobId': id,
        'device': remote.target.label,
        'remote': true,
        // 老 host：删不删由它决定、这里分不出是哪种 → null，如实说明。
        'deletedFiles': supported ? deleteFiles : null,
        'message': supported
            ? '已删除 host「${remote.target.label}」上的任务'
                  '${deleteFiles ? '，并删除了已下载文件' : '，已下载文件保留'}'
            : '已删除 host「${remote.target.label}」上的任务。这台 host 版本较旧，'
                  '文件去留由它决定：Fushi app 当 host 保留文件，无头 fushi_server 连下载数据一起删除',
      };
    }
    final int? directId = parseDirectDownloadTaskId(call.params['id']!);
    if (directId != null) {
      // 与下载页直链行「删除任务」同一入口（[DiscoveryDownloadQueue.remove]）：只摘
      // 行，`.part` 与已入库文件都不动——那边没有「连文件一起删」的语义。
      if (deleteFiles) {
        throw const CtlFailure.badRequest('直链任务只移除队列行，不支持 --delete-files');
      }
      _directQueue(appModel)!.remove(_requireDirectTask(appModel, directId));
      return <String, Object?>{
        'ok': true,
        'jobId': '$kCtlDirectDownloadIdPrefix$directId',
        'deletedFiles': false,
      };
    }
    final VideoDownloadJobRow job = await _requireJob(
      appModel,
      call.params['id']!,
    );
    final VideoDownloadPipelineService? pipeline =
        appModel.videoDownloadPipelineService;
    await _mapPipelineErrors(() async {
      if (pipeline != null) {
        await pipeline.deleteJob(job.jobId, deleteFiles: deleteFiles);
      } else {
        await deletePersistedVideoDownloadJob(
          database: appModel.database,
          job: job,
          deleteFiles: deleteFiles,
          pathMappings: appModel.downloadPathMappingsForProfile(
            job.backendProfileId,
          ),
        );
      }
    });
    return <String, Object?>{
      'ok': true,
      'jobId': job.jobId,
      'deletedFiles': deleteFiles,
    };
  }),
];

// ── 媒体服务器 ───────────────────────────────────────────────────────

Future<MediaServerBrowser> _browserFor(OpContext context, String id) async {
  final AppModel appModel = context.appModel;
  if (!appModel.moduleVisibility.isEnabled(ModuleId.video)) {
    throw const CtlFailure.rejected('视频模块已关闭');
  }
  final List<MediaServerConfig> configs = await SyncRepository(
    appModel.database,
  ).getMediaServers();
  // 与视频页「媒体服务器」分区同一构造（home_page `_loadMediaServerEntries`）。
  return resolveMediaServerConfig(configs, id).buildBrowser();
}

/// 媒体服务器请求失败：带原因回给终端，但先抹掉 URL 里可能带着的令牌。
Future<T> _mapServerErrors<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on CtlFailure {
    rethrow;
  } catch (e) {
    throw CtlFailure.rejected('媒体服务器请求失败：${redactCtlSecrets('$e')}');
  }
}

List<CtlRoute> _mediaServerRoutes(OpContext context) => <CtlRoute>[
  CtlRoute.get('/api/admin/media-servers', (CtlCall call) async {
    final List<MediaServerConfig> configs = await SyncRepository(
      context.appModel.database,
    ).getMediaServers();
    return <String, Object?>{
      'servers': <Map<String, Object?>>[
        for (int i = 0; i < configs.length; i++)
          mediaServerConfigToWire(configs[i], index: i + 1),
      ],
    };
  }),
  // 无 parent = 媒体库清单；有 parent = 该节点的直接子级（按父级分页）。
  CtlRoute.get('/api/admin/media-servers/:id/items', (CtlCall call) async {
    final MediaServerBrowser browser = await _browserFor(
      context,
      call.params['id']!,
    );
    final String? parent = call.optString('parent');
    if (parent == null) {
      final List<MediaServerLibrary> libraries = await _mapServerErrors(
        browser.listLibraries,
      );
      return <String, Object?>{
        'server': browser.displayName,
        'items': libraries.map(mediaServerLibraryToWire).toList(),
      };
    }
    final MediaServerPage page = await _mapServerErrors(
      () => browser.listChildren(
        parentId: parent,
        startIndex: call.optInt('start') ?? 0,
        limit: call.optInt('limit') ?? kMediaServerPageSize,
      ),
    );
    return <String, Object?>{
      'server': browser.displayName,
      ...mediaServerPageToWire(page),
    };
  }),
  CtlRoute.get('/api/admin/media-servers/:id/search', (CtlCall call) async {
    final MediaServerBrowser browser = await _browserFor(
      context,
      call.params['id']!,
    );
    final String query = call.requireString('q');
    final MediaServerPage page = await _mapServerErrors(
      () => browser.search(
        query,
        startIndex: call.optInt('start') ?? 0,
        limit: call.optInt('limit') ?? kMediaServerPageSize,
      ),
    );
    return <String, Object?>{
      'server': browser.displayName,
      'query': query,
      ...mediaServerPageToWire(page),
    };
  }),
];

// ── 互联 ─────────────────────────────────────────────────────────────

Future<Map<String, Object?>> _hostStatus(AppModel appModel) async {
  final FushiSyncServerController controller = appModel.syncServerController;
  final SyncRepository repo = SyncRepository(appModel.database);
  return <String, Object?>{
    'running': controller.isRunning,
    'enabled': await repo.isServerEnabled(),
    'port': controller.boundPort ?? await repo.getServerPort(),
    'pairedPeers': (await appModel.database.getPairedPeers()).length,
  };
}

List<CtlRoute> _peerRoutes(OpContext context) => <CtlRoute>[
  // 两个方向的对端：本机作为 client 记住的 host 地址，以及已配对到本机 host 的
  // 设备。令牌 / 证书只报「有没有」。
  CtlRoute.get('/api/admin/peers', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    final SyncRepository repo = SyncRepository(appModel.database);
    final List<FushiPairedPeerRow> paired = await appModel.database
        .getPairedPeers();
    return <String, Object?>{
      'hosts': (await repo.getFushiClientUrls())
          .map(peerHostUrlToWire)
          .toList(),
      'clients': <Map<String, Object?>>[
        for (final FushiPairedPeerRow row in paired)
          <String, Object?>{
            'peerId': row.peerId,
            if (row.deviceName != null) 'deviceName': row.deviceName,
            'pairedAt': row.pairedAtMs,
            if (row.lastSeenIp != null) 'lastSeenIp': row.lastSeenIp,
          },
      ],
    };
  }),
  CtlRoute.get('/api/admin/peers/host', (CtlCall call) async {
    return _hostStatus(context.appModel);
  }),
  // 与设置页「启用主机服务」开关同一序列：首次启用的 TLS 默认 → controller.start()。
  CtlRoute.post('/api/admin/peers/host/start', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    final SyncRepository repo = SyncRepository(appModel.database);
    // 角色锁（设置页 `lockedByClient`）：本机已作为 client 连着别的 host 时不能
    // 同时当 host。
    if (!await repo.isServerEnabled() &&
        (await repo.getFushiClientUrls()).isNotEmpty) {
      throw const CtlFailure.rejected('本机已作为客户端连接了 host，不能同时当 host');
    }
    await repo.applyFirstHostingTlsDefault();
    final FushiServerStartOutcome outcome = await appModel.syncServerController
        .start();
    switch (outcome) {
      case FushiServerStarted():
        return _hostStatus(appModel);
      case FushiServerPortInUse(:final int port):
        throw CtlFailure.conflict('端口 $port 已被占用');
      case FushiServerStartError(:final String message):
        throw CtlFailure.rejected(redactCtlSecrets(message));
    }
  }),
  CtlRoute.post('/api/admin/peers/host/stop', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    await appModel.syncServerController.stop(persistDisabled: true);
    return _hostStatus(appModel);
  }),
  // 配对链接。缺省经 app 的确认框（链接可能来自任何网页）：拉起
  // [runInterconnectLinkPairingFlow]，结果在 app 里提示。带 `confirm: true`（CLI
  // `--yes`，本机持令牌的操作者已核对过链接）时跳过确认框，直接走同一个
  // [pairWithInterconnectLink] 并把结果回给终端；不带票据、要 PIN 的链接终端输不了
  // PIN，如实报错让用户回 app 配。
  CtlRoute.post('/api/admin/peers/pair', (CtlCall call) async {
    final String raw = call.requireString('link');
    final FushiPairLink? link = FushiPairLink.tryParse(raw);
    if (link == null) {
      throw const CtlFailure.badRequest('不是有效的 fushi://pair 配对链接');
    }
    final AppModel appModel = context.appModel;
    if (call.optBool('confirm') == true) {
      final SyncRepository repo = SyncRepository(appModel.database);
      final InterconnectLinkPairingResult result =
          await pairWithInterconnectLink(
            repo: repo,
            link: link,
            localDeviceName: await resolveInterconnectDeviceName(
              appModel.platformServices.deviceInfo,
            ),
            pinProvider: () async => null,
          );
      switch (result) {
        case InterconnectLinkPaired(
          :final String baseUrl,
          :final String? deviceName,
        ):
          return <String, Object?>{
            'ok': true,
            'paired': true,
            'url': baseUrl,
            'hostId': link.hostId,
            'deviceName': ?(deviceName ?? link.deviceName),
            'message': '已配对：${deviceName ?? link.deviceName ?? baseUrl}',
          };
        case InterconnectLinkPairingFailed(:final String reason):
          if (reason == 'cancelled' || reason == 'pin') {
            throw const CtlFailure.rejected(
              '这个链接不带一次性票据，host 要求输入 PIN；终端无法输入，去掉 --yes 在 app 里配对',
            );
          }
          throw CtlFailure.rejected(
            '配对失败（$reason）：${interconnectPairFailureMessage(reason)}',
          );
      }
    }
    final BuildContext ui = await _uiContext(context);
    _runDetached(
      'peers.pair',
      () => runInterconnectLinkPairingFlow(ui, appModel, link),
    );
    return <String, Object?>{
      'ok': true,
      if (link.deviceName != null) 'deviceName': link.deviceName,
      'message': '已在 Fushi 里弹出配对确认，请在 app 里确认',
    };
  }),
  // 本机 host 签发一次性配对链接：与设置页「扫码配对」二维码同一入口
  // [FushiSyncServerController.createPairLink]（重新签发即作废上一张票据）。链接
  // 就是要交给对方设备的东西，所以原样回给终端（二维码里本来也是它）。
  CtlRoute.post('/api/admin/peers/pair-link', (CtlCall call) async {
    final FushiSyncServerController controller =
        context.appModel.syncServerController;
    final FushiPairLink? link = await controller.createPairLink();
    if (link == null) {
      throw const CtlFailure.conflict('本机互联 host 没在运行（peer host start）');
    }
    if (link.addresses.isEmpty) {
      // 与二维码窗口同一判据：没有可公布的地址，对方拿到链接也连不上。
      controller.revokePairTicket();
      throw const CtlFailure.rejected(
        '本机 host 没有可公布的地址（只监听本机？在设置 › 互联里开放局域网访问）',
      );
    }
    return <String, Object?>{
      'link': link.toUri(),
      'hostId': link.hostId,
      'deviceName': ?link.deviceName,
      'oneTime': link.hasTicket,
      'addresses': link.addresses.map(pairLinkAddressToWire).toList(),
    };
  }),
  // 作废当前配对票据（= 关掉二维码窗口），凭它开出、还没确认的会话一并作废。
  CtlRoute.delete('/api/admin/peers/pair-link', (CtlCall call) async {
    context.appModel.syncServerController.revokePairTicket();
    return const <String, Object?>{'ok': true, 'revoked': true};
  }),
  // 吊销一台已配对到本机 host 的设备：与设置页「移除已配对设备」同一入口
  // [FushiSyncServerController.revokePeer]（删 per-peer token，下一次请求即 401）。
  CtlRoute.delete('/api/admin/peers/clients/:peerId', (CtlCall call) async {
    _requireConfirm(call, '吊销已配对设备');
    final String peerId = call.params['peerId']!;
    final bool revoked = await context.appModel.syncServerController.revokePeer(
      peerId,
    );
    if (!revoked) throw CtlFailure.notFound('没有这台已配对设备：$peerId（peer ls 查看）');
    return <String, Object?>{'ok': true, 'peerId': peerId};
  }),
  // 忘记本机作为 client 记住的一台 host：与设置页地址行「删除」同一变换
  // [withoutInterconnectHost]，经 [SyncRepository.updateFushiClientUrls] 串行写库
  // （与后台地址学习、链接配对互斥）。按 hostId 认：同一台 host 的全部地址一起删。
  CtlRoute.delete('/api/admin/peers/hosts/:host', (CtlCall call) async {
    _requireConfirm(call, '忘记 host');
    final SyncRepository repo = SyncRepository(context.appModel.database);
    final ({String url, String? hostId}) target = resolveForgetHost(
      await repo.getFushiClientUrls(),
      call.params['host']!,
    );
    int removed = 0;
    final List<FushiClientUrl> after = await repo.updateFushiClientUrls((
      List<FushiClientUrl> current,
    ) {
      final List<FushiClientUrl> next = withoutInterconnectHost(
        current,
        url: target.url,
        hostId: target.hostId,
      );
      removed = current.length - next.length;
      return next;
    });
    return <String, Object?>{
      'ok': true,
      'url': target.url,
      'hostId': ?target.hostId,
      'removedAddresses': removed,
      'remainingAddresses': after.length,
    };
  }),
];

// ── 存储 ─────────────────────────────────────────────────────────────

List<CtlRoute> _storageRoutes(OpContext context, _CtlDataTasks tasks) =>
    <CtlRoute>[
      // 数据目录迁移：与设置 › 存储「更改位置」同一套 [planDataRootMigration]（解析 +
      // 触发前校验）→ [runDataRootMigration]（关库 → 搬移 → 写位置 → 自动重启）。
      // `dryRun` 只出解析后的两个落点（= 设置页确认框里列的那两行），不动任何东西。
      // 真迁移要 `confirm: true`；它会关掉数据库并在成功后重启 app，所以在后台跑、
      // 立即返回，进度用 GET 查（重启后控制通道换成新进程的）。
      CtlRoute.post('/api/admin/storage/migrate', (CtlCall call) async {
        final String path = call.requireString('path');
        if (!p.isAbsolute(path)) {
          throw CtlFailure.badRequest('目标目录必须是绝对路径：$path');
        }
        final bool dryRun = call.optBool('dryRun') ?? false;
        if (!dryRun) _requireConfirm(call, '迁移数据目录');
        final AppModel appModel = context.appModel;
        if (appModel.dataRootMigrationActive) {
          throw const CtlFailure.conflict('数据目录迁移已在进行中');
        }
        if (appModel.backupExportActive) {
          throw const CtlFailure.conflict('备份导出进行中，先等它结束');
        }
        final DataRootMigrationPlan plan;
        try {
          plan = await planDataRootMigration(appModel: appModel, picked: path);
        } on DataRootMigrationPrecheckFailure catch (e) {
          throw CtlFailure.rejected(e.message);
        }
        final Map<String, Object?> planWire = <String, Object?>{
          'path': path,
          'documentsRoot': plan.target.documentsRoot.path,
          'supportRoot': plan.target.supportRoot.path,
          'defaultLocation': plan.target.isDefaultLocation,
          'fromDocumentsRoot': plan.oldDocumentsRoot,
          'fromSupportRoot': plan.oldSupportRoot,
        };
        if (dryRun) return <String, Object?>{...planWire, 'dryRun': true};
        tasks.lastMigration = <String, Object?>{
          ...planWire,
          'state': 'running',
          'startedAt': DateTime.now().millisecondsSinceEpoch,
        };
        _runDetached('storage.migrate', () async {
          try {
            final DataRootMigrationRunOutcome outcome =
                await runDataRootMigration(appModel: appModel, plan: plan);
            tasks.lastMigration = <String, Object?>{
              ...planWire,
              'state': outcome.name,
              if (appModel.dataRootMigrationFailure != null)
                'message': appModel.dataRootMigrationFailure,
            };
          } on DataRootMigrationPrecheckFailure catch (e) {
            tasks.lastMigration = <String, Object?>{
              ...planWire,
              'state': 'failed',
              'message': e.message,
            };
          }
          return null;
        });
        return <String, Object?>{
          ...planWire,
          'ok': true,
          'started': true,
          'message':
              '已开始迁移（app 显示迁移遮罩，数据库已关闭）；成功后 app 会自动重启。'
              '用 storage migrate-status 查进度，重启后 storage root 确认新位置',
        };
      }),
      CtlRoute.get('/api/admin/storage/migrate', (CtlCall call) async {
        final AppModel appModel = context.appModel;
        final ({int copied, int total})? progress =
            appModel.dataRootMigrationProgress;
        return <String, Object?>{
          'active': appModel.dataRootMigrationActive,
          // 跨盘逐文件复制时才有（已复制文件数 / 总文件数）；同盘 rename 瞬时完成、无进度。
          if (progress != null) 'copiedFiles': progress.copied,
          if (progress != null) 'totalFiles': progress.total,
          'failure': ?appModel.dataRootMigrationFailure,
          'last': ?tasks.lastMigration,
        };
      }),
      CtlRoute.get('/api/admin/storage/root', (CtlCall call) async {
        final AppModel appModel = context.appModel;
        final Directory documents = await AppPaths.documentsRootDirectory();
        final Directory defaultDocuments =
            await AppPaths.defaultLocationDocumentsRoot();
        return <String, Object?>{
          'documents': documents.path,
          'support': (await AppPaths.supportRootDirectory()).path,
          'temp': (await AppPaths.tempRootDirectory()).path,
          'database': appModel.databaseDirectory.path,
          'customDataRoot': !p.equals(documents.path, defaultDocuments.path),
        };
      }),
      // 与设置 › 存储页同一个扫描器，只出类目合计（明细行要书目清单，存储页那份
      // 组装逻辑在设置 schema 里，CLI 不复制）。
      CtlRoute.get('/api/admin/storage/usage', (CtlCall call) async {
        final AppModel appModel = context.appModel;
        final List<Map<String, Object?>> categories = <Map<String, Object?>>[];
        int total = 0;
        await for (final StorageCategoryUsage usage
            in StorageUsageService().scanCategories(
              books: const <StorageBookRef>[],
              dictionaryNames: <String>[
                for (final Dictionary dictionary in appModel.dictionaries)
                  dictionary.name,
              ],
            )) {
          total += usage.bytes;
          categories.add(<String, Object?>{
            'id': usage.id.name,
            'bytes': usage.bytes,
          });
        }
        return <String, Object?>{'totalBytes': total, 'categories': categories};
      }),
    ];
