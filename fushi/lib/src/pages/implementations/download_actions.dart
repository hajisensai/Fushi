import 'dart:async' show unawaited;
import 'package:flutter/material.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi_engine/media/torrent/magnet_utils.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/downloads/download_execution_target.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/torrent_upload_consent_dialog.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/media/discovery/sources/core_audio_discovery_source.dart';

/// 通用磁力推送的结果（调用方据此弹提示）。
enum GenericPushOutcome {
  ok,
  invalidMagnet,
  storeUnavailable,
  notReady,
  pushFailed,

  /// 已交给「下载执行设备」偏好指向的互联 host（设计 §3.3）。
  remoteQueued,

  /// 偏好指向的 host 连不上；**没有**退回本机下载。
  remoteUnreachable,

  /// host 不收这个内容域（无头 fushi_server 只收视频）。
  remoteKindUnsupported,

  /// host 只收磁链，`.torrent` 文件 / 单文件选择走不了远端。
  remoteMagnetOnly;

  bool get isSuccess => this == ok || this == remoteQueued;
}

/// 下载后端是否就绪：内置引擎宿主就绪（桌面 + DLL）且未显式选外接 qb → 就绪；
/// 否则走外接 qb，需填了**能解析出身份**的地址。下载对话框与下载页共用同一判断。
///
/// 「地址非空」不够：`buildVideoDownloadBackendIdentity` 用
/// [normalizeQbBackendAddress] 解析身份，它要求 http/https scheme + 非空 host，
/// 而 qb 用户最常见的手输形式恰恰是 `127.0.0.1:8080`（实测被判非法）。两套判据
/// 一松一严时，「非空」这套会放行 → 落库 → 身份解析抛 ArgumentError → 调用方把
/// 它当「未配置」再弹一次配置引导，字段原样、无错误提示，用户出不去。所以两处
/// 必须是同一个函数，而不是各判各的。
bool torrentBackendReady(AppModel appModel) =>
    appModel.readyVideoDownloadBackend != null;

/// 首次下载弹「上传/做种」一次性提示（默认关上传、询问开启、可配限速/时长/
/// 分享率）；确认后落偏好（即时应用到内置引擎）并置首用 flag。仅内置引擎相关。
Future<void> maybeShowTorrentUploadConsent(
  BuildContext context,
  AppModel appModel,
) async {
  final QbConnectionConfig config =
      effectiveTorrentConfig(appModel.qbConnectionConfig);
  if (appModel.torrentUploadIntroShown ||
      !appModel.isEmbeddedTorrentReady ||
      config.backend == QbConnectionConfig.backendQbittorrent) {
    return;
  }
  await showAppDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) => TorrentUploadConsentDialog(
      initialConfig: config,
      onApply: (QbConnectionConfig next) async {
        await appModel.setQbConnectionConfig(next);
        await appModel.setTorrentUploadIntroShown();
      },
    ),
  );
}

/// 通用磁力推送：首用同意 → 解析 infoHash → 落通用计划（带 [contentKind]）→ 推
/// 后端（顺序 + 首尾块优先，支持边下边播）。失败回滚计划。下载对话框与下载页
/// 共用这一逻辑（单一真相源）。返回 [GenericPushOutcome] 供调用方弹提示。
Future<GenericPushOutcome> pushGenericMagnet({
  required BuildContext context,
  required AppModel appModel,
  required String magnet,
  required String contentKind,
  DiscoveryMediaKind? discoveryKind,
}) async {
  // 「下载执行设备」指到互联 host 时整条磁链交给它，本机不碰下载后端。
  // [discoveryKind] 是远端按域入库用的内容域（null = 视频）；本机路径仍按
  // [contentKind] 走旧计划。
  final DownloadExecutionResolution execution =
      await resolveDownloadExecution(appModel);
  switch (execution) {
    case DownloadExecutionRemote(target: final target, client: final client):
      final String? kindName = discoveryKind?.name;
      if (!target.supportsKind(kindName)) {
        return GenericPushOutcome.remoteKindUnsupported;
      }
      final String trimmed = magnet.trim();
      if (parseMagnetInfoHash(trimmed) == null) {
        return GenericPushOutcome.invalidMagnet;
      }
      try {
        await client.addMagnet(
          target,
          magnetUri: trimmed,
          title: parseMagnetDisplayName(trimmed) ?? trimmed,
          discoveryKind: kindName,
        );
        return GenericPushOutcome.remoteQueued;
      } on Object catch (error, stack) {
        ErrorLogService.instance.log('GenericMagnet.remote', error, stack);
        return GenericPushOutcome.pushFailed;
      }
    case DownloadExecutionUnreachable():
      return GenericPushOutcome.remoteUnreachable;
    case DownloadExecutionLocal():
      break;
  }
  // 上面的解析可能真的等过网络（偏好指到 host 时探一次），回来时发起页面可能
  // 已经关了：同意弹窗要 context，没有宿主就别推。
  if (!context.mounted) return GenericPushOutcome.pushFailed;
  if (!torrentBackendReady(appModel)) return GenericPushOutcome.notReady;
  final QbConnectionConfig config =
      effectiveTorrentConfig(appModel.qbConnectionConfig);
  final String? infoHash = parseMagnetInfoHash(magnet.trim());
  if (infoHash == null) return GenericPushOutcome.invalidMagnet;
  final AnimeDownloadPlanStore? store = appModel.animeDownloadPlanStore;
  if (store == null) return GenericPushOutcome.storeUnavailable;

  await maybeShowTorrentUploadConsent(context, appModel);

  final String title = parseMagnetDisplayName(magnet) ?? magnet.trim();
  final AnimeDownloadPlan plan = AnimeDownloadPlan(
    id: infoHash,
    createdAtMs: DateTime.now().millisecondsSinceEpoch,
    seriesTitle: title,
    torrentTitle: title,
    magnet: magnet.trim(),
    qbCategory: config.category,
    contentKind: contentKind,
  );
  await store.save(plan);

  final TorrentBackend backend = appModel.createTorrentBackend(config);
  bool pushed = false;
  try {
    await backend.prepareCategory(config.category);
    pushed = await backend.addTorrent(
      magnet.trim(),
      category: config.category,
      sequential: true,
      firstLastPiecePrio: true,
    );
  } finally {
    backend.close();
  }
  if (!pushed) {
    await store.delete(infoHash);
    return GenericPushOutcome.pushFailed;
  }
  unawaited(appModel.animeDownloadService?.tick());
  return GenericPushOutcome.ok;
}

