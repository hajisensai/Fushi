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

import 'package:meta/meta.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';
import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/interconnect_host_failure_text.dart';
import 'package:fushi/i18n/strings.g.dart';
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
  const DownloadExecutionRemote({
    required this.target,
    required this.client,
    this.ownsClient = false,
  });

  final HostDownloadTarget target;
  final InterconnectDownloadClient client;

  /// [client] 是 [resolveDownloadExecution] 自建的：用完由拿到本结果的一方
  /// [release]。调用方自己传入的 client 归调用方，这里不关。
  final bool ownsClient;

  /// 用完即调（`try/finally`）：关掉自建 client 的通道与连接。
  void release() {
    if (ownsClient) client.close();
  }
}

/// 偏好指向的 host 不在配对清单里 / 已停用 / 探不到 / 没宣告代下载能力。
class DownloadExecutionUnreachable extends DownloadExecutionResolution {
  const DownloadExecutionUnreachable({
    required this.url,
    this.deviceName,
    this.failure = InterconnectHostFailure.unreachable,
    this.statusCode,
  });

  final String url;
  final String? deviceName;

  /// 探测失败的原因（凭据失效 / 证书不符 / 版本旧或能力没开 / 连不上…）。
  final InterconnectHostFailure failure;

  /// [failure] 为 [InterconnectHostFailure.httpError] 时 host 回的状态码。
  final int? statusCode;

  String get label => deviceName ?? url;
}

Future<DownloadExecutionResolution> resolveDownloadExecution(
  AppModel appModel, {
  InterconnectDownloadClient? client,
}) => resolveDownloadExecutionFor(
  url: appModel.prefsRepo.downloadExecutionHostUrl,
  repo: SyncRepository(appModel.database),
  client: client,
);

InterconnectDownloadClient _defaultDownloadClient(SyncRepository repo) =>
    InterconnectDownloadClient(repo: repo);

/// [resolveDownloadExecution] 的本体：[url] 是「下载执行设备」偏好。
/// [createClient] 只在没传 [client] 时用（测试缝）。
Future<DownloadExecutionResolution> resolveDownloadExecutionFor({
  required String url,
  required SyncRepository repo,
  InterconnectDownloadClient? client,
  @visibleForTesting
  InterconnectDownloadClient Function(SyncRepository repo) createClient =
      _defaultDownloadClient,
}) async {
  if (url.isEmpty) return const DownloadExecutionLocal();
  // 传入的 client 归调用方；自建的走 Local / Unreachable 前关掉，走 Remote 时
  // 交给结果（[DownloadExecutionRemote.release]）。
  final bool owns = client == null;
  final InterconnectDownloadClient resolved = client ?? createClient(repo);
  // 「这台设备还在不在配对清单里」要先于「能不能探到」判：偏好里存的是一个 URL，
  // 用户解绑那台 host / 禁用那条 client URL 之后，设置页的下拉整块不再渲染
  // （它只在有已配对 host 时出现），偏好就永远停在那个死地址——此后每一次发现页
  // 下载、番剧对话框磁链都恒返回「执行设备连不上」，而 UI 里没有任何地方能把它
  // 改回本机。配对关系都没有了就不该再守着它：退回本机。
  // 「在清单里但此刻探不到」仍按原语义拒绝（不静默改在别的机器上下载）。
  // 按「那台 host」判：同一台 host 的地址会随它换 IP 被自动增删，偏好里那一条
  // 恰好被删不等于解绑了这台设备。
  final FushiClientUrl? paired = interconnectPeerRepresentativeOf(
    await repo.getFushiClientUrls(),
    url,
  );
  if (paired == null) {
    if (owns) resolved.close();
    return const DownloadExecutionLocal();
  }
  final String? deviceName = paired.deviceName;
  // 探「那台 host」（组内选路），带回失败原因：凭据失效、证书变了、版本旧 / 没开
  // 代下载都要如实说，而不是一律「连不上」。
  final InterconnectCapabilityOutcome<HostDownloadTarget> outcome;
  try {
    outcome = await resolved.probeHost(InterconnectHostRef.ofRow(paired));
  } on Object {
    if (owns) resolved.close();
    rethrow;
  }
  switch (outcome) {
    case InterconnectCapabilityAvailable<HostDownloadTarget>(:final target):
      return DownloadExecutionRemote(
        target: target,
        client: resolved,
        ownsClient: owns,
      );
    case InterconnectCapabilityUnavailable<HostDownloadTarget>(
      :final failure,
      :final statusCode,
    ):
      if (owns) resolved.close();
      return DownloadExecutionUnreachable(
        url: url,
        deviceName: deviceName,
        failure: failure,
        statusCode: statusCode,
      );
  }
}

/// [DownloadExecutionUnreachable] 的提示：原因是用户能动手解决的（重新配对、证书、
/// 版本 / 能力）就带设备名说出来，单纯连不上沿用原文案。
String downloadExecutionUnreachableMessage(DownloadExecutionUnreachable u) =>
    interconnectHostFailureWorthTelling(u.failure)
    ? interconnectHostFailureLine(
        u.failure,
        device: u.label,
        statusCode: u.statusCode,
      )
    : t.download_execution_host_unreachable;

/// [url] 刚从 [previousHostId] 改归别的 host（地址归属闸里用户确认了「作为新设备
/// 配对」）：偏好正指向它时改写为旧 host 剩余的代表地址；旧 host 一条地址都不剩
/// → 清空（回本机，与 [resolveDownloadExecution]「解绑后回本机」同一语义）。偏好
/// 按 URL 存，不改写就会把下载静默投给新 host。[rowsAfter] 是改归属后的地址列表。
Future<void> reconcileDownloadExecutionHostAfterReassign(
  PreferencesRepository prefs,
  List<FushiClientUrl> rowsAfter, {
  required String url,
  required String previousHostId,
}) async {
  if (prefs.downloadExecutionHostUrl != url) return;
  final List<FushiClientUrl> previous = rowsAfter
      .where((FushiClientUrl u) => u.hostId == previousHostId)
      .toList(growable: false);
  final List<FushiClientUrl> reps = interconnectPeerRepresentatives(previous);
  await prefs.setDownloadExecutionHostUrl(reps.isEmpty ? '' : reps.first.url);
}
