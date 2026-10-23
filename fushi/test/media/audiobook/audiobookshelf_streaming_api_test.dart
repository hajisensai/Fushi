// Audiobookshelf 流式 / 播客 / 进度同步相关的协议层契约：/status、Set-Cookie 兜底
// 取 refresh token、条目详情（书的音轨偏移、播客单集、服务器上的字幕文件）、开播放
// 会话与同步、Range 读取遇 401 刷新重试、小文件体积上限、JWT 过期时间解码。
//
// 响应形状取自 audiobooks.dev（ABS v2.37.1）的实测输出。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/external_provider.dart';

final Uri _server = Uri.parse('https://abs.example.com');

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

String _jwt({int? exp}) {
  String part(Map<String, Object?> map) =>
      base64Url.encode(utf8.encode(jsonEncode(map))).replaceAll('=', '');
  return '${part(<String, Object?>{'alg': 'HS256'})}.'
      '${part(<String, Object?>{'userId': 'u', if (exp != null) 'exp': exp})}.sig';
}

AudiobookshelfApi _api(
  MockClientHandler handler, {
  AudiobookshelfTokens? tokens = const AudiobookshelfTokens(
    accessToken: 'access-1',
    refreshToken: 'refresh-1',
  ),
  AudiobookshelfTokensChanged? onTokensChanged,
}) => AudiobookshelfApi(
  serverUrl: _server,
  providerId: 'abs-test',
  tokens: tokens,
  onTokensChanged: onTokensChanged,
  client: MockClient(handler),
);

Map<String, Object?> _bookItem() => <String, Object?>{
  'id': 'item_1',
  'libraryId': 'lib_1',
  'mediaType': 'book',
  'relPath': 'Aesop',
  'isFile': false,
  'media': <String, Object?>{
    'metadata': <String, Object?>{'title': 'Fables'},
    'duration': 1000.0,
    'chapters': <Object?>[
      <String, Object?>{'id': 0, 'start': 0, 'end': 42.5, 'title': 'Intro'},
    ],
    'tracks': <Object?>[
      <String, Object?>{
        'index': 1,
        'ino': '10',
        'duration': 600.5,
        'startOffset': 0,
        'mimeType': 'audio/mpeg',
        'metadata': <String, Object?>{'filename': 'a.mp3', 'size': 5000},
      },
      <String, Object?>{
        'index': 2,
        'ino': '11',
        'duration': 399.5,
        'startOffset': 600.5,
        'mimeType': 'audio/mpeg',
        'metadata': <String, Object?>{'filename': 'b.mp3', 'size': 4000},
      },
    ],
  },
  'libraryFiles': <Object?>[
    <String, Object?>{
      'ino': '10',
      'fileType': 'audio',
      'metadata': <String, Object?>{'filename': 'a.mp3', 'size': 5000},
    },
    <String, Object?>{
      'ino': '20',
      'fileType': 'unknown',
      'metadata': <String, Object?>{
        'filename': 'Fables.SRT',
        'relPath': 'Fables.SRT',
        'size': 321,
      },
    },
  ],
  'userMediaProgress': <String, Object?>{
    'currentTime': 80,
    'duration': 1000,
    'isFinished': false,
  },
};

