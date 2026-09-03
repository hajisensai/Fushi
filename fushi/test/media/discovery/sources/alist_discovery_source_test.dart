import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/sources/alist_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';

http.Response _json(Map<String, dynamic> envelope) => http.Response.bytes(
      utf8.encode(jsonEncode(envelope)),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );

AListDiscoverySource _source(MockClient client) => AListDiscoverySource(
      id: 'alist-test',
      displayName: 'Test AList',
      baseUrl: 'https://alist.example.com/',
      kinds: const <DiscoveryMediaKind>[DiscoveryMediaKind.game],
      client: client,
    );

void main() {
  test('browse:目录/文件分形,分页由 total 决定,文件 payload 留待 resolve', () async {
    Map<String, dynamic>? capturedBody;
    final AListDiscoverySource source = _source(
      MockClient((http.Request request) async {
        expect(request.url.path, '/api/fs/list');
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _json(<String, dynamic>{
          'code': 200,
          'message': 'success',
          'data': <String, dynamic>{
            'content': <Map<String, dynamic>>[
              <String, dynamic>{'name': '年份合集', 'is_dir': true, 'size': 0},
              <String, dynamic>{
                'name': 'game.rar',
                'is_dir': false,
                'size': 12345,
                'modified': '2025-11-19T06:23:16.457Z',
              },
            ],
            'total': 5,
            'provider': 'Alias',
          },
        });
      }),
    );

    final ProviderBatchResult<DiscoveryResultPage> result = await source.browse(
      const DiscoveryRequest(
        kind: DiscoveryMediaKind.game,
        path: '/其他',
        pageSize: 2,
      ),
    );

    expect(capturedBody!['path'], '/其他');
    expect(capturedBody!['per_page'], 2);

    final DiscoveryResultPage page = result.items.single;
    expect(page.hasMore, isTrue, reason: 'total 5 > page1*2');
    final DiscoveryFolder folder = page.entries[0] as DiscoveryFolder;
    expect(folder.path, '/其他/年份合集');
    final DiscoveryResourceItem file = page.entries[1] as DiscoveryResourceItem;
    expect(file.id, '/其他/game.rar');
    expect(file.payload, isNull, reason: '直链临期,下载时才 resolve');
    expect(file.payloadKind, DiscoveryPayloadKind.httpFile);
    expect(file.sizeBytes, 12345);
    expect(file.dateText, '2025-11-19');
  });

  // BUG-1771：AList 的 `fs/search` 在**用户根命名空间**里返回 `parent`
  // （erogame.space 的 guest 是 `/guest`），而 `fs/list` / `fs/get` 收的是**相对
  // 该根**的路径。原样拿来用，站点对搜索结果里的每个目录和每个文件都回
  // `object not found`：目录一个都打不开、文件一个都下不了。
  //
  // 前缀靠 `fs/list '/'` 的根目录名反推（不问 `/api/me`：实测该站点直连时
  // `/api/me` 3/3 连接超时，而 fs/list、fs/search 正常）。
  //
  // 三条成对/成组，缺一条就能被糊弄：只有①会被「一律剥首段」骗过；只有②会被
  // 「永不剥」骗过；③钉住「推断失败不许把搜索本身拖挂」。

  /// 建一个按 path 分发的 MockClient：根列表 [rootNames]，搜索结果 [searchContent]。
  MockClient mockSite({
    required List<String> rootNames,
    required List<Map<String, dynamic>> searchContent,
    List<String>? seenPaths,
    http.Response Function()? listOverride,
  }) {
    return MockClient((http.Request request) async {
      seenPaths?.add(request.url.path);
      if (request.url.path == '/api/fs/list') {
        if (listOverride != null) return listOverride();
        return _json(<String, dynamic>{
          'code': 200,
          'message': 'success',
          'data': <String, dynamic>{
            'content': <Map<String, dynamic>>[
              for (final String n in rootNames)
                <String, dynamic>{'name': n, 'is_dir': true, 'size': 0},
            ],
            'total': rootNames.length,
          },
        });
      }
      expect(request.url.path, '/api/fs/search');
      return _json(<String, dynamic>{
        'code': 200,
        'message': 'success',
        'data': <String, dynamic>{
          'content': searchContent,
          'total': searchContent.length,
        },
      });
    });
  }

  test('search:根名字落在第 2 段 → 剥掉前缀(否则 fs/list/fs/get 全 404)', () async {
    final List<String> seen = <String>[];
    final AListDiscoverySource source = _source(
      mockSite(
        rootNames: <String>['其他', '年份合集'],
        seenPaths: seen,
        searchContent: <Map<String, dynamic>>[
          <String, dynamic>{
            'parent': '/guest/其他',
            'name': 'ATRI.rar',
            'is_dir': false,
            'size': 1,
          },
          <String, dynamic>{
            'parent': '/guest',
            'name': '其他',
            'is_dir': true,
            'size': 0,
          },
        ],
      ),
    );

    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.game, query: 'ATRI'),
    );
    expect(seen, contains('/api/fs/list'), reason: '要靠根列表反推前缀');
    final List<DiscoveryEntry> entries = result.items.single.entries;
    expect((entries[0] as DiscoveryResourceItem).id, '/其他/ATRI.rar');
    // parent 恰好就是前缀本身 → 归一成根，不能变成空串。
    expect((entries[1] as DiscoveryFolder).path, '/其他');
    expect(result.items.single.hasMore, isFalse);
  });

  test('search:根名字已在第 1 段 → 路径原样,不许乱剥', () async {
    // 站点没开用户根：search 的 parent 与 fs/list 同命名空间，首段就是真实根目录。
    final AListDiscoverySource source = _source(
      mockSite(
        rootNames: <String>['guest', '年份合集'],
        searchContent: <Map<String, dynamic>>[
          <String, dynamic>{
            'parent': '/guest/其他',
            'name': 'ATRI.rar',
            'is_dir': false,
            'size': 1,
          },
        ],
      ),
    );

    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.game, query: 'ATRI'),
    );
    expect(
      (result.items.single.entries.single as DiscoveryResourceItem).id,
      '/guest/其他/ATRI.rar',
      reason: '这里的 guest 是真实根目录名，不是命名空间前缀',
    );
  });

  test('search:根目录列不出来时退回不剥前缀，不让整个搜索失败', () async {
    final AListDiscoverySource source = _source(
      mockSite(
        rootNames: const <String>[],
        listOverride: () => http.Response('nope', 500),
        searchContent: <Map<String, dynamic>>[
          <String, dynamic>{
            'parent': '/guest/其他',
            'name': 'ATRI.rar',
            'is_dir': false,
            'size': 1,
          },
        ],
      ),
    );

    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.game, query: 'ATRI'),
    );
    expect(
      (result.items.single.entries.single as DiscoveryResourceItem).id,
      '/guest/其他/ATRI.rar',
    );
  });

  test('search:前缀探测失败后必须能重试，不许一次失败就永久放弃', () async {
    // 回归守卫：曾经用「_basePath 空串 + 一个 _basePathProbed 布尔」两份状态表示
    // 一件事，而布尔在**开始尝试**时就置位 —— 于是根目录列不出来的那一次直接把
    // 本会话的推断永久关掉，之后每次搜索拿到的目录都打不开、文件都下不了。
    // 现在 _basePath 可空，只有真正得出结论才落值。
    int listCalls = 0;
    final AListDiscoverySource source = _source(
      MockClient((http.Request request) async {
        if (request.url.path == '/api/fs/list') {
          listCalls++;
          if (listCalls == 1) return http.Response('nope', 500); // 首次抖动
          return _json(<String, dynamic>{
            'code': 200,
            'message': 'success',
            'data': <String, dynamic>{
              'content': <Map<String, dynamic>>[
                <String, dynamic>{'name': '其他', 'is_dir': true, 'size': 0},
              ],
              'total': 1,
            },
          });
        }
        expect(request.url.path, '/api/fs/search');
        return _json(<String, dynamic>{
          'code': 200,
          'message': 'success',
          'data': <String, dynamic>{
            'content': <Map<String, dynamic>>[
              <String, dynamic>{
                'parent': '/guest/其他',
                'name': 'ATRI.rar',
                'is_dir': false,
                'size': 1,
              },
            ],
            'total': 1,
          },
        });
      }),
    );

    const DiscoveryRequest req =
        DiscoveryRequest(kind: DiscoveryMediaKind.game, query: 'ATRI');

    final ProviderBatchResult<DiscoveryResultPage> first =
        await source.search(req);
    expect(
      (first.items.single.entries.single as DiscoveryResourceItem).id,
      '/guest/其他/ATRI.rar',
      reason: '首次探测失败 → 退回不剥前缀的老行为，搜索本身照常成功',
    );

    final ProviderBatchResult<DiscoveryResultPage> second =
        await source.search(req);
    expect(
      (second.items.single.entries.single as DiscoveryResourceItem).id,
      '/其他/ATRI.rar',
      reason: '第二次必须重新探测并剥掉 /guest；若这里仍是 /guest/... 说明又退回了'
          '「一次失败即永久放弃」',
    );
    expect(listCalls, 2, reason: '第二次搜索必须真的再问一次根目录');
  });

  test('resolvePayload 走 fs/get 取 raw_url', () async {
    final AListDiscoverySource source = _source(
      MockClient((http.Request request) async {
        expect(request.url.path, '/api/fs/get');
        expect(
          (jsonDecode(request.body) as Map<String, dynamic>)['path'],
          '/其他/game.rar',
        );
        return _json(<String, dynamic>{
          'code': 200,
          'message': 'success',
          'data': <String, dynamic>{
            'name': 'game.rar',
            'size': 999,
            'raw_url': 'https://cdn.example.com/game.rar?sign=abc',
          },
        });
      }),
    );

    final DiscoveryPayload payload = await source.resolvePayload(
      const DiscoveryResourceItem(
        sourceId: 'alist-test',
        title: 'game.rar',
        id: '/其他/game.rar',
        kind: DiscoveryMediaKind.game,
        payloadKind: DiscoveryPayloadKind.httpFile,
      ),
    );
    final DiscoveryHttpPayload http0 = payload as DiscoveryHttpPayload;
    expect(http0.url, 'https://cdn.example.com/game.rar?sign=abc');
    expect(http0.fileName, 'game.rar');
    expect(http0.sizeBytes, 999);
  });

  test('信封 code 非 200 抛脱敏失败', () async {
    final AListDiscoverySource source = _source(
      MockClient(
        (http.Request request) async => _json(<String, dynamic>{
          'code': 500,
          'message': 'failed to get obj: object not found',
          'data': null,
        }),
      ),
    );

    expect(
      () => source.browse(
        const DiscoveryRequest(kind: DiscoveryMediaKind.game, path: '/x'),
      ),
      throwsA(
        isA<ExternalProviderFailure>().having(
          (ExternalProviderFailure f) => f.kind,
          'kind',
          ExternalProviderFailureKind.invalidResponse,
        ),
      ),
    );
  });
}
