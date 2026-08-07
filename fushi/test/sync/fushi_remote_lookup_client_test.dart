import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

FushiDatabase _testDb() {
  return FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

Future<SyncRepository> _repo({
  required FushiDatabase db,
  required List<FushiClientUrl> urls,
  String token = 'tok',
}) async {
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(urls);
  await repo.setFushiClientToken(token);
  return repo;
}

void main() {
  test('dictionary lookup fails over enabled candidate urls', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[
        FushiClientUrl(url: 'http://lan:8765'),
        FushiClientUrl(url: 'http://wan:8765'),
      ],
    );
    final List<String> requestedHosts = <String>[];
    final FushiRemoteLookupClient client = FushiRemoteLookupClient(
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
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[
        FushiClientUrl(url: 'http://lan:8765'),
        FushiClientUrl(url: 'http://wan:8765'),
      ],
    );
    final List<String> requestedHosts = <String>[];
    final FushiRemoteLookupClient client = FushiRemoteLookupClient(
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
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[
        FushiClientUrl(url: 'http://old:8765'),
        FushiClientUrl(url: 'http://new:8765'),
      ],
    );
    final List<String> requestedHosts = <String>[];
    final FushiRemoteLookupClient client = FushiRemoteLookupClient(
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

  // TODO-961 gap①：https 带指纹的候选必须走钉扎 client，即使外部注入了共享
  // keep-alive client（生产 AppModel 就是注入的）——注入 client 只服务明文 http。
  test('https candidate with fingerprint always uses the pinned client',
      () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[
        FushiClientUrl(
          url: 'https://pinned:38765',
          fingerprintSha256: 'aa:bb:cc',
        ),
        FushiClientUrl(url: 'http://plain:38765'),
      ],
    );

    http.Response okDictionary(http.Request request) => http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'type': 'dictionaryResult',
            'result': <String, dynamic>{
              'searchTerm': '猫',
              'bestLength': 0,
              'scrollPosition': 0,
              'entries': <String>[
                DictionaryEntry(word: '猫', reading: 'ねこ', meaning: 'cat')
                    .toJson(),
              ],
            },
          })),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );

    final List<String> injectedClientHosts = <String>[];
    final List<String> pinnedFingerprints = <String>[];
    final List<String> pinnedClientHosts = <String>[];

    final FushiRemoteLookupClient client = FushiRemoteLookupClient(
      repo: repo,
      // 生产同款：注入共享明文 keep-alive client（TODO-744）。
      httpClient: MockClient((http.Request request) async {
        injectedClientHosts.add(request.url.host);
        return http.Response('should not serve pinned candidates', 503);
      }),
      pinnedClientFactory: (String expectedFingerprint) {
        pinnedFingerprints.add(expectedFingerprint);
        return MockClient((http.Request request) async {
          pinnedClientHosts.add(request.url.host);
          return okDictionary(request);
        });
      },
    );

    final DictionarySearchResult? result = await client.searchDictionary(
      term: '猫',
      wildcards: false,
      maximumTerms: 10,
    );

    // 钉扎 client 服务了 https 候选并带上正确指纹；注入 client 没碰它。
    expect(result, isNotNull);
    expect(pinnedFingerprints, <String>['aa:bb:cc']);
    expect(pinnedClientHosts, <String>['pinned']);
    expect(injectedClientHosts, isEmpty);
  });

  test('plain http candidates still use the injected shared client', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[
        FushiClientUrl(
          url: 'https://pinned:38765',
          fingerprintSha256: 'aa:bb:cc',
        ),
        FushiClientUrl(url: 'http://plain:38765'),
      ],
    );

    final List<String> injectedClientHosts = <String>[];
    bool pinnedFactoryCalledForPlain = false;

    final FushiRemoteLookupClient client = FushiRemoteLookupClient(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        injectedClientHosts.add(request.url.host);
        return http.Response.bytes(
          utf8.encode(jsonEncode(<String, dynamic>{
            'type': 'audioResult',
            'url': 'http://plain:38765/api/lookup/audio/file?id=abc',
          })),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
      pinnedClientFactory: (String expectedFingerprint) {
        return MockClient((http.Request request) async {
          if (request.url.host != 'pinned') {
            pinnedFactoryCalledForPlain = true;
          }
          // 钉扎候选失败 → failover 到明文候选。
          return http.Response('tls host down', 503);
        });
      },
    );

    final String? url = await client.lookupAudioUrl(
      expression: '猫',
      reading: 'ねこ',
    );

    expect(url, 'http://plain:38765/api/lookup/audio/file?id=abc');
    // 明文候选由注入的共享 client 服务（keep-alive 行为零变化）。
    expect(injectedClientHosts, <String>['plain']);
    expect(pinnedFactoryCalledForPlain, isFalse);
  });

  // ── 可达性信号：区分「配对设备死了」与「设备在但这个词没音频」 ──────────
  group('audio lookup reachability signal', () {
    test(
        'all candidates failing at the transport layer throws '
        'RemoteLookupUnreachableError (connection refused + timeout)',
        () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = await _repo(
        db: db,
        urls: const <FushiClientUrl>[
          FushiClientUrl(url: 'http://refused:8765'),
          FushiClientUrl(url: 'http://slow:8765'),
        ],
      );
      final List<String> requestedHosts = <String>[];
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        timeout: const Duration(milliseconds: 50),
        httpClient: MockClient((http.Request request) async {
          requestedHosts.add(request.url.host);
          if (request.url.host == 'refused') {
            throw const SocketException('Connection refused');
          }
          // 超过 client timeout 才回：以 TimeoutException 形态计传输失败。
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return http.Response('late', 200);
        }),
      );

      await expectLater(
        client.lookupAudioUrl(expression: '猫', reading: 'ねこ'),
        throwsA(isA<RemoteLookupUnreachableError>()),
      );
      // 两个候选都真被尝试过，一个响应都没拿到。
      expect(requestedHosts, <String>['refused', 'slow']);
    });

    test(
        'a reachable candidate answering 404 means "no audio" (null), even '
        'when other candidates are transport-dead', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = await _repo(
        db: db,
        urls: const <FushiClientUrl>[
          FushiClientUrl(url: 'http://dead:8765'),
          FushiClientUrl(url: 'http://alive:8765'),
        ],
      );
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        httpClient: MockClient((http.Request request) async {
          if (request.url.host == 'dead') {
            throw const SocketException('Connection refused');
          }
          return http.Response('missing', 404);
        }),
      );

      final String? url = await client.lookupAudioUrl(
        expression: '猫',
        reading: 'ねこ',
      );

      // 拿到过 HTTP 响应 = 设备可达，绝不能抛 unreachable。
      expect(url, isNull);
    });

    test('200 with an empty audio url is reachable-no-audio (null, no throw)',
        () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = await _repo(
        db: db,
        urls: const <FushiClientUrl>[
          FushiClientUrl(url: 'http://alive:8765'),
        ],
      );
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        httpClient: MockClient((http.Request request) async {
          return http.Response.bytes(
            utf8.encode(jsonEncode(<String, dynamic>{
              'type': 'audioResult',
              'url': '',
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

      expect(url, isNull);
    });

    test('no paired candidates configured returns null instead of throwing',
        () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = await _repo(
        db: db,
        urls: const <FushiClientUrl>[],
      );
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        httpClient: MockClient((http.Request request) async {
          fail('no request should be issued without candidates');
        }),
      );

      final String? url = await client.lookupAudioUrl(
        expression: '猫',
        reading: 'ねこ',
      );

      // 未配对不是「设备不可达」：按无结果处理，不得触发上层冷却。
      expect(url, isNull);
    });

    // BUG-1302 契约变更：词典路径此前是全仓唯一「拿到 allUnreachable 却不消费」
    // 的调用点（旧断言：全不可达 → 返回 null）。因为远端查词排在本地缓存之前，
    // 那等于配对设备离线时每次查词都白付一遍「3s × 候选数」，重复查同一个词也
    // 不例外——用户报的「某些机器上查词 4-5 秒」。现在与音频路径对称抛出，
    // 供 AppModel 计入失败冷却。
    test(
        'dictionary lookup throws RemoteLookupUnreachableError when all '
        'candidates are transport-dead (BUG-1302)', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = await _repo(
        db: db,
        urls: const <FushiClientUrl>[
          FushiClientUrl(url: 'http://dead:8765'),
        ],
      );
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        httpClient: MockClient((http.Request request) async {
          throw const SocketException('Connection refused');
        }),
      );

      await expectLater(
        client.searchDictionary(
          term: '猫',
          wildcards: false,
          maximumTerms: 10,
        ),
        throwsA(isA<RemoteLookupUnreachableError>()),
      );
    });

    test(
        'dictionary lookup on a reachable host with no match still returns '
        'null (no false cooldown)', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = await _repo(
        db: db,
        urls: const <FushiClientUrl>[
          FushiClientUrl(url: 'http://dead:8765'),
          FushiClientUrl(url: 'http://alive:8765'),
        ],
      );
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        httpClient: MockClient((http.Request request) async {
          if (request.url.host == 'dead') {
            throw const SocketException('Connection refused');
          }
          return http.Response('missing', 404);
        }),
      );

      final DictionarySearchResult? result = await client.searchDictionary(
        term: '猫',
        wildcards: false,
        maximumTerms: 10,
      );

      // 只要有一个候选给出过 HTTP 响应就是「设备活着」，绝不能抛 unreachable
      // ——否则设备在线但没这个词也会把远端查词打进冷却。
      expect(result, isNull);
    });

    test(
        'dictionary lookup without paired candidates returns null instead of '
        'throwing', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = await _repo(
        db: db,
        urls: const <FushiClientUrl>[],
      );
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        httpClient: MockClient((http.Request request) async {
          fail('no request should be issued without candidates');
        }),
      );

      final DictionarySearchResult? result = await client.searchDictionary(
        term: '猫',
        wildcards: false,
        maximumTerms: 10,
      );

      // 未配对 ≠ 设备不可达：不得触发冷却（否则刚配好对的第一次查词被冷却窗吃掉）。
      expect(result, isNull);
    });
  });
}
