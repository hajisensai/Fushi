// Emby 兼容层两条（离线，MockClient）：
//
// - BUG-3137：部分非标准 Emby 的 `/System/Info/Public` 回 404，添加服务器时连接探测
//   直接报「无法连接」；同一服务器 SenPlayer / Emby 官方客户端能连上——它们的探测顺序
//   是根路径 Info/Public → `/emby` 前缀 Info/Public → `/System/Ping`。
// - BUG-3191：外挂 ASS 字幕取流按服务器在 PlaybackInfo 里签发的 `DeliveryUrl`（原格式
//   外挂交付）优先，拼出来的 `/Subtitles/{n}/Stream.ass` 只作回落。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoEmbeddedSubtitleTrack, RemoteVideoStreamUrls;
import 'package:fushi/src/sync/jellyfin_video_client.dart';

http.Response _json(Object? body) => http.Response(jsonEncode(body), 200);

JellyfinApi _api(
  String serverUrl,
  Future<http.Response> Function(http.Request req) handler, {
  List<String>? seen,
}) => JellyfinApi(
  serverUrl: serverUrl,
  accessToken: 'tok',
  client: MockClient((http.Request req) async {
    seen?.add(req.url.path);
    return handler(req);
  }),
);

void main() {
  group('BUG-3137 连接探测顺序', () {
    test('根路径 Info/Public 404 → 改走 /emby 前缀，基址带上前缀', () async {
      final List<String> seen = <String>[];
      final JellyfinApi api = _api('https://emby.example.com', (
        http.Request req,
      ) async {
        if (req.url.path == '/emby/System/Info/Public') {
          return _json(<String, Object?>{'ServerName': 'Box'});
        }
        return http.Response('Not Found', 404);
      }, seen: seen);
      final JellyfinServerProbe probe = await api.probeServer();
      expect(probe.baseUrl, 'https://emby.example.com/emby');
      expect(probe.serverName, 'Box');
      expect(seen, <String>['/System/Info/Public', '/emby/System/Info/Public']);
    });

    test('两处 Info/Public 都 404、Ping 通 → 认根路径（兼容层砍了公开信息端点）', () async {
      final JellyfinApi api = _api('http://nas:8096', (http.Request req) async {
        if (req.url.path == '/System/Ping') {
          return http.Response('Emby Server', 200);
        }
        return http.Response('', 404);
      });
      final JellyfinServerProbe probe = await api.probeServer();
      expect(probe.baseUrl, 'http://nas:8096');
      expect(probe.serverName, isNull);
    });

    test('Ping 回网页（反代 / SPA）不算媒体服务器', () async {
      final JellyfinApi api = _api('http://nas:8096', (http.Request req) async {
        if (req.url.path.endsWith('/System/Ping')) {
          return http.Response('<html>login</html>', 200);
        }
        return http.Response('', 404);
      });
      await expectLater(
        api.probeServer(),
        throwsA(
          isA<JellyfinApiException>()
              .having((JellyfinApiException e) => e.statusCode, 'status', 404)
              .having(
                (JellyfinApiException e) => e.endpoint,
                'endpoint',
                '/System/Info/Public',
              ),
        ),
      );
    });

    test('地址已带 /emby：先试原样，404 再试去掉前缀', () async {
      final JellyfinApi api = _api('https://x.example.com/emby', (
        http.Request req,
      ) async {
        if (req.url.path == '/System/Info/Public') {
          return _json(<String, Object?>{'ServerName': 'Root'});
        }
        return http.Response('', 404);
      });
      final JellyfinServerProbe probe = await api.probeServer();
      expect(probe.baseUrl, 'https://x.example.com');
    });

    test('403（客户端白名单）不回落，原样报出服务器说明', () async {
      final List<String> seen = <String>[];
      final JellyfinApi api = _api('https://emby.example.com', (
        http.Request req,
      ) async {
        return http.Response.bytes(utf8.encode('请使用允许的客户端'), 403);
      }, seen: seen);
      await expectLater(
        api.probeServer(),
        throwsA(
          isA<JellyfinApiException>().having(
            (JellyfinApiException e) => e.statusCode,
            'status',
            403,
          ),
        ),
      );
      expect(seen, <String>['/System/Info/Public']);
    });

    test('原版服务器：一次 Info/Public 就定案', () async {
      final List<String> seen = <String>[];
      final JellyfinApi api = _api('http://nas:8096', (http.Request req) async {
        return _json(<String, Object?>{'ServerName': 'NAS'});
      }, seen: seen);
      final JellyfinServerProbe probe = await api.probeServer();
      expect(probe.baseUrl, 'http://nas:8096');
      expect(probe.serverName, 'NAS');
      expect(seen, hasLength(1));
    });
  });

  group('BUG-3191 外挂字幕取流优先 DeliveryUrl', () {
    Map<String, Object?> episode() => <String, Object?>{
      'Id': 'ep1',
      'Name': 'Pilot',
      'Type': 'Episode',
      'MediaSources': <Object?>[
        <String, Object?>{
          'Id': 'src1',
          'MediaStreams': <Object?>[
            <String, Object?>{'Type': 'Video', 'Index': 0},
            <String, Object?>{
              'Type': 'Subtitle',
              'Index': 3,
              'Codec': 'ass',
              'Language': 'chi',
              'DisplayTitle': 'Show.ass',
              'IsExternal': true,
              'IsTextSubtitleStream': true,
            },
          ],
        },
      ],
    };

    Map<String, Object?> playbackInfo() => <String, Object?>{
      'PlaySessionId': 'ps-1',
      'MediaSources': <Object?>[
        <String, Object?>{
          'Id': 'src1',
          'SupportsDirectPlay': true,
          'SupportsDirectStream': true,
          'MediaStreams': <Object?>[
            <String, Object?>{'Type': 'Video', 'Index': 0},
            <String, Object?>{
              'Type': 'Subtitle',
              'Index': 3,
              'Codec': 'ass',
              'IsExternal': true,
              'DeliveryMethod': 'External',
              'DeliveryUrl': '/Videos/ep1/src1/Subtitles/3/0/Stream.ass',
            },
          ],
        },
      ],
    };

    test('parsePlaybackInfo 收下字幕流的 DeliveryUrl', () {
      final JellyfinPlaybackInfo info = JellyfinApi.parsePlaybackInfo(
        playbackInfo(),
      );
      expect(info.mediaSources.single.subtitleDeliveryUrls, <int, String>{
        3: '/Videos/ep1/src1/Subtitles/3/0/Stream.ass',
      });
    });

    test('字幕轨 URL 用服务器签发的 DeliveryUrl（补成绝对地址并带令牌）', () async {
      final JellyfinVideoClient c = JellyfinVideoClient(
        api: _api('http://nas:8096', (http.Request req) async {
          if (req.url.path == '/Users/u1/Items/ep1') return _json(episode());
          if (req.url.path == '/Items/ep1/PlaybackInfo') {
            return _json(playbackInfo());
          }
          return http.Response('', 204);
        }),
        userId: 'u1',
      );
      final RemoteVideoStreamUrls urls = await c.remoteVideoStreamUrls('ep1');
      final RemoteVideoEmbeddedSubtitleTrack track =
          urls.embeddedSubtitleTracks.single;
      expect(
        track.url,
        'http://nas:8096/Videos/ep1/src1/Subtitles/3/0/Stream.ass?api_key=tok',
      );
      expect(track.isExternalFile, isTrue);
      expect(urls.subtitleUrl, track.url);
    });

    test('下载走 DeliveryUrl；它失败时回落拼出来的 Stream.ass', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('emby_ass');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final List<String> seen = <String>[];
      final JellyfinVideoClient c = JellyfinVideoClient(
        api: _api('http://nas:8096', (http.Request req) async {
          if (req.url.path == '/Users/u1/Items/ep1') return _json(episode());
          if (req.url.path == '/Items/ep1/PlaybackInfo') {
            return _json(playbackInfo());
          }
          if (req.url.path == '/Videos/ep1/src1/Subtitles/3/0/Stream.ass') {
            return http.Response('', 500);
          }
          if (req.url.path == '/Videos/ep1/src1/Subtitles/3/Stream.ass') {
            return http.Response('[Script Info]\n', 200);
          }
          return http.Response('', 204);
        }, seen: seen),
        userId: 'u1',
      );
      await c.remoteVideoStreamUrls('ep1');
      final File dest = File('${tmp.path}/a.ass');
      await c.getRemoteVideoSubtitle('ep1', dest, embeddedStreamIndex: 3);
      expect(dest.readAsStringSync(), '[Script Info]\n');
      expect(seen.where((String p) => p.contains('/Subtitles/')), <String>[
        '/Videos/ep1/src1/Subtitles/3/0/Stream.ass',
        '/Videos/ep1/src1/Subtitles/3/Stream.ass',
      ]);
    });
  });
}
