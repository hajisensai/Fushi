// JellyfinApi / JellyfinVideoClient 离线单测（MockClient，无真实服务器）。
// 覆盖：URL 归一化、认证头与令牌回填、JSON→DTO 解析（tick→ms、字幕流、
// 单集展示标题）、RemoteVideoClient 适配（清单映射 / 流 URL 自带 api_key /
// 外挂字幕优先 / 断点读写）。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo, RemoteVideoStreamUrls;
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

Map<String, Object?> _episodeJson({
  String id = 'ep1',
  int? positionTicks,
  List<Map<String, Object?>> subtitleStreams = const <Map<String, Object?>>[],
}) =>
    <String, Object?>{
      'Id': id,
      'Name': 'The Pilot',
      'Type': 'Episode',
      'SeriesName': 'Show A',
      'ParentIndexNumber': 1,
      'IndexNumber': 2,
      'RunTimeTicks': 90 * 60 * 1000 * kTicksPerMs,
      'ImageTags': <String, Object?>{'Primary': 'tag'},
      'UserData': <String, Object?>{
        'PlaybackPositionTicks': positionTicks ?? 0,
      },
      'MediaSources': <Object?>[
        <String, Object?>{
          'Id': 'src1',
          'MediaStreams': <Object?>[
            <String, Object?>{'Type': 'Video', 'Index': 0},
            ...subtitleStreams,
          ],
        },
      ],
    };

