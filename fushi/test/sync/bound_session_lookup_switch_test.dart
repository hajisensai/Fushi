import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// BUG-4962：「用这台服务器查词典」（[FushiClientUrl.lookupEnabled]）只管从已配对 host
/// 里挑词典来源。绑定会话（游戏串流 / 视频遥控）查的是那台 host 上正在播放的内容，
/// 必须仍由它回答；此前开关关掉后这两条路径一次请求都不发，查词恒无结果。
void main() {
  const FushiClientUrl hostOff = FushiClientUrl(
    url: 'http://desk:8765',
    hostId: 'desk',
    token: 't',
    lookupEnabled: false,
  );

  late FushiDatabase db;
  late SyncRepository repo;
  late int requests;
  late MockClient host;

  setUp(() async {
    resetInterconnectRaceCache();
    debugInterconnectAddressProbeOverride =
        (FushiClientUrl candidate, String? hostId) async => true;
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[hostOff]);
    requests = 0;
    host = MockClient((http.Request request) async {
      requests++;
      final Map<String, dynamic> body =
          jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'type': 'dictionaryResult',
            'result': <String, dynamic>{
              'searchTerm': body['term'],
              'bestLength': 3,
              'entries': <String>[
                DictionaryEntry(
                  dictionaryName: 'JMdict',
                  word: '食べる',
                  reading: 'たべる',
                  meaning: 'to eat',
                ).toJson(),
              ],
            },
            'dictionaryStylesRevision': 'r',
            'dictionaryStyles': <String, String>{},
          }),
        ),
        200,
        headers: const <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );
    });
  });
  tearDown(() async {
    debugInterconnectAddressProbeOverride = null;
    resetInterconnectRaceCache();
    await db.close();
  });

  test('游戏串流：串流 host 关了查词开关，仍由它回答', () async {
    final DictionarySearchResult? result =
        await InterconnectGameStreamDictionaryLookup(
          repo: repo,
          peer: hostOff,
          httpClient: host,
        ).searchDictionary(term: '食べる', wildcards: false, maximumTerms: 20);
    expect(requests, 1);
    expect(result?.entries.single.word, '食べる');
  });

  test('视频遥控（绑定 host 的查词客户端）：关了开关仍由它回答', () async {
    final DictionarySearchResult? result = await FushiRemoteLookupClient(
      repo: repo,
      onlyCandidate: hostOff,
      httpClient: host,
    ).searchDictionary(term: '食べる', wildcards: false, maximumTerms: 20);
    expect(requests, 1);
    expect(result?.entries.single.word, '食べる');
  });

  test('普通查词（挑来源）：关了开关的 host 照旧不问', () async {
    final DictionarySearchResult? result = await FushiRemoteLookupClient(
      repo: repo,
      httpClient: host,
    ).searchDictionary(term: '食べる', wildcards: false, maximumTerms: 20);
    expect(requests, 0);
    expect(result, isNull);
  });
}
