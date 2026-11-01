import 'dart:convert';

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart';
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

Map<String, Object?> _song(
  String id, {
  String name = 'Song',
  int disc = 1,
  int track = 1,
  bool preview = true,
  String type = 'songs',
}) => <String, Object?>{
  'id': id,
  'type': type,
  'attributes': <String, Object?>{
    'name': name,
    'artistName': 'YOASOBI',
    'albumName': 'THE BOOK',
    'discNumber': disc,
    'trackNumber': track,
    'durationInMillis': 200000,
    'isrc': 'JPXX0000$id',
    'artwork': <String, Object?>{
      'url': 'https://is1.mzstatic.com/image/$id/{w}x{h}bb.jpg',
    },
    if (preview)
      'previews': <Object?>[
        <String, Object?>{'url': 'https://audio.example/$id.m4a'},
      ],
  },
};

Map<String, Object?> _album(String id, {String? artistId, String? date}) =>
    <String, Object?>{
      'id': id,
      'type': 'albums',
      'attributes': <String, Object?>{
        'name': 'Album $id',
        'artistName': 'Artist',
        'trackCount': 10,
        if (date != null) 'releaseDate': date,
        'artwork': <String, Object?>{
          'url': 'https://is1.mzstatic.com/image/$id/{w}x{h}{c}.{f}',
        },
      },
      if (artistId != null)
        'relationships': <String, Object?>{
          'artists': <String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'id': artistId,
                'type': 'artists',
                'attributes': <String, Object?>{'name': 'Artist $artistId'},
              },
            ],
          },
        },
    };

/// 固定返回一枚 token 的来源（计数取用次数）。
class _Rig {
  _Rig(this.handler) {
    tokens = AppleMusicTokenSource(
      client: MockClient((http.Request r) async {
        tokenFetches++;
        return _json(<String, Object?>{
          'token': 'tok$tokenFetches',
          'expiresAt': 1 << 50,
        });
      }),
    );
    client = AppleMusicCatalogClient(
      tokens: tokens,
      storefront: 'JP',
      client: MockClient((http.Request r) async {
        requests.add(r);
        return handler(r);
      }),
    );
  }

  final Future<http.Response> Function(http.Request) handler;
  late final AppleMusicTokenSource tokens;
  late final AppleMusicCatalogClient client;
  final List<http.Request> requests = <http.Request>[];
  int tokenFetches = 0;
}

