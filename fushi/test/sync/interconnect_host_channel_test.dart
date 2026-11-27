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

/// [refused] 里的主机像「连接被拒」一样失败：不读请求体就抛（真实 IOClient 在
/// openUrl 建连失败时也还没开始写请求体）；其余主机交给 [inner]。
class _RefuseConnectClient extends http.BaseClient {
  _RefuseConnectClient(this.refused, this.inner);
  final Set<String> refused;
  final http.Client inner;
  final Map<String, int> refusedHits = <String, int>{};
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (refused.contains(request.url.host)) {
      refusedHits.update(request.url.host, (int n) => n + 1, ifAbsent: () => 1);
      return Future<http.StreamedResponse>.error(
        http.ClientException('Connection refused', request.url),
      );
    }
    return inner.send(request);
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

    test(
      'POST 建连被拒（请求体没开始写出）：换同组下一条地址并作废选路缓存（评审 compat-1 / tests-1）',
      () async {
        final InterconnectHostRef host = await twoAddressHost();
        int probes = 0;
        final Map<String, int> hits = <String, int>{};
        final _RefuseConnectClient plain = _RefuseConnectClient(
          <String>{'10.0.0.1'},
          MockClient((http.Request req) async {
            hits.update(req.url.host, (int n) => n + 1, ifAbsent: () => 1);
            return http.Response('{"ok":true}', 200);
          }),
        );
        final InterconnectHostChannel ch = InterconnectHostChannel(
          repo: repo,
          host: host,
          plainClient: plain,
          probe: (FushiClientUrl c, String? hostId) async {
            probes++;
            return true;
          },
        );
        final InterconnectChannelResponse r = await ch.send(
          'POST',
          '/api/x',
          body: const InterconnectRequestBody.json(<String, Object?>{'a': 1}),
          timeout: const Duration(seconds: 5),
        );
        expect(r.statusCode, 200, reason: '修复前直接抛 unreachable，不试活地址');
        expect(r.via.url, 'http://10.0.0.2:8080');
        expect(plain.refusedHits['10.0.0.1'], 1);
        expect(hits['10.0.0.2'], 1);

        // 选路缓存已作废：下一次请求重新竞速，而不是在 30 秒窗口里先撞死地址。
        final int before = probes;
        await ch.send('GET', '/api/y', timeout: const Duration(seconds: 5));
        expect(probes, greaterThan(before));
      },
    );

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

