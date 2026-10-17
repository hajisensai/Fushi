// BUG-2946：YouTube 兜底链不得依赖 watch page。
//
// 原始失败（2026-10-04 制卡日志）：公开视频 `N2uQWfV6Jr4` 制卡连续报
// 「youtube manifest failed for all clients … VideoUnavailableException: Video
// 'N2uQWfV6Jr4' is unavailable」。根因：每个 client 都走 youtube_explode 的
// `requireWatchPage: true`，先拉 watch page HTML；YouTube 间歇下发的降级页（有 #player、
// 无 og:url）让 youtube_explode 在发任何 player 请求之前就抛「视频不可用」，5 个 client
// 全死在同一张页面上。修复后链上一律不拉 watch page，visionOS 的 visitor 身份改从
// `sw.js_data` 取。
//
// 这里用 MockClient 离线重现「watch page 降级」这一外部状态，驱动真实兜底链。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'package:fushi_engine/media/video/youtube_source_resolver.dart';

const String _videoId = 'N2uQWfV6Jr4';
const String _visitor = 'CgtWSVNJVE9SX0lEEg%3D%3D';
const String _streamUrl =
    'https://rr1---sn-test.googlevideo.com/videoplayback?itag=251&c=VISIONOS';

/// YouTube 间歇下发的降级 watch page：有播放器壳，没有 `og:url`。
const String _degradedWatchPage =
    '<html><body><div id="player"></div></body></html>';

String _swJsData(String visitor) => ")]}'${jsonEncode(<Object?>[
          <Object?>[
            null,
            null,
            <Object?>[
              <Object?>[
                <Object?>[for (int i = 0; i < 13; i++) null, visitor],
              ],
            ],
          ],
        ])}";

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
        'reason': "Sign in to confirm you're not a bot",
      },
    });

/// youtube_explode 校验响应时读 `response.request!`，MockClient 默认不填，这里补上。
MockClient _mockClient(Future<http.Response> Function(http.Request) handler) =>
    MockClient((http.Request req) async {
      final http.Response r = await handler(req);
      return http.Response.bytes(r.bodyBytes, r.statusCode,
          headers: r.headers, request: req);
    });

/// 记录每个请求的 MockClient：watch page 降级；VISIONOS 只有带 visitor 身份才出流。
class _Recorder {
  final List<http.Request> requests = <http.Request>[];

  late final MockClient client = _mockClient((http.Request req) async {
    requests.add(req);
    final Uri u = req.url;
    if (u.path == '/watch') {
      return http.Response(
        _degradedWatchPage,
        200,
        headers: <String, String>{'set-cookie': 'YSC=x; path=/'},
      );
    }
    if (u.path == '/sw.js_data') return http.Response(_swJsData(_visitor), 200);
    if (u.path == '/youtubei/v1/player') {
      final Map<String, dynamic> body =
          jsonDecode(req.body) as Map<String, dynamic>;
      final Map<String, dynamic> c = (body['context']
          as Map<String, dynamic>)['client'] as Map<String, dynamic>;
      final bool vision = c['clientName'] == 'VISIONOS';
      final bool hasIdentity = c['visitorData'] == _visitor &&
          req.headers['X-Goog-Visitor-Id'] == _visitor;
      return http.Response(
        vision && hasIdentity ? _playerOk() : _playerBot(),
        200,
      );
    }
    if (u.host.endsWith('googlevideo.com')) return http.Response('', 200);
    return http.Response('unexpected ${req.method} $u', 404);
  });

  bool get touchedWatchPage =>
      requests.any((http.Request r) => r.url.path == '/watch');
}

