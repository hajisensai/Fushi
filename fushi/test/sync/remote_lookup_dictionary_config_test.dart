import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart'
    show
        RemoteLookupDictionaryConfig,
        kRemoteLookupDictionariesField,
        kRemoteLookupDictionaryConfigAppliedField;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 远端查词请求带本端配置的词典选择（`dictionaries` 字段，按 host 算）：
/// * 只有给了 `dictionaryConfigFor` 且对那台 host 返回非 null 才发字段，否则请求体与
///   旧版逐字相同；
/// * 只发给开着「用这台服务器查词典」（[FushiClientUrl.lookupEnabled]）的地址；
/// * 回包的 `dictionaryConfigApplied` 按 host 记下（老 host 不回 = false）。
void main() {
  late FushiDatabase db;
  late SyncRepository repo;
  late List<({String host, Map<String, Object?> body})> sent;
  late Map<String, Map<String, Object?>> replies;

  Map<String, Object?> dictionaryReply({bool? applied}) => <String, Object?>{
    'type': 'dictionaryResult',
    'result': <String, Object?>{
      'searchTerm': '猫',
      'bestLength': 1,
      'entries': <Object?>[
        <String, Object?>{
          'word': '猫',
          'reading': 'ねこ',
          'meaning': 'cat',
          'dictionaryName': 'Daijirin',
        },
      ],
    },
    if (applied != null) kRemoteLookupDictionaryConfigAppliedField: applied,
  };

  http.Client client() => MockClient((http.Request request) async {
    sent.add((
      host: request.url.host,
      body: jsonDecode(request.body) as Map<String, Object?>,
    ));
    final Map<String, Object?>? reply = replies[request.url.host];
    if (reply == null) return http.Response('down', 503);
    return http.Response.bytes(
      utf8.encode(jsonEncode(reply)),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
    await repo.setFushiClientToken('tok');
    sent = <({String host, Map<String, Object?> body})>[];
    replies = <String, Map<String, Object?>>{};
  });
  tearDown(() => db.close());

  test('addFushiClientUrl：同一 host 的地址全关了查词时，新加的地址继承关', () async {
    // 老配对没有 hostId：身份是去掉结尾 `/` 的地址，带 `/` 的写法是同一台 host。
    await repo.setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(url: 'http://old:1', lookupEnabled: false),
      FushiClientUrl(url: 'http://lan:2', hostId: 'h1', lookupEnabled: false),
      FushiClientUrl(url: 'http://wan:2', hostId: 'h1', lookupEnabled: false),
    ]);
    List<FushiClientUrl> urls = await repo.addFushiClientUrl('http://old:1/');
    expect(urls.last.url, 'http://old:1/');
    expect(urls.last.lookupEnabled, isFalse);

    // 别的 host 的新地址照常默认开。
    urls = await repo.addFushiClientUrl('http://other:3');
    expect(urls.last.lookupEnabled, isTrue);

    // 新地址随后被地址学习归到 h1（h1 的地址全关）⇒ 跟着关。
    urls = await repo.addFushiClientUrl('http://p2p:2');
    expect(urls.last.lookupEnabled, isTrue);
    urls = await repo.updateFushiClientUrls(
      (List<FushiClientUrl> current) => <FushiClientUrl>[
        for (final FushiClientUrl u in current)
          u.url == 'http://p2p:2' ? u.copyWith(hostId: 'h1') : u,
      ],
    );
    final FushiClientUrl p2p = urls.firstWhere(
      (FushiClientUrl u) => u.url == 'http://p2p:2',
    );
    expect(p2p.lookupEnabled, isFalse);
    expect((await repo.getFushiClientUrls()).length, 6);
  });

  test('FushiClientUrl.lookupEnabled：默认 true 不落盘，false 往返保留', () {
    const FushiClientUrl on = FushiClientUrl(url: 'http://a');
    expect(on.toJson().containsKey('lookupEnabled'), isFalse);
    expect(FushiClientUrl.fromJson(on.toJson()).lookupEnabled, isTrue);
    final FushiClientUrl off = on.copyWith(lookupEnabled: false);
    expect(off.toJson()['lookupEnabled'], isFalse);
    expect(FushiClientUrl.fromJson(off.toJson()).lookupEnabled, isFalse);
    expect(off.copyWith(deviceName: 'PC').lookupEnabled, isFalse);
    expect(off.isDictionaryLookupCandidate, isFalse);
    expect(
      remoteDictionaryHostIdOf(const FushiClientUrl(url: ' http://old:1/ ')),
      'http://old:1',
    );
    expect(
      remoteDictionaryHostIdOf(
        const FushiClientUrl(url: 'http://x:1', hostId: 'h'),
      ),
      'h',
    );
  });

  test('传输层候选筛选：predicate 拒掉的地址一律不发', () async {
    await repo.setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(url: 'http://a:1', hostId: 'ha'),
      FushiClientUrl(url: 'http://b:1', hostId: 'hb'),
    ]);
    replies['b'] = <String, Object?>{'ok': true};
    final InterconnectPostOutcome outcome =
        await InterconnectPostTransport(repo: repo, httpClient: client()).post(
          path: '/api/x',
          body: const <String, dynamic>{},
          timeout: const Duration(seconds: 1),
          authErrorMessage: 'x',
          candidateFilter: (FushiClientUrl c) => c.hostId == 'hb',
        );
    expect(sent.map((s) => s.host), <String>['b']);
    expect(outcome.candidate?.hostId, 'hb');

    // 全部被筛掉：不是「不可达」，是「没有候选」。
    sent.clear();
    final InterconnectPostOutcome none =
        await InterconnectPostTransport(repo: repo, httpClient: client()).post(
          path: '/api/x',
          body: const <String, dynamic>{},
          timeout: const Duration(seconds: 1),
          authErrorMessage: 'x',
          candidateFilter: (FushiClientUrl c) => false,
        );
    expect(sent, isEmpty);
    expect(none.allUnreachable, isFalse);
    expect(none.json, isNull);
  });

  test('没给 dictionaryConfigFor：请求体不带 dictionaries（旧行为）', () async {
    await repo.setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(url: 'http://a:1', hostId: 'ha'),
    ]);
    replies['a'] = dictionaryReply();
    final FushiRemoteLookupClient lookup = FushiRemoteLookupClient(
      repo: repo,
      httpClient: client(),
    );
    expect(
      await lookup.searchDictionary(
        term: '猫',
        wildcards: false,
        maximumTerms: 5,
      ),
      isNotNull,
    );
    expect(
      sent.single.body.containsKey(kRemoteLookupDictionariesField),
      isFalse,
    );
    expect(lookup.dictionaryConfigAppliedByHost, isEmpty);
  });

  test('按 host 发各自的选择；返回 null 的 host 不带字段；关掉查词的 host 不发', () async {
    await repo.setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(
        url: 'http://off:1',
        hostId: 'h-off',
        lookupEnabled: false,
      ),
      FushiClientUrl(url: 'http://a:1', hostId: 'ha'),
      FushiClientUrl(url: 'http://b:1', hostId: 'hb'),
    ]);
    // a 503 → 换 b；b 回了结果但没回执（老 host）。
    replies['b'] = dictionaryReply();
    final List<String> asked = <String>[];
    final FushiRemoteLookupClient lookup = FushiRemoteLookupClient(
      repo: repo,
      httpClient: client(),
    );
    await lookup.searchDictionary(
      term: '猫',
      wildcards: false,
      maximumTerms: 5,
      dictionaryConfigFor: (FushiClientUrl candidate) {
        asked.add(candidate.hostId!);
        return candidate.hostId == 'ha'
            ? const RemoteLookupDictionaryConfig(
                excluded: <String>{'Meikyo'},
                order: <String>['Daijirin', 'JMdict'],
              )
            : null;
      },
    );
    expect(sent.map((s) => s.host), <String>['a', 'b']);
    expect(asked, <String>['ha', 'hb']);
    expect(sent[0].body[kRemoteLookupDictionariesField], <String, Object?>{
      'excluded': <Object?>['Meikyo'],
      'order': <Object?>['Daijirin', 'JMdict'],
    });
    expect(sent[1].body.containsKey(kRemoteLookupDictionariesField), isFalse);
    // b 没收到选择：不记回执。
    expect(lookup.dictionaryConfigAppliedByHost, isEmpty);
  });

  test('回执按 host 记：套用了 = true，老 host 不回 = false', () async {
    await repo.setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(url: 'http://a:1', hostId: 'ha'),
    ]);
    const RemoteLookupDictionaryConfig config = RemoteLookupDictionaryConfig(
      excluded: <String>{},
      order: <String>['Daijirin'],
    );
    final FushiRemoteLookupClient lookup = FushiRemoteLookupClient(
      repo: repo,
      httpClient: client(),
    );
    replies['a'] = dictionaryReply(applied: true);
    await lookup.searchDictionary(
      term: '猫',
      wildcards: false,
      maximumTerms: 5,
      dictionaryConfigFor: (_) => config,
    );
    expect(lookup.dictionaryConfigAppliedByHost, <String, bool>{'ha': true});

    replies['a'] = dictionaryReply();
    await lookup.searchDictionary(
      term: '猫',
      wildcards: false,
      maximumTerms: 5,
      dictionaryConfigFor: (_) => config,
    );
    expect(lookup.dictionaryConfigAppliedByHost, <String, bool>{'ha': false});
  });

  test('词典样式 / 媒体端点同样只问开着查词的 host；音频端点不受影响', () async {
    await repo.setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(
        url: 'http://off:1',
        hostId: 'h-off',
        lookupEnabled: false,
      ),
    ]);
    final FushiRemoteLookupClient lookup = FushiRemoteLookupClient(
      repo: repo,
      httpClient: client(),
    );
    expect(await lookup.dictionaryStyles(), isEmpty);
    expect(
      await lookup.searchDictionary(
        term: '猫',
        wildcards: false,
        maximumTerms: 5,
      ),
      isNull,
    );
    expect(sent, isEmpty);
    replies['off'] = <String, Object?>{'type': 'audioResult'};
    await lookup.lookupAudioUrl(expression: '猫', reading: 'ねこ');
    expect(sent.map((s) => s.host), <String>['off']);
  });
}
