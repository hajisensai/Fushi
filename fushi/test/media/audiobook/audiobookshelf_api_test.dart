// Audiobookshelf 协议层契约：登录新旧两种响应、401 → 刷新 → 重试、refresh token
// 轮换被交出持久化、库/条目分页解析、podcast 库识别、下载权限 403。
//
// 响应形状按 ABS v2.37.1 源码（Auth.js / LibraryController / LibraryItem /
// Book / User 的 toOldJSON* 系列）构造。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/external_provider.dart';

final Uri _server = Uri.parse('https://abs.example.com/audiobookshelf');

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, Object?> _loginBody({
  String? accessToken,
  String? refreshToken,
  String? legacyToken,
  bool canDownload = true,
}) => <String, Object?>{
  'user': <String, Object?>{
    'id': 'usr_1',
    'username': 'alice',
    'type': 'user',
    if (legacyToken != null) 'token': legacyToken,
    if (accessToken != null) 'accessToken': accessToken,
    'refreshToken': refreshToken,
    'permissions': <String, Object?>{'download': canDownload},
  },
  'userDefaultLibraryId': 'lib_books',
  'serverSettings': <String, Object?>{'version': '2.37.1'},
};

Map<String, Object?> _minifiedItem(
  String id, {
  String title = 'Book',
  int? numAudioFiles = 3,
  bool isFile = false,
  String? relPath,
}) => <String, Object?>{
  'id': id,
  'libraryId': 'lib_books',
  'isFile': isFile,
  'relPath': relPath ?? title,
  'mediaType': 'book',
  'size': 1024,
  'media': <String, Object?>{
    'metadata': <String, Object?>{
      'title': title,
      'authorName': 'Author A',
      'narratorName': 'Narrator N',
      'seriesName': 'Series S #1',
      'publishedYear': '2020',
    },
    'numAudioFiles': numAudioFiles,
    'duration': 3725.5,
  },
};