void main() {
  group('BUG-2946 watch page 降级不再拖垮整条兜底链', () {
    test(
      '降级 watch page 下 visionOS 凭 sw.js_data 身份出流，且全程不请求 watch page',
      () async {
        final _Recorder rec = _Recorder();
        final yt.StreamManifest manifest =
            await getYoutubeManifestWithClientFallback(
          yt.YoutubeHttpClient(rec.client),
          _videoId,
          kYoutubeManifestClientFallback,
        );
        expect(manifest.audioOnly.single.url.toString(), _streamUrl);
        expect(rec.touchedWatchPage, isFalse);
        // 身份只取一次。
        expect(
          rec.requests.where((http.Request r) => r.url.path == '/sw.js_data'),
          hasLength(1),
        );
      },
    );

    test('全部失败时报错逐 client 列出原因（不再只剩最后一个异常）', () async {
      final MockClient allBot = _mockClient((http.Request req) async {
        if (req.url.path == '/sw.js_data') {
          return http.Response(_swJsData(_visitor), 200);
        }
        return http.Response(_playerBot(), 200);
      });
      await expectLater(
        getYoutubeManifestWithClientFallback(
          yt.YoutubeHttpClient(allBot),
          _videoId,
          kYoutubeManifestClientFallback,
        ),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            allOf(<Matcher>[
              contains(_videoId),
              for (final yt.YoutubeApiClient c
                  in kYoutubeManifestClientFallback)
                contains('${youtubeClientName(c)}:'),
            ]),
          ),
        ),
      );
    });

    test('sw.js_data 取身份失败只算 visionOS 失败，链继续往下走', () async {
      final List<String> playerClients = <String>[];
      final MockClient noVisitor = _mockClient((http.Request req) async {
        if (req.url.path == '/sw.js_data') return http.Response('oops', 500);
        if (req.url.path == '/youtubei/v1/player') {
          final Map<String, dynamic> c =
              ((jsonDecode(req.body) as Map<String, dynamic>)['context']
                  as Map<String, dynamic>)['client'] as Map<String, dynamic>;
          playerClients.add(c['clientName'] as String);
        }
        return http.Response(_playerBot(), 200);
      });
      await expectLater(
        getYoutubeManifestWithClientFallback(
          yt.YoutubeHttpClient(noVisitor),
          _videoId,
          kYoutubeManifestClientFallback,
        ),
        throwsA(isA<StateError>()),
      );
      expect(playerClients, isNot(contains('VISIONOS')));
      expect(playerClients, containsAll(<String>['ANDROID_VR', 'ANDROID']));
    });
  });

  group('BUG-2946 visitor 身份的纯函数', () {
    test('parseYoutubeVisitorData 处理 XSSI 前缀与无前缀两种形态', () {
      expect(parseYoutubeVisitorData(_swJsData('abc')), 'abc');
      expect(parseYoutubeVisitorData(_swJsData('abc').substring(4)), 'abc');
    });

    test('结构不符抛 FormatException（交给调用方记为该 client 失败）', () {
      expect(() => parseYoutubeVisitorData(")]}'[]"), throwsFormatException);
      expect(
        () => parseYoutubeVisitorData(_swJsData('')),
        throwsFormatException,
      );
    });

    test('youtubeClientWithVisitorData 注入 body 与 header 两处，且不改模板', () {
      final yt.YoutubeApiClient derived = youtubeClientWithVisitorData(
        kYoutubeVisionOsClient,
        'v1',
      );
      final Map<String, dynamic> client = (derived.payload['context']
          as Map<String, dynamic>)['client'] as Map<String, dynamic>;
      expect(client['visitorData'], 'v1');
      expect(client['clientName'], 'VISIONOS');
      expect(derived.headers['X-Goog-Visitor-Id'], 'v1');
      expect(derived.apiUrl, kYoutubeVisionOsClient.apiUrl);
      final Map<String, dynamic> template =
          (kYoutubeVisionOsClient.payload['context']
              as Map<String, dynamic>)['client'] as Map<String, dynamic>;
      expect(template.containsKey('visitorData'), isFalse);
      expect(kYoutubeVisionOsClient.headers, isEmpty);
    });

    test('需要身份的 client 集合就是 visionOS 本身（引用相等）', () {
      expect(kYoutubeVisitorIdentityClients, hasLength(1));
      expect(
        identical(
          kYoutubeVisitorIdentityClients.single,
          kYoutubeVisionOsClient,
        ),
        isTrue,
      );
    });
  });
}
