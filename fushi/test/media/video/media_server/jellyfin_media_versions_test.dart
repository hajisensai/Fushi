// Emby / Jellyfin「同一条目多版本」（MediaSources > 1）的离线单测（MockClient）：
// 版本解析、记住的选择、选中版本的 MediaSourceId 进 PlaybackInfo / 直出 URL、
// 字幕轨按选中版本列出、播放页版本菜单（RemoteVideoStreamVariants）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoEmbeddedSubtitleTrack, RemoteVideoStreamUrls;

const String kServer = 'http://emby:8096';

http.Response _json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

/// Emby 4.9 `/Users/{uid}/Items/{id}` 一集双版本的真实形状（裁掉无关字段）：
/// 同一集挂 1080p H264 与 2160p HEVC 两个文件，各自的音轨 / 字幕轨不同。
Map<String, Object?> _twoVersionEpisode({
  String id = 'ep1',
  String sourceA = 'ms-1080',
  String sourceB = 'ms-2160',
}) => <String, Object?>{
  'Name': '第1话',
  'ServerId': 'srv',
  'Id': id,
  'Type': 'Episode',
  'SeriesId': 'series-1',
  'SeriesName': '葬送的芙莉莲',
  'SeasonId': 'season-1',
  'ParentIndexNumber': 1,
  'IndexNumber': 1,
  'RunTimeTicks': 14400000000,
  'UserData': <String, Object?>{'PlaybackPositionTicks': 0, 'Played': false},
  'MediaSources': <Object?>[
    <String, Object?>{
      'Protocol': 'File',
      'Id': sourceA,
      'Path': '/media/anime/Frieren/S01E01 - 1080p.mkv',
      'Type': 'Default',
      'Container': 'mkv',
      'Size': 2040109465,
      'Name': '1080p',
      'IsRemote': false,
      'RunTimeTicks': 14400000000,
      'SupportsDirectPlay': true,
      'Bitrate': 11200000,
      'MediaStreams': <Object?>[
        <String, Object?>{
          'Codec': 'h264',
          'Type': 'Video',
          'Index': 0,
          'Width': 1920,
          'Height': 1080,
          'BitRate': 10800000,
          'VideoRange': 'SDR',
          'DisplayTitle': '1080p H264',
        },
        <String, Object?>{
          'Codec': 'aac',
          'Language': 'jpn',
          'Type': 'Audio',
          'Index': 1,
          'IsDefault': true,
          'DisplayTitle': 'Japanese AAC stereo (默认)',
        },
        <String, Object?>{
          'Codec': 'ass',
          'Language': 'chi',
          'Type': 'Subtitle',
          'Index': 2,
          'IsExternal': false,
          'IsTextSubtitleStream': true,
          'DisplayTitle': '简体中文 ASS',
        },
      ],
    },
    <String, Object?>{
      'Protocol': 'File',
      'Id': sourceB,
      'Path': '/media/anime/Frieren/S01E01 - 2160p.mkv',
      'Container': 'mkv',
      'Size': 6442450944,
      'Name': '2160p HDR',
      'SupportsDirectPlay': true,
      'Bitrate': 35000000,
      'MediaStreams': <Object?>[
        <String, Object?>{
          'Codec': 'hevc',
          'Type': 'Video',
          'Index': 0,
          'Width': 3840,
          'Height': 2160,
          'VideoRange': 'HDR',
        },
        <String, Object?>{
          'Codec': 'flac',
          'Language': 'jpn',
          'Type': 'Audio',
          'Index': 1,
          'DisplayTitle': 'Japanese FLAC 5.1',
        },
        <String, Object?>{
          'Codec': 'aac',
          'Language': 'eng',
          'Type': 'Audio',
          'Index': 2,
          'DisplayTitle': 'English AAC stereo',
        },
        <String, Object?>{
          'Codec': 'subrip',
          'Language': 'eng',
          'Type': 'Subtitle',
          'Index': 3,
          'IsExternal': true,
          'IsTextSubtitleStream': true,
          'DisplayTitle': 'English SRT',
        },
      ],
    },
  ],
};

class _Router {
  _Router(this.handler);

  final http.Response Function(http.Request req) handler;
  final List<http.Request> seen = <http.Request>[];

  MockClient get client => MockClient((http.Request req) async {
    seen.add(req);
    return handler(req);
  });

  List<http.Request> playbackInfoRequests() => <http.Request>[
    for (final http.Request r in seen)
      if (r.url.path.endsWith('/PlaybackInfo')) r,
  ];
}

