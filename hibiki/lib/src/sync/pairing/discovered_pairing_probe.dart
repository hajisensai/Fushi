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

  /// host 的 /api/ping 应答（isHibiki 恒为 true，否则整体返回 null）。
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

/// 按候选顺序探测一台发现设备，返回第一个 ping 通的端点。
///
/// https 候选先经 TOFU 一次性握手取指纹（取不到 → 跳过该候选，绝不裸读
/// https），再用钉扎 ping 确认；明文 http 候选直接 ping。全部失败返回 null
/// （调用方回落 v1 明文配对老路径，旧版 host 行为零变化）。
///
/// [captureFingerprint] / [ping] 为测试注入缝，生产默认真实现。
Future<DiscoveredPairingProbeResult?> probeDiscoveredPairingEndpoint({
  required String host,
  required int port,
  required bool tlsAdvertised,
  Future<String?> Function(String host, int port)? captureFingerprint,
  Future<FushiPingResult?> Function(String baseUrl,
          {String? pinnedFingerprint})?
      ping,
}) async {
  final Future<String?> Function(String host, int port) capture =
      captureFingerprint ??
          (String h, int p) => FushiTofuProbe.captureFingerprint(h, p);
  final Future<FushiPingResult?> Function(String baseUrl,
          {String? pinnedFingerprint}) doPing =
      ping ??
          (String baseUrl, {String? pinnedFingerprint}) =>
              fetchFushiPing(baseUrl, pinnedFingerprint: pinnedFingerprint);

  for (final String baseUrl in discoveredPairingCandidateUrls(
    host: host,
    port: port,
    tlsAdvertised: tlsAdvertised,
  )) {
    if (baseUrl.startsWith('https://')) {
      final String? captured = await capture(host, port);
      if (captured == null || captured.isEmpty) continue;
      final FushiPingResult? result =
          await doPing(baseUrl, pinnedFingerprint: captured);
      if (result == null) continue;
      // 钉扎指纹以 ping 回传为准（与捕获一致，钉扎 client 已保证）；回传缺失时
      // 用捕获值。https 必须有指纹才可用（镜像手动配对的硬约束）。
      final String? fingerprint = (result.fingerprint?.isNotEmpty ?? false)
          ? result.fingerprint
          : captured;
      return DiscoveredPairingProbeResult(
        baseUrl: baseUrl,
        fingerprint: fingerprint,
        ping: result,
      );
    } else {
      final FushiPingResult? result = await doPing(baseUrl);
      if (result == null) continue;
      return DiscoveredPairingProbeResult(
        baseUrl: baseUrl,
        fingerprint: null,
        ping: result,
      );
    }
  }
  return null;
}
