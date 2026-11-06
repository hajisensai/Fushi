/// 「互联主机」AI 提供商的 app 侧出口（反馈 M8KvhMTHVS，wire 见
/// `package:fushi_engine/ai/ai_relay.dart`）：按 hostId 在配对表里找到那台主机，经
/// [InterconnectHostClient] 的鉴权通道（per-peer 口令 + 证书钉扎 + 同一台主机的多地址
/// 选路）POST 过去；连接层的各种失败折成 `relay_*` 短码，界面经 `aiFailureText` 说清楚。
library;

import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart'
    show interconnectPeerRepresentatives;
import 'package:fushi/src/sync/sync_backend.dart' show SyncAuthError;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_targets.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart' show AiChatFailure;
import 'package:fushi_engine/ai/ai_relay.dart';

/// 一次转发的整体时限：主机那边一次补全最多重试 3 轮（每轮 90 s 上限 + 退避），
/// 推理模型也确实慢；比主机侧的总预算宽一点，免得主机还在算、这边先放弃。
const Duration kAiRelayRequestTimeout = Duration(minutes: 6);

/// 把 [InterconnectHostClient] 的失败折成 `relay_*` 短码。
///
/// 404 / 405 = 主机没有这个端点（老版本 / 无头服务端没接线）；401 = 配对凭据被拒；
/// 其它非 2xx 原样报 `http_<码>`（`aiFailureText` 已有通用文案）。
AiChatFailure aiRelayFailureFor(Object error) => switch (error) {
  SyncAuthError() => const AiChatFailure(kAiRelayAuthRejected),
  InterconnectHostError(
    message: InterconnectHostError.certificateMismatchCode,
  ) =>
    const AiChatFailure(kAiRelayCertificateMismatch),
  InterconnectHostError(statusCode: null) => const AiChatFailure(
    kAiRelayHostUnreachable,
  ),
  InterconnectHostError(statusCode: 404 || 405) => const AiChatFailure(
    kAiRelayHostUnsupported,
  ),
  InterconnectHostError(statusCode: 401) => const AiChatFailure(
    kAiRelayAuthRejected,
  ),
  InterconnectHostError(:final int statusCode) => AiChatFailure(
    'http_$statusCode',
  ),
  _ => const AiChatFailure(kAiRelayHostUnreachable),
};

/// 配对表里 [hostId] 那台主机的代表条目（凭据、钉扎已补齐）；没有有效配对时 null。
Future<FushiClientUrl?> pairedInterconnectHostPeer(
  SyncRepository repository,
  String hostId,
) async {
  final List<FushiClientUrl> urls = await repository.getFushiClientUrls();
  final String? fallbackToken = await repository.getFushiClientToken();
  for (final FushiClientUrl u in interconnectPeerRepresentatives(
    urls.where((FushiClientUrl u) => u.enabled),
  )) {
    if (u.hostId == hostId && interconnectTokenFor(u, fallbackToken) != null) {
      return interconnectHostPeerFor(u, urls, fallbackToken);
    }
  }
  return null;
}

class AppAiRelayTransport implements AiRelayTransport {
  AppAiRelayTransport(
    this._repository, {
    InterconnectHostClient Function(FushiClientUrl peer)? clientFactory,
  }) : _clientFactory = clientFactory;

  final SyncRepository _repository;
  final InterconnectHostClient Function(FushiClientUrl peer)? _clientFactory;

  @override
  Future<Map<String, Object?>> post(
    String hostId,
    String path,
    Map<String, Object?> body,
  ) async {
    final FushiClientUrl? peer = await pairedInterconnectHostPeer(
      _repository,
      hostId,
    );
    if (peer == null) throw const AiChatFailure(kAiRelayHostNotPaired);
    final InterconnectHostClient client =
        _clientFactory?.call(peer) ??
        InterconnectHostClient(repository: _repository, peer: peer);
    try {
      return await client.postJson(
        path,
        body: body,
        timeout: kAiRelayRequestTimeout,
        authErrorMessage: 'AI relay authentication rejected',
      );
    } on SyncAuthError catch (e) {
      throw aiRelayFailureFor(e);
    } on InterconnectHostError catch (e) {
      throw aiRelayFailureFor(e);
    } finally {
      client.cancelPending();
    }
  }
}

/// 列出此刻开放了 AI 转发（[kAiRelayCapability]）的互联主机（设置页「添加提供商 ›
/// 互联主机」用）。
Future<List<InterconnectHostTarget>> probeAiRelayHostTargets(
  SyncRepository repository,
) => probeInterconnectHostTargets(
  repository: repository,
  probe: (SyncRepository repo, FushiClientUrl peer) => InterconnectHostClient(
    repository: repo,
    peer: peer,
  ).declaresCapability(kAiRelayCapability),
);
