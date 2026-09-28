import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_v2_client.dart';
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart'
    show fingerprintEquals;

/// 扫码 / 深链 / NFC 配对的编排（与 UI 无关；设置页与根级深链处理共用一份）。
/// 设计见 docs/specs/2026-09-28-interconnect-remote-reach.md §4。
///
/// 与手动输地址的配对相比只省两件事：地址（链接里一整套，并发挑可达的那条）和
/// 证书指纹（带外到达，不必 TOFU）。PIN / 审批的判据仍在 host：带票据的链接用
/// secret 代替 PIN，不带票据的（NFC 贴纸）照常要 host 审批 + 按需 PIN。
sealed class InterconnectLinkPairingResult {
  const InterconnectLinkPairingResult();
}

final class InterconnectLinkPaired extends InterconnectLinkPairingResult {
  const InterconnectLinkPaired({required this.baseUrl, this.deviceName});

  /// 实际完成配对用的那条地址。
  final String baseUrl;
  final String? deviceName;
}

/// [reason] 与 [FushiPairV2Failure.reason] 同一套词汇，另加：
/// - `unreachable`：链接里没有一条地址可达（或可达的不是链接里那台 host）。
/// - `fingerprint_changed`：本机已为这条地址钉扎的证书与链接里的指纹不符。
final class InterconnectLinkPairingFailed
    extends InterconnectLinkPairingResult {
  const InterconnectLinkPairingFailed(this.reason);
  final String reason;
}

/// 链接能否并入已有的同 hostId 组：组不存在 → 能；存在 → 双方都有证书指纹且
/// 相等才能（指纹 = 那台 host 的私钥，冒名者给不出同一个）。
bool _linkMayJoinHostGroup(List<FushiClientUrl> urls, FushiPairLink link) {
  final Iterable<FushiClientUrl> group =
      urls.where((FushiClientUrl u) => u.hostId == link.hostId);
  if (group.isEmpty) return true;
  final String? linkFp = link.fingerprint;
  if (linkFp == null || linkFp.isEmpty) return false;
  for (final FushiClientUrl u in group) {
    final String? fp = u.fingerprintSha256;
    if (fp != null && fp.isNotEmpty) return fingerprintEquals(fp, linkFp);
  }
  return false;
}

/// 把链接里的地址转成候选（https 的带上链接给的指纹；P2P 地址这里不参与——
/// 配对必须经可直接 HTTP 到达的地址，隧道只在配对后作为已配对 host 的备用路径）。
List<FushiClientUrl> interconnectLinkCandidates(FushiPairLink link) =>
    <FushiClientUrl>[
      for (final InterconnectHostAddress a in link.addresses)
        if (a.kind != InterconnectAddressKind.p2p)
          FushiClientUrl(
            url: a.url,
            fingerprintSha256: a.url.toLowerCase().startsWith('https://')
                ? link.fingerprint
                : null,
            deviceName: link.deviceName,
            hostId: link.hostId,
          ),
    ];

/// 按链接完成一次配对，并把链接里的其余地址记为该 host 的 learned 地址。
///
/// [pinProvider] 只在链接不带票据、而 host 又要求 PIN 时被调用（NFC 贴纸跨网段）。
/// 调用方在调本函数**之前**必须已让用户确认「连接到 <设备名>」：链接可能来自任何
/// 网页，不经确认就配对等于让一个链接把本机库同步给陌生 host。
Future<InterconnectLinkPairingResult> pairWithInterconnectLink({
  required SyncRepository repo,
  required FushiPairLink link,
  required String localDeviceName,
  required Future<String?> Function() pinProvider,
  InterconnectAddressProbe probe = defaultInterconnectAddressProbe,
  FushiPairV2Client Function(String baseUrl, String fingerprint)? clientFactory,
}) async {
  final FushiClientUrl? chosen = await raceInterconnectHostAddresses(
    interconnectLinkCandidates(link),
    hostId: link.hostId,
    probe: probe,
  );
  if (chosen == null) {
    return const InterconnectLinkPairingFailed('unreachable');
  }
  final String? fingerprint = chosen.fingerprintSha256;
  final String? stored = await repo.getFushiClientFingerprint(chosen.url);
  if (fingerprint != null &&
      stored != null &&
      stored.isNotEmpty &&
      !fingerprintEquals(stored, fingerprint)) {
    return const InterconnectLinkPairingFailed('fingerprint_changed');
  }

  final FushiPairV2Client client =
      (clientFactory ??
      (String baseUrl, String fp) => FushiPairV2Client(
        baseUrl: baseUrl,
        expectedFingerprint: fp,
      ))(chosen.url, fingerprint ?? '');
  final String? secret = link.hasTicket ? link.ticketSecret : null;
  final FushiPairV2Outcome outcome = await client.pair(
    deviceName: localDeviceName,
    pinProvider: secret != null ? () async => secret : pinProvider,
    clientDeviceId: await repo.getOrCreateDeviceId(),
    ticketId: link.hasTicket ? link.ticketId : null,
  );
  switch (outcome) {
    case FushiPairV2Failure(:final String reason):
      return InterconnectLinkPairingFailed(reason);
    case FushiPairV2Success(:final String token):
      await repo.addFushiClientUrl(
        chosen.url,
        fingerprint: fingerprint,
        deviceName: link.deviceName,
      );
      await repo.setFushiClientTokenForUrl(chosen.url, token);
      await repo.updateFushiClientUrls((List<FushiClientUrl> urls) {
        // hostId 是公开值：链接可以随便声称自己是某台已配对 host。只有证书指纹
        // 对得上（同一把私钥）才并入那一组；否则只按普通配对留下这一条地址——
        // 不打 hostId、不学地址，更不删真 host 的地址（审查问题 7）。
        if (!_linkMayJoinHostGroup(urls, link)) return urls;
        return mergeLearnedHostAddresses(
          urls,
          anchorUrl: chosen.url,
          hostId: link.hostId,
          addresses: link.addresses,
        );
      });
      await repo.setInterconnectEnabled(true);
      // 链接里的地址是二维码生成那一刻的快照；配对后再从 host 学一次最新的。
      for (final FushiClientUrl u in await repo.getFushiClientUrls()) {
        if (u.url == chosen.url) {
          InterconnectAddressLearner(repo).refreshInBackground(u);
          break;
        }
      }
      engineLog.logDiagnostic(
        'InterconnectLinkPairing',
        'paired via ${chosen.url} (ticket=${link.hasTicket})',
      );
      return InterconnectLinkPaired(
        baseUrl: chosen.url,
        deviceName: link.deviceName,
      );
  }
}