void main() {
  group('AppleMusicTokenSource', () {
    test('caches until near expiry and coalesces concurrent fetches', () async {
      int now = 0;
      int fetches = 0;
      final AppleMusicTokenSource src = AppleMusicTokenSource(
        now: () => now,
        client: MockClient((http.Request r) async {
          fetches++;
          expect(r.url, kAppleMusicTokenEndpoint);
          return _json(<String, Object?>{
            'token': 't$fetches',
            'expiresAt': now + const Duration(hours: 12).inMilliseconds,
          });
        }),
      );
      final List<String> both = await Future.wait(<Future<String>>[
        src.token(),
        src.token(),
      ]);
      expect(both, <String>['t1', 't1']);
      expect(fetches, 1);

      now += const Duration(hours: 11).inMilliseconds;
      expect(await src.token(), 't1');
      // 进入刷新余量：重取。
      now += const Duration(minutes: 55).inMilliseconds;
      expect(await src.token(), 't2');
      expect(fetches, 2);

      src.invalidate();
      expect(await src.token(), 't3');
    });

    test('503 maps to not_configured, garbage to bad_response', () async {
      final AppleMusicTokenSource off = AppleMusicTokenSource(
        client: MockClient(
          (_) async =>
              _json(<String, Object?>{'error': 'musickit_not_configured'}, 503),
        ),
      );
      await expectLater(
        off.token(),
        throwsA(
          isA<AppleMusicUnavailableException>().having(
            (AppleMusicUnavailableException e) => e.reason,
            'reason',
            'not_configured',
          ),
        ),
      );
      final AppleMusicTokenSource bad = AppleMusicTokenSource(
        client: MockClient((_) async => http.Response('nope', 200)),
      );
      await expectLater(
        bad.token(),
        throwsA(
          isA<AppleMusicUnavailableException>().having(
            (AppleMusicUnavailableException e) => e.reason,
            'reason',
            'bad_response',
          ),
        ),
      );
      final AppleMusicTokenSource down = AppleMusicTokenSource(
        client: MockClient((_) async => throw http.ClientException('down')),
      );
      await expectLater(
        down.token(),
        throwsA(isA<AppleMusicUnavailableException>()),
      );
    });
  });

  group('AppleMusicCatalogClient', () {
    test('identity and storefront normalisation', () {
      final _Rig rig = _Rig((_) async => _json(<String, Object?>{}));
      expect(rig.client.kind, MusicServerKind.appleMusic);
      expect(rig.client.storefront, 'jp');
      expect(rig.client.serverId, 'apple-music:jp');
      expect(normalizeAppleMusicStorefront('xyz'), 'jp');
      expect(normalizeAppleMusicStorefront(' US '), 'us');
    });

    test(
      'search sends bearer token, parses, drops preview-less songs',
      () async {
        final _Rig rig = _Rig((http.Request r) async {
          expect(r.url.path, '/v1/catalog/jp/search');
          expect(r.url.queryParameters['term'], '夜に駆ける');
          expect(r.url.queryParameters['types'], 'songs,albums,artists');
          expect(r.url.queryParameters['limit'], '25');
          expect(r.headers['Authorization'], 'Bearer tok1');
          return _json(<String, Object?>{
            'results': <String, Object?>{
              'songs': <String, Object?>{
                'data': <Object?>[_song('1'), _song('2', preview: false)],
              },
              'albums': <String, Object?>{
                'data': <Object?>[_album('a1', date: '2021-01-06')],
              },
              'artists': <String, Object?>{
                'data': <Object?>[
                  <String, Object?>{
                    'id': 'ar1',
                    'type': 'artists',
                    'attributes': <String, Object?>{'name': 'YOASOBI'},
                  },
                ],
              },
            },
          });
        });
        expect(
          (await rig.client.search('  ')).isEmpty,
          isTrue,
          reason: 'blank query must not hit the network',
        );
        expect(rig.requests, isEmpty);

        final MusicServerSearchResult r = await rig.client.search(
          '夜に駆ける',
          limit: 99,
        );
        expect(r.tracks.map((MusicServerTrack t) => t.id), <String>['1']);
        expect(r.tracks.single.codec, 'aac');
        expect(r.albums.single.year, 2021);
        expect(r.artists.single.name, 'YOASOBI');

        final MusicServerStream s = rig.client.streamFor(r.tracks.single);
        expect(s.uri.toString(), 'https://audio.example/1.m4a');
        expect(s.transcoded, isFalse);
        expect(
          () =>
              rig.client.streamFor(const MusicServerTrack(id: '2', title: 'x')),
          throwsStateError,
        );
      },
    );

    test('401 drops the cached token and retries once', () async {
      int calls = 0;
      final _Rig rig = _Rig((http.Request r) async {
        calls++;
        if (calls == 1) {
          expect(r.headers['Authorization'], 'Bearer tok1');
          return http.Response('', 401);
        }
        expect(r.headers['Authorization'], 'Bearer tok2');
        return _json(<String, Object?>{'results': <String, Object?>{}});
      });
      await rig.client.search('x');
      expect(rig.tokenFetches, 2);
      expect(calls, 2);
    });

    test('persistent 401 / 404 surface as AppleMusicApiException', () async {
      final _Rig rig = _Rig((_) async => http.Response('', 401));
      await expectLater(
        rig.client.search('x'),
        throwsA(
          isA<AppleMusicApiException>().having(
            (AppleMusicApiException e) => e.httpStatus,
            'status',
            401,
          ),
        ),
      );
      expect(rig.requests.length, 2);
    });

    test(
      'albumTracks follows next, keeps songs only, sorts by disc/track',
      () async {
        final _Rig rig = _Rig((http.Request r) async {
          if (r.url.path == '/v1/catalog/jp/albums/a1') {
            expect(r.url.queryParameters['include'], 'tracks');
            return _json(<String, Object?>{
              'data': <Object?>[
                <String, Object?>{
                  'id': 'a1',
                  'type': 'albums',
                  'attributes': <String, Object?>{'name': 'A'},
                  'relationships': <String, Object?>{
                    'tracks': <String, Object?>{
                      'data': <Object?>[
                        _song('s3', disc: 2, track: 1),
                        _song('mv', type: 'music-videos'),
                        _song('s1', track: 1),
                      ],
                      'next': '/v1/catalog/jp/albums/a1/tracks?offset=300',
                    },
                  },
                },
              ],
            });
          }
          expect(r.url.path, '/v1/catalog/jp/albums/a1/tracks');
          expect(r.url.queryParameters['offset'], '300');
          return _json(<String, Object?>{
            'data': <Object?>[_song('s2', track: 2)],
          });
        });
        final List<MusicServerTrack> tracks = await rig.client.albumTracks(
          'a1',
        );
        expect(tracks.map((MusicServerTrack t) => t.id), <String>[
          's1',
          's2',
          's3',
        ]);
      },
    );

    test('listAlbums pages the top-albums chart', () async {
      final _Rig rig = _Rig((http.Request r) async {
        expect(r.url.path, '/v1/catalog/jp/charts');
        expect(r.url.queryParameters['types'], 'albums');
        expect(r.url.queryParameters['limit'], '50');
        final int offset = int.parse(r.url.queryParameters['offset']!);
        return _json(<String, Object?>{
          'results': <String, Object?>{
            'albums': <Object?>[
              <String, Object?>{
                'data': <Object?>[_album('a$offset'), _album('b$offset')],
                if (offset == 0) 'next': '/v1/catalog/jp/charts?offset=2',
              },
            ],
          },
        });
      });
      final MusicServerPage<MusicServerAlbum> p1 = await rig.client
          .listAlbums();
      expect(p1.items.map((MusicServerAlbum a) => a.id), <String>['a0', 'b0']);
      expect(p1.nextOffset, 2);
      final MusicServerPage<MusicServerAlbum> p2 = await rig.client.listAlbums(
        offset: 2,
      );
      expect(p2.hasMore, isFalse);
    });

    test(
      'listArtists collects chart album artists in order, deduped',
      () async {
        final _Rig rig = _Rig((http.Request r) async {
          if (r.url.path == '/v1/catalog/jp/charts') {
            return _json(<String, Object?>{
              'results': <String, Object?>{
                'albums': <Object?>[
                  <String, Object?>{
                    'data': <Object?>[_album('a'), _album('b'), _album('c')],
                  },
                ],
              },
            });
          }
          expect(r.url.path, '/v1/catalog/jp/albums');
          expect(r.url.queryParameters['ids'], 'a,b,c');
          expect(r.url.queryParameters['include'], 'artists');
          return _json(<String, Object?>{
            'data': <Object?>[
              _album('a', artistId: 'x'),
              _album('b', artistId: 'y'),
              _album('c', artistId: 'x'),
            ],
          });
        });
        final List<MusicServerArtist> artists = await rig.client.listArtists();
        expect(artists.map((MusicServerArtist a) => a.id), <String>['x', 'y']);
      },
    );

    test('artistAlbums follows next and sorts newest first', () async {
      final _Rig rig = _Rig((http.Request r) async {
        if (r.url.queryParameters['offset'] == null) {
          expect(r.url.path, '/v1/catalog/jp/artists/x/albums');
          return _json(<String, Object?>{
            'data': <Object?>[_album('old', date: '2019-01-01')],
            'next': '/v1/catalog/jp/artists/x/albums?offset=100',
          });
        }
        return _json(<String, Object?>{
          'data': <Object?>[_album('new', date: '2024')],
        });
      });
      final List<MusicServerAlbum> albums = await rig.client.artistAlbums('x');
      expect(albums.map((MusicServerAlbum a) => a.id), <String>['new', 'old']);
    });

    test('artwork template expands size, crop and format', () {
      expect(
        appleMusicArtworkUri(
          'https://is1.mzstatic.com/image/x/{w}x{h}{c}.{f}',
          size: 300,
        ).toString(),
        'https://is1.mzstatic.com/image/x/300x300bb.jpg',
      );
      expect(appleMusicArtworkUri(null), isNull);
    });
  });
}
