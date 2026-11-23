import 'dart:convert';

import 'package:fushi_engine/media/music/server/jellyfin_music_parse.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/subsonic_music_client.dart';
import 'package:fushi_engine/media/music/server/subsonic_server_config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Map<String, Object?> _ok(Map<String, Object?> body) => <String, Object?>{
  'subsonic-response': <String, Object?>{
    'status': 'ok',
    'version': '1.16.1',
    'openSubsonic': true,
    ...body,
  },
};

Map<String, Object?> _fail(int code) => <String, Object?>{
  'subsonic-response': <String, Object?>{
    'status': 'failed',
    'error': <String, Object?>{'code': code, 'message': 'nope'},
  },
};

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

class _Rig {
  _Rig(this.handler) {
    client = SubsonicMusicClient(
      SubsonicServerConfig(
        id: 'nd',
        name: 'Navidrome',
        serverUrl: Uri.parse('https://music.example.com/navi/'),
        username: 'alice',
        password: 'sesame',
      ),
      client: MockClient((http.Request r) async {
        requests.add(r.url);
        return handler(r);
      }),
      saltSource: () => 'abcdef',
    );
  }

  final Future<http.Response> Function(http.Request) handler;
  final List<Uri> requests = <Uri>[];
  late final SubsonicMusicClient client;
}

MusicServerPlaybackReport _report({required int positionMs, int? durationMs}) =>
    MusicServerPlaybackReport(
      trackId: 's1',
      playSessionId: 'sess',
      positionMs: positionMs,
      startedAtMs: 1700000000000,
      durationMs: durationMs,
    );

