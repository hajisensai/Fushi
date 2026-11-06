import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        kLegacySchemaBridgeAppVersion,
        kLegacySchemaBridgeReleaseUrl,
        kMinSupportedSchemaVersion;

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/onboarding/recommended_pack_import.dart';
import 'package:fushi/src/ops/ctl_data_wire.dart' show parseBackupImportPreset;
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show BackupImportPreset;

/// 「推荐包」整包（词典 + 发音库，一份 Fushi 备份 zip）控制通道路由。
///
/// 全部复用设置 › 系统那一行与新手引导用的 [RecommendedPackDownloadController]
/// （下载 / 续传 / 取消 / 放弃半截）与 [importDownloadedRecommendedPack]（备份导入
/// 编排）；本文件只做门控 + 参数解析 + 出参。CLI 命令见
/// `packages/fushi_cli/lib/src/commands/dictionary_commands.dart` 的 `dict pack-*`。
List<CtlRoute> buildDictionaryPackCtlRoutes(OpContext context) {
  RecommendedPackDownloadController controller() =>
      context.appModel.recommendedPackDownloadController;

  return <CtlRoute>[
    CtlRoute.get('/api/admin/dictionary-pack', (CtlCall call) async {
      return ctlPackStatusJson(controller());
    }),
    CtlRoute.post('/api/admin/dictionary-pack/download', (CtlCall call) async {
      final RecommendedPackDownloadController c = controller();
      c.syncStageWithDisk();
      if (c.isDownloading) {
        throw const CtlFailure.conflict('推荐包正在下载（fushi_cli dict pack 查看进度）');
      }
      if (c.hasPendingImport) {
        throw const CtlFailure.conflict(
          '推荐包已下载完成，等待导入（fushi_cli dict pack-import）',
        );
      }
      // 与设置行「下载 / 继续下载」同一个 start()：盘上有半截会续传。
      final Future<File?> run = c.start();
      if (call.optBool('wait') ?? false) {
        final File? file = await run;
        return <String, Object?>{
          'finished': true,
          'downloaded': file != null,
          ...ctlPackStatusJson(c),
        };
      }
      unawaited(
        run.then<void>(
          (_) {},
          onError: (Object e, StackTrace s) =>
              debugPrint('ctl[pack.download] failed: $e\n$s'),
        ),
      );
      // start() 同步段已把阶段切到 downloading。
      return <String, Object?>{'started': true, ...ctlPackStatusJson(c)};
    }),
    CtlRoute.post('/api/admin/dictionary-pack/cancel', (CtlCall call) async {
      final RecommendedPackDownloadController c = controller();
      if (!c.isDownloading) {
        throw const CtlFailure.conflict('推荐包没有在下载');
      }
      // 半截文件保留，下次 pack-download 续传。
      c.requestCancel();
      return <String, Object?>{'cancelRequested': true};
    }),
    CtlRoute.delete('/api/admin/dictionary-pack', (CtlCall call) async {
      if (call.optBool('confirm') != true) {
        throw const CtlFailure.badRequest('放弃推荐包半截下载需要 confirm=true');
      }
      final RecommendedPackDownloadController c = controller();
      c.syncStageWithDisk();
      if (!c.isPaused) {
        throw const CtlFailure.conflict('只有「已暂停」的半截下载能放弃（下载中先 pack-cancel）');
      }
      final bool deleted = await c.discardPartialDownload();
      if (!deleted) {
        throw CtlFailure.conflict(c.failureMessage ?? '半截文件删除失败（可能被占用）');
      }
      return <String, Object?>{'discarded': true, ...ctlPackStatusJson(c)};
    }),
    CtlRoute.post('/api/admin/dictionary-pack/import', (CtlCall call) async {
      if (call.optBool('confirm') != true) {
        throw const CtlFailure.badRequest('导入推荐包需要 confirm=true');
      }
      // 必须显式给模式：不弹确认框替用户选覆盖 / 合并。
      if (call.optString('mode') == null) {
        throw const CtlFailure.badRequest('mode 缺失（merge 或 replace）');
      }
      final BackupImportPreset preset = parseBackupImportPreset(
        mode: call.optString('mode'),
        categories: call.stringList('categories'),
        importSettings: call.optBool('importSettings') ?? false,
      )!;
      final AppModel appModel = context.appModel;
      final RecommendedPackDownloadController c = controller();
      c.syncStageWithDisk();
      if (!c.hasPendingImport) {
        throw const CtlFailure.conflict(
          '推荐包还没下载完成（fushi_cli dict pack 查看，dict pack-download 下载）',
        );
      }
      if (appModel.backupExportActive) {
        throw const CtlFailure.conflict('备份导出进行中，先等它结束');
      }
      final BackupMeta? meta = await BackupRestoreService.validateBackup(
        c.packFile.path,
      );
      if (meta == null) throw const CtlFailure.rejected('推荐包不是有效的 Fushi 备份包');
      if (meta.schemaVersion > appModel.database.schemaVersion) {
        throw CtlFailure.rejected(
          '推荐包来自更新版本的 Fushi（schema ${meta.schemaVersion}），先升级 app',
        );
      }
      if (meta.schemaVersion > 0 &&
          meta.schemaVersion < kMinSupportedSchemaVersion) {
        throw CtlFailure.rejected(
          '推荐包 schema ${meta.schemaVersion} 过旧，先装 Fushi '
          'v$kLegacySchemaBridgeAppVersion 导入一次（$kLegacySchemaBridgeReleaseUrl）',
        );
      }
      await context.focusMainWindow();
      unawaited(
        Future<void>.sync(
          () => importDownloadedRecommendedPack(appModel, preset: preset),
        ).catchError((Object e, StackTrace s) {
          debugPrint('ctl[pack.import] failed: $e\n$s');
        }),
      );
      final bool merge = '${call.optString('mode')}' == 'merge';
      return <String, Object?>{
        'ok': true,
        'mode': merge ? 'merge' : 'replace',
        'restarts': true,
        'message':
            '已开始${merge ? '合并' : '覆盖'}导入推荐包（进度在 Fushi 里显示），'
            '完成后 app 会自动重启，控制通道随之断开',
      };
    }),
  ];
}

/// 推荐包下载状态的投影（纯函数读 controller 当前值）。
Map<String, Object?> ctlPackStatusJson(
  RecommendedPackDownloadController controller,
) {
  controller.syncStageWithDisk();
  return <String, Object?>{
    'stage': controller.stage.value.name,
    'progress': controller.progress.value,
    'receivedBytes': controller.receivedBytes.value,
    'downloading': controller.isDownloading,
    'resumable': controller.isPaused,
    'readyToImport': controller.hasPendingImport,
    if (controller.error.value != null)
      'error': controller.failureMessage ?? controller.error.value,
    'packFile': controller.packFile.path,
  };
}
