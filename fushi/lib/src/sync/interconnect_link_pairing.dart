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
  const InterconnectLinkPaired({
    required this.baseUrl,
    this.deviceName,
    this.reassignedFromHostId,
  });

  /// 实际完成配对用的那条地址。
  final String baseUrl;
  final String? deviceName;

  /// 这条地址原本归哪台 host（用户确认「作为新设备配对」后改归链接里的 host）；
  /// 没有改归属为 null。调用方据此修正指向这条地址的偏好
  /// （`reconcileDownloadExecutionHostAfterReassign`）。
  final String? reassignedFromHostId;
}

/// [reason] 与 [FushiPairV2Failure.reason] 同一套词汇，另加：
/// - `unreachable`：链接里没有一条地址可达（或可达的不是链接里那台 host）。
/// - `fingerprint_changed`：本机已为这条地址钉扎的证书与链接里的指纹不符。
/// - `address_owner_conflict`：选中的地址已归另一台已配对 host，而用户没有确认
///   「作为新设备配对」（或调用方无法确认，如终端）。
final class InterconnectLinkPairingFailed
    extends InterconnectLinkPairingResult {
  const InterconnectLinkPairingFailed(this.reason);
  final String reason;
}

/// 一次 v2 配对成功后落库（BUG-4322：设置页手动地址、LAN 发现、扫码 / 深链三条入口共用这一份）：地址 + TOFU
/// 指纹 + host 展示名，再把 per-peer token 落到这台 host 的全部地址（53NT7G_tSO）。
///
/// [deviceName] 是 host 自报的展示名（`/api/ping` 的 `deviceName`，链接里的设备名）。以前设置页那两条入口在
/// 这里写死 null：手动地址配对的 host 没有名字，`peer ls` 不列名字、远程复习标题只剩 URL 主机名。
///
/// 已为这条地址钉扎的指纹与 [fingerprint] 不符时抛 [FushiFingerprintMismatchException]，绝不覆盖（疑似 MITM）。
///
/// [reassignOwner]：用户已确认把这条原属另一台 host 的地址改归新 host（V-A2）。此时这一行
/// 先脱离旧组（清掉旧 host 的展示名 / token）再记新 host 的指纹与展示名，否则旧组那一行
/// 会先被写上新 host 的名字；指纹在写 token 之前核对，不符就什么都不写。为 false 而这条
/// 地址已归另一台 host 时抛 [InterconnectAddressOwnerConflict]（确认与写入之间被并发
/// 改归），凭据不落库。
Future<void> recordInterconnectPairing(
  SyncRepository repo, {
  required String baseUrl,
  required String token,
  String? fingerprint,
  String? deviceName,
  String? hostId,
  bool reassignOwner = false,
}) async {
  final String? name = (deviceName?.trim().isNotEmpty ?? false)
      ? deviceName!.trim()
      : null;
  if (reassignOwner) {
    final String? stored = await repo.getFushiClientFingerprint(baseUrl);
    if (fingerprint != null &&
        fingerprint.isNotEmpty &&
        stored != null &&
        stored.isNotEmpty &&
        !fingerprintEquals(stored, fingerprint)) {
      throw FushiFingerprintMismatchException(
        url: baseUrl,
        storedFingerprint: stored,
        incomingFingerprint: fingerprint,
      );
    }
  } else {
    await repo.addFushiClientUrl(
      baseUrl,
      fingerprint: fingerprint,
      deviceName: name,
    );
  }
  await repo.setFushiClientTokenForUrl(
    baseUrl,
    token,
    hostId: hostId,
    reassignOwner: reassignOwner,
  );
  if (reassignOwner) {
    await repo.addFushiClientUrl(
      baseUrl,
      fingerprint: fingerprint,
      deviceName: name,
    );
  }
}

/// 链接能否并入已有的同 hostId 组：组不存在 → 能；存在 → 双方都有证书指纹且
/// 相等才能（指纹 = 那台 host 的私钥，冒名者给不出同一个）。
bool _linkMayJoinHostGroup(List<FushiClientUrl> urls, FushiPairLink link) {
  final Iterable<FushiClientUrl> group = urls.where(
    (FushiClientUrl u) => u.hostId == link.hostId,
  );
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
///
/// [confirmAddressReassign]：选中的地址已归另一台 host（地址归属闸）时问用户是否
/// 「作为新设备配对」，参数是那一行（带原归属与展示名）。为 null 或返回 false →
/// `address_owner_conflict`，不发配对请求、不写任何凭据。
Future<InterconnectLinkPairingResult> pairWithInterconnectLink({
  required SyncRepository repo,
  required FushiPairLink link,
  required String localDeviceName,
  required Future<String?> Function() pinProvider,
  InterconnectAddressProbe probe = defaultInterconnectAddressProbe,
  FushiPairV2Client Function(String baseUrl, String fingerprint)? clientFactory,
  Future<bool> Function(FushiClientUrl owner)? confirmAddressReassign,
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
  // 地址归属闸：这条 URL 已归另一台 host 时，没有用户确认就不配对——否则新 token
  // 会被写进那台 host 的整组（V-A2）。在发起配对之前判，失败不留任何副作用。
  final FushiClientUrl? owner = interconnectAddressOwnerConflict(
    await repo.getFushiClientUrls(),
    chosen.url,
    incomingHostId: link.hostId,
  );
  if (owner != null &&
      (confirmAddressReassign == null ||
          !await confirmAddressReassign(owner))) {
    return const InterconnectLinkPairingFailed('address_owner_conflict');
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
    // 设备钥匙照样证明：票据配对本身不授予「我的设备」，但 host 记下指纹后可手动标记。
    deviceKey: await repo.getOrCreateInterconnectDeviceKey(),
  );
  switch (outcome) {
    case FushiPairV2Failure(:final String reason):
      return InterconnectLinkPairingFailed(reason);
    case FushiPairV2Success(:final String token):
      // 53NT7G_tSO：新 token 同步到这台 host 的全部地址（重新配对作废了旧 token）。
      // 归组判据同下方 merge：指纹对不上就只改这一行。
      try {
        await recordInterconnectPairing(
          repo,
          baseUrl: chosen.url,
          token: token,
          fingerprint: fingerprint,
          deviceName: link.deviceName,
          hostId: link.hostId,
          reassignOwner: owner != null,
        );
      } on InterconnectAddressOwnerConflict catch (e) {
        // 确认与写入之间这条地址被并发改归了别的 host：如实报冲突，不写凭据。
        engineLog.logDiagnostic('InterconnectLinkPairing', '$e');
        return const InterconnectLinkPairingFailed('address_owner_conflict');
      } on FushiFingerprintMismatchException catch (e) {
        // 上面核对之后这条地址又被钉上了另一张证书：同样不覆盖。
        engineLog.logDiagnostic('InterconnectLinkPairing', '$e');
        return const InterconnectLinkPairingFailed('fingerprint_changed');
      }
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
          deviceName: link.deviceName,
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
        reassignedFromHostId: owner?.hostId,
      );
  }
}
