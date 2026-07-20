import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/magnet_utils.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/torrent_upload_consent_dialog.dart';
import 'package:hibiki/utils.dart';

/// 通用磁力推送的结果（调用方据此弹提示）。
enum GenericPushOutcome {
  ok,
  invalidMagnet,
  storeUnavailable,
  notReady,
  pushFailed
}

/// 下载后端是否就绪：内置引擎宿主就绪（桌面 + DLL）且未显式选外接 qb → 就绪；
/// 否则走外接 qb，需填了地址。下载对话框与下载页共用同一判断（去重）。
bool torrentBackendReady(AppModel appModel) {
  final QbConnectionConfig config =
      appModel.qbConnectionConfig ?? const QbConnectionConfig();
  if (appModel.isEmbeddedTorrentReady &&
      config.backend != QbConnectionConfig.backendQbittorrent) {
    return true;
  }
  return config.baseUrl.trim().isNotEmpty;
}

/// 首次下载弹「上传/做种」一次性提示（默认关上传、询问开启、可配限速/时长/
/// 分享率）；确认后落偏好（即时应用到内置引擎）并置首用 flag。仅内置引擎相关。
Future<void> maybeShowTorrentUploadConsent(
  BuildContext context,
  AppModel appModel,
) async {
  final QbConnectionConfig config =
      appModel.qbConnectionConfig ?? const QbConnectionConfig();
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
}) async {
  if (!torrentBackendReady(appModel)) return GenericPushOutcome.notReady;
  final QbConnectionConfig config =
      appModel.qbConnectionConfig ?? const QbConnectionConfig();
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

/// 把 [GenericPushOutcome] 映射成用户可读提示文案（i18n）。
String genericPushMessage(GenericPushOutcome outcome) {
  switch (outcome) {
    case GenericPushOutcome.ok:
      return t.anime_download_pushed;
    case GenericPushOutcome.invalidMagnet:
      return t.anime_download_magnet_invalid;
    case GenericPushOutcome.storeUnavailable:
      return t.anime_download_store_unavailable;
    case GenericPushOutcome.notReady:
      return t.download_backend_not_configured;
    case GenericPushOutcome.pushFailed:
      return t.anime_download_push_failed;
  }
}
