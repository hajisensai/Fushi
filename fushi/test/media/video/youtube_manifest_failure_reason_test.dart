// YouTube 兜底链全部失败时，异常必须保留逐 client 的原始原因与类型。
//
// 原始失败（2026-10-24，Android 真机浏览器「用 Fushi 播放」）：设备走 Wi-Fi 系统代理，
// Dart 侧没读到它、直连 YouTube 超时；5 个 client 各自 13 s 超时后被包成一句
// StateError「youtube manifest failed for all clients …」，播放页的子串判据见到
// 「manifest failed」就报「无法获取视频流（视频不可用）」，错误日志里也没有原因。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'package:fushi_engine/media/video/youtube_source_resolver.dart';

const String _videoId = 'dQw4w9WgXcQ';

const String _streamUrl =
    'https://rr1---sn-test.googlevideo.com/videoplayback?itag=251&c=ANDROID';

String _playerOk() => jsonEncode(<String, Object?>{
  'playabilityStatus': <String, Object?>{'status': 'OK'},
  'videoDetails': <String, Object?>{'videoId': _videoId},
  'streamingData': <String, Object?>{
    'adaptiveFormats': <Object?>[
      <String, Object?>{
        'itag': 251,
        'url': _streamUrl,
        'mimeType': 'audio/webm; codecs="opus"',
        'bitrate': 140000,
        'averageBitrate': 130000,
        'contentLength': '3433755',
        'audioQuality': 'AUDIO_QUALITY_MEDIUM',
        'audioSampleRate': '48000',
        'audioChannels': 2,
      },
    ],
  },
});

String _playerBot() => jsonEncode(<String, Object?>{
  'playabilityStatus': <String, Object?>{
    'status': 'LOGIN_REQUIRED',
    'reason': 'Sign in to confirm you are not a bot',
  },
});

/// player 请求体里的 innertube clientName；不是 player 请求返回 null。
String? _playerClientName(http.Request req) {
  if (req.url.path != '/youtubei/v1/player') return null;
  final Map<String, dynamic> client =
      ((jsonDecode(req.body) as Map<String, dynamic>)['context']
              as Map<String, dynamic>)['client']
          as Map<String, dynamic>;
  return client['clientName'] as String?;
}

/// youtube_explode 校验响应时读 `response.request!`，MockClient 默认不填，这里补上。
MockClient _withRequest(Future<http.Response> Function(http.Request) handler) =>
    MockClient((http.Request req) async {
      final http.Response r = await handler(req);
      return http.Response.bytes(
        r.bodyBytes,
        r.statusCode,
        headers: r.headers,
        request: req,
      );
    });