void main() {
  group('status', () {
    test('免鉴权，解析版本与登录方式', () async {
      late http.Request seen;
      final AudiobookshelfApi api = _api((http.Request request) async {
        seen = request;
        return _json(<String, Object?>{
          'app': 'audiobookshelf',
          'serverVersion': '2.37.1',
          'isInit': true,
          'authMethods': <String>['local'],
        });
      }, tokens: null);
      final AudiobookshelfServerStatus status = await api.status();
      expect(seen.url.path, '/status');
      expect(seen.headers.containsKey('Authorization'), isFalse);
      expect(status.serverVersion, '2.37.1');
      expect(status.supportsPasswordLogin, isTrue);
    });

    test('不是 ABS 的响应 → invalidResponse', () async {
      final AudiobookshelfApi api = _api(
        (http.Request request) async =>
            _json(<String, Object?>{'app': 'something-else'}),
        tokens: null,
      );
      await expectLater(
        api.status(),
        throwsA(
          isA<ExternalProviderFailure>().having(
            (ExternalProviderFailure f) => f.kind,
            'kind',
            ExternalProviderFailureKind.invalidResponse,
          ),
        ),
      );
    });

    test('只有 openid 时不支持账号密码', () {
      final AudiobookshelfServerStatus? status =
          AudiobookshelfServerStatus.parse(<String, Object?>{
            'app': 'audiobookshelf',
            'authMethods': <String>['openid'],
          });
      expect(status!.supportsPasswordLogin, isFalse);
    });
  });

  group('登录 Set-Cookie 兜底', () {
    test('响应体 refreshToken 为 null 时取 cookie', () async {
      final AudiobookshelfApi api = _api(
        (http.Request request) async => http.Response(
          jsonEncode(<String, Object?>{
            'user': <String, Object?>{
              'id': 'u',
              'username': 'demo',
              'accessToken': 'access-new',
              'refreshToken': null,
            },
          }),
          200,
          headers: <String, String>{
            'content-type': 'application/json',
            'set-cookie':
                'connect.sid=abc; Path=/, refresh_token=r.t.k; Max-Age=2592000; HttpOnly',
          },
        ),
        tokens: null,
      );
      final AudiobookshelfSession session = await api.login('demo', 'demo');
      expect(session.tokens.refreshToken, 'r.t.k');
      expect(api.tokens?.refreshToken, 'r.t.k');
    });

    test('refreshTokenFromSetCookie：没有就是 null，前缀相近的 cookie 不误中', () {
      expect(AudiobookshelfApi.refreshTokenFromSetCookie(null), isNull);
      expect(
        AudiobookshelfApi.refreshTokenFromSetCookie('a=b; Path=/'),
        isNull,
      );
      expect(
        AudiobookshelfApi.refreshTokenFromSetCookie('x_refresh_token=nope'),
        isNull,
      );
      expect(
        AudiobookshelfApi.refreshTokenFromSetCookie(
          'refresh_token=abc; Path=/',
        ),
        'abc',
      );
    });
  });

  group('条目详情', () {
    test('书：音轨偏移累计、字幕文件按扩展名识别、章节与进度', () async {
      late http.Request seen;
      final AudiobookshelfApi api = _api((http.Request request) async {
        seen = request;
        return _json(_bookItem());
      });
      final AudiobookshelfItemDetail detail = await api.itemDetail('item_1');
      expect(seen.url.queryParameters['expanded'], '1');
      expect(detail.tracks, hasLength(2));
      expect(detail.tracks[1].startOffsetMs, 600500);
      expect(detail.tracks[1].endOffsetMs, 1000000);
      expect(detail.tracks[0].contentPath, '/api/items/item_1/file/10');
      expect(detail.tracks[0].sizeBytes, 5000);
      expect(
        detail.subtitleFiles.map((AudiobookshelfLibraryFile f) => f.ino),
        <String>['20'],
      );
      expect(detail.chapters.single.title, 'Intro');
      expect(detail.progress?.currentTimeSeconds, 80);
      expect(detail.isPodcast, isFalse);
    });

    test('只有 audioFiles（无 tracks）时自己累计偏移', () {
      final AudiobookshelfItemDetail? detail = AudiobookshelfItemDetail.parse(
        <String, Object?>{
          'id': 'i',
          'media': <String, Object?>{
            'audioFiles': <Object?>[
              <String, Object?>{'ino': '1', 'duration': 10},
              <String, Object?>{'ino': '2', 'duration': 5},
            ],
          },
        },
      );
      expect(
        detail!.tracks.map((AudiobookshelfTrack t) => t.startOffsetMs),
        <int>[0, 10000],
      );
    });

    test('播客：单集音轨起点恒为 0，非展开形状请求不带 expanded', () async {
      late http.Request seen;
      final AudiobookshelfApi api = _api((http.Request request) async {
        seen = request;
        return _json(<String, Object?>{
          'id': 'pod_1',
          'mediaType': 'podcast',
          'media': <String, Object?>{
            'metadata': <String, Object?>{'title': 'Show'},
            'episodes': <Object?>[
              <String, Object?>{
                'id': 'ep_1',
                'index': 1,
                'title': 'Ep One',
                'publishedAt': 1344590120000,
                'audioFile': <String, Object?>{
                  'ino': '77',
                  'duration': 1200.25,
                  'mimeType': 'audio/mpeg',
                  'metadata': <String, Object?>{'filename': 'e1.mp3'},
                },
                'audioTrack': <String, Object?>{'startOffset': 999},
              },
              <String, Object?>{'id': 'broken'},
            ],
          },
        });
      });
      final AudiobookshelfItemDetail detail = await api.itemDetail(
        'pod_1',
        expanded: false,
      );
      expect(seen.url.queryParameters.containsKey('expanded'), isFalse);
      expect(detail.isPodcast, isTrue);
      expect(detail.tracks, isEmpty);
      expect(detail.episodes, hasLength(1));
      final AudiobookshelfEpisode episode = detail.episodes.single;
      expect(episode.title, 'Ep One');
      expect(episode.track.startOffsetMs, 0);
      expect(episode.track.durationMs, 1200250);
      expect(episode.track.contentPath, '/api/items/pod_1/file/77');
    });

    test('搜索：podcast 库的 {podcast: [...]} 形状也解析', () {
      final List<AudiobookshelfItem> hits = parseAudiobookshelfSearch(
        <String, Object?>{
          'podcast': <Object?>[
            <String, Object?>{
              'libraryItem': <String, Object?>{
                'id': 'pod_1',
                'mediaType': 'podcast',
                'media': <String, Object?>{
                  'metadata': <String, Object?>{'title': 'Show'},
                },
              },
            },
          ],
        },
      );
      expect(hits.single.id, 'pod_1');
    });
  });

  group('播放会话与进度', () {
    test('startPlay：direct play 请求体，续播位置与音轨', () async {
      late http.Request seen;
      final AudiobookshelfApi api = _api((http.Request request) async {
        seen = request;
        return _json(<String, Object?>{
          'id': 'sess_1',
          'libraryItemId': 'item_1',
          'episodeId': null,
          'duration': 1000,
          'currentTime': 80.5,
          'audioTracks': <Object?>[
            <String, Object?>{
              'index': 1,
              'ino': '10',
              'duration': 600.5,
              'startOffset': 0,
            },
            <String, Object?>{
              'index': 2,
              'ino': '11',
              'duration': 399.5,
              'startOffset': 600.5,
            },
          ],
        });
      });
      final AudiobookshelfPlaySession session = await api.startPlay(
        'item_1',
        deviceId: 'dev-1',
      );
      expect(seen.method, 'POST');
      expect(seen.url.path, '/api/items/item_1/play');
      expect(seen.headers['Authorization'], 'Bearer access-1');
      final Map<String, Object?> body =
          jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['forceDirectPlay'], isTrue);
      expect((body['deviceInfo'] as Map)['deviceId'], 'dev-1');
      expect(session.id, 'sess_1');
      expect(session.currentTimeSeconds, 80.5);
      expect(session.tracks[1].startOffsetMs, 600500);
    });

    test('startPlay：播客单集走 /play/:episodeId', () async {
      late Uri seen;
      final AudiobookshelfApi api = _api((http.Request request) async {
        seen = request.url;
        return _json(<String, Object?>{
          'id': 's',
          'libraryItemId': 'pod_1',
          'episodeId': 'ep_1',
          'audioTracks': <Object?>[
            <String, Object?>{'ino': '77', 'duration': 5, 'startOffset': 0},
          ],
        });
      });
      final AudiobookshelfPlaySession session = await api.startPlay(
        'pod_1',
        deviceId: 'd',
        episodeId: 'ep_1',
      );
      expect(seen.path, '/api/items/pod_1/play/ep_1');
      expect(session.episodeId, 'ep_1');
    });

    test('没有音轨的会话视为畸形响应', () async {
      final AudiobookshelfApi api = _api(
        (http.Request request) async => _json(<String, Object?>{
          'id': 's',
          'libraryItemId': 'i',
          'audioTracks': <Object?>[],
        }),
      );
      await expectLater(
        api.startPlay('i', deviceId: 'd'),
        throwsA(isA<ExternalProviderFailure>()),
      );
    });

    test('syncSession / closeSession：路径与请求体；文本 OK 响应不解析', () async {
      final List<http.Request> seen = <http.Request>[];
      final AudiobookshelfApi api = _api((http.Request request) async {
        seen.add(request);
        return http.Response('OK', 200);
      });
      await api.syncSession(
        'sess_1',
        currentTimeSeconds: 75.5,
        timeListenedSeconds: 10,
        durationSeconds: 1000,
      );
      await api.closeSession(
        'sess_1',
        currentTimeSeconds: 76,
        timeListenedSeconds: 0.5,
        durationSeconds: 1000,
      );
      expect(seen[0].url.path, '/api/session/sess_1/sync');
      expect(seen[1].url.path, '/api/session/sess_1/close');
      final Map<String, Object?> body =
          jsonDecode(seen[0].body) as Map<String, Object?>;
      expect(body, <String, Object?>{
        'currentTime': 75.5,
        'timeListening': 10,
        'duration': 1000,
      });
    });

    test('会话已过期（404）→ notFound，供调用方退回 PATCH', () async {
      final AudiobookshelfApi api = _api(
        (http.Request request) async => http.Response('Not found', 404),
      );
      await expectLater(
        api.syncSession(
          'gone',
          currentTimeSeconds: 1,
          timeListenedSeconds: 1,
          durationSeconds: 2,
        ),
        throwsA(
          isA<ExternalProviderFailure>().having(
            (ExternalProviderFailure f) => f.kind,
            'kind',
            ExternalProviderFailureKind.notFound,
          ),
        ),
      );
    });

    test('patchProgress：自己算 progress；播客带 episodeId', () async {
      late http.Request seen;
      final AudiobookshelfApi api = _api((http.Request request) async {
        seen = request;
        return http.Response('OK', 200);
      });
      await api.patchProgress(
        'pod_1',
        episodeId: 'ep_1',
        currentTimeSeconds: 25,
        durationSeconds: 100,
      );
      expect(seen.method, 'PATCH');
      expect(seen.url.path, '/api/me/progress/pod_1/ep_1');
      final Map<String, Object?> body =
          jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['progress'], 0.25);
      expect(body['isFinished'], false);
    });

    test('getProgress：404 = 还没有记录 → null', () async {
      final AudiobookshelfApi api = _api(
        (http.Request request) async => http.Response('Not found', 404),
      );
      expect(await api.getProgress('item_1'), isNull);
    });

    test('itemsInProgress：播客带最近一集', () async {
      final AudiobookshelfApi api = _api(
        (http.Request request) async => _json(<String, Object?>{
          'libraryItems': <Object?>[
            <String, Object?>{
              'id': 'pod_1',
              'mediaType': 'podcast',
              'media': <String, Object?>{
                'metadata': <String, Object?>{'title': 'Show'},
              },
              'recentEpisode': <String, Object?>{'id': 'ep_9', 'title': 'Nine'},
            },
            <String, Object?>{
              'id': 'book_1',
              'media': <String, Object?>{
                'metadata': <String, Object?>{'title': 'Book'},
              },
            },
          ],
        }),
      );
      final List<AudiobookshelfInProgressEntry> entries = await api
          .itemsInProgress();
      expect(entries, hasLength(2));
      expect(entries[0].episodeId, 'ep_9');
      expect(entries[0].episodeTitle, 'Nine');
      expect(entries[1].episodeId, isNull);
    });
  });

  group('openRange / 文件读取', () {
    test('带 Range 头与 Bearer，返回 206 流', () async {
      late http.Request seen;
      final AudiobookshelfApi api = _api((http.Request request) async {
        seen = request;
        return http.Response.bytes(<int>[1, 2, 3], 206);
      });
      final http.StreamedResponse response = await api.openRange(
        api.fileUri('item_1', '10'),
        start: 100,
        end: 102,
      );
      expect(seen.headers['Range'], 'bytes=100-102');
      expect(seen.headers['Authorization'], 'Bearer access-1');
      expect(response.statusCode, 206);
      expect(await response.stream.toBytes(), <int>[1, 2, 3]);
    });

    test('401 → 刷新（refresh token 轮换交出持久化）→ 带新令牌重试', () async {
      final List<AudiobookshelfTokens> persisted = <AudiobookshelfTokens>[];
      final List<String> auths = <String>[];
      final AudiobookshelfApi api = _api(
        (http.Request request) async {
          if (request.url.path == '/auth/refresh') {
            expect(request.headers['x-refresh-token'], 'refresh-1');
            return _json(<String, Object?>{
              'user': <String, Object?>{
                'id': 'u',
                'username': 'demo',
                'accessToken': 'access-2',
                'refreshToken': 'refresh-2',
              },
            });
          }
          auths.add(request.headers['Authorization'] ?? '');
          return auths.length == 1
              ? http.Response('nope', 401)
              : http.Response.bytes(<int>[9], 200);
        },
        onTokensChanged: (AudiobookshelfTokens tokens) async =>
            persisted.add(tokens),
      );
      final http.StreamedResponse response = await api.openRange(
        api.fileUri('item_1', '10'),
      );
      expect(auths, <String>['Bearer access-1', 'Bearer access-2']);
      expect(persisted.single.refreshToken, 'refresh-2');
      expect(await response.stream.toBytes(), <int>[9]);
    });

    test('刷新也失败 → unauthorized', () async {
      final AudiobookshelfApi api = _api(
        (http.Request request) async => http.Response('nope', 401),
        tokens: const AudiobookshelfTokens(accessToken: 'api-key'),
      );
      await expectLater(
        api.openRange(api.fileUri('i', '1')),
        throwsA(
          isA<ExternalProviderFailure>().having(
            (ExternalProviderFailure f) => f.kind,
            'kind',
            ExternalProviderFailureKind.unauthorized,
          ),
        ),
      );
    });

    test('不向别的 origin 发凭据', () async {
      int calls = 0;
      final AudiobookshelfApi api = _api((http.Request request) async {
        calls++;
        return http.Response('x', 200);
      });
      await expectLater(
        api.openRange(Uri.parse('https://evil.example.com/a.mp3')),
        throwsA(
          isA<ExternalProviderFailure>().having(
            (ExternalProviderFailure f) => f.kind,
            'kind',
            ExternalProviderFailureKind.forbidden,
          ),
        ),
      );
      expect(calls, 0);
    });

    test('fetchLibraryTextFile：读到字节；超过上限 → invalidResponse', () async {
      final AudiobookshelfApi api = _api(
        (http.Request request) async => http.Response.bytes(
          utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nhi'),
          200,
        ),
      );
      expect(
        utf8.decode(await api.fetchLibraryTextFile('item_1', '20')),
        contains('hi'),
      );
      await expectLater(
        api.fetchLibraryTextFile('item_1', '20', maxBytes: 4),
        throwsA(
          isA<ExternalProviderFailure>().having(
            (ExternalProviderFailure f) => f.kind,
            'kind',
            ExternalProviderFailureKind.invalidResponse,
          ),
        ),
      );
    });

    test('prepareFileDownload：无下载权限 → forbidden；有则给 /download 地址', () async {
      AudiobookshelfApi apiWith({required bool canDownload}) => _api(
        (http.Request request) async => _json(<String, Object?>{
          'id': 'u',
          'username': 'demo',
          'permissions': <String, Object?>{'download': canDownload},
        }),
      );
      await expectLater(
        apiWith(
          canDownload: false,
        ).prepareFileDownload('i', '5', fileName: 'e.mp3'),
        throwsA(
          isA<ExternalProviderFailure>().having(
            (ExternalProviderFailure f) => f.kind,
            'kind',
            ExternalProviderFailureKind.forbidden,
          ),
        ),
      );
      final AudiobookshelfDownloadTarget target = await apiWith(
        canDownload: true,
      ).prepareFileDownload('i', '5', fileName: 'e.mp3', sizeBytes: 9);
      expect(target.url.path, '/api/items/i/file/5/download');
      expect(target.fileName, 'e.mp3');
      expect(target.headers['Authorization'], 'Bearer access-1');
    });
  });

  group('令牌过期时间', () {
    test('audiobookshelfTokenExpiry：读 JWT exp；API key / 无 exp / 乱码为 null', () {
      expect(
        audiobookshelfTokenExpiry(_jwt(exp: 1700000000)),
        DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
      );
      expect(audiobookshelfTokenExpiry(_jwt()), isNull);
      expect(audiobookshelfTokenExpiry('not-a-jwt'), isNull);
      expect(audiobookshelfTokenExpiry('a.@@@.c'), isNull);
    });

    test('freshAuthorizationHeaders：快过期先刷新，没过期不动', () async {
      int refreshes = 0;
      final String soon = _jwt(
        exp: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30,
      );
      final String later = _jwt(
        exp: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      );
      AudiobookshelfApi apiFor(String access) => _api(
        (http.Request request) async {
          refreshes++;
          return _json(<String, Object?>{
            'user': <String, Object?>{
              'id': 'u',
              'username': 'demo',
              'accessToken': 'access-fresh',
              'refreshToken': 'refresh-2',
            },
          });
        },
        tokens: AudiobookshelfTokens(
          accessToken: access,
          refreshToken: 'refresh-1',
        ),
      );
      expect(
        (await apiFor(later).freshAuthorizationHeaders())['Authorization'],
        'Bearer $later',
      );
      expect(refreshes, 0);
      expect(
        (await apiFor(soon).freshAuthorizationHeaders())['Authorization'],
        'Bearer access-fresh',
      );
      expect(refreshes, 1);
    });
  });
}
