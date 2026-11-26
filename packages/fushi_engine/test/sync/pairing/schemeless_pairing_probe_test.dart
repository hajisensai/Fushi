import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/sync/pairing/discovered_pairing_probe.dart';
import 'package:fushi_engine/sync/pairing/fushi_ping_client.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:test/test.dart';

/// BUG-5519：手动输入不带 scheme 的地址（`host:port`）配对 TLS host 时，旧实现
/// 把它补成 `http://` 再探测。TLS host 只 `bindSecure`，明文 ping 打上去：直连时
/// 被立刻断开，隔一层不传递断开的端口转发（容器 / NAT 映射）时挂到超时，UI 说
/// 「对端没在时限内应答」。这里全部用真 socket：真 TLS host、真明文 host、以及
/// 一个模拟「不把后端断开传回客户端」的 TCP 转发器。
void main() {
  late SecurityContext tlsContext;

  setUpAll(() {
    final ({String certificatePem, String privateKeyPem}) cert =
        FushiSelfSignedCertGenerator.generate(
          commonName: 'fushi-test',
          sanIpAddresses: <String>['127.0.0.1'],
        );
    tlsContext = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(cert.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(cert.privateKeyPem));
  });

  void servePing(HttpServer server, {required bool tls}) {
    server.listen((HttpRequest request) {
      final String body = jsonEncode(<String, Object?>{
        'app': 'fushi',
        'pairing': <String, Object?>{'v2': true},
        'tls': <String, Object?>{'enabled': tls},
        'deviceName': 'Test host',
        'hostId': 'host-1',
      });
      request.response
        ..headers.contentType = ContentType.json
        ..contentLength = utf8.encode(body).length
        ..write(body);
      unawaited(request.response.close());
    });
  }

  /// TCP 转发器：两向照搬字节，但**后端断开时不关客户端**——容器 / NAT 端口
  /// 映射里真实存在的那种转发链路。
  Future<ServerSocket> startNonClosingForwarder(int backendPort) async {
    final ServerSocket forwarder = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    forwarder.listen((Socket client) async {
      final Socket backend = await Socket.connect(
        InternetAddress.loopbackIPv4,
        backendPort,
      );
      client.listen(
        backend.add,
        onDone: () => backend.destroy(),
        onError: (Object _) => backend.destroy(),
      );
      backend.listen(client.add, onDone: () {}, onError: (Object _) {});
    });
    return forwarder;
  }

  group('schemelessPairingCandidates', () {
    test('https 优先、http 兜底，host/port 取自地址', () {
      final List<FushiPairingCandidate> c = schemelessPairingCandidates(
        '192.0.2.10:48765',
      );
      expect(c.map((FushiPairingCandidate e) => e.baseUrl), <String>[
        'https://192.0.2.10:48765',
        'http://192.0.2.10:48765',
      ]);
      expect(c.first.host, '192.0.2.10');
      expect(c.first.port, 48765);
    });

    test('没写端口时各用 scheme 默认端口', () {
      final List<FushiPairingCandidate> c = schemelessPairingCandidates(
        'host.example',
      );
      expect(c.first.port, 443);
      expect(c.last.port, 80);
    });
  });

  group('TLS-only host（真 socket）', () {
    late HttpServer tlsHost;

    setUp(() async {
      tlsHost = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        tlsContext,
      );
      servePing(tlsHost, tls: true);
    });

    tearDown(() => tlsHost.close(force: true));

    test('直连：明文 ping 被断开 → 归 unreachable，不归 timeout', () async {
      final FushiPingOutcome outcome = await probeFushiPing(
        'http://127.0.0.1:${tlsHost.port}',
        timeout: const Duration(seconds: 10),
      );
      expect(outcome.isOk, isFalse);
      expect(outcome.failure, FushiPingFailure.unreachable);
    });

    test('隔着不传递断开的转发器：明文 ping 挂到超时（旧路径的根因复现）', () async {
      final ServerSocket forwarder = await startNonClosingForwarder(
        tlsHost.port,
      );
      addTearDown(forwarder.close);
      final FushiPingOutcome outcome = await probeFushiPing(
        'http://127.0.0.1:${forwarder.port}',
        timeout: const Duration(milliseconds: 800),
      );
      expect(outcome.failure, FushiPingFailure.timeout);
    });

    test('无 scheme 地址：直连 TLS host 探到 https 端点 + 指纹', () async {
      final DiscoveredPairingProbeOutcome outcome =
          await probeFushiPairingCandidates(
            schemelessPairingCandidates('127.0.0.1:${tlsHost.port}'),
          );
      final DiscoveredPairingProbeResult? probe = outcome.result;
      expect(probe, isNotNull, reason: 'failure=${outcome.failure}');
      expect(probe!.baseUrl, 'https://127.0.0.1:${tlsHost.port}');
      expect(probe.fingerprint, isNotEmpty);
      expect(probe.ping.supportsPairV2, isTrue);
      expect(probe.ping.hostId, 'host-1');
      expect(outcome.peerSpeaksTls, isTrue);
    });

    test('无 scheme 地址：隔着不传递断开的转发器也探到 https，不超时', () async {
      final ServerSocket forwarder = await startNonClosingForwarder(
        tlsHost.port,
      );
      addTearDown(forwarder.close);
      final Stopwatch sw = Stopwatch()..start();
      final DiscoveredPairingProbeOutcome outcome =
          await probeFushiPairingCandidates(
            schemelessPairingCandidates('127.0.0.1:${forwarder.port}'),
          );
      expect(outcome.result?.baseUrl, 'https://127.0.0.1:${forwarder.port}');
      expect(outcome.result?.fingerprint, isNotEmpty);
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 4)),
        reason: 'https 先试就不该碰明文那条会挂住的路',
      );
    });
  });

  group('明文 host（真 socket）', () {
    test('无 scheme 地址：TLS 握手被拒后回落 http 端点', () async {
      final HttpServer plainHost = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => plainHost.close(force: true));
      servePing(plainHost, tls: false);

      final Stopwatch sw = Stopwatch()..start();
      final DiscoveredPairingProbeOutcome outcome =
          await probeFushiPairingCandidates(
            schemelessPairingCandidates('127.0.0.1:${plainHost.port}'),
          );
      final DiscoveredPairingProbeResult? probe = outcome.result;
      expect(probe, isNotNull, reason: 'failure=${outcome.failure}');
      expect(probe!.baseUrl, 'http://127.0.0.1:${plainHost.port}');
      expect(probe.fingerprint, isNull);
      expect(outcome.peerSpeaksTls, isFalse);
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 4)),
        reason: '明文 host 对 TLS 握手应立刻拒绝，不该等满 TOFU 超时',
      );
    });
  });
}
