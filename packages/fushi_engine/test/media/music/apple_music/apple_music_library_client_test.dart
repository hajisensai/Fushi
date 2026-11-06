import 'dart:convert';

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_token_source.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, Object?> _catalogSong(
  String id, {
  bool preview = true,
  bool playParams = true,
}) => <String, Object?>{
  'id': id,
  'type': 'songs',
  'attributes': <String, Object?>{
    'name': 'Song $id',
    'artistName': 'YOASOBI',
    'durationInMillis': 200000,
    if (playParams) 'playParams': <String, Object?>{'id': id, 'kind': 'song'},
    if (preview)
      'previews': <Object?>[
        <String, Object?>{'url': 'https://audio.example/$id.m4a'},
      ],
  },
};

Map<String, Object?> _librarySong(
  String id, {
  String? catalogId,
  int disc = 1,
  int track = 1,
}) => <String, Object?>{
  'id': id,
  'type': 'library-songs',
  'attributes': <String, Object?>{
    'name': 'Lib $id',
    'artistName': 'Aimer',
    'albumName': 'Walpurgis',
    'discNumber': disc,
    'trackNumber': track,
    'durationInMillis': 180000,
    'artwork': <String, Object?>{
      'url': 'https://is1.mzstatic.com/image/$id/{w}x{h}bb.jpg',
    },
    'playParams': <String, Object?>{
      'id': id,
      'kind': 'song',
      'isLibrary': true,
      if (catalogId != null) 'catalogId': catalogId,
    },
  },
};

AppleMusicTokenSource _tokens() => AppleMusicTokenSource(
  client: MockClient(
    (_) async => _json(<String, Object?>{
      'token': 'dev',
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 86400000,
    }),
  ),
);

