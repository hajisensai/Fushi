import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show Dictionary;
import 'package:fushi_core/fushi_core.dart'
    show FushiPairedPeerRow, VideoDownloadJobRow;
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/sync/downloads/host_download_host.dart'
    show HostDownloadAddRequest, videoDownloadJobToWire;
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';
import 'package:fushi_engine/sync/sync_backend_type.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/discovery/direct_link_download.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/manual_download_task_dialog.dart'
    show showManualDownloadTaskDialog;
import 'package:fushi/src/platform/desktop/ctl/ctl_data_wire.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart'
    show runManualSyncWithFeedback;
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
        runBackupImportFlowForFile,
        runInterconnectLinkPairingFlow;

/// data 域控制通道路由（CLI 侧命令见 `packages/fushi_cli/lib/src/commands/data_commands.dart`）。
///
/// 每条路由只做「门控 + 参数解析 + 调 app 既有入口 + 白名单出参」，业务都在
/// 原服务里：备份 [BackupService] / [BackupRestoreService]、同步
/// [runManualSyncWithFeedback]、下载 [AppModel.appDownloadHost] 与下载管线 / 直链队列
/// [AppModel.discoveryDownloadQueue]、媒体
/// 服务器 [MediaServerConfig.buildBrowser]、互联 [FushiSyncServerController]、存储
/// [StorageUsageService]。
List<CtlRoute> buildDataCtlRoutes(DesktopCtlContext context) => <CtlRoute>[
  ..._backupRoutes(context),
  ..._syncRoutes(context),
  ..._downloadRoutes(context),
  ..._mediaServerRoutes(context),
  ..._peerRoutes(context),
  ..._storageRoutes(context),
];

/// 破坏性动作在 app 侧的第二道门：body / query 必须带 `confirm: true`。
void _requireConfirm(CtlCall call, String what) {
  if (call.optBool('confirm') != true) {
    throw CtlFailure.badRequest('$what 需要确认（confirm: true）');
  }
}