/// PlaybackInfo 照 Emby 行为回显请求里的 MediaSourceId 那一条（直播放）。
http.Response _playbackInfoFor(http.Request req) {
  final Map<String, Object?> body = (jsonDecode(req.body) as Map)
      .cast<String, Object?>();
  final String id = (body['MediaSourceId'] as String?) ?? 'ms-1080';
  return _json(<String, Object?>{
    'PlaySessionId': 'play-1',
    'MediaSources': <Object?>[
      <String, Object?>{'Id': id, 'SupportsDirectPlay': true},
    ],
  });
}

JellyfinVideoClient _client(http.Client mock) => JellyfinVideoClient(
  api: JellyfinApi(serverUrl: kServer, accessToken: 'tok', client: mock),
  userId: 'u1',
);

void main() {
  setUp(() {
    mediaServerVersionMemory = InMemoryMediaServerVersionMemory();
  });

  group('MediaSources 解析', () {
    test('itemDetail 给出全部版本：名称 / 分辨率 / 编码 / 大小 / 码率 / 音轨 / 字幕轨', () async {
      final _Router r = _Router((_) => _json(_twoVersionEpisode()));
      final MediaServerItem item = await _client(r.client).itemDetail('ep1');
      expect(item.versions, hasLength(2));
      final MediaServerVersion a = item.versions[0];
      expect(a.id, 'ms-1080');
      expect(a.title, '1080p');
      expect(a.resolutionLabel, '1080p');
      expect(a.qualitySummary, '1080p H264 · 1.9 GB · 11.2 Mbps');
      expect(a.audioTracks.single.label, 'Japanese AAC stereo (默认)');
      expect(a.audioTracks.single.isDefault, isTrue);
      expect(a.subtitleTracks.single.label, '简体中文 ASS');
      final MediaServerVersion b = item.versions[1];
      expect(b.qualitySummary, '2160p HEVC HDR · 6.0 GB · 35.0 Mbps');
      expect(b.audioTracks.map((MediaServerStreamTrack t) => t.index), <int>[
        1,
        2,
      ]);
      expect(b.subtitleTracks.single.isExternal, isTrue);
      expect(
        mediaServerVersionLabel(b),
        '2160p HDR · 2160p HEVC HDR · 6.0 GB · 35.0 Mbps',
      );
    });

    test('单版本 / 无 MediaSources 的条目：versions 至多一条，派生字段不变', () {
      final Map<String, Object?> json = _twoVersionEpisode();
      json['MediaSources'] = (json['MediaSources']! as List<Object?>).sublist(
        0,
        1,
      );
      final JellyfinItem one = JellyfinApi.parseItem(json);
      expect(one.mediaSources, hasLength(1));
      expect(one.mediaSourceId, 'ms-1080');
      final JellyfinItem none = JellyfinApi.parseItem(<String, Object?>{
        'Id': 'x',
        'Name': 'x',
        'Type': 'Movie',
      });
      expect(none.mediaSources, isEmpty);
      expect(none.mediaSourceId, isNull);
    });

    test('宽银幕 1920x800 仍归 1080p；无宽度看高度', () {
      expect(
        const MediaServerVersion(
          id: 'a',
          width: 1920,
          height: 800,
        ).resolutionLabel,
        '1080p',
      );
      expect(
        const MediaServerVersion(id: 'b', height: 720).resolutionLabel,
        '720p',
      );
      expect(const MediaServerVersion(id: 'c').resolutionLabel, isNull);
    });
  });

  group('选中版本进取流', () {
    test('没选过：PlaybackInfo 与直出 URL 带服务器默认 MediaSources[0]', () async {
      final _Router r = _Router(
        (http.Request req) => req.url.path.endsWith('/PlaybackInfo')
            ? _playbackInfoFor(req)
            : _json(_twoVersionEpisode()),
      );
      final RemoteVideoStreamUrls urls = await _client(
        r.client,
      ).remoteVideoStreamUrls('ep1');
      final Map<String, Object?> body =
          (jsonDecode(r.playbackInfoRequests().single.body) as Map)
              .cast<String, Object?>();
      expect(body['MediaSourceId'], 'ms-1080');
      expect(urls.streamUrl, contains('MediaSourceId=ms-1080'));
      expect(
        urls.embeddedSubtitleTracks.map(
          (RemoteVideoEmbeddedSubtitleTrack t) => t.streamIndex,
        ),
        <int>[2],
      );
    });

    test('记住的版本：MediaSourceId / 字幕轨都换成那条', () async {
      rememberMediaServerVersion(
        serverId: _client(MockClient((_) async => _json(<Object?>[]))).serverId,
        itemId: 'ep1',
        seriesId: 'series-1',
        version: const MediaServerVersion(id: 'ms-2160', name: '2160p HDR'),
      );
      final _Router r = _Router(
        (http.Request req) => req.url.path.endsWith('/PlaybackInfo')
            ? _playbackInfoFor(req)
            : _json(_twoVersionEpisode()),
      );
      final JellyfinVideoClient client = _client(r.client);
      final RemoteVideoStreamUrls urls = await client.remoteVideoStreamUrls(
        'ep1',
      );
      final Map<String, Object?> body =
          (jsonDecode(r.playbackInfoRequests().single.body) as Map)
              .cast<String, Object?>();
      expect(body['MediaSourceId'], 'ms-2160');
      expect(urls.streamUrl, contains('/Videos/ep1/stream'));
      expect(urls.streamUrl, contains('MediaSourceId=ms-2160'));
      // 字幕轨属于 2160p 那个文件：外挂 English SRT，URL 也挂在该版本下。
      final RemoteVideoEmbeddedSubtitleTrack sub =
          urls.embeddedSubtitleTracks.single;
      expect(sub.streamIndex, 3);
      expect(sub.url, contains('/Videos/ep1/ms-2160/Subtitles/3'));
      expect(urls.subtitleUrl, contains('/ms-2160/Subtitles/3'));
    });

    test('PlaybackInfo 缺失（兼容层 404）时直出 URL 仍带选中的 MediaSourceId', () async {
      final JellyfinVideoClient probe = _client(
        MockClient((_) async => _json(<Object?>[])),
      );
      rememberMediaServerVersion(
        serverId: probe.serverId,
        itemId: 'ep1',
        seriesId: null,
        version: const MediaServerVersion(id: 'ms-2160'),
      );
      final _Router r = _Router(
        (http.Request req) => req.url.path.endsWith('/PlaybackInfo')
            ? http.Response('', 404)
            : _json(_twoVersionEpisode()),
      );
      final RemoteVideoStreamUrls urls = await _client(
        r.client,
      ).remoteVideoStreamUrls('ep1');
      expect(urls.streamUrl, contains('MediaSourceId=ms-2160'));
    });

    test('同剧另一集没单独选过：按记住的版本名挑同类版本', () async {
      final JellyfinVideoClient probe = _client(
        MockClient((_) async => _json(<Object?>[])),
      );
      rememberMediaServerVersion(
        serverId: probe.serverId,
        itemId: 'ep1',
        seriesId: 'series-1',
        version: const MediaServerVersion(
          id: 'ms-2160',
          name: '2160p HDR',
          width: 3840,
          videoCodec: 'hevc',
          videoRange: 'HDR',
        ),
      );
      final _Router r = _Router(
        (http.Request req) => req.url.path.endsWith('/PlaybackInfo')
            ? _playbackInfoFor(req)
            : _json(
                _twoVersionEpisode(
                  id: 'ep2',
                  sourceA: 'ep2-1080',
                  sourceB: 'ep2-2160',
                ),
              ),
      );
      final RemoteVideoStreamUrls urls = await _client(
        r.client,
      ).remoteVideoStreamUrls('ep2');
      expect(urls.streamUrl, contains('MediaSourceId=ep2-2160'));
    });
  });

  group('播放页版本菜单（RemoteVideoStreamVariants）', () {
    test('取流后列出两个版本；改选记住并在下次取流生效', () async {
      final _Router r = _Router(
        (http.Request req) => req.url.path.endsWith('/PlaybackInfo')
            ? _playbackInfoFor(req)
            : _json(_twoVersionEpisode()),
      );
      final JellyfinVideoClient client = _client(r.client);
      expect(client.streamVariants, isEmpty);
      await client.remoteVideoStreamUrls('ep1');
      expect(
        client.streamVariants.map((RemoteVideoStreamVariant v) => v.label),
        <String>[
          '1080p · 1080p H264 · 1.9 GB · 11.2 Mbps',
          '2160p HDR · 2160p HEVC HDR · 6.0 GB · 35.0 Mbps',
        ],
      );
      expect(client.streamVariantIndex, 0);

      client.streamVariantIndex = 1;
      final RemoteVideoStreamUrls again = await client.remoteVideoStreamUrls(
        'ep1',
      );
      expect(again.streamUrl, contains('MediaSourceId=ms-2160'));
      expect(client.streamVariantIndex, 1);
    });

    test('单版本条目菜单为空', () async {
      final Map<String, Object?> json = _twoVersionEpisode();
      json['MediaSources'] = (json['MediaSources']! as List<Object?>).sublist(
        0,
        1,
      );
      final _Router r = _Router(
        (http.Request req) => req.url.path.endsWith('/PlaybackInfo')
            ? _playbackInfoFor(req)
            : _json(json),
      );
      final JellyfinVideoClient client = _client(r.client);
      await client.remoteVideoStreamUrls('ep1');
      expect(client.streamVariants, isEmpty);
    });
  });
}
