import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// [InterconnectPostTransport] 直接守卫。
///
/// 这套「已启用候选按序 fallback + Basic 鉴权 + https 带指纹强制钉扎 + 每候选独立回收」
/// 的逻辑此前在 `fushi_remote_lookup_client.dart` 与 `fushi_remote_mining_client.dart`
/// 各抄了一份（后者的类注释自己就写着「传输契约与前者完全同构」），另有 mangaOcr 的
/// GET 版与 `InterconnectSyncBackend` 走 WebDavOps 的第四份。抄漏一处钉扎/回收就是真
/// 事故（TODO-961 gap①），故收敛成一份并在此直接锁语义——制卡侧原本只有 1 个测试，
/// 收敛后它的传输层由本文件与 lookup 的用例共同覆盖。
FushiDatabase _testDb() => FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );

Future<SyncRepository> _repo({
  required FushiDatabase db,
  required List<FushiClientUrl> urls,
  String? token = 'tok',
}) async {
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(urls);
  await repo.setFushiClientToken(token);
  return repo;
}

Future<InterconnectPostOutcome> _post(
  InterconnectPostTransport transport,
) =>
    transport.post(
      path: '/api/probe',
      body: const <String, dynamic>{'k': 'v'},
      timeout: const Duration(seconds: 3),
      authErrorMessage: 'rejected',
    );

