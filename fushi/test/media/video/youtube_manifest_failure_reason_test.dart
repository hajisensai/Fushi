// YouTube 兜底链全部失败时，异常必须保留逐 client 的原始原因与类型。
//
// 原始失败（2026-10-24，Android 真机浏览器「用 Fushi 播放」）：设备走 Wi-Fi 系统代理，
// Dart 侧没读到它、直连 YouTube 超时；5 个 client 各自 13 s 超时后被包成一句
// StateError「youtube manifest failed for all clients …」，播放页的子串判据见到
// 「manifest failed」就报「无法获取视频流（视频不可用）」，错误日志里也没有原因。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'package:fushi_engine/media/video/youtube_source_resolver.dart';

const String _videoId = 'dQw4w9WgXcQ';

Future<YoutubeManifestException> _failWith(
  Future<http.Response> Function(http.Request) handler, {
  Duration perClientTimeout = const Duration(seconds: 5),
}) async {
  final MockClient client = MockClient((http.Request req) async {
    final http.Response r = await handler(req);
    return http.Response.bytes(
      r.bodyBytes,
      r.statusCode,
      headers: r.headers,
      request: req,
    );
  });
  try {
    await getYoutubeManifestWithClientFallback(
      yt.YoutubeHttpClient(client),
      _videoId,
      kYoutubeManifestClientFallback,
      perClientTimeout: perClientTimeout,
    );
  } on YoutubeManifestException catch (e) {
    return e;
  }
  fail('expected YoutubeManifestException');
}

void main() {
  test('连不上（SocketException）：每个 client 都判传输层失败，原因带异常类型', () async {
    final YoutubeManifestException e = await _failWith(
      (http.Request req) async =>
          throw const SocketException('Connection timed out'),
    );
    expect(e.videoId, _videoId);
    expect(e.failures, hasLength(kYoutubeManifestClientFallback.length));
    expect(e.isTransportFailure, isTrue);
    expect(
      e.failures.map((YoutubeClientFailure f) => f.client),
      kYoutubeManifestClientFallback.map(youtubeClientName),
    );
    expect(e.toString(), contains('VISIONOS: '));
    expect(e.toString(), contains('Connection timed out'));
  });

  test('每个 client 都挂到超时：TimeoutException 也算传输层失败', () async {
    final YoutubeManifestException e = await _failWith(
      (http.Request req) => Completer<http.Response>().future,
      perClientTimeout: const Duration(milliseconds: 30),
    );
    expect(e.isTransportFailure, isTrue);
    expect(
      e.failures.every((YoutubeClientFailure f) => f.error is TimeoutException),
      isTrue,
    );
    expect(e.toString(), contains('TimeoutException'));
  });

  test('YouTube 回答了「不可播」：不是传输层失败，原因逐 client 列出', () async {
    final String bot = jsonEncode(<String, Object?>{
      'playabilityStatus': <String, Object?>{
        'status': 'LOGIN_REQUIRED',
        'reason': 'Sign in to confirm you are not a bot',
      },
    });
    final YoutubeManifestException e = await _failWith(
      (http.Request req) async =>
          http.Response(req.url.path == '/sw.js_data' ? ")]}'[]" : bot, 200),
    );
    expect(e.isTransportFailure, isFalse);
    // visionOS 死在取身份（sw.js_data 结构不符），其余 client 死在 unplayable。
    expect(e.failures.first.error, isA<FormatException>());
    expect(e.toString(), contains('VideoUnplayableException'));
    for (final yt.YoutubeApiClient c in kYoutubeManifestClientFallback) {
      expect(e.toString(), contains('${youtubeClientName(c)}: '));
    }
  });

  test('部分传输失败 + 部分无流：不算出口问题', () {
    const YoutubeManifestException e =
        YoutubeManifestException(_videoId, <YoutubeClientFailure>[
          YoutubeClientFailure('A', SocketException('x')),
          YoutubeClientFailure('B', null),
        ]);
    expect(e.isTransportFailure, isFalse);
    expect(e.toString(), contains('B: no streams'));
  });
}
