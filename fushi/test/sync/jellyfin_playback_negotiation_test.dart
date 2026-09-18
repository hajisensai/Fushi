// Jellyfin / Emby 起播协商与会话生命周期（离线，MockClient）。
//
// 成熟客户端（Jellyfin web / Emby 官方 / Infuse）起播的协议形状：
//   POST /Items/{id}/PlaybackInfo（带 DeviceProfile）→ 服务器裁决直播放 / 转码并签发
//   PlaySessionId → POST /Sessions/Playing → Progress（含暂停 / 继续事件）→ Stopped
//   （转码会话再 DELETE /Videos/ActiveEncodings）。
// 此前本仓手拼 static=true 直出 URL、从不发 Start、DeviceId 全体安装共用一个常量。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoEmbeddedSubtitleTrack, RemoteVideoStreamUrls;
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';

Map<String, Object?> _episodeJson() => <String, Object?>{
      'Id': 'ep1',
      'Name': 'The Pilot',
      'Type': 'Episode',
      'MediaSources': <Object?>[
        <String, Object?>{
          'Id': 'src1',
          'MediaStreams': <Object?>[
            <String, Object?>{'Type': 'Video', 'Index': 0},
          ],
        },
      ],
    };

Map<String, Object?> _playbackInfoJson({
  bool directPlay = true,
  String? transcodingUrl,
  String playSessionId = 'ps-1',
}) =>
    <String, Object?>{
      'PlaySessionId': playSessionId,
      'MediaSources': <Object?>[
        <String, Object?>{
          'Id': 'src1',
          'SupportsDirectPlay': directPlay,
          'SupportsDirectStream': directPlay,
          'SupportsTranscoding': true,
          if (transcodingUrl != null) 'TranscodingUrl': transcodingUrl,
        },
      ],
    };

