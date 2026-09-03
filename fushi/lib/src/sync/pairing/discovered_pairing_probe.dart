import 'package:fushi/src/sync/pairing/fushi_ping_client.dart';
import 'package:fushi/src/sync/tls/fushi_tofu_probe.dart';

/// TODO-961: LAN 发现设备的「配对前探测」结果——探明的 base URL（含 scheme）、
/// https 钉扎指纹（明文 http 为 null）与 /api/ping 应答。
class DiscoveredPairingProbeResult {
  const DiscoveredPairingProbeResult({
    required this.baseUrl,
    required this.fingerprint,
    required this.ping,
  });

  /// 探明可用的 base URL（`https://host:port` 或 `http://host:port`）。
  final String baseUrl;

  /// https 路径的 TOFU 捕获指纹（ping 回传优先）；明文 http 为 null。
  final String? fingerprint;

  /// host 的 /api/ping 应答（isFushi 恒为 true，否则整体返回 null）。
  final FushiPingResult ping;
}

/// 发现配对的候选 base URL 顺序（纯函数，供单测）。
///
/// - TXT 广播了 `tls=1` → https 优先（host 只讲 https，http 必失败）。
/// - 未广播 / 旧版 host → http 优先；https 兜底覆盖「host 已开 TLS 但平台把
///   TXT 属性丢了」的情况（resolve 丢 TXT 在部分平台真实存在，见
///   `FushiDevice.fromResolvedService` 的 id 兜底注释）。
List<String> discoveredPairingCandidateUrls({
  required String host,
  required int port,
  required bool tlsAdvertised,
}) {
  final String https = 'https://$host:$port';
  final String http = 'http://$host:$port';
  return tlsAdvertised ? <String>[https, http] : <String>[http, https];
}

/// BUG-1741：整段探测的收口结果——探到的端点，或**为什么没探到**。
class DiscoveredPairingProbeOutcome {
  const DiscoveredPairingProbeOutcome.found(
    DiscoveredPairingProbeResult this.result, {
    required this.peerSpeaksTls,
  }) : failure = null;

  const DiscoveredPairingProbeOutcome.failed(
    FushiPingFailure this.failure, {
    required this.peerSpeaksTls,
  }) : result = null;

  /// 探到的可用端点；失败时为 null。
  final DiscoveredPairingProbeResult? result;

  /// 整段探测的失败原因（按严重度取最重的一条）；成功时为 null。
  final FushiPingFailure? failure;

  /// 探测过程中**确证**对端在该端口讲 TLS（TOFU 握手拿到了证书）。
  ///
  /// 调用方据此禁止回落 v1 明文配对：对一个 TLS-only 端口发明文 POST 必然失败，
  /// 回落只会把真实原因（证书 / 超时）换成一句无意义的「配对失败」。
  final bool peerSpeaksTls;
}

/// 失败原因的严重度：越靠前越该优先展示给用户。
///
/// tls 是安全事件，必须盖过后面几种；notFushi 最弱——只要有过任何一次
/// 「连得上但对不上」以外的失败，都比「这里没有 Hibiki」更接近真相。
const List<FushiPingFailure> _failureSeverity = <FushiPingFailure>[
  FushiPingFailure.tls,
  FushiPingFailure.timeout,
  FushiPingFailure.unreachable,
  FushiPingFailure.notFushi,
];

FushiPingFailure _worst(FushiPingFailure? a, FushiPingFailure b) {
  if (a == null) return b;
  return _failureSeverity.indexOf(a) <= _failureSeverity.indexOf(b) ? a : b;
}