Future<YoutubeManifestException> _failWith(
  Future<http.Response> Function(http.Request) handler, {
  Duration perClientTimeout = const Duration(seconds: 5),
}) async {
  final MockClient client = _withRequest(handler);
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
  test('连不上（SocketException）：试过的 client 都判传输层失败，原因带异常类型', () async {
    final YoutubeManifestException e = await _failWith(
      (http.Request req) async =>
          throw const SocketException('Connection timed out'),
    );
    expect(e.videoId, _videoId);
    expect(e.isTransportFailure, isTrue);
    expect(e.toString(), contains('VISIONOS: '));
    expect(e.toString(), contains('Connection timed out'));
  });

  // BUG-4822：出口不通时五个 client 的结局必然相同，不该挨个等满。
  group('BUG-4822 出口不通提前停', () {
    test('连续两个 client 都死在连接层：停，不再请求后面的 client', () async {
      final List<String> playerClients = <String>[];
      final YoutubeManifestException e = await _failWith((
        http.Request req,
      ) async {
        final String? name = _playerClientName(req);
        if (name != null) playerClients.add(name);
        throw const SocketException('Connection timed out');
      });
      expect(e.failures, hasLength(kYoutubeEgressFailureStreakLimit));
      expect(
        e.failures.map((YoutubeClientFailure f) => f.client),
        kYoutubeManifestClientFallback
            .take(kYoutubeEgressFailureStreakLimit)
            .map(youtubeClientName),
      );
      // 文案分型不变：仍是「传输层失败」。
      expect(e.isTransportFailure, isTrue);
      // visionOS 死在取身份（没发 player 请求），第二个是 ANDROID_VR；ANDROID / IOS /
      // TV 一个请求都没发出去。
      expect(playerClients.toSet(), <String>{'ANDROID_VR'});
    });

    test('TLS 握手失败同样算连接层', () async {
      final YoutubeManifestException e = await _failWith(
        (http.Request req) async =>
            throw const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
      );
      expect(e.failures, hasLength(kYoutubeEgressFailureStreakLimit));
    });

    test('连上了但对端不回（超时）不是出口信号：兜底链照旧试完', () async {
      final YoutubeManifestException e = await _failWith(
        (http.Request req) => Completer<http.Response>().future,
        perClientTimeout: const Duration(milliseconds: 30),
      );
      expect(e.failures, hasLength(kYoutubeManifestClientFallback.length));
    });

    test('单 client 窗口内先连接失败、重试时才被超时掐掉（黑洞出口的真实形态）：算连接层', () async {
      // 真机上连接阶段超时（10 s）以 SocketException 落进 youtube_explode 的重试循环，
      // 重试还没跑完就被单 client 上限（13 s）掐掉——浮到兜底链的只有 TimeoutException。
      // 这里每个请求先抛一次连接失败、之后的重试一律挂住，复刻同一时序。
      final Set<String> failedOnce = <String>{};
      final YoutubeManifestException e = await _failWith((
        http.Request req,
      ) async {
        final String key = _playerClientName(req) ?? req.url.path;
        if (failedOnce.add(key)) {
          throw const SocketException('HTTP connection timed out');
        }
        return Completer<http.Response>().future;
      }, perClientTimeout: const Duration(milliseconds: 900));
      expect(e.failures, hasLength(kYoutubeEgressFailureStreakLimit));
      // visionOS 死在取身份（`getString` 不重试，连接失败原样浮出来）；ANDROID_VR 的
      // player 请求在 youtube_explode 的重试循环里，浮到兜底链的只剩 TimeoutException
      // ——没有 send 层的记账，这一个 client 看不出是连接层失败。
      expect(e.failures.first.error, isA<SocketException>());
      expect(e.failures.last.client, 'ANDROID_VR');
      expect(e.failures.last.error, isA<TimeoutException>());
    });

    test('前两个 client 被拖到超时、第三个能出流：照常起播（不被误判成出口不通）', () async {
      final MockClient client = _withRequest((http.Request req) {
        if (req.url.host.endsWith('googlevideo.com')) {
          return Future<http.Response>.value(http.Response('', 200));
        }
        if (_playerClientName(req) == 'ANDROID') {
          return Future<http.Response>.value(http.Response(_playerOk(), 200));
        }
        return Completer<http.Response>().future; // sw.js_data / ANDROID_VR 挂住
      });
      final yt.StreamManifest manifest =
          await getYoutubeManifestWithClientFallback(
            yt.YoutubeHttpClient(client),
            _videoId,
            kYoutubeManifestClientFallback,
            perClientTimeout: const Duration(milliseconds: 300),
          );
      expect(manifest.audioOnly.single.url.toString(), _streamUrl);
    });

    test('连接失败与真实应答交替：连击被清零，不提前停', () async {
      int identityRequests = 0;
      final YoutubeManifestException e = await _failWith((
        http.Request req,
      ) async {
        // visionOS（第一次取身份）与 ANDROID 连不上；其余 client 拿到「判 bot」的真实
        // 应答。IOS 自己也会取一次 `sw.js_data`（youtube_explode 内部），那次放行——
        // 否则 ANDROID、IOS 就成了连续两个连接层失败。
        if (req.url.path == '/sw.js_data') {
          identityRequests++;
          if (identityRequests == 1) {
            throw const SocketException('Connection refused');
          }
        } else if (_playerClientName(req) == 'ANDROID') {
          throw const SocketException('Connection refused');
        }
        return http.Response(_playerBot(), 200);
      });
      expect(identityRequests, greaterThanOrEqualTo(1));
      expect(e.failures, hasLength(kYoutubeManifestClientFallback.length));
      expect(e.isTransportFailure, isFalse);
    });

    test('上一个 client 超时后迟到的连接失败不记进下一个 client 的窗口', () async {
      // 单 client 的整体超时不取消 youtube_explode 重试循环里的在途请求。时序：
      //   visionOS   取身份挂住 → 超时（无连接层失败）
      //   ANDROID_VR 首次建连立刻失败，0.5 s 后的重试拖到链起点后 2.0 s 才再次建连
      //              失败——此时 ANDROID_VR 的窗口（0.8～1.6 s）已结束，轮到 ANDROID
      //   ANDROID 及之后：连上了但对端不回（零响应、零连接失败）
      // ANDROID_VR 迟到的那次失败若记进 ANDROID 的窗口，就成了连续两个「出口不通」，
      // 兜底链在 ANDROID 之后提前停，IOS / TV 没试。
      const Duration perClient = Duration(milliseconds: 800);
      final Stopwatch clock = Stopwatch()..start();
      int androidVrAttempts = 0;
      bool lateFailureThrown = false;
      final YoutubeManifestException e = await _failWith((
        http.Request req,
      ) async {
        if (_playerClientName(req) == 'ANDROID_VR') {
          androidVrAttempts++;
          if (androidVrAttempts == 1) {
            throw const SocketException('HTTP connection timed out');
          }
          if (androidVrAttempts == 2) {
            // 拖到 ANDROID 的窗口中段（visionOS 0.8 s + ANDROID_VR 0.8 s 之后）。
            final Duration wait = perClient * 2.5 - clock.elapsed;
            if (wait > Duration.zero) await Future<void>.delayed(wait);
            lateFailureThrown = true;
            throw const SocketException('HTTP connection timed out');
          }
        }
        return Completer<http.Response>().future;
      }, perClientTimeout: perClient);
      expect(lateFailureThrown, isTrue, reason: '迟到的失败必须真的发生在链结束之前');
      expect(e.failures, hasLength(kYoutubeManifestClientFallback.length));
    });

    test('生产出站的底层 HttpClient 真的用了 kYoutubeConnectTimeout', () {
      // 所有提前停用例都注入 MockClient、立刻抛 SocketException；黑洞出口（SYN 被丢）下
      // 连接层失败能不能在单 client 窗口内浮出来，只取决于生产工厂给底层 HttpClient 设的
      // 连接超时。改回应用默认的 20 s，上面的用例照绿，而黑洞出口回到 5 × 13 s。
      HttpClient? underlying;
      final YoutubeProbingHttpClient client = createYoutubeHttpClient(
        configure: (HttpClient c) => underlying = c,
      );
      addTearDown(client.close);
      expect(underlying, isNotNull);
      expect(underlying!.connectionTimeout, kYoutubeConnectTimeout);
    });

    test('连接超时必须短于单 client 上限（否则连接阶段的失败浮不出来）', () {
      expect(
        kYoutubeConnectTimeout,
        lessThan(kYoutubePerClientManifestTimeout),
      );
      expect(kYoutubeConnectTimeout, greaterThan(Duration.zero));
      // 1 = 首个 client 连不上就放弃整条链，等于废掉兜底。
      expect(kYoutubeEgressFailureStreakLimit, greaterThanOrEqualTo(2));
      expect(
        kYoutubeEgressFailureStreakLimit,
        lessThan(kYoutubeManifestClientFallback.length),
      );
    });
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