void main() {
  group('Jellyfin 解析', () {
    test('流地址认回曲目：直出 / 转码 / 子路径；别的路径不认', () {
      final MusicServerStreamRef? direct = jellyfinStreamRefOf(
        Uri.parse('http://nas:8096/Audio/abc/stream?static=true&api_key=x'),
      );
      expect(direct?.trackId, 'abc');
      expect(direct?.transcoded, isFalse);
      final MusicServerStreamRef? universal = jellyfinStreamRefOf(
        Uri.parse('https://h/jellyfin/Audio/def/universal?UserId=u'),
      );
      expect(universal?.trackId, 'def');
      expect(universal?.transcoded, isTrue);
      expect(
        jellyfinStreamRefOf(Uri.parse('http://nas/Videos/abc/stream')),
        isNull,
      );
      expect(jellyfinStreamRefOf(Uri.parse('http://nas/Audio/abc')), isNull);
    });

    test('与 jellyfinMusicStreamRequest 拼出的地址互逆', () {
      for (final int? limit in <int?>[null, 192]) {
        final ({String path, Map<String, String> query, bool transcoded}) req =
            jellyfinMusicStreamRequest(
              trackId: 't9',
              userId: 'u',
              deviceId: 'd',
              token: 'tok',
              maxBitrateKbps: limit,
            );
        final Uri uri = Uri.parse(
          'http://nas:8096${req.path}',
        ).replace(queryParameters: req.query);
        final MusicServerStreamRef ref = jellyfinStreamRefOf(uri)!;
        expect(ref.trackId, 't9');
        expect(ref.transcoded, req.transcoded);
      }
    });

    test('歌词：Jellyfin 10.10 真实响应形态 → 同步 LRC', () {
      // 照 dev 服务器 `/Audio/{id}/Lyrics` 的原样响应（Start 是 100 ns 刻度）。
      final MusicServerLyrics lyrics = parseJellyfinLyrics(<String, Object?>{
        'Metadata': <String, Object?>{},
        'Lyrics': <Object?>[
          <String, Object?>{'Text': '初恋テスト Track 1 一行目', 'Start': 0},
          <String, Object?>{'Text': '二行目の歌詞です', 'Start': 50000000},
          <String, Object?>{'Text': '三行目 さようなら', 'Start': 100000000},
        ],
      })!;
      expect(lyrics.synced, isTrue);
      final ({String text, String format}) raw = lyrics.toRaw();
      expect(raw.format, 'lrc');
      expect(
        raw.text,
        '[00:00.00]初恋テスト Track 1 一行目\n'
        '[00:05.00]二行目の歌詞です\n'
        '[00:10.00]三行目 さようなら\n',
      );
    });

    test('歌词：没有时间的行 → 纯文本；空 / 坏数据 → null', () {
      final MusicServerLyrics plain = parseJellyfinLyrics(<String, Object?>{
        'Lyrics': <Object?>[
          <String, Object?>{'Text': 'a'},
          <String, Object?>{'Text': 'b'},
        ],
      })!;
      expect(plain.synced, isFalse);
      expect(plain.toRaw(), (text: 'a\nb', format: 'txt'));
      expect(
        parseJellyfinLyrics(<String, Object?>{'Lyrics': <Object?>[]}),
        isNull,
      );
      expect(parseJellyfinLyrics('x'), isNull);
    });

    test('收藏读 UserData.IsFavorite；流派带封面', () {
      final MusicServerTrack t = parseJellyfinMusicTrack(<String, Object?>{
        'Id': 't',
        'Name': 'n',
        'UserData': <String, Object?>{'IsFavorite': true, 'PlayCount': 3},
      })!;
      expect(t.favorite, isTrue);
      expect(
        parseJellyfinMusicAlbum(<String, Object?>{'Id': 'a'})!.favorite,
        isNull,
      );
      final MusicServerGenre g = parseJellyfinMusicGenre(<String, Object?>{
        'Id': 'g1',
        'Name': 'J-Pop',
        'ImageTags': <String, Object?>{'Primary': 'x'},
      })!;
      expect(g.name, 'J-Pop');
      expect(g.coverRef, 'g1');
    });

    test('LRC 时间戳按分 / 秒 / 百分秒补零', () {
      const MusicServerLyrics l = MusicServerLyrics(
        lines: <MusicServerLyricLine>[
          MusicServerLyricLine(text: 'x', startMs: 61234),
        ],
      );
      expect(l.toRaw().text, '[01:01.23]x\n');
    });
  });

  group('scrobble 门槛', () {
    test('一半或 4 分钟', () {
      expect(musicScrobbleThresholdReached(29000, 60000), isFalse);
      expect(musicScrobbleThresholdReached(30000, 60000), isTrue);
      expect(musicScrobbleThresholdReached(240000, 900000), isTrue);
      expect(musicScrobbleThresholdReached(200000, null), isFalse);
    });
  });

  group('Subsonic', () {
    test('流地址认回曲目（raw = 直出，其余 = 请求了转码）', () {
      final _Rig rig = _Rig((_) async => _json(_ok(<String, Object?>{})));
      const MusicServerTrack track = MusicServerTrack(id: 's7', title: 't');
      final MusicServerStreamRef raw = rig.client.streamRefOf(
        rig.client.streamFor(track).uri,
      )!;
      expect(raw.trackId, 's7');
      expect(raw.transcoded, isFalse);
      final MusicServerStreamRef opus = rig.client.streamRefOf(
        rig.client.streamFor(track, maxBitrateKbps: 128).uri,
      )!;
      expect(opus.transcoded, isTrue);
      expect(
        rig.client.streamRefOf(Uri.parse('https://x/rest/getCoverArt?id=1')),
        isNull,
      );
    });

    test('开播报正在播放；停止时听够门槛才提交', () async {
      final _Rig rig = _Rig((_) async => _json(_ok(<String, Object?>{})));
      await rig.client.reportPlaybackStarted(_report(positionMs: 0));
      expect(rig.requests.single.path, '/navi/rest/scrobble');
      expect(rig.requests.single.queryParameters['submission'], 'false');
      rig.requests.clear();
      await rig.client.reportPlaybackProgress(_report(positionMs: 10000));
      expect(rig.requests, isEmpty);
      await rig.client.reportPlaybackStopped(
        _report(positionMs: 10000, durationMs: 300000),
      );
      expect(rig.requests, isEmpty);
      await rig.client.reportPlaybackStopped(
        _report(positionMs: 160000, durationMs: 300000),
      );
      final Map<String, String> q = rig.requests.single.queryParameters;
      expect(q['submission'], 'true');
      expect(q['id'], 's1');
      expect(q['time'], '1700000000000');
    });

    test('补记离线播放：scrobble 带原开播毫秒、submission=true；停止时才计次', () async {
      final _Rig rig = _Rig((_) async => _json(_ok(<String, Object?>{})));
      expect(rig.client.countsPlayOnStart, isFalse);
      await rig.client.markPlayed(
        's9',
        DateTime.fromMillisecondsSinceEpoch(1700000123456, isUtc: true),
      );
      final Map<String, String> q = rig.requests.single.queryParameters;
      expect(rig.requests.single.path, '/navi/rest/scrobble');
      expect(q['id'], 's9');
      expect(q['time'], '1700000123456');
      expect(q['submission'], 'true');
    });

    test('收藏按种类发 id / albumId / artistId；starred 读成收藏', () async {
      final _Rig rig = _Rig((http.Request r) async {
        if (r.url.path.endsWith('getStarred2')) {
          return _json(
            _ok(<String, Object?>{
              'starred2': <String, Object?>{
                'song': <Object?>[
                  <String, Object?>{
                    'id': 's1',
                    'title': 'Song',
                    'starred': '2026-01-01T00:00:00Z',
                  },
                ],
                'album': <String, Object?>{'id': 'a1', 'name': 'Album'},
              },
            }),
          );
        }
        return _json(_ok(<String, Object?>{}));
      });
      await rig.client.setFavorite(
        MusicServerItemKind.album,
        'a1',
        favorite: true,
      );
      expect(rig.requests.last.path, '/navi/rest/star');
      expect(rig.requests.last.queryParameters['albumId'], 'a1');
      await rig.client.setFavorite(
        MusicServerItemKind.track,
        's1',
        favorite: false,
      );
      expect(rig.requests.last.path, '/navi/rest/unstar');
      expect(rig.requests.last.queryParameters['id'], 's1');
      final MusicServerItems favs = await rig.client.listFavorites();
      expect(favs.tracks.single.favorite, isTrue);
      expect(favs.albums.single.id, 'a1');
      expect(favs.albums.single.favorite, isFalse);
    });

    test('流派：getGenres 按名排、byGenre 专辑、getSongsByGenre 曲目', () async {
      final _Rig rig = _Rig((http.Request r) async {
        final String m = r.url.pathSegments.last;
        if (m == 'getGenres') {
          return _json(
            _ok(<String, Object?>{
              'genres': <String, Object?>{
                'genre': <Object?>[
                  <String, Object?>{
                    'value': 'Rock',
                    'songCount': 7,
                    'albumCount': 2,
                  },
                  <String, Object?>{'value': 'Ambient', 'songCount': 3},
                ],
              },
            }),
          );
        }
        if (m == 'getSongsByGenre') {
          return _json(
            _ok(<String, Object?>{
              'songsByGenre': <String, Object?>{
                'song': <Object?>[
                  <String, Object?>{'id': 'x', 'title': 'X'},
                ],
              },
            }),
          );
        }
        return _json(
          _ok(<String, Object?>{
            'albumList2': <String, Object?>{
              'album': <Object?>[
                <String, Object?>{'id': 'a', 'name': 'A'},
              ],
            },
          }),
        );
      });
      final List<MusicServerGenre> genres = await rig.client.listGenres();
      expect(genres.map((MusicServerGenre g) => g.name), <String>[
        'Ambient',
        'Rock',
      ]);
      expect(genres.last.albumCount, 2);
      await rig.client.genreAlbums(genres.last);
      expect(rig.requests.last.queryParameters['type'], 'byGenre');
      expect(rig.requests.last.queryParameters['genre'], 'Rock');
      final List<MusicServerTrack> tracks = await rig.client.genreTracks(
        genres.last,
      );
      expect(tracks.single.id, 'x');
      final MusicServerItems most = await rig.client.mostPlayed();
      expect(rig.requests.last.queryParameters['type'], 'frequent');
      expect(most.albums.single.id, 'a');
      await rig.client.recentlyPlayed();
      expect(rig.requests.last.queryParameters['type'], 'recent');
      await rig.client.recentlyAddedAlbums();
      expect(rig.requests.last.queryParameters['type'], 'newest');
    });

    test('即时混音走 getSimilarSongs', () async {
      final _Rig rig = _Rig(
        (_) async => _json(
          _ok(<String, Object?>{
            'similarSongs': <String, Object?>{
              'song': <Object?>[
                <String, Object?>{'id': 'm1', 'title': 'M'},
              ],
            },
          }),
        ),
      );
      final List<MusicServerTrack> mix = await rig.client.instantMix(
        MusicServerItemKind.artist,
        'ar1',
      );
      expect(rig.requests.single.path, '/navi/rest/getSimilarSongs');
      expect(rig.requests.single.queryParameters['id'], 'ar1');
      expect(mix.single.id, 'm1');
    });

    test('歌词：取同步那份并按 offset 前移；不支持 / 没有 → null', () async {
      final _Rig rig = _Rig(
        (_) async => _json(
          _ok(<String, Object?>{
            'lyricsList': <String, Object?>{
              'structuredLyrics': <Object?>[
                <String, Object?>{
                  'synced': false,
                  'line': <Object?>[
                    <String, Object?>{'value': 'plain'},
                  ],
                },
                <String, Object?>{
                  'synced': true,
                  'offset': 100,
                  'line': <Object?>[
                    <String, Object?>{'start': 1000, 'value': 'one'},
                    <String, Object?>{'start': 2500, 'value': 'two'},
                  ],
                },
              ],
            },
          }),
        ),
      );
      final MusicServerLyrics l = (await rig.client.lyricsFor('s1'))!;
      expect(l.synced, isTrue);
      expect(l.lines.map((MusicServerLyricLine x) => x.startMs), <int>[
        900,
        2400,
      ]);
      final _Rig unsupported = _Rig((_) async => _json(_fail(0)));
      expect(await unsupported.client.lyricsFor('s1'), isNull);
      final _Rig notFound = _Rig((_) async => http.Response('', 404));
      expect(await notFound.client.lyricsFor('s1'), isNull);
      final _Rig badAuth = _Rig((_) async => _json(_fail(40)));
      await expectLater(
        badAuth.client.lyricsFor('s1'),
        throwsA(isA<SubsonicApiException>()),
      );
    });
  });
}
