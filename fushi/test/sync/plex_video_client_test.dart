// PlexVideoClient（MediaServerBrowser + RemoteVideoClient）离线单测：假 PMS 走
// MockClient，按路径分发。锁住：
//  [A] 每个请求带 Accept: application/json + X-Plex-* 身份头 + X-Plex-Token；
//  [B] 浏览各层：库（只留视频库、库 id 带前缀）→ 库内分页（Container-Start/Size、
//      sort、nextStartIndex 按服务器行数）→ 季（excludeAllLeaves）→ 集（季 /
//      allLeaves）→ 详情；首页三行的端点与回退、失败即空；搜索客户端把关 + 不分页；
//  [C] 封面走 /photo/:/transcode 带 token；库封面不给；
//  [D] 取流 = Part.key 直链 + token（direct play）；外挂字幕给下载 URL、容器内字幕
//      只给序号（下载时抛 → 播放页回落 libmpv）；
//  [E] 进度：timeline playing（10s 节流）/ paused / stopped，过 90% 显式 scrobble；
//      续播读 viewOffset + lastViewedAt；
//  [F] 网络层异常文本里的 X-Plex-Token 被脱敏。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/sync/plex_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show
        RemoteVideoEmbeddedSubtitleTrack,
        RemoteVideoInfo,
        RemoteVideoStreamUrls;

const String kServer = 'http://pms.lan:32400';
const String kToken = 'tok-SECRET-123';

http.Response _mc(Map<String, Object?> container, [int status = 200]) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(<String, Object?>{'MediaContainer': container})),
      status,
    );

Map<String, Object?> _episode(
  String key, {
  int season = 1,
  int index = 1,
  int viewOffset = 0,
  int viewCount = 0,
}) => <String, Object?>{
  'ratingKey': key,
  'type': 'episode',
  'title': 'Ep $index',
  'grandparentRatingKey': 'show-1',
  'grandparentTitle': 'Show A',
  'grandparentArt': '/library/metadata/show-1/art/1',
  'parentRatingKey': 'season-$season',
  'parentIndex': season,
  'index': index,
  'duration': 1440000,
  'viewOffset': viewOffset,
  'viewCount': viewCount,
  'thumb': '/library/metadata/$key/thumb/1',
};

Map<String, Object?> _detailEpisode() => <String, Object?>{
  ..._episode('ep-9', index: 2, viewOffset: 60000),
  'lastViewedAt': 1700000000,
  'summary': 'Plot',
  'Media': <Object?>[
    <String, Object?>{
      'id': 5,
      'duration': 1440000,
      'Part': <Object?>[
        <String, Object?>{
          'id': 77,
          'key': '/library/parts/77/1690000000/file.mkv',
          'size': 123456,
          'container': 'mkv',
          'Stream': <Object?>[
            <String, Object?>{'id': 1, 'streamType': 1, 'index': 0},
            <String, Object?>{'id': 2, 'streamType': 2, 'index': 1},
            // 容器内图形轨：占 libmpv 序号，但不报给文本轨列表。
            <String, Object?>{
              'id': 3,
              'streamType': 3,
              'index': 2,
              'codec': 'pgs',
            },
            <String, Object?>{
              'id': 4,
              'streamType': 3,
              'index': 3,
              'codec': 'ass',
              'languageCode': 'jpn',
            },
            // 外挂 sidecar：有 key、无 index。
            <String, Object?>{
              'id': 9,
              'streamType': 3,
              'codec': 'srt',
              'languageCode': 'chi',
              'key': '/library/streams/9',
            },
          ],
        },
      ],
    },
  ],
};

class _FakePms {
  final List<http.Request> seen = <http.Request>[];

  /// 让某些路径失败（模拟旧版 PMS 没有新 hub）。
  final Set<String> failing = <String>{};

