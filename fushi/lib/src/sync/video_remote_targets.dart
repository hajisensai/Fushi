import 'dart:async';

import 'package:fushi/src/sync/interconnect_peer_addresses.dart'
    show interconnectPeerRepresentatives;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_client.dart';

/// 一台可以从手机上操作的电脑：已配对、此刻可达、`/api/capabilities` 声明了所要的能力
/// （视频遥控 `videoRemoteControlV1`、复习远程刷卡 `srsRemoteReviewV1`）。[peer] 已补好凭据与
/// 证书指纹，可直接交给 [VideoRemoteClient] / `SrsRemoteReviewClient`。
class InterconnectHostTarget {
  const InterconnectHostTarget({
    required this.hostId,
    required this.displayName,
    required this.peer,
  });

  /// host 的稳定设备 id（同一台电脑的多条地址共用）。记住上次选择用它。
  final String hostId;

  /// 给用户看的名字：配对时记下的设备名，没有就用地址的主机部分。
  final String displayName;

  /// 遥控固定的对端（凭据按 BUG-1550 规则取、指纹按同 host 配对指纹补齐）。
  final FushiClientUrl peer;
}

/// 视频遥控的目标电脑。
typedef VideoRemoteTarget = InterconnectHostTarget;

/// 探一台对端是否声明某项能力。null = 没有应答（视为不可用）。
typedef InterconnectCapabilityProbe =
    Future<bool?> Function(SyncRepository repository, FushiClientUrl peer);

/// 视频遥控的能力探测。
typedef VideoRemoteCapabilityProbe = InterconnectCapabilityProbe;

Future<bool?> _defaultProbe(SyncRepository repository, FushiClientUrl peer) =>
    VideoRemoteClient(repository: repository, peer: peer).supportsVideoRemote();

/// 固定的对端：凭据按 BUG-1550 规则取；本行没有指纹（P2P 明文转发口等）
/// 时沿用同一台 host 的配对指纹，客户端据此拒绝任何不符的证书。
FushiClientUrl interconnectHostPeerFor(
  FushiClientUrl u,
  List<FushiClientUrl> allUrls,
  String? fallbackToken,
) {
  String? pin = u.fingerprintSha256;
  if ((pin == null || pin.isEmpty) && u.hostId != null) {
    for (final FushiClientUrl other in allUrls) {
      final String? fp = other.fingerprintSha256;
      if (other.hostId == u.hostId && fp != null && fp.isNotEmpty) {
        pin = fp;
        break;
      }
    }
  }
  return u.copyWith(
    token: interconnectTokenFor(u, fallbackToken),
    fingerprintSha256: pin,
  );
}

/// 列出此刻可以遥控的电脑（[probeInterconnectHostTargets] 按视频遥控能力探）。
Future<List<VideoRemoteTarget>> probeVideoRemoteTargets({
  required SyncRepository repository,
  VideoRemoteCapabilityProbe? probe,
  Duration timeout = const Duration(seconds: 6),
}) => probeInterconnectHostTargets(
  repository: repository,
  probe: probe ?? _defaultProbe,
  timeout: timeout,
);

/// 列出此刻声明了某项能力（[probe]）的电脑（每台 host 只一条，顺序同配对清单）。
///
/// 互联未启用、本机正在做互联 host（`serverEnabled`：host 本身不能再作为客户端
/// 连出去）时直接返回空。各 host 并发探测，单台超过 [timeout] 或探测抛错都静默
/// 视为不可用——入口只在确认可用时出现，不报错。没有 hostId 的老条目无法稳定
/// 认出是哪台电脑，不列。
Future<List<InterconnectHostTarget>> probeInterconnectHostTargets({
  required SyncRepository repository,
  required InterconnectCapabilityProbe probe,
  Duration timeout = const Duration(seconds: 6),
}) async {
  if (!await repository.isInterconnectEnabled()) {
    return const <VideoRemoteTarget>[];
  }
  if (await repository.isServerEnabled()) return const <VideoRemoteTarget>[];
  final List<FushiClientUrl> urls = await repository.getFushiClientUrls();
  final String? fallbackToken = await repository.getFushiClientToken();

  final List<FushiClientUrl> peers = <FushiClientUrl>[
    for (final FushiClientUrl u in interconnectPeerRepresentatives(
      urls.where((FushiClientUrl u) => u.enabled),
    ))
      if (u.hostId != null &&
          u.hostId!.isNotEmpty &&
          interconnectTokenFor(u, fallbackToken) != null)
        interconnectHostPeerFor(u, urls, fallbackToken),
  ];

  Future<bool> supported(FushiClientUrl peer) async {
    try {
      return await probe(repository, peer).timeout(timeout) == true;
    } catch (_) {
      return false;
    }
  }

  final List<bool> results = await Future.wait(peers.map(supported));
  return <InterconnectHostTarget>[
    for (int i = 0; i < peers.length; i++)
      if (results[i])
        InterconnectHostTarget(
          hostId: peers[i].hostId!,
          displayName: _displayNameOf(peers[i]),
          peer: peers[i],
        ),
  ];
}

String _displayNameOf(FushiClientUrl peer) {
  final String? name = peer.deviceName?.trim();
  if (name != null && name.isNotEmpty) return name;
  final String host = Uri.tryParse(peer.url)?.host ?? '';
  return host.isNotEmpty ? host : peer.url;
}
