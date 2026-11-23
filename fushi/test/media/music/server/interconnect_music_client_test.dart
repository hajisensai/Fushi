// 互联共享音乐库 client 侧（设计 docs/specs/2026-11-23-interconnect-music-library-design.md §5）：
// 浏览映射、放不了的曲目不列出、起播签票 + 旧票释放、CUE 起止、写回请求形状、播放身份（design-imusic-q1
// 选 a：uid = host track_uid）与远程曲目落库往返。host 侧路由由引擎
// `packages/fushi_engine/test/sync/music_library_host_module_test.dart` 覆盖。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_remote_media.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/server/interconnect_music_client.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';

typedef _Call = ({
  String method,
  String path,
  Map<String, String> query,
  Object? json,
});

class _FakeTransport implements InterconnectMusicTransport {
  _FakeTransport(this.handler);

  final ({int status, Object? body}) Function(_Call call) handler;
  final List<_Call> calls = <_Call>[];
  bool closed = false;

  @override
  Future<InterconnectMusicResponse> send(
    String method,
    String path, {
    Map<String, String> query = const <String, String>{},
    Object? json,
    required Duration timeout,
  }) async {
    final _Call call = (method: method, path: path, query: query, json: json);
    calls.add(call);
    final ({int status, Object? body}) r = handler(call);
    final Object? body = r.body;
    return (
      status: r.status,
      bytes: body is Uint8List
          ? body
          : Uint8List.fromList(
              utf8.encode(body == null ? '' : jsonEncode(body)),
            ),
      json: body is Map<String, Object?> ? body : null,
      resolve: (String p, Map<String, String> q) => Uri(
        scheme: 'https',
        host: '10.0.0.2',
        port: 8443,
        path: p,
        queryParameters: q.isEmpty ? null : q,
      ),
    );
  }

  @override
  void close() => closed = true;
}

Map<String, Object?> _track(
  String id, {
  String? unplayable,
  bool isVideo = false,
  int? cueStart,
  int? cueEnd,
}) => <String, Object?>{
  'id': id,
  'title': 'T-$id',
  'artist': 'A',
  'album': 'Al',
  'albumId': 'alb1',
  'durationMs': 1000,
  'coverRef': 't:$id',
  'unplayableReason': ?unplayable,
  if (isVideo) 'isVideo': true,
  'cueStartMs': ?cueStart,
  'cueEndMs': ?cueEnd,
};