    test('幂等的流式 PUT 写出一部分后断开：也不换地址，open 只调用一次（评审 correctness-4）', () async {
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
          await body.first;
          throw http.ClientException('Connection reset', req.url);
        }),
      );
      await expectLater(
        ch.send(
          'PUT',
          '/api/upload',
          idempotent: true,
          body: InterconnectRequestBody.stream(() {
            opened++;
            return Stream<List<int>>.fromIterable(<List<int>>[
              <int>[1],
              <int>[2],
            ]);
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
      expect(opened, 1, reason: '修复前幂等请求换地址后再 open 一次');
      expect(hits['10.0.0.2'], isNull);
    });

    test('流式 PUT 第一条建连被拒（流没打开）：换下一条，open 只调用一次', () async {
      final InterconnectHostRef host = await twoAddressHost();
      int opened = 0;
      final List<int> received = <int>[];
      final _RefuseConnectClient plain = _RefuseConnectClient(
        <String>{'10.0.0.1'},
        MockClient.streaming((
          http.BaseRequest req,
          http.ByteStream body,
        ) async {
          received.addAll(await body.toBytes());
          return http.StreamedResponse(Stream<List<int>>.value(<int>[]), 204);
        }),
      );
      final InterconnectChannelResponse r = await channel(host, plain: plain)
          .send(
            'PUT',
            '/api/upload',
            body: InterconnectRequestBody.stream(() {
              opened++;
              return Stream<List<int>>.value(<int>[7, 8]);
            }, contentLength: 2),
            timeout: const Duration(seconds: 5),
          );
      expect(r.statusCode, 204);
      expect(r.via.url, 'http://10.0.0.2:8080');
      expect(opened, 1);
      expect(received, <int>[7, 8]);
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

  test(
    '钉扎闸拒掉明文地址、https 地址只是传输失败 → unreachable，不是永久的证书不符（评审 correctness-3）',
    () async {
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://10.0.0.1:8080', hostId: 'h1', token: 'tok'),
        FushiClientUrl(
          url: 'https://10.0.0.2:8443',
          hostId: 'h1',
          fingerprintSha256: _fp,
          token: 'tok',
        ),
      ]);
      final InterconnectHostRef host = InterconnectHostRef.ofRow(
        (await repo.getFushiClientUrls()).first,
      );
      int plainRequests = 0;
      final InterconnectHostChannel ch = channel(
        host,
        plain: MockClient((http.Request req) async {
          plainRequests++;
          return http.Response('{}', 200);
        }),
        pinned: (String fp) => MockClient(
          (http.Request req) async =>
              throw http.ClientException('Connection timed out', req.url),
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
      expect(plainRequests, 0, reason: '钉扎 host 的明文地址仍一个字节都不发');
    },
  );

  test('请求 URI：没有查询参数时结尾不带 `?`；有则编码进查询串（评审 tests-2）', () {
    expect(
      interconnectRequestUri('http://10.0.0.1:8080/', '/api/x').toString(),
      'http://10.0.0.1:8080/api/x',
    );
    expect(
      interconnectRequestUri(
        'https://h.example',
        '/api/x',
        const <String, String>{'deleteFiles': 'true'},
      ).toString(),
      'https://h.example/api/x?deleteFiles=true',
    );
    expect(
      interconnectRequestUri(
        'http://[fe80::1]:38765/old/path?q=1',
        '/api/x',
      ).toString(),
      'http://[fe80::1]:38765/api/x',
    );
    expect(interconnectRequestUri('ftp://h', '/api/x'), isNull);
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

  test('选路吃光整段超时、一条地址都没试：unreachable 而非 notPaired（评审 recheck-1）', () async {
    // 两条都带密码学身份（https 钉扎）→ withheld == 0；选路要竞速，探测比整段
    // 超时还慢（直连全死后冷启动 P2P 隧道的情形）。
    await repo.setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(
        url: 'https://10.0.0.1:8443',
        hostId: 'h1',
        token: 'tok',
        fingerprintSha256: _fp,
      ),
      FushiClientUrl(
        url: 'https://203.0.113.5:8443',
        hostId: 'h1',
        token: 'tok',
        fingerprintSha256: _fp,
      ),
    ]);
    final InterconnectHostRef host = InterconnectHostRef.ofRow(
      (await repo.getFushiClientUrls()).first,
    );
    int requests = 0;
    final InterconnectHostChannel ch = InterconnectHostChannel(
      repo: repo,
      host: host,
      pinnedClientFactory: (String fp) => MockClient((http.Request req) async {
        requests++;
        return http.Response('{}', 200);
      }),
      probe: (FushiClientUrl c, String? hostId) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return true;
      },
    );
    await expectLater(
      ch.send('GET', '/api/x', timeout: const Duration(milliseconds: 50)),
      throwsA(
        channelFailure(InterconnectChannelFailure.unreachable).having(
          (InterconnectChannelException e) => e.kind,
          'kind（修复前是 notPaired）',
          isNot(InterconnectChannelFailure.notPaired),
        ),
      ),
    );
    expect(requests, 0, reason: '超时用完后不应再发请求');
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

  group('能力表缓存', () {
    const Duration timeout = Duration(seconds: 5);
    late Duration now;
    late int hits;
    Completer<void>? gate;
    late http.Response Function() answer;

    setUp(() {
      now = Duration.zero;
      hits = 0;
      gate = null;
      answer = () => http.Response('{"x":true}', 200);
      debugInterconnectCapabilitiesClock = () => now;
    });

    MockClient capsHost() => MockClient((http.Request req) async {
      if (req.url.path == '/api/capabilities') hits++;
      final Completer<void>? g = gate;
      if (g != null) await g.future;
      return answer();
    });

    Future<InterconnectHostRef> oneHost({String token = 'tok'}) async {
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: 'http://10.0.0.1:8080', hostId: 'h1', token: token),
      ]);
      return InterconnectHostRef.ofRow((await repo.getFushiClientUrls()).first);
    }

    test('TTL 内同一台 host 只请求一次（跨通道共用），过期后重新请求', () async {
      final InterconnectHostRef host = await oneHost();
      final MockClient plain = capsHost();
      final InterconnectHostChannel a = channel(host, plain: plain);
      final InterconnectHostChannel b = channel(host, plain: plain);
      expect(
        (await a.capabilities(timeout: timeout)).jsonObject,
        <String, Object?>{'x': true},
      );
      await b.capabilities(timeout: timeout);
      await a.capabilities(timeout: timeout);
      expect(hits, 1);

      now = kInterconnectCapabilitiesTtl - const Duration(milliseconds: 1);
      await a.capabilities(timeout: timeout);
      expect(hits, 1, reason: '还没过期');

      now = kInterconnectCapabilitiesTtl;
      await b.capabilities(timeout: timeout);
      expect(hits, 2, reason: '过期后重新请求');
    });

    test('probeInterconnectCapability：缺省要当场的能力表但写回缓存；放宽 maxAge 才命中', () async {
      final InterconnectHostRef host = await oneHost();
      final MockClient plain = capsHost();
      Future<InterconnectCapabilityOutcome<bool>> probe({
        Duration maxAge = Duration.zero,
      }) => probeInterconnectCapability<bool>(
        channel(host, plain: plain),
        label: 'PC',
        parse: (Map<String, dynamic> caps, FushiClientUrl via) =>
            caps['x'] == true ? true : null,
        timeout: timeout,
        maxAge: maxAge,
      );
      expect(await probe(), isA<InterconnectCapabilityAvailable<bool>>());
      expect(await probe(), isA<InterconnectCapabilityAvailable<bool>>());
      expect(hits, 2, reason: '带就绪状态的入口每次要当场的能力表');

      // 当场探到的应答写回了缓存：只看静态能力位的调用方直接复用。
      await channel(host, plain: plain).capabilities(timeout: timeout);
      expect(
        await probe(maxAge: kInterconnectCapabilitiesTtl),
        isA<InterconnectCapabilityAvailable<bool>>(),
      );
      expect(hits, 2);
    });

    test('并发请求合并成一次', () async {
      final InterconnectHostRef host = await oneHost();
      final MockClient plain = capsHost();
      gate = Completer<void>();
      final List<Future<InterconnectChannelResponse>> calls =
          <Future<InterconnectChannelResponse>>[
            for (int i = 0; i < 4; i++)
              channel(host, plain: plain).capabilities(timeout: timeout),
          ];
      await pumpEventQueue();
      gate!.complete();
      final List<InterconnectChannelResponse> responses = await Future.wait(
        calls,
      );
      expect(hits, 1);
      expect(
        responses.every((InterconnectChannelResponse r) => r.statusCode == 200),
        isTrue,
      );
    });

    test('在途失败一起失败，且失败 / 非 200 都不进缓存', () async {
      final InterconnectHostRef host = await oneHost();
      final _RefuseConnectClient dead = _RefuseConnectClient(<String>{
        '10.0.0.1',
      }, capsHost());
      final List<Future<InterconnectChannelResponse>> calls =
          <Future<InterconnectChannelResponse>>[
            for (int i = 0; i < 3; i++)
              channel(host, plain: dead).capabilities(timeout: timeout),
          ];
      for (final Future<InterconnectChannelResponse> c in calls) {
        await expectLater(
          c,
          throwsA(channelFailure(InterconnectChannelFailure.unreachable)),
        );
      }
      expect(dead.refusedHits['10.0.0.1'], 1, reason: '并发的三次只发了一次');

      final MockClient plain = capsHost();
      answer = () => http.Response('busy', 503);
      expect(
        (await channel(
          host,
          plain: plain,
        ).capabilities(timeout: timeout)).statusCode,
        503,
      );
      answer = () => http.Response('{"x":true}', 200);
      expect(
        (await channel(
          host,
          plain: plain,
        ).capabilities(timeout: timeout)).statusCode,
        200,
      );
      expect(hits, 2, reason: '503 没被当成缓存');
    });

    test('发起方通道被关掉时，合并进来的通道自己重发', () async {
      final InterconnectHostRef host = await oneHost();
      final MockClient plain = capsHost();
      gate = Completer<void>();
      final InterconnectHostChannel owner = channel(host, plain: plain);
      final Future<InterconnectChannelResponse> first = owner.capabilities(
        timeout: timeout,
      );
      await pumpEventQueue();
      final Future<InterconnectChannelResponse> joined = channel(
        host,
        plain: plain,
      ).capabilities(timeout: timeout);
      await pumpEventQueue();
      owner.close();
      await expectLater(
        first,
        throwsA(channelFailure(InterconnectChannelFailure.cancelled)),
      );
      gate!.complete();
      expect((await joined).statusCode, 200);
      expect(hits, 2);
    });

    test('重新配对（凭据变）/ 改地址 / 取消配对都让缓存作废', () async {
      InterconnectHostRef host = await oneHost();
      final MockClient plain = capsHost();
      await channel(host, plain: plain).capabilities(timeout: timeout);
      expect(hits, 1);

      host = await oneHost(token: 'tok2');
      await channel(host, plain: plain).capabilities(timeout: timeout);
      expect(hits, 2, reason: '重新配对换了凭据');

      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(
          url: 'http://10.0.0.9:8080',
          hostId: 'h1',
          token: 'tok2',
        ),
      ]);
      await channel(host, plain: plain).capabilities(timeout: timeout);
      expect(hits, 3, reason: '地址变了');

      await repo.setFushiClientUrls(const <FushiClientUrl>[]);
      await expectLater(
        channel(host, plain: plain).capabilities(timeout: timeout),
        throwsA(channelFailure(InterconnectChannelFailure.notPaired)),
      );
      expect(hits, 3, reason: '取消配对后不再返回旧能力表');
    });

    test('不同会话绑定分开缓存', () async {
      final InterconnectHostRef host = await oneHost();
      final MockClient plain = capsHost();
      await channel(host, plain: plain).capabilities(timeout: timeout);
      for (int i = 0; i < 2; i++) {
        await channel(
          host,
          plain: plain,
          binding: (token: 'tok', fingerprint: null),
        ).capabilities(timeout: timeout);
      }
      expect(hits, 2);
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