/// 把已经解析出单文件选择的 `.torrent` 放进 schema-v78 durable 管线。
/// CoreAudio/TMW 不能走旧 [pushGenericMagnet]，因为后者只保存 infoHash，会丢掉
/// “只下载这一卷”的选择意图。
Future<GenericPushOutcome> enqueueSelectedDiscoveryTorrent({
  required BuildContext context,
  required AppModel appModel,
  required String title,
  required String resourceTitle,
  required InspectedTorrentMetainfo metainfo,
  required Set<int> selectedFileIndexes,
  required DiscoveryMediaKind kind,
  required bool importAfterDownload,
  String? coverUrl,
  String? metadataProvider,
  String? externalId,
}) async {
  if (!torrentBackendReady(appModel)) {
    // 远端只收磁链：单文件选择的种子走不了 host，本机又没后端——说清原因，
    // 而不是把用户引去配一个他刻意没配的本机后端。
    return appModel.prefsRepo.downloadExecutionHostUrl.isNotEmpty
        ? GenericPushOutcome.remoteMagnetOnly
        : GenericPushOutcome.notReady;
  }
  final VideoDownloadPipelineService? pipeline =
      appModel.videoDownloadPipelineService;
  if (pipeline == null) return GenericPushOutcome.storeUnavailable;
  await maybeShowTorrentUploadConsent(context, appModel);
  try {
    final VideoDownloadBackendTarget target =
        await appModel.currentVideoDownloadBackendTarget();
    await pipeline.enqueueManual(
      VideoDownloadManualEnqueueRequest(
        title: title,
        resourceTitle: resourceTitle,
        backendTarget: target,
        metainfo: metainfo,
        selectedFileIndexes: selectedFileIndexes,
        discoveryKind: kind,
        importAfterDownload: importAfterDownload,
        coverUrl: coverUrl,
        metadataProvider: metadataProvider,
        externalId: externalId,
      ),
    );
    return GenericPushOutcome.ok;
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('DiscoveryTorrent.enqueue', error, stack);
    return GenericPushOutcome.pushFailed;
  }
}

/// 把 [GenericPushOutcome] 映射成用户可读提示文案（i18n）。
String genericPushMessage(GenericPushOutcome outcome) {
  switch (outcome) {
    case GenericPushOutcome.ok:
      return t.discovery_download_queued;
    case GenericPushOutcome.invalidMagnet:
      return t.anime_download_magnet_invalid;
    case GenericPushOutcome.storeUnavailable:
      return t.anime_download_store_unavailable;
    case GenericPushOutcome.notReady:
      return t.download_backend_not_configured;
    case GenericPushOutcome.pushFailed:
      return t.download_request_failed;
    case GenericPushOutcome.remoteQueued:
      return t.download_execution_remote_queued;
    case GenericPushOutcome.remoteUnreachable:
      return t.download_execution_host_unreachable;
    case GenericPushOutcome.remoteKindUnsupported:
      return t.download_execution_remote_kind_unsupported;
    case GenericPushOutcome.remoteMagnetOnly:
      return t.download_execution_remote_magnet_only;
  }
}

/// 解析尚未触及下载后端；按数据边界提示恢复动作，避免误导用户修改 qB 设置。
String discoveryTorrentResolveFailureMessage(Object error) {
  if (error is CoreAudioFileMatchException) {
    return t.download_torrent_selection_failed;
  }
  if (error is FormatException) return t.download_torrent_invalid;
  return t.download_resource_resolve_failed;
}
