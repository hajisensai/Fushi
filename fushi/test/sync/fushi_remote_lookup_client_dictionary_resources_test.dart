import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// [FushiRemoteLookupClient.dictionaryStyles] / [FushiRemoteLookupClient.dictionaryMedia]：
/// 手机遥控查电脑词典时，弹框的样式与媒体只问钉住的那台电脑。
void main() {
  const FushiClientUrl pinned = FushiClientUrl(
    url: 'http://desk:8765',
    hostId: 'desk',
    token: 'desk-token',
  );
  const FushiClientUrl other = FushiClientUrl(
    url: 'http://other:8765',
    hostId: 'other',
    token: 'other-token',
  );

  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[other, pinned]);
  });
  tearDown(() async => db.close());

  http.Response json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );

  test(
    'styles: only the pinned host is asked, whole table by default',
    () async {
      final List<http.Request> requests = <http.Request>[];
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        onlyCandidate: pinned,
        httpClient: MockClient((http.Request request) async {
          requests.add(request);
          return json(<String, dynamic>{
            'type': 'dictionaryStyles',
            'styles': <String, Object>{'明鏡': '.a{}', 'bad': 3},
          });
        }),
      );

      final Map<String, String> styles = await client.dictionaryStyles();

      expect(styles, <String, String>{'明鏡': '.a{}'});
      expect(requests.single.url.host, 'desk');
      expect(requests.single.url.path, '/api/lookup/dictionary/styles');
      expect(jsonDecode(requests.single.body), <String, dynamic>{});
    },
  );

  test('styles: named request filters the reply to the asked names', () async {
    final FushiRemoteLookupClient client = FushiRemoteLookupClient(
      repo: repo,
      onlyCandidate: pinned,
      httpClient: MockClient((http.Request request) async {
        expect(jsonDecode(request.body), <String, dynamic>{
          'dictionaries': <String>['明鏡'],
        });
        return json(<String, dynamic>{
          'type': 'dictionaryStyles',
          'styles': <String, String>{'明鏡': '.a{}', '大辞林': '.b{}'},
        });
      }),
    );
    expect(
      await client.dictionaryStyles(<String>['明鏡', '明鏡']),
      <String, String>{'明鏡': '.a{}'},
    );
  });

  test('styles: an old host without the endpoint yields no styles', () async {
    final FushiRemoteLookupClient client = FushiRemoteLookupClient(
      repo: repo,
      onlyCandidate: pinned,
      httpClient: MockClient((http.Request request) async {
        return http.Response('Not found', 404);
      }),
    );
    expect(await client.dictionaryStyles(), isEmpty);
  });

  test('media: decodes bytes and keeps the server content type', () async {
    final FushiRemoteLookupClient client = FushiRemoteLookupClient(
      repo: repo,
      onlyCandidate: pinned,
      httpClient: MockClient((http.Request request) async {
        expect(request.url.path, '/api/lookup/dictionary/media');
        expect(jsonDecode(request.body), <String, dynamic>{
          'dictionary': '明鏡',
          'path': 'gaiji/a.svg',
        });
        return json(<String, dynamic>{
          'type': 'dictionaryMedia',
          'contentType': 'image/svg+xml',
          'data': base64Encode(utf8.encode('<svg/>')),
        });
      }),
    );

    final RemoteDictionaryMedia? media = await client.dictionaryMedia(
      dictionary: '明鏡',
      path: r'.\gaiji\a.svg',
    );

    expect(media, isNotNull);
    expect(utf8.decode(media!.bytes), '<svg/>');
    expect(media.contentType, 'image/svg+xml');
  });

  test('media: traversal is refused before any request is sent', () async {
    final FushiRemoteLookupClient client = FushiRemoteLookupClient(
      repo: repo,
      onlyCandidate: pinned,
      httpClient: MockClient((http.Request request) async {
        fail('a traversal path must never leave the phone');
      }),
    );
    expect(
      await client.dictionaryMedia(dictionary: '明鏡', path: '../a.png'),
      isNull,
    );
    expect(
      await client.dictionaryMedia(dictionary: '明鏡', path: 'C:/x.png'),
      isNull,
    );
  });

  test(
    'media: malformed replies are rejected, missing media is null',
    () async {
      int call = 0;
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        onlyCandidate: pinned,
        httpClient: MockClient((http.Request request) async {
          call++;
          if (call == 1) return http.Response('Not found', 404);
          return json(<String, dynamic>{
            'type': 'dictionaryMedia',
            'contentType': 'image/png',
            'data': '%%% not base64 %%%',
          });
        }),
      );
      expect(
        await client.dictionaryMedia(dictionary: '明鏡', path: 'a.png'),
        isNull,
      );
      expect(
        await client.dictionaryMedia(dictionary: '明鏡', path: 'a.png'),
        isNull,
      );
    },
  );

  test('a dead pinned host surfaces RemoteLookupUnreachableError', () async {
    final FushiRemoteLookupClient client = FushiRemoteLookupClient(
      repo: repo,
      onlyCandidate: pinned,
      httpClient: MockClient((http.Request request) async {
        expect(request.url.host, 'desk', reason: 'never falls back to other');
        throw const SocketException('Connection refused');
      }),
    );
    await expectLater(
      client.dictionaryStyles(),
      throwsA(isA<RemoteLookupUnreachableError>()),
    );
    await expectLater(
      client.dictionaryMedia(dictionary: '明鏡', path: 'a.png'),
      throwsA(isA<RemoteLookupUnreachableError>()),
    );
  });
}
