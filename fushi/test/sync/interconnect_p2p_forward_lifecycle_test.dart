import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/sync/interconnect_p2p_app.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/interconnect_p2p.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'temp_dir_cleanup.dart';

/// BUG：P2P 转发口撤销后「转发口 → p2p://」反查映射残留；学习器拿临时转发口
/// 当锚点学不到地址。映射必须与转发口同生命周期（engine 持有、随撤口 / 关端点
/// 回收），学习器按持久 URL 认锚点。
void main() {
  final String nodeHex = 'a' * 64;
  String p2pUrl({String relay = 'r1', bool tls = false}) =>
      interconnectP2pUrl(nodeHex, tls: tls, relayUrl: relay);

  late _FakePort port;
  late InterconnectP2pNode node;
  late InterconnectP2pRuntime runtime;

  setUp(() {
    resetInterconnectRaceCache();
    InterconnectAddressLearner.resetForTest();
    port = _FakePort();
    node = InterconnectP2pNode.forTesting(port, 'self');
    runtime = InterconnectP2pRuntime(
      loadSecret: () async => null,
      saveSecret: (String _) async {},
      loadRelayUrls: () async => const <String>[],
    )..debugInstall(node);
    bindInterconnectP2pClient(runtime);
  });

  tearDown(() async {
    await node.close();
    debugResetAppInterconnectP2p();
    resetInterconnectRaceCache();
  });

  Future<bool> probe(FushiClientUrl c, String? hostId) async =>
      c.url.contains('://127.0.0.1:');

  List<FushiClientUrl> peers(String p2p) => <FushiClientUrl>[
    const FushiClientUrl(url: 'http://192.168.1.5:38765', hostId: 'H'),
    FushiClientUrl(url: p2p, hostId: 'H', learned: true),
  ];

  group('转发口反查映射与转发口同生命周期', () {
    test('换提示撤口后旧口不再映射；关端点后新口也不再映射', () async {
      final List<FushiClientUrl> first = await rankInterconnectCandidates(
        peers(p2pUrl()),
        probe: probe,
      );
      expect(first.first.url, 'http://127.0.0.1:5001');
      expect(interconnectPersistedUrl('http://127.0.0.1:5001'), p2pUrl());

      resetInterconnectRaceCache();
      final List<FushiClientUrl> second = await rankInterconnectCandidates(
        peers(p2pUrl(relay: 'r2')),
        probe: probe,
      );
      expect(second.first.url, 'http://127.0.0.1:5002');
      expect(port.stopped, <int>[5001]);
      expect(
        interconnectPersistedUrl('http://127.0.0.1:5001'),
        'http://127.0.0.1:5001',
        reason: '撤掉的口不能再被当成隧道',
      );
      expect(isInterconnectTunnelOrigin('127.0.0.1', 5001), isFalse);
      expect(
        interconnectPersistedUrl('http://127.0.0.1:5002'),
        p2pUrl(relay: 'r2'),
      );

      await node.close();
      expect(
        interconnectPersistedUrl('http://127.0.0.1:5002'),
        'http://127.0.0.1:5002',
      );
      expect(isInterconnectTunnelOrigin('127.0.0.1', 5002), isFalse);
    });

    test('钉扎 host 的明文守卫不放行已撤销的旧转发口', () async {
      await rankInterconnectCandidates(peers(p2pUrl()), probe: probe);
      resetInterconnectRaceCache();
      await rankInterconnectCandidates(
        peers(p2pUrl(relay: 'r2')),
        probe: probe,
      );

      final Directory dir = await Directory.systemTemp.createTemp(
        'fushi_p2p_forward_guard',
      );
      final FushiDatabase db = FushiDatabase(dir.path);
      addTearDown(() async {
        await db.close();
        await cleanupTempDir(dir);
      });
      int sent = 0;
      final InterconnectHostClient client = InterconnectHostClient(
        repository: SyncRepository(db),
        peer: const FushiClientUrl(
          url: 'https://192.168.1.5:38765',
          hostId: 'H',
          fingerprintSha256: 'ff',
        ),
      );
      final http.Client guarded = client.guardPlaintext(
        MockClient((http.Request r) async {
          sent++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        guarded.get(Uri.parse('http://127.0.0.1:5001/api/ping')),
        throwsA(isA<InterconnectPinRefused>()),
      );
      expect(sent, 0);
      await guarded.get(Uri.parse('http://127.0.0.1:5002/api/ping'));
      expect(sent, 1, reason: '仍存活的转发口照常放行');
    });
  });

  test('InterconnectHostClient 经选路走 P2P 转发口（直连不通时）', () async {
    final Directory dir = await Directory.systemTemp.createTemp(
      'fushi_p2p_host_client',
    );
    final FushiDatabase db = FushiDatabase(dir.path);
    addTearDown(() async {
      debugInterconnectAddressProbeOverride = null;
      await db.close();
      await cleanupTempDir(dir);
    });
    final SyncRepository repo = SyncRepository(db);
    final FushiClientUrl tunnelRow = FushiClientUrl(
      url: p2pUrl(),
      hostId: 'H',
      token: 'T',
      learned: true,
      addressKind: 'p2p',
    );
    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(
        url: 'http://192.168.1.5:38765',
        hostId: 'H',
        token: 'T',
      ),
      tunnelRow,
    ]);
    debugInterconnectAddressProbeOverride = probe;
    final List<Uri> reached = <Uri>[];
    final InterconnectHostClient client = InterconnectHostClient(
      repository: repo,
      peer: tunnelRow,
      httpClient: MockClient((http.Request r) async {
        reached.add(r.url);
        if (r.url.host != '127.0.0.1') {
          throw const SocketException('unreachable');
        }
        return http.Response('{"videoRemoteControlV1":true}', 200);
      }),
    );
    addTearDown(client.cancelPending);

    final http.Response? response = await client.getFromHost(
      '/api/capabilities',
      timeout: const Duration(seconds: 2),
    );
    expect(response?.statusCode, 200);
    expect(reached, hasLength(1));
    expect(reached.single.origin, 'http://127.0.0.1:5001');
    expect(reached.single.path, '/api/capabilities');
  });

  group('学习器按持久 URL 认锚点', () {
    late Directory dir;
    late FushiDatabase db;
    late SyncRepository repo;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fushi_p2p_forward_learn');
      db = FushiDatabase(dir.path);
      repo = SyncRepository(db);
    });

    tearDown(() async {
      await db.close();
      await cleanupTempDir(dir);
    });

    InterconnectAddressLearner learner(
      List<Map<String, Object?>> addresses,
      List<Uri> requested,
    ) => InterconnectAddressLearner(
      repo,
      clientFactory: (String? fingerprint) => MockClient((
        http.Request r,
      ) async {
        requested.add(r.url);
        return http.Response(
          jsonEncode(<String, Object?>{'hostId': 'H', 'addresses': addresses}),
          200,
        );
      }),
    );

    test('tls=1 隧道锚点：经转发口取地址集，合并进 p2p 行所在的组', () async {
      final String tunnel = p2pUrl(tls: true);
      await repo.setFushiClientUrls(<FushiClientUrl>[
        const FushiClientUrl(url: 'http://192.168.1.5:38765', hostId: 'H'),
        FushiClientUrl(
          url: tunnel,
          hostId: 'H',
          token: 'T',
          fingerprintSha256: 'ff',
          learned: true,
          addressKind: 'p2p',
        ),
      ]);
      final FushiClientUrl anchor = (await rankInterconnectCandidates(
        await repo.getFushiClientUrls(),
        probe: probe,
      )).first;
      expect(anchor.url, 'https://127.0.0.1:5001');

      final List<Uri> requested = <Uri>[];
      final bool changed = await learner(<Map<String, Object?>>[
        <String, Object?>{'url': 'https://192.168.1.9:38765', 'kind': 'lan'},
        <String, Object?>{'url': tunnel, 'kind': 'p2p'},
      ], requested).refresh(anchor);

      expect(
        requested.single.toString(),
        'https://127.0.0.1:5001/api/host/addresses',
      );
      expect(changed, isTrue);
      final List<FushiClientUrl> urls = await repo.getFushiClientUrls();
      final FushiClientUrl lan = urls.firstWhere(
        (FushiClientUrl u) => u.url == 'https://192.168.1.9:38765',
      );
      expect(lan.hostId, 'H');
      expect(lan.token, 'T');
      expect(lan.fingerprintSha256, 'ff');
    });

    test('明文隧道锚点也能学（隧道按 NodeId 认证），节流键是持久 URL', () async {
      final String tunnel = p2pUrl();
      await repo.setFushiClientUrls(<FushiClientUrl>[
        const FushiClientUrl(url: 'http://192.168.1.5:38765', hostId: 'H'),
        FushiClientUrl(
          url: tunnel,
          hostId: 'H',
          token: 'T',
          learned: true,
          addressKind: 'p2p',
        ),
      ]);
      final FushiClientUrl anchor = (await rankInterconnectCandidates(
        await repo.getFushiClientUrls(),
        probe: probe,
      )).first;
      expect(anchor.url, 'http://127.0.0.1:5001');

      final String renewed = p2pUrl(relay: 'r9');
      final List<Uri> requested = <Uri>[];
      final InterconnectAddressLearner l = learner(<Map<String, Object?>>[
        <String, Object?>{'url': renewed, 'kind': 'p2p'},
      ], requested);
      expect(await l.refresh(anchor), isTrue);
      final List<String> after = <String>[
        for (final FushiClientUrl u in await repo.getFushiClientUrls()) u.url,
      ];
      expect(after, contains(renewed));
      expect(
        after,
        isNot(contains(tunnel)),
        reason: 'host 换了 home relay：旧 p2p 行被新提示替换',
      );

      // 后台刷新按持久 URL 节流：同一隧道换了转发口也不重复学。
      l.refreshInBackground(anchor.copyWith(url: 'http://127.0.0.1:5001'));
      await Future<void>.delayed(Duration.zero);
      expect(requested, hasLength(1));
    });

    test('没有 hostId 的隧道锚点不学', () async {
      final String tunnel = p2pUrl();
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: tunnel, token: 'T'),
      ]);
      await node.close();
      final InterconnectP2pNode fresh = InterconnectP2pNode.forTesting(
        _FakePort(),
        'self',
      );
      runtime.debugInstall(fresh);
      addTearDown(fresh.close);
      final int forwarded = fresh.forwardTo(
        nodeHex,
        relayUrl: 'r1',
        originUrl: tunnel,
      );
      final List<Uri> requested = <Uri>[];
      expect(
        await learner(const <Map<String, Object?>>[], requested).refresh(
          FushiClientUrl(url: 'http://127.0.0.1:$forwarded', token: 'T'),
        ),
        isFalse,
      );
      expect(requested, isEmpty);
    });
  });
}

final class _FakePort implements InterconnectP2pEndpointPort {
  int _next = 5001;
  final List<int> stopped = <int>[];

  @override
  int clientForward(
    String nodeId, {
    List<String> directAddrs = const <String>[],
    String? relayUrl,
  }) => _next++;

  @override
  bool stopForward(int port) {
    stopped.add(port);
    return true;
  }

  @override
  FushiP2pConnStatus status(String nodeId) => throw UnimplementedError();

  @override
  FushiP2pInfo info() => throw UnimplementedError();

  @override
  void hostListen(int port) {}

  @override
  void hostStop() {}

  @override
  String? hostPeer(int port) => null;

  @override
  bool networkChange() => false;

  @override
  Future<void> closeAsync() async {}
}
