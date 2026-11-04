import 'dart:convert';

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_items.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_personal_client.dart';
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

Map<String, Object?> _song(String id, {bool preview = true}) =>
    <String, Object?>{
      'id': id,
      'type': 'songs',
      'attributes': <String, Object?>{
        'name': 'Song $id',
        'artistName': 'YOASOBI',
        'durationInMillis': 200000,
        'playParams': <String, Object?>{'id': id, 'kind': 'song'},
        if (preview)
          'previews': <Object?>[
            <String, Object?>{'url': 'https://audio.example/$id.m4a'},
          ],
      },
    };

Map<String, Object?> _librarySong(String id, String? catalogId) =>
    <String, Object?>{
      'id': id,
      'type': 'library-songs',
      'attributes': <String, Object?>{
        'name': 'Lib $id',
        'artistName': 'Aimer',
        'playParams': <String, Object?>{
          'id': id,
          'kind': 'song',
          'isLibrary': true,
          'catalogId': ?catalogId,
        },
      },
    };

Map<String, Object?> _playlist(
  String id, {
  String type = 'playlists',
  bool canEdit = false,
}) => <String, Object?>{
  'id': id,
  'type': type,
  'attributes': <String, Object?>{
    'name': 'Playlist $id',
    'curatorName': 'Apple Music',
    'description': <String, Object?>{
      'standard': 'Best of <b>J-Pop</b> &amp; more',
    },
    'artwork': <String, Object?>{'url': 'https://img/$id/{w}x{h}bb.jpg'},
    if (type == 'library-playlists') 'canEdit': canEdit,
  },
};

Map<String, Object?> _album(String id, {String type = 'albums'}) =>
    <String, Object?>{
      'id': id,
      'type': type,
      'attributes': <String, Object?>{
        'name': 'Album $id',
        'artistName': 'Aimer',
        'releaseDate': '2021-04-14',
      },
    };