void main() {
  const String serverId = 'Host-ABC';

  group('浏览', () {
    test('专辑页带排序与分页，曲目列表过滤掉本机放不了的', () async {
      final _FakeTransport t = _FakeTransport((_Call c) {
        if (c.path == '/api/library/music/albums') {
          return (
            status: 200,
            body: <String, Object?>{
              'items': <Object?>[
                <String, Object?>{'id': 'alb1', 'title': 'Album', 'year': 2020},
              ],
              'nextOffset': 100,
              'total': 150,
            },
          );
        }
        if (c.path == '/api/library/music/albums/alb1/tracks') {
          return (
            status: 200,
            body: <String, Object?>{
              'items': <Object?>[
                _track('u1'),
                _track('u2', unplayable: 'cdda'),
                _track('u3', isVideo: true),
                _track('u4'),
              ],
            },
          );
        }
        return (status: 404, body: null);
      });
      final InterconnectMusicBrowser b = InterconnectMusicBrowser(
        serverId: serverId,
        displayName: 'PC',
        transport: t,
      );
      final MusicServerPage<MusicServerAlbum> page = await b.listAlbums(
        sort: MusicServerAlbumSort.newest,
      );
      expect(page.items.single.title, 'Album');
      expect(page.nextOffset, 100);
      expect(page.total, 150);
      expect(t.calls.first.query, <String, String>{
        'offset': '0',
        'limit': '100',
        'sort': 'newest',
      });
      final List<MusicServerTrack> tracks = await b.albumTracks('alb1');
      // 曲目本身是 MV 视频的照常列（design-imusic-q8）；host 给不出字节的不列。
      expect(tracks.map((MusicServerTrack x) => x.id), <String>[
        'u1',
        'u3',
        'u4',
      ]);
      expect(b.kind, MusicServerKind.fushiHost);
    });

    test('host 错误抛 InterconnectMusicHostError（页面显示错误与重试）', () async {
      final InterconnectMusicBrowser b = InterconnectMusicBrowser(
        serverId: serverId,
        displayName: 'PC',
        transport: _FakeTransport((_) => (status: 404, body: null)),
      );
      await expectLater(
        b.albumTracks('x'),
        throwsA(isA<InterconnectMusicHostError>()),
      );
    });
  });

  group('起播签票', () {
    test('按本次走的地址重拼流地址，带 CUE 起止；只留最近 3 张票，旧票主动释放', () async {
      int n = 0;
      final _FakeTransport t = _FakeTransport((_Call c) {
        if (c.path == '/api/library/media/streamurl') {
          n++;
          return (
            status: 200,
            body: <String, Object?>{
              'url': 'https://192.168.9.9:1/api/library/media/stream?token=k$n',
              'ticket': 'k$n',
            },
          );
        }
        if (c.path.startsWith('/api/library/music/tracks/')) {
          return (
            status: 200,
            body: _track('u1', cueStart: 5000, cueEnd: 9000),
          );
        }
        if (c.path == '/api/library/media/streamrelease') {
          return (status: 204, body: null);
        }
        return (status: 404, body: null);
      });
      final InterconnectMusicBrowser b = InterconnectMusicBrowser(
        serverId: serverId,
        displayName: 'PC',
        transport: t,
      );
      final InterconnectMusicOpenedTrack first = await b.openTrack('u1');
      expect(
        first.url,
        'https://10.0.0.2:8443/api/library/media/stream?token=k1',
      );
      expect(first.startMs, 5000);
      expect(first.endMs, 9000);
      final _Call issue = t.calls.firstWhere(
        (_Call c) => c.path == '/api/library/media/streamurl',
      );
      expect(issue.json, <String, Object?>{'kind': 'musicTrack', 'id': 'u1'});

      for (int i = 0; i < 3; i++) {
        await b.openTrack('u1');
      }
      await Future<void>.delayed(Duration.zero);
      expect(b.heldTrackTickets, <String>['k2', 'k3', 'k4']);
      final List<_Call> released = t.calls
          .where((_Call c) => c.path == '/api/library/media/streamrelease')
          .toList();
      expect(released.single.query, <String, String>{'ticket': 'k1'});

      await b.dispose();
      expect(t.closed, isTrue);
      expect(
        t.calls
            .where((_Call c) => c.path == '/api/library/media/streamrelease')
            .map((_Call c) => c.query['ticket']),
        containsAll(<String>['k1', 'k2', 'k3', 'k4']),
      );
    });

    test('码率上限随签票带给 host；host 截好段时不再用曲目行的 CUE 起止', () async {
      final _FakeTransport t = _FakeTransport((_Call c) {
        if (c.path == '/api/library/media/streamurl') {
          return (
            status: 200,
            body: <String, Object?>{
              'url': 'https://h/api/library/media/stream?token=z',
              'ticket': 'z',
              'segmentApplied': true,
              'transcoded': true,
            },
          );
        }
        return (status: 200, body: _track('u1', cueStart: 5000, cueEnd: 9000));
      });
      final InterconnectMusicBrowser b = InterconnectMusicBrowser(
        serverId: serverId,
        displayName: 'PC',
        transport: t,
        maxBitrateKbps: () => 128,
      );
      final InterconnectMusicOpenedTrack o = await b.openTrack('u1');
      expect(o.startMs, isNull);
      expect(o.endMs, isNull);
      expect(
        t.calls
            .firstWhere((_Call c) => c.path == '/api/library/media/streamurl')
            .json,
        <String, Object?>{
          'kind': 'musicTrack',
          'id': 'u1',
          'options': <String, Object?>{'maxBitrateKbps': 128},
        },
      );
    });

    test('resolveMusicMedia：占位路径起播时签票；CUE 曲目给 EDL 段', () async {
      final MusicPlayItem item = MusicPlayItem(
        trackUid: 'u1',
        path: fushiHostMusicTrackPath(serverId, 'u1'),
        title: 'T',
      );
      expect(musicItemResolvesStream(item), isTrue);
      final MusicResolvedMedia whole = await resolveMusicMedia(
        item,
        fushiHostOpener: (String p) async {
          expect(p, item.path);
          return (url: 'https://h/s?token=a', startMs: null, endMs: null);
        },
      );
      expect(whole.media.uri, 'https://h/s?token=a');
      final MusicResolvedMedia cue = await resolveMusicMedia(
        item,
        fushiHostOpener: (_) async =>
            (url: 'https://h/s?token=b', startMs: 5000, endMs: 9000),
      );
      expect(
        cue.media.uri,
        musicEdlUri('https://h/s?token=b', startMs: 5000, endMs: 9000),
      );
    });
  });

  group('写回 host（design-imusic-q3 选 c）', () {
    test('歌词：204 = 没有；偏移带 updatedAt；换来源 raw 用 base64', () async {
      final _FakeTransport t = _FakeTransport((_Call c) {
        if (c.method == 'GET') return (status: 204, body: null);
        return (status: 200, body: <String, Object?>{'offsetMs': 120});
      });
      final InterconnectMusicBrowser b = InterconnectMusicBrowser(
        serverId: serverId,
        displayName: 'PC',
        transport: t,
        now: () => DateTime.fromMillisecondsSinceEpoch(777),
      );
      expect(await b.lyricsFor('u1'), isNull);
      await b.setLyricsOffset('u1', source: 'sidecar', offsetMs: 120);
      expect(t.calls[1].method, 'PUT');
      expect(t.calls[1].path, '/api/library/music/tracks/u1/lyrics/offset');
      expect(t.calls[1].json, <String, Object?>{
        'source': 'sidecar',
        'offsetMs': 120,
        'updatedAt': 777,
      });
      await b.chooseLyrics(
        'u1',
        format: 'lrc',
        raw: utf8.encode('[00:01.00]x'),
        offsetMs: 0,
      );
      expect(
        (t.calls[2].json! as Map<String, Object?>)['raw'],
        base64Encode(utf8.encode('[00:01.00]x')),
      );
    });

    test('歌单编辑与 MV 微调走 host 路由', () async {
      final _FakeTransport t = _FakeTransport((_Call c) {
        if (c.method == 'POST' && c.path == '/api/library/music/playlists') {
          return (
            status: 200,
            body: <String, Object?>{
              'id': 'pl1',
              'title': 'Mine',
              'editable': true,
            },
          );
        }
        return (status: 204, body: null);
      });
      final InterconnectMusicBrowser b = InterconnectMusicBrowser(
        serverId: serverId,
        displayName: 'PC',
        transport: t,
        now: () => DateTime.fromMillisecondsSinceEpoch(5),
      );
      final MusicServerPlaylist p = await b.createPlaylist(
        'Mine',
        trackIds: <String>['u1'],
      );
      expect(p.editable, isTrue);
      await b.addToPlaylist('pl1', <String>['u2']);
      await b.removeFromPlaylist('pl1', <String>['7']);
      await b.movePlaylistEntry('pl1', '8', 0);
      await b.renamePlaylist('pl1', 'New');
      await b.deletePlaylist('pl1');
      await b.setVideoOffset(
        const MusicServerVideo(id: '3', kind: 'local', offsetMs: 0),
        -250,
      );
      expect(t.calls.map((_Call c) => '${c.method} ${c.path}'), <String>[
        'POST /api/library/music/playlists',
        'POST /api/library/music/playlists/pl1/tracks',
        'POST /api/library/music/playlists/pl1/entries/remove',
        'PUT /api/library/music/playlists/pl1/entries/8/position',
        'PUT /api/library/music/playlists/pl1',
        'DELETE /api/library/music/playlists/pl1',
        'PUT /api/library/music/videos/3/offset',
      ]);
      expect(t.calls.last.json, <String, Object?>{
        'offsetMs': -250,
        'updatedAt': 5,
      });
    });
  });

  group('播放身份与远程曲目（design-imusic-q1 选 a）', () {
    final InterconnectMusicBrowser b = InterconnectMusicBrowser(
      serverId: serverId,
      displayName: 'PC',
      transport: _FakeTransport((_) => (status: 404, body: null)),
    );
    const MusicServerTrack track = MusicServerTrack(
      id: 'uid-1',
      title: 'Song',
      albumId: 'alb-1',
      coverRef: 't:uid-1',
    );

    test('占位路径保住大小写，经 Uri 往返仍能解析', () {
      final String path = fushiHostMusicTrackPath(serverId, 'Uid/1');
      expect(parseFushiHostMusicTrackPath(path), (
        hostId: serverId,
        trackUid: 'Uid/1',
      ));
      expect(parseFushiHostMusicTrackPath(Uri.parse(path).toString()), (
        hostId: serverId,
        trackUid: 'Uid/1',
      ));
      expect(isFushiHostMusicPath(path), isTrue);
      expect(parseFushiHostMusicCoverPath(path), isNull);
    });

    test('播放项 uid 就是 host 的 track_uid，专辑 uid 同理', () {
      final MusicPlayItem item = musicServerPlayItem(b, track);
      expect(item.trackUid, 'uid-1');
      expect(item.albumUid, 'alb-1');
      expect(item.path, fushiHostMusicTrackPath(serverId, 'uid-1'));
      expect(item.coverPath, fushiHostMusicCoverPath(serverId, 't:uid-1'));
      expect(musicItemIsRemoteTrack(item), isTrue);
    });

    test('加入音乐库 / 歌单：落成 fushi_host 行，再还原成同一个播放项', () {
      final MusicRemoteTracksCompanion fromServer =
          musicServerRemoteTrackCompanion(b, track)!;
      expect(fromServer.kind.value, 'fushi_host');
      expect(fromServer.trackUid.value, 'uid-1');
      final MusicRemoteTracksCompanion c = musicRemoteTrackCompanionOf(
        musicServerPlayItem(b, track),
      )!;
      expect(c.kind.value, 'fushi_host');
      expect(c.sourceKey.value, serverId);
      expect(c.itemId.value, 'uid-1');
      expect(c.coverUrl.value, isNull);
      expect(c.coverRef.value, 't:uid-1');
      final MusicRemoteTrackRow row = MusicRemoteTrackRow(
        trackUid: c.trackUid.value,
        kind: c.kind.value,
        sourceKey: c.sourceKey.value,
        itemId: c.itemId.value,
        title: c.title.value,
        coverRef: c.coverRef.value,
        albumId: 'alb-1',
        createdAt: 1,
        updatedAt: 1,
      );
      final MusicPlayItem back = musicPlayItemOfRemote(row)!;
      expect(back.trackUid, 'uid-1');
      expect(back.path, fushiHostMusicTrackPath(serverId, 'uid-1'));
      expect(back.coverPath, fushiHostMusicCoverPath(serverId, 't:uid-1'));
      expect(
        musicRemoteCoverUrlOf(row),
        fushiHostMusicCoverPath(serverId, 't:uid-1'),
      );
      expect(
        musicRemoteKindAvailable(MusicRemoteTrackKind.fushiHost, online: false),
        isTrue,
      );
    });
  });
}
