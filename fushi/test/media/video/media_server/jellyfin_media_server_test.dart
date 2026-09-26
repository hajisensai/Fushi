// JellyfinVideoClient 作为 MediaServerBrowser 的离线单测（MockClient）。
//
// 每个端点断言三件事：请求路径与关键 query（**不带 MediaSources**，BUG-1891；
// `IncludeItemTypes` / `SortBy` **单值**，BUG-2254；封面带 `maxWidth`）、解析
// 后的字段、分页 `hasMore` / `nextStartIndex`；再各补一条非 2xx 的行为
// （主干导航抛、装饰行空、剧集树回退到通用 /Items）。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/jellyfin_video_client.dart';

const String kServer = 'http://nas:8096';
const String kLastPlayed = '2026-08-19T10:20:30.0000000Z';

http.Response _json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

http.Response _page(List<Map<String, Object?>> items, {int? total}) => _json(
  <String, Object?>{'Items': items, 'TotalRecordCount': total ?? items.length},
);

Map<String, Object?> _item(
  String id,
  String type, {
  String? name,
  bool isFolder = false,
  Map<String, Object?> extra = const <String, Object?>{},
}) => <String, Object?>{
  'Id': id,
  'Name': name ?? id,
  'Type': type,
  'IsFolder': isFolder,
  ...extra,
};

Map<String, Object?> _episode(
  String id, {
  String series = 'Show A',
  int season = 1,
  int episode = 2,
  int? positionTicks,
  bool hasSubtitles = false,
}) => _item(
  id,
  'Episode',
  name: 'The Pilot',
  extra: <String, Object?>{
    'SeriesId': 'series-1',
    'SeriesName': series,
    'SeasonId': 'season-1',
    'ParentIndexNumber': season,
    'IndexNumber': episode,
    'RunTimeTicks': 24 * 60 * 1000 * kTicksPerMs,
    'ImageTags': <String, Object?>{'Primary': 'tag'},
    'HasSubtitles': hasSubtitles,
    'UserData': <String, Object?>{
      'PlaybackPositionTicks': positionTicks ?? 0,
      'LastPlayedDate': kLastPlayed,
      'Played': false,
    },
  },
);

JellyfinVideoClient _client(
  http.Client mock, {
  String? serverName,
  String serverUrl = kServer,
}) => JellyfinVideoClient(
  api: JellyfinApi(serverUrl: serverUrl, accessToken: 'tok', client: mock),
  userId: 'u1',
  serverName: serverName,
);

/// 记录全部请求，按路径分派响应。
class _Router {
  _Router(this.handler);

  final http.Response Function(http.Request req) handler;
  final List<http.Request> seen = <http.Request>[];

  MockClient get client => MockClient((http.Request req) async {
    seen.add(req);
    return handler(req);
  });

  http.Request get single => seen.single;
  Map<String, String> get singleQuery => single.url.queryParameters;
}

