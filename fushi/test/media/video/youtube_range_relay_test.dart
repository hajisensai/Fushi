import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/youtube_range_relay.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoStreamUrls;

/// 模拟 googlevideo（BUG-2491）：无 `Range` / 开放区间 `bytes=X-` 一律 403；有界区间
/// 才 206，且单次最多给 [maxChunk] 字节（超出部分截断到 maxChunk，与真实服务端对更大
/// 区间限速/截断的行为同形）。记录每次收到的 Range 头供断言。
class _FakeGoogleVideo {
  _FakeGoogleVideo(this.body, {this.maxChunk = 1 << 20, this.forceStatus});

  final Uint8List body;
  final int maxChunk;
  final int? forceStatus;
  final List<String?> seenRanges = <String?>[];
  final List<String?> seenUserAgents = <String?>[];
  late HttpServer _server;

  Uri get url =>
      Uri.parse('http://127.0.0.1:${_server.port}/videoplayback?rqh=1');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((HttpRequest req) async {
      seenRanges.add(req.headers.value(HttpHeaders.rangeHeader));
      seenUserAgents.add(req.headers.value(HttpHeaders.userAgentHeader));
      final int? forced = forceStatus;
      if (forced != null) {
        req.response.statusCode = forced;
        await req.response.close();
        return;
      }
      final RegExpMatch? m = RegExp(r'^bytes=(\d+)-(\d+)$')
          .firstMatch(req.headers.value(HttpHeaders.rangeHeader) ?? '');
      if (m == null) {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      final int start = int.parse(m.group(1)!);
      int end = min(int.parse(m.group(2)!), body.length - 1);
      end = min(end, start + maxChunk - 1);
      if (start >= body.length) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await req.response.close();
        return;
      }
      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      req.response.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-$end/${body.length}');
      req.response.headers.contentLength = end - start + 1;
      if (req.method != 'HEAD') {
        req.response.add(body.sublist(start, end + 1));
      }
      await req.response.close();
    });
  }

  Future<void> close() => _server.close(force: true);
}

Future<({int status, Map<String, String> headers, Uint8List body})> _get(
  Uri uri, {
  String? range,
  String method = 'GET',
}) async {
  final HttpClient c = HttpClient();
  try {
    final HttpClientRequest req = await c.openUrl(method, uri);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final HttpClientResponse res = await req.close();
    final BytesBuilder bb = BytesBuilder(copy: false);
    await for (final List<int> chunk in res) {
      bb.add(chunk);
    }
    final Map<String, String> headers = <String, String>{};
    res.headers.forEach((String k, List<String> v) => headers[k] = v.join(','));
    return (status: res.statusCode, headers: headers, body: bb.takeBytes());
  } finally {
    c.close(force: true);
  }
}

Uint8List _pattern(int n) => Uint8List.fromList(
    List<int>.generate(n, (int i) => (i * 7 + i ~/ 251) & 0xff));

