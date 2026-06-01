import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_client.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

Future<SyncRepository> _repo({
  required HibikiDatabase db,
  required List<HibikiClientUrl> urls,
  String token = 'tok',
}) async {
  final SyncRepository repo = SyncRepository(db);
  await repo.setHibikiClientUrls(urls);
  await repo.setHibikiClientToken(token);
  return repo;
}

void main() {
  test('dictionary lookup fails over enabled candidate urls', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <HibikiClientUrl>[
        HibikiClientUrl(url: 'http://lan:8765'),
        HibikiClientUrl(url: 'http://wan:8765'),
      ],
    );
    final List<String> requestedHosts = <String>[];
    final HibikiRemoteLookupClient client = HibikiRemoteLookupClient(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        requestedHosts.add(request.url.host);
        if (request.url.host == 'lan') {
          return http.Response('down', 503);
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'type': 'dictionaryResult',
            'result': <String, dynamic>{
              'searchTerm': '猫',
              'bestLength': 0,
              'scrollPosition': 0,
              'entries': <String>[
                DictionaryEntry(
                  word: '猫',
                  reading: 'ねこ',
                  meaning: 'cat',
                ).toJson(),
              ],
            },
            'popupJson': '{"html":"ok"}',
          })),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    );

    final DictionarySearchResult? result = await client.searchDictionary(
      term: '猫',
      wildcards: false,
      maximumTerms: 10,
    );

    expect(requestedHosts, <String>['lan', 'wan']);
    expect(result, isNotNull);
    expect(result!.entries.single.meaning, 'cat');
    expect(result.popupJson, '{"html":"ok"}');
  });

  test('401 stops lookup instead of trying another address with same token',
      () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <HibikiClientUrl>[
        HibikiClientUrl(url: 'http://lan:8765'),
        HibikiClientUrl(url: 'http://wan:8765'),
      ],
    );
    final List<String> requestedHosts = <String>[];
    final HibikiRemoteLookupClient client = HibikiRemoteLookupClient(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        requestedHosts.add(request.url.host);
        return http.Response('unauthorized', 401);
      }),
    );

    await expectLater(
      client.searchDictionary(
        term: '猫',
        wildcards: false,
        maximumTerms: 10,
      ),
      throwsA(isA<SyncAuthError>()),
    );
    expect(requestedHosts, <String>['lan']);
  });

  test('remote audio lookup returns url and treats 404 as unsupported',
      () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <HibikiClientUrl>[
        HibikiClientUrl(url: 'http://old:8765'),
        HibikiClientUrl(url: 'http://new:8765'),
      ],
    );
    final List<String> requestedHosts = <String>[];
    final HibikiRemoteLookupClient client = HibikiRemoteLookupClient(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        requestedHosts.add(request.url.host);
        if (request.url.host == 'old') return http.Response('missing', 404);
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'type': 'audioResult',
            'url': 'http://new:8765/api/lookup/audio/file?id=abc',
            'contentType': 'audio/mpeg',
          })),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    );

    final String? url = await client.lookupAudioUrl(
      expression: '猫',
      reading: 'ねこ',
    );

    expect(requestedHosts, <String>['old', 'new']);
    expect(url, 'http://new:8765/api/lookup/audio/file?id=abc');
  });
}
