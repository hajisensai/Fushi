// 共享 host 通道（BUG interconnect-client-no-shared-host-channel，步骤 7）：
// 整段超时、非幂等不重发、流式上传只打开一次、证书不符分型、生命周期、
// per-peer 凭据、钉扎闸、401、会话绑定。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _fp =
    'aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:'
    'aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99';

/// 记录关闭的 client（工厂建出的 client 归通道所有，close 时必须被关）。
class _TrackedClient extends http.BaseClient {
  _TrackedClient(this.inner);
  final http.Client inner;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);
  @override
  void close() {
    closed = true;
    inner.close();
  }
}

Future<bool> _alwaysReachable(FushiClientUrl c, String? hostId) async => true;

void main() {
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() async {
    resetInterconnectRaceCache();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
    await repo.setFushiClientToken('global');
  });

  tearDown(() async {
    resetInterconnectRaceCache();
    await db.close();
  });

  /// 同一台 host（h1）的两条明文地址：A 在前、B 在后。
  Future<InterconnectHostRef> twoAddressHost() async {
    await repo.setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(url: 'http://10.0.0.1:8080', hostId: 'h1', token: 'tok'),
      FushiClientUrl(url: 'http://10.0.0.2:8080', hostId: 'h1', token: 'tok'),
    ]);
    return InterconnectHostRef.ofRow((await repo.getFushiClientUrls()).first);
  }

  InterconnectHostChannel channel(
    InterconnectHostRef host, {
    http.Client? plain,
    http.Client Function(String)? pinned,
    InterconnectHostBinding? binding,
  }) => InterconnectHostChannel(
    repo: repo,
    host: host,
    binding: binding,
    plainClient: plain,
    pinnedClientFactory: pinned,
    probe: _alwaysReachable,
  );

  TypeMatcher<InterconnectChannelException> channelFailure(
    InterconnectChannelFailure kind, {
    bool? mayHaveDelivered,
  }) => isA<InterconnectChannelException>()
      .having((InterconnectChannelException e) => e.kind, 'kind', kind)
      .having(
        (InterconnectChannelException e) => e.mayHaveDelivered,
        'mayHaveDelivered',
        mayHaveDelivered ?? anything,
      );

  test('整段超时：响应头到了但响应体永不结束，在超时内抛 unreachable', () async {
    await repo.setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(url: 'http://10.0.0.1:8080'),
    ]);
    final StreamController<List<int>> stuck = StreamController<List<int>>();
    // 没人听的 controller 的 close() 永不完成：不等它。
    addTearDown(() => unawaited(stuck.close()));
    final InterconnectHostChannel ch = channel(
      const InterconnectHostRef.legacyUrl('http://10.0.0.1:8080'),
      plain: MockClient.streaming(
        (http.BaseRequest req, http.ByteStream body) async =>
            http.StreamedResponse(stuck.stream, 200),
      ),
    );
    await expectLater(
      ch
          .send('GET', '/api/x', timeout: const Duration(milliseconds: 200))
          .timeout(const Duration(seconds: 1)),
      throwsA(
        channelFailure(
          InterconnectChannelFailure.unreachable,
          mayHaveDelivered: true,
        ),
      ),
    );
  });

  group('非幂等只发一次', () {
    test('POST 在 send 阶段传输失败：不换第二条地址', () async {
      final InterconnectHostRef host = await twoAddressHost();
      final Map<String, int> hits = <String, int>{};
      final InterconnectHostChannel ch = channel(
        host,
        plain: MockClient((http.Request req) async {
          hits.update(req.url.host, (int n) => n + 1, ifAbsent: () => 1);
          if (req.url.host == '10.0.0.1') {
            throw http.ClientException('Connection reset', req.url);
          }
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        ch.send(
          'POST',
          '/api/x',
          body: const InterconnectRequestBody.json(<String, Object?>{'a': 1}),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(
          channelFailure(
            InterconnectChannelFailure.unreachable,
            mayHaveDelivered: true,
          ),
        ),
      );
      expect(hits['10.0.0.1'], 1);
      expect(hits['10.0.0.2'], isNull, reason: '非幂等请求不得换地址重发');
    });

    test('POST 在读响应体时失败：不换第二条地址', () async {
      final InterconnectHostRef host = await twoAddressHost();
      final Map<String, int> hits = <String, int>{};
      final InterconnectHostChannel ch = channel(
        host,
        plain: MockClient.streaming((
          http.BaseRequest req,
          http.ByteStream body,
        ) async {
          await body.drain<void>();
          hits.update(req.url.host, (int n) => n + 1, ifAbsent: () => 1);
          return http.StreamedResponse(
            Stream<List<int>>.error(
              http.ClientException('Connection closed', req.url),
            ),
            200,
          );
        }),
      );
      await expectLater(
        ch.send('POST', '/api/x', timeout: const Duration(seconds: 5)),
        throwsA(
          channelFailure(
            InterconnectChannelFailure.unreachable,
            mayHaveDelivered: true,
          ),
        ),
      );
      expect(hits['10.0.0.2'], isNull);
    });

    test('GET 在同样的失败下换到第二条地址', () async {
      final InterconnectHostRef host = await twoAddressHost();
      final InterconnectHostChannel ch = channel(
        host,
        plain: MockClient((http.Request req) async {
          if (req.url.host == '10.0.0.1') {
            throw http.ClientException('Connection reset', req.url);
          }
          return http.Response('{"ok":true}', 200);
        }),
      );
      final InterconnectChannelResponse r = await ch.send(
        'GET',
        '/api/x',
        timeout: const Duration(seconds: 5),
      );
      expect(r.statusCode, 200);
      expect(r.via.url, 'http://10.0.0.2:8080');
      expect(r.jsonObject, <String, dynamic>{'ok': true});
    });
  });

  group('流式上传', () {
    test('open 只被调用一次，请求体完整送达', () async {
      final InterconnectHostRef host = await twoAddressHost();
      int opened = 0;
      final List<int> received = <int>[];
      final InterconnectHostChannel ch = channel(
        host,
        plain: MockClient.streaming((
          http.BaseRequest req,
          http.ByteStream body,
        ) async {
          received.addAll(await body.toBytes());
          return http.StreamedResponse(Stream<List<int>>.value(<int>[]), 204);
        }),
      );
      final InterconnectChannelResponse r = await ch.send(
        'PUT',
        '/api/upload',
        body: InterconnectRequestBody.stream(() {
          opened++;
          return Stream<List<int>>.fromIterable(<List<int>>[
            <int>[1, 2],
            <int>[3],
          ]);
        }, contentLength: 3),
        timeout: const Duration(seconds: 5),
      );
      expect(r.statusCode, 204);
      expect(opened, 1);
      expect(received, <int>[1, 2, 3]);
    });

    test('PUT 失败不重试：open 仍只调用一次，第二条地址零请求', () async {
      final InterconnectHostRef host = await twoAddressHost();
      int opened = 0;
      final Map<String, int> hits = <String, int>{};
      final InterconnectHostChannel ch = channel(
        host,
        plain: MockClient.streaming((
          http.BaseRequest req,
          http.ByteStream body,
        ) async {
          hits.update(req.url.host, (int n) => n + 1, ifAbsent: () => 1);
          await body.drain<void>();
          throw http.ClientException('Broken pipe', req.url);
        }),
      );
      await expectLater(
        ch.send(
          'PUT',
          '/api/upload',
          body: InterconnectRequestBody.stream(() {
            opened++;
            return Stream<List<int>>.value(<int>[1]);
          }),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(
          channelFailure(
            InterconnectChannelFailure.unreachable,
            mayHaveDelivered: true,
          ),
        ),
      );
      expect(opened, 1);
      expect(hits['10.0.0.2'], isNull);
    });
  });

  group('证书不符分型', () {
    Future<InterconnectHostRef> pinnedHost() async {
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(
          url: 'https://10.0.0.1:8443',
          fingerprintSha256: _fp,
          token: 'tok',
        ),
      ]);
      return const InterconnectHostRef.legacyUrl('https://10.0.0.1:8443');
    }

    test('钉扎 client 本地拒绝 → certificateMismatch（permanent）', () async {
      final InterconnectHostChannel ch = channel(
        await pinnedHost(),
        pinned: (String fp) => MockClient(
          (http.Request req) async => throw const InterconnectPinRefused(),
        ),
      );
      await expectLater(
        ch.send('GET', '/api/x', timeout: const Duration(seconds: 5)),
        throwsA(
          channelFailure(InterconnectChannelFailure.certificateMismatch).having(
            (InterconnectChannelException e) => e.permanent,
            'permanent',
            isTrue,
          ),
        ),
      );
    });

    test('握手中断（不是证书回调拒绝）→ unreachable，不算永久失败', () async {
      final InterconnectHostChannel ch = channel(
        await pinnedHost(),
        pinned: (String fp) => MockClient(
          (http.Request req) async => throw const HandshakeException(
            'Connection terminated during handshake',
          ),
        ),
      );
      await expectLater(
        ch.send('GET', '/api/x', timeout: const Duration(seconds: 5)),
        throwsA(
          channelFailure(InterconnectChannelFailure.unreachable).having(
            (InterconnectChannelException e) => e.permanent,
            'permanent',
            isFalse,
          ),
        ),
      );
    });
  });

  group('生命周期', () {
    test('close 关掉通道建的 client，不关借用的明文 client', () async {
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(
          url: 'https://10.0.0.1:8443',
          fingerprintSha256: _fp,
          token: 'tok',
        ),
      ]);
      final List<_TrackedClient> built = <_TrackedClient>[];
      final _TrackedClient borrowed = _TrackedClient(
        MockClient((http.Request req) async => http.Response('', 200)),
      );
      final InterconnectHostChannel ch = channel(
        const InterconnectHostRef.legacyUrl('https://10.0.0.1:8443'),
        plain: borrowed,
        pinned: (String fp) {
          final _TrackedClient c = _TrackedClient(
            MockClient((http.Request req) async => http.Response('{}', 200)),
          );
          built.add(c);
          return c;
        },
      );
      await ch.send('GET', '/api/x', timeout: const Duration(seconds: 5));
      await ch.send('GET', '/api/y', timeout: const Duration(seconds: 5));
      expect(built, hasLength(1), reason: '同一指纹的钉扎 client 复用');
      ch.close();
      expect(ch.isClosed, isTrue);
      expect(built.single.closed, isTrue);
      expect(borrowed.closed, isFalse, reason: '借用的 client 归调用方');
    });

    test('close 时在途的请求（响应体挂起）与之后的请求都抛 cancelled', () async {
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://10.0.0.1:8080'),
      ]);
      final StreamController<List<int>> stuck = StreamController<List<int>>();
      // 没人听的 controller 的 close() 永不完成：不等它。
      addTearDown(() => unawaited(stuck.close()));
      final Completer<void> headersSent = Completer<void>();
      final InterconnectHostChannel ch = channel(
        const InterconnectHostRef.legacyUrl('http://10.0.0.1:8080'),
        plain: MockClient.streaming((
          http.BaseRequest req,
          http.ByteStream body,
        ) async {
          headersSent.complete();
          return http.StreamedResponse(stuck.stream, 200);
        }),
      );
      final Future<InterconnectChannelResponse> inflight = ch.send(
        'GET',
        '/api/x',
        timeout: const Duration(seconds: 30),
      );
      await headersSent.future;
      ch.close();
      await expectLater(
        inflight.timeout(const Duration(seconds: 2)),
        throwsA(channelFailure(InterconnectChannelFailure.cancelled)),
      );
      await expectLater(
        ch.send('GET', '/api/x', timeout: const Duration(seconds: 5)),
        throwsA(channelFailure(InterconnectChannelFailure.cancelled)),
      );
    });
  });

  test('per-host 凭据：用行 token，不用全局 token', () async {
    await repo.setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(url: 'http://10.0.0.1:8080', token: 'rowtok'),
    ]);
    String? auth;
    final InterconnectHostChannel ch = channel(
      const InterconnectHostRef.legacyUrl('http://10.0.0.1:8080'),
      plain: MockClient((http.Request req) async {
        auth = req.headers['Authorization'];
        return http.Response('{}', 200);
      }),
    );
    await ch.send('GET', '/api/x', timeout: const Duration(seconds: 5));
    expect(auth, 'Basic ${base64Encode(utf8.encode('hibiki:rowtok'))}');
  });

  test('钉扎：host 有指纹时明文非隧道地址不发请求，结局 certificateMismatch', () async {
    await repo.setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(
        url: 'http://10.0.0.1:8080',
        fingerprintSha256: _fp,
        token: 'tok',
      ),
    ]);
    int requests = 0;
    final InterconnectHostChannel ch = channel(
      const InterconnectHostRef.legacyUrl('http://10.0.0.1:8080'),
      plain: MockClient((http.Request req) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
      ch.send('GET', '/api/x', timeout: const Duration(seconds: 5)),
      throwsA(channelFailure(InterconnectChannelFailure.certificateMismatch)),
    );
    expect(requests, 0);
  });

  test('401：全部地址拒绝 → authRejected', () async {
    final InterconnectHostRef host = await twoAddressHost();
    final InterconnectHostChannel ch = channel(
      host,
      plain: MockClient(
        (http.Request req) async => http.Response('unauthorized', 401),
      ),
    );
    await expectLater(
      ch.send('GET', '/api/x', timeout: const Duration(seconds: 5)),
      throwsA(
        channelFailure(InterconnectChannelFailure.authRejected).having(
          (InterconnectChannelException e) => e.code,
          'code',
          'auth_rejected',
        ),
      ),
    );
  });

  test('非 401 的错误状态码原样返回（host 的回答，不换地址）', () async {
    final InterconnectHostRef host = await twoAddressHost();
    final Map<String, int> hits = <String, int>{};
    final InterconnectHostChannel ch = channel(
      host,
      plain: MockClient((http.Request req) async {
        hits.update(req.url.host, (int n) => n + 1, ifAbsent: () => 1);
        return http.Response('{"message":"boom"}', 500);
      }),
    );
    final InterconnectChannelResponse r = await ch.send(
      'GET',
      '/api/x',
      query: const <String, String>{'deleteFiles': 'true'},
      timeout: const Duration(seconds: 5),
    );
    expect(r.statusCode, 500);
    expect(r.jsonString('message'), 'boom');
    expect(hits['10.0.0.2'], isNull);
  });

  test('会话绑定：凭据与成员不一致 → notPaired，不发任何请求', () async {
    final InterconnectHostRef host = await twoAddressHost();
    int requests = 0;
    final InterconnectHostChannel ch = channel(
      host,
      binding: (token: 'other', fingerprint: null),
      plain: MockClient((http.Request req) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    await expectLater(
      ch.send('GET', '/api/x', timeout: const Duration(seconds: 5)),
      throwsA(
        channelFailure(
          InterconnectChannelFailure.notPaired,
        ).having((InterconnectChannelException e) => e.code, 'code', 'no_host'),
      ),
    );
    expect(requests, 0);
  });

  group('能力探测', () {
    test('404 → unsupported；200 带能力 → Available；401 → authRejected', () async {
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://10.0.0.1:8080', deviceName: 'PC'),
      ]);
      const InterconnectHostRef host = InterconnectHostRef.legacyUrl(
        'http://10.0.0.1:8080',
      );
      Future<InterconnectCapabilityOutcome<String>> probeWith(
        http.Response response,
      ) => probeInterconnectCapability<String>(
        channel(host, plain: MockClient((http.Request req) async => response)),
        label: 'PC',
        parse: (Map<String, dynamic> caps, FushiClientUrl via) =>
            caps['x'] == true ? via.url : null,
        timeout: const Duration(seconds: 5),
      );

      expect(
        await probeWith(http.Response('', 404)),
        isA<InterconnectCapabilityUnavailable<String>>().having(
          (InterconnectCapabilityUnavailable<String> o) => o.failure,
          'failure',
          InterconnectHostFailure.unsupported,
        ),
      );
      expect(
        await probeWith(http.Response('{"x":true}', 200)),
        isA<InterconnectCapabilityAvailable<String>>().having(
          (InterconnectCapabilityAvailable<String> o) => o.target,
          'target',
          'http://10.0.0.1:8080',
        ),
      );
      expect(
        await probeWith(http.Response('', 401)),
        isA<InterconnectCapabilityUnavailable<String>>().having(
          (InterconnectCapabilityUnavailable<String> o) => o.failure,
          'failure',
          InterconnectHostFailure.authRejected,
        ),
      );
      expect(
        await probeWith(http.Response('nope', 503)),
        isA<InterconnectCapabilityUnavailable<String>>().having(
          (InterconnectCapabilityUnavailable<String> o) => o.statusCode,
          'statusCode',
          503,
        ),
      );
    });
  });

  test('ref：hostId 组按 hostId 认，老条目按持久 URL 认；标签取组内设备名', () {
    const List<FushiClientUrl> rows = <FushiClientUrl>[
      FushiClientUrl(url: 'http://a', hostId: 'h1', learned: true),
      FushiClientUrl(url: 'http://b', hostId: 'h1', deviceName: 'Desk PC'),
      FushiClientUrl(url: 'http://c'),
      FushiClientUrl(url: 'http://d', enabled: false),
    ];
    final InterconnectHostRef? h1 = interconnectHostRefForUrl(rows, 'http://a');
    expect(h1?.key, 'host:h1');
    expect(h1?.anchorUrl, 'http://b', reason: '锚点取手输代表地址');
    expect(interconnectHostRefForUrl(rows, 'http://zz'), isNull);
    expect(
      interconnectPairedHostRefs(
        rows,
      ).map((InterconnectHostRef r) => r.key).toList(),
      <String>['host:h1', 'url:http://c'],
    );
    expect(interconnectHostLabel(rows, h1!), 'Desk PC');
    expect(
      interconnectHostLabel(
        rows,
        const InterconnectHostRef.legacyUrl('http://c'),
      ),
      'http://c',
    );
    expect(h1.matches(rows[2]), isFalse);
    expect(
      const InterconnectHostRef.legacyUrl('http://c').matches(rows[2]),
      isTrue,
    );
  });
}
