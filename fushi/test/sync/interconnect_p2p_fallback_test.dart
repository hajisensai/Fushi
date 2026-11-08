// BUG-4241：直连不通、只剩 `p2p://` 时，按能力探测列主机的入口（远程复习、视频遥控、
// AI 中继）与同一 host client 的 GET / POST 都要经 P2P 隧道到达 host；选路缓存记着
// 刚失效的直连地址时，组内的 `p2p://` 仍要可拨，失败后缓存立即作废。
//
// host 是真实的 FushiSyncServer：隧道那一跳用它自己的 P2P 监听口（隧道流量在 host 上
// 就落在这个口，请求按 p2p 信任区处理），假 resolver 把 `p2p://` 换成这个口——即
// 只有「转发口」可达。直连地址是一个刚关掉的本机端口（连接被拒）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_remote_store_client.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_targets.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:http/http.dart' as http;

import '../srs/srs_test_support.dart';
import 'temp_dir_cleanup.dart';

const String _hostId = 'HOST-P2P';
const String _token = 'shared-token';
const String _p2pUrl = 'p2p://node-under-test';

void main() {
  late Directory dir;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late FushiDatabase clientDb;
  late SyncRepository repo;
  late int tunnelPort;
  late String deadDirect;
  final List<String> hostOps = <String>[];

  /// 一个刚关掉的本机端口：连上去立即被拒（「直连被挡」）。
  Future<String> closedLocalUrl() async {
    final ServerSocket socket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = socket.port;
    await socket.close();
    return 'http://127.0.0.1:$port';
  }

  /// 本机配对清单：同一台 host 的手输直连地址 + 学到的 `p2p://`，都带 [token]。
  Future<void> pairWith({required String token}) async {
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: deadDirect, token: token, hostId: _hostId),
      FushiClientUrl(
        url: _p2pUrl,
        token: token,
        hostId: _hostId,
        learned: true,
      ),
    ]);
  }

  FushiClientUrl peerWith(String token) =>
      FushiClientUrl(url: deadDirect, token: token, hostId: _hostId);

  setUp(() async {
    resetInterconnectRaceCache();
    hostOps.clear();
    dir = await Directory.systemTemp.createTemp('fushi_p2p_fallback_test');
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
    hostDb = db;
    final SrsRemoteStoreService service = SrsRemoteStoreService(
      readStore: () async {
        hostOps.add('store');
        return store;
      },
      readMedia: (String name) async {
        hostOps.add('media/$name');
        return name == 'card.png'
            ? Uint8List.fromList(<int>[1, 2, 3, 4])
            : null;
      },
    );
    server =
        FushiSyncServer(
            syncDataDir: dir.path,
            port: 0,
            token: _token,
            allowLan: true,
          )
          ..hostId = _hostId
          ..interfaceLister = (() async => <NetworkInterface>[])
          ..srsRemoteStoreProvider = (() => service);
    await server.start();
    tunnelPort = await server.startP2pListener();
    deadDirect = await closedLocalUrl();
    setInterconnectP2pResolver((FushiClientUrl candidate) async {
      if (candidate.url != _p2pUrl) return null;
      return candidate.copyWith(url: 'http://127.0.0.1:$tunnelPort');
    });

    clientDb = FushiDatabase(
      (await Directory(
        '${dir.path}${Platform.pathSeparator}client',
      ).create()).path,
    );
    repo = SyncRepository(clientDb);
    await repo.setInterconnectEnabled(true);
  });

  tearDown(() async {
    setInterconnectP2pResolver(null);
    resetInterconnectRaceCache();
    await server.stop();
    await clientDb.close();
    await hostDb.close();
    await cleanupTempDir(dir);
  });

  test('只有 p2p:// 可达：能力探测为真，远程复习入口列出这台 host', () async {
    await pairWith(token: _token);

    final InterconnectHostClient client = InterconnectHostClient(
      repository: repo,
      peer: peerWith(_token),
    );
    addTearDown(client.cancelPending);
    expect(
      await client.declaresCapability(kSrsRemoteStoreCapability),
      isTrue,
      reason: 'GET 与 POST 共用选路：p2p:// 换成转发口再请求',
    );

    final List<InterconnectHostTarget> targets =
        await filterSrsRemoteStoreTargets(
          repo,
          await configuredInterconnectHostTargets(repo),
        );
    expect(targets.map((InterconnectHostTarget t) => t.hostId), <String>[
      _hostId,
    ]);

    final List<InterconnectHostTarget> probed =
        await probeInterconnectHostTargets(
          repository: repo,
          probe: (SyncRepository r, FushiClientUrl peer) async {
            final SrsRemoteHostClient c = SrsRemoteHostClient(
              repository: r,
              peer: peer,
            );
            try {
              return await c.supportsRemoteStore();
            } finally {
              c.cancelPending();
            }
          },
        );
    expect(probed.map((InterconnectHostTarget t) => t.hostId), <String>[
      _hostId,
    ]);
  });

  test('缓存的直连胜出地址已失效：POST / GET 立即经组内 p2p:// 成功，缓存随之作废', () async {
    await pairWith(token: _token);
    // 直连刚才还通（选路胜出并进了缓存），随后被挡。
    final List<FushiClientUrl> primed = await rankInterconnectCandidates(
      await repo.getFushiClientUrls(),
      probe: (FushiClientUrl c, String? _) async => c.url == deadDirect,
    );
    expect(primed.first.url, deadDirect);

    final SrsRemoteHostClient client = SrsRemoteHostClient(
      repository: repo,
      peer: peerWith(_token),
    );
    addTearDown(client.cancelPending);
    final Map<String, dynamic> hello = await client.call('hello');
    expect(hello, isNotEmpty, reason: '不等 30 秒 TTL：组内 p2p:// 就是可拨的转发口');
    expect(await client.media('card.png'), <int>[1, 2, 3, 4]);
    expect(hostOps, containsAll(<String>['store', 'media/card.png']));

    final List<FushiClientUrl> next = await rankInterconnectCandidates(
      await repo.getFushiClientUrls(),
      probe: (FushiClientUrl c, String? _) async =>
          fail('缓存应已换成刚才到达 host 的隧道地址，不必再探测：${c.url}'),
    );
    expect(
      interconnectPersistedUrl(next.first.url),
      _p2pUrl,
      reason: '失效的直连不再在 TTL 内排组首',
    );
    expect(Uri.parse(next.first.url).port, tunnelPort);
  });

  test('经 P2P 隧道的请求不带有效配对凭据 → 401，host 不执行', () async {
    final http.Response bare = await http.get(
      Uri.parse('http://127.0.0.1:$tunnelPort/api/srs/remote/media/card.png'),
    );
    expect(bare.statusCode, 401, reason: '隧道口同样要配对凭据');

    await pairWith(token: 'not-the-pairing-token');
    final SrsRemoteHostClient client = SrsRemoteHostClient(
      repository: repo,
      peer: peerWith('not-the-pairing-token'),
    );
    addTearDown(client.cancelPending);
    await expectLater(
      client.call('hello'),
      throwsA(
        isA<SyncAuthError>().having(
          (SyncAuthError e) => e.kind,
          'kind',
          SyncAuthFailureKind.pairingRejected,
        ),
      ),
    );
    expect(await client.media('card.png'), isNull);
    final http.Response wrong = await http.get(
      Uri.parse('http://127.0.0.1:$tunnelPort/api/srs/remote/media/card.png'),
      headers: <String, String>{
        'Authorization':
            'Basic ${base64Encode(utf8.encode('hibiki:not-the-pairing-token'))}',
      },
    );
    expect(wrong.statusCode, 401);
    expect(hostOps, isEmpty, reason: '凭据不对的请求一个都没进到复习库');
  });
}
