import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// BUG-1570 守卫：host 的 /api/lookup/dictionary 响应携带完整
/// DictionarySearchResult.toJson()（truncated / headwordCount / kanjiResults），
/// client 解析时不得丢弃：
/// - truncated 恒 false → remote-first 语义下「加载更多」永不出现（BUG-1472 在
///   远端路径整个失效）；
/// - headwordCount 恒 0 → 分页基数错（BUG-1478 同理失效）；
/// - kanjiResults 恒空 → 远端结果永远没有汉字卡，瘦 client（本地无词典）的
///   kanji-only 命中被当「无结果」丢弃。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<SyncRepository> _repo(FushiDatabase db) async {
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(const <FushiClientUrl>[
    FushiClientUrl(url: 'http://host:8765'),
  ]);
  await repo.setFushiClientToken('tok');
  return repo;
}

http.Response _jsonOk(Map<String, dynamic> body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

void main() {
  test('truncated / headwordCount / kanjiResults 全部透传', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(db);
    // host 侧真实响应形状：result = DictionarySearchResult.toJson() 解码后的 Map
    // （见 buildRemoteDictionaryLookupResponse）。
    final DictionarySearchResult hostResult = DictionarySearchResult(
      searchTerm: '猫',
      bestLength: 1,
      truncated: true,
      headwordCount: 7,
      entries: <DictionaryEntry>[
        DictionaryEntry(word: '猫', reading: 'ねこ', meaning: 'cat'),
      ],
      kanjiResults: const <FushiKanjiResult>[
        FushiKanjiResult(
          character: '猫',
          onyomi: 'ビョウ',
          kunyomi: 'ねこ',
          radical: '犭',
          strokes: 11,
          meanings: <String>['cat'],
          dictName: 'KANJIDIC',
        ),
      ],
    );
    final FushiRemoteLookupClient client = FushiRemoteLookupClient(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        return _jsonOk(<String, dynamic>{
          'type': 'dictionaryResult',
          'result': jsonDecode(hostResult.toJson()),
          'popupJson': '{"html":"ok"}',
        });
      }),
    );

    final DictionarySearchResult? result = await client.searchDictionary(
      term: '猫',
      wildcards: false,
      maximumTerms: 10,
    );

    expect(result, isNotNull);
    expect(result!.truncated, isTrue, reason: '截断标志必须透传，否则「加载更多」在远端路径永不出现');
    expect(result.headwordCount, 7, reason: '词头数必须透传，分页递增以它为基数（BUG-1478）');
    expect(result.kanjiResults, hasLength(1), reason: '汉字卡数据必须透传');
    expect(result.kanjiResults.single.character, '猫');
    expect(result.kanjiResults.single.strokes, 11);
    expect(result.entries.single.meaning, 'cat');
  });

  test('kanji-only 远端结果（无词条）不再被当「无结果」丢弃', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(db);
    final DictionarySearchResult kanjiOnly = DictionarySearchResult(
      searchTerm: '狛',
      kanjiResults: const <FushiKanjiResult>[
        FushiKanjiResult(
          character: '狛',
          onyomi: 'ハク',
          kunyomi: 'こま',
          radical: '犭',
          strokes: 8,
          meanings: <String>['archaic guardian dog'],
          dictName: 'KANJIDIC',
        ),
      ],
    );
    final FushiRemoteLookupClient client = FushiRemoteLookupClient(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        return _jsonOk(<String, dynamic>{
          'type': 'dictionaryResult',
          'result': jsonDecode(kanjiOnly.toJson()),
          'popupJson': null,
        });
      }),
    );

    final DictionarySearchResult? result = await client.searchDictionary(
      term: '狛',
      wildcards: false,
      maximumTerms: 10,
    );

    expect(result, isNotNull,
        reason: '瘦 client 本地没有汉字词典——远端 kanji-only 命中是唯一数据源，'
            '不得因 entries 为空判「无结果」（BUG-1570）');
    expect(result!.entries, isEmpty);
    expect(result.kanjiResults.single.character, '狛');
  });

  test('老 host 缺字段时保持默认（不破坏兼容）', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(db);
    final FushiRemoteLookupClient client = FushiRemoteLookupClient(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        return _jsonOk(<String, dynamic>{
          'type': 'dictionaryResult',
          'result': <String, dynamic>{
            'searchTerm': '猫',
            'bestLength': 1,
            'scrollPosition': 0,
            'entries': <String>[
              DictionaryEntry(word: '猫', reading: 'ねこ', meaning: 'cat')
                  .toJson(),
            ],
          },
          'popupJson': null,
        });
      }),
    );

    final DictionarySearchResult? result = await client.searchDictionary(
      term: '猫',
      wildcards: false,
      maximumTerms: 10,
    );

    expect(result, isNotNull);
    expect(result!.truncated, isFalse);
    expect(result.headwordCount, 0);
    expect(result.kanjiResults, isEmpty);
  });
}