void main() {
  late List<http.Request> seen;

  JellyfinVideoClient clientWith(
    Future<http.Response> Function(http.Request req) handler, {
    String deviceId = 'dev-42',
  }) {
    seen = <http.Request>[];
    return JellyfinVideoClient(
      api: JellyfinApi(
        serverUrl: 'http://nas:8096',
        accessToken: 'tok',
        deviceId: deviceId,
        client: MockClient((http.Request req) async {
          seen.add(req);
          return handler(req);
        }),
      ),
      userId: 'u1',
    );
  }

  http.Response json(Object? body) => http.Response(jsonEncode(body), 200);

  group('PlaybackInfo 协商', () {
    test('直播放：请求带 DeviceProfile，直出 URL 附 PlaySessionId + DeviceId', () async {
      final JellyfinVideoClient c = clientWith((http.Request req) async {
        if (req.url.path == '/Users/u1/Items/ep1') return json(_episodeJson());
        if (req.url.path == '/Items/ep1/PlaybackInfo') {
          expect(req.method, 'POST');
          expect(req.url.queryParameters['UserId'], 'u1');
          final Map<String, Object?> body =
              (jsonDecode(req.body) as Map).cast<String, Object?>();
          expect(body['UserId'], 'u1');
          expect(body['MediaSourceId'], 'src1');
          expect(body['EnableDirectPlay'], isTrue);
          expect(body['EnableTranscoding'], isTrue);
          expect(body['DeviceProfile'], isA<Map<String, Object?>>());
          final Map<String, Object?> profile =
              (body['DeviceProfile'] as Map).cast<String, Object?>();
          expect(profile['Name'], 'Hibiki');
          expect(profile['DirectPlayProfiles'], hasLength(2));
          expect(profile['TranscodingProfiles'], isNotEmpty);
          expect(body.containsKey('MaxStreamingBitrate'), isFalse,
              reason: '自动档不给上限');
          return json(_playbackInfoJson());
        }
        return http.Response('', 204);
      });
      final RemoteVideoStreamUrls urls = await c.remoteVideoStreamUrls('ep1');
      expect(
        urls.streamUrl,
        'http://nas:8096/Videos/ep1/stream?static=true&MediaSourceId=src1'
        '&PlaySessionId=ps-1&DeviceId=dev-42&api_key=tok',
      );
      expect(c.debugActiveSession('ep1')?.playMethod, 'DirectPlay');
      expect(c.debugActiveSession('ep1')?.isTranscoding, isFalse);
    });

    test('服务器判定转码：用它签发的 TranscodingUrl（补成绝对 URL）', () async {
      final JellyfinVideoClient c = clientWith((http.Request req) async {
        if (req.url.path == '/Users/u1/Items/ep1') return json(_episodeJson());
        if (req.url.path == '/Items/ep1/PlaybackInfo') {
          return json(_playbackInfoJson(
            directPlay: false,
            transcodingUrl:
                '/videos/ep1/master.m3u8?DeviceId=dev-42&PlaySessionId=ps-1'
                '&api_key=tok&VideoCodec=h264',
          ));
        }
        return http.Response('', 204);
      });
      final RemoteVideoStreamUrls urls = await c.remoteVideoStreamUrls('ep1');
      expect(
        urls.streamUrl,
        'http://nas:8096/videos/ep1/master.m3u8?DeviceId=dev-42'
        '&PlaySessionId=ps-1&api_key=tok&VideoCodec=h264',
      );
      expect(c.debugActiveSession('ep1')?.playMethod, 'Transcode');
    });

    test('选了画质档：PlaybackInfo 带 MaxStreamingBitrate + 宽度条件', () async {
      final JellyfinVideoClient c = clientWith((http.Request req) async {
        if (req.url.path == '/Users/u1/Items/ep1') return json(_episodeJson());
        if (req.url.path == '/Items/ep1/PlaybackInfo') {
          final Map<String, Object?> body =
              (jsonDecode(req.body) as Map).cast<String, Object?>();
          expect(body['MaxStreamingBitrate'], 3000000);
          final Map<String, Object?> profile =
              (body['DeviceProfile'] as Map).cast<String, Object?>();
          expect(profile['MaxStreamingBitrate'], 3000000);
          final List<Object?> codecProfiles =
              profile['CodecProfiles'] as List<Object?>;
          expect(codecProfiles, hasLength(1));
          final Map<String, Object?> condition =
              (((codecProfiles.single as Map)['Conditions'] as List).single
                      as Map)
                  .cast<String, Object?>();
          expect(condition['Property'], 'Width');
          expect(condition['Value'], '1280');
          return json(_playbackInfoJson());
        }
        return http.Response('', 204);
      });
      final int index = JellyfinVideoClient.kQualityPresets
          .indexWhere((MediaServerQualityPreset p) => p.maxBitrate == 3000000);
      expect(index, greaterThanOrEqualTo(0));
      c.qualityPresetIndex = index;
      await c.remoteVideoStreamUrls('ep1');
    });

    test('兼容层没有 PlaybackInfo（404 / 回 HTML）：回落手拼直出 URL，无会话', () async {
      for (final http.Response reply in <http.Response>[
        http.Response('', 404),
        http.Response('<!doctype html><html></html>', 200),
      ]) {
        final JellyfinVideoClient c = clientWith((http.Request req) async {
          if (req.url.path == '/Users/u1/Items/ep1') {
            return json(_episodeJson());
          }
          if (req.url.path == '/Items/ep1/PlaybackInfo') return reply;
          return http.Response('', 204);
        });
        final RemoteVideoStreamUrls urls = await c.remoteVideoStreamUrls('ep1');
        expect(
          urls.streamUrl,
          'http://nas:8096/Videos/ep1/stream?static=true&MediaSourceId=src1'
          '&api_key=tok',
        );
        expect(c.debugActiveSession('ep1'), isNull);
        // 无会话时 Start 什么都不发（服务器不认无会话的 Start），Progress 照旧。
        await c.startRemoteVideoPlayback('ep1', 0);
        expect(
          seen.where((http.Request r) => r.url.path == '/Sessions/Playing'),
          isEmpty,
        );
      }
    });
  });

  group('内嵌字幕轨的容器内序号与直出标记（BUG-2590）', () {
    // 真机形状（「UHD Media Server」Emby 兼容层）：视频 0 / 音频 1 / 字幕 2..5，
    // 全部 IsExternal=false、SupportsExternalStream=false；另模拟一条图形轨与一条
    // 外挂 srt 文件夹在中间，考验序号只数容器内的轨、图形轨也占号。
    Map<String, Object?> episodeWithSubs() => <String, Object?>{
          'Id': 'ep1',
          'Name': 'E01',
          'Type': 'Episode',
          'MediaSources': <Object?>[
            <String, Object?>{
              'Id': 'src1',
              'MediaStreams': <Object?>[
                <String, Object?>{'Type': 'Video', 'Index': 0},
                <String, Object?>{'Type': 'Audio', 'Index': 1},
                <String, Object?>{
                  'Type': 'Subtitle',
                  'Index': 2,
                  'Codec': 'subrip',
                  'Language': 'jpn',
                  'IsTextSubtitleStream': true,
                },
                <String, Object?>{
                  'Type': 'Subtitle',
                  'Index': 3,
                  'Codec': 'PGSSUB',
                  'IsTextSubtitleStream': false,
                },
                <String, Object?>{
                  'Type': 'Subtitle',
                  'Index': 4,
                  'Codec': 'subrip',
                  'Language': 'chi',
                  'IsTextSubtitleStream': true,
                },
                <String, Object?>{
                  'Type': 'Subtitle',
                  'Index': 5,
                  'Codec': 'srt',
                  'IsExternal': true,
                  'IsTextSubtitleStream': true,
                },
              ],
            },
          ],
        };

    test('containerSubtitleOrdinals：全局流号 → 容器内字幕序号，图形轨占号、外挂不占', () {
      final Map<int, int> ordinals =
          JellyfinVideoClient.containerSubtitleOrdinals(
        const <JellyfinSubtitleStream>[
          // 故意乱序：序号按 Index 升序算，与 MediaStreams 给出的顺序无关。
          JellyfinSubtitleStream(index: 4, codec: 'subrip'),
          JellyfinSubtitleStream(index: 9, codec: 'srt', isExternal: true),
          JellyfinSubtitleStream(
            index: 3,
            codec: 'PGSSUB',
            isTextSubtitleStream: false,
          ),
          JellyfinSubtitleStream(index: 2, codec: 'subrip'),
        ],
      );
      expect(ordinals, <int, int>{2: 0, 3: 1, 4: 2});
      expect(ordinals.containsKey(9), isFalse, reason: '外挂文件不在容器里');
    });

    test('直播放：轨带 containerTrackOrdinal，流标记为原始容器', () async {
      final JellyfinVideoClient c = clientWith((http.Request req) async {
        if (req.url.path == '/Users/u1/Items/ep1') {
          return json(episodeWithSubs());
        }
        if (req.url.path == '/Items/ep1/PlaybackInfo') {
          return json(_playbackInfoJson());
        }
        return http.Response('', 204);
      });
      final RemoteVideoStreamUrls urls = await c.remoteVideoStreamUrls('ep1');
      expect(urls.streamIsOriginalContainer, isTrue);
      final Map<int, int?> byIndex = <int, int?>{
        for (final RemoteVideoEmbeddedSubtitleTrack t
            in urls.embeddedSubtitleTracks)
          t.streamIndex: t.containerTrackOrdinal,
      };
      // 文本轨 2 / 4 / 5 进选择器；图形轨 3 不进但占了容器内第 1 号；外挂 5 无序号。
      expect(byIndex, <int, int?>{2: 0, 4: 2, 5: null});
    });

    test('转码 HLS：流不是原始容器（libmpv 自绘回落不可用）', () async {
      final JellyfinVideoClient c = clientWith((http.Request req) async {
        if (req.url.path == '/Users/u1/Items/ep1') {
          return json(episodeWithSubs());
        }
        if (req.url.path == '/Items/ep1/PlaybackInfo') {
          return json(_playbackInfoJson(
            directPlay: false,
            transcodingUrl: '/videos/ep1/master.m3u8?PlaySessionId=ps-1',
          ));
        }
        return http.Response('', 204);
      });
      final RemoteVideoStreamUrls urls = await c.remoteVideoStreamUrls('ep1');
      expect(urls.streamIsOriginalContainer, isFalse);
    });

    test('兼容层没有 PlaybackInfo：手拼直出仍是原始容器', () async {
      final JellyfinVideoClient c = clientWith((http.Request req) async {
        if (req.url.path == '/Users/u1/Items/ep1') {
          return json(episodeWithSubs());
        }
        if (req.url.path == '/Items/ep1/PlaybackInfo') {
          return http.Response('', 404);
        }
        return http.Response('', 204);
      });
      final RemoteVideoStreamUrls urls = await c.remoteVideoStreamUrls('ep1');
      expect(urls.streamIsOriginalContainer, isTrue);
    });
  });

  group('会话生命周期', () {
    Future<JellyfinVideoClient> negotiated({
      bool transcode = false,
    }) async {
      final JellyfinVideoClient c = clientWith((http.Request req) async {
        if (req.url.path == '/Users/u1/Items/ep1') return json(_episodeJson());
        if (req.url.path == '/Items/ep1/PlaybackInfo') {
          return json(_playbackInfoJson(
            directPlay: !transcode,
            transcodingUrl: transcode ? '/videos/ep1/master.m3u8?x=1' : null,
          ));
        }
        return http.Response('', 204);
      });
      await c.remoteVideoStreamUrls('ep1');
      return c;
    }

    Map<String, Object?> bodyOf(http.Request r) =>
        (jsonDecode(r.body) as Map).cast<String, Object?>();

    test('Start → Progress（timeupdate）→ 暂停 / 继续 → Stopped 全带会话身份', () async {
      final JellyfinVideoClient c = await negotiated();
      await c.startRemoteVideoPlayback('ep1', 5000);
      final http.Request start =
          seen.lastWhere((http.Request r) => r.url.path == '/Sessions/Playing');
      expect(bodyOf(start)['PlaySessionId'], 'ps-1');
      expect(bodyOf(start)['MediaSourceId'], 'src1');
      expect(bodyOf(start)['PlayMethod'], 'DirectPlay');
      expect(bodyOf(start)['PositionTicks'], 5000 * kTicksPerMs);
      expect(bodyOf(start)['IsPaused'], isFalse);

      await c.putRemoteVideoPosition('ep1', 15000, 1);
      final http.Request progress = seen.lastWhere(
          (http.Request r) => r.url.path == '/Sessions/Playing/Progress');
      expect(bodyOf(progress)['PlaySessionId'], 'ps-1');
      expect(bodyOf(progress)['EventName'], 'timeupdate');
      expect(bodyOf(progress)['IsPaused'], isFalse);

      // 暂停 / 继续即时上报，不受 10s 心跳节流（紧接着上一条 Progress 也照发）。
      await c.setRemoteVideoPlaybackPaused('ep1', 16000, paused: true);
      final http.Request pause = seen.last;
      expect(pause.url.path, '/Sessions/Playing/Progress');
      expect(bodyOf(pause)['IsPaused'], isTrue);
      expect(bodyOf(pause)['EventName'], 'pause');
      await c.setRemoteVideoPlaybackPaused('ep1', 16000, paused: false);
      expect(bodyOf(seen.last)['EventName'], 'unpause');

      await c.stopRemoteVideoPlayback('ep1', 20000);
      final http.Request stopped = seen.lastWhere(
          (http.Request r) => r.url.path == '/Sessions/Playing/Stopped');
      expect(bodyOf(stopped)['PlaySessionId'], 'ps-1');
      expect(bodyOf(stopped)['PositionTicks'], 20000 * kTicksPerMs);
      expect(
        seen.where((http.Request r) => r.url.path == '/Videos/ActiveEncodings'),
        isEmpty,
        reason: '直播放没有转码任务可清',
      );
      expect(c.debugActiveSession('ep1'), isNull, reason: '停止后会话出队');
    });

    test('转码会话 Stopped 后 DELETE /Videos/ActiveEncodings', () async {
      final JellyfinVideoClient c = await negotiated(transcode: true);
      await c.stopRemoteVideoPlayback('ep1', 20000);
      final http.Request cleanup = seen.lastWhere(
          (http.Request r) => r.url.path == '/Videos/ActiveEncodings');
      expect(cleanup.method, 'DELETE');
      expect(cleanup.url.queryParameters['DeviceId'], 'dev-42');
      expect(cleanup.url.queryParameters['PlaySessionId'], 'ps-1');
    });

    test('同一条目「退出→立刻重开」：Stopped 按先进先出取旧会话，不拿新会话报停', () async {
      int issued = 0;
      final JellyfinVideoClient c = clientWith((http.Request req) async {
        if (req.url.path == '/Users/u1/Items/ep1') return json(_episodeJson());
        if (req.url.path == '/Items/ep1/PlaybackInfo') {
          issued++;
          return json(_playbackInfoJson(playSessionId: 'ps-$issued'));
        }
        return http.Response('', 204);
      });
      await c.remoteVideoStreamUrls('ep1'); // 旧页
      await c.remoteVideoStreamUrls('ep1'); // 新页先协商
      await c.stopRemoteVideoPlayback('ep1', 1000); // 旧页的停止晚到
      final http.Request stopped = seen.lastWhere(
          (http.Request r) => r.url.path == '/Sessions/Playing/Stopped');
      expect(bodyOf(stopped)['PlaySessionId'], 'ps-1');
      expect(c.debugActiveSession('ep1')?.playSessionId, 'ps-2',
          reason: '新页的会话仍在');
    });
  });

  group('设备身份', () {
    test('认证头 DeviceId 用配置里的 per-install id；旧配置回落常量', () {
      expect(
        JellyfinApi.authHeaderFor('tok', 'dev-42'),
        contains('DeviceId="dev-42"'),
      );
      expect(
        JellyfinApi.authHeaderFor('tok'),
        contains('DeviceId="${JellyfinApi.kLegacyDeviceId}"'),
      );
      const JellyfinServerConfig fresh = JellyfinServerConfig(
        serverUrl: 'http://nas:8096',
        username: 'u',
        userId: 'u1',
        accessToken: 'tok',
        deviceId: 'dev-42',
      );
      expect(fresh.toJson()['deviceId'], 'dev-42');
      final JellyfinServerConfig? legacy = JellyfinServerConfig.fromJson(
        <String, dynamic>{
          'serverUrl': 'http://nas:8096',
          'userId': 'u1',
          'accessToken': 'tok',
        },
      );
      expect(legacy!.deviceId, JellyfinApi.kLegacyDeviceId,
          reason: '令牌与 DeviceId 绑定：旧配置不能换 id，否则用户被迫重登');
      expect(legacy.toJson().containsKey('deviceId'), isFalse);
      expect(fresh.buildClient().api.deviceId, 'dev-42');
    });
  });

  group('连接诊断', () {
    test('normalizeServerUrl：scheme 不分大小写', () {
      expect(JellyfinApi.normalizeServerUrl('HTTP://nas:8096/'),
          'http://nas:8096');
      expect(JellyfinApi.normalizeServerUrl('Https://nas'), 'https://nas');
      expect(JellyfinApi.normalizeServerUrl('nas:8096'), 'http://nas:8096');
    });

    test('isHostLookupFailure 认 Dart 的 host lookup 异常，不误判连接被拒', () {
      expect(
        JellyfinApi.isHostLookupFailure(
          const SocketException('Failed host lookup: \'nas.local\''),
        ),
        isTrue,
      );
      expect(
        JellyfinApi.isHostLookupFailure(
          const SocketException('Connection refused'),
        ),
        isFalse,
      );
      expect(JellyfinApi.isHostLookupFailure(StateError('x')), isFalse);
    });

    test('publicSystemInfo 走 /System/Info/Public 并回服务器名', () async {
      final JellyfinVideoClient c = clientWith((http.Request req) async {
        expect(req.url.path, '/System/Info/Public');
        return json(<String, Object?>{'ServerName': 'NAS', 'Version': '10.10'});
      });
      expect(await c.api.publicSystemInfo(), 'NAS');
    });
  });
}
