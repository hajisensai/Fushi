// Audiobookshelf 发现源契约：根目录只列有声书库（podcast 过滤）、库内分页映射
// （发现页 1 基 → ABS 0 基）、无音频条目不列、搜索跨库合并去重、resolvePayload 产出
// 的 httpFile payload（下载端点 + Bearer + 带扩展名文件名）、鉴权头不发往别的 host、
// 下载权限 / 登录失效给出用户可读的错误、配置的序列化与令牌写回。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/discovery/sources/audiobookshelf_discovery_source.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/external_provider.dart';

const String _host = 'abs.example.com';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, Object?> _item(
  String id, {
  String title = 'Book',
  int numAudioFiles = 2,
  String mediaType = 'book',
}) => <String, Object?>{
  'id': id,
  'libraryId': 'lib_books',
  'isFile': false,
  'relPath': title,
  'mediaType': mediaType,
  'size': 2048,
  'media': <String, Object?>{
    'metadata': <String, Object?>{
      'title': title,
      'authorName': 'Author',
      'narratorName': 'Reader',
      'seriesName': 'Saga #2',
      'publishedYear': '2019',
    },
    'numAudioFiles': numAudioFiles,
    'duration': 3661.0,
  },
};

AudiobookshelfServerConfig _config({
  AudiobookshelfTokens tokens = const AudiobookshelfTokens(
    accessToken: 'tok',
    refreshToken: 'ref',
  ),
}) => AudiobookshelfServerConfig(
  id: 'srv1',
  name: 'Home ABS',
  serverUrl: Uri.parse('https://$_host/abs'),
  username: 'alice',
  tokens: tokens,
);

/// 记录全部请求的假服务器。
class _FakeAbs {
  _FakeAbs({this.canDownload = true});

  final bool canDownload;
  final List<http.Request> requests = <http.Request>[];

  MockClient get client => MockClient((http.Request request) async {
    requests.add(request);
    final String path = request.url.path;
    if (path == '/abs/api/libraries') {
      return _json(<String, Object?>{
        'libraries': <Object?>[
          <String, Object?>{
            'id': 'lib_books',
            'name': 'Books',
            'mediaType': 'book',
          },
          <String, Object?>{
            'id': 'lib_pods',
            'name': 'Podcasts',
            'mediaType': 'podcast',
          },
          <String, Object?>{
            'id': 'lib_more',
            'name': 'More books',
            'mediaType': 'book',
          },
        ],
      });
    }
    if (path == '/abs/api/libraries/lib_books/items') {
      return _json(<String, Object?>{
        'results': <Object?>[
          _item('li_1', title: 'Alpha'),
          _item('li_ebook', title: 'Ebook only', numAudioFiles: 0),
        ],
        'total': 120,
        'limit': request.url.queryParameters['limit'],
        'page': request.url.queryParameters['page'],
      });
    }
    if (path == '/abs/api/libraries/lib_books/search') {
      return _json(<String, Object?>{
        'book': <Object?>[
          <String, Object?>{'libraryItem': _item('li_1', title: 'Alpha')},
        ],
      });
    }
    if (path == '/abs/api/libraries/lib_more/search') {
      return _json(<String, Object?>{
        'book': <Object?>[
          // 同一条目在两个库的搜索里都出现时只列一次。
          <String, Object?>{'libraryItem': _item('li_1', title: 'Alpha')},
          <String, Object?>{'libraryItem': _item('li_2', title: 'Beta')},
        ],
      });
    }
    if (path == '/abs/api/me') {
      return _json(<String, Object?>{
        'id': 'usr',
        'username': 'alice',
        'permissions': <String, Object?>{'download': canDownload},
      });
    }
    if (path == '/abs/api/items/li_1') {
      return _json(_item('li_1', title: 'Alpha'));
    }
    return http.Response('not found', 404);
  });
}

