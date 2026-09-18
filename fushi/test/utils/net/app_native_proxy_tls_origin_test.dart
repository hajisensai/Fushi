import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

/// 普通 https 媒体流（Emby / Jellyfin 远程访问、公网直链）不再交给 native 播放器
/// 自己做 TLS：macOS / iOS 随包 libmpv（FFmpeg 6.1.6 + Mbed TLS）在
/// `mbedtls_ssl_handshake` 里段错误（Mac 崩溃报告 fushi-2026-09-18-210129.ips），
/// Android 随包 libmpv 的 ffmpeg tls 又从不校验证书。URL 经 [nativePlaybackUri]
/// 降成明文 http 并登记原点，中继用系统信任根的 [createAppHttpClient] 升回 https。
///
/// 这里用真自签 https 原点走一遍 native 的请求形状（absolute-form GET +
/// Proxy-Authorization），证明：
///  - 已登记原点 → 中继升 https，200 / 206 + Content-Range 原样透传；
///  - 上游 3xx 的 https `Location` 被改写成中继认识的明文显式端口形式并登记；
///  - 同一原点的一串请求复用同一个上游客户端（keep-alive 池），不再一请求一握手。
void main() {
  late AppNativeProxy relay;
  late HttpServer origin;
  late String Function() oldMode;
  late HttpClient Function() oldFactory;
  int clientsBuilt = 0;
  final List<int> body = List<int>.generate(4096, (int i) => i % 251);

  setUp(() async {
    oldMode = appUserProxyModeReader;
    oldFactory = appNativeProxyUpstreamClientFactory;
    appUserProxyModeReader = () => kProxyModeDirect;
    clearPinnedNativeOriginsForTesting();
    clientsBuilt = 0;
    final ({String certificatePem, String privateKeyPem}) cert =
        FushiSelfSignedCertGenerator.generate(
          commonName: 'fushi-test',
          sanIpAddresses: <String>['127.0.0.1'],
        );
    final SecurityContext ctx = SecurityContext()
      ..useCertificateChainBytes(cert.certificatePem.codeUnits)
      ..usePrivateKeyBytes(cert.privateKeyPem.codeUnits);
    origin = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    origin.listen((HttpRequest request) async {
      if (request.uri.path == '/redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'https://127.0.0.1:${origin.port}/clip.bin',
        );
        await request.response.close();
        return;
      }
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
    // 系统信任根不认测试自签证书：测试里换成信任它的客户端；生产走默认工厂。
    appNativeProxyUpstreamClientFactory = () {
      clientsBuilt++;
      return createAppHttpClient()
        ..badCertificateCallback = (X509Certificate _, String __, int ___) =>
            true;
    };
    relay = await AppNativeProxy.start();
  });

  tearDown(() async {
    await relay.close();
    await origin.close(force: true);
    clearPinnedNativeOriginsForTesting();
    appUserProxyModeReader = oldMode;
    appNativeProxyUpstreamClientFactory = oldFactory;
  });

  String auth() =>
      'Basic ${base64.encode(utf8.encode(relay.endpoint.userInfo))}';

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

  String downgraded(String path) =>
      nativePlaybackUri('https://127.0.0.1:${origin.port}$path');

  test('已登记原点：中继升 https，整段 GET 200 透传', () async {
    expect(downgraded('/clip.bin'), 'http://127.0.0.1:${origin.port}/clip.bin');
    final ({String head, List<int> body}) r = await viaRelay('/clip.bin');
    expect(r.head, startsWith('HTTP/1.1 200'));
    expect(r.body, body);
  });

  test('已登记原点：Range 206 + Content-Range 原样透传（libmpv 取流形状）', () async {
    downgraded('/clip.bin');
    final ({String head, List<int> body}) r = await viaRelay(
      '/clip.bin',
      range: 'bytes=100-199',
    );
    expect(r.head, startsWith('HTTP/1.1 206'));
    expect(r.head.toLowerCase(), contains('content-range: bytes 100-199/4096'));
    expect(r.body, body.sublist(100, 200));
  });

  test('未登记的明文请求打到 https 端口：必失败（登记是升级的唯一条件）', () async {
    final ({String head, List<int> body}) r = await viaRelay('/clip.bin');
    expect(r.head, startsWith('HTTP/1.1 502'));
  });

  test('上游 https Location 改写成明文显式端口形式并登记原点', () async {
    downgraded('/redirect');
    final ({String head, List<int> body}) r = await viaRelay('/redirect');
    expect(r.head, startsWith('HTTP/1.1 302'));
    expect(
      r.head.toLowerCase(),
      contains('location: http://127.0.0.1:${origin.port}/clip.bin'),
      reason: 'native 跟过去仍经中继升 https，而不是自己握手',
    );
    expect(isTlsNativeOrigin('127.0.0.1', origin.port), isTrue);
  });

  test('同一原点的一串请求复用同一上游客户端（keep-alive 池）', () async {
    downgraded('/clip.bin');
    for (int i = 0; i < 4; i++) {
      final ({String head, List<int> body}) r = await viaRelay(
        '/clip.bin',
        range: 'bytes=${i * 10}-${i * 10 + 9}',
      );
      expect(r.head, startsWith('HTTP/1.1 206'));
    }
    expect(clientsBuilt, 1, reason: '此前是一请求一客户端 + 强制关闭 = 每个 Range 重新握手');
  });
}
