import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/pairing/discovered_pairing_probe.dart';
import 'package:hibiki/src/sync/pairing/hibiki_ping_client.dart';

/// TODO-961：发现配对的 scheme 选择 + 探测编排单测。
///
/// - 候选顺序纯函数：TXT `tls=1` → https 优先；未广播 → http 优先、https 兜底
///   （覆盖平台 resolve 丢 TXT 属性的真实情况）。
/// - 探测编排：https 先 TOFU 捕获指纹（取不到 → 跳过，绝不裸读 https）、钉扎
///   ping 定案；全部失败返回 null（调用方回落 v1 明文老路径）。
void main() {
  const HibikiPingResult v2TlsPing = HibikiPingResult(
    isHibiki: true,
    supportsPairV2: true,
    tlsEnabled: true,
    fingerprint: 'aa:bb:cc',
    deviceName: 'Host PC',
  );
  const HibikiPingResult v2PlainPing = HibikiPingResult(
    isHibiki: true,
    supportsPairV2: true,
    tlsEnabled: false,
  );

  group('discoveredPairingCandidateUrls', () {
    test('TXT 广播 tls=1 时 https 优先', () {
      expect(
        discoveredPairingCandidateUrls(
          host: '192.168.1.50',
          port: 38765,
          tlsAdvertised: true,
        ),
        <String>['https://192.168.1.50:38765', 'http://192.168.1.50:38765'],
      );
    });

    test('未广播 tls（旧版 host / TXT 被平台丢弃）时 http 优先、https 兜底', () {
      expect(
        discoveredPairingCandidateUrls(
          host: '192.168.1.50',
          port: 38765,
          tlsAdvertised: false,
        ),
        <String>['http://192.168.1.50:38765', 'https://192.168.1.50:38765'],
      );
    });
  });

  group('probeDiscoveredPairingEndpoint', () {
    test('tls host：TOFU 捕获指纹 → 钉扎 ping → 返回 https 端点', () async {
      final List<String> pingedUrls = <String>[];
      final List<String?> pingedPins = <String?>[];

      final DiscoveredPairingProbeResult? result =
          await probeDiscoveredPairingEndpoint(
        host: 'h',
        port: 38765,
        tlsAdvertised: true,
        captureFingerprint: (String host, int port) async => 'aa:bb:cc',
        ping: (String baseUrl, {String? pinnedFingerprint}) async {
          pingedUrls.add(baseUrl);
          pingedPins.add(pinnedFingerprint);
          return baseUrl.startsWith('https://') ? v2TlsPing : null;
        },
      );

      expect(result, isNotNull);
      expect(result!.baseUrl, 'https://h:38765');
      expect(result.fingerprint, 'aa:bb:cc');
      expect(result.ping.supportsPairV2, isTrue);
      // https 探测必须带钉扎指纹（绝不裸读 https）。
      expect(pingedUrls, <String>['https://h:38765']);
      expect(pingedPins, <String?>['aa:bb:cc']);
    });

    test('tls host 但指纹捕获失败：跳过 https（不裸读），回落 http 候选', () async {
      final List<String> pingedUrls = <String>[];

      final DiscoveredPairingProbeResult? result =
          await probeDiscoveredPairingEndpoint(
        host: 'h',
        port: 38765,
        tlsAdvertised: true,
        captureFingerprint: (String host, int port) async => null,
        ping: (String baseUrl, {String? pinnedFingerprint}) async {
          pingedUrls.add(baseUrl);
          return baseUrl.startsWith('http://') ? v2PlainPing : null;
        },
      );

      expect(result, isNotNull);
      expect(result!.baseUrl, 'http://h:38765');
      expect(result.fingerprint, isNull);
      // https 候选从未被 ping（捕获不到指纹就不许连）。
      expect(pingedUrls, <String>['http://h:38765']);
    });

    test('明文 host：http 直接 ping 通，https 兜底不被触发', () async {
      final List<String> pingedUrls = <String>[];

      final DiscoveredPairingProbeResult? result =
          await probeDiscoveredPairingEndpoint(
        host: 'h',
        port: 38765,
        tlsAdvertised: false,
        captureFingerprint: (String host, int port) async =>
            fail('明文 host ping 通后不应再做 TOFU 握手'),
        ping: (String baseUrl, {String? pinnedFingerprint}) async {
          pingedUrls.add(baseUrl);
          return baseUrl.startsWith('http://') ? v2PlainPing : null;
        },
      );

      expect(result, isNotNull);
      expect(result!.baseUrl, 'http://h:38765');
      expect(pingedUrls, <String>['http://h:38765']);
    });

    test('TXT 丢失但 host 已开 TLS：http 失败后 https 兜底探到', () async {
      final DiscoveredPairingProbeResult? result =
          await probeDiscoveredPairingEndpoint(
        host: 'h',
        port: 38765,
        tlsAdvertised: false,
        captureFingerprint: (String host, int port) async => 'aa:bb:cc',
        ping: (String baseUrl, {String? pinnedFingerprint}) async =>
            baseUrl.startsWith('https://') ? v2TlsPing : null,
      );

      expect(result, isNotNull);
      expect(result!.baseUrl, 'https://h:38765');
      expect(result.fingerprint, 'aa:bb:cc');
    });

    test('ping 未回传指纹时以 TOFU 捕获值钉扎', () async {
      const HibikiPingResult noFpPing = HibikiPingResult(
        isHibiki: true,
        supportsPairV2: true,
        tlsEnabled: true,
      );
      final DiscoveredPairingProbeResult? result =
          await probeDiscoveredPairingEndpoint(
        host: 'h',
        port: 38765,
        tlsAdvertised: true,
        captureFingerprint: (String host, int port) async => 'de:ad:be',
        ping: (String baseUrl, {String? pinnedFingerprint}) async =>
            baseUrl.startsWith('https://') ? noFpPing : null,
      );

      expect(result, isNotNull);
      expect(result!.fingerprint, 'de:ad:be');
    });

    test('两个 scheme 都探不通（旧 host 无 /api/ping）返回 null → 回落 v1', () async {
      final DiscoveredPairingProbeResult? result =
          await probeDiscoveredPairingEndpoint(
        host: 'h',
        port: 38765,
        tlsAdvertised: false,
        captureFingerprint: (String host, int port) async => null,
        ping: (String baseUrl, {String? pinnedFingerprint}) async => null,
      );

      expect(result, isNull);
    });
  });
}