void main() {
  group('parseRelayRange', () {
    test('无 Range → 从 0 到末尾', () {
      expect(parseRelayRange(null), (start: 0, end: null));
      expect(parseRelayRange(''), (start: 0, end: null));
    });
    test('开放 / 闭区间 / 非法', () {
      expect(parseRelayRange('bytes=1234-'), (start: 1234, end: null));
      expect(parseRelayRange('bytes=10-20'), (start: 10, end: 20));
      expect(parseRelayRange('bytes=-500'), isNull);
      expect(parseRelayRange('bytes=20-10'), isNull);
      expect(parseRelayRange('items=0-1'), isNull);
    });
  });

  group('parseContentRange', () {
    test('带总长 / 总长未知 / 非法', () {
      expect(
          parseContentRange('bytes 0-9/100'), (start: 0, end: 9, total: 100));
      expect(parseContentRange('bytes 5-9/*'), (start: 5, end: 9, total: null));
      expect(parseContentRange('bytes 0-9'), isNull);
      expect(parseContentRange(null), isNull);
    });
  });

  group('isYoutubeMediaStreamUrl', () {
    test('只认 googlevideo 直链', () {
      expect(
          isYoutubeMediaStreamUrl(
              'https://rr2---sn-x.googlevideo.com/videoplayback?a=1'),
          isTrue);
      expect(isYoutubeMediaStreamUrl('https://www.youtube.com/watch?v=x'),
          isFalse);
      expect(
          isYoutubeMediaStreamUrl('https://cdn.example.com/a.m3u8'), isFalse);
      expect(isYoutubeMediaStreamUrl('not a url'), isFalse);
    });
  });

  group('YoutubeRangeRelay', () {
    late _FakeGoogleVideo upstream;
    late YoutubeRangeRelay relay;
    final Uint8List body = _pattern(3 * 1024 * 1024 + 12345);

    setUp(() async {
      upstream = _FakeGoogleVideo(body, maxChunk: 1 << 20);
      await upstream.start();
      relay = await YoutubeRangeRelay.start();
    });

    tearDown(() async {
      await relay.close();
      await upstream.close();
    });

    test('无 Range 的整流请求：上游全程只收到有界区间，拼回完整正文 + Content-Length', () async {
      final Uri local = relay.register(
        upstream.url.toString(),
        const <String, String>{'User-Agent': 'fushi-test-ua'},
      );
      final res = await _get(local);
      expect(res.status, HttpStatus.ok);
      expect(res.headers['content-length'], '${body.length}');
      expect(res.headers['accept-ranges'], 'bytes');
      expect(res.headers['content-type'], 'video/mp4');
      expect(res.body, body);
      expect(upstream.seenRanges, isNotEmpty);
      expect(
        upstream.seenRanges.every(
            (String? r) => r != null && RegExp(r'^bytes=\d+-\d+$').hasMatch(r)),
        isTrue,
        reason: '上游绝不能收到无 Range / 开放区间请求（那正是 403 的根因）',
      );
      expect(upstream.seenUserAgents.toSet(), <String?>{'fushi-test-ua'},
          reason: '回放 header 必须原样带到上游');
    });

    test('开放区间 bytes=X-（内核 seek）：206 + Content-Range，从 X 起到末尾', () async {
      final Uri local =
          relay.register(upstream.url.toString(), const <String, String>{});
      const int from = 1500000;
      final res = await _get(local, range: 'bytes=$from-');
      expect(res.status, HttpStatus.partialContent);
      expect(res.headers['content-range'],
          'bytes $from-${body.length - 1}/${body.length}');
      expect(res.headers['content-length'], '${body.length - from}');
      expect(res.body, body.sublist(from));
    });

    test('闭区间 bytes=a-b 精确返回；越过末尾按总长截断', () async {
      final Uri local =
          relay.register(upstream.url.toString(), const <String, String>{});
      final res = await _get(local, range: 'bytes=100-2099');
      expect(res.status, HttpStatus.partialContent);
      expect(res.body, body.sublist(100, 2100));
      final res2 = await _get(local,
          range: 'bytes=${body.length - 10}-${body.length + 1000}');
      expect(res2.body, body.sublist(body.length - 10));
      expect(res2.headers['content-range'],
          'bytes ${body.length - 10}-${body.length - 1}/${body.length}');
    });

    test('HEAD 只探一块就回总长，不拉正文', () async {
      final Uri local =
          relay.register(upstream.url.toString(), const <String, String>{});
      final res = await _get(local, method: 'HEAD');
      expect(res.status, HttpStatus.ok);
      expect(res.headers['content-length'], '${body.length}');
      expect(res.body, isEmpty);
      expect(upstream.seenRanges.length, 1);
    });

    test('未登记 token → 404；同一 URL 重复登记复用同一地址', () async {
      final res =
          await _get(Uri.parse('http://127.0.0.1:${relay.port}/yt/nope'));
      expect(res.status, HttpStatus.notFound);
      final Uri a =
          relay.register(upstream.url.toString(), const <String, String>{});
      final Uri b =
          relay.register(upstream.url.toString(), const <String, String>{});
      expect(a, b);
    });

    test('上游首块 403（URL 过期）原样透传给内核，绝不伪装成 200 空流', () async {
      final _FakeGoogleVideo dead = _FakeGoogleVideo(body, forceStatus: 403);
      await dead.start();
      try {
        final Uri local =
            relay.register(dead.url.toString(), const <String, String>{});
        final res = await _get(local, range: 'bytes=0-');
        expect(res.status, HttpStatus.forbidden);
      } finally {
        await dead.close();
      }
    });
  });

  group('UrlStreamVideoClient.remoteVideoStreamUrls', () {
    test('googlevideo 三条流都经中继换址，非 googlevideo 原样', () async {
      final List<String> relayed = <String>[];
      Future<String> fake(String url, Map<String, String> headers) async {
        if (!isYoutubeMediaStreamUrl(url)) return url;
        relayed.add(url);
        return 'http://127.0.0.1:1/yt/${relayed.length}';
      }

      final UrlStreamVideoClient yt = UrlStreamVideoClient(
        streamUrl: 'https://rr1---sn-a.googlevideo.com/videoplayback?itag=137',
        audioStreamUrl:
            'https://rr1---sn-a.googlevideo.com/videoplayback?itag=140',
        miningVideoUrl:
            'https://rr1---sn-a.googlevideo.com/videoplayback?itag=18',
        youtubeCaptionsUrl: 'https://www.youtube.com/watch?v=x',
        youtubeStreamRelay: fake,
      );
      final RemoteVideoStreamUrls urls = await yt.remoteVideoStreamUrls('x');
      expect(urls.streamUrl, 'http://127.0.0.1:1/yt/1');
      expect(urls.audioStreamUrl, 'http://127.0.0.1:1/yt/2');
      expect(urls.miningVideoUrl, 'http://127.0.0.1:1/yt/3');
      expect(relayed.length, 3);

      final UrlStreamVideoClient plain = UrlStreamVideoClient(
        streamUrl: 'https://cdn.example.com/a.m3u8',
        youtubeStreamRelay: fake,
      );
      final RemoteVideoStreamUrls plainUrls =
          await plain.remoteVideoStreamUrls('y');
      expect(plainUrls.streamUrl, 'https://cdn.example.com/a.m3u8');
      expect(relayed.length, 3);
    });
  });
}
