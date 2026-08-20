import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/pairing/discovered_pairing_probe.dart';
import 'package:fushi/src/sync/pairing/fushi_ping_client.dart';
import 'package:fushi/src/sync/tls/fushi_tofu_probe.dart';

/// TODO-961：发现配对的 scheme 选择 + 探测编排单测。
///
/// - 候选顺序纯函数：TXT `tls=1` → https 优先；未广播 → http 优先、https 兜底
///   （覆盖平台 resolve 丢 TXT 属性的真实情况）。
/// - 探测编排：https 先 TOFU 捕获指纹（取不到 → 跳过，绝不裸读 https）、钉扎
///   ping 定案。
/// - BUG-1741：探测失败不再压平成一个裸 null——要带出**为什么**失败，以及是否
///   确证对端讲 TLS（后者决定调用方能不能回落 v1 明文配对）。
void main() {
  const FushiPingResult v2TlsPing = FushiPingResult(
    isFushi: true,
    supportsPairV2: true,
    tlsEnabled: true,
    fingerprint: 'aa:bb:cc',
    deviceName: 'Host PC',
  );
  const FushiPingResult v2PlainPing = FushiPingResult(
    isFushi: true,
    supportsPairV2: true,
    tlsEnabled: false,
  );
  const FushiPingOutcome unreachable =
      FushiPingOutcome.failed(FushiPingFailure.unreachable);

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

  // BUG-1741 收尾（PR#912 审查）：丢原因的薄封装 probeDiscoveredPairingEndpoint
  // 已删除，本组「只关心探到哪个端点」的用例直接读 Outcome.result。
  group('probeDiscoveredPairingEndpointDetailed（端点选择）', () {
    test('tls host：TOFU 捕获指纹 → 钉扎 ping → 返回 https 端点', () async {
      final List<String> pingedUrls = <String>[];
      final List<String?> pingedPins = <String?>[];

      final DiscoveredPairingProbeResult? result =
          (await probeDiscoveredPairingEndpointDetailed(
        host: 'h',
        port: 38765,
        tlsAdvertised: true,
        captureFingerprint: (String host, int port) async =>
            const FushiTofuOutcome.captured('aa:bb:cc'),
        ping: (String baseUrl, {String? pinnedFingerprint}) async {
          pingedUrls.add(baseUrl);
          pingedPins.add(pinnedFingerprint);
          return baseUrl.startsWith('https://')
              ? const FushiPingOutcome.ok(v2TlsPing)
              : unreachable;
        },
      ))
              .result;

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
          (await probeDiscoveredPairingEndpointDetailed(
        host: 'h',
        port: 38765,
        tlsAdvertised: true,
        captureFingerprint: (String host, int port) async =>
            const FushiTofuOutcome.failed(FushiTofuFailure.unreachable),
        ping: (String baseUrl, {String? pinnedFingerprint}) async {
          pingedUrls.add(baseUrl);
          return baseUrl.startsWith('http://')
              ? const FushiPingOutcome.ok(v2PlainPing)
              : unreachable;
        },
      ))
              .result;

      expect(result, isNotNull);
      expect(result!.baseUrl, 'http://h:38765');
      expect(result.fingerprint, isNull);
      // https 候选从未被 ping（捕获不到指纹就不许连）。
      expect(pingedUrls, <String>['http://h:38765']);
    });

    test('明文 host：http 直接 ping 通，https 兜底不被触发', () async {
      final List<String> pingedUrls = <String>[];

      final DiscoveredPairingProbeResult? result =
          (await probeDiscoveredPairingEndpointDetailed(
        host: 'h',
        port: 38765,
        tlsAdvertised: false,
        captureFingerprint: (String host, int port) async =>
            fail('明文 host ping 通后不应再做 TOFU 握手'),
        ping: (String baseUrl, {String? pinnedFingerprint}) async {
          pingedUrls.add(baseUrl);
          return baseUrl.startsWith('http://')
              ? const FushiPingOutcome.ok(v2PlainPing)
              : unreachable;
        },
      ))
              .result;

      expect(result, isNotNull);
      expect(result!.baseUrl, 'http://h:38765');
      expect(pingedUrls, <String>['http://h:38765']);
    });

    test('TXT 丢失但 host 已开 TLS：http 失败后 https 兜底探到', () async {
      final DiscoveredPairingProbeResult? result =
          (await probeDiscoveredPairingEndpointDetailed(
        host: 'h',
        port: 38765,
        tlsAdvertised: false,
        captureFingerprint: (String host, int port) async =>
            const FushiTofuOutcome.captured('aa:bb:cc'),
        ping: (String baseUrl, {String? pinnedFingerprint}) async =>
            baseUrl.startsWith('https://')
                ? const FushiPingOutcome.ok(v2TlsPing)
                : unreachable,
      ))
              .result;

      expect(result, isNotNull);
      expect(result!.baseUrl, 'https://h:38765');
      expect(result.fingerprint, 'aa:bb:cc');
    });

    test('ping 未回传指纹时以 TOFU 捕获值钉扎', () async {
      const FushiPingResult noFpPing = FushiPingResult(
        isFushi: true,
        supportsPairV2: true,
        tlsEnabled: true,
      );
      final DiscoveredPairingProbeResult? result =
          (await probeDiscoveredPairingEndpointDetailed(
        host: 'h',
        port: 38765,
        tlsAdvertised: true,
        captureFingerprint: (String host, int port) async =>
            const FushiTofuOutcome.captured('de:ad:be'),
        ping: (String baseUrl, {String? pinnedFingerprint}) async =>
            baseUrl.startsWith('https://')
                ? const FushiPingOutcome.ok(noFpPing)
                : unreachable,
      ))
              .result;

      expect(result, isNotNull);
      expect(result!.fingerprint, 'de:ad:be');
    });

    test('两个 scheme 都探不通（旧 host 无 /api/ping）返回 null', () async {
      final DiscoveredPairingProbeResult? result =
          (await probeDiscoveredPairingEndpointDetailed(
        host: 'h',
        port: 38765,
        tlsAdvertised: false,
        captureFingerprint: (String host, int port) async =>
            const FushiTofuOutcome.failed(FushiTofuFailure.unreachable),
        ping: (String baseUrl, {String? pinnedFingerprint}) async =>
            unreachable,
      ))
              .result;

      expect(result, isNull);
    });
  });

  // BUG-1741：这一组是「配对报错文案完全误导」的根：探测层此前把所有失败压成
  // 一个 null，调用方既不知道为什么失败，也不知道对端到底讲不讲 TLS——于是把
  // TLS host 一律推进 v1 明文死路，最后只能说一句「配对失败」。
  group('probeDiscoveredPairingEndpointDetailed（失败原因 + TLS 确证）', () {
    test('钉扎失败：带出 tls 原因，且确证对端讲 TLS（禁止回落 v1）', () async {
      final DiscoveredPairingProbeOutcome outcome =
          await probeDiscoveredPairingEndpointDetailed(
        host: 'h',
        port: 38765,
        tlsAdvertised: true,
        captureFingerprint: (String host, int port) async =>
            const FushiTofuOutcome.captured('aa:bb:cc'),
        ping: (String baseUrl, {String? pinnedFingerprint}) async =>
            const FushiPingOutcome.failed(FushiPingFailure.tls),
      );

      expect(outcome.result, isNull);
      expect(outcome.failure, FushiPingFailure.tls);
      // TOFU 握手成功过 → 对端确实在讲 TLS。明文 v1 打过去必然失败。
      expect(outcome.peerSpeaksTls, isTrue);
    });

    test('TXT 丢了 tls 标志：http 先失败，https 握手成功也算确证讲 TLS', () async {
      final DiscoveredPairingProbeOutcome outcome =
          await probeDiscoveredPairingEndpointDetailed(
        host: 'h',
        port: 38765,
        tlsAdvertised: false,
        captureFingerprint: (String host, int port) async =>
            const FushiTofuOutcome.captured('aa:bb:cc'),
        ping: (String baseUrl, {String? pinnedFingerprint}) async =>
            const FushiPingOutcome.failed(FushiPingFailure.timeout),
      );

      expect(outcome.result, isNull);
      expect(outcome.peerSpeaksTls, isTrue);
    });

    test('真·旧版明文 host：没有任何 TLS 证据，允许回落 v1', () async {
      final DiscoveredPairingProbeOutcome outcome =
          await probeDiscoveredPairingEndpointDetailed(
        host: 'h',
        port: 38765,
        tlsAdvertised: false,
        captureFingerprint: (String host, int port) async =>
            const FushiTofuOutcome.failed(FushiTofuFailure.notTls),
        ping: (String baseUrl, {String? pinnedFingerprint}) async =>
            const FushiPingOutcome.failed(FushiPingFailure.notFushi),
      );

      expect(outcome.result, isNull);
      expect(outcome.peerSpeaksTls, isFalse);
      expect(outcome.failure, FushiPingFailure.notFushi);
    });

    test('多候选失败时取最严重的原因：tls 盖过 unreachable', () async {
      final DiscoveredPairingProbeOutcome outcome =
          await probeDiscoveredPairingEndpointDetailed(
        host: 'h',
        port: 38765,
        tlsAdvertised: true,
        captureFingerprint: (String host, int port) async =>
            const FushiTofuOutcome.captured('aa:bb:cc'),
        ping: (String baseUrl, {String? pinnedFingerprint}) async =>
            baseUrl.startsWith('https://')
                ? const FushiPingOutcome.failed(FushiPingFailure.tls)
                : unreachable,
      );

      expect(outcome.failure, FushiPingFailure.tls);
    });

    test('探测成功时不带失败原因', () async {
      final DiscoveredPairingProbeOutcome outcome =
          await probeDiscoveredPairingEndpointDetailed(
        host: 'h',
        port: 38765,
        tlsAdvertised: true,
        captureFingerprint: (String host, int port) async =>
            const FushiTofuOutcome.captured('aa:bb:cc'),
        ping: (String baseUrl, {String? pinnedFingerprint}) async =>
            const FushiPingOutcome.ok(v2TlsPing),
      );

      expect(outcome.failure, isNull);
      expect(outcome.result?.baseUrl, 'https://h:38765');
      expect(outcome.peerSpeaksTls, isTrue);
    });
  });
}
