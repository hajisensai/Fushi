import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_p2p_app.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/interconnect_video_quality.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/interconnect_p2p.dart';
import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
import 'package:http/http.dart' as http;

import 'temp_dir_cleanup.dart';

/// P2P 隧道（docs/specs/2026-09-28-interconnect-remote-reach.md §5）。
///
/// 真隧道那组需要原生库：`FUSHI_P2P_LIB` 指向 fushi_p2p.dll / .so，或它就在
/// `native/fushi_p2p/prebuilt/<平台>/` 下；缺库时跳过（能力本就判不可用）。
void main() {
  late Directory dir;
  late FushiSyncServer server;
  final List<String?> approvalRemotes = <String?>[];

  Future<void> startHost() async {
    dir = await Directory.systemTemp.createTemp('fushi_p2p_tunnel_test');
    server =
        FushiSyncServer(
            syncDataDir: dir.path,
            port: 0,
            token: 'shared-token',
            allowLan: true,
          )
          ..hostId = 'HOST-P2P'
          ..onPairRequest = ((FushiPairRequest r) async {
            approvalRemotes.add(r.remoteAddress);
            return true;
          })
          ..lanRequiresPinProvider = (() async => false)
          ..interfaceLister = (() async => <NetworkInterface>[]);
    await server.start();
  }

  Future<bool> pinRequiredVia(int port) async {
    final http.Response resp = await http.post(
      Uri.parse('http://127.0.0.1:$port/api/pair/v2'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{'clientNonce': 'cn'}),
    );
    expect(resp.statusCode, 200);
    return (jsonDecode(resp.body) as Map<String, dynamic>)['pinRequired']
        as bool;
  }

  /// 经 [port] 开一个 PIN 会话并用错 PIN confirm，返回 confirm 的状态码。
  Future<int> wrongPinVia(int port, String nonce, {String? deviceId}) async {
    final http.Response start = await http.post(
      Uri.parse('http://127.0.0.1:$port/api/pair/v2'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'clientNonce': nonce,
        if (deviceId != null) 'clientDeviceId': deviceId,
      }),
    );
    expect(start.statusCode, 200);
    final Map<String, dynamic> body =
        jsonDecode(start.body) as Map<String, dynamic>;
    final http.Response confirm = await http.post(
      Uri.parse('http://127.0.0.1:$port/api/pair/v2/confirm'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'sessionId': body['sessionId'] as String,
        'pinProof': FushiPairingProtocol.computePinProof(
          pin: '000000',
          clientNonce: nonce,
          hostNonce: body['hostNonce'] as String,
        ),
      }),
    );
    return confirm.statusCode;
  }

  group('信任区（不需要原生库）', () {
    setUp(startHost);
    tearDown(() async {
      await server.stop();
      await cleanupTempDir(dir);
    });

    test('隧道监听口进来的配对一律按公网：强制 PIN（即便来源是 127.0.0.1）', () async {
      expect(
        await pinRequiredVia(server.port),
        isFalse,
        reason: '对照：主监听口的 127.0.0.1 仍按本机免 PIN',
      );
      final int tunnelPort = await server.startP2pListener();
      approvalRemotes.clear();
      expect(await pinRequiredVia(tunnelPort), isTrue);
      expect(approvalRemotes, <String?>[
        kFushiP2pRemoteAddress,
      ], reason: '审批框里如实标成隧道，而不是看似本机的 127.0.0.1');
      expect(await server.startP2pListener(), tunnelPort, reason: '幂等');
      await server.stopP2pListener();
    });

    test('隧道对端按 NodeId 分桶限流：一个人撞 PIN 不会把别人锁在外面', () async {
      String? peer = 'NODE-A';
      server.p2pPeerResolver = (int _) => peer;
      final int tunnelPort = await server.startP2pListener();
      final List<int> a = <int>[
        for (int i = 0; i < 5; i++)
          await wrongPinVia(tunnelPort, 'a$i', deviceId: 'victim-device'),
      ];
      expect(a.last, 429, reason: 'A 撞满阈值被锁');
      peer = 'NODE-B';
      expect(
        await wrongPinVia(tunnelPort, 'b0', deviceId: 'victim-device'),
        401,
        reason: 'B 是另一个隧道对端：不受 A 的锁影响，且自报 deviceId 不参与分桶',
      );
    });

    test('查不到隧道对端身份时所有隧道会话共用一个桶（宁可误伤不放开）', () async {
      final int tunnelPort = await server.startP2pListener();
      for (int i = 0; i < 5; i++) {
        await wrongPinVia(tunnelPort, 'x$i', deviceId: 'dev-$i');
      }
      expect(await wrongPinVia(tunnelPort, 'y', deviceId: 'fresh'), 429);
    });

    test('主机停了就不再开隧道监听口（不留孤儿口）', () async {
      await server.stop();
      await expectLater(server.startP2pListener(), throwsStateError);
    });

    test('直连提示剔除 TUN / fake-ip、回环、链路本地与未指定地址', () {
      for (final String bad in <String>[
        '198.18.0.1:5000', // Clash / FlClash TUN 网卡（实测 iroh 会报出来）
        '198.19.255.2:5000',
        '127.0.0.1:5000',
        '169.254.3.4:5000',
        '0.0.0.0:5000',
        '[::1]:5000',
        '[fe80::1]:5000',
        'not-an-ip:5000',
        'nocolon',
      ]) {
        expect(isInterconnectP2pDialableAddr(bad), isFalse, reason: bad);
      }
      for (final String good in <String>[
        '192.168.1.5:5000',
        '120.7.30.20:5000',
        '198.20.0.1:5000',
        '[2408:8207::5]:5000',
      ]) {
        expect(isInterconnectP2pDialableAddr(good), isTrue, reason: good);
      }
    });

    test('没有中继也没有可路由直连地址时不公布 p2p 地址', () {
      expect(
        interconnectP2pPublishableUrl(
          'node',
          tls: false,
          relayUrl: null,
          directAddrs: <String>['198.18.0.1:1', '127.0.0.1:1'],
        ),
        isNull,
        reason: '只能靠发现去拨——新 host 要 10–50 秒才查得到，约一半失败',
      );
      final String? relayOnly = interconnectP2pPublishableUrl(
        'node',
        tls: false,
        relayUrl: 'https://relay.example/',
        directAddrs: <String>['198.18.0.1:1'],
      );
      expect(parseInterconnectP2pUrl(relayOnly!)!.directAddrs, isEmpty);
      final String? directOnly = interconnectP2pPublishableUrl(
        'node',
        tls: true,
        relayUrl: null,
        directAddrs: <String>['198.18.0.1:1', '192.168.1.5:1'],
      );
      expect(parseInterconnectP2pUrl(directOnly!)!.directAddrs, <String>[
        '192.168.1.5:1',
      ]);
    });

    test('p2p 地址编解码：tls 与拨号提示往返', () {
      final String url = interconnectP2pUrl(
        'nodeabc',
        tls: true,
        relayUrl: 'https://relay.example/',
        directAddrs: <String>['192.168.1.5:5000', '[2408::5]:5000'],
      );
      final ({
        String nodeId,
        bool tls,
        String? relayUrl,
        List<String> directAddrs,
      })?
      parsed = parseInterconnectP2pUrl(url);
      expect(parsed!.nodeId, 'nodeabc');
      expect(parsed.tls, isTrue);
      expect(parsed.relayUrl, 'https://relay.example/');
      expect(parsed.directAddrs, <String>[
        '192.168.1.5:5000',
        '[2408::5]:5000',
      ]);
      expect(parseInterconnectP2pUrl('http://x:1'), isNull);
      expect(interconnectUrlRank(url), 4, reason: 'P2P 恒排最后');
    });
  });

  group('真隧道端到端', () {
    final bool available = InterconnectP2pRuntime.isAvailable;
    late InterconnectP2pRuntime hostRuntime;
    late FushiDatabase db;
    late SyncRepository repo;
    final List<String?> resolvedPeers = <String?>[];

    setUp(() async {
      if (!available) return;
      resolvedPeers.clear();
      resetInterconnectRaceCache();
      await startHost();
      String? hostSecret;
      hostRuntime = InterconnectP2pRuntime(
        loadSecret: () async => hostSecret,
        saveSecret: (String s) async => hostSecret = s,
        loadRelayUrls: () async => const <String>[],
      );
      final InterconnectP2pNode node = (await hostRuntime.ensure())!;
      final int tunnelPort = await server.startP2pListener();
      server.p2pPeerResolver = (int p) {
        final String? id = hostRuntime.current?.hostPeer(p);
        resolvedPeers.add(id);
        return id;
      };
      node.hostListen(tunnelPort);
      server.extraAddressesProvider = () =>
          hostRuntime.hostAddresses(tls: false);
      db = FushiDatabase(dir.path);
      repo = SyncRepository(db);
      installInterconnectP2pClient(repo);
    });

    tearDown(() async {
      if (!available) return;
      await currentAppInterconnectP2pRuntime?.dispose();
      await hostRuntime.dispose();
      await server.stop();
      await db.close();
      await cleanupTempDir(dir);
    });

    test(
      '直连全死 → 经 P2P 隧道到达，隧道里仍核对身份、强制 PIN、按外网定画质',
      () async {
        final List<InterconnectHostAddress> published = hostRuntime
            .hostAddresses(tls: false);
        expect(published.single.kind, InterconnectAddressKind.p2p);
        final List<FushiClientUrl> ranked = await rankInterconnectCandidates(
          <FushiClientUrl>[
            const FushiClientUrl(url: 'http://127.0.0.1:1', hostId: 'HOST-P2P'),
            FushiClientUrl(
              url: published.single.url,
              hostId: 'HOST-P2P',
              learned: true,
            ),
          ],
        );
        final Uri first = Uri.parse(ranked.first.url);
        expect(first.host, '127.0.0.1');
        expect(first.port, isNot(1), reason: '胜出的是隧道本地转发口');
        expect(
          isPrivateNetworkHost(ranked.first.url),
          isFalse,
          reason: '隧道口字面是回环，画质必须按外网给',
        );
        expect(
          await pinRequiredVia(first.port),
          isTrue,
          reason: '隧道流量落在信任区，配对强制 PIN',
        );
        expect(
          resolvedPeers.last,
          currentAppInterconnectP2pRuntime!.current!.nodeId,
          reason: 'host 从连接源端口查出的对端就是客户端端点的 NodeId',
        );
      },
      skip: available ? false : 'fushi_p2p 原生库不可用',
    );

    test('host 地址集经鉴权端点公布 p2p 地址', () async {
      final http.Response resp = await http.get(
        Uri.parse('http://127.0.0.1:${server.port}/api/host/addresses'),
        headers: <String, String>{
          'Authorization':
              'Basic ${base64Encode(utf8.encode('hibiki:shared-token'))}',
        },
      );
      expect(resp.statusCode, 200);
      final List<dynamic> addresses =
          (jsonDecode(resp.body) as Map<String, dynamic>)['addresses']
              as List<dynamic>;
      expect(
        addresses.any(
          (dynamic a) =>
              (a as Map<String, dynamic>)['kind'] == 'p2p' &&
              (a['url'] as String).startsWith('p2p://'),
        ),
        isTrue,
      );
    }, skip: available ? false : 'fushi_p2p 原生库不可用');
  });
}