/// 需要界面（确认框 / 提示）的动作：主窗口带到前台，返回全局 navigator 的 context。
Future<BuildContext> _uiContext(DesktopCtlContext context) async {
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

List<CtlRoute> _backupRoutes(DesktopCtlContext context) => <CtlRoute>[
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
    final Set<BackupCategory>? categories = all
        ? null
        : (parseBackupCategories(call.stringList('categories')) ??
              // ignore: invalid_use_of_visible_for_testing_member
              defaultBackupExportCategories());
    List<String> skippedDictionaries = const <String>[];
    appModel.beginBackupExport();
    final BackupMeta meta;
    try {
      meta = await service.createBackup(
        outputPath,
        categories: categories,
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
      'categories': categories == null
          ? <String>[
              for (final BackupCategory c in BackupCategory.values) c.name,
            ]
          : <String>[for (final BackupCategory c in categories) c.name],
      'skippedDictionaries': skippedDictionaries,
      ...backupMetaToWire(meta),
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

List<CtlRoute> _syncRoutes(DesktopCtlContext context) => <CtlRoute>[
  CtlRoute.get('/api/admin/sync', (CtlCall call) async {
    final SyncRepository repo = SyncRepository(context.appModel.database);
    final SyncBackendType selected = await repo.getBackendType();
    return <String, Object?>{
      'autoSync': await repo.isAutoSyncEnabled(),
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
  // 指定的通道（[runManualFullSync] 的 onlyChannels）。冲突 / 鉴权失效的交互与
  // 提示都在 app 里出现。
  CtlRoute.post('/api/admin/sync/run', (CtlCall call) async {
    final Set<SyncAssetChannelScope>? only = parseSyncChannelScopes(
      call.stringList('channels'),
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
    );
    if (call.optBool('wait') != true) {
      _runDetached('sync.run', () => run);
      return const <String, Object?>{'ok': true, 'started': true};
    }
    final ManualSyncOutcome outcome = await run;
    return <String, Object?>{
      'ok': outcome == ManualSyncOutcome.completed,
      'outcome': outcome.name,
      'lastFullSweep': syncOutcomeToWire(lastFullSweepOutcome.value),
    };
  }),
];

// ── 下载 ─────────────────────────────────────────────────────────────

/// 下载中心的门：合规门（iOS 无下载中心）+「浏览」模块开关（下载页签挂在它下面）。
void _requireDownloads(AppModel appModel) {
  if (!StoreRestrictedCapability.downloads.isAvailable) {
    throw const CtlFailure.unsupported('本平台不提供下载中心');
  }
  if (!appModel.moduleVisibility.isEnabled(ModuleId.browse)) {
    throw const CtlFailure.rejected('「浏览」模块已关闭（设置 › 功能模块）');
  }
}

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

List<CtlRoute> _downloadRoutes(DesktopCtlContext context) => <CtlRoute>[
  // 与无头服务端 `admin_api.dart` 的 GET /api/admin/downloads 同形：能力位 + 任务表。
  CtlRoute.get('/api/admin/downloads', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    _requireDownloads(appModel);
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
    final int? directId = parseDirectDownloadTaskId(id);
    if (directId != null) {
      return directDownloadTaskToWire(_requireDirectTask(appModel, directId));
    }
    return videoDownloadJobToWire(await _requireJob(appModel, id));
  }),
  // 磁链：走 [AppDownloadHost.add]（与 admin_api / 互联代下载同一入口，落到
  // 默认受管视频来源）。.torrent：打开「添加任务」对话框预填该种子，由用户确认
  // 标题 / 内容类型 / 目标来源（对话框是种子解析与文件选择的唯一实现）。
  CtlRoute.post('/api/admin/downloads', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    _requireDownloads(appModel);
    final String target =
        call.optString('magnet') ?? call.requireString('target');
    switch (classifyDownloadTarget(target)) {
      case CtlDownloadTargetKind.magnet:
        final String? title = magnetTaskTitle(target, call.optString('title'));
        if (title == null) {
          throw const CtlFailure.badRequest('磁链里没有显示名（dn），请用 --title 指定');
        }
        final String jobId = await _mapPipelineErrors(
          () => appModel.appDownloadHost.add(
            HostDownloadAddRequest.magnet(
              magnetUri: target,
              title: title,
              mediaKind: call.optString('mediaKind') == 'tv' ? 'tv' : 'movie',
            ),
          ),
        );
        return <String, Object?>{'jobId': jobId, 'title': title};
      case CtlDownloadTargetKind.torrentFile:
        if (!p.isAbsolute(target) || !await File(target).exists()) {
          throw CtlFailure.notFound('种子文件不存在：$target');
        }
        final BuildContext ui = await _uiContext(context);
        _runDetached(
          'downloads.add',
          () => showManualDownloadTaskDialog(
            context: ui,
            appModel: appModel,
            torrentPaths: <String>[target],
          ),
        );
        return const <String, Object?>{
          'ok': true,
          'dialog': true,
          'message': '已在 Fushi 里打开「添加任务」对话框，确认后入队',
        };
      case CtlDownloadTargetKind.url:
        // http(s) 直链：进下载中心既有的直链队列（发现页 http 资源同一条
        // [DiscoveryDownloadQueue]：续传、自动重试、下完按内容类型自动入库）。
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
          destinationDir: appModel.discoveryDownloadDirFor(kind),
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
  // 与下载页任务面板「删除」同一路径（`browse_page.dart` onDelete）：有管线走
  // [VideoDownloadPipelineService.deleteJob]，没有就只删持久化任务。
  CtlRoute.delete('/api/admin/downloads/:id', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    _requireDownloads(appModel);
    _requireConfirm(call, '删除下载任务');
    final bool deleteFiles = call.optBool('deleteFiles') ?? false;
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

Future<MediaServerBrowser> _browserFor(
  DesktopCtlContext context,
  String id,
) async {
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

List<CtlRoute> _mediaServerRoutes(DesktopCtlContext context) => <CtlRoute>[
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

List<CtlRoute> _peerRoutes(DesktopCtlContext context) => <CtlRoute>[
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
  // 配对链接：必须经 app 的确认框（链接可能来自任何网页），这里只解析并拉起
  // [runInterconnectLinkPairingFlow]，结果在 app 里提示。
  CtlRoute.post('/api/admin/peers/pair', (CtlCall call) async {
    final String raw = call.requireString('link');
    final FushiPairLink? link = FushiPairLink.tryParse(raw);
    if (link == null) {
      throw const CtlFailure.badRequest('不是有效的 fushi://pair 配对链接');
    }
    final AppModel appModel = context.appModel;
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
];

// ── 存储 ─────────────────────────────────────────────────────────────

List<CtlRoute> _storageRoutes(DesktopCtlContext context) => <CtlRoute>[
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
