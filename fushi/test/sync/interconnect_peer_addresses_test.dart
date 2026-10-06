import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:http/http.dart' as http;

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
        url: 'https://192.168.1.5:38765',
        kind: InterconnectAddressKind.lan,
      ),
      InterconnectHostAddress(
        url: 'https://[2408::5]:38765',
        kind: InterconnectAddressKind.ipv6,
      ),
      InterconnectHostAddress(
        url: 'p2p://node',
        kind: InterconnectAddressKind.p2p,
      ),
    ];

    test('锚点标 hostId；新地址按优先级插入，继承 token 与指纹；p2p 默认不收', () {
      final List<FushiClientUrl> merged = mergeLearnedHostAddresses(
        <FushiClientUrl>[
          const FushiClientUrl(
            url: 'https://home.example',
            token: 'T',
            fingerprintSha256: 'aa:bb',
          ),
          url('http://other:1'),
        ],
        anchorUrl: 'https://home.example',
        hostId: 'A',
        addresses: published,
      );
      expect(merged.map((FushiClientUrl u) => u.url), <String>[
        'https://192.168.1.5:38765',
        'https://[2408::5]:38765',
        'https://home.example',
        'http://other:1',
      ]);
      expect(merged[2].hostId, 'A');
      expect(merged[2].learned, isFalse);
      expect(merged[0].learned, isTrue);
      expect(merged[0].token, 'T');
      expect(merged[0].fingerprintSha256, 'aa:bb');
      expect(merged[0].addressKind, 'lan');
      expect(merged[3].hostId, isNull, reason: '别的 host 不受影响');
    });

    test('明文 http 地址一律不学（学到的 LAN 地址换网可能是别人的机器）', () {
      final List<FushiClientUrl> merged = mergeLearnedHostAddresses(
        <FushiClientUrl>[url('https://home.example')],
        anchorUrl: 'https://home.example',
        hostId: 'A',
        addresses: const <InterconnectHostAddress>[
          InterconnectHostAddress(
            url: 'http://192.168.1.5:38765',
            kind: InterconnectAddressKind.lan,
          ),
          InterconnectHostAddress(
            url: 'http://[2408::5]:38765',
            kind: InterconnectAddressKind.ipv6,
          ),
        ],
      );
      expect(merged.map((FushiClientUrl u) => u.url), <String>[
        'https://home.example',
      ]);
    });

    test('host 不再公布的 learned 地址被删；手输条目永不删', () {
      final List<FushiClientUrl> merged = mergeLearnedHostAddresses(
        <FushiClientUrl>[
          url('https://10.0.0.9:38765', host: 'A', learned: true),
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
          url('https://192.168.1.5:38765'),
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

    test('已配对的别台 host 自报真 host 的 hostId：不并组、不删真 host 的地址（审查 B1）', () {
      final List<FushiClientUrl> list = <FushiClientUrl>[
        const FushiClientUrl(
          url: 'https://a.example',
          token: 'TA',
          fingerprintSha256: 'aa:aa',
          hostId: 'A',
        ),
        const FushiClientUrl(
          url: 'https://10.0.0.5:38765',
          token: 'TA',
          fingerprintSha256: 'aa:aa',
          hostId: 'A',
          learned: true,
        ),
        const FushiClientUrl(
          url: 'https://m.example',
          token: 'TM',
          fingerprintSha256: 'mm:mm',
        ),
      ];
      final List<FushiClientUrl> merged = mergeLearnedHostAddresses(
        list,
        anchorUrl: 'https://m.example',
        hostId: 'A',
        addresses: const <InterconnectHostAddress>[
          InterconnectHostAddress(
            url: 'https://evil.example:38765',
            kind: InterconnectAddressKind.public,
          ),
        ],
      );
      expect(merged, same(list));
    });

    test('明文锚点不能并入已有的组（链接走 http 配对，指纹只是链接声明，审查 B2）', () {
      final List<FushiClientUrl> list = <FushiClientUrl>[
        const FushiClientUrl(
          url: 'https://a.example',
          fingerprintSha256: 'aa:aa',
          hostId: 'A',
        ),
        const FushiClientUrl(url: 'http://attacker:38765'),
      ];
      final List<FushiClientUrl> merged = mergeLearnedHostAddresses(
        list,
        anchorUrl: 'http://attacker:38765',
        hostId: 'A',
        addresses: const <InterconnectHostAddress>[],
      );
      expect(merged, same(list));
    });

    test('同一张证书的新地址可以加入已有的组', () {
      final List<FushiClientUrl> merged = mergeLearnedHostAddresses(
        <FushiClientUrl>[
          const FushiClientUrl(
            url: 'https://a.example',
            fingerprintSha256: 'aa:aa',
            hostId: 'A',
          ),
          const FushiClientUrl(
            url: 'https://a2.example',
            fingerprintSha256: 'AA:AA',
          ),
        ],
        anchorUrl: 'https://a2.example',
        hostId: 'A',
        addresses: const <InterconnectHostAddress>[],
      );
      expect(merged[1].hostId, 'A');
    });

    test('锚点已属别的 hostId：拒绝换组', () {
      final List<FushiClientUrl> list = <FushiClientUrl>[
        const FushiClientUrl(
          url: 'https://b.example',
          fingerprintSha256: 'bb:bb',
          hostId: 'B',
        ),
      ];
      expect(
        mergeLearnedHostAddresses(
          list,
          anchorUrl: 'https://b.example',
          hostId: 'A',
          addresses: const <InterconnectHostAddress>[],
        ),
        same(list),
      );
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

    test('组网私网段按 host 标注的种类排在物理 LAN 之后', () {
      final List<FushiClientUrl> merged = mergeLearnedHostAddresses(
        <FushiClientUrl>[url('https://home.example')],
        anchorUrl: 'https://home.example',
        hostId: 'A',
        addresses: const <InterconnectHostAddress>[
          InterconnectHostAddress(
            url: 'https://10.147.17.3:1',
            kind: InterconnectAddressKind.overlay,
          ),
          InterconnectHostAddress(
            url: 'https://192.168.1.5:1',
            kind: InterconnectAddressKind.lan,
          ),
        ],
      );
      expect(merged.map((FushiClientUrl u) => u.url).take(2), <String>[
        'https://192.168.1.5:1',
        'https://10.147.17.3:1',
      ]);
    });
  });

  group('真 host 端到端', () {
    late Directory dir;
    late FushiSyncServer server;
    late FushiDatabase db;
    late SyncRepository repo;
    late String fingerprint;

    Future<void> startHost({required bool tls}) async {
      dir = await Directory.systemTemp.createTemp('fushi_peer_addr_test');
      SecurityContext? ctx;
      if (tls) {
        final FushiTlsIdentity id = await FushiTlsIdentityStore(
          dataDir: dir.path,
        ).loadOrCreate();
        fingerprint = id.fingerprintSha256;
        ctx = SecurityContext()
          ..useCertificateChainBytes(utf8.encode(id.certificatePem))
          ..usePrivateKeyBytes(utf8.encode(id.privateKeyPem));
      }
      server =
          FushiSyncServer(
              syncDataDir: dir.path,
              port: 0,
              token: 'shared-token',
              allowLan: true,
              securityContext: ctx,
              hostFingerprint: tls ? fingerprint : null,
            )
            ..hostId = 'HOST-1'
            ..publicUrlsProvider = (() async => <String>[
              'https://home.example',
              'http://plain.example',
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
    }

    tearDown(() async {
      await server.stop();
      await db.close();
      await cleanupTempDir(dir);
    });

    test('ping 身份核对：hostId 相符才算可达', () async {
      await startHost(tls: false);
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

    test('TLS host：经钉扎锚点学到 https 地址集，明文地址不公布', () async {
      await startHost(tls: true);
      final String anchor = 'https://127.0.0.1:${server.port}';
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(
          url: anchor,
          token: 'shared-token',
          fingerprintSha256: fingerprint,
        ),
      ]);
      final int revisionBefore = SyncRepository.fushiClientUrlsRevision.value;

      final bool changed = await InterconnectAddressLearner(
        repo,
      ).refresh((await repo.getFushiClientUrls()).single);

      expect(changed, isTrue);
      final List<FushiClientUrl> urls = await repo.getFushiClientUrls();
      final int port = server.port;
      expect(
        urls.map((FushiClientUrl u) => u.url),
        <String>[
          'https://192.168.77.5:$port',
          'https://[2408:8207::5]:$port',
          anchor,
          'https://home.example',
        ],
        reason: 'http://plain.example 与 docker 网桥都不公布',
      );
      expect(urls.every((FushiClientUrl u) => u.hostId == 'HOST-1'), isTrue);
      expect(
        urls
            .firstWhere((FushiClientUrl u) => u.url.contains('77.5'))
            .fingerprintSha256,
        fingerprint,
        reason: '同一张自签证书，learned 地址照样钉扎',
      );
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

    test('明文 host：不公布明文地址；明文锚点根本不学', () async {
      await startHost(tls: false);
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
        addresses.map((dynamic a) => (a as Map<String, dynamic>)['url']),
        <String>['https://home.example'],
        reason: '网卡上的明文地址与 http 公网地址都不公布',
      );

      final String anchor = 'http://127.0.0.1:${server.port}';
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: anchor, token: 'shared-token'),
      ]);
      expect(
        await InterconnectAddressLearner(
          repo,
        ).refresh((await repo.getFushiClientUrls()).single),
        isFalse,
        reason: '明文锚点背后可能是冒名者，它公布的地址集会带着 token 落库',
      );
      expect((await repo.getFushiClientUrls()).single.hostId, isNull);
    });

    test('无 token 的请求拿不到地址集（端点需鉴权）', () async {
      await startHost(tls: false);
      final HttpClient client = HttpClient();
      addTearDown(client.close);
      final HttpClientResponse resp = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/api/host/addresses'),
      )).close();
      await resp.drain<void>();
      expect(resp.statusCode, 401);
    });

    test('没有 hostId 的 host 不公布地址集（404，client 不学）', () async {
      await startHost(tls: true);
      server.hostId = null;
      final String anchor = 'https://127.0.0.1:${server.port}';
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(
          url: anchor,
          token: 'shared-token',
          fingerprintSha256: fingerprint,
        ),
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
  _FakeNic(this.name, List<InternetAddress> addresses)
    : addresses = <InterfaceAddress>[
        for (final InternetAddress a in addresses) _FakeInterfaceAddress(a),
      ];

  @override
  final String name;

  // Dart 3.13 起 `NetworkInterface.addresses` 是 `List<InterfaceAddress>`。
  @override
  final List<InterfaceAddress> addresses;

  @override
  int get index => 0;
}

class _FakeInterfaceAddress implements InterfaceAddress {
  _FakeInterfaceAddress(this._address);

  final InternetAddress _address;

  @override
  int get prefixLength => _address.type == InternetAddressType.IPv4 ? 24 : 64;

  @override
  InternetAddress? get broadcast => null;

  @override
  InternetAddressType get type => _address.type;

  @override
  String get address => _address.address;

  @override
  String get host => _address.host;

  @override
  Uint8List get rawAddress => _address.rawAddress;

  @override
  bool get isLoopback => _address.isLoopback;

  @override
  bool get isLinkLocal => _address.isLinkLocal;

  @override
  bool get isMulticast => _address.isMulticast;

  @override
  Future<InternetAddress> reverse() => _address.reverse();
}
