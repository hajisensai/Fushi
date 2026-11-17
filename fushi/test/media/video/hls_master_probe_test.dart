// BUG-4805：HLS 画质探测。
//
// 原实现在播放页里直接用顶层 `http.get`（默认 IOClient，不认应用代理），失败还静默
// 吞掉。现在取数收进 fushi_engine 的 [fetchHlsMasterVariants]：出站走统一装配点
// （由 `outbound_http_discipline_guard_test.dart` 咬住），失败抛给调用方记日志。
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:fushi_engine/media/video/m3u8_playlist.dart';

const String _master =
    '#EXTM3U\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n'
    'lo/index.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n'
    'hi/index.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720\n'
    'https://other.example/mid.m3u8\n';

const String _media =
    '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg0.ts\n#EXT-X-ENDLIST\n';

final Uri _uri = Uri.parse('https://cdn.example/v/master.m3u8?token=secret');

void main() {
  test('master：各档按画质从高到低，子地址按 master URL 解析', () async {
    final List<http.Request> seen = <http.Request>[];
    final List<HlsVariant> variants = await fetchHlsMasterVariants(
      _uri,
      headers: const <String, String>{'Referer': 'https://site.example/'},
      httpClient: MockClient((http.Request req) async {
        seen.add(req);
        return http.Response(_master, 200);
      }),
    );
    expect(variants.map((HlsVariant v) => v.height), <int?>[1080, 720, 360]);
    expect(variants.map((HlsVariant v) => v.url), <String>[
      'https://cdn.example/v/hi/index.m3u8',
      'https://other.example/mid.m3u8',
      'https://cdn.example/v/lo/index.m3u8',
    ]);
    // 防盗链头原样带上，只发一次请求。
    expect(seen.single.url, _uri);
    expect(seen.single.headers['Referer'], 'https://site.example/');
  });

  test('媒体播放列表（单码率）：空表，不是错误', () async {
    expect(
      await fetchHlsMasterVariants(
        _uri,
        httpClient: MockClient(
          (http.Request _) async => http.Response(_media, 200),
        ),
      ),
      isEmpty,
    );
  });

  test('非 200：抛带状态码的异常（调用方据此记日志），不当成「没有画质档」吞掉', () async {
    await expectLater(
      fetchHlsMasterVariants(
        _uri,
        httpClient: MockClient(
          (http.Request _) async => http.Response('denied', 403),
        ),
      ),
      throwsA(
        isA<HlsMasterProbeStatusException>()
            .having(
              (HlsMasterProbeStatusException e) => e.statusCode,
              'statusCode',
              403,
            )
            // 异常正文不带 URL（query 里有播放 token，会进 error_log）。
            .having(
              (HlsMasterProbeStatusException e) => e.toString(),
              'text',
              isNot(contains('secret')),
            ),
      ),
    );
  });

  test('连接失败原样抛出', () async {
    await expectLater(
      fetchHlsMasterVariants(
        _uri,
        httpClient: MockClient(
          (http.Request _) async =>
              throw const SocketException('Connection refused'),
        ),
      ),
      throwsA(isA<SocketException>()),
    );
  });

  test('对端连上不回：到 timeout 抛 TimeoutException，不无限等', () async {
    await expectLater(
      fetchHlsMasterVariants(
        _uri,
        timeout: const Duration(milliseconds: 40),
        httpClient: MockClient(
          (http.Request _) => Completer<http.Response>().future,
        ),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('注入的 client 不被本函数关闭（自建的才关）', () async {
    final _CloseSpy spy = _CloseSpy(
      MockClient((http.Request _) async => http.Response(_media, 200)),
    );
    await fetchHlsMasterVariants(_uri, httpClient: spy);
    expect(spy.closed, isFalse);
  });
}

class _CloseSpy extends http.BaseClient {
  _CloseSpy(this._inner);

  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    closed = true;
    _inner.close();
  }
}