Map<String, Object?> _station(String id, {bool live = false}) =>
    <String, Object?>{
      'id': id,
      'type': 'stations',
      'attributes': <String, Object?>{
        'name': 'Station $id',
        'isLive': live,
        'editorialNotes': <String, Object?>{'short': 'notes $id'},
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

Future<AppleMusicUserCredentials> _creds() async =>
    const AppleMusicUserCredentials(developerToken: 'dev', userToken: 'usr');

void main() {
  group('parsers', () {
    test('playlist strips html, maps curator and editability', () {
      final MusicServerPlaylist? c = parseAppleMusicPlaylist(_playlist('pl.1'));
      expect(c!.title, 'Playlist pl.1');
      expect(c.curator, 'Apple Music');
      expect(c.description, 'Best of J-Pop & more');
      expect(c.editable, isFalse);
      final MusicServerPlaylist? l = parseAppleMusicPlaylist(
        _playlist('p.1', type: 'library-playlists', canEdit: true),
      );
      expect(l!.editable, isTrue);
      expect(parseAppleMusicPlaylist(_album('1')), isNull);
    });

    test('mixed items keep order, dedupe, map library songs to catalog', () {
      final List<AppleMusicItem> items = parseAppleMusicItems(<Object?>[
        _album('1'),
        _album('l.1', type: 'library-albums'),
        _playlist('pl.1'),
        _album('1'),
        _station('ra.1', live: true),
        _librarySong('i.1', '555'),
        _librarySong('i.2', null),
        <String, Object?>{'id': 'mv', 'type': 'music-videos'},
      ]);
      expect(items.map((AppleMusicItem i) => i.key), <String>[
        'c-album-1',
        'l-album-l.1',
        'c-playlist-pl.1',
        'c-station-ra.1',
        'c-song-555',
      ]);
      final AppleMusicStationItem st = items[3] as AppleMusicStationItem;
      expect(st.station.isLive, isTrue);
      expect(st.station.subtitle, 'notes ra.1');
    });
  });

  group('AppleMusicCatalogClient playlists / charts / artist views', () {
    test('listPlaylists pages the top-playlists chart', () async {
      final AppleMusicCatalogClient c = AppleMusicCatalogClient(
        tokens: _tokens(),
        client: MockClient((http.Request r) async {
          expect(r.url.path, '/v1/catalog/jp/charts');
          expect(r.url.queryParameters['types'], 'playlists');
          return _json(<String, Object?>{
            'results': <String, Object?>{
              'playlists': <Object?>[
                <String, Object?>{
                  'data': <Object?>[_playlist('pl.1'), _playlist('pl.2')],
                  'next': '/v1/catalog/jp/charts?offset=2',
                },
              ],
            },
          });
        }),
      );
      final MusicServerPage<MusicServerPlaylist> p = await c.listPlaylists(
        offset: 4,
      );
      expect(p.items.map((MusicServerPlaylist x) => x.id), <String>[
        'pl.1',
        'pl.2',
      ]);
      expect(p.nextOffset, 6);
    });

    test('playlistTracks keeps playlist order and follows next', () async {
      final AppleMusicCatalogClient c = AppleMusicCatalogClient(
        tokens: _tokens(),
        client: MockClient((http.Request r) async {
          if (r.url.path == '/v1/catalog/jp/playlists/pl.1') {
            expect(r.url.queryParameters['include'], 'tracks');
            return _json(<String, Object?>{
              'data': <Object?>[
                <String, Object?>{
                  ..._playlist('pl.1'),
                  'relationships': <String, Object?>{
                    'tracks': <String, Object?>{
                      'data': <Object?>[_song('3'), _song('1')],
                      'next': '/v1/catalog/jp/playlists/pl.1/tracks?offset=2',
                    },
                  },
                },
              ],
            });
          }
          expect(r.url.path, '/v1/catalog/jp/playlists/pl.1/tracks');
          return _json(<String, Object?>{
            'data': <Object?>[_song('2'), _song('9', preview: false)],
          });
        }),
      );
      final List<MusicServerTrack> t = await c.playlistTracks('pl.1');
      expect(t.map((MusicServerTrack x) => x.id), <String>['3', '1', '2']);
    });

    test('charts parses the three kinds and passes genre', () async {
      final AppleMusicCatalogClient c = AppleMusicCatalogClient(
        tokens: _tokens(),
        client: MockClient((http.Request r) async {
          expect(r.url.queryParameters['genre'], '27');
          expect(r.url.queryParameters['types'], 'songs,albums,playlists');
          return _json(<String, Object?>{
            'results': <String, Object?>{
              'songs': <Object?>[
                <String, Object?>{
                  'name': 'Top Songs',
                  'data': <Object?>[_song('1')],
                },
              ],
              'albums': <Object?>[
                <String, Object?>{
                  'name': 'Top Albums',
                  'data': <Object?>[_album('a')],
                },
              ],
              'playlists': <Object?>[
                <String, Object?>{
                  'data': <Object?>[_playlist('pl.1')],
                },
              ],
            },
          });
        }),
      );
      final AppleMusicCharts ch = await c.charts(genreId: '27');
      expect(ch.songs.single.id, '1');
      expect(ch.albums.single.id, 'a');
      expect(ch.playlists.single.id, 'pl.1');
      expect(ch.songsTitle, 'Top Songs');
      expect(ch.playlistsTitle, isNull);
      expect(c.canStream('1'), isTrue);
    });

    test('genres drops the root genre', () async {
      final AppleMusicCatalogClient c = AppleMusicCatalogClient(
        tokens: _tokens(),
        client: MockClient(
          (_) async => _json(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'id': '34',
                'type': 'genres',
                'attributes': <String, Object?>{'name': 'Music'},
              },
              <String, Object?>{
                'id': '27',
                'type': 'genres',
                'attributes': <String, Object?>{
                  'name': 'J-Pop',
                  'parentId': '34',
                },
              },
            ],
          }),
        ),
      );
      final List<AppleMusicGenre> g = await c.genres();
      expect(g.map((AppleMusicGenre x) => x.id), <String>['27']);
    });

    test('artist views hit view endpoints', () async {
      final List<String> paths = <String>[];
      final AppleMusicCatalogClient c = AppleMusicCatalogClient(
        tokens: _tokens(),
        client: MockClient((http.Request r) async {
          paths.add(r.url.path);
          if (r.url.path.endsWith('top-songs')) {
            return _json(<String, Object?>{
              'data': <Object?>[_song('1')],
            });
          }
          if (r.url.path.endsWith('similar-artists')) {
            return _json(<String, Object?>{
              'data': <Object?>[
                <String, Object?>{
                  'id': 'ar2',
                  'type': 'artists',
                  'attributes': <String, Object?>{'name': 'LiSA'},
                },
              ],
            });
          }
          return _json(<String, Object?>{
            'data': <Object?>[_playlist('pl.ess')],
          });
        }),
      );
      expect((await c.artistTopSongs('ar1')).single.id, '1');
      expect((await c.similarArtists('ar1')).single.name, 'LiSA');
      expect((await c.artistPlaylists('ar1')).single.id, 'pl.ess');
      expect(paths, <String>[
        '/v1/catalog/jp/artists/ar1/view/top-songs',
        '/v1/catalog/jp/artists/ar1/view/similar-artists',
        '/v1/catalog/jp/artists/ar1/view/featured-playlists',
      ]);
    });

    test('stationFor returns null on 404 and parses otherwise', () async {
      final AppleMusicCatalogClient c = AppleMusicCatalogClient(
        tokens: _tokens(),
        client: MockClient((http.Request r) async {
          if (r.url.path == '/v1/catalog/jp/songs/1/station') {
            return _json(<String, Object?>{
              'data': <Object?>[_station('ra.1')],
            });
          }
          return _json(<String, Object?>{}, 404);
        }),
      );
      expect((await c.stationFor(AppleMusicStationSeed.song, '1'))!.id, 'ra.1');
      expect(await c.stationFor(AppleMusicStationSeed.artist, '2'), isNull);
    });

    test('searchAll carries playlists and stations; suggestions', () async {
      final AppleMusicCatalogClient c = AppleMusicCatalogClient(
        tokens: _tokens(),
        client: MockClient((http.Request r) async {
          if (r.url.path.endsWith('/suggestions')) {
            return _json(<String, Object?>{
              'results': <String, Object?>{
                'suggestions': <Object?>[
                  <String, Object?>{'kind': 'terms', 'searchTerm': 'yoasobi'},
                  <String, Object?>{'kind': 'terms'},
                ],
              },
            });
          }
          return _json(<String, Object?>{
            'results': <String, Object?>{
              'playlists': <String, Object?>{
                'data': <Object?>[_playlist('pl.1')],
              },
              'stations': <String, Object?>{
                'data': <Object?>[_station('ra.1')],
              },
            },
          });
        }),
      );
      final AppleMusicSearchResult r = await c.searchAll('yoa');
      expect(r.result.playlists.single.id, 'pl.1');
      expect(r.stations.single.id, 'ra.1');
      expect(r.isEmpty, isFalse);
      expect(await c.searchSuggestions('yoa'), <String>['yoasobi']);
      expect(await c.searchSuggestions('  '), isEmpty);
    });

    test('adoptSongs registers library songs only in full-track mode', () {
      final AppleMusicCatalogClient preview = AppleMusicCatalogClient(
        tokens: _tokens(),
        client: MockClient((_) async => _json(<String, Object?>{})),
      );
      expect(preview.adoptSongs(<Object?>[_librarySong('i.1', '5')]), isEmpty);
      final AppleMusicCatalogClient full = AppleMusicCatalogClient(
        tokens: _tokens(),
        fullTracks: true,
        client: MockClient((_) async => _json(<String, Object?>{})),
      );
      final List<MusicServerTrack> t = full.adoptSongs(<Object?>[
        _librarySong('i.1', '5'),
        _song('7', preview: false),
      ]);
      expect(t.map((MusicServerTrack x) => x.id), <String>['5', '7']);
      expect(
        full.streamFor(t.first).uri.toString(),
        'fushi-apple-music://song/5',
      );
    });
  });

  group('AppleMusicLibraryClient playlists & writes', () {
    test(
      'listPlaylists / playlistTracks send user token, keep order',
      () async {
        final AppleMusicLibraryClient c = AppleMusicLibraryClient(
          credentials: _creds,
          client: MockClient((http.Request r) async {
            expect(r.headers['Music-User-Token'], 'usr');
            expect(r.headers['Authorization'], 'Bearer dev');
            if (r.url.path == '/v1/me/library/playlists') {
              return _json(<String, Object?>{
                'data': <Object?>[
                  _playlist('p.1', type: 'library-playlists', canEdit: true),
                ],
                'meta': <String, Object?>{'total': 1},
              });
            }
            expect(r.url.path, '/v1/me/library/playlists/p.1/tracks');
            return _json(<String, Object?>{
              'data': <Object?>[
                _librarySong('i.2', '22'),
                _librarySong('i.1', '11'),
                _librarySong('i.3', null),
              ],
            });
          }),
        );
        final MusicServerPage<MusicServerPlaylist> p = await c.listPlaylists();
        expect(p.items.single.editable, isTrue);
        expect(p.total, 1);
        expect(p.hasMore, isFalse);
        final List<MusicServerTrack> t = await c.playlistTracks('p.1');
        expect(t.map((MusicServerTrack x) => x.id), <String>['i.2', 'i.1']);
        expect(c.catalogIdOf('i.1'), '11');
        expect(
          c.streamFor(t.first).uri.toString(),
          'fushi-apple-music://song/22',
        );
      },
    );

    test(
      'createPlaylist and addToPlaylist post the documented bodies',
      () async {
        final List<http.Request> sent = <http.Request>[];
        final AppleMusicLibraryClient c = AppleMusicLibraryClient(
          credentials: _creds,
          client: MockClient((http.Request r) async {
            sent.add(r);
            if (r.url.path == '/v1/me/library/playlists') {
              return _json(<String, Object?>{
                'data': <Object?>[
                  _playlist('p.new', type: 'library-playlists', canEdit: true),
                ],
              }, 201);
            }
            return http.Response('', 204);
          }),
        );
        final MusicServerPlaylist p = await c.createPlaylist(
          ' 日本語 ',
          description: 'study',
          catalogSongIds: <String>['1'],
        );
        expect(p.id, 'p.new');
        await c.addToPlaylist('p.new', <String>['2', '3']);
        await c.addToPlaylist('p.new', const <String>[]);
        expect(sent.length, 2);
        expect(sent[0].method, 'POST');
        expect(jsonDecode(sent[0].body), <String, Object?>{
          'attributes': <String, Object?>{
            'name': '日本語',
            'description': 'study',
          },
          'relationships': <String, Object?>{
            'tracks': <String, Object?>{
              'data': <Object?>[
                <String, Object?>{'id': '1', 'type': 'songs'},
              ],
            },
          },
        });
        expect(sent[1].url.path, '/v1/me/library/playlists/p.new/tracks');
        expect(jsonDecode(sent[1].body), <String, Object?>{
          'data': <Object?>[
            <String, Object?>{'id': '2', 'type': 'songs'},
            <String, Object?>{'id': '3', 'type': 'songs'},
          ],
        });
        expect(() => c.createPlaylist('  '), throwsArgumentError);
      },
    );

    test('recentlyAdded pages until limit and parses mixed items', () async {
      int calls = 0;
      final AppleMusicLibraryClient c = AppleMusicLibraryClient(
        credentials: _creds,
        client: MockClient((http.Request r) async {
          calls++;
          expect(r.url.path, '/v1/me/library/recently-added');
          final int offset = int.parse(r.url.queryParameters['offset']!);
          return _json(<String, Object?>{
            'data': <Object?>[
              _album('l.$offset', type: 'library-albums'),
              _playlist('pl.$offset'),
            ],
            if (offset == 0) 'next': '/v1/me/library/recently-added?offset=2',
          });
        }),
      );
      final List<AppleMusicItem> items = await c.recentlyAdded(limit: 3);
      expect(calls, 2);
      expect(items.length, 3);
      expect(items.first.library, isTrue);
    });
  });

  group('AppleMusicPersonalClient', () {
    AppleMusicCatalogClient fullCatalog() => AppleMusicCatalogClient(
      tokens: _tokens(),
      fullTracks: true,
      client: MockClient((_) async => _json(<String, Object?>{})),
    );

    test('recommendations become shelves with playable songs', () async {
      final AppleMusicCatalogClient cat = fullCatalog();
      final AppleMusicPersonalClient c = AppleMusicPersonalClient(
        credentials: _creds,
        catalog: cat,
        client: MockClient((http.Request r) async {
          expect(r.url.path, '/v1/me/recommendations');
          return _json(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'id': 'r1',
                'type': 'personal-recommendation',
                'attributes': <String, Object?>{
                  'title': <String, Object?>{
                    'stringForDisplay': 'Made for You',
                  },
                },
                'relationships': <String, Object?>{
                  'contents': <String, Object?>{
                    'data': <Object?>[_playlist('pl.1'), _song('8')],
                  },
                },
              },
              // 没有内容的行丢掉。
              <String, Object?>{
                'id': 'r2',
                'type': 'personal-recommendation',
                'attributes': <String, Object?>{
                  'title': <String, Object?>{'stringForDisplay': 'Empty'},
                },
              },
            ],
          });
        }),
      );
      final List<AppleMusicShelf> s = await c.recommendations();
      expect(s.single.title, 'Made for You');
      expect(s.single.items.map((AppleMusicItem i) => i.key), <String>[
        'c-playlist-pl.1',
        'c-song-8',
      ]);
      expect(cat.canStream('8'), isTrue);
    });

    test('recentTracks adopts into catalog; recentlyPlayed pages', () async {
      final AppleMusicCatalogClient cat = fullCatalog();
      final AppleMusicPersonalClient c = AppleMusicPersonalClient(
        credentials: _creds,
        catalog: cat,
        client: MockClient((http.Request r) async {
          if (r.url.path == '/v1/me/recent/played/tracks') {
            expect(r.url.queryParameters['types'], 'songs,library-songs');
            return _json(<String, Object?>{
              'data': <Object?>[_song('1'), _librarySong('i.9', '99')],
            });
          }
          expect(r.url.path, '/v1/me/recent/played');
          expect(r.url.queryParameters['limit'], '10');
          return _json(<String, Object?>{
            'data': <Object?>[_album('a'), _station('ra.1')],
          });
        }),
      );
      final List<MusicServerTrack> t = await c.recentTracks();
      expect(t.map((MusicServerTrack x) => x.id), <String>['1', '99']);
      final List<AppleMusicItem> items = await c.recentlyPlayed();
      expect(items.length, 2);
    });

    test('ratings: put love, read back, clear tolerates 404', () async {
      final List<String> log = <String>[];
      final AppleMusicPersonalClient c = AppleMusicPersonalClient(
        credentials: _creds,
        catalog: fullCatalog(),
        client: MockClient((http.Request r) async {
          log.add('${r.method} ${r.url.path}');
          switch (r.method) {
            case 'PUT':
              expect(jsonDecode(r.body), <String, Object?>{
                'type': 'rating',
                'attributes': <String, Object?>{'value': 1},
              });
              return http.Response('', 204);
            case 'GET':
              if (r.url.path.endsWith('/2')) {
                return _json(<String, Object?>{}, 404);
              }
              return _json(<String, Object?>{
                'data': <Object?>[
                  <String, Object?>{
                    'type': 'ratings',
                    'attributes': <String, Object?>{'value': -1},
                  },
                ],
              });
            default:
              return http.Response('', 404);
          }
        }),
      );
      await c.setRating(
        AppleMusicResourceType.song,
        '1',
        AppleMusicRating.love,
      );
      expect(
        await c.rating(AppleMusicResourceType.song, '1'),
        AppleMusicRating.dislike,
      );
      expect(await c.rating(AppleMusicResourceType.album, '2'), isNull);
      await c.setRating(AppleMusicResourceType.playlist, 'pl.1', null);
      expect(log, <String>[
        'PUT /v1/me/ratings/songs/1',
        'GET /v1/me/ratings/songs/1',
        'GET /v1/me/ratings/albums/2',
        'DELETE /v1/me/ratings/playlists/pl.1',
      ]);
    });

    test('addToLibrary encodes ids per type and skips empty', () async {
      final List<Uri> sent = <Uri>[];
      final AppleMusicPersonalClient c = AppleMusicPersonalClient(
        credentials: _creds,
        catalog: fullCatalog(),
        client: MockClient((http.Request r) async {
          sent.add(r.url);
          expect(r.method, 'POST');
          return http.Response('', 202);
        }),
      );
      await c.addToLibrary(<AppleMusicResourceType, List<String>>{
        AppleMusicResourceType.song: <String>['1', '2'],
        AppleMusicResourceType.album: const <String>[],
      });
      await c.addToLibrary(const <AppleMusicResourceType, List<String>>{});
      expect(sent.single.path, '/v1/me/library');
      expect(sent.single.queryParameters, <String, String>{
        'ids[songs]': '1,2',
      });
    });

    test('personalStation uses the storefront catalog path', () async {
      final AppleMusicPersonalClient c = AppleMusicPersonalClient(
        credentials: _creds,
        catalog: fullCatalog(),
        client: MockClient((http.Request r) async {
          expect(r.url.path, '/v1/catalog/jp/stations');
          expect(r.url.queryParameters['filter[identity]'], 'personal');
          expect(r.headers['Music-User-Token'], 'usr');
          return _json(<String, Object?>{
            'data': <Object?>[_station('ra.me')],
          });
        }),
      );
      expect((await c.personalStation())!.id, 'ra.me');
    });
  });
}
