import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';
import 'package:fushi/src/utils/net/hls_relay_normalizer.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

/// BUG-2609：中继对视频源扩展 HLS 流的归一化，用真中继 + 本地明文上游走一遍 native
/// 的请求形状（absolute-form GET + Proxy-Authorization + ffmpeg 默认的
/// `Range: bytes=0-`）：
///  - 播放列表里的绝对 https 分片改写成中继终结 TLS 的明文显式端口形式；
///  - 图片伪装的分片剥掉前缀、长度改算、206 完整范围回 200、类型改 `video/mp2t`；
///  - 真图片 / 真部分范围请求 / 普通正文一字节不动；
///  - 上游收到的是 `Accept-Encoding: identity`（不然 Brotli 回来改写不了）。
void main() {
  late AppNativeProxy relay;
  late HttpServer origin;
  late String Function() oldMode;
  late String Function() oldProxy;
  final List<String> upstreamAcceptEncodings = <String>[];

  final Uint8List png = Uint8List.fromList(<int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ]);
  final Uint8List ts = Uint8List(kTransportStreamPacketLength * 8);
  for (int p = 0; p < 8; p++) {
    ts[p * kTransportStreamPacketLength] = 0x47;
    for (int i = 1; i < kTransportStreamPacketLength; i++) {
      ts[p * kTransportStreamPacketLength + i] = 0x10 + (i % 50);
    }
  }
  final Uint8List disguised = Uint8List.fromList(<int>[
    ...png,
    ...List<int>.filled(252 - png.length, 0),
    ...ts,
  ]);
  final Uint8List genuineImage = Uint8List.fromList(<int>[
    ...png,
    ...List<int>.generate(3000, (int i) => (i * 7) & 0xFF),
  ]);

  // `/slow.bin` 的写循环因下游断开而退出时完成；中继若不 cancel 上游迭代器，
  // 上游那条连接停在 paused、写端 flush 永远挂住，它就永不完成。
  late Completer<void> slowUpstreamEnded;

  setUp(() async {
    oldMode = appUserProxyModeReader;
    oldProxy = appUserProxyReader;
    appUserProxyModeReader = () => kProxyModeDirect;
    upstreamAcceptEncodings.clear();
    slowUpstreamEnded = Completer<void>();
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((HttpRequest request) async {
      upstreamAcceptEncodings.add(
        request.headers.value(HttpHeaders.acceptEncodingHeader) ?? '<none>',
      );
      final HttpResponse res = request.response;
      final String? range = request.headers.value(HttpHeaders.rangeHeader);
      switch (request.uri.path) {
        case '/index.m3u8':
          res.headers.contentType = ContentType.parse(
            'application/vnd.apple.mpegurl',
          );
          res.write(
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="https://key.invalid/k"\n'
            '#EXTINF:3.84,\nhttps://cdn.invalid/seg1.image?x=1\n'
            '#EXTINF:3.84,\nseg2.ts\n#EXT-X-ENDLIST\n',
          );
        case '/gz.m3u8':
          res.headers.contentType = ContentType.parse('application/x-mpegURL');
          res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
          res.add(
            gzip.encode(utf8.encode('#EXTM3U\nhttps://cdn.invalid/a.ts\n')),
          );
        case '/seg.image':
          res.headers.contentType = ContentType('image', 'png');
          if (range == null) {
            res.contentLength = disguised.length;
            res.add(disguised);
          } else {
            // ffmpeg 首请求 `bytes=0-` → 服务器回 206 + 完整 Content-Range。
            final RegExpMatch m = RegExp(
              r'bytes=(\d+)-(\d*)',
            ).firstMatch(range)!;
            final int start = int.parse(m.group(1)!);
            final int end = m.group(2)!.isEmpty
                ? disguised.length - 1
                : int.parse(m.group(2)!);
            res.statusCode = HttpStatus.partialContent;
            res.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${disguised.length}',
            );
            res.contentLength = end - start + 1;
            res.add(disguised.sublist(start, end + 1));
          }
        case '/cover.png':
          res.headers.contentType = ContentType('image', 'png');
          res.contentLength = genuineImage.length;
          res.add(genuineImage);
        case '/plain.bin':
          res.headers.contentType = ContentType.binary;
          res.contentLength = ts.length;
          res.add(ts);
        case '/slow.bin':
          // 无限长整包：模拟正在下的大分片，native 中途掐断。
          res.headers.contentType = ContentType.binary;
          res.bufferOutput = false;
          try {
            for (int i = 0; i < 100000; i++) {
              res.add(ts);
              await res.flush();
              await Future<void>.delayed(const Duration(milliseconds: 5));
              // Dart 的 HttpResponse 对已销毁连接 add/flush 不抛、done 不完成，
              // 中继关掉上游连接后只有 connectionInfo 变 null 可观测。
              if (res.connectionInfo == null) break;
            }
          } catch (_) {
            // 写端报错也是出口。
          }
          if (!slowUpstreamEnded.isCompleted) slowUpstreamEnded.complete();
          try {
            await res.close();
          } catch (_) {}
          return;
        default:
          res.statusCode = HttpStatus.notFound;
      }
      await res.close();
    });
    relay = await AppNativeProxy.start();
  });

  tearDown(() async {
    await relay.close();
    await origin.close(force: true);
    appUserProxyModeReader = oldMode;
    appUserProxyReader = oldProxy;
  });

  String auth() =>
      'Basic ${base64.encode(utf8.encode(relay.endpoint.userInfo))}';

  Future<({int status, Map<String, String> headers, Uint8List body})> get(
    String path, {
    String? range,
  }) async {
    final HttpClient client = HttpClient()
      ..autoUncompress = false
      ..findProxy = (Uri _) =>
          'PROXY ${relay.endpoint.host}:${relay.endpoint.port}';
    try {
      final HttpClientRequest request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${origin.port}$path'),
      );
      request.headers.set(HttpHeaders.proxyAuthorizationHeader, auth());
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      final HttpClientResponse response = await request.close();
      final BytesBuilder b = BytesBuilder(copy: false);
      await for (final List<int> chunk in response) {
        b.add(chunk);
      }
      final Map<String, String> headers = <String, String>{};
      response.headers.forEach(
        (String k, List<String> v) => headers[k] = v.join(','),
      );
      return (
        status: response.statusCode,
        headers: headers,
        body: b.takeBytes(),
      );
    } finally {
      client.close(force: true);
    }
  }

  test('native disconnecting mid-relay cancels the upstream body', () async {
    // libmpv 每次 seek / 换集都会掐掉正在下的分片；`_relayBody` 手动迭代上游流，
    // 中断路径必须 cancel 迭代器，否则上游连接（https 含 TLS）永不回池也不关。
    final HttpClient client = HttpClient()
      ..findProxy = (Uri _) =>
          'PROXY ${relay.endpoint.host}:${relay.endpoint.port}';
    final HttpClientRequest request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${origin.port}/slow.bin'),
    );
    request.headers.set(HttpHeaders.proxyAuthorizationHeader, auth());
    final HttpClientResponse response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    await response.first;
    client.close(force: true);
    await slowUpstreamEnded.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () =>
          fail('upstream body was never cancelled after native hung up'),
    );
  });

  test('playlist: absolute https URIs are rewritten to relay form', () async {
    final result = await get('/index.m3u8', range: 'bytes=0-');
    expect(result.status, 200);
    expect(
      utf8.decode(result.body),
      '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="http://key.invalid:443/k"\n'
      '#EXTINF:3.84,\nhttp://cdn.invalid:443/seg1.image?x=1\n'
      '#EXTINF:3.84,\nseg2.ts\n#EXT-X-ENDLIST\n',
    );
    expect(result.headers['content-length'], '${result.body.length}');
    // 改写的同时把原点登记成「中继终结 TLS」，分片请求回来时才升得回 https。
    expect(isTlsNativeOrigin('cdn.invalid', 443), isTrue);
    expect(isTlsNativeOrigin('key.invalid', 443), isTrue);
    expect(upstreamAcceptEncodings, <String>['identity']);
  });

  test('gzip playlist is decoded, rewritten and served plain', () async {
    final result = await get('/gz.m3u8');
    expect(result.status, 200);
    expect(result.headers.containsKey('content-encoding'), isFalse);
    expect(utf8.decode(result.body), '#EXTM3U\nhttp://cdn.invalid:443/a.ts\n');
  });

  test(
    'disguised segment: image prefix stripped, 206 whole range → 200',
    () async {
      for (final String? range in <String?>[null, 'bytes=0-']) {
        final result = await get('/seg.image', range: range);
        expect(result.status, 200, reason: 'range=$range');
        expect(result.headers['content-type'], 'video/mp2t');
        expect(result.headers.containsKey('content-range'), isFalse);
        expect(result.headers['content-length'], '${ts.length}');
        expect(result.body, ts, reason: 'range=$range');
      }
    },
  );

  test('a real partial range request is passed through untouched', () async {
    final result = await get('/seg.image', range: 'bytes=100-299');
    expect(result.status, 206);
    expect(result.headers['content-type'], 'image/png');
    expect(
      result.headers['content-range'],
      'bytes 100-299/${disguised.length}',
    );
    expect(result.body, disguised.sublist(100, 300));
  });

  test(
    'a genuine image and ordinary bodies are passed through byte-exact',
    () async {
      final cover = await get('/cover.png');
      expect(cover.status, 200);
      expect(cover.headers['content-type'], 'image/png');
      expect(cover.body, genuineImage);
      final plain = await get('/plain.bin', range: 'bytes=0-');
      expect(plain.status, 200);
      expect(plain.body, ts);
    },
  );
}
