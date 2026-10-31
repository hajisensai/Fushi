import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 远程查词带上**原文自带振假名**（wire 字段 `ruby`，`[{s, e, r}]`，以 term 为坐标系，
/// 可选）：浏览器扩展 / 互联客户端把来源 `<ruby>` 的读音交给 host，host 让引擎把读音
/// 吻合的同长度候选排前面。
///
/// 兼容契约：请求不带 ruby / service 不认识 ruby（旧实现、测试替身）时一律走旧方法；
/// 分派只在 `searchRemoteDictionary*ForRequest` 一处。

/// 只实现旧接口 + popup 快路径的 service（旧 host 实现 / 测试替身）。
class _LegacyPopupLookup
    implements FushiRemoteLookupService, FushiRemotePopupLookupService {
  final List<String> calls = <String>[];

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    calls.add('full');
    return DictionarySearchResult(searchTerm: term, bestLength: 1);
  }

  @override
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopup({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    calls.add('popup');
    return const RemoteDictionaryPopupLookup(popupJson: '[]', bestLength: 1);
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}

/// 只实现旧完整查词接口（没有 popup 快路径）、但认识 ruby 的 service。
class _RubyOnlyLookup
    implements FushiRemoteLookupService, FushiRemoteRubyLookupService {
  final List<String> calls = <String>[];
  final List<List<FushiRubySpan>> spans = <List<FushiRubySpan>>[];
  final List<String?> languages = <String?>[];
  RemoteDictionaryPopupTiming? lastTiming;

  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    calls.add('full');
    return DictionarySearchResult(searchTerm: term, bestLength: 1);
  }

  @override
  Future<DictionarySearchResult?> searchDictionaryWithRuby({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required List<FushiRubySpan> rubySpans,
    String? language,
  }) async {
    calls.add('full-ruby');
    spans.add(rubySpans);
    languages.add(language);
    return DictionarySearchResult(searchTerm: term, bestLength: 3);
  }

  @override
  Future<RemoteDictionaryPopupLookup?> searchDictionaryPopupWithRuby({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    required List<FushiRubySpan> rubySpans,
    String? language,
    RemoteDictionaryPopupTiming? timing,
  }) async {
    calls.add('popup-ruby');
    spans.add(rubySpans);
    languages.add(language);
    lastTiming = timing;
    return const RemoteDictionaryPopupLookup(popupJson: '[]', bestLength: 3);
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}

const List<Map<String, Object>> _wireRuby = <Map<String, Object>>[
  <String, Object>{'s': 0, 'e': 1, 'r': 'せわ'},
];
const List<FushiRubySpan> _ruby = <FushiRubySpan>[
  FushiRubySpan(start: 0, end: 1, reading: 'せわ'),
];

void main() {
  group('remoteLookupRubySpansOf', () {
    test('读 `[{s, e, r}]`，畸形项丢弃', () {
      expect(
        remoteLookupRubySpansOf(<String, dynamic>{
          'ruby': <Object?>[
            <String, Object?>{'s': 0, 'e': 1, 'r': ' せわ '},
            <String, Object?>{'s': 2, 'e': 2, 'r': 'x'},
            <String, Object?>{'s': 0, 'e': 1},
            'junk',
          ],
        }),
        _ruby,
      );
    });
    test('缺省 / 非数组 ⇒ 空', () {
      expect(remoteLookupRubySpansOf(<String, dynamic>{}), isEmpty);
      expect(remoteLookupRubySpansOf(<String, dynamic>{'ruby': 'x'}), isEmpty);
    });
  });

  group('buildRemoteDictionaryLookupResponse 按 ruby 分派', () {
    test('完整查词：带 ruby + service 认识 ⇒ WithRuby，区间与语言照传', () async {
      final _RubyOnlyLookup lookup = _RubyOnlyLookup();
      final Map<String, dynamic> r = await buildRemoteDictionaryLookupResponse(
        <String, dynamic>{'term': '忙しい', 'ruby': _wireRuby, 'language': 'ja'},
        lookup: lookup,
      );
      expect(lookup.calls, <String>['full-ruby']);
      expect(lookup.spans.single, _ruby);
      expect(lookup.languages, <String?>['ja']);
      expect((r['result'] as Map<String, dynamic>)['bestLength'], 3);
    });

    test('popupOnly：认识 ruby 的 service 即使没有旧 popup 快路径也走 popup-ruby', () async {
      final _RubyOnlyLookup lookup = _RubyOnlyLookup();
      final RemoteDictionaryPopupTiming timing = RemoteDictionaryPopupTiming();
      final Map<String, dynamic> r = await buildRemoteDictionaryLookupResponse(
        <String, dynamic>{'term': '忙しい', 'popupOnly': true, 'ruby': _wireRuby},
        lookup: lookup,
        popupTiming: timing,
      );
      expect(lookup.calls, <String>['popup-ruby']);
      expect(lookup.spans.single, _ruby);
      expect(lookup.languages, <String?>[null]);
      expect(identical(lookup.lastTiming, timing), isTrue);
      expect(r['popupJson'], '[]');
      expect((r['result'] as Map<String, dynamic>)['bestLength'], 3);
    });

    test('不带 ruby / 空数组 ⇒ 旧方法（旧请求行为不变）', () async {
      final _RubyOnlyLookup lookup = _RubyOnlyLookup();
      await buildRemoteDictionaryLookupResponse(<String, dynamic>{
        'term': '忙しい',
      }, lookup: lookup);
      await buildRemoteDictionaryLookupResponse(<String, dynamic>{
        'term': '忙しい',
        'ruby': <Object?>[],
      }, lookup: lookup);
      // 无 ruby 时 popupOnly 也没有快路径（这个替身没实现旧 popup 接口）⇒ 完整查词。
      await buildRemoteDictionaryLookupResponse(<String, dynamic>{
        'term': '忙しい',
        'popupOnly': true,
      }, lookup: lookup);
      expect(lookup.calls, <String>['full', 'full', 'full']);
      expect(lookup.spans, isEmpty);
    });

    test('带 ruby 但 service 不认识 ruby ⇒ 回落旧方法', () async {
      final _LegacyPopupLookup lookup = _LegacyPopupLookup();
      await buildRemoteDictionaryLookupResponse(<String, dynamic>{
        'term': '忙しい',
        'ruby': _wireRuby,
      }, lookup: lookup);
      await buildRemoteDictionaryLookupResponse(<String, dynamic>{
        'term': '忙しい',
        'popupOnly': true,
        'ruby': _wireRuby,
      }, lookup: lookup);
      expect(lookup.calls, <String>['full', 'popup']);
    });

    test('record=true 时 popupOnly 走完整查词，ruby 照带', () async {
      final _RubyOnlyLookup lookup = _RubyOnlyLookup();
      await buildRemoteDictionaryLookupResponse(<String, dynamic>{
        'term': '忙しい',
        'popupOnly': true,
        'record': true,
        'ruby': _wireRuby,
      }, lookup: lookup);
      expect(lookup.calls, <String>['full-ruby']);
      expect(lookup.spans.single, _ruby);
    });
  });

  group('FushiRemoteLookupClient.searchDictionary 发出 ruby', () {
    const FushiClientUrl host = FushiClientUrl(
      url: 'http://desk:8765',
      hostId: 'desk',
      token: 'desk-token',
    );
    late FushiDatabase db;
    late SyncRepository repo;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      repo = SyncRepository(db);
      await repo.setFushiClientUrls(<FushiClientUrl>[host]);
    });
    tearDown(() async => db.close());

    Future<Map<String, dynamic>> sentBody(List<FushiRubySpan> ruby) async {
      Map<String, dynamic>? body;
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        onlyCandidate: host,
        httpClient: MockClient((http.Request request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, dynamic>{
                'type': 'dictionaryResult',
                'result': null,
              }),
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );
      await client.searchDictionary(
        term: '忙しい',
        wildcards: false,
        maximumTerms: 5,
        rubySpans: ruby,
      );
      return body!;
    }

    test('非空 ⇒ body 带 ruby（wire 形态，可被 host 原样解析回来）', () async {
      final Map<String, dynamic> body = await sentBody(_ruby);
      expect(body[kRemoteLookupRubyField], _wireRuby);
      expect(remoteLookupRubySpansOf(body), _ruby);
      expect(body['term'], '忙しい');
    });

    test('空 ⇒ 不发该字段（与旧客户端请求体逐字相同）', () async {
      expect(
        (await sentBody(
          const <FushiRubySpan>[],
        )).containsKey(kRemoteLookupRubyField),
        isFalse,
      );
    });
  });
}
