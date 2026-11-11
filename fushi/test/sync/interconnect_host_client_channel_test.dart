import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// BUG-4403 步骤 11：[InterconnectHostClient] 收到共享 host 通道上——GET 与 POST
/// 共用同一套选路、per-peer 凭据、钉扎闸与 client 生命周期。
void main() {
  late FushiDatabase database;
  late SyncRepository repository;

  setUp(() async {
    resetInterconnectRaceCache();
    database = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    repository = SyncRepository(database);
  });
  tearDown(() async {
    debugInterconnectAddressProbeOverride = null;
    resetInterconnectRaceCache();
    await database.close();
  });

  const FushiClientUrl deadLan = FushiClientUrl(
    url: 'http://192.168.1.5:38765',
    token: 'secret',
    hostId: 'H',
    learned: true,
  );
  const FushiClientUrl liveHttps = FushiClientUrl(
    url: 'https://h.example:38766',
    token: 'secret',
    hostId: 'H',
    fingerprintSha256: 'aa:bb',
  );

  test('getFromHost：同组 [死明文 LAN, 活 https] 经选路走活地址，死地址不吃超时、拿不到凭据', () async {
    // 未钉扎的 host：钉扎闸挡不住明文地址，只能靠选路。
    const FushiClientUrl liveUnpinned = FushiClientUrl(
      url: 'https://h.example:38766',
      token: 'secret',
      hostId: 'H',
    );
    await repository.setFushiClientUrls(<FushiClientUrl>[
      deadLan,
      liveUnpinned,
    ]);
    debugInterconnectAddressProbeOverride =
        (FushiClientUrl c, String? hostId) async =>
            c.url == liveUnpinned.url && hostId == 'H';
    final List<Uri> reached = <Uri>[];
    final InterconnectHostClient client = InterconnectHostClient(
      repository: repository,
      peer: deadLan,
      httpClient: MockClient((http.Request r) {
        reached.add(r.url);
        if (r.url.host == '192.168.1.5') {
          // 死地址：永不回答。
          return Completer<http.Response>().future;
        }
        return Future<http.Response>.value(http.Response('{"ok":true}', 200));
      }),
    );
    addTearDown(client.cancelPending);

    final Stopwatch clock = Stopwatch()..start();
    final http.Response? response = await client.getFromHost(
      '/api/capabilities',
      timeout: const Duration(milliseconds: 800),
    );
    expect(response?.statusCode, 200);
    expect(reached.map((Uri u) => u.host), <String>[
      'h.example',
    ], reason: '没核对过 hostId 的死明文地址不该收到带凭据的请求');
    expect(clock.elapsed, lessThan(const Duration(milliseconds: 800)));
  });

  test(
    'postJson：缓存胜者是同组的死 LAN（连接被拒）→ 换到活地址，不再整次失败（评审 compat-1 / tests-1）',
    () async {
      // 未钉扎的 host：死 LAN 也核对通过（刚离开家里 Wi-Fi，选路缓存还指着它）。
      const FushiClientUrl liveUnpinned = FushiClientUrl(
        url: 'https://h.example:38766',
        token: 'secret',
        hostId: 'H',
      );
      await repository.setFushiClientUrls(<FushiClientUrl>[
        deadLan,
        liveUnpinned,
      ]);
      debugInterconnectAddressProbeOverride =
          (FushiClientUrl c, String? hostId) async => hostId == 'H';
      final List<String> reached = <String>[];
      final InterconnectHostClient client = InterconnectHostClient(
        repository: repository,
        peer: deadLan,
        httpClient: _RefusingClient(
          '192.168.1.5',
          MockClient((http.Request r) async {
            reached.add(r.url.host);
            return http.Response('{"ok":true}', 200);
          }),
        ),
      );
      addTearDown(client.cancelPending);

      // 先让死 LAN 当上缓存胜者（两条都核对通过，组首胜出）。
      for (int i = 0; i < 2; i++) {
        expect(
          await client.postJson('/api/x', authErrorMessage: 'rejected'),
          <String, dynamic>{'ok': true},
          reason: '修复前第一条地址连接被拒就抛 unreachable',
        );
      }
      expect(reached, <String>['h.example', 'h.example']);
    },
  );

  test('会话绑定（凭据）：同一台 host 重新配对换了 token，旧会话不再发请求', () async {
    await repository.setFushiClientUrls(<FushiClientUrl>[liveHttps]);
    final List<String> reachedTokens = <String>[];
    final InterconnectHostClient client = InterconnectHostClient(
      repository: repository,
      peer: liveHttps,
      pinnedClientFactory: (String pin) => MockClient((http.Request r) async {
        reachedTokens.add(r.headers['Authorization'] ?? '');
        return http.Response('{"ok":true}', 200);
      }),
    );
    addTearDown(client.cancelPending);
    expect(
      await client.postJson('/api/x', authErrorMessage: 'rejected'),
      <String, dynamic>{'ok': true},
    );

    // hostId 不变、只换凭据：只按 hostId 筛成员挡不住，靠的是通道的会话绑定。
    await repository.setFushiClientTokenForUrl(
      liveHttps.url,
      'rotated',
      hostId: 'H',
    );
    final FushiClientUrl rotated =
        (await repository.getFushiClientUrls()).single;
    expect(rotated.hostId, 'H');
    expect(rotated.token, 'rotated');

    await expectLater(
      client.postJson('/api/x', authErrorMessage: 'rejected'),
      throwsA(isA<InterconnectHostError>()),
    );
    expect(
      await client.getFromHost('/api/x', timeout: const Duration(seconds: 1)),
      isNull,
    );
    expect(reachedTokens, hasLength(1), reason: '凭据换了的会话一次请求都不该发出');
  });

  test('重新配对后旧会话不换库：URL 改归另一台 host，旧会话抛 unreachable、新 host 零请求', () async {
    await repository.setFushiClientUrls(<FushiClientUrl>[liveHttps]);
    final List<String> reachedTokens = <String>[];
    final InterconnectHostClient client = InterconnectHostClient(
      repository: repository,
      peer: liveHttps,
      pinnedClientFactory: (String pin) => MockClient((http.Request r) async {
        reachedTokens.add(r.headers['Authorization'] ?? '');
        return http.Response('{"ok":true}', 200);
      }),
    );
    addTearDown(client.cancelPending);
    expect(
      await client.postJson('/api/x', authErrorMessage: 'rejected'),
      <String, dynamic>{'ok': true},
    );
    expect(reachedTokens, hasLength(1));

    await repository.setFushiClientTokenForUrl(
      liveHttps.url,
      'new-token',
      hostId: 'B',
      reassignOwner: true,
    );
    final FushiClientUrl reassigned =
        (await repository.getFushiClientUrls()).single;
    expect(reassigned.hostId, 'B');

    await expectLater(
      client.postJson('/api/x', authErrorMessage: 'rejected'),
      throwsA(
        isA<InterconnectHostError>().having(
          (InterconnectHostError e) => e.message,
          'message',
          InterconnectHostError.unreachableCode,
        ),
      ),
    );
    expect(
      await client.getFromHost('/api/x', timeout: const Duration(seconds: 1)),
      isNull,
    );
    expect(reachedTokens, hasLength(1), reason: '新 host 一次请求都不该收到');
  });

  test('cancelPending：在途请求立即收尾，自建的钉扎 client 全部关闭；之后可继续请求', () async {
    await repository.setFushiClientUrls(<FushiClientUrl>[liveHttps]);
    final List<_TrackingClient> built = <_TrackingClient>[];
    bool hang = true;
    final InterconnectHostClient client = InterconnectHostClient(
      repository: repository,
      peer: liveHttps,
      pinnedClientFactory: (String pin) {
        final _TrackingClient c = _TrackingClient(
          MockClient((http.Request r) {
            if (hang) return Completer<http.Response>().future;
            return Future<http.Response>.value(
              http.Response('{"ok":true}', 200),
            );
          }),
        );
        built.add(c);
        return c;
      },
    );
    addTearDown(client.cancelPending);

    final Future<Map<String, dynamic>> inFlight = client.postJson(
      '/api/x',
      authErrorMessage: 'rejected',
    );
    final Future<Object?> settled = inFlight.then<Object?>(
      (Map<String, dynamic> v) => v,
      onError: (Object e) => e,
    );
    // 让请求真正发出去。
    for (int i = 0; i < 20 && built.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(built, hasLength(1));

    client.cancelPending();
    final Object? outcome = await settled.timeout(
      const Duration(seconds: 2),
      onTimeout: () => 'still pending',
    );
    expect(outcome, isA<InterconnectHostError>());
    expect(built.every((_TrackingClient c) => c.closed), isTrue);

    hang = false;
    expect(
      await client.postJson('/api/x', authErrorMessage: 'rejected'),
      <String, dynamic>{'ok': true},
      reason: 'cancelPending 之后重建通道，同一个 client 还能继续用',
    );
  });
}

/// [refusedHost] 像「连接被拒」一样失败：不读请求体就抛（真实 IOClient 建连失败时
/// 也还没开始写请求体）；其余交给 [inner]。
class _RefusingClient extends http.BaseClient {
  _RefusingClient(this.refusedHost, this.inner);
  final String refusedHost;
  final http.Client inner;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.host == refusedHost) {
      return Future<http.StreamedResponse>.error(
        http.ClientException('Connection refused', request.url),
      );
    }
    return inner.send(request);
  }
}

class _TrackingClient extends http.BaseClient {
  _TrackingClient(this.inner);
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