void main() {
  group('Apple Music track uri', () {
    test('round-trips catalog ids and rejects other paths', () {
      final Uri u = appleMusicSongUri('1440833098');
      expect(u.toString(), 'fushi-apple-music://song/1440833098');
      expect(isAppleMusicTrackPath(u.toString()), isTrue);
      expect(appleMusicSongIdFromPath(u.toString()), '1440833098');
      expect(appleMusicSongIdFromPath('https://audio.example/1.m4a'), isNull);
      expect(appleMusicSongIdFromPath('fushi-apple-music://album/1'), isNull);
      expect(isAppleMusicTrackPath('fushi-music-plugin://x/1'), isFalse);
    });
  });

  group('AppleMusicCatalogClient full tracks', () {
    test(
      'preview mode keeps only songs with previews and streams them',
      () async {
        final AppleMusicCatalogClient c = AppleMusicCatalogClient(
          tokens: _tokens(),
          client: MockClient(
            (_) async => _json(<String, Object?>{
              'results': <String, Object?>{
                'songs': <String, Object?>{
                  'data': <Object?>[
                    _catalogSong('1'),
                    _catalogSong('2', preview: false),
                  ],
                },
              },
            }),
          ),
        );
        final MusicServerSearchResult r = await c.search('x');
        expect(r.tracks.map((MusicServerTrack t) => t.id), <String>['1']);
        expect(
          c.streamFor(r.tracks.single).uri.toString(),
          'https://audio.example/1.m4a',
        );
      },
    );

    test(
      'full-track mode keeps streamable songs without previews and routes to MusicKit',
      () async {
        final AppleMusicCatalogClient c = AppleMusicCatalogClient(
          tokens: _tokens(),
          fullTracks: true,
          client: MockClient(
            (_) async => _json(<String, Object?>{
              'results': <String, Object?>{
                'songs': <String, Object?>{
                  'data': <Object?>[
                    _catalogSong('1'),
                    _catalogSong('2', preview: false),
                    // 不带 playParams：订阅也放不了，不列出。
                    _catalogSong('3', playParams: false),
                  ],
                },
              },
            }),
          ),
        );
        final MusicServerSearchResult r = await c.search('x');
        expect(r.tracks.map((MusicServerTrack t) => t.id), <String>['1', '2']);
        final MusicServerStream s = c.streamFor(r.tracks[1]);
        expect(s.uri.toString(), 'fushi-apple-music://song/2');
        expect(s.transcoded, isFalse);
        expect(s.bitrateKbps, kAppleMusicFullTrackBitrateKbps);
      },
    );
  });

  group('AppleMusicLibraryClient', () {
    test(
      'sends both tokens, maps library songs to catalog ids, skips uploads',
      () async {
        final List<http.Request> seen = <http.Request>[];
        final AppleMusicLibraryClient c = AppleMusicLibraryClient(
          credentials: () async => const AppleMusicUserCredentials(
            developerToken: 'dev',
            userToken: 'user',
          ),
          client: MockClient((http.Request req) async {
            seen.add(req);
            return _json(<String, Object?>{
              'data': <Object?>[
                _librarySong('i.B', catalogId: '200', track: 2),
                _librarySong('i.A', catalogId: '100', track: 1),
                // 用户上传：没有 catalogId，MusicKit 单曲队列放不了。
                _librarySong('i.U', track: 3),
              ],
            });
          }),
        );
        final List<MusicServerTrack> tracks = await c.albumTracks('l.album');
        expect(seen.single.url.path, '/v1/me/library/albums/l.album/tracks');
        expect(seen.single.url.queryParameters['limit'], '100');
        expect(seen.single.headers['Authorization'], 'Bearer dev');
        expect(seen.single.headers['Music-User-Token'], 'user');
        expect(tracks.map((MusicServerTrack t) => t.id), <String>[
          'i.A',
          'i.B',
        ]);
        expect(tracks.first.albumId, 'l.album');
        expect(
          c.streamFor(tracks.first).uri.toString(),
          'fushi-apple-music://song/100',
        );
        expect(
          () => c.streamFor(const MusicServerTrack(id: 'i.U', title: 'x')),
          throwsStateError,
        );
      },
    );

    test('listAlbums pages by offset and reads total', () async {
      final AppleMusicLibraryClient c = AppleMusicLibraryClient(
        credentials: () async => const AppleMusicUserCredentials(
          developerToken: 'dev',
          userToken: 'user',
        ),
        client: MockClient((http.Request req) async {
          expect(req.url.path, '/v1/me/library/albums');
          final int offset = int.parse(req.url.queryParameters['offset']!);
          return _json(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'id': 'l.$offset',
                'type': 'library-albums',
                'attributes': <String, Object?>{
                  'name': 'Album $offset',
                  'artistName': 'Aimer',
                  'releaseDate': '2016-04-27',
                  'trackCount': 12,
                },
              },
            ],
            if (offset == 0) 'next': '/v1/me/library/albums?offset=1',
            'meta': <String, Object?>{'total': 2},
          });
        }),
      );
      final MusicServerPage<MusicServerAlbum> p1 = await c.listAlbums(limit: 1);
      expect(p1.items.single.title, 'Album 0');
      expect(p1.items.single.year, 2016);
      expect(p1.total, 2);
      expect(p1.nextOffset, 1);
      final MusicServerPage<MusicServerAlbum> p2 = await c.listAlbums(
        offset: 1,
        limit: 1,
      );
      expect(p2.items.single.id, 'l.1');
      expect(p2.hasMore, isFalse);
    });

    test('listArtists follows next and sorts by name', () async {
      final AppleMusicLibraryClient c = AppleMusicLibraryClient(
        credentials: () async => const AppleMusicUserCredentials(
          developerToken: 'dev',
          userToken: 'user',
        ),
        client: MockClient((http.Request req) async {
          final bool second = req.url.queryParameters['offset'] == '100';
          return _json(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'id': second ? 'r.2' : 'r.1',
                'type': 'library-artists',
                'attributes': <String, Object?>{
                  'name': second ? 'aimer' : 'YOASOBI',
                },
              },
            ],
            if (!second) 'next': '/v1/me/library/artists?offset=100',
          });
        }),
      );
      final List<MusicServerArtist> artists = await c.listArtists();
      expect(artists.map((MusicServerArtist a) => a.name), <String>[
        'aimer',
        'YOASOBI',
      ]);
    });

    test('search reads library-* result keys', () async {
      final AppleMusicLibraryClient c = AppleMusicLibraryClient(
        credentials: () async => const AppleMusicUserCredentials(
          developerToken: 'dev',
          userToken: 'user',
        ),
        client: MockClient((http.Request req) async {
          expect(req.url.path, '/v1/me/library/search');
          expect(
            req.url.queryParameters['types'],
            'library-songs,library-albums,library-artists,library-playlists',
          );
          return _json(<String, Object?>{
            'results': <String, Object?>{
              'library-songs': <String, Object?>{
                'data': <Object?>[_librarySong('i.1', catalogId: '1')],
              },
              'library-artists': <String, Object?>{
                'data': <Object?>[
                  <String, Object?>{
                    'id': 'r.1',
                    'type': 'library-artists',
                    'attributes': <String, Object?>{'name': 'Aimer'},
                  },
                ],
              },
            },
          });
        }),
      );
      final MusicServerSearchResult r = await c.search('  aimer ');
      expect(r.tracks.single.id, 'i.1');
      expect(r.artists.single.name, 'Aimer');
      expect(r.albums, isEmpty);
      expect(await c.search('   '), isA<MusicServerSearchResult>());
    });

    test('non-2xx surfaces as AppleMusicApiException', () async {
      final AppleMusicLibraryClient c = AppleMusicLibraryClient(
        credentials: () async => const AppleMusicUserCredentials(
          developerToken: 'dev',
          userToken: 'expired',
        ),
        client: MockClient((_) async => _json(<String, Object?>{}, 403)),
      );
      expect(
        c.listArtists(),
        throwsA(
          isA<AppleMusicApiException>().having(
            (AppleMusicApiException e) => e.httpStatus,
            'httpStatus',
            403,
          ),
        ),
      );
    });
  });
}