void main() {
  group('JellyfinApi.normalizeServerUrl', () {
    test('补 scheme、去尾斜杠', () {
      expect(JellyfinApi.normalizeServerUrl('nas.local:8096/'),
          'http://nas.local:8096');
      expect(JellyfinApi.normalizeServerUrl('https://jf.example.com//'),
          'https://jf.example.com');
      expect(JellyfinApi.normalizeServerUrl('  '), '');
    });
  });

  group('解析（纯函数）', () {
    test('parseAuthResult 取令牌与用户 id', () {
      final JellyfinAuthResult r =
          JellyfinApi.parseAuthResult(<String, Object?>{
        'AccessToken': 'tok',
        'ServerName': 'NAS',
        'User': <String, Object?>{'Id': 'u1'},
      });
      expect(r.accessToken, 'tok');
      expect(r.userId, 'u1');
      expect(r.serverName, 'NAS');
    });

    test('parseViews 保留 collectionType；isVideoish 滤掉音乐/图书', () {
      final List<JellyfinLibraryView> views =
          JellyfinApi.parseViews(<String, Object?>{
        'Items': <Object?>[
          <String, Object?>{
            'Id': 'v1',
            'Name': '电影',
            'CollectionType': 'movies'
          },
          <String, Object?>{
            'Id': 'v2',
            'Name': '音乐',
            'CollectionType': 'music'
          },
          <String, Object?>{'Id': 'v3', 'Name': '混合'},
        ],
      });
      expect(views, hasLength(3));
      expect(views[0].isVideoish, isTrue);
      expect(views[1].isVideoish, isFalse);
      expect(views[2].isVideoish, isTrue);
    });

    test('parseItem：tick→ms、字幕流、单集展示标题', () {
      final JellyfinItem item = JellyfinApi.parseItem(_episodeJson(
        positionTicks: 5000 * kTicksPerMs,
        subtitleStreams: <Map<String, Object?>>[
          <String, Object?>{
            'Type': 'Subtitle',
            'Index': 2,
            'Codec': 'subrip',
            'Language': 'jpn',
            'IsExternal': true,
            'IsTextSubtitleStream': true,
          },
        ],
      ));
      expect(item.durationMs, 90 * 60 * 1000);
      expect(item.positionMs, 5000);
      expect(item.hasPrimaryImage, isTrue);
      expect(item.displayTitle, 'Show A S01E02 The Pilot');
      expect(item.mediaSourceId, 'src1');
      expect(item.subtitleStreams.single.index, 2);
      expect(item.subtitleStreams.single.isExternal, isTrue);
      expect(item.isPlayableVideo, isTrue);
    });
  });

  group('JellyfinApi HTTP（MockClient）', () {
    test('authenticateByName 带 MediaBrowser 头并回填令牌', () async {
      late http.Request seen;
      final JellyfinApi api = JellyfinApi(
        serverUrl: 'http://nas:8096',
        client: MockClient((http.Request req) async {
          seen = req;
          return http.Response(
            jsonEncode(<String, Object?>{
              'AccessToken': 'tok',
              'User': <String, Object?>{'Id': 'u1'},
            }),
            200,
          );
        }),
      );
      final JellyfinAuthResult r = await api.authenticateByName('u', 'p');
      expect(seen.url.path, '/Users/AuthenticateByName');
      expect(seen.headers['Authorization'], contains('MediaBrowser'));
      expect(
          jsonDecode(seen.body), <String, Object?>{'Username': 'u', 'Pw': 'p'});
      expect(r.userId, 'u1');
      expect(api.accessToken, 'tok', reason: '认证成功必须回填令牌供后续 URL 构造');
    });

    test('认证失败抛 JellyfinApiException（状态码保留）', () async {
      final JellyfinApi api = JellyfinApi(
        serverUrl: 'http://nas:8096',
        client: MockClient((_) async => http.Response('', 401)),
      );
      await expectLater(
        api.authenticateByName('u', 'bad'),
        throwsA(isA<JellyfinApiException>()
            .having((JellyfinApiException e) => e.statusCode, 'status', 401)),
      );
    });

    test('reportStopped 上报 ticks（ms×10000）', () async {
      late http.Request seen;
      final JellyfinApi api = JellyfinApi(
        serverUrl: 'http://nas:8096',
        accessToken: 'tok',
        client: MockClient((http.Request req) async {
          seen = req;
          return http.Response('', 204);
        }),
      );
      await api.reportStopped(itemId: 'ep1', positionMs: 1234);
      expect(seen.url.path, '/Sessions/Playing/Stopped');
      expect(jsonDecode(seen.body), <String, Object?>{
        'ItemId': 'ep1',
        'PositionTicks': 1234 * kTicksPerMs
      });
      expect(seen.headers['Authorization'], contains('Token="tok"'));
    });
  });

  group('JellyfinVideoClient (RemoteVideoClient 适配)', () {
    JellyfinVideoClient clientWith(MockClient mock) => JellyfinVideoClient(
          api: JellyfinApi(
            serverUrl: 'http://nas:8096',
            accessToken: 'tok',
            client: mock,
          ),
          userId: 'u1',
        );

    test('remoteLibrarySourceId 按服务器细分', () {
      final JellyfinVideoClient c =
          clientWith(MockClient((_) async => http.Response('{}', 200)));
      expect(c.remoteLibrarySourceId, 'jellyfin:http://nas:8096');
    });

    test('coverCacheNamespace 按服务器+用户稳定细分（BUG-1693 口径）', () {
      final JellyfinVideoClient a =
          clientWith(MockClient((_) async => http.Response('{}', 200)));
      final JellyfinVideoClient b = JellyfinVideoClient(
        api: JellyfinApi(
          serverUrl: 'http://other:8096',
          accessToken: 'tok2',
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
        userId: 'u1',
      );
      expect(a.coverCacheNamespace, startsWith('jellyfin-'));
      expect(a.coverCacheNamespace, isNot(b.coverCacheNamespace),
          reason: '换服务器必须换封面缓存命名空间（防串味）');
      final JellyfinVideoClient a2 =
          clientWith(MockClient((_) async => http.Response('{}', 200)));
      expect(a.coverCacheNamespace, a2.coverCacheNamespace,
          reason: '同服务器同用户跨实例稳定（换令牌不重下封面）');
    });

    test('listRemoteVideos 映射标题/时长/封面 URL（自带 api_key）/断点', () async {
      final JellyfinVideoClient c =
          clientWith(MockClient((http.Request req) async {
        expect(req.url.path, '/Users/u1/Items');
        expect(req.url.queryParameters['Recursive'], 'true');
        expect(req.url.queryParameters['IncludeItemTypes'], 'Movie,Episode');
        return http.Response(
          jsonEncode(<String, Object?>{
            'Items': <Object?>[
              _episodeJson(positionTicks: 60000 * kTicksPerMs)
            ],
            'TotalRecordCount': 1,
          }),
          200,
        );
      }));
      final List<RemoteVideoInfo> list = await c.listRemoteVideos();
      final RemoteVideoInfo info = list.single;
      expect(info.id, 'ep1');
      expect(info.title, 'Show A S01E02 The Pilot');
      expect(info.durationMs, 90 * 60 * 1000);
      expect(info.positionMs, 60000);
      expect(info.hasCover, isTrue);
      expect(info.coverUrl,
          'http://nas:8096/Items/ep1/Images/Primary?api_key=tok');
      // 「显示视频库」结构表达：单集按剧名折叠成 playlist 合集卡。
      expect(info.collection?.collectionName, 'Show A');
      expect(info.collection?.collectionType, 'playlist');
      expect(info.collection?.sortIndex, 1 * 10000 + 2,
          reason: '组内序 = 季×10000+集，跨季自然有序');
    });

    test('remoteVideoStreamUrls：直连流自带 api_key，外挂文本字幕优先', () async {
      final JellyfinVideoClient c =
          clientWith(MockClient((http.Request req) async {
        expect(req.url.path, '/Users/u1/Items/ep1');
        return http.Response(
          jsonEncode(_episodeJson(
            subtitleStreams: <Map<String, Object?>>[
              <String, Object?>{
                'Type': 'Subtitle',
                'Index': 1,
                'Codec': 'ass',
                'IsExternal': false,
                'IsTextSubtitleStream': true,
              },
              <String, Object?>{
                'Type': 'Subtitle',
                'Index': 3,
                'Codec': 'subrip',
                'Language': 'jpn',
                'IsExternal': true,
                'IsTextSubtitleStream': true,
              },
              <String, Object?>{
                'Type': 'Subtitle',
                'Index': 4,
                'Codec': 'pgssub',
                'IsExternal': false,
                'IsTextSubtitleStream': false,
              },
            ],
          )),
          200,
        );
      }));
      final RemoteVideoStreamUrls urls = await c.remoteVideoStreamUrls('ep1');
      expect(urls.streamUrl,
          'http://nas:8096/Videos/ep1/stream?static=true&api_key=tok');
      expect(urls.subtitleUrl,
          'http://nas:8096/Videos/ep1/src1/Subtitles/3/Stream.srt?api_key=tok',
          reason: '外挂文本轨优先作为默认外挂字幕');
      expect(urls.subtitleFileName, 'Show A S01E02 The Pilot.jpn.srt');
      expect(urls.embeddedSubtitleTracks, hasLength(2),
          reason: '图形字幕（pgssub）不进文本轨选择器');
      expect(urls.miningVideoHasAudio, isTrue);
    });

    test('remoteVideoPosition 读 UserData；put 走 reportStopped', () async {
      final List<http.Request> seen = <http.Request>[];
      final JellyfinVideoClient c =
          clientWith(MockClient((http.Request req) async {
        seen.add(req);
        if (req.method == 'POST') return http.Response('', 204);
        return http.Response(
            jsonEncode(_episodeJson(positionTicks: 42000 * kTicksPerMs)), 200);
      }));
      final ({int positionMs, int updatedAtMs}) pos =
          await c.remoteVideoPosition('ep1');
      expect(pos.positionMs, 42000);
      expect(pos.updatedAtMs, 0, reason: '服务器无更新时刻——报 0 让本地较新时间戳自然赢');

      await c.putRemoteVideoPosition('ep1', 90000, 1755000000000);
      expect(seen.last.method, 'POST');
      expect(seen.last.url.path, '/Sessions/Playing/Stopped');
      expect(jsonDecode(seen.last.body)['PositionTicks'], 90000 * kTicksPerMs);
    });
  });

  group('JellyfinServerConfig 持久化（SyncRepository）', () {
    test('set → get 往返；null = 登出删键', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      expect(await repo.getJellyfinServer(), isNull);

      const JellyfinServerConfig config = JellyfinServerConfig(
        serverUrl: 'http://nas:8096',
        username: 'u',
        userId: 'u1',
        accessToken: 'tok',
        serverName: 'NAS',
      );
      await repo.setJellyfinServer(config);
      final JellyfinServerConfig? loaded = await repo.getJellyfinServer();
      expect(loaded, isNotNull);
      expect(loaded!.serverUrl, 'http://nas:8096');
      expect(loaded.userId, 'u1');
      expect(loaded.accessToken, 'tok');
      expect(loaded.serverName, 'NAS');

      await repo.setJellyfinServer(null);
      expect(await repo.getJellyfinServer(), isNull);
    });

    test('缺关键字段的脏 JSON → null（不崩）', () {
      expect(
        JellyfinServerConfig.fromJson(<String, dynamic>{
          'serverUrl': 'http://nas:8096',
        }),
        isNull,
      );
    });

    test('sync_jellyfin_server 在设备本地键目录（令牌不随备份跨设备）', () {
      expect(
          SyncRepository.deviceLocalPrefKeys, contains('sync_jellyfin_server'));
    });
  });
}