void main() {
  group('normalizeServerUrl', () {
    test('补 scheme、保留子路径、去尾斜杠与查询', () {
      expect(
        AudiobookshelfApi.normalizeServerUrl('192.168.1.5:13378/')?.toString(),
        'http://192.168.1.5:13378',
      );
      expect(
        AudiobookshelfApi.normalizeServerUrl(
          'https://host.example/abs/?x=1',
        )?.toString(),
        'https://host.example/abs',
      );
      expect(AudiobookshelfApi.normalizeServerUrl(''), isNull);
      expect(AudiobookshelfApi.normalizeServerUrl('ftp://host'), isNull);
    });
  });

  group('login', () {
    test('新版响应：accessToken + refreshToken，带 x-return-tokens，令牌交出持久化', () async {
      final List<AudiobookshelfTokens> persisted = <AudiobookshelfTokens>[];
      late http.Request seen;
      final AudiobookshelfApi api = AudiobookshelfApi(
        serverUrl: _server,
        providerId: 'abs-test',
        onTokensChanged: (AudiobookshelfTokens tokens) async =>
            persisted.add(tokens),
        client: MockClient((http.Request request) async {
          seen = request;
          return _json(_loginBody(accessToken: 'acc-1', refreshToken: 'ref-1'));
        }),
      );

      final AudiobookshelfSession session = await api.login('alice', 'pw');

      expect(seen.method, 'POST');
      expect(
        seen.url.toString(),
        'https://abs.example.com/audiobookshelf/login',
      );
      expect(seen.headers['x-return-tokens'], 'true');
      expect(jsonDecode(seen.body), <String, Object?>{
        'username': 'alice',
        'password': 'pw',
      });
      expect(session.tokens.accessToken, 'acc-1');
      expect(session.tokens.refreshToken, 'ref-1');
      expect(session.user.canDownload, isTrue);
      expect(session.defaultLibraryId, 'lib_books');
      expect(session.serverVersion, '2.37.1');
      expect(persisted, <AudiobookshelfTokens>[
        const AudiobookshelfTokens(accessToken: 'acc-1', refreshToken: 'ref-1'),
      ]);
      expect(api.authorizationHeaders, <String, String>{
        'Authorization': 'Bearer acc-1',
      });
    });

    test('旧版响应：只有 user.token，不可刷新', () async {
      final AudiobookshelfApi api = AudiobookshelfApi(
        serverUrl: _server,
        providerId: 'abs-test',
        client: MockClient(
          (http.Request request) async => _json(_loginBody(legacyToken: 'old')),
        ),
      );
      final AudiobookshelfSession session = await api.login('alice', 'pw');
      expect(session.tokens.accessToken, 'old');
      expect(session.tokens.refreshToken, isNull);
      expect(session.tokens.canRefresh, isFalse);
    });

    test('账号密码错 → unauthorized；响应没有 token → invalidResponse', () async {
      final AudiobookshelfApi wrong = AudiobookshelfApi(
        serverUrl: _server,
        providerId: 'abs-test',
        client: MockClient(
          (http.Request request) async => http.Response('Unauthorized', 401),
        ),
      );
      await expectLater(
        wrong.login('alice', 'bad'),
        throwsA(
          isA<ExternalProviderFailure>().having(
            (ExternalProviderFailure f) => f.kind,
            'kind',
            ExternalProviderFailureKind.unauthorized,
          ),
        ),
      );

      final AudiobookshelfApi malformed = AudiobookshelfApi(
        serverUrl: _server,
        providerId: 'abs-test',
        client: MockClient(
          (http.Request request) async => _json(<String, Object?>{
            'user': <String, Object?>{'id': 'u'},
          }),
        ),
      );
      await expectLater(
        malformed.login('alice', 'pw'),
        throwsA(
          isA<ExternalProviderFailure>().having(
            (ExternalProviderFailure f) => f.kind,
            'kind',
            ExternalProviderFailureKind.invalidResponse,
          ),
        ),
      );
    });
  });

  group('401 → 刷新 → 重试', () {
    test('过期 access token 刷新一次后重试成功，轮换后的 refresh token 被持久化', () async {
      final List<AudiobookshelfTokens> persisted = <AudiobookshelfTokens>[];
      final List<String> calls = <String>[];
      final AudiobookshelfApi api = AudiobookshelfApi(
        serverUrl: _server,
        providerId: 'abs-test',
        tokens: const AudiobookshelfTokens(
          accessToken: 'expired',
          refreshToken: 'ref-old',
        ),
        onTokensChanged: (AudiobookshelfTokens tokens) async =>
            persisted.add(tokens),
        client: MockClient((http.Request request) async {
          final String auth = request.headers['Authorization'] ?? '';
          calls.add(
            '${request.method} ${request.url.path} $auth'
            '${request.headers['x-refresh-token'] ?? ''}',
          );
          if (request.url.path.endsWith('/auth/refresh')) {
            expect(request.headers['x-refresh-token'], 'ref-old');
            return _json(
              _loginBody(accessToken: 'fresh', refreshToken: 'ref-new'),
            );
          }
          if (auth == 'Bearer expired') return http.Response('', 401);
          return _json(<String, Object?>{
            'libraries': <Object?>[
              <String, Object?>{
                'id': 'lib_books',
                'name': 'Books',
                'mediaType': 'book',
              },
            ],
          });
        }),
      );

      final List<AudiobookshelfLibrary> libraries = await api.libraries();

      expect(libraries.single.id, 'lib_books');
      expect(calls, <String>[
        'GET /audiobookshelf/api/libraries Bearer expired',
        'POST /audiobookshelf/auth/refresh ref-old',
        'GET /audiobookshelf/api/libraries Bearer fresh',
      ]);
      expect(persisted, <AudiobookshelfTokens>[
        const AudiobookshelfTokens(
          accessToken: 'fresh',
          refreshToken: 'ref-new',
        ),
      ]);
      expect(api.tokens!.refreshToken, 'ref-new');
    });

    test('并发 401 只刷新一次', () async {
      int refreshes = 0;
      final AudiobookshelfApi api = AudiobookshelfApi(
        serverUrl: _server,
        providerId: 'abs-test',
        tokens: const AudiobookshelfTokens(
          accessToken: 'expired',
          refreshToken: 'ref-old',
        ),
        client: MockClient((http.Request request) async {
          if (request.url.path.endsWith('/auth/refresh')) {
            refreshes++;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return _json(
              _loginBody(accessToken: 'fresh', refreshToken: 'ref-$refreshes'),
            );
          }
          if (request.headers['Authorization'] == 'Bearer expired') {
            return http.Response('', 401);
          }
          return _json(<String, Object?>{'libraries': <Object?>[]});
        }),
      );

      await Future.wait(<Future<Object?>>[api.libraries(), api.libraries()]);
      expect(refreshes, 1);
    });

    test('refresh token 也失效 → unauthorized（提示重新登录），不无限重试', () async {
      int requests = 0;
      final AudiobookshelfApi api = AudiobookshelfApi(
        serverUrl: _server,
        providerId: 'abs-test',
        tokens: const AudiobookshelfTokens(
          accessToken: 'expired',
          refreshToken: 'ref-dead',
        ),
        client: MockClient((http.Request request) async {
          requests++;
          return http.Response('{"error":"Invalid refresh token"}', 401);
        }),
      );
      await expectLater(
        api.libraries(),
        throwsA(
          isA<ExternalProviderFailure>()
              .having(
                (ExternalProviderFailure f) => f.kind,
                'kind',
                ExternalProviderFailureKind.unauthorized,
              )
              .having(
                (ExternalProviderFailure f) => f.message,
                'message',
                contains('sign in again'),
              ),
        ),
      );
      // 原请求 + 一次刷新，刷新失败后不再重试原请求。
      expect(requests, 2);
    });

    test('API key（无 refresh token）401 直接判 unauthorized，不发刷新', () async {
      final List<String> paths = <String>[];
      final AudiobookshelfApi api = AudiobookshelfApi(
        serverUrl: _server,
        providerId: 'abs-test',
        tokens: const AudiobookshelfTokens(accessToken: 'revoked-key'),
        client: MockClient((http.Request request) async {
          paths.add(request.url.path);
          return http.Response('', 401);
        }),
      );
      await expectLater(
        api.libraries(),
        throwsA(isA<ExternalProviderFailure>()),
      );
      expect(paths, <String>['/audiobookshelf/api/libraries']);
    });

    test('未登录直接 unauthorized，不发请求', () async {
      bool called = false;
      final AudiobookshelfApi api = AudiobookshelfApi(
        serverUrl: _server,
        providerId: 'abs-test',
        client: MockClient((http.Request request) async {
          called = true;
          return _json(<String, Object?>{});
        }),
      );
      await expectLater(
        api.libraries(),
        throwsA(isA<ExternalProviderFailure>()),
      );
      expect(called, isFalse);
    });
  });

  group('库与条目解析', () {
    test('库清单区分 book / podcast', () {
      final List<AudiobookshelfLibrary>
      libraries = AudiobookshelfLibrary.parseList(<String, Object?>{
        'libraries': <Object?>[
          <String, Object?>{'id': 'a', 'name': 'Books', 'mediaType': 'book'},
          <String, Object?>{'id': 'b', 'name': 'Pods', 'mediaType': 'podcast'},
          <String, Object?>{'name': 'no id'},
        ],
      });
      expect(libraries.map((AudiobookshelfLibrary l) => l.id), <String>[
        'a',
        'b',
      ]);
      expect(libraries[0].isBookLibrary, isTrue);
      expect(libraries[1].isBookLibrary, isFalse);
    });

    test('条目分页：0 基页码、查询参数、字符串回显的 page/limit、hasMore', () async {
      late Uri seen;
      final AudiobookshelfApi api = AudiobookshelfApi(
        serverUrl: _server,
        providerId: 'abs-test',
        tokens: const AudiobookshelfTokens(accessToken: 'tok'),
        client: MockClient((http.Request request) async {
          seen = request.url;
          return _json(<String, Object?>{
            'results': <Object?>[
              _minifiedItem('li_1', title: 'Alpha'),
              _minifiedItem('li_2', title: 'Beta', numAudioFiles: 0),
            ],
            'total': 5,
            'limit': '2',
            'page': '1',
          });
        }),
      );

      final AudiobookshelfItemPage page = await api.libraryItems(
        'lib_books',
        page: 1,
        limit: 2,
      );

      expect(seen.path, '/audiobookshelf/api/libraries/lib_books/items');
      expect(seen.queryParameters, <String, String>{
        'limit': '2',
        'page': '1',
        'sort': 'media.metadata.title',
        'minified': '1',
      });
      expect(page.page, 1);
      expect(page.limit, 2);
      expect(page.total, 5);
      expect(page.hasMore, isTrue); // (1+1)*2 = 4 < 5
      final AudiobookshelfItem first = page.items.first;
      expect(first.title, 'Alpha');
      expect(first.authorName, 'Author A');
      expect(first.narratorName, 'Narrator N');
      expect(first.seriesName, 'Series S #1');
      expect(first.durationSeconds, 3725.5);
      expect(first.sizeBytes, 1024);
      expect(first.hasNoAudio, isFalse);
      expect(page.items[1].hasNoAudio, isTrue);
    });

    test('最后一页 hasMore 为 false', () {
      final AudiobookshelfItemPage page = AudiobookshelfItemPage.parse(
        <String, Object?>{'results': <Object?>[], 'total': 4},
        requestedPage: 1,
        requestedLimit: 2,
      );
      expect(page.hasMore, isFalse);
    });

    test('搜索结果取 book[].libraryItem', () {
      final List<AudiobookshelfItem> items = parseAudiobookshelfSearch(
        <String, Object?>{
          'book': <Object?>[
            <String, Object?>{
              'libraryItem': _minifiedItem('li_9', title: 'Hit'),
            },
          ],
          'series': <Object?>[],
          'authors': <Object?>[],
        },
      );
      expect(items.single.id, 'li_9');
      expect(items.single.title, 'Hit');
    });
  });

  group('下载', () {
    AudiobookshelfApi downloadApi({
      required bool canDownload,
      Map<String, Object?>? item,
    }) => AudiobookshelfApi(
      serverUrl: _server,
      providerId: 'abs-test',
      tokens: const AudiobookshelfTokens(accessToken: 'tok'),
      client: MockClient((http.Request request) async {
        if (request.url.path.endsWith('/api/me')) {
          return _json(<String, Object?>{
            'id': 'usr_1',
            'username': 'alice',
            'permissions': <String, Object?>{'download': canDownload},
          });
        }
        if (request.url.path.endsWith('/api/items/li_1')) {
          expect(request.url.queryParameters['expanded'], '1');
          return _json(item ?? _minifiedItem('li_1', title: 'My Book'));
        }
        return http.Response('', 404);
      }),
    );

    test('多文件条目：zip 文件名 + Bearer 头 + download 端点', () async {
      final AudiobookshelfDownloadTarget target = await downloadApi(
        canDownload: true,
      ).prepareDownload('li_1');
      expect(
        target.url.toString(),
        'https://abs.example.com/audiobookshelf/api/items/li_1/download',
      );
      expect(target.headers, <String, String>{'Authorization': 'Bearer tok'});
      expect(target.fileName, 'My Book.zip');
      expect(target.sizeBytes, 1024);
    });

    test('单文件条目：直接用原文件名', () async {
      final AudiobookshelfDownloadTarget target = await downloadApi(
        canDownload: true,
        item: _minifiedItem(
          'li_1',
          title: 'Single',
          isFile: true,
          relPath: 'Single Book.m4b',
        ),
      ).prepareDownload('li_1');
      expect(target.fileName, 'Single Book.m4b');
    });

    test('没有下载权限 → forbidden（不把一个必然 403 的地址交给下载队列）', () async {
      await expectLater(
        downloadApi(canDownload: false).prepareDownload('li_1'),
        throwsA(
          isA<ExternalProviderFailure>()
              .having(
                (ExternalProviderFailure f) => f.kind,
                'kind',
                ExternalProviderFailureKind.forbidden,
              )
              .having(
                (ExternalProviderFailure f) => f.statusCode,
                'status',
                403,
              ),
        ),
      );
    });

    test('服务端 403 映射成 forbidden', () async {
      final AudiobookshelfApi api = AudiobookshelfApi(
        serverUrl: _server,
        providerId: 'abs-test',
        tokens: const AudiobookshelfTokens(accessToken: 'tok'),
        client: MockClient(
          (http.Request request) async => http.Response('Forbidden', 403),
        ),
      );
      await expectLater(
        api.item('li_1'),
        throwsA(
          isA<ExternalProviderFailure>().having(
            (ExternalProviderFailure f) => f.kind,
            'kind',
            ExternalProviderFailureKind.forbidden,
          ),
        ),
      );
    });

    test('封面地址免鉴权、保留子路径', () {
      final AudiobookshelfApi api = AudiobookshelfApi(
        serverUrl: _server,
        providerId: 'abs-test',
        client: MockClient(
          (http.Request request) async => http.Response('', 500),
        ),
      );
      expect(
        api.coverUri('li_1').toString(),
        'https://abs.example.com/audiobookshelf/api/items/li_1/cover?width=400',
      );
      expect(
        api.isServerOrigin(Uri.parse('https://abs.example.com/x')),
        isTrue,
      );
      expect(
        api.isServerOrigin(Uri.parse('https://cdn.example.com/x')),
        isFalse,
      );
      expect(
        api.isServerOrigin(Uri.parse('http://abs.example.com/x')),
        isFalse,
      );
    });
  });
}