  MockClient client() => MockClient((http.Request req) async {
    seen.add(req);
    final String path = req.url.path;
    if (failing.contains(path)) return http.Response('nope', 404);
    switch (path) {
      case '/identity':
        return _mc(<String, Object?>{'machineIdentifier': 'mid-1'});
      case '/library/sections':
        return _mc(<String, Object?>{
          'Directory': <Object?>[
            <String, Object?>{'key': '1', 'type': 'movie', 'title': 'Movies'},
            <String, Object?>{'key': '2', 'type': 'show', 'title': 'Anime'},
            <String, Object?>{'key': '3', 'type': 'artist', 'title': 'Music'},
          ],
        });
      case '/library/sections/2/all':
        return _mc(<String, Object?>{
          'totalSize': 130,
          'offset': 60,
          'Metadata': <Object?>[
            <String, Object?>{
              'ratingKey': 'show-1',
              'type': 'show',
              'title': 'Show A',
              'childCount': 2,
              'leafCount': 24,
              'viewedLeafCount': 4,
              'thumb': '/library/metadata/show-1/thumb/1',
              'art': '/library/metadata/show-1/art/1',
              'Genre': <Object?>[
                <String, Object?>{'tag': 'Drama'},
              ],
              'Image': <Object?>[
                <String, Object?>{'type': 'clearLogo', 'url': '/x'},
              ],
            },
            // 非视频域条目被滤掉，但仍占服务器行。
            <String, Object?>{
              'ratingKey': 'artist-1',
              'type': 'artist',
              'title': 'Band',
            },
          ],
        });
      case '/library/metadata/show-1/children':
        return _mc(<String, Object?>{
          'Metadata': <Object?>[
            <String, Object?>{
              'ratingKey': 'season-2',
              'type': 'season',
              'title': 'Season 2',
              'index': 2,
              'parentRatingKey': 'show-1',
              'parentTitle': 'Show A',
              'leafCount': 12,
            },
            <String, Object?>{
              'ratingKey': 'season-1',
              'type': 'season',
              'title': 'Season 1',
              'index': 1,
              'parentRatingKey': 'show-1',
              'parentTitle': 'Show A',
              'leafCount': 12,
            },
          ],
        });
      case '/library/metadata/season-1/children':
        return _mc(<String, Object?>{
          'totalSize': 2,
          'Metadata': <Object?>[
            _episode('ep-2', index: 2),
            _episode('ep-1', index: 1, viewCount: 1),
          ],
        });
      case '/library/metadata/show-1/allLeaves':
        return _mc(<String, Object?>{
          'totalSize': 3,
          'Metadata': <Object?>[
            _episode('ep-1', index: 1),
            _episode('ep-2', index: 2),
            _episode('ep-3', season: 2, index: 1),
          ],
        });
      case '/library/metadata/ep-9':
        return _mc(<String, Object?>{
          'Metadata': <Object?>[_detailEpisode()],
        });
      case '/hubs/continueWatching/items':
        return _mc(<String, Object?>{
          'Metadata': <Object?>[
            _episode('ep-5', index: 5, viewOffset: 1000),
            _episode('ep-6', index: 6),
          ],
        });
      case '/library/onDeck':
        return _mc(<String, Object?>{
          'Metadata': <Object?>[
            _episode('ep-7', index: 7, viewOffset: 500),
            _episode('ep-8', index: 8),
          ],
        });
      case '/library/sections/2/recentlyAdded':
        return _mc(<String, Object?>{
          'Metadata': <Object?>[_episode('ep-3', season: 2, index: 1)],
        });
      case '/hubs/search':
        return _mc(<String, Object?>{
          'Hub': <Object?>[
            <String, Object?>{
              'type': 'movie',
              'Metadata': <Object?>[
                <String, Object?>{
                  'ratingKey': 'm-2',
                  'type': 'movie',
                  'title': 'Something Else',
                },
                <String, Object?>{
                  'ratingKey': 'm-1',
                  'type': 'movie',
                  'title': 'Frieren',
                },
              ],
            },
            <String, Object?>{
              'type': 'show',
              'Metadata': <Object?>[
                <String, Object?>{
                  'ratingKey': 's-1',
                  'type': 'show',
                  'title': 'Sousou no Frieren',
                },
              ],
            },
            <String, Object?>{
              'type': 'episode',
              'Metadata': <Object?>[_episode('ep-frieren')],
            },
          ],
        });
      case '/:/timeline':
      case '/:/scrobble':
      case '/:/unscrobble':
        return http.Response('', 200);
    }
    return http.Response('not found', 404);
  });
}

