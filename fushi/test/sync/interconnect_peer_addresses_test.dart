import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';

import 'temp_dir_cleanup.dart';

/// 互联「对端 = 同一 hostId 的一组地址」（docs/specs/2026-09-28-interconnect-remote-reach.md
/// §1/§2）：分组、组内并发裁决、学习合并、身份核对。
void main() {
  FushiClientUrl url(String u, {String? host, bool learned = false}) =>
      FushiClientUrl(url: u, hostId: host, learned: learned);

  setUp(resetInterconnectRaceCache);

  group('groupInterconnectPeers / representatives', () {
    test('老条目（无 hostId）各自成组，顺序不变', () {
      final List<List<FushiClientUrl>> groups = groupInterconnectPeers(
        <FushiClientUrl>[url('http://a:1'), url('http://b:1')],
      );
      expect(groups.map((List<FushiClientUrl> g) => g.single.url), <String>[
        'http://a:1',
        'http://b:1',
      ]);
    });

    test('同 hostId 归一组，按首次出现排组', () {
      final List<List<FushiClientUrl>> groups = groupInterconnectPeers(
        <FushiClientUrl>[
          url('http://a1:1', host: 'A'),
          url('http://b:1'),
          url('http://a2:1', host: 'A'),
        ],
      );
      expect(groups, hasLength(2));
      expect(groups[0].map((FushiClientUrl u) => u.url), <String>[
        'http://a1:1',
        'http://a2:1',
      ]);
    });

    test('身份代表取组内第一条手输条目（learned 会随 host 换 IP 被删）', () {
      final List<FushiClientUrl> list = <FushiClientUrl>[
        url('http://192.168.1.5:1', host: 'A', learned: true),
        url('https://home.example', host: 'A'),
      ];
      expect(
        interconnectPeerRepresentatives(list).single.url,
        'https://home.example',
      );
      expect(
        interconnectPeerRepresentativeOf(list, 'http://192.168.1.5:1')?.url,
        'https://home.example',
      );
      expect(interconnectPeerRepresentativeOf(list, 'http://x:1'), isNull);
    });
  });

  group('raceInterconnectHostAddresses', () {
    test('高优先级成功即胜出，即便低优先级先回', () async {
      final Completer<bool> high = Completer<bool>();
      final Completer<bool> low = Completer<bool>();
      final Future<FushiClientUrl?> result = raceInterconnectHostAddresses(
        <FushiClientUrl>[url('http://lan:1'), url('http://v6:1')],
        probe: (FushiClientUrl c, String? _) =>
            c.url == 'http://lan:1' ? high.future : low.future,
        grace: const Duration(seconds: 30),
      );
      low.complete(true);
      high.complete(true);
      expect((await result)?.url, 'http://lan:1');
    });

    test('高优先级迟迟不回：低优先级成功后只再等宽限期', () async {
      final Stopwatch sw = Stopwatch()..start();
      final FushiClientUrl? winner = await raceInterconnectHostAddresses(
        <FushiClientUrl>[url('http://lan:1'), url('http://v6:1')],
        probe: (FushiClientUrl c, String? _) => c.url == 'http://lan:1'
            ? Completer<bool>()
                  .future // 永不返回（死地址还在等超时）
            : Future<bool>.value(true),
        grace: const Duration(milliseconds: 20),
      );
      expect(winner?.url, 'http://v6:1');
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('高优先级失败：立即采用下一个成功者', () async {
      final FushiClientUrl? winner = await raceInterconnectHostAddresses(
        <FushiClientUrl>[url('http://lan:1'), url('http://v6:1')],
        probe: (FushiClientUrl c, String? _) =>
            Future<bool>.value(c.url == 'http://v6:1'),
        grace: const Duration(seconds: 30),
      );
      expect(winner?.url, 'http://v6:1');
    });

    test('全部失败 → null；探测抛异常按失败处理', () async {
      final FushiClientUrl? winner = await raceInterconnectHostAddresses(
        <FushiClientUrl>[url('http://a:1'), url('http://b:1')],
        probe: (FushiClientUrl c, String? _) => c.url == 'http://a:1'
            ? Future<bool>.value(false)
            : Future<bool>.error(const SocketException('boom')),
      );
      expect(winner, isNull);
    });
  });

  group('rankInterconnectCandidates', () {
    test('单地址组（含全部老条目）原样、不探测', () async {
      int probes = 0;
      final List<FushiClientUrl> ranked = await rankInterconnectCandidates(
        <FushiClientUrl>[url('http://a:1'), url('http://b:1')],
        probe: (FushiClientUrl c, String? _) async {
          probes++;
          return true;
        },
      );
      expect(ranked.map((FushiClientUrl u) => u.url), <String>[
        'http://a:1',
        'http://b:1',
      ]);
      expect(probes, 0);
    });

    test('组内可达者排到组首、组间顺序保持；结果缓存复用', () async {
      int probes = 0;
      Future<bool> probe(FushiClientUrl c, String? hostId) async {
        probes++;
        expect(hostId, 'A');
        return c.url == 'http://v6:1';
      }

      final List<FushiClientUrl> list = <FushiClientUrl>[
        url('http://lan:1', host: 'A'),
        url('http://other:1'),
        url('http://v6:1', host: 'A', learned: true),
      ];
      final List<FushiClientUrl> ranked = await rankInterconnectCandidates(
        list,
        probe: probe,
      );
      expect(ranked.map((FushiClientUrl u) => u.url), <String>[
        'http://v6:1',
        'http://lan:1',
        'http://other:1',
      ]);
      expect(probes, 2);

      await rankInterconnectCandidates(list, probe: probe);
      expect(probes, 2, reason: '30 秒内复用上次胜出地址');
    });
  });

  group('mergeLearnedHostAddresses', () {
    const List<InterconnectHostAddress> published = <InterconnectHostAddress>[
      InterconnectHostAddress(
        url: 'http://192.168.1.5:38765',
        kind: InterconnectAddressKind.lan,
      ),
      InterconnectHostAddress(
        url: 'http://[2408::5]:38765',
        kind: InterconnectAddressKind.ipv6,
      ),
      InterconnectHostAddress(
        url: 'p2p://node',
        kind: InterconnectAddressKind.p2p,
      ),
    ];

    test('锚点标 hostId；新地址按优先级插入，继承 token；p2p 默认不收', () {
      final List<FushiClientUrl> merged = mergeLearnedHostAddresses(
        <FushiClientUrl>[
          const FushiClientUrl(url: 'https://home.example', token: 'T'),
          url('http://other:1'),
        ],
        anchorUrl: 'https://home.example',
        hostId: 'A',
        addresses: published,
      );
      expect(merged.map((FushiClientUrl u) => u.url), <String>[
        'http://192.168.1.5:38765',
        'http://[2408::5]:38765',
        'https://home.example',
        'http://other:1',
      ]);
      expect(merged[2].hostId, 'A');
      expect(merged[2].learned, isFalse);
      expect(merged[0].learned, isTrue);
      expect(merged[0].token, 'T');
      expect(merged[0].fingerprintSha256, isNull, reason: '明文地址不带指纹');
      expect(merged[3].hostId, isNull, reason: '别的 host 不受影响');
    });

    test('host 不再公布的 learned 地址被删；手输条目永不删', () {
      final List<FushiClientUrl> merged = mergeLearnedHostAddresses(
        <FushiClientUrl>[
          url('http://10.0.0.9:38765', host: 'A', learned: true),
          url('http://192.168.9.9:38765', host: 'A'),
          url('https://home.example', host: 'A'),
        ],
        anchorUrl: 'https://home.example',
        hostId: 'A',
        addresses: const <InterconnectHostAddress>[],
      );
      expect(merged.map((FushiClientUrl u) => u.url), <String>[
        'http://192.168.9.9:38765',
        'https://home.example',
      ]);
    });

    test('手输的同一地址被 host 公布 → 归入该组（不重复添加）', () {
      final List<FushiClientUrl> merged = mergeLearnedHostAddresses(
        <FushiClientUrl>[
          url('http://192.168.1.5:38765'),
          url('https://home.example'),
        ],
        anchorUrl: 'https://home.example',
        hostId: 'A',
        addresses: published.take(1).toList(),
      );
      expect(merged, hasLength(2));
      expect(merged[0].hostId, 'A');
      expect(merged[0].learned, isFalse);
    });

    test('锚点已被删 → 原样返回', () {
      final List<FushiClientUrl> list = <FushiClientUrl>[url('http://x:1')];
      expect(
        mergeLearnedHostAddresses(
          list,
          anchorUrl: 'http://gone:1',
          hostId: 'A',
          addresses: published,
        ),
        same(list),
      );
    });

    test('开启 P2P 能力后收 p2p 地址，排在最后', () {
      setInterconnectAcceptsP2pAddresses(true);
      addTearDown(() => setInterconnectAcceptsP2pAddresses(false));
      final List<FushiClientUrl> merged = mergeLearnedHostAddresses(
        <FushiClientUrl>[url('https://home.example')],
        anchorUrl: 'https://home.example',
        hostId: 'A',
        addresses: published,
      );
      expect(merged.last.url, 'p2p://node');
    });
  });

  group('真 host 端到端', () {
    late Directory dir;
    late FushiSyncServer server;
    late FushiDatabase db;
    late SyncRepository repo;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fushi_peer_addr_test');
      server =
          FushiSyncServer(
              syncDataDir: dir.path,
              port: 0,
              token: 'shared-token',
              allowLan: true,
            )
            ..hostId = 'HOST-1'
            ..publicUrlsProvider = (() async => <String>[
              'https://home.example',
            ])
            ..interfaceLister = (() async => <NetworkInterface>[
              _FakeNic('Ethernet', <InternetAddress>[
                InternetAddress('192.168.77.5'),
                InternetAddress('2408:8207::5'),
              ]),
              _FakeNic('docker0', <InternetAddress>[
                InternetAddress('172.17.0.1'),
              ]),
            ]);
      await server.start();
      db = FushiDatabase(dir.path);
      repo = SyncRepository(db);
      InterconnectAddressLearner.resetForTest();
    });

    tearDown(() async {
      await server.stop();
      await db.close();
      await cleanupTempDir(dir);
    });

    test('ping 身份核对：hostId 相符才算可达', () async {
      final FushiClientUrl self = FushiClientUrl(
        url: 'http://127.0.0.1:${server.port}',
      );
      expect(await defaultInterconnectAddressProbe(self, 'HOST-1'), isTrue);
      expect(
        await defaultInterconnectAddressProbe(self, 'SOMEONE-ELSE'),
        isFalse,
      );
      expect(await defaultInterconnectAddressProbe(self, null), isTrue);
    });

    test('配对后学习：host 公布的地址集并入候选列表', () async {
      final String anchor = 'http://127.0.0.1:${server.port}';
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: anchor, token: 'shared-token'),
      ]);
      final int revisionBefore = SyncRepository.fushiClientUrlsRevision.value;

      final bool changed = await InterconnectAddressLearner(
        repo,
      ).refresh((await repo.getFushiClientUrls()).single);

      expect(changed, isTrue);
      final List<FushiClientUrl> urls = await repo.getFushiClientUrls();
      final int port = server.port;
      expect(urls.map((FushiClientUrl u) => u.url), <String>[
        'http://192.168.77.5:$port',
        'http://[2408:8207::5]:$port',
        anchor,
        'https://home.example',
      ]);
      expect(urls.every((FushiClientUrl u) => u.hostId == 'HOST-1'), isTrue);
      expect(urls.where((FushiClientUrl u) => !u.learned).single.url, anchor);
      expect(
        SyncRepository.fushiClientUrlsRevision.value,
        greaterThan(revisionBefore),
        reason: '设置页靠这个广播重载，否则下次编辑会覆盖学到的地址',
      );
      expect(interconnectPeerRepresentatives(urls).single.url, anchor);

      // 再学一次：无变化、不写盘。
      expect(
        await InterconnectAddressLearner(
          repo,
        ).refresh(urls.firstWhere((FushiClientUrl u) => u.url == anchor)),
        isFalse,
      );
    });

    test('无 token 的请求拿不到地址集（端点需鉴权）', () async {
      final HttpClient client = HttpClient();
      addTearDown(client.close);
      final HttpClientResponse resp = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/api/host/addresses'),
      )).close();
      await resp.drain<void>();
      expect(resp.statusCode, 401);
    });

    test('没有 hostId 的 host 不公布地址集（404，client 不学）', () async {
      server.hostId = null;
      final String anchor = 'http://127.0.0.1:${server.port}';
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: anchor, token: 'shared-token'),
      ]);
      expect(
        await InterconnectAddressLearner(
          repo,
        ).refresh((await repo.getFushiClientUrls()).single),
        isFalse,
      );
      expect((await repo.getFushiClientUrls()).single.hostId, isNull);
    });
  });
}

class _FakeNic implements NetworkInterface {
  _FakeNic(this.name, this.addresses);

  @override
  final String name;

  @override
  final List<InternetAddress> addresses;

  @override
  int get index => 0;
}
