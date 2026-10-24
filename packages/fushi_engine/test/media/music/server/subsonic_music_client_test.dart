import 'dart:convert';

import 'package:crypto/crypto.dart';
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
    'type': 'navidrome',
    'openSubsonic': true,
    ...body,
  },
};

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

SubsonicServerConfig _pwConfig() => SubsonicServerConfig(
  id: 'nd',
  name: 'Navidrome',
  serverUrl: Uri.parse('https://music.example.com/navi/'),
  username: 'alice',
  password: 'sesame',
);

class _Rig {
  _Rig(this.handler, {SubsonicServerConfig? config}) {
    client = SubsonicMusicClient(
      config ?? _pwConfig(),
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

void main() {
  group('认证', () {
    test('token 模式：t = md5(password + salt)，带 v/c/f，不发 p=', () async {
      final _Rig rig = _Rig((_) async => _json(_ok(<String, Object?>{})));
      await rig.client.ping();
      final Uri u = rig.requests.single;
      expect(u.path, '/navi/rest/ping');
      final Map<String, String> q = u.queryParameters;
      expect(q['v'], '1.16.1');
      expect(q['c'], 'fushi');
      expect(q['f'], 'json');
      expect(q['u'], 'alice');
      expect(q['s'], 'abcdef');
      expect(q['t'], md5.convert(utf8.encode('sesameabcdef')).toString());
      expect(q.containsKey('p'), isFalse);
      expect(q.containsKey('apiKey'), isFalse);
    });

    test('apiKey 模式只带 apiKey，不带 u/t/s', () async {
      final _Rig rig = _Rig(
        (_) async => _json(_ok(<String, Object?>{})),
        config: SubsonicServerConfig(
          id: 'k',
          name: 'K',
          serverUrl: Uri.parse('https://music.example.com'),
          apiKey: 'KEY123',
        ),
      );
      await rig.client.ping();
      final Map<String, String> q = rig.requests.single.queryParameters;
      expect(q['apiKey'], 'KEY123');
      expect(q['v'], '1.16.1');
      expect(q['c'], 'fushi');
      expect(q['f'], 'json');
      for (final String k in <String>['u', 't', 's', 'p']) {
        expect(q.containsKey(k), isFalse, reason: k);
      }
    });

    test('默认盐每个请求不同', () async {
      final List<String> salts = <String>[];
      final SubsonicMusicClient c = SubsonicMusicClient(
        _pwConfig(),
        client: MockClient((http.Request r) async {
          salts.add(r.url.queryParameters['s']!);
          return _json(_ok(<String, Object?>{}));
        }),
      );
      await c.ping();
      await c.ping();
      expect(salts[0], isNot(salts[1]));
      expect(salts[0], hasLength(12));
    });
  });

  group('错误', () {
    test('failed + code 40 抛 SubsonicApiException，文本不含凭据', () async {
      final _Rig rig = _Rig(
        (_) async => _json(<String, Object?>{
          'subsonic-response': <String, Object?>{
            'status': 'failed',
            'version': '1.16.1',
            'error': <String, Object?>{
              'code': 40,
              'message': 'Wrong username or password',
            },
          },
        }),
      );
      try {
        await rig.client.ping();
        fail('should throw');
      } on SubsonicApiException catch (e) {
        expect(e.code, 40);
        final String text = e.toString();
        expect(text, contains('40'));
        expect(text, isNot(contains('sesame')));
        expect(
          text,
          isNot(contains(md5.convert(utf8.encode('sesameabcdef')).toString())),
        );
      }
    });

    test('错误消息里带的凭据 query 会被脱敏', () {
      const SubsonicApiException e = SubsonicApiException(
        code: 0,
        message: 'bad https://h/rest/ping?u=a&apiKey=SECRETKEY&t=TOK',
      );
      expect(e.toString(), isNot(contains('SECRETKEY')));
      expect(e.toString(), isNot(contains('TOK')));
    });

    test('HTTP 非 2xx 抛带状态码的异常；非 JSON 抛 FormatException', () async {
      final _Rig bad = _Rig((_) async => http.Response('x', 503));
      await expectLater(
        bad.client.ping(),
        throwsA(
          isA<SubsonicApiException>().having(
            (SubsonicApiException e) => e.httpStatus,
            'httpStatus',
            503,
          ),
        ),
      );
      final _Rig html = _Rig((_) async => http.Response('<html>', 200));
      await expectLater(html.client.ping(), throwsFormatException);
    });

    test('网络异常里的凭据被脱敏', () async {
      final _Rig rig = _Rig((http.Request r) async {
        throw http.ClientException('boom', r.url);
      });
      try {
        await rig.client.ping();
        fail('should throw');
      } on http.ClientException catch (e) {
        expect(e.message, isNot(contains('sesame')));
      }
    });

    test('openSubsonicExtensions：支持时返回名字集合，不支持（错误 / 404）返回空集', () async {
      final _Rig ok = _Rig(
        (_) async => _json(
          _ok(<String, Object?>{
            'openSubsonicExtensions': <Object?>[
              <String, Object?>{
                'name': 'apiKeyAuthentication',
                'versions': <int>[1],
              },
              <String, Object?>{
                'name': 'transcodeOffset',
                'versions': <int>[1],
              },
            ],
          }),
        ),
      );
      expect(await ok.client.openSubsonicExtensions(), <String>{
        'apiKeyAuthentication',
        'transcodeOffset',
      });
      final _Rig notFound = _Rig((_) async => http.Response('nope', 404));
      expect(await notFound.client.openSubsonicExtensions(), isEmpty);
      final _Rig failed = _Rig(
        (_) async => _json(<String, Object?>{
          'subsonic-response': <String, Object?>{
            'status': 'failed',
            'error': <String, Object?>{'code': 30, 'message': 'unsupported'},
          },
        }),
      );
      expect(await failed.client.openSubsonicExtensions(), isEmpty);
    });
  });

  group('专辑列表', () {
    Map<String, Object?> albumJson(int i) => <String, Object?>{
      'id': 'al-$i',
      'name': 'Album $i',
      'artist': 'Artist',
      'artistId': 'ar-1',
      'year': 2000 + i,
      'songCount': 10,
      'duration': 2400,
      'coverArt': 'al-$i',
    };

    test('满页给 nextOffset，不满页给 null；字段映射', () async {
      final _Rig rig = _Rig((http.Request r) async {
        final int size = int.parse(r.url.queryParameters['size']!);
        return _json(
          _ok(<String, Object?>{
            'albumList2': <String, Object?>{
              'album': <Object?>[for (int i = 0; i < size; i++) albumJson(i)],
            },
          }),
        );
      });
      final MusicServerPage<MusicServerAlbum> full = await rig.client
          .listAlbums(offset: 10, limit: 3);
      expect(full.items, hasLength(3));
      expect(full.nextOffset, 13);
      expect(full.hasMore, isTrue);
      final MusicServerAlbum a = full.items.first;
      expect(a.id, 'al-0');
      expect(a.title, 'Album 0');
      expect(a.artist, 'Artist');
      expect(a.artistId, 'ar-1');
      expect(a.year, 2000);
      expect(a.trackCount, 10);
      expect(a.durationMs, 2400000);
      expect(a.coverRef, 'al-0');
      expect(rig.requests.last.queryParameters['offset'], '10');
      expect(rig.requests.last.queryParameters['size'], '3');

      final _Rig short = _Rig(
        (_) async => _json(
          _ok(<String, Object?>{
            'albumList2': <String, Object?>{
              'album': <Object?>[albumJson(1)],
            },
          }),
        ),
      );
      final MusicServerPage<MusicServerAlbum> last = await short.client
          .listAlbums(limit: 5);
      expect(last.nextOffset, isNull);
      expect(last.hasMore, isFalse);

      final _Rig empty = _Rig(
        (_) async =>
            _json(_ok(<String, Object?>{'albumList2': <String, Object?>{}})),
      );
      expect((await empty.client.listAlbums()).items, isEmpty);
    });

    test('排序参数映射；byYear 带 fromYear/toYear；size 上限 500', () async {
      final _Rig rig = _Rig(
        (_) async =>
            _json(_ok(<String, Object?>{'albumList2': <String, Object?>{}})),
      );
      final Map<MusicServerAlbumSort, String> expected =
          <MusicServerAlbumSort, String>{
            MusicServerAlbumSort.name: 'alphabeticalByName',
            MusicServerAlbumSort.newest: 'newest',
            MusicServerAlbumSort.artist: 'alphabeticalByArtist',
            MusicServerAlbumSort.year: 'byYear',
          };
      for (final MapEntry<MusicServerAlbumSort, String> e in expected.entries) {
        await rig.client.listAlbums(sort: e.key);
        final Map<String, String> q = rig.requests.last.queryParameters;
        expect(q['type'], e.value);
        if (e.key == MusicServerAlbumSort.year) {
          expect(q['fromYear'], '0');
          expect(q['toYear'], '9999');
        } else {
          expect(q.containsKey('fromYear'), isFalse);
        }
      }
      await rig.client.listAlbums(limit: 9999);
      expect(rig.requests.last.queryParameters['size'], '500');
    });
  });

  group('曲目', () {
    test('字段映射、按碟号 / 轨号排序、codec 与无损判定', () async {
      final _Rig rig = _Rig(
        (_) async => _json(
          _ok(<String, Object?>{
            'album': <String, Object?>{
              'id': 'al-1',
              'name': 'A',
              'song': <Object?>[
                <String, Object?>{
                  'id': 's3',
                  'title': 'D2T1',
                  'discNumber': 2,
                  'track': 1,
                  'suffix': 'mp3',
                  'contentType': 'audio/mpeg',
                  'bitRate': 320,
                },
                <String, Object?>{
                  'id': 's2',
                  'title': 'D1T2',
                  'discNumber': 1,
                  'track': 2,
                  'suffix': 'flac',
                  'contentType': 'audio/flac',
                  'bitRate': 905,
                  'samplingRate': 96000,
                  'bitDepth': 24,
                  'channelCount': 2,
                  'size': 31457280,
                  'duration': 215,
                  'artist': 'Artist',
                  'album': 'A',
                  'albumId': 'al-1',
                  'coverArt': 'mf-2',
                },
                <String, Object?>{
                  'id': 's1',
                  'title': 'D1T1',
                  'discNumber': 1,
                  'track': 1,
                  'suffix': 'm4a',
                  'codec': 'ALAC',
                },
              ],
            },
          }),
        ),
      );
      final List<MusicServerTrack> tracks = await rig.client.albumTracks(
        'al-1',
      );
      expect(rig.requests.single.path, '/navi/rest/getAlbum');
      expect(rig.requests.single.queryParameters['id'], 'al-1');
      expect(tracks.map((MusicServerTrack t) => t.id), <String>[
        's1',
        's2',
        's3',
      ]);

      final MusicServerTrack flac = tracks[1];
      expect(flac.durationMs, 215000);
      expect(flac.container, 'flac');
      expect(flac.codec, 'flac');
      expect(flac.bitrateKbps, 905);
      expect(flac.sampleRate, 96000);
      expect(flac.bitDepth, 24);
      expect(flac.channels, 2);
      expect(flac.sizeBytes, 31457280);
      expect(flac.artist, 'Artist');
      expect(flac.albumId, 'al-1');
      expect(flac.discNo, 1);
      expect(flac.trackNo, 2);
      expect(flac.coverRef, 'mf-2');
      expect(flac.isLossless, isTrue);

      expect(tracks[0].codec, 'alac'); // OpenSubsonic codec 字段优先，转小写
      expect(tracks[0].isLossless, isTrue);
      expect(tracks[2].codec, 'mp3');
      expect(tracks[2].isLossless, isFalse);
    });

    test('只有 contentType 时从它推 codec', () async {
      final _Rig rig = _Rig(
        (_) async => _json(
          _ok(<String, Object?>{
            'album': <String, Object?>{
              'song': <Object?>[
                <String, Object?>{
                  'id': 'a',
                  'title': 'a',
                  'contentType': 'audio/mpeg',
                },
                <String, Object?>{
                  'id': 'b',
                  'title': 'b',
                  'contentType': 'audio/x-flac',
                },
              ],
            },
          }),
        ),
      );
      final List<MusicServerTrack> t = await rig.client.albumTracks('x');
      expect(t[0].codec, 'mp3');
      expect(t[1].codec, 'flac');
      expect(t[1].isLossless, isTrue);
    });
  });

  group('艺人 / 搜索', () {
    test('listArtists 摊平 index', () async {
      final _Rig rig = _Rig(
        (_) async => _json(
          _ok(<String, Object?>{
            'artists': <String, Object?>{
              'index': <Object?>[
                <String, Object?>{
                  'name': 'A',
                  'artist': <Object?>[
                    <String, Object?>{
                      'id': 'ar1',
                      'name': 'Aimer',
                      'albumCount': 5,
                      'coverArt': 'ar-ar1',
                    },
                  ],
                },
                <String, Object?>{
                  'name': 'B',
                  'artist': <Object?>[
                    <String, Object?>{'id': 'ar2', 'name': 'Bump'},
                    <String, Object?>{'id': 'ar3', 'name': 'Bee'},
                  ],
                },
              ],
            },
          }),
        ),
      );
      final List<MusicServerArtist> artists = await rig.client.listArtists();
      expect(artists.map((MusicServerArtist a) => a.id), <String>[
        'ar1',
        'ar2',
        'ar3',
      ]);
      expect(artists.first.name, 'Aimer');
      expect(artists.first.albumCount, 5);
      expect(artists.first.coverRef, 'ar-ar1');
      expect(artists[1].albumCount, isNull);
    });

    test('artistAlbums 读 artist.album[]', () async {
      final _Rig rig = _Rig(
        (_) async => _json(
          _ok(<String, Object?>{
            'artist': <String, Object?>{
              'id': 'ar1',
              'album': <Object?>[
                <String, Object?>{'id': 'x', 'name': 'X', 'year': 2020},
              ],
            },
          }),
        ),
      );
      final List<MusicServerAlbum> albums = await rig.client.artistAlbums(
        'ar1',
      );
      expect(rig.requests.single.path, '/navi/rest/getArtist');
      expect(albums.single.title, 'X');
      expect(albums.single.year, 2020);
    });

    test('search3 三类都映射，count 都等于 limit', () async {
      final _Rig rig = _Rig(
        (_) async => _json(
          _ok(<String, Object?>{
            'searchResult3': <String, Object?>{
              'artist': <Object?>[
                <String, Object?>{'id': 'ar1', 'name': 'Aimer'},
              ],
              'album': <Object?>[
                <String, Object?>{'id': 'al1', 'name': 'Sun Dance'},
              ],
              'song': <Object?>[
                <String, Object?>{'id': 's1', 'title': 'Brave Shine'},
                <String, Object?>{'id': 's2', 'title': 'Ref:rain'},
              ],
            },
          }),
        ),
      );
      final MusicServerSearchResult r = await rig.client.search(
        'aimer',
        limit: 7,
      );
      expect(r.artists.single.name, 'Aimer');
      expect(r.albums.single.title, 'Sun Dance');
      expect(r.tracks, hasLength(2));
      expect(r.isEmpty, isFalse);
      final Map<String, String> q = rig.requests.single.queryParameters;
      expect(q['query'], 'aimer');
      expect(q['artistCount'], '7');
      expect(q['albumCount'], '7');
      expect(q['songCount'], '7');
    });

    test('空白 search 不发请求', () async {
      final _Rig rig = _Rig((_) async => _json(_ok(<String, Object?>{})));
      final MusicServerSearchResult r = await rig.client.search('   ');
      expect(r.isEmpty, isTrue);
      expect(rig.requests, isEmpty);
    });
  });

  group('流与封面', () {
    const MusicServerTrack track = MusicServerTrack(
      id: 's1',
      title: 't',
      codec: 'flac',
      container: 'flac',
      bitrateKbps: 900,
    );

    test('直出：format=raw，不转码，codec/bitrate 取源', () {
      final _Rig rig = _Rig((_) async => _json(_ok(<String, Object?>{})));
      final MusicServerStream s = rig.client.streamFor(track);
      expect(s.transcoded, isFalse);
      expect(s.codec, 'flac');
      expect(s.bitrateKbps, 900);
      expect(s.uri.path, '/navi/rest/stream');
      final Map<String, String> q = s.uri.queryParameters;
      expect(q['id'], 's1');
      expect(q['format'], 'raw');
      expect(q.containsKey('maxBitRate'), isFalse);
      expect(q['t'], md5.convert(utf8.encode('sesameabcdef')).toString());
      expect(q['u'], 'alice');
    });

    test('转码：format=opus & maxBitRate', () {
      final _Rig rig = _Rig((_) async => _json(_ok(<String, Object?>{})));
      final MusicServerStream s = rig.client.streamFor(
        track,
        maxBitrateKbps: 128,
      );
      expect(s.transcoded, isTrue);
      expect(s.codec, 'opus');
      expect(s.bitrateKbps, 128);
      final Map<String, String> q = s.uri.queryParameters;
      expect(q['format'], 'opus');
      expect(q['maxBitRate'], '128');
    });

    test('coverUri：带 id / size / 认证；null ref 返回 null', () {
      final _Rig rig = _Rig((_) async => _json(_ok(<String, Object?>{})));
      expect(rig.client.coverUri(null), isNull);
      expect(rig.client.coverUri(''), isNull);
      final Uri u = rig.client.coverUri('al-1', size: 256)!;
      expect(u.path, '/navi/rest/getCoverArt');
      expect(u.queryParameters['id'], 'al-1');
      expect(u.queryParameters['size'], '256');
      expect(u.queryParameters['u'], 'alice');
      expect(
        rig.client.coverUri('al-1')!.queryParameters['size'],
        '$kMusicServerCoverSize',
      );
    });

    test('身份：kind / serverId / displayName', () {
      final _Rig rig = _Rig((_) async => _json(_ok(<String, Object?>{})));
      expect(rig.client.kind, MusicServerKind.subsonic);
      expect(rig.client.serverId, 'subsonic-nd');
      expect(rig.client.displayName, 'Navidrome');
    });
  });

  group('SubsonicServerConfig', () {
    test('toJson/fromJson 往返；凭据是 base64 不是明文', () {
      final SubsonicServerConfig c = SubsonicServerConfig(
        id: 'a',
        name: 'N',
        serverUrl: Uri.parse('https://m.example.com/sub/'),
        username: 'bob',
        password: 'pw-secret',
        apiKey: 'key-secret',
        enabled: false,
      );
      expect(c.serverUrl.toString(), 'https://m.example.com/sub');
      final Map<String, Object?> j = c.toJson();
      final String raw = jsonEncode(j);
      expect(raw, isNot(contains('pw-secret')));
      expect(raw, isNot(contains('key-secret')));
      expect(
        utf8.decode(base64Decode(j['passwordB64']! as String)),
        'pw-secret',
      );
      expect(
        utf8.decode(base64Decode(j['apiKeyB64']! as String)),
        'key-secret',
      );

      final SubsonicServerConfig back = SubsonicServerConfig.fromJson(
        jsonDecode(raw) as Map<String, Object?>,
      );
      expect(back.id, 'a');
      expect(back.name, 'N');
      expect(back.serverUrl, c.serverUrl);
      expect(back.username, 'bob');
      expect(back.password, 'pw-secret');
      expect(back.apiKey, 'key-secret');
      expect(back.enabled, isFalse);
      expect(back.serverId, 'subsonic-a');
    });

    test('displayName 空名回落 host', () {
      final SubsonicServerConfig c = SubsonicServerConfig(
        id: 'a',
        name: ' ',
        serverUrl: Uri.parse('https://m.example.com'),
        apiKey: 'k',
      );
      expect(c.displayName, 'm.example.com');
    });

    test('明文 http 非 loopback 且未放行时构造抛；放行或 loopback 可过', () {
      expect(
        () => SubsonicServerConfig(
          id: 'a',
          name: 'n',
          serverUrl: Uri.parse('http://music.example.com'),
          apiKey: 'k',
        ),
        throwsArgumentError,
      );
      expect(
        SubsonicServerConfig(
          id: 'a',
          name: 'n',
          serverUrl: Uri.parse('http://192.168.1.5:4533'),
          apiKey: 'k',
          allowInsecureHttp: true,
        ).allowInsecureHttp,
        isTrue,
      );
      expect(
        SubsonicServerConfig(
          id: 'a',
          name: 'n',
          serverUrl: Uri.parse('http://127.0.0.1:4533'),
          apiKey: 'k',
        ).serverUrl.host,
        '127.0.0.1',
      );
    });

    test('缺凭据 / 空 id / 带 userInfo / 非 http 协议都抛', () {
      expect(
        () => SubsonicServerConfig(
          id: 'a',
          name: 'n',
          serverUrl: Uri.parse('https://m.example.com'),
        ),
        throwsArgumentError,
      );
      expect(
        () => SubsonicServerConfig(
          id: ' ',
          name: 'n',
          serverUrl: Uri.parse('https://m.example.com'),
          apiKey: 'k',
        ),
        throwsArgumentError,
      );
      expect(
        () => SubsonicServerConfig(
          id: 'a',
          name: 'n',
          serverUrl: Uri.parse('https://u:p@m.example.com'),
          apiKey: 'k',
        ),
        throwsArgumentError,
      );
      expect(
        () => SubsonicServerConfig(
          id: 'a',
          name: 'n',
          serverUrl: Uri.parse('ftp://m.example.com'),
          apiKey: 'k',
        ),
        throwsArgumentError,
      );
    });

    test('decodeSubsonicServerConfigs 丢弃坏条目与重复 id', () {
      final String raw = jsonEncode(<Object?>[
        <String, Object?>{
          'id': 'ok',
          'name': 'OK',
          'url': 'https://m.example.com',
          'apiKeyB64': base64Encode(utf8.encode('k')),
        },
        <String, Object?>{'id': 'nourl'},
        <String, Object?>{'id': 'nocred', 'url': 'https://m.example.com'},
        <String, Object?>{
          'id': 'plain',
          'url': 'http://music.example.com',
          'apiKeyB64': base64Encode(utf8.encode('k')),
        },
        <String, Object?>{
          'id': 'ok',
          'name': 'dup',
          'url': 'https://other.example.com',
          'apiKeyB64': base64Encode(utf8.encode('k')),
        },
        'garbage',
      ]);
      final List<SubsonicServerConfig> list = decodeSubsonicServerConfigs(raw);
      expect(list, hasLength(1));
      expect(list.single.name, 'OK');
      expect(decodeSubsonicServerConfigs(null), isEmpty);
      expect(decodeSubsonicServerConfigs('not json'), isEmpty);
      expect(decodeSubsonicServerConfigs('{}'), isEmpty);

      final String again = encodeSubsonicServerConfigs(list);
      expect(decodeSubsonicServerConfigs(again).single.id, 'ok');
    });
  });
}
