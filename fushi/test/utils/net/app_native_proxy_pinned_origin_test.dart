import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

/// BUG-2448：互联 host 的自签 https 流不再交给 native 自己去做 TLS——URL 经
/// [nativePlaybackUri] 降成明文 http，中继按登记的 (host, port) 指纹升回钉扎 https。
///
/// 这里用真自签证书起一个 https 原点，从中继的 loopback 入口以 native 播放器的
/// 请求形状（absolute-form GET + Proxy-Authorization）走一遍，证明：
///  - 指纹相符 → 200/206 原样透传（Range 是 libmpv 取流的基本形状）；
///  - 指纹不符 → 502（绝不放行任意自签证书）；
///  - 未登记 → 明文直连 https 端口，必失败（说明「登记」是唯一放行条件）。
void main() {
  late AppNativeProxy relay;
  late HttpServer origin;
  late String fingerprint;
  late String Function() oldMode;
  final List<int> body = List<int>.generate(4096, (int i) => i % 251);

  setUp(() async {
    oldMode = appUserProxyModeReader;
    appUserProxyModeReader = () => kProxyModeDirect;
    clearPinnedNativeOriginsForTesting();
    final ({String certificatePem, String privateKeyPem}) cert =
        FushiSelfSignedCertGenerator.generate(
          commonName: 'fushi-test',
          sanIpAddresses: <String>['127.0.0.1'],
        );
    fingerprint = FushiTlsIdentityStore.fingerprintOf(cert.certificatePem);
    final SecurityContext ctx = SecurityContext()
      ..useCertificateChainBytes(cert.certificatePem.codeUnits)
      ..usePrivateKeyBytes(cert.privateKeyPem.codeUnits);
    origin = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    origin.listen((HttpRequest request) async {
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      request.response.headers.contentType = ContentType.binary;
      if (range == null) {
        request.response.contentLength = body.length;
        request.response.add(body);
      } else {
        final RegExpMatch m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
        final int start = int.parse(m.group(1)!);
        final int end = int.parse(m.group(2)!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${body.length}',
        );
        request.response.contentLength = end - start + 1;
        request.response.add(body.sublist(start, end + 1));
      }
      await request.response.close();
    });
    relay = await AppNativeProxy.start();
  });

  tearDown(() async {
    await relay.close();
    await origin.close(force: true);
    clearPinnedNativeOriginsForTesting();
    appUserProxyModeReader = oldMode;
  });

  String auth() =>
      'Basic ${base64.encode(utf8.encode(relay.endpoint.userInfo))}';

  /// native 播放器的请求形状：absolute-form 明文 http + 中继凭据。
  Future<({String head, List<int> body})> viaRelay(
    String path, {
    String? range,
  }) async {
    final Socket socket = await Socket.connect(
      relay.endpoint.host,
      relay.endpoint.port,
    );
    try {
      final String authority = '127.0.0.1:${origin.port}';
      socket.write(
        'GET http://$authority$path HTTP/1.1\r\n'
        'Host: $authority\r\n'
        'Proxy-Authorization: ${auth()}\r\n'
        '${range == null ? '' : 'Range: $range\r\n'}'
        'Connection: close\r\n\r\n',
      );
      final List<int> bytes = <int>[];
      await for (final List<int> chunk in socket.timeout(
        const Duration(seconds: 10),
      )) {
        bytes.addAll(chunk);
      }
      final int split = latin1.decode(bytes).indexOf('\r\n\r\n');
      return (
        head: latin1.decode(bytes.sublist(0, split)),
        body: bytes.sublist(split + 4),
      );
    } finally {
      socket.destroy();
    }
  }

  group('nativePlaybackUri', () {
    test('已登记原点的 https 降成带显式端口的 http，路径与 query 一字不改', () {
      registerPinnedNativeOrigin(
        host: '192.168.1.5',
        port: 38765,
        fingerprintSha256: fingerprint,
      );
      const String path =
          '/api/library/videos/video/%E6%A1%9CTrick%20(2014)/stream?token=aB-c_d';
      expect(
        nativePlaybackUri('https://192.168.1.5:38765$path'),
        'http://192.168.1.5:38765$path',
      );
    });

    test('隐含 443 的 https 降级后端口必须显式（否则中继查不到登记项）', () {
      registerPinnedNativeOrigin(
        host: 'host.example',
        port: 443,
        fingerprintSha256: fingerprint,
      );
      expect(
        nativePlaybackUri('https://host.example/stream'),
        'http://host.example:443/stream',
      );
    });

    test('未登记 / 非 https / 本地文件 原样返回', () {
      expect(
        nativePlaybackUri('https://unknown.example:1/x'),
        'https://unknown.example:1/x',
      );
      expect(
        nativePlaybackUri('http://192.168.1.5:38765/x'),
        'http://192.168.1.5:38765/x',
      );
      expect(nativePlaybackUri('file:///C:/a%20b.mkv'), 'file:///C:/a%20b.mkv');
      expect(nativePlaybackUri('not a uri'), 'not a uri');
    });

    test('host 匹配不分大小写、重复登记以最新指纹为准', () {
      registerPinnedNativeOrigin(
        host: 'Desktop.local',
        port: 1,
        fingerprintSha256: 'old',
      );
      registerPinnedNativeOrigin(
        host: 'desktop.LOCAL',
        port: 1,
        fingerprintSha256: 'new',
      );
      expect(pinnedNativeOriginFingerprint('DESKTOP.local', 1), 'new');
      expect(pinnedNativeOriginFingerprint('desktop.local', 2), isNull);
    });
  });

  group('relay upgrades a registered origin to pinned https', () {
    test('指纹相符：整段 GET 200 透传', () async {
      registerPinnedNativeOrigin(
        host: '127.0.0.1',
        port: origin.port,
        fingerprintSha256: fingerprint,
      );
      final ({String head, List<int> body}) r = await viaRelay('/clip.bin');
      expect(r.head, startsWith('HTTP/1.1 200'));
      expect(r.body, body);
    });

    test('指纹相符：Range 请求 206 + Content-Range 原样透传（libmpv 取流形状）', () async {
      registerPinnedNativeOrigin(
        host: '127.0.0.1',
        port: origin.port,
        fingerprintSha256: fingerprint,
      );
      final ({String head, List<int> body}) r = await viaRelay(
        '/clip.bin',
        range: 'bytes=100-199',
      );
      expect(r.head, startsWith('HTTP/1.1 206'));
      expect(
        r.head.toLowerCase(),
        contains('content-range: bytes 100-199/${body.length}'),
      );
      expect(r.body, body.sublist(100, 200));
    });

    test('指纹不符：钉扎拒绝 → 502，绝不放行任意自签证书', () async {
      final String wrong = fingerprint.startsWith('00:')
          ? '11:${fingerprint.substring(3)}'
          : '00:${fingerprint.substring(3)}';
      registerPinnedNativeOrigin(
        host: '127.0.0.1',
        port: origin.port,
        fingerprintSha256: wrong,
      );
      final ({String head, List<int> body}) r = await viaRelay('/clip.bin');
      expect(r.head, startsWith('HTTP/1.1 502'));
      expect(r.body, isEmpty);
    });

    test('未登记：中继按明文 http 直连 TLS 端口 → 502（登记是唯一放行条件）', () async {
      final ({String head, List<int> body}) r = await viaRelay('/clip.bin');
      expect(r.head, startsWith('HTTP/1.1 502'));
      expect(r.body, isEmpty);
    });

    test('撤销登记后同一原点回到明文直连 → 502（host 关 TLS 后不残留旧指纹）', () async {
      registerPinnedNativeOrigin(
        host: '127.0.0.1',
        port: origin.port,
        fingerprintSha256: fingerprint,
      );
      expect((await viaRelay('/clip.bin')).head, startsWith('HTTP/1.1 200'));
      unregisterPinnedNativeOrigin(host: '127.0.0.1', port: origin.port);
      expect(pinnedNativeOriginFingerprint('127.0.0.1', origin.port), isNull);
      final ({String head, List<int> body}) r = await viaRelay('/clip.bin');
      expect(r.head, startsWith('HTTP/1.1 502'));
    });

    test('同一钉扎原点的连续请求复用一条上游连接（不逐请求重新 TLS 握手）', () async {
      registerPinnedNativeOrigin(
        host: '127.0.0.1',
        port: origin.port,
        fingerprintSha256: fingerprint,
      );
      for (int i = 0; i < 3; i++) {
        final ({String head, List<int> body}) r = await viaRelay(
          '/clip.bin',
          range: 'bytes=$i-$i',
        );
        expect(r.head, startsWith('HTTP/1.1 206'), reason: 'request #$i');
      }
      // 三个 Range 请求若各起一个客户端，原点会看到 3 条连接；复用后只有 1 条。
      expect(origin.connectionsInfo().total, 1);
    });
  });
}
