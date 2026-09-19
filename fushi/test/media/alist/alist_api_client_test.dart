/// AListApiClient：翻页拉全、total 失真不死循环、token 失效重登一次。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/alist/alist_api_client.dart';

http.Response _json(Map<String, dynamic> envelope) => http.Response.bytes(
      utf8.encode(jsonEncode(envelope)),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );

Map<String, dynamic> _ok(Map<String, dynamic> data) => <String, dynamic>{
      'code': 200,
      'message': 'success',
      'data': data,
    };

void main() {
  test('listAll pages until total is reached', () async {
    final List<int> pages = <int>[];
    final AListApiClient api = AListApiClient(
      baseUrl: 'https://od.example.com/',
      providerId: 't',
      client: MockClient((http.Request request) async {
        expect(request.url.toString(), 'https://od.example.com/api/fs/list');
        final Map<String, dynamic> body =
            jsonDecode(request.body) as Map<String, dynamic>;
        final int page = body['page'] as int;
        pages.add(page);
        return _json(_ok(<String, dynamic>{
          'content': <Map<String, dynamic>>[
            for (int i = 0; i < 2; i++)
              <String, dynamic>{'name': 'p$page-$i', 'is_dir': false},
          ],
          'total': 5,
        }));
      }),
    );
    final List<AListEntry> all = await api.listAll('/x', perPage: 2);
    expect(pages, <int>[1, 2, 3]);
    expect(all.map((AListEntry e) => e.name).toList(), <String>[
      'p1-0',
      'p1-1',
      'p2-0',
      'p2-1',
      'p3-0',
      'p3-1',
    ]);
  });

  test('listAll stops on a short page even if total is bogus', () async {
    int calls = 0;
    final AListApiClient api = AListApiClient(
      baseUrl: 'https://od.example.com',
      providerId: 't',
      client: MockClient((http.Request request) async {
        calls++;
        return _json(_ok(<String, dynamic>{
          'content': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'only', 'is_dir': true},
          ],
          'total': 999,
        }));
      }),
    );
    final List<AListEntry> all = await api.listAll('/', perPage: 50);
    expect(calls, 1);
    expect(all.single.isDir, isTrue);
  });

  test('listAll keeps paging on full pages when the driver reports total 0',
      () async {
    // 部分存储驱动恒报 total: 0 却真有内容——满页时不能被 0 截断成一页，
    // 短页才收尾。
    final List<int> pages = <int>[];
    final AListApiClient api = AListApiClient(
      baseUrl: 'https://od.example.com',
      providerId: 't',
      client: MockClient((http.Request request) async {
        final Map<String, dynamic> body =
            jsonDecode(request.body) as Map<String, dynamic>;
        final int page = body['page'] as int;
        pages.add(page);
        final int count = page < 3 ? 2 : 1;
        return _json(_ok(<String, dynamic>{
          'content': <Map<String, dynamic>>[
            for (int i = 0; i < count; i++)
              <String, dynamic>{'name': 'p$page-$i', 'is_dir': false},
          ],
          'total': 0,
        }));
      }),
    );
    final List<AListEntry> all = await api.listAll('/x', perPage: 2);
    expect(pages, <int>[1, 2, 3]);
    expect(all.length, 5);
  });

  test('listAll caps the page count when total and page length both lie',
      () async {
    int calls = 0;
    final AListApiClient api = AListApiClient(
      baseUrl: 'https://od.example.com',
      providerId: 't',
      client: MockClient((http.Request request) async {
        calls++;
        return _json(_ok(<String, dynamic>{
          'content': <Map<String, dynamic>>[
            for (int i = 0; i < 2; i++)
              <String, dynamic>{'name': 'x$calls-$i', 'is_dir': false},
          ],
          'total': 0,
        }));
      }),
    );
    await api.listAll('/x', perPage: 2);
    expect(calls, kAListListAllMaxPages);
  });

  test('401 with an account: re-login once and retry with the new token',
      () async {
    final List<String?> seenAuth = <String?>[];
    int logins = 0;
    final AListApiClient api = AListApiClient(
      baseUrl: 'https://od.example.com',
      providerId: 't',
      username: 'alice',
      password: 'pw',
      client: MockClient((http.Request request) async {
        if (request.url.path == '/api/auth/login') {
          logins++;
          return _json(_ok(<String, dynamic>{'token': 'tok$logins'}));
        }
        seenAuth.add(request.headers['Authorization']);
        if (request.headers['Authorization'] == 'tok1') {
          return _json(<String, dynamic>{'code': 401, 'message': 'expired'});
        }
        return _json(_ok(<String, dynamic>{'raw_url': 'https://cdn/x?sign=1'}));
      }),
    );
    final AListFileLink link = await api.getFile('/x.mkv');
    expect(link.rawUrl, 'https://cdn/x?sign=1');
    expect(logins, 2);
    expect(seenAuth, <String?>['tok1', 'tok2']);
  });

  test('guest hit by 401 surfaces unauthorized (no login to retry)', () async {
    final AListApiClient api = AListApiClient(
      baseUrl: 'https://od.example.com',
      providerId: 't',
      client: MockClient((http.Request request) async =>
          _json(<String, dynamic>{'code': 401, 'message': 'guest disabled'})),
    );
    await expectLater(
      api.list('/'),
      throwsA(isA<ExternalProviderFailure>().having(
        (ExternalProviderFailure f) => f.kind,
        'kind',
        ExternalProviderFailureKind.unauthorized,
      )),
    );
  });
}