void main() {
  group('身份', () {
    test('serverId = remoteLibrarySourceId；displayName 取服务器名，缺省回落主机名', () {
      final JellyfinVideoClient named = _client(
        MockClient((_) async => _json(<String, Object?>{})),
        serverName: 'NAS 影视',
      );
      expect(named, isA<MediaServerBrowser>());
      expect(named.serverId, named.remoteLibrarySourceId);
      expect(named.serverId, 'jellyfin:$kServer|u1');
      expect(named.displayName, 'NAS 影视');
      expect(named.serverUrl, kServer);
      expect(
        identical(named.playbackClient, named),
        isTrue,
        reason: '播放仍走同一个 client，不另造播放路径',
      );

      final JellyfinVideoClient unnamed = _client(
        MockClient((_) async => _json(<String, Object?>{})),
      );
      expect(unnamed.displayName, 'nas');
      final JellyfinVideoClient blank = _client(
        MockClient((_) async => _json(<String, Object?>{})),
        serverName: '  ',
      );
      expect(blank.displayName, 'nas', reason: '空白名等于没名');
    });

    test('JellyfinServerConfig.buildClient 把 serverName 带进 client', () {
      final JellyfinVideoClient c = const JellyfinServerConfig(
        serverUrl: kServer,
        username: 'u',
        userId: 'u1',
        accessToken: 'tok',
        serverName: 'Living Room',
      ).buildClient(httpClient: MockClient((_) async => _json(<String>[])));
      addTearDown(c.close);
      expect(c.serverName, 'Living Room');
      expect(c.displayName, 'Living Room');
    });
  });

  group('listLibraries', () {
    test('走 /Users/{uid}/Views，滤掉非视频库，collectionType → kind', () async {
      final _Router r = _Router(
        (http.Request req) => _json(<String, Object?>{
          'Items': <Object?>[
            <String, Object?>{
              'Id': 'lib-movies',
              'Name': '电影',
              'CollectionType': 'movies',
              'ImageTags': <String, Object?>{'Primary': 't'},
            },
            <String, Object?>{
              'Id': 'lib-tv',
              'Name': '剧集',
              'CollectionType': 'tvshows',
            },
            <String, Object?>{
              'Id': 'lib-music',
              'Name': '音乐',
              'CollectionType': 'music',
            },
            <String, Object?>{
              'Id': 'lib-books',
              'Name': '图书',
              'CollectionType': 'books',
            },
            <String, Object?>{'Id': 'lib-mixed', 'Name': '混合'},
            <String, Object?>{
              'Id': 'lib-home',
              'Name': '家庭视频',
              'CollectionType': 'homevideos',
            },
          ],
        }),
      );

      final List<MediaServerLibrary> libs = await _client(
        r.client,
      ).listLibraries();

      expect(r.single.url.path, '/Users/u1/Views');
      expect(libs.map((MediaServerLibrary l) => l.id).toList(), <String>[
        'lib-movies',
        'lib-tv',
        'lib-mixed',
        'lib-home',
      ]);
      expect(libs[0].kind, MediaServerLibraryKind.movies);
      expect(libs[0].hasCover, isTrue);
      expect(libs[1].kind, MediaServerLibraryKind.tvShows);
      expect(libs[1].hasCover, isFalse);
      expect(libs[2].kind, MediaServerLibraryKind.mixed);
      expect(libs[3].kind, MediaServerLibraryKind.mixed);
    });

    test('非 2xx 抛 JellyfinApiException（主干导航不吞错）', () async {
      final JellyfinVideoClient c = _client(
        MockClient((_) async => http.Response('', 401)),
      );
      await expectLater(
        c.listLibraries(),
        throwsA(
          isA<JellyfinApiException>().having(
            (JellyfinApiException e) => e.statusCode,
            'status',
            401,
          ),
        ),
      );
    });
  });

  group('listChildren', () {
    test(
      '请求：ParentId / 分页 / Fields 不带 MediaSources / 不传 IncludeItemTypes',
      () async {
        final _Router r = _Router((_) => _page(<Map<String, Object?>>[]));

        await _client(
          r.client,
        ).listChildren(parentId: 'lib-tv', startIndex: 120, limit: 60);

        expect(r.single.url.path, '/Users/u1/Items');
        final Map<String, String> q = r.singleQuery;
        expect(q['ParentId'], 'lib-tv');
        expect(q['StartIndex'], '120');
        expect(q['Limit'], '60');
        expect(q['Fields'], 'ChildCount,RecursiveItemCount,ProductionYear');
        expect(
          q['Fields'],
          isNot(contains('MediaSources')),
          reason: 'BUG-1891：MediaSources 让服务器为每条条目展开媒体源',
        );
        expect(
          q.containsKey('IncludeItemTypes'),
          isFalse,
          reason: '浏览这一层要的是全部子级；类型在客户端滤（BUG-2254 不拼逗号多值）',
        );
        expect(q.containsKey('Recursive'), isFalse);
        expect(q['SortBy'], 'SortName');
        expect(q['SortOrder'], 'Ascending');
      },
    );

    test('sort 映射到单值 SortBy + SortOrder', () async {
      const Map<MediaServerSort, (String, String)> expected =
          <MediaServerSort, (String, String)>{
            MediaServerSort.name: ('SortName', 'Ascending'),
            MediaServerSort.dateAdded: ('DateCreated', 'Descending'),
            MediaServerSort.premiereDate: ('PremiereDate', 'Descending'),
            MediaServerSort.communityRating: ('CommunityRating', 'Descending'),
          };
      for (final MapEntry<MediaServerSort, (String, String)> e
          in expected.entries) {
        final _Router r = _Router((_) => _page(<Map<String, Object?>>[]));
        await _client(r.client).listChildren(parentId: 'x', sort: e.key);
        expect(r.singleQuery['SortBy'], e.value.$1, reason: '${e.key}');
        expect(r.singleQuery['SortOrder'], e.value.$2, reason: '${e.key}');
        expect(
          r.singleQuery['SortBy'],
          isNot(contains(',')),
          reason: 'SortBy 也单值：多值在飞牛上没验过',
        );
      }
    });

    test('类型映射 + 客户端滤掉非视频域；nextStartIndex 按服务器返回行数推', () async {
      final _Router r = _Router(
        (_) => _page(<Map<String, Object?>>[
          _item('m1', 'Movie'),
          _item(
            's1',
            'Series',
            isFolder: true,
            extra: <String, Object?>{
              // Emby 4.9 真机：ChildCount 是季数、RecursiveItemCount 才是集数。
              'ChildCount': 3,
              'RecursiveItemCount': 36,
              'UserData': <String, Object?>{'UnplayedItemCount': 2},
            },
          ),
          _item('a1', 'Audio'),
          _item('alb', 'MusicAlbum', isFolder: true),
          _item('b1', 'Book'),
          _item('box', 'BoxSet', isFolder: true),
          _item('hv', 'Video'),
          _item('odd', 'SomeVendorFolder', isFolder: true),
          _item('odd2', 'SomeVendorLeaf'),
          _item(
            'se',
            'Season',
            isFolder: true,
            extra: <String, Object?>{'IndexNumber': 2, 'SeriesId': 's1'},
          ),
        ], total: 100),
      );

      final MediaServerPage page = await _client(
        r.client,
      ).listChildren(parentId: 'lib', startIndex: 20, limit: 10);

      expect(page.items.map((MediaServerItem i) => i.id).toList(), <String>[
        'm1',
        's1',
        'box',
        'hv',
        'odd',
        'se',
      ]);
      expect(page.items[0].type, MediaServerItemType.movie);
      expect(page.items[1].type, MediaServerItemType.series);
      expect(page.items[1].childCount, 3);
      expect(page.items[1].episodeCount, 36);
      expect(page.items[1].unplayedChildCount, 2);
      expect(page.items[2].type, MediaServerItemType.folder);
      expect(
        page.items[3].type,
        MediaServerItemType.movie,
        reason: '家庭视频库的 Video 是可播叶子，同走 /Videos/{id}/stream',
      );
      expect(
        page.items[4].type,
        MediaServerItemType.folder,
        reason: '未知类型只要 IsFolder 就可下钻',
      );
      expect(page.items[5].type, MediaServerItemType.season);
      expect(page.items[5].seasonNumber, 2, reason: '季自己的序号在 IndexNumber 上');
      expect(page.items[5].episodeNumber, isNull);
      expect(page.items[5].seriesId, 's1');

      expect(page.totalCount, 100);
      expect(page.startIndex, 20);
      expect(
        page.nextStartIndex,
        30,
        reason:
            '服务器返了 10 行（含被滤掉的 4 行），下一页从 30 起，'
            '按 items.length 推会把 26..29 重复取回来',
      );
      expect(page.hasMore, isTrue);
    });

    test('末页 hasMore=false', () async {
      final _Router r = _Router(
        (_) => _page(<Map<String, Object?>>[
          _item('m1', 'Movie'),
          _item('a1', 'Audio'),
        ], total: 12),
      );
      final MediaServerPage page = await _client(
        r.client,
      ).listChildren(parentId: 'lib', startIndex: 10, limit: 10);
      expect(page.items, hasLength(1));
      expect(page.nextStartIndex, 12);
      expect(page.hasMore, isFalse);
    });

    test('非 2xx 抛（主干导航）', () async {
      final JellyfinVideoClient c = _client(
        MockClient((_) async => http.Response('', 500)),
      );
      await expectLater(
        c.listChildren(parentId: 'lib'),
        throwsA(isA<JellyfinApiException>()),
      );
    });
  });

  group('listSeasons', () {
    test('走 /Shows/{seriesId}/Seasons?UserId=，按季号排序，只留 Season', () async {
      final _Router r = _Router(
        (_) => _page(<Map<String, Object?>>[
          _item(
            'sp',
            'Season',
            name: 'Specials',
            isFolder: true,
            extra: <String, Object?>{'IndexNumber': 0},
          ),
          _item(
            's2',
            'Season',
            isFolder: true,
            extra: <String, Object?>{'IndexNumber': 2, 'ChildCount': 12},
          ),
          _item(
            's1',
            'Season',
            isFolder: true,
            extra: <String, Object?>{'IndexNumber': 1},
          ),
          _item('stray', 'Episode'),
        ]),
      );

      final List<MediaServerItem> seasons = await _client(
        r.client,
      ).listSeasons('series-1');

      expect(r.single.url.path, '/Shows/series-1/Seasons');
      expect(r.singleQuery['UserId'], 'u1');
      expect(r.singleQuery['Fields'], 'ChildCount');
      expect(seasons.map((MediaServerItem s) => s.id).toList(), <String>[
        'sp',
        's1',
        's2',
      ]);
      expect(seasons[2].childCount, 12);
      expect(seasons.every((MediaServerItem s) => s.isContainer), isTrue);
    });

    test(
      '/Shows 端点 404 → 回退 /Items?ParentId=&IncludeItemTypes=Season（非递归）',
      () async {
        final _Router r = _Router((http.Request req) {
          if (req.url.path.startsWith('/Shows/')) return http.Response('', 404);
          return _page(<Map<String, Object?>>[
            _item(
              's1',
              'Season',
              isFolder: true,
              extra: <String, Object?>{'IndexNumber': 1},
            ),
          ]);
        });

        final List<MediaServerItem> seasons = await _client(
          r.client,
        ).listSeasons('series-1');

        expect(r.seen.map((http.Request q) => q.url.path).toList(), <String>[
          '/Shows/series-1/Seasons',
          '/Users/u1/Items',
        ]);
        final Map<String, String> q = r.seen.last.url.queryParameters;
        expect(q['ParentId'], 'series-1');
        expect(q['IncludeItemTypes'], 'Season');
        expect(q.containsKey('Recursive'), isFalse);
        expect(seasons.single.id, 's1');
      },
    );

    test('/Shows 端点 200 却回 SPA HTML（飞牛，BUG-2254 备注④）→ 同样回退', () async {
      final _Router r = _Router((http.Request req) {
        if (req.url.path.startsWith('/Shows/')) {
          return http.Response('<!doctype html><html></html>', 200);
        }
        return _page(<Map<String, Object?>>[
          _item('s1', 'Season', isFolder: true),
        ]);
      });
      final List<MediaServerItem> seasons = await _client(
        r.client,
      ).listSeasons('series-1');
      expect(r.seen, hasLength(2));
      expect(seasons.single.id, 's1');
    });

    test('网络层异常不回退、原样抛（真断网回退也一样断）', () async {
      int calls = 0;
      final JellyfinVideoClient c = _client(
        MockClient((http.Request req) async {
          calls++;
          throw http.ClientException('Connection refused', req.url);
        }),
      );
      await expectLater(c.listSeasons('series-1'), throwsA(isA<Exception>()));
      expect(calls, 1);
    });
  });

  group('listEpisodes', () {
    test(
      '走 /Shows/{seriesId}/Episodes：UserId / SeasonId / 分页 / Fields',
      () async {
        final _Router r = _Router(
          (_) => _page(<Map<String, Object?>>[
            _episode('ep1', season: 1, episode: 1),
            _episode('ep2', season: 1, episode: 2, hasSubtitles: true),
          ], total: 26),
        );

        final MediaServerPage page = await _client(r.client).listEpisodes(
          seriesId: 'series-1',
          seasonId: 'season-1',
          startIndex: 24,
          limit: 100,
        );

        expect(r.single.url.path, '/Shows/series-1/Episodes');
        final Map<String, String> q = r.singleQuery;
        expect(q['UserId'], 'u1');
        expect(q['SeasonId'], 'season-1');
        expect(q['StartIndex'], '24');
        expect(q['Limit'], '100');
        expect(q['Fields'], 'ProductionYear');
        expect(q['Fields'], isNot(contains('MediaSources')));

        expect(page.items, hasLength(2));
        expect(page.items[0].type, MediaServerItemType.episode);
        expect(page.items[0].episodeCode, 'S01E01');
        expect(page.items[0].seriesId, 'series-1');
        expect(page.items[0].seasonId, 'season-1');
        expect(page.items[0].seriesName, 'Show A');
        expect(page.items[0].durationMs, 24 * 60 * 1000);
        expect(page.items[0].isPlayable, isTrue);
        expect(
          page.items[1].hasSubtitle,
          isTrue,
          reason: '清单没 MediaSources 时回落服务器粗粒度 HasSubtitles',
        );
        expect(page.totalCount, 26);
        expect(page.nextStartIndex, 26);
        expect(page.hasMore, isFalse);
      },
    );

    test('整部剧（seasonId null）不带 SeasonId；分页 hasMore', () async {
      final _Router r = _Router(
        (_) => _page(<Map<String, Object?>>[_episode('ep1')], total: 40),
      );
      final MediaServerPage page = await _client(
        r.client,
      ).listEpisodes(seriesId: 'series-1', limit: 1);
      expect(r.singleQuery.containsKey('SeasonId'), isFalse);
      expect(page.hasMore, isTrue);
      expect(page.nextStartIndex, 1);
    });

    test(
      '/Shows 端点不可用 → 回退递归 /Items?ParentId=<季或剧>&IncludeItemTypes=Episode，页内按季集号排',
      () async {
        final _Router r = _Router((http.Request req) {
          if (req.url.path.startsWith('/Shows/')) return http.Response('', 404);
          return _page(<Map<String, Object?>>[
            _episode('ep3', season: 1, episode: 3),
            _episode('ep1', season: 1, episode: 1),
            _item('noise', 'Audio'),
            _episode('ep2', season: 1, episode: 2),
          ], total: 3);
        });

        final MediaServerPage page = await _client(r.client).listEpisodes(
          seriesId: 'series-1',
          seasonId: 'season-1',
          startIndex: 0,
          limit: 50,
        );

        expect(r.seen.map((http.Request q) => q.url.path).toList(), <String>[
          '/Shows/series-1/Episodes',
          '/Users/u1/Items',
        ]);
        final Map<String, String> q = r.seen.last.url.queryParameters;
        expect(q['ParentId'], 'season-1');
        expect(q['Recursive'], 'true');
        expect(q['IncludeItemTypes'], 'Episode');
        expect(q['StartIndex'], '0');
        expect(q['Limit'], '50');
        expect(q['Fields'], 'ProductionYear');
        expect(page.items.map((MediaServerItem e) => e.id).toList(), <String>[
          'ep1',
          'ep2',
          'ep3',
        ]);
        expect(page.nextStartIndex, 4, reason: '服务器返了 4 行（含被滤掉的 Audio）');

        // 没给季 → ParentId 落在剧上。
        r.seen.clear();
        await _client(r.client).listEpisodes(seriesId: 'series-1');
        expect(r.seen.last.url.queryParameters['ParentId'], 'series-1');
      },
    );
  });

  group('listResume', () {
    test(
      '走 /Users/{uid}/Items/Resume?Limit=&MediaTypes=Video；positionMs = ticks/10000',
      () async {
        final _Router r = _Router(
          (_) => _page(<Map<String, Object?>>[
            _episode('ep1', positionTicks: 754321 * kTicksPerMs + 9999),
            _item(
              'm1',
              'Movie',
              extra: <String, Object?>{
                'UserData': <String, Object?>{
                  'PlaybackPositionTicks': 60000 * kTicksPerMs,
                  'PlayedPercentage': 42.5,
                },
              },
            ),
          ]),
        );

        final List<MediaServerItem> row = await _client(
          r.client,
        ).listResume(limit: 7);

        expect(r.single.url.path, '/Users/u1/Items/Resume');
        expect(r.singleQuery['Limit'], '7');
        expect(r.singleQuery['MediaTypes'], 'Video');
        expect(row, hasLength(2));
        expect(row[0].positionMs, 754321, reason: '整除截断，不四舍五入');
        expect(
          row[0].lastPlayedAtMs,
          DateTime.parse(kLastPlayed).millisecondsSinceEpoch,
        );
        expect(row[1].positionMs, 60000);
        expect(row[1].playedPercentage, 42.5);
      },
    );

    test('非 2xx → 空行 + 不抛（装饰行不该拖死整页）', () async {
      final JellyfinVideoClient c = _client(
        MockClient((_) async => http.Response('', 500)),
      );
      expect(await c.listResume(), isEmpty);
    });
  });

  group('listNextUp', () {
    test('走 /Shows/NextUp?UserId=&Limit=；seriesId / seasonId 透传', () async {
      final _Router r = _Router(
        (_) => _page(<Map<String, Object?>>[
          _episode('ep5', season: 2, episode: 5),
        ]),
      );

      final List<MediaServerItem> row = await _client(
        r.client,
      ).listNextUp(limit: 5);

      expect(r.single.url.path, '/Shows/NextUp');
      expect(r.singleQuery['UserId'], 'u1');
      expect(r.singleQuery['Limit'], '5');
      expect(row.single.seriesId, 'series-1');
      expect(row.single.seasonId, 'season-1');
      expect(row.single.episodeCode, 'S02E05');
    });

    test('非 2xx → 空', () async {
      final JellyfinVideoClient c = _client(
        MockClient((_) async => http.Response('', 404)),
      );
      expect(await c.listNextUp(), isEmpty);
    });
  });

  group('listLatest', () {
    test(
      '走 /Users/{uid}/Items/Latest?ParentId=&Limit=，解析裸数组，Series 容器照收，Audio 滤掉',
      () async {
        final _Router r = _Router(
          (_) => _json(<Object?>[
            _item(
              's1',
              'Series',
              isFolder: true,
              extra: <String, Object?>{
                'ChildCount': 2,
                'UserData': <String, Object?>{'UnplayedItemCount': 2},
              },
            ),
            _item('m1', 'Movie'),
            _item('a1', 'Audio'),
          ]),
        );

        final List<MediaServerItem> row = await _client(
          r.client,
        ).listLatest(libraryId: 'lib-tv', limit: 12);

        expect(r.single.url.path, '/Users/u1/Items/Latest');
        expect(r.singleQuery['ParentId'], 'lib-tv');
        expect(r.singleQuery['Limit'], '12');
        expect(row.map((MediaServerItem i) => i.id).toList(), <String>[
          's1',
          'm1',
        ]);
        expect(row[0].type, MediaServerItemType.series);
        expect(row[0].unplayedChildCount, 2);
      },
    );

    test('libraryId null 不带 ParentId；对象形状 {Items:[…]} 也能解', () async {
      final _Router r = _Router(
        (_) => _page(<Map<String, Object?>>[_item('m1', 'Movie')]),
      );
      final List<MediaServerItem> row = await _client(r.client).listLatest();
      expect(r.singleQuery.containsKey('ParentId'), isFalse);
      expect(row.single.id, 'm1');
    });

    test('非 2xx → 空', () async {
      final JellyfinVideoClient c = _client(
        MockClient((_) async => http.Response('', 500)),
      );
      expect(await c.listLatest(), isEmpty);
    });
  });

  group('search', () {
    /// 电影 2 部、剧 3 部的服务器；按单值类型分派，按 StartIndex/Limit 切片。
    /// 条目名都真含查询词（服务器命中 = 客户端把关也过，BUG-2608）。
    http.Response serve(http.Request req) {
      final Map<String, String> q = req.url.queryParameters;
      expect(q['SearchTerm'], 'love');
      expect(q['Recursive'], 'true');
      expect(q['Fields'], isNot(contains('MediaSources')));
      expect(q['Fields'], contains('OriginalTitle'), reason: 'Emby 要显式要原名');
      final String type = q['IncludeItemTypes']!;
      expect(type, isNot(contains(',')), reason: '单值（BUG-2254）');
      final int total = type == 'Movie' ? 2 : 3;
      final int start = int.parse(q['StartIndex']!);
      final int limit = int.parse(q['Limit']!);
      return _page(<Map<String, Object?>>[
        for (int i = start; i < total && i < start + limit; i++)
          _item(
            '$type$i',
            type,
            name: 'Love $type $i',
            isFolder: type == 'Series',
          ),
      ], total: total);
    }

    test('Movie / Series 各一轮单值，按拼接序分页：第 1 页', () async {
      final _Router r = _Router(serve);
      final MediaServerPage page = await _client(
        r.client,
      ).search('  love ', limit: 4);

      expect(
        r.seen
            .map((http.Request q) => q.url.queryParameters['IncludeItemTypes'])
            .toList(),
        <String>['Movie', 'Series'],
      );
      expect(r.seen[0].url.queryParameters['StartIndex'], '0');
      expect(
        r.seen[0].url.queryParameters['Limit'],
        '${JellyfinVideoClient.kSearchServerPageSize}',
        reason: '服务器页比客户端页大：把关会漏掉一部分，一发多要些少往返',
      );
      expect(r.seen[1].url.queryParameters['StartIndex'], '0');
      expect(
        page.items.map((MediaServerItem i) => i.id).toList(),
        <String>['Movie0', 'Movie1', 'Series0', 'Series1', 'Series2'],
        reason: '最后一发服务器页把关后全收，允许略多于 limit',
      );
      expect(page.totalCount, 5);
      expect(page.startIndex, 0);
      expect(page.nextStartIndex, 5);
      expect(page.hasMore, isFalse);
    });

    test('第 2 页：起点跨过整轮电影后落到剧的第 2 条', () async {
      final _Router r = _Router(serve);
      final MediaServerPage page = await _client(
        r.client,
      ).search('love', startIndex: 4, limit: 4);

      expect(
        r.seen[0].url.queryParameters['StartIndex'],
        '4',
        reason: '电影轮照问（要它的总数才知道该跳过多少）',
      );
      expect(r.seen[1].url.queryParameters['StartIndex'], '2');
      expect(page.items.map((MediaServerItem i) => i.id).toList(), <String>[
        'Series2',
      ]);
      expect(page.totalCount, 5);
      expect(page.hasMore, isFalse);
    });

    test('电影已凑够一页时剧那轮只问总数（Limit=1）且不混入条目', () async {
      final _Router r = _Router(serve);
      final MediaServerPage page = await _client(
        r.client,
      ).search('love', limit: 2);
      expect(r.seen, hasLength(2));
      expect(r.seen[1].url.queryParameters['Limit'], '1');
      expect(page.items.map((MediaServerItem i) => i.id).toList(), <String>[
        'Movie0',
        'Movie1',
      ]);
      expect(page.totalCount, 5);
      expect(page.hasMore, isTrue);
      expect(page.nextStartIndex, 2);
    });

    test('空白 / 纯标点 query 不发请求', () async {
      final _Router r = _Router(serve);
      expect((await _client(r.client).search('   ')).items, isEmpty);
      expect((await _client(r.client).search(' 「」… ')).hasMore, isFalse);
      expect(r.seen, isEmpty);
    });

    test('非 2xx 抛（主干导航）', () async {
      final JellyfinVideoClient c = _client(
        MockClient((_) async => http.Response('', 503)),
      );
      await expectLater(c.search('x'), throwsA(isA<JellyfinApiException>()));
    });

    /// BUG-2608：兼容层（UHD Media Server）的 SearchTerm 按字模糊 + 相关度：搜
    /// 「怪奇物语」电影轮回 121 条（怪形 / 尘兔 / 绿毛怪格林奇……只沾一个字），
    /// 精确命中的剧被压在整轮电影之后。客户端只留标题 / 原名真含查询词的条目，
    /// 精确同名置顶；分页偏移仍按服务器行走。
    group('把关（BUG-2608）', () {
      /// 电影轮 121 条：第 0 条是《最后的冒险：怪奇物语幕后》、其余全是沾边；
      /// 剧轮 3 条：怪奇背后 / 怪奇物语：1985 / 怪奇物语（精确，故意放最后）。
      http.Response fuzzyServe(http.Request req) {
        final Map<String, String> q = req.url.queryParameters;
        final String type = q['IncludeItemTypes']!;
        final int start = int.parse(q['StartIndex']!);
        final int limit = int.parse(q['Limit']!);
        final List<Map<String, Object?>> all = type == 'Movie'
            ? <Map<String, Object?>>[
                _item(
                  'making-of',
                  'Movie',
                  name: '最后的冒险：《怪奇物语》第五季幕后',
                  extra: <String, Object?>{
                    'OriginalTitle': 'The Making of Stranger Things 5',
                  },
                ),
                for (int i = 1; i < 121; i++)
                  _item('junk$i', 'Movie', name: '怪形 $i'),
              ]
            : <Map<String, Object?>>[
                _item('beyond', 'Series', name: '怪奇背后', isFolder: true),
                _item('tales', 'Series', name: '怪奇物语：1985故事集', isFolder: true),
                _item(
                  'st',
                  'Series',
                  name: '怪奇物语',
                  isFolder: true,
                  extra: <String, Object?>{'OriginalTitle': 'Stranger Things'},
                ),
              ];
        return _page(all.skip(start).take(limit).toList(), total: all.length);
      }

      test('沾边命中被滤掉、精确同名置顶、以查询开头的其次；偏移按服务器行', () async {
        final _Router r = _Router(fuzzyServe);
        final MediaServerPage page = await _client(r.client).search('怪奇物语');
        expect(page.items.map((MediaServerItem i) => i.id).toList(), <String>[
          'st',
          'tales',
          'making-of',
        ]);
        expect(page.totalCount, 124, reason: '服务器总数只是上界');
        expect(page.nextStartIndex, 124);
        expect(page.hasMore, isFalse);
        // 电影轮 121 行分两发（100 + 21），第三发不该有：总数已知、已扫穿。
        expect(
          r.seen
              .map(
                (http.Request q) =>
                    '${q.url.queryParameters['IncludeItemTypes']}'
                    '@${q.url.queryParameters['StartIndex']}',
              )
              .toList(),
          <String>['Movie@0', 'Movie@100', 'Series@0'],
        );
      });

      test('按原名搜也命中（Emby 中文库的外文原题）', () async {
        final MediaServerPage page = await _client(
          _Router(fuzzyServe).client,
        ).search('stranger things');
        expect(page.items.map((MediaServerItem i) => i.id).toList(), <String>[
          'st',
          'making-of',
        ]);
      });

      test(
        '扫满 kSearchScanLimit 行就先返回：命中可为 0 而 hasMore 仍 true，偏移落在电影轮中段',
        () async {
          // 全是沾边的电影 900 条 + 精确命中的剧 1 条。
          http.Response hugeServe(http.Request req) {
            final Map<String, String> q = req.url.queryParameters;
            final String type = q['IncludeItemTypes']!;
            final int start = int.parse(q['StartIndex']!);
            final int limit = int.parse(q['Limit']!);
            final int total = type == 'Movie' ? 900 : 1;
            return _page(<Map<String, Object?>>[
              for (int i = start; i < total && i < start + limit; i++)
                if (type == 'Movie')
                  _item('junk$i', 'Movie', name: '怪形 $i')
                else
                  _item('st', 'Series', name: '怪奇物语', isFolder: true),
            ], total: total);
          }

          final _Router r = _Router(hugeServe);
          final JellyfinVideoClient c = _client(r.client);
          final MediaServerPage first = await c.search('怪奇物语');
          expect(first.items, isEmpty);
          expect(first.totalCount, 901);
          expect(first.nextStartIndex, JellyfinVideoClient.kSearchScanLimit);
          expect(first.hasMore, isTrue);
          expect(
            r.seen.last.url.queryParameters['IncludeItemTypes'],
            'Series',
            reason: '剧那轮仍要问一次总数',
          );
          expect(r.seen.last.url.queryParameters['Limit'], '1');

          // 页面按 nextStartIndex 接着扫：剩下 400 条电影 + 剧轮命中。
          final MediaServerPage second = await c.search(
            '怪奇物语',
            startIndex: first.nextStartIndex,
          );
          expect(
            second.items.map((MediaServerItem i) => i.id).toList(),
            <String>['st'],
          );
          expect(second.nextStartIndex, 901);
          expect(second.hasMore, isFalse);
        },
      );
    });
  });

  group('itemDetail', () {
    test('走 /Users/{uid}/Items/{id}（与播放路径同一发，不另加参数）；详情字段解析', () async {
      final _Router r = _Router(
        (_) => _json(
          _item(
            'm1',
            'Movie',
            name: 'Ghost in the Shell',
            extra: <String, Object?>{
              'Overview': '公安 9 课。',
              'Genres': <Object?>['Anime', 'Sci-Fi', '', 42],
              'CommunityRating': 8.1,
              'ProductionYear': 1995,
              'BackdropImageTags': <Object?>['bd1'],
              'ImageTags': <String, Object?>{
                'Primary': 'p',
                'Thumb': 't',
                'Logo': 'l',
              },
              'UserData': <String, Object?>{'Played': true},
            },
          ),
        ),
      );

      final MediaServerItem d = await _client(r.client).itemDetail('m1');

      expect(r.single.url.path, '/Users/u1/Items/m1');
      expect(r.singleQuery, isEmpty);
      expect(d.name, 'Ghost in the Shell');
      expect(d.overview, '公安 9 课。');
      expect(d.genres, <String>['Anime', 'Sci-Fi']);
      expect(d.communityRating, 8.1);
      expect(d.productionYear, 1995);
      expect(d.played, isTrue);
      expect(d.hasCover, isTrue);
      expect(d.hasBackdrop, isTrue);
      expect(d.hasThumb, isTrue);
      expect(d.hasLogo, isTrue);
    });

    test('非视频域条目抛 ArgumentError；非 2xx 抛 JellyfinApiException', () async {
      final JellyfinVideoClient audio = _client(
        MockClient((_) async => _json(_item('a1', 'Audio'))),
      );
      await expectLater(audio.itemDetail('a1'), throwsArgumentError);

      final JellyfinVideoClient gone = _client(
        MockClient((_) async => http.Response('', 404)),
      );
      await expectLater(
        gone.itemDetail('x'),
        throwsA(isA<JellyfinApiException>()),
      );
    });
  });

  group('coverUrl', () {
    const MediaServerItem full = MediaServerItem(
      id: 'm1',
      name: 'M',
      type: MediaServerItemType.movie,
      hasCover: true,
      hasBackdrop: true,
      hasThumb: true,
      hasLogo: true,
    );
    const MediaServerItem bare = MediaServerItem(
      id: 'm2',
      name: 'M',
      type: MediaServerItemType.movie,
    );
    final JellyfinVideoClient c = _client(
      MockClient((_) async => _json(<String, Object?>{})),
    );

    test('主图带 maxWidth / quality / api_key；各 kind 按有无返回', () {
      expect(
        c.coverUrl(full),
        '$kServer/Items/m1/Images/Primary?maxWidth=720&quality=90&api_key=tok',
      );
      expect(kMediaServerCoverMaxWidth, 720);
      expect(
        c.coverUrl(full, maxWidth: 300, kind: MediaServerImageKind.backdrop),
        '$kServer/Items/m1/Images/Backdrop?maxWidth=300&quality=90&api_key=tok',
      );
      expect(
        c.coverUrl(full, kind: MediaServerImageKind.thumb),
        contains('/Images/Thumb?'),
      );
      expect(
        c.coverUrl(full, kind: MediaServerImageKind.logo),
        contains('/Images/Logo?'),
      );

      expect(c.coverUrl(bare), isNull);
      expect(c.coverUrl(bare, kind: MediaServerImageKind.backdrop), isNull);
      expect(c.coverUrl(bare, kind: MediaServerImageKind.thumb), isNull);
      expect(c.coverUrl(bare, kind: MediaServerImageKind.logo), isNull);
    });

    test('libraryCoverUrl 按 hasCover', () {
      expect(
        c.libraryCoverUrl(
          const MediaServerLibrary(
            id: 'lib',
            name: 'L',
            kind: MediaServerLibraryKind.movies,
            hasCover: true,
          ),
        ),
        '$kServer/Items/lib/Images/Primary?maxWidth=720&quality=90&api_key=tok',
      );
      expect(
        c.libraryCoverUrl(
          const MediaServerLibrary(
            id: 'lib',
            name: 'L',
            kind: MediaServerLibraryKind.movies,
          ),
        ),
        isNull,
      );
    });

    test('JellyfinApi.imageUrl 不给 maxWidth 时保持旧 URL（原图）', () {
      expect(
        c.api.imageUrl('m1'),
        '$kServer/Items/m1/Images/Primary?api_key=tok',
      );
    });
  });

  group('toRemoteVideoInfo', () {
    test('单集：标题与 JellyfinItem.displayTitle 同口径、剧名折叠合集、封面 720、断点', () async {
      final Map<String, Object?> json = _episode(
        'ep2',
        season: 1,
        episode: 2,
        positionTicks: 60000 * kTicksPerMs,
        hasSubtitles: true,
      );
      final JellyfinItem parsed = JellyfinApi.parseItem(json);
      final _Router r = _Router((_) => _page(<Map<String, Object?>>[json]));
      final JellyfinVideoClient c = _client(r.client);
      final MediaServerPage page = await c.listEpisodes(seriesId: 'series-1');

      final RemoteVideoInfo info = c.toRemoteVideoInfo(page.items.single);

      expect(info.id, 'ep2');
      expect(info.title, 'Show A S01E02 The Pilot');
      expect(
        info.title,
        parsed.displayTitle,
        reason: '浏览路径与全量清单路径的标题必须一字不差，否则同一集在两条路上是两个名字',
      );
      expect(
        JellyfinVideoClient.displayTitleOf(page.items.single),
        parsed.displayTitle,
      );
      expect(info.collection?.collectionName, 'Show A');
      expect(info.collection?.collectionType, 'playlist');
      expect(info.collection?.sortIndex, 1 * 10000 + 2);
      expect(info.hasCover, isTrue);
      expect(info.coverUrl, contains('maxWidth=720'));
      expect(info.coverUrl, contains('/Items/ep2/Images/Primary?'));
      expect(info.durationMs, 24 * 60 * 1000);
      expect(info.positionMs, 60000);
      expect(
        info.positionUpdatedAtMs,
        DateTime.parse(kLastPlayed).millisecondsSinceEpoch,
      );
      expect(info.hasSubtitle, isTrue);
      expect(info.sizeBytes, isNull, reason: '清单没 MediaSources，详情才有');

      // 同一条 JSON 走 infoFromItem（全量清单路径）得到同一份 RemoteVideoInfo。
      final RemoteVideoInfo viaList = c.infoFromItem(parsed);
      expect(viaList.title, info.title);
      expect(viaList.coverUrl, info.coverUrl);
      expect(viaList.collection?.sortIndex, info.collection?.sortIndex);
      expect(viaList.positionUpdatedAtMs, info.positionUpdatedAtMs);
    });

    test('电影：无合集；非叶子抛 ArgumentError', () {
      final JellyfinVideoClient c = _client(
        MockClient((_) async => _json(<String, Object?>{})),
      );
      final RemoteVideoInfo movie = c.toRemoteVideoInfo(
        const MediaServerItem(
          id: 'm1',
          name: 'Movie',
          type: MediaServerItemType.movie,
        ),
      );
      expect(movie.title, 'Movie');
      expect(movie.collection, isNull);
      expect(movie.coverUrl, isNull);

      for (final MediaServerItemType t in <MediaServerItemType>[
        MediaServerItemType.series,
        MediaServerItemType.season,
        MediaServerItemType.folder,
      ]) {
        expect(
          () =>
              c.toRemoteVideoInfo(MediaServerItem(id: 'x', name: 'x', type: t)),
          throwsArgumentError,
          reason: '$t',
        );
      }
    });
  });

  group('parseItem 新字段', () {
    test(
      'SeriesId / SeasonId / Played / UnplayedItemCount / Backdrop / 详情字段；旧字段不变',
      () {
        final JellyfinItem item = JellyfinApi.parseItem(<String, Object?>{
          'Id': 's1',
          'Name': 'Show',
          'Type': 'Series',
          'IsFolder': true,
          'SeriesId': 'parent-series',
          'SeasonId': 'parent-season',
          'ChildCount': 24,
          'BackdropImageTags': <Object?>['a', 'b'],
          'Overview': 'o',
          'CommunityRating': 7,
          'Genres': <Object?>['Drama'],
          'UserData': <String, Object?>{
            'Played': true,
            'UnplayedItemCount': 3,
            'PlaybackPositionTicks': 0,
          },
        });
        expect(item.seriesId, 'parent-series');
        expect(item.seasonId, 'parent-season');
        expect(item.played, isTrue);
        expect(item.unplayedChildCount, 3);
        expect(item.hasBackdrop, isTrue);
        expect(item.hasThumbImage, isFalse);
        expect(item.overview, 'o');
        expect(item.communityRating, 7.0);
        expect(item.genres, <String>['Drama']);
        expect(item.childCount, 24);
        expect(item.isFolder, isTrue);
        expect(item.hasPrimaryImage, isFalse);
        expect(item.positionMs, 0);
        expect(item.isPlayableVideo, isFalse);

        final JellyfinItem minimal = JellyfinApi.parseItem(<String, Object?>{
          'Id': 'x',
          'Name': 'x',
          'Type': 'Movie',
        });
        expect(minimal.played, isFalse);
        expect(minimal.unplayedChildCount, isNull);
        expect(minimal.hasBackdrop, isFalse);
        expect(minimal.genres, isEmpty);
        expect(minimal.seriesId, isNull);
      },
    );

    test('集借用的剧级横图：有 tag 才给 id，并透传到 MediaServerItem', () {
      final JellyfinItem episode = JellyfinApi.parseItem(<String, Object?>{
        'Id': 'ep1',
        'Name': 'Ep',
        'Type': 'Episode',
        'ParentThumbItemId': 'series-1',
        'ParentThumbImageTag': 'thumb-tag',
        'ParentBackdropItemId': 'series-1',
        'ParentBackdropImageTags': <Object?>['bd-tag'],
      });
      expect(episode.parentThumbItemId, 'series-1');
      expect(episode.parentBackdropItemId, 'series-1');
      final MediaServerItem mapped = JellyfinVideoClient.mediaServerItemFrom(
        episode,
        MediaServerItemType.episode,
      );
      expect(mapped.parentThumbItemId, 'series-1');
      expect(mapped.parentBackdropItemId, 'series-1');

      // 只有 id 没 tag（服务器没有这张图）：拿去请求必 404，解析成 null。
      final JellyfinItem noTags = JellyfinApi.parseItem(<String, Object?>{
        'Id': 'ep2',
        'Name': 'Ep',
        'Type': 'Episode',
        'ParentThumbItemId': 'series-1',
        'ParentBackdropItemId': 'series-1',
        'ParentBackdropImageTags': <Object?>[],
      });
      expect(noTags.parentThumbItemId, isNull);
      expect(noTags.parentBackdropItemId, isNull);
    });
  });
}