PlexVideoClient _client(_FakePms pms) => PlexVideoClient(
  api: PlexApi(
    serverUrl: kServer,
    token: kToken,
    clientInfo: const PlexClientInfo(
      clientIdentifier: 'client-uuid',
      platform: 'Windows',
    ),
    client: pms.client(),
  ),
  machineIdentifier: 'mid-1',
  accountId: '42',
  serverName: 'Home PMS',
);

List<http.Request> _hits(_FakePms pms, String path) => <http.Request>[
  for (final http.Request r in pms.seen)
    if (r.url.path == path) r,
];

void main() {
  group('[A] 请求头', () {
    test('Accept json + X-Plex-* 身份头 + token', () async {
      final _FakePms pms = _FakePms();
      await _client(pms).listLibraries();
      final http.Request req = pms.seen.single;
      expect(req.headers['Accept'], 'application/json');
      expect(req.headers['X-Plex-Client-Identifier'], 'client-uuid');
      expect(req.headers['X-Plex-Product'], PlexClientInfo.kPlexProduct);
      expect(req.headers['X-Plex-Version'], isNotEmpty);
      expect(req.headers['X-Plex-Platform'], 'Windows');
      expect(req.headers['X-Plex-Token'], kToken);
    });
  });

  group('[B] 浏览', () {
    test('库：只留视频库，id 带前缀，类型映射', () async {
      final List<MediaServerLibrary> libs = await _client(
        _FakePms(),
      ).listLibraries();
      expect(libs.map((MediaServerLibrary l) => l.id), <String>[
        'lib:1',
        'lib:2',
      ]);
      expect(libs[0].kind, MediaServerLibraryKind.movies);
      expect(libs[1].kind, MediaServerLibraryKind.tvShows);
      expect(libs.every((MediaServerLibrary l) => !l.hasCover), isTrue);
    });

    test('库内分页：Container-Start/Size + sort；nextStartIndex 按服务器行数', () async {
      final _FakePms pms = _FakePms();
      final MediaServerPage page = await _client(pms).listChildren(
        parentId: 'lib:2',
        startIndex: 60,
        sort: MediaServerSort.dateAdded,
      );
      final Uri url = pms.seen.single.url;
      expect(url.path, '/library/sections/2/all');
      expect(url.queryParameters['X-Plex-Container-Start'], '60');
      expect(url.queryParameters['X-Plex-Container-Size'], '60');
      expect(url.queryParameters['sort'], 'addedAt:desc');
      expect(page.items, hasLength(1), reason: 'artist 被滤掉');
      expect(page.totalCount, 130);
      expect(page.nextStartIndex, 62, reason: '被滤掉的行照样占服务器序号');
      expect(page.hasMore, isTrue);
      final MediaServerItem show = page.items.single;
      expect(show.type, MediaServerItemType.series);
      expect(show.childCount, 2);
      expect(show.episodeCount, 24);
      expect(show.unplayedChildCount, 20);
      expect(show.hasCover, isTrue);
      expect(show.hasBackdrop, isTrue);
      expect(show.hasLogo, isTrue);
      expect(show.hasThumb, isFalse);
      expect(show.genres, <String>['Drama']);
    });

    test('非库 id 走 /library/metadata/{id}/children', () async {
      final _FakePms pms = _FakePms();
      await _client(pms).listChildren(parentId: 'show-1');
      expect(pms.seen.single.url.path, '/library/metadata/show-1/children');
      expect(pms.seen.single.url.queryParameters['excludeAllLeaves'], '1');
    });

    test('服务器根（null）= 把视频库当文件夹列出', () async {
      final MediaServerPage page = await _client(
        _FakePms(),
      ).listChildren(parentId: null);
      expect(page.items.map((MediaServerItem i) => i.id), <String>[
        'lib:1',
        'lib:2',
      ]);
      expect(page.hasMore, isFalse);
    });

    test('季：按季号排序，季号 = index，归属剧', () async {
      final List<MediaServerItem> seasons = await _client(
        _FakePms(),
      ).listSeasons('show-1');
      expect(seasons.map((MediaServerItem s) => s.seasonNumber), <int>[1, 2]);
      expect(seasons.first.seriesId, 'show-1');
      expect(seasons.first.episodeCount, 12);
    });

    test('集：指定季走 children，整部剧走 allLeaves，页内按季集号排', () async {
      final _FakePms pms = _FakePms();
      final PlexVideoClient c = _client(pms);
      final MediaServerPage bySeason = await c.listEpisodes(
        seriesId: 'show-1',
        seasonId: 'season-1',
      );
      expect(bySeason.items.map((MediaServerItem e) => e.id), <String>[
        'ep-1',
        'ep-2',
      ]);
      expect(bySeason.items.first.played, isTrue);
      expect(bySeason.items.first.seriesName, 'Show A');
      expect(bySeason.items.first.episodeCode, 'S01E01');
      final MediaServerPage all = await c.listEpisodes(seriesId: 'show-1');
      expect(_hits(pms, '/library/metadata/show-1/allLeaves'), hasLength(1));
      expect(all.items.map((MediaServerItem e) => e.id), <String>[
        'ep-1',
        'ep-2',
        'ep-3',
      ]);
    });

    test('继续观看：新 hub 只留有断点的叶子', () async {
      final List<MediaServerItem> row = await _client(_FakePms()).listResume();
      expect(row.map((MediaServerItem i) => i.id), <String>['ep-5']);
    });

    test('继续观看：新 hub 不存在时回退 /library/onDeck', () async {
      final _FakePms pms = _FakePms()
        ..failing.add('/hubs/continueWatching/items');
      final List<MediaServerItem> row = await _client(pms).listResume();
      expect(row.map((MediaServerItem i) => i.id), <String>['ep-7']);
    });

    test('接下来看：/hubs/home/onDeck 失败回退旧端点，只留未开始的集', () async {
      final _FakePms pms = _FakePms();
      final List<MediaServerItem> row = await _client(pms).listNextUp();
      expect(_hits(pms, '/hubs/home/onDeck'), hasLength(1));
      expect(row.map((MediaServerItem i) => i.id), <String>['ep-8']);
    });

    test('装饰行全部失败 = 空，不抛', () async {
      final _FakePms pms = _FakePms()
        ..failing.addAll(<String>{
          '/hubs/continueWatching/items',
          '/library/onDeck',
        });
      expect(await _client(pms).listResume(), isEmpty);
    });

    test('最近添加：按库走 /library/sections/{key}/recentlyAdded', () async {
      final _FakePms pms = _FakePms();
      final List<MediaServerItem> row = await _client(
        pms,
      ).listLatest(libraryId: 'lib:2', limit: 5);
      expect(pms.seen.single.url.path, '/library/sections/2/recentlyAdded');
      expect(pms.seen.single.url.queryParameters['X-Plex-Container-Size'], '5');
      expect(row.single.id, 'ep-3');
    });

    test('主干导航失败抛 PlexApiException', () async {
      final _FakePms pms = _FakePms()..failing.add('/library/sections');
      await expectLater(
        _client(pms).listLibraries(),
        throwsA(isA<PlexApiException>()),
      );
    });

    test('搜索：只要电影 / 剧，客户端把关，精确同名置顶，不分页', () async {
      final _FakePms pms = _FakePms();
      final PlexVideoClient c = _client(pms);
      final MediaServerPage page = await c.search('  Frieren ');
      expect(pms.seen.single.url.queryParameters['query'], 'Frieren');
      expect(page.items.map((MediaServerItem i) => i.id), <String>[
        'm-1',
        's-1',
      ]);
      expect(page.hasMore, isFalse);
      final MediaServerPage next = await c.search(
        'Frieren',
        startIndex: page.nextStartIndex,
      );
      expect(next.items, isEmpty);
      expect(next.hasMore, isFalse);
      expect(await c.search('   '), isA<MediaServerPage>());
      expect(pms.seen, hasLength(1), reason: '第二页与空白查询都不发请求');
    });

    test('详情：带简介、断点、上次观看时刻（秒→毫秒）', () async {
      final MediaServerItem item = await _client(_FakePms()).itemDetail('ep-9');
      expect(item.overview, 'Plot');
      expect(item.positionMs, 60000);
      expect(item.lastPlayedAtMs, 1700000000 * 1000);
      expect(item.hasSubtitle, isTrue);
      expect(item.parentBackdropItemId, 'show-1');
    });
  });

  group('[C] 封面', () {
    test('主图走 /photo/:/transcode，带尺寸框与 token', () {
      final PlexVideoClient c = _client(_FakePms());
      const MediaServerItem poster = MediaServerItem(
        id: 'show-1',
        name: 'Show A',
        type: MediaServerItemType.series,
        hasCover: true,
        hasBackdrop: true,
      );
      final Uri cover = Uri.parse(c.coverUrl(poster, maxWidth: 400)!);
      expect(cover.path, '/photo/:/transcode');
      expect(cover.queryParameters['url'], '/library/metadata/show-1/thumb');
      expect(cover.queryParameters['width'], '400');
      expect(cover.queryParameters['height'], '600');
      expect(cover.queryParameters['X-Plex-Token'], kToken);
      final Uri backdrop = Uri.parse(
        c.coverUrl(poster, kind: MediaServerImageKind.backdrop)!,
      );
      expect(backdrop.queryParameters['url'], '/library/metadata/show-1/art');
      expect(
        c.coverUrl(poster, kind: MediaServerImageKind.logo),
        isNull,
        reason: '没有 clearLogo 不给 URL',
      );
      expect(
        c.libraryCoverUrl(
          const MediaServerLibrary(
            id: 'lib:1',
            name: 'Movies',
            kind: MediaServerLibraryKind.movies,
          ),
        ),
        isNull,
      );
    });
  });

  group('[D] 取流与字幕', () {
    test('direct play 直链 + token；外挂字幕给 URL，容器内文本轨只给序号', () async {
      final PlexVideoClient c = _client(_FakePms());
      final RemoteVideoStreamUrls urls = await c.remoteVideoStreamUrls('ep-9');
      final Uri stream = Uri.parse(urls.streamUrl);
      expect(stream.path, '/library/parts/77/1690000000/file.mkv');
      expect(stream.queryParameters['X-Plex-Token'], kToken);
      expect(urls.streamIsOriginalContainer, isTrue);
      expect(Uri.parse(urls.subtitleUrl!).path, '/library/streams/9');
      expect(urls.subtitleFileName, endsWith('.chi.srt'));
      expect(urls.embeddedSubtitleTracks, hasLength(2), reason: 'pgs 不算文本轨');
      final RemoteVideoEmbeddedSubtitleTrack embedded = urls
          .embeddedSubtitleTracks
          .firstWhere(
            (RemoteVideoEmbeddedSubtitleTrack t) => t.streamIndex == 4,
          );
      expect(embedded.url, isNull);
      expect(embedded.isExternalFile, isFalse);
      expect(embedded.containerTrackOrdinal, 1, reason: 'pgs 占第 0 号');
      expect(c.debugDurationOf('ep-9'), 1440000);
    });

    test('容器内轨下载抛 FileSystemException（播放页回落 libmpv）', () async {
      final PlexVideoClient c = _client(_FakePms());
      final Directory dir = Directory.systemTemp.createTempSync('plex_sub_');
      addTearDown(() => dir.deleteSync(recursive: true));
      await expectLater(
        c.getRemoteVideoSubtitle(
          'ep-9',
          File('${dir.path}/a.ass'),
          embeddedStreamIndex: 4,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('外挂字幕按 /library/streams/{id} 下载', () async {
      final _FakePms pms = _FakePms();
      final Directory dir = Directory.systemTemp.createTempSync('plex_sub_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File dest = File('${dir.path}/a.srt');
      // 假服务器对 /library/streams/9 回 404 → 抛；这里只断言请求打到了正确路径。
      await expectLater(
        _client(pms).getRemoteVideoSubtitle('ep-9', dest),
        throwsA(isA<PlexApiException>()),
      );
      expect(_hits(pms, '/library/streams/9'), hasLength(1));
    });

    test('toRemoteVideoInfo：集的标题 / 合集归属 / 封面；非叶子抛', () {
      final PlexVideoClient c = _client(_FakePms());
      final MediaServerItem ep = PlexVideoClient.mediaServerItemFrom(
        PlexApi.parseMetadata(_episode('ep-1', index: 3))!,
        MediaServerItemType.episode,
      );
      final RemoteVideoInfo info = c.toRemoteVideoInfo(ep);
      expect(info.title, 'Show A S01E03 Ep 3');
      expect(info.collection?.collectionName, 'Show A');
      expect(info.coverUrl, contains('/photo/:/transcode'));
      expect(
        () => c.toRemoteVideoInfo(
          const MediaServerItem(
            id: 'show-1',
            name: 'S',
            type: MediaServerItemType.series,
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('[E] 进度', () {
    test('timeline 心跳 10s 节流；起播重开窗口；暂停即时', () async {
      final _FakePms pms = _FakePms();
      final PlexVideoClient c = _client(pms);
      await c.remoteVideoStreamUrls('ep-9');
      await c.startRemoteVideoPlayback('ep-9', 0);
      await c.putRemoteVideoPosition('ep-9', 1000, 0);
      await c.putRemoteVideoPosition('ep-9', 2000, 0);
      await c.setRemoteVideoPlaybackPaused('ep-9', 2500, paused: true);
      final List<http.Request> timeline = _hits(pms, '/:/timeline');
      expect(
        timeline.map((http.Request r) => r.url.queryParameters['state']),
        <String>['playing', 'playing', 'paused'],
        reason: '第二次心跳在 10s 窗口内被吞',
      );
      final Map<String, String> q = timeline[1].url.queryParameters;
      expect(q['ratingKey'], 'ep-9');
      expect(q['key'], '/library/metadata/ep-9');
      expect(q['time'], '1000');
      expect(q['duration'], '1440000');
      expect(q['identifier'], PlexApi.kLibraryIdentifier);
    });

    test('停止：timeline stopped；过 90% 显式 scrobble，不足不 scrobble', () async {
      final _FakePms pms = _FakePms();
      final PlexVideoClient c = _client(pms);
      await c.remoteVideoStreamUrls('ep-9');
      await c.stopRemoteVideoPlayback('ep-9', 600000);
      expect(_hits(pms, '/:/scrobble'), isEmpty);
      await c.stopRemoteVideoPlayback('ep-9', 1400000);
      final List<http.Request> scrobbles = _hits(pms, '/:/scrobble');
      expect(scrobbles.single.url.queryParameters['key'], 'ep-9');
      expect(
        _hits(
          pms,
          '/:/timeline',
        ).map((http.Request r) => r.url.queryParameters['state']),
        <String>['stopped', 'stopped'],
      );
    });

    test('续播读 viewOffset / lastViewedAt', () async {
      final ({int positionMs, int updatedAtMs}) pos = await _client(
        _FakePms(),
      ).remoteVideoPosition('ep-9');
      expect(pos.positionMs, 60000);
      expect(pos.updatedAtMs, 1700000000000);
    });

    test('unscrobble 端点形状', () async {
      final _FakePms pms = _FakePms();
      await _client(pms).api.unscrobble('ep-1');
      final Uri url = pms.seen.single.url;
      expect(url.path, '/:/unscrobble');
      expect(url.queryParameters['key'], 'ep-1');
      expect(url.queryParameters['identifier'], PlexApi.kLibraryIdentifier);
    });
  });

  group('[F] 身份与脱敏', () {
    test('sourceId / 能力判据', () {
      final PlexVideoClient c = _client(_FakePms());
      expect(c.serverId, 'plex:mid-1|42');
      expect(c.displayName, 'Home PMS');
      expect(c, isA<MediaServerBrowser>());
      expect(c, isA<RemoteVideoPlaybackSession>());
      expect(c, isNot(isA<RemoteVideoQualityLimit>()), reason: 'v1 不做转码画质档');
      expect(identical(c.playbackClient, c), isTrue);
    });

    test('网络层异常文本里的 X-Plex-Token 被脱敏', () async {
      final PlexVideoClient c = PlexVideoClient(
        api: PlexApi(
          serverUrl: kServer,
          token: kToken,
          clientInfo: const PlexClientInfo(clientIdentifier: 'x'),
          client: MockClient(
            (http.Request req) async =>
                throw http.ClientException('Connection refused', req.url),
          ),
        ),
        machineIdentifier: 'mid-1',
      );
      final String url = c.coverUrl(
        const MediaServerItem(
          id: '1',
          name: 'n',
          type: MediaServerItemType.movie,
          hasCover: true,
        ),
      )!;
      expect(url, contains(kToken));
      Object? error;
      try {
        await c.fetchRemoteCover(url);
      } catch (e) {
        error = e;
      }
      expect('$error', isNot(contains(kToken)));
      expect('$error', contains('X-Plex-Token=<redacted>'));
    });
  });
}
