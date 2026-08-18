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

  test('search:条目路径来自 parent+name', () async {
    final AListDiscoverySource source = _source(
      MockClient((http.Request request) async {
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

    final ProviderBatchResult<DiscoveryResultPage> result = await source.search(
      const DiscoveryRequest(kind: DiscoveryMediaKind.game, query: 'ATRI'),
    );
    final DiscoveryResourceItem item =
        result.items.single.entries.single as DiscoveryResourceItem;
    expect(item.id, '/guest/其他/ATRI.rar');
    expect(result.items.single.hasMore, isFalse);
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
