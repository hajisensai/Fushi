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

void main() {
  late List<http.Request> requests;
  late JellyfinMusicClient client;

  setUp(() {
    requests = <http.Request>[];
    client = JellyfinMusicClient(
      _config,
      httpClient: MockClient((http.Request req) async {
        requests.add(req);
        if (req.method == 'POST' && req.url.path == '/Playlists') {
          return http.Response(
            jsonEncode(<String, Object?>{'Id': 'new1'}),
            200,
          );
        }
        if (req.method == 'GET' && req.url.path == '/Playlists/p1/Items') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'Items': <Object?>[
                <String, Object?>{
                  'Id': 's1',
                  'Name': 'Song',
                  'Type': 'Audio',
                  'PlaylistItemId': 'e1',
                  'Path': '/media/music/song.flac',
                },
                <String, Object?>{
                  'Id': 's1',
                  'Name': 'Song',
                  'Type': 'Audio',
                  'PlaylistItemId': 'e2',
                },
              ],
            }),
            200,
          );
        }
        if (req.method == 'GET' && req.url.path == '/Users/uid/Items') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'Items': <Object?>[
                <String, Object?>{
                  'Id': 'mine',
                  'Name': 'Mine',
                  'CanDelete': true,
                },
                <String, Object?>{
                  'Id': 'theirs',
                  'Name': 'Theirs',
                  'CanDelete': false,
                },
                <String, Object?>{'Id': 'old', 'Name': 'Old server'},
              ],
              'TotalRecordCount': 3,
            }),
            200,
          );
        }
        return http.Response('', 204);
      }),
    );
  });

  test('歌单曲目带条目 id 与服务器路径；CanDelete=false 的歌单不可改', () async {
    final List<MusicServerTrack> tracks = await client.playlistTracks('p1');
    expect(tracks.map((MusicServerTrack t) => t.playlistEntryId), <String?>[
      'e1',
      'e2',
    ]);
    expect(tracks.first.path, '/media/music/song.flac');
    expect(tracks.last.path, isNull);
    expect(requests.single.url.queryParameters['Fields'], contains('Path'));

    final MusicServerPage<MusicServerPlaylist> lists = await client
        .listPlaylists();
    expect(
      <String, bool>{
        for (final MusicServerPlaylist p in lists.items) p.id: p.editable,
      },
      <String, bool>{'mine': true, 'theirs': false, 'old': true},
    );
  });

  test('新建：查询串与 JSON 体都带名字 / 用户 / 音频类型 / 曲目', () async {
    final MusicServerPlaylist p = await client.createPlaylist(
      'Night',
      trackIds: <String>['a', 'b'],
    );
    expect(p.id, 'new1');
    expect(p.title, 'Night');
    expect(p.editable, isTrue);
    final http.Request req = requests.single;
    expect(req.method, 'POST');
    expect(req.url.queryParameters, <String, String>{
      'Name': 'Night',
      'UserId': 'uid',
      'MediaType': 'Audio',
      'Ids': 'a,b',
    });
    expect(jsonDecode(req.body), <String, Object?>{
      'Name': 'Night',
      'UserId': 'uid',
      'MediaType': 'Audio',
      'Ids': <Object?>['a', 'b'],
    });
    expect(req.headers['X-Emby-Authorization'], contains('tok'));
  });

  test('加歌 / 删条目 / 挪位置 / 改名 / 删除各走对应端点', () async {
    await client.addToPlaylist('p1', <String>['a', 'b']);
    await client.removeFromPlaylist('p1', <String>['e1', 'e2']);
    await client.movePlaylistEntry('p1', 'e2', 0);
    await client.renamePlaylist('p1', 'New name');
    await client.deletePlaylist('p1');
    // 空列表不发请求。
    await client.addToPlaylist('p1', const <String>[]);
    await client.removeFromPlaylist('p1', const <String>[]);

    expect(
      requests.map((http.Request r) => '${r.method} ${r.url.path}'),
      <String>[
        'POST /Playlists/p1/Items',
        'DELETE /Playlists/p1/Items',
        'POST /Playlists/p1/Items/e2/Move/0',
        'POST /Playlists/p1',
        'DELETE /Items/p1',
      ],
    );
    expect(requests[0].url.queryParameters, <String, String>{
      'Ids': 'a,b',
      'UserId': 'uid',
    });
    expect(requests[1].url.queryParameters, <String, String>{
      'EntryIds': 'e1,e2',
    });
    expect(jsonDecode(requests[3].body), <String, Object?>{'Name': 'New name'});
  });

  test('服务器拒绝（403）时抛错，不吞', () async {
    final JellyfinMusicClient denied = JellyfinMusicClient(
      _config,
      httpClient: MockClient(
        (http.Request req) async => http.Response('forbidden', 403),
      ),
    );
    await expectLater(
      denied.deletePlaylist('p1'),
      throwsA(isA<JellyfinApiException>()),
    );
  });
}