void main() {
  group('browse', () {
    test('根目录只列有声书库，podcast 库被过滤', () async {
      final _FakeAbs fake = _FakeAbs();
      final AudiobookshelfDiscoverySource source =
          AudiobookshelfDiscoverySource(config: _config(), client: fake.client);

      final ProviderBatchResult<DiscoveryResultPage> result = await source
          .browse(const DiscoveryRequest(kind: DiscoveryMediaKind.audiobook));

      final List<DiscoveryEntry> entries = result.items.single.entries;
      expect(entries, everyElement(isA<DiscoveryFolder>()));
      expect(entries.map((DiscoveryEntry e) => e.title), <String>[
        'Books',
        'More books',
      ]);
      expect((entries.first as DiscoveryFolder).path, 'library:lib_books');
      expect(result.items.single.hasMore, isFalse);
      expect(source.id, 'abs-srv1');
      expect(source.displayName, 'Home ABS');
      expect(source.isUserConfigured, isTrue);
      expect(source.capabilities.kinds, <DiscoveryMediaKind>{
        DiscoveryMediaKind.audiobook,
      });
    });

    test('库内分页：发现页第 2 页 = ABS page 1；资源项字段与无音频过滤', () async {
      final _FakeAbs fake = _FakeAbs();
      final AudiobookshelfDiscoverySource source =
          AudiobookshelfDiscoverySource(config: _config(), client: fake.client);

      final ProviderBatchResult<DiscoveryResultPage> result = await source
          .browse(
            const DiscoveryRequest(
              kind: DiscoveryMediaKind.audiobook,
              path: 'library:lib_books',
              page: 2,
              pageSize: 50,
            ),
          );

      final http.Request sent = fake.requests.single;
      expect(sent.url.queryParameters['page'], '1');
      expect(sent.url.queryParameters['limit'], '50');
      expect(sent.headers['Authorization'], 'Bearer tok');

      final DiscoveryResultPage page = result.items.single;
      expect(page.page, 2);
      expect(page.hasMore, isTrue); // (1+1)*50 = 100 < 120
      final List<DiscoveryResourceItem> items = page.entries
          .cast<DiscoveryResourceItem>();
      expect(
        items.map((DiscoveryResourceItem i) => i.id),
        <String>['li_1'],
        reason: '只有电子书没有音频的条目在有声书页里点下载必然导入失败',
      );
      final DiscoveryResourceItem alpha = items.single;
      expect(alpha.title, 'Alpha');
      expect(alpha.kind, DiscoveryMediaKind.audiobook);
      expect(alpha.payloadKind, DiscoveryPayloadKind.httpFile);
      expect(alpha.payload, isNull, reason: '令牌一小时过期，payload 必须下载时现取');
      expect(alpha.sizeBytes, 2048);
      expect(alpha.dateText, '2019');
      expect(
        alpha.coverUrl,
        'https://$_host/abs/api/items/li_1/cover?width=400',
      );
      expect(alpha.note, contains('Author'));
      expect(alpha.note, contains('Reader'));
      expect(alpha.note, contains('Saga #2'));
      expect(alpha.note, contains('1:01:01'));
    });
  });

  group('search', () {
    test('跨全部有声书库搜索、按条目 id 去重，不搜 podcast 库', () async {
      final _FakeAbs fake = _FakeAbs();
      final AudiobookshelfDiscoverySource source =
          AudiobookshelfDiscoverySource(config: _config(), client: fake.client);

      final ProviderBatchResult<DiscoveryResultPage> result = await source
          .search(
            const DiscoveryRequest(
              kind: DiscoveryMediaKind.audiobook,
              query: ' alpha ',
            ),
          );

      expect(
        result.items.single.entries.map((DiscoveryEntry e) => e.title),
        <String>['Alpha', 'Beta'],
      );
      final Iterable<String> searched = fake.requests
          .where((http.Request r) => r.url.path.endsWith('/search'))
          .map((http.Request r) => r.url.path);
      expect(searched, <String>[
        '/abs/api/libraries/lib_books/search',
        '/abs/api/libraries/lib_more/search',
      ]);
      expect(
        fake.requests
            .firstWhere((http.Request r) => r.url.path.endsWith('/search'))
            .url
            .queryParameters['q'],
        'alpha',
      );
      expect(result.items.single.hasMore, isFalse);

      // 第 2 页：ABS 搜索不分页，直接空页、不再发请求。
      final int before = fake.requests.length;
      final ProviderBatchResult<DiscoveryResultPage> second = await source
          .search(
            const DiscoveryRequest(
              kind: DiscoveryMediaKind.audiobook,
              query: 'alpha',
              page: 2,
            ),
          );
      expect(second.items.single.entries, isEmpty);
      expect(fake.requests.length, before);
    });
  });

  group('resolvePayload', () {
    const DiscoveryResourceItem item = DiscoveryResourceItem(
      sourceId: 'abs-srv1',
      title: 'Alpha',
      id: 'li_1',
      kind: DiscoveryMediaKind.audiobook,
      payloadKind: DiscoveryPayloadKind.httpFile,
    );

    test('httpFile payload：下载端点 + Bearer + zip 文件名', () async {
      final _FakeAbs fake = _FakeAbs();
      final AudiobookshelfDiscoverySource source =
          AudiobookshelfDiscoverySource(config: _config(), client: fake.client);

      final DiscoveryPayload payload = await source.resolvePayload(item);

      expect(payload, isA<DiscoveryHttpPayload>());
      final DiscoveryHttpPayload direct = payload as DiscoveryHttpPayload;
      expect(direct.url, 'https://$_host/abs/api/items/li_1/download');
      expect(direct.headers, <String, String>{'Authorization': 'Bearer tok'});
      expect(direct.fileName, 'Alpha.zip');
      expect(direct.sizeBytes, 2048);
      // 鉴权头只发往本服务器：列表 / 物化阶段的每个请求都打在配置的 host 上。
      expect(
        fake.requests.map((http.Request r) => r.url.host).toSet(),
        <String>{_host},
      );
    });

    test('没有下载权限 → 用户可读的错误（toString 即提示文案）', () async {
      final _FakeAbs fake = _FakeAbs(canDownload: false);
      final AudiobookshelfDiscoverySource source =
          AudiobookshelfDiscoverySource(config: _config(), client: fake.client);

      Object? caught;
      try {
        await source.resolvePayload(item);
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<AudiobookshelfActionRequired>());
      final AudiobookshelfActionRequired action =
          caught! as AudiobookshelfActionRequired;
      expect(action.failure.kind, ExternalProviderFailureKind.forbidden);
      expect('$action', isNot(contains('ExternalProviderFailure')));
      expect('$action', isNotEmpty);
      expect(
        fake.requests.any((http.Request r) => r.url.path.endsWith('/download')),
        isFalse,
      );
    });

    test('登录失效（刷新也 401）→ 提示重新登录', () async {
      final AudiobookshelfDiscoverySource source =
          AudiobookshelfDiscoverySource(
            config: _config(),
            client: MockClient(
              (http.Request request) async => http.Response('', 401),
            ),
          );
      await expectLater(
        source.resolvePayload(item),
        throwsA(
          isA<AudiobookshelfActionRequired>().having(
            (AudiobookshelfActionRequired a) => a.failure.kind,
            'kind',
            ExternalProviderFailureKind.unauthorized,
          ),
        ),
      );
    });

    test('刷新轮换后的令牌经回调交出，下载用的是新令牌', () async {
      final List<AudiobookshelfTokens> persisted = <AudiobookshelfTokens>[];
      final AudiobookshelfDiscoverySource source =
          AudiobookshelfDiscoverySource(
            config: _config(
              tokens: const AudiobookshelfTokens(
                accessToken: 'expired',
                refreshToken: 'ref-old',
              ),
            ),
            onTokensChanged: (AudiobookshelfTokens tokens) async =>
                persisted.add(tokens),
            client: MockClient((http.Request request) async {
              if (request.url.path == '/abs/auth/refresh') {
                return _json(<String, Object?>{
                  'user': <String, Object?>{
                    'id': 'usr',
                    'username': 'alice',
                    'accessToken': 'fresh',
                    'refreshToken': 'ref-new',
                  },
                });
              }
              if (request.headers['Authorization'] == 'Bearer expired') {
                return http.Response('', 401);
              }
              if (request.url.path == '/abs/api/me') {
                return _json(<String, Object?>{
                  'id': 'usr',
                  'username': 'alice',
                  'permissions': <String, Object?>{'download': true},
                });
              }
              return _json(_item('li_1', title: 'Alpha'));
            }),
          );

      final DiscoveryHttpPayload payload =
          await source.resolvePayload(item) as DiscoveryHttpPayload;

      expect(payload.headers['Authorization'], 'Bearer fresh');
      expect(persisted, <AudiobookshelfTokens>[
        const AudiobookshelfTokens(
          accessToken: 'fresh',
          refreshToken: 'ref-new',
        ),
      ]);
    });
  });

  group('配置', () {
    test('JSON 往返：令牌 base64 存放、不存密码；坏条目与重复 id 被丢弃', () {
      final AudiobookshelfServerConfig config = _config();
      final String raw = encodeAudiobookshelfServerConfigs(
        <AudiobookshelfServerConfig>[config],
      );
      expect(raw, isNot(contains('"tok"')));
      expect(raw, isNot(contains('password')));

      final List<Object?> list = jsonDecode(raw) as List<Object?>;
      final String withJunk = jsonEncode(<Object?>[
        ...list,
        ...list, // 重复 id
        <String, Object?>{'id': 'bad', 'url': 'ftp://x'},
        'not a map',
      ]);
      final List<AudiobookshelfServerConfig> decoded =
          decodeAudiobookshelfServerConfigs(withJunk);
      expect(decoded, hasLength(1));
      expect(decoded.single.tokens, config.tokens);
      expect(decoded.single.serverUrl.toString(), 'https://$_host/abs');
      expect(decoded.single.username, 'alice');
    });

    test('明文 HTTP 需显式放行（回环地址除外）', () {
      expect(
        () => AudiobookshelfServerConfig(
          id: 'x',
          name: '',
          serverUrl: Uri.parse('http://192.168.1.5:13378'),
        ),
        throwsArgumentError,
      );
      expect(
        AudiobookshelfServerConfig(
          id: 'x',
          name: '',
          serverUrl: Uri.parse('http://192.168.1.5:13378'),
          allowInsecureHttp: true,
        ).displayName,
        '192.168.1.5',
      );
    });

    test('replaceAudiobookshelfTokens 只换目标 id，删掉的服务器不会被写回', () {
      final AudiobookshelfServerConfig other = AudiobookshelfServerConfig(
        id: 'srv2',
        name: '',
        serverUrl: Uri.parse('https://other.example.com'),
      );
      const AudiobookshelfTokens next = AudiobookshelfTokens(
        accessToken: 'a2',
        refreshToken: 'r2',
      );
      final List<AudiobookshelfServerConfig> replaced =
          replaceAudiobookshelfTokens(
            <AudiobookshelfServerConfig>[_config(), other],
            'srv1',
            next,
          );
      expect(replaced.first.tokens, next);
      expect(replaced.last.tokens, isNull);
      expect(
        replaceAudiobookshelfTokens(
          <AudiobookshelfServerConfig>[other],
          'srv1',
          next,
        ),
        hasLength(1),
      );
    });
  });
}