void main() {
  test('按序 fallback：前一个候选非 2xx 时试下一个', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[
        FushiClientUrl(url: 'http://lan:8765'),
        FushiClientUrl(url: 'http://wan:8765'),
      ],
    );
    final List<String> hosts = <String>[];
    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        hosts.add(request.url.host);
        if (request.url.host == 'lan') return http.Response('down', 503);
        return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
      }),
    );

    final InterconnectPostOutcome outcome = await _post(transport);
    expect(hosts, <String>['lan', 'wan']);
    expect(outcome.json?['ok'], isTrue);
    expect(outcome.allUnreachable, isFalse);
  });

  test('disabled 候选被跳过', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[
        FushiClientUrl(url: 'http://off:8765', enabled: false),
        FushiClientUrl(url: 'http://on:8765'),
      ],
    );
    final List<String> hosts = <String>[];
    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        hosts.add(request.url.host);
        return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
      }),
    );

    await _post(transport);
    expect(hosts, <String>['on'], reason: 'enabled=false 的候选一枪都不该发');
  });

  test('Basic 鉴权头用 base64(hibiki:token)', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[FushiClientUrl(url: 'http://h:8765')],
      token: 'secret',
    );
    String? auth;
    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        auth = request.headers['Authorization'];
        return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
      }),
    );

    await _post(transport);
    expect(auth, 'Basic ${base64Encode(utf8.encode('hibiki:secret'))}');
  });

  // BUG-1550：401 只否掉**这一台**。全部候选都拒了才抛 SyncAuthError——调用方
  // （BUG-1185 的查重 fail-soft）仍能据此区分「没查成」与「查过了没有」。
  test('全部候选都 401 时才抛 SyncAuthError', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[
        FushiClientUrl(url: 'http://a:8765'),
        FushiClientUrl(url: 'http://b:8765'),
      ],
    );
    int calls = 0;
    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        calls++;
        return http.Response('no', 401);
      }),
    );

    await expectLater(_post(transport), throwsA(isA<SyncAuthError>()));
    expect(calls, 2, reason: '一台拒绝不代表其余都拒绝，必须问完');
  });

  // BUG-1550 核心回归：第一台对端吊销了我的凭据，第二台仍应正常服务。
  test('前一台 401 不再株连后一台，且各用各的 per-peer token', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[
        FushiClientUrl(url: 'http://a:8765', token: 'token-a'),
        FushiClientUrl(url: 'http://b:8765', token: 'token-b'),
      ],
      token: 'global-token',
    );
    final Map<String, String?> authByHost = <String, String?>{};
    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        authByHost[request.url.host] = request.headers['Authorization'];
        if (request.url.host == 'a') return http.Response('no', 401);
        return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
      }),
    );

    final InterconnectPostOutcome outcome = await _post(transport);
    expect(outcome.json?['ok'], isTrue);
    expect(authByHost['a'],
        'Basic ${base64Encode(utf8.encode('hibiki:token-a'))}');
    expect(authByHost['b'],
        'Basic ${base64Encode(utf8.encode('hibiki:token-b'))}');
  });

  // 老配置（行上无 token）回落全局键，升级路径零破坏。
  test('行上无 token 的候选回落全局 token', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[FushiClientUrl(url: 'http://legacy:8765')],
      token: 'global-token',
    );
    String? auth;
    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        auth = request.headers['Authorization'];
        return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
      }),
    );

    await _post(transport);
    expect(auth, 'Basic ${base64Encode(utf8.encode('hibiki:global-token'))}');
  });

  test('404/405 视为老 host 无此端点，继续下一个候选', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[
        FushiClientUrl(url: 'http://old:8765'),
        FushiClientUrl(url: 'http://new:8765'),
      ],
    );
    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        if (request.url.host == 'old') return http.Response('nope', 404);
        return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
      }),
    );

    final InterconnectPostOutcome outcome = await _post(transport);
    expect(outcome.json?['ok'], isTrue);
  });

  test('全部候选传输层失败 → allUnreachable（配对设备死了）', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[
        FushiClientUrl(url: 'http://a:8765'),
        FushiClientUrl(url: 'http://b:8765'),
      ],
    );
    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      // 传输层失败（连接拒绝 / 超时 / DNS）在 http 包里就是 ClientException。
      httpClient: MockClient((http.Request request) async {
        throw http.ClientException('connection refused', request.url);
      }),
    );

    final InterconnectPostOutcome outcome = await _post(transport);
    expect(outcome.json, isNull);
    expect(outcome.allUnreachable, isTrue);
  });

  test('可达但没结果 ≠ 不可达（失败冷却不得被误触发）', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[FushiClientUrl(url: 'http://a:8765')],
    );
    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        return http.Response('not json at all', 200);
      }),
    );

    final InterconnectPostOutcome outcome = await _post(transport);
    expect(outcome.json, isNull);
    expect(outcome.allUnreachable, isFalse,
        reason: '拿到了 HTTP 响应就算可达，哪怕响应体不是 JSON');
  });

  test('未配对 / 无 token 不算不可达', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository noUrls = await _repo(
      db: db,
      urls: const <FushiClientUrl>[],
    );
    final InterconnectPostOutcome a = await _post(
      InterconnectPostTransport(
        repo: noUrls,
        httpClient: MockClient((_) async => throw StateError('不该发请求')),
      ),
    );
    expect(a.allUnreachable, isFalse);

    final SyncRepository noToken = await _repo(
      db: db,
      urls: const <FushiClientUrl>[FushiClientUrl(url: 'http://a:8765')],
      token: null,
    );
    final InterconnectPostOutcome b = await _post(
      InterconnectPostTransport(
        repo: noToken,
        httpClient: MockClient((_) async => throw StateError('不该发请求')),
      ),
    );
    expect(b.allUnreachable, isFalse);
  });

  test('https 带指纹的候选强制走钉扎 client，不碰注入的共享 client (TODO-961 gap①)', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[
        FushiClientUrl(
          url: 'https://secure:8765',
          fingerprintSha256: 'aa:bb:cc',
        ),
      ],
    );
    final List<String> pinnedFor = <String>[];
    bool sharedUsed = false;
    bool pinnedClosed = false;

    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      httpClient: MockClient((_) async {
        sharedUsed = true;
        return http.Response('{}', 200);
      }),
      pinnedClientFactory: (String fingerprint) {
        pinnedFor.add(fingerprint);
        return _ClosableMockClient(
          (http.Request request) async =>
              http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200),
          onClose: () => pinnedClosed = true,
        );
      },
    );

    final InterconnectPostOutcome outcome = await _post(transport);
    expect(outcome.json?['ok'], isTrue);
    expect(pinnedFor, <String>['aa:bb:cc'],
        reason: 'https 带指纹必须用该指纹建钉扎 client');
    expect(sharedUsed, isFalse, reason: '注入的 keep-alive client 绝不能旁路证书钉扎');
    expect(pinnedClosed, isTrue, reason: '每候选的钉扎 client 用完即关，不泄漏 socket');
  });

  test('明文 http 候选用共享 client，且绝不在此关闭它', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[FushiClientUrl(url: 'http://plain:8765')],
    );
    bool sharedClosed = false;
    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      httpClient: _ClosableMockClient(
        (http.Request request) async =>
            http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200),
        onClose: () => sharedClosed = true,
      ),
      pinnedClientFactory: (_) => throw StateError('明文候选不该建钉扎 client'),
    );

    await _post(transport);
    expect(sharedClosed, isFalse, reason: '共享 client 归调用方所有，传输层不得关它');
  });

  test('https 无指纹不走钉扎（老配置向后兼容）', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[FushiClientUrl(url: 'https://nofp:8765')],
    );
    bool sharedUsed = false;
    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      httpClient: MockClient((_) async {
        sharedUsed = true;
        return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
      }),
      pinnedClientFactory: (_) => throw StateError('无指纹不该建钉扎 client'),
    );

    await _post(transport);
    expect(sharedUsed, isTrue);
  });

  test('畸形候选 URL 被跳过，不影响后续候选', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = await _repo(
      db: db,
      urls: const <FushiClientUrl>[
        FushiClientUrl(url: '::::not a url::::'),
        FushiClientUrl(url: 'http://good:8765'),
      ],
    );
    final List<String> hosts = <String>[];
    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        hosts.add(request.url.host);
        return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
      }),
    );

    final InterconnectPostOutcome outcome = await _post(transport);
    expect(outcome.json?['ok'], isTrue);
    expect(hosts, <String>['good']);
  });

  group('interconnectEndpointUri', () {
    test('拼端点并清空查询串', () {
      final Uri? uri =
          interconnectEndpointUri('http://h:8765/?x=1', '/api/probe');
      expect(uri?.host, 'h');
      expect(uri?.path, '/api/probe');
      expect(uri?.query, isEmpty);
    });

    test('畸形基址返回 null', () {
      expect(interconnectEndpointUri('::::bad::::', '/api/probe'), isNull);
    });
  });
}

/// [MockClient] 不暴露「是否被 close」，而 socket 回收正是本传输层的安全约束之一，
/// 故包一层记录 close。
class _ClosableMockClient extends MockClient {
  _ClosableMockClient(super.handler, {required this.onClose});

  final void Function() onClose;

  @override
  void close() {
    onClose();
    super.close();
  }
}