/// 按候选顺序探测一台发现设备，返回第一个 ping 通的端点**或失败原因**。
///
/// https 候选先经 TOFU 一次性握手取指纹（取不到 → 记下原因并跳过该候选，绝不
/// 裸读 https），再用钉扎 ping 确认；明文 http 候选直接 ping。
///
/// [captureFingerprint] / [ping] 为测试注入缝，生产默认真实现。
Future<DiscoveredPairingProbeOutcome> probeDiscoveredPairingEndpointDetailed({
  required String host,
  required int port,
  required bool tlsAdvertised,
  Future<FushiTofuOutcome> Function(String host, int port)? captureFingerprint,
  Future<FushiPingOutcome> Function(String baseUrl,
          {String? pinnedFingerprint})?
      ping,
}) async {
  final Future<FushiTofuOutcome> Function(String host, int port) capture =
      captureFingerprint ??
          (String h, int p) => FushiTofuProbe.probeFingerprint(h, p);
  final Future<FushiPingOutcome> Function(String baseUrl,
          {String? pinnedFingerprint}) doPing =
      ping ??
          (String baseUrl, {String? pinnedFingerprint}) =>
              probeFushiPing(baseUrl, pinnedFingerprint: pinnedFingerprint);

  FushiPingFailure? worst;
  bool peerSpeaksTls = false;

  for (final String baseUrl in discoveredPairingCandidateUrls(
    host: host,
    port: port,
    tlsAdvertised: tlsAdvertised,
  )) {
    if (baseUrl.startsWith('https://')) {
      final FushiTofuOutcome tofu = await capture(host, port);
      if (tofu.speaksTls) peerSpeaksTls = true;
      final String? captured = tofu.fingerprint;
      if (captured == null || captured.isEmpty) {
        final FushiPingFailure? mapped = _tofuToPingFailure(tofu.failure);
        if (mapped != null) worst = _worst(worst, mapped);
        continue;
      }
      final FushiPingOutcome outcome =
          await doPing(baseUrl, pinnedFingerprint: captured);
      final FushiPingResult? result = outcome.result;
      if (result == null) {
        worst = _worst(worst, outcome.failure ?? FushiPingFailure.unreachable);
        continue;
      }
      // 钉扎指纹以 ping 回传为准（与捕获一致，钉扎 client 已保证）；回传缺失时
      // 用捕获值。https 必须有指纹才可用（镜像手动配对的硬约束）。
      final String? fingerprint = (result.fingerprint?.isNotEmpty ?? false)
          ? result.fingerprint
          : captured;
      return DiscoveredPairingProbeOutcome.found(
        DiscoveredPairingProbeResult(
          baseUrl: baseUrl,
          fingerprint: fingerprint,
          ping: result,
        ),
        peerSpeaksTls: true,
      );
    } else {
      final FushiPingOutcome outcome = await doPing(baseUrl);
      final FushiPingResult? result = outcome.result;
      if (result == null) {
        worst = _worst(worst, outcome.failure ?? FushiPingFailure.unreachable);
        continue;
      }
      return DiscoveredPairingProbeOutcome.found(
        DiscoveredPairingProbeResult(
          baseUrl: baseUrl,
          fingerprint: null,
          ping: result,
        ),
        peerSpeaksTls: peerSpeaksTls,
      );
    }
  }
  return DiscoveredPairingProbeOutcome.failed(
    worst ?? FushiPingFailure.unreachable,
    peerSpeaksTls: peerSpeaksTls,
  );
}

/// TOFU 失败原因 → ping 失败原因的归一（两套枚举面向同一个用户可见结论）。
///
/// 返回 null 表示**这次失败不构成证据**，不参与最终原因的评选。
FushiPingFailure? _tofuToPingFailure(FushiTofuFailure? failure) {
  switch (failure) {
    case FushiTofuFailure.timeout:
      return FushiPingFailure.timeout;
    case FushiTofuFailure.unreachable:
      return FushiPingFailure.unreachable;
    case FushiTofuFailure.notTls:
    case null:
      // 「该端口不讲 TLS」在一台明文 host 上正是预期结果，零信息量。若拿它去
      // 评选最终原因，会把 http 候选带回来的「连上了但不是 Hibiki」这种真正
      // 有用的结论盖掉。
      return null;
  }
}
