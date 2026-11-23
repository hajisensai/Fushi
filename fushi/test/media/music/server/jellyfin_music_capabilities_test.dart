import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/server/jellyfin_music_client.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const JellyfinServerConfig _config = JellyfinServerConfig(
  serverUrl: 'http://nas:8096',
  username: 'me',
  userId: 'uid',
  accessToken: 'tok',
);

http.Response _items(List<Map<String, Object?>> items) => http.Response.bytes(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'Items': items,
      'TotalRecordCount': items.length,
    }),
  ),
  200,
);

/// Jellyfin 音乐客户端的收藏 / 发现 / 即时混音 / 播放上报 / 歌词请求形态（照 10.10.7 实测）。
void main() {
  late List<http.Request> requests;
  late JellyfinMusicClient client;

  setUp(() {
    requests = <http.Request>[];
    client = JellyfinMusicClient(
      _config,
      httpClient: MockClient((http.Request req) async {
        requests.add(req);
        final String path = req.url.path;
        if (path == '/Audio/has/Lyrics') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'Metadata': <String, Object?>{},
                'Lyrics': <Object?>[
                  <String, Object?>{'Text': 'line', 'Start': 12340000},
                ],
              }),
            ),
            200,
          );
        }
        if (path == '/Audio/none/Lyrics') {
          return http.Response('{"title":"Not Found"}', 404);
        }
        if (path == '/MusicGenres') {
          return _items(<Map<String, Object?>>[
            <String, Object?>{'Id': 'g1', 'Name': 'Rock'},
          ]);
        }
        if (path.startsWith('/Sessions/') ||
            path.contains('/FavoriteItems/') ||
            path.contains('/PlayedItems/')) {
          return http.Response('', 204);
        }
        return _items(<Map<String, Object?>>[
          <String, Object?>{
            'Id': 'i1',
            'Name': 'Item',
            'Type': 'Audio',
            'UserData': <String, Object?>{'IsFavorite': true},
          },
        ]);
      }),
    );
  });

  test('收藏：POST / DELETE /Users/{uid}/FavoriteItems/{id}', () async {
    await client.setFavorite(MusicServerItemKind.track, 't1', favorite: true);
    await client.setFavorite(MusicServerItemKind.album, 'a1', favorite: false);
    expect(requests[0].method, 'POST');
    expect(requests[0].url.path, '/Users/uid/FavoriteItems/t1');
    expect(requests[1].method, 'DELETE');
    expect(requests[1].url.path, '/Users/uid/FavoriteItems/a1');
  });

  test(
    '补记离线播放：POST /Users/{uid}/PlayedItems/{id}?datePlayed=<UTC ISO>；开播即计次',
    () async {
      expect(client.countsPlayOnStart, isTrue);
      await client.markPlayed(
        't9',
        DateTime.fromMillisecondsSinceEpoch(1795600000000, isUtc: true),
      );
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/Users/uid/PlayedItems/t9');
      expect(
        requests.single.url.queryParameters['datePlayed'],
        DateTime.fromMillisecondsSinceEpoch(
          1795600000000,
          isUtc: true,
        ).toIso8601String(),
      );
    },
  );

  test('收藏列表按种类各一轮 Filters=IsFavorite', () async {
    final MusicServerItems favs = await client.listFavorites();
    expect(
      requests.map(
        (http.Request r) => r.url.queryParameters['IncludeItemTypes'],
      ),
      <String>['MusicAlbum', 'MusicArtist', 'Audio'],
    );
    expect(
      requests.every(
        (http.Request r) => r.url.queryParameters['Filters'] == 'IsFavorite',
      ),
      isTrue,
    );
    expect(favs.tracks.single.favorite, isTrue);
  });

  test('流派 / 流派专辑 / 最常 / 最近播放 / 最近添加的查询参数', () async {
    final List<MusicServerGenre> genres = await client.listGenres();
    expect(requests.last.url.path, '/MusicGenres');
    expect(requests.last.url.queryParameters['UserId'], 'uid');
    await client.genreAlbums(genres.single);
    expect(requests.last.url.queryParameters['GenreIds'], 'g1');
    expect(requests.last.url.queryParameters['IncludeItemTypes'], 'MusicAlbum');
    await client.genreTracks(genres.single);
    expect(requests.last.url.queryParameters['IncludeItemTypes'], 'Audio');
    final MusicServerItems most = await client.mostPlayed();
    expect(requests.last.url.queryParameters['SortBy'], 'PlayCount,SortName');
    expect(requests.last.url.queryParameters['Filters'], 'IsPlayed');
    expect(most.tracks, isNotEmpty);
    await client.recentlyPlayed();
    expect(requests.last.url.queryParameters['SortBy'], 'DatePlayed');
    await client.recentlyAddedAlbums();
    expect(requests.last.url.queryParameters['SortBy'], 'DateCreated,SortName');
  });

  test('即时混音：/Items/{id}/InstantMix', () async {
    final List<MusicServerTrack> mix = await client.instantMix(
      MusicServerItemKind.album,
      'alb',
    );
    expect(requests.single.url.path, '/Items/alb/InstantMix');
    expect(mix.single.id, 'i1');
  });

  test('播放上报复用 /Sessions/Playing*：同一会话 id、直出 / 转码 PlayMethod', () async {
    const MusicServerPlaybackReport r = MusicServerPlaybackReport(
      trackId: 't1',
      playSessionId: 'sess',
      positionMs: 1500,
      startedAtMs: 0,
      paused: true,
      transcoded: true,
    );
    await client.reportPlaybackStarted(r);
    await client.reportPlaybackProgress(
      r,
      event: MusicServerPlaybackEvent.pause,
    );
    await client.reportPlaybackStopped(r);
    expect(requests.map((http.Request q) => q.url.path), <String>[
      '/Sessions/Playing',
      '/Sessions/Playing/Progress',
      '/Sessions/Playing/Stopped',
    ]);
    final List<Map<String, Object?>> bodies = <Map<String, Object?>>[
      for (final http.Request q in requests)
        jsonDecode(q.body) as Map<String, Object?>,
    ];
    for (final Map<String, Object?> b in bodies) {
      expect(b['ItemId'], 't1');
      expect(b['PlaySessionId'], 'sess');
      expect(b['MediaSourceId'], 't1');
      expect(b['PlayMethod'], 'Transcode');
      expect(b['PositionTicks'], 1500 * 10000);
    }
    expect(bodies[1]['EventName'], 'pause');
    expect(bodies[1]['IsPaused'], isTrue);
  });

  test('流地址互认：streamFor 拼的地址认回同一曲目', () {
    const MusicServerTrack t = MusicServerTrack(id: 'abc', title: 'x');
    expect(client.streamRefOf(client.streamFor(t).uri)?.trackId, 'abc');
    expect(
      client
          .streamRefOf(client.streamFor(t, maxBitrateKbps: 128).uri)
          ?.transcoded,
      isTrue,
    );
  });

  test('歌词：有 → 同步行；404 → null', () async {
    final MusicServerLyrics l = (await client.lyricsFor('has'))!;
    expect(l.lines.single.startMs, 1234);
    expect(await client.lyricsFor('none'), isNull);
  });
}
