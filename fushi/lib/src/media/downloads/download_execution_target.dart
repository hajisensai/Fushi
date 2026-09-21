/// 「新下载任务在哪台设备上跑」的解析（设计 §3.3 的客户端侧）。
///
/// 用户在下载设置里把「下载执行设备」指到某台已配对的互联 host 后，手动添加任务、
/// 发现页种子、番剧对话框的通用磁链、资源搜索页四个入口都先问这里：解析成
/// [DownloadExecutionRemote] 就把磁链交给那台 host（`/api/downloads`），本机不碰
/// 下载后端；解析成 [DownloadExecutionUnreachable] 时**不**退回本机——用户点名的
/// 设备连不上要如实报，悄悄下到手机自己肚子里是更糟的结果。
///
/// 这一层刻意放在「下载后端」之上：后端回答的是「用什么引擎下」，这里回答的是
/// 「在哪台设备下」，手机不需要知道电脑用的是内置引擎还是外接 qBittorrent。
library;

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';

sealed class DownloadExecutionResolution {
  const DownloadExecutionResolution();
}

/// 偏好是本机（默认）。
class DownloadExecutionLocal extends DownloadExecutionResolution {
  const DownloadExecutionLocal();
}

/// 偏好指向的 host 在线且宣告代下载能力。
class DownloadExecutionRemote extends DownloadExecutionResolution {
  const DownloadExecutionRemote({required this.target, required this.client});

  final HostDownloadTarget target;
  final InterconnectDownloadClient client;
}

/// 偏好指向的 host 不在配对清单里 / 已停用 / 探不到 / 没宣告代下载能力。
class DownloadExecutionUnreachable extends DownloadExecutionResolution {
  const DownloadExecutionUnreachable({required this.url, this.deviceName});

  final String url;
  final String? deviceName;

  String get label => deviceName ?? url;
}

Future<DownloadExecutionResolution> resolveDownloadExecution(
  AppModel appModel, {
  InterconnectDownloadClient? client,
}) async {
  final String url = appModel.prefsRepo.downloadExecutionHostUrl;
  if (url.isEmpty) return const DownloadExecutionLocal();
  final SyncRepository repo = SyncRepository(appModel.database);
  final InterconnectDownloadClient resolved =
      client ?? InterconnectDownloadClient(repo: repo);
  HostDownloadTarget? target;
  try {
    target = await resolved.probeUrl(url);
  } catch (_) {
    target = null;
  }
  if (target != null) {
    return DownloadExecutionRemote(target: target, client: resolved);
  }
  String? deviceName;
  for (final FushiClientUrl u in await repo.getFushiClientUrls()) {
    if (u.url == url) deviceName = u.deviceName;
  }
  return DownloadExecutionUnreachable(url: url, deviceName: deviceName);
}
