/// 「下载后端 = 互联设备」端到端：真实 [FushiSyncServer] 挂一个假引擎，客户端用
/// 真实的 [RemoteFushiTorrentBackend] 经 [InterconnectHostChannel] 打过去。
///
/// 守的是 host 侧两道边界与 wire 往返：
/// * 只有已配对设备自己的凭据能用（共享 token → 403，客户端得到失败值而不是抛）；
/// * 远程只看得见、改得了自己经本路由加进去的种子（租约），host 自己的种子不可见；
/// * 保存目录 / 移动目标越出白名单根一律拒绝；改名不许 `..`；
/// * 租约落盘、换实例读得回（host 重启后 resume 剪枝不会删远程任务）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/app_peer_torrent_engine.dart';
import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/interconnect_torrent_engine_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/remote_torrent_wire.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/torrent_engine/host_torrent_engine.dart';
import 'package:path/path.dart' as p;

const String _hostId = 'vm-host-1';
const String _sharedToken = 'shared-token';
const String _peerToken = 'peer-token-of-pc';
const String _otherPeerToken = 'peer-token-of-phone';
const String _hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _hostOwnHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _FakeTorrent {
  _FakeTorrent(this.hash, this.savePath, {this.paused = false});
  final String hash;
  String savePath;
  bool paused;
  final List<TorrentFilePriority> priorities = <TorrentFilePriority>[
    TorrentFilePriority.normal,
    TorrentFilePriority.normal,
  ];
  final List<String> trackers = <String>[];
}

class _FakeBackend
    implements
        TorrentRemovalBackend,
        TorrentPauseBackend,
        TorrentDetailBackend,
        TorrentMetainfoBackend,
        TorrentPausedMetainfoBackend,
        TorrentBulkFilePriorityBackend,
        TorrentTrackerMutationBackend {
  final Map<String, _FakeTorrent> torrents = <String, _FakeTorrent>{};
  int addCalls = 0;
  int closeCalls = 0;

  @override
  bool get pauseControlAvailable => true;
  @override
  bool get detailAvailable => true;

  @override
  Future<String?> probeConnection() async => 'libtorrent 2.0-test';
  @override
  Future<bool> prepareCategory(String category) async => true;

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    String? savePath,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async {
    addCalls++;
    final String hash = RegExp(
      r'btih:([0-9a-f]{40})',
    ).firstMatch(magnetOrUrl)!.group(1)!;
    if (torrents.containsKey(hash)) return false;
    torrents[hash] = _FakeTorrent(hash, savePath ?? '/default/$category');
    return true;
  }

  @override
  Future<bool> addTorrentMetainfo(
    TorrentMetainfoPayload payload, {
    required String category,
    String? savePath,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async {
    addCalls++;
    torrents[payload.torrentId!] = _FakeTorrent(
      payload.torrentId!,
      savePath ?? '/default/$category',
    );
    return true;
  }

  @override
  Future<bool> addTorrentMetainfoPaused(
    TorrentMetainfoPayload payload, {
    required String category,
    String? savePath,
  }) async {
    addCalls++;
    torrents[payload.torrentId!] = _FakeTorrent(
      payload.torrentId!,
      savePath ?? '/default/$category',
      paused: true,
    );
    return true;
  }

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      <TorrentSnapshot>[
        for (final _FakeTorrent t in torrents.values)
          TorrentSnapshot(
            hash: t.hash,
            name: 'name-${t.hash.substring(0, 4)}',
            progress: 0.5,
            state: t.paused ? 'pausedDL' : 'downloading',
            savePath: t.savePath,
            contentPath: '${t.savePath}/x',
            amountLeft: 10,
            totalSizeBytes: 20,
            downRateBps: 7,
            numSeeds: 3,
          ),
      ];

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async =>
      <TorrentFileEntry>[
        const TorrentFileEntry(name: 'a.mkv', size: 10, progress: 1, index: 0),
        const TorrentFileEntry(name: 'b.mkv', size: 10, progress: 0, index: 1),
      ];

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async => TorrentStorageResult(ok: true, path: newPath);

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async {
    torrents[torrentId]!.savePath = newSavePath;
    return TorrentStorageResult(ok: true, path: newSavePath);
  }

  @override
  Future<bool> removeTorrent(
    String torrentId, {
    bool deleteFiles = false,
  }) async => torrents.remove(torrentId) != null;

  @override
  Future<bool> pauseTorrent(String torrentId) async {
    torrents[torrentId]!.paused = true;
    return true;
  }

  @override
  Future<bool> resumeTorrent(String torrentId) async {
    torrents[torrentId]!.paused = false;
    return true;
  }

  @override
  Future<bool> addTrackers(
    String torrentId,
    Iterable<String> trackerUrls,
  ) async {
    torrents[torrentId]!.trackers.addAll(trackerUrls);
    return true;
  }

  @override
  Future<List<TorrentFilePriority>?> filePriorities(String torrentId) async =>
      torrents[torrentId]?.priorities;

  @override
  Future<bool> setFilePriority(
    String torrentId,
    int fileIndex,
    TorrentFilePriority priority,
  ) => setFilePriorities(torrentId, <int>[fileIndex], priority);

  @override
  Future<bool> setFilePriorities(
    String torrentId,
    Iterable<int> fileIndexes,
    TorrentFilePriority priority,
  ) async {
    for (final int i in fileIndexes) {
      torrents[torrentId]!.priorities[i] = priority;
    }
    return true;
  }

  @override
  Future<List<TorrentPeerDetail>?> listPeers(String torrentId) async =>
      const <TorrentPeerDetail>[
        TorrentPeerDetail(address: '1.2.3.4', port: 6881, client: 'qB'),
      ];

  @override
  Future<List<TorrentTrackerDetail>?> listTrackers(
    String torrentId,
  ) async => const <TorrentTrackerDetail>[
    TorrentTrackerDetail(url: 'udp://t', status: TorrentTrackerStatus.working),
  ];

  @override
  Future<TorrentSessionStatusInfo?> sessionStatus() async =>
      const TorrentSessionStatusInfo(dhtEnabled: true, listenPort: 6881);

  @override
  Future<TorrentPieceStates?> pieceStates(String torrentId) async =>
      const TorrentPieceStates(states: <int>[2, 0, 1]);

  @override
  void close() => closeCalls++;
}

class _FakeEngine implements HostTorrentEngine {
  _FakeEngine(this.backend, this._leases, this._paths);

  final _FakeBackend backend;
  final PeerTorrentLeaseStore _leases;
  final HostTorrentPathPolicy _paths;

  @override
  Future<PeerTorrentLeaseStore?> leases() async => _leases;

  @override
  Future<HostTorrentPathPolicy> paths() async => _paths;

  @override
  Future<TorrentEngineCapability> capability() async => TorrentEngineCapability(
    supported: true,
    backend: 'embedded',
    features: torrentEngineFeaturesOf(backend),
    pauseControlAvailable: true,
    detailAvailable: true,
    allowedRoots: _paths.roots,
  );

  @override
  Future<R?> withBackend<R>(
    Future<R> Function(TorrentBackend backend) action,
  ) => action(backend);
}

/// 最小合法 v1 .torrent：单文件 `a.txt`。
Uint8List _torrentBytes() {
  final List<int> pieces = List<int>.filled(20, 7);
  final BytesBuilder info = BytesBuilder()
    ..add(
      utf8.encode('d6:lengthi5e4:name5:a.txt12:piece lengthi16384e6:pieces20:'),
    )
    ..add(pieces)
    ..add(utf8.encode('e'));
  return (BytesBuilder()
        ..add(utf8.encode('d4:info'))
        ..add(info.toBytes())
        ..add(utf8.encode('e')))
      .toBytes();
}

String _infoHashOf(Uint8List torrent) {
  // info 字典紧跟在 `d4:info` 之后、到最后一个 `e` 之前。
  final Uint8List info = Uint8List.sublistView(torrent, 7, torrent.length - 1);
  return sha1.convert(info).toString();
}

FushiSyncServer buildServer(HostTorrentEngine engine, String syncDir) =>
    FushiSyncServer(
        syncDataDir: syncDir,
        port: 0,
        token: _sharedToken,
        torrentEngine: engine,
        deviceName: 'VM',
      )
      ..hostId = _hostId
      ..pairedPeerCredentialsProvider = (() async => <String, String>{
        'pc-device': _peerToken,
        'phone-device': _otherPeerToken,
      });

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SyncRepository repo;
  late _FakeBackend backend;
  late PeerTorrentLeaseStore leases;
  late String allowedRoot;
  late FushiSyncServer server;

  setUp(() async {
    resetRemoteTorrentEngineCapabilityCache();
    tmp = Directory.systemTemp.createTempSync('fushi-torrent-engine-');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
    backend = _FakeBackend();
    // host 自己管线的种子：远程不可见。
    backend.torrents[_hostOwnHash] = _FakeTorrent(_hostOwnHash, '/host/own');
    allowedRoot = p.join(tmp.path, 'peer-library');
    leases = PeerTorrentLeaseStore(File(p.join(tmp.path, 'leases.json')));
    server = buildServer(
      _FakeEngine(
        backend,
        leases,
        HostTorrentPathPolicy(<String>[allowedRoot]),
      ),
      p.join(tmp.path, 'sync'),
    );
    await server.start();
  });

  /// 换一个引擎实现重起 host（端口重新分配；客户端按新端口登记）。
  Future<void> restartWith(HostTorrentEngine engine) async {
    await server.stop();
    server = buildServer(engine, p.join(tmp.path, 'sync'));
    await server.start();
    resetRemoteTorrentEngineCapabilityCache();
  }

  tearDown(() async {
    await server.stop();
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<RemoteFushiTorrentBackend> client({String token = _peerToken}) async {
    final String url = 'http://127.0.0.1:${server.port}';
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: url, deviceName: 'VM', hostId: _hostId, token: token),
    ]);
    final RemoteFushiTorrentBackend b = RemoteFushiTorrentBackend(
      repo: repo,
      host: InterconnectHostRef.persisted(hostId: _hostId, anchorUrl: url),
    );
    addTearDown(b.close);
    return b;
  }

  String magnet(String hash) => 'magnet:?xt=urn:btih:$hash&dn=x';

  test('probe 拿到对端引擎版本，能力位进缓存', () async {
    final RemoteFushiTorrentBackend b = await client();
    expect(await b.probeConnection(), 'Fushi embedded libtorrent 2.0-test');
    expect(b.capability?.allowedRoots, <String>[p.normalize(allowedRoot)]);
    expect(b.capability?.has(TorrentEngineFeature.bulkPriority), isTrue);
    expect(b.pauseControlAvailable, isTrue);
  });

  test('加种子落进白名单根 → 登记租约；列表只含远程任务', () async {
    final RemoteFushiTorrentBackend b = await client();
    final String save = p.join(allowedRoot, '.fushi-incoming', 'fushi');
    expect(
      await b.addTorrent(magnet(_hashA), category: 'fushi', savePath: save),
      isTrue,
    );
    expect(await leases.contains(_hashA), isTrue);
    expect(
      await PeerTorrentLeaseStore(
        File(p.join(tmp.path, 'leases.json')),
      ).hashes(),
      <String>{_hashA},
      reason: '租约落盘：host 重启后 resume 保留集合里还有它',
    );

    final List<TorrentSnapshot> listed = await b.listTorrents();
    expect(listed.map((TorrentSnapshot s) => s.hash), <String>[_hashA]);
    expect(listed.single.savePath, p.normalize(save));
    expect(listed.single.totalSizeBytes, 20);
    expect(listed.single.numSeeds, 3);
  });

  test('host 自己的种子对远程不存在：读不到、删不掉、改不了', () async {
    final RemoteFushiTorrentBackend b = await client();
    expect(await b.listFiles(_hostOwnHash), isEmpty);
    expect(await b.removeTorrent(_hostOwnHash, deleteFiles: true), isFalse);
    expect(await b.pauseTorrent(_hostOwnHash), isFalse);
    final TorrentStorageResult moved = await b.moveStorage(
      _hostOwnHash,
      allowedRoot,
    );
    expect(moved.ok, isFalse);
    expect(backend.torrents[_hostOwnHash]!.savePath, '/host/own');
  });

  test('host 已有同一颗种子：不让远程接管，不登记租约', () async {
    final RemoteFushiTorrentBackend b = await client();
    expect(
      await b.addTorrent(magnet(_hostOwnHash), category: 'fushi'),
      isFalse,
    );
    expect(await leases.contains(_hostOwnHash), isFalse);
  });

  test('租约按设备隔离：别的已配对设备看不到、改不了、删不掉、也接管不了', () async {
    final RemoteFushiTorrentBackend pc = await client();
    final String save = p.join(allowedRoot, 'pc');
    expect(
      await pc.addTorrent(magnet(_hashA), category: 'fushi', savePath: save),
      isTrue,
    );

    final RemoteFushiTorrentBackend phone = await client(
      token: _otherPeerToken,
    );
    expect(await phone.listTorrents(), isEmpty);
    expect(await phone.listFiles(_hashA), isEmpty);
    expect(await phone.pauseTorrent(_hashA), isFalse);
    expect(
      (await phone.moveStorage(_hashA, p.join(allowedRoot, 'x'))).ok,
      isFalse,
    );
    expect(await phone.removeTorrent(_hashA, deleteFiles: true), isFalse);
    // 同一颗种子再交一次：不接管，不改登记。
    expect(await phone.addTorrent(magnet(_hashA), category: 'fushi'), isFalse);
    expect(backend.torrents[_hashA]!.paused, isFalse);
    expect(backend.torrents[_hashA]!.savePath, p.normalize(save));
    expect(await leases.contains(_hashA), isTrue);

    final RemoteFushiTorrentBackend pcAgain = await client();
    expect(
      (await pcAgain.listTorrents()).map((TorrentSnapshot s) => s.hash),
      <String>[_hashA],
    );
    expect(await pcAgain.pauseTorrent(_hashA), isTrue);
  });

  test('保存目录越出白名单根 → 拒绝，引擎没被调用', () async {
    final RemoteFushiTorrentBackend b = await client();
    expect(
      await b.addTorrent(
        magnet(_hashA),
        category: 'fushi',
        savePath: p.join(tmp.path, 'elsewhere'),
      ),
      isFalse,
    );
    expect(
      await b.addTorrent(
        magnet(_hashA),
        category: 'fushi',
        savePath: p.join(allowedRoot, '..', 'escape'),
      ),
      isFalse,
    );
    expect(backend.addCalls, 0);
    expect(await leases.hashes(), isEmpty);
  });

  test('分类名不能带路径分隔符', () async {
    final RemoteFushiTorrentBackend b = await client();
    expect(await b.prepareCategory('../etc'), isFalse);
    expect(await b.addTorrent(magnet(_hashA), category: 'a/b'), isFalse);
  });

  test('移动越界报原因；白名单内照常移动；改名不许 ..', () async {
    final RemoteFushiTorrentBackend b = await client();
    await b.addTorrent(magnet(_hashA), category: 'fushi');
    final TorrentStorageResult bad = await b.moveStorage(
      _hashA,
      p.join(tmp.path, 'outside'),
    );
    expect(bad.ok, isFalse);
    expect(bad.error, contains('outside'));

    final String target = p.join(allowedRoot, 'Show');
    final TorrentStorageResult ok = await b.moveStorage(_hashA, target);
    expect(ok.ok, isTrue);
    expect(backend.torrents[_hashA]!.savePath, p.normalize(target));

    final TorrentStorageResult escape = await b.renameFile(
      _hashA,
      0,
      '../../evil.mkv',
    );
    expect(escape.ok, isFalse);
    final TorrentStorageResult renamed = await b.renameFile(
      _hashA,
      0,
      'Season 01/E01.mkv',
    );
    expect(renamed.ok, isTrue);
    expect(renamed.path, 'Season 01/E01.mkv');
  });

  test('删除释放租约；暂停 / 恢复 / 优先级 / 详情往返', () async {
    final RemoteFushiTorrentBackend b = await client();
    await b.addTorrent(magnet(_hashA), category: 'fushi');

    expect(await b.pauseTorrent(_hashA), isTrue);
    expect(backend.torrents[_hashA]!.paused, isTrue);
    expect(await b.resumeTorrent(_hashA), isTrue);

    expect(
      await b.setFilePriorities(_hashA, <int>[1], TorrentFilePriority.skip),
      isTrue,
    );
    expect(await b.filePriorities(_hashA), <TorrentFilePriority>[
      TorrentFilePriority.normal,
      TorrentFilePriority.skip,
    ]);
    expect(
      (await b.listFiles(_hashA)).map((TorrentFileEntry f) => f.name),
      <String>['a.mkv', 'b.mkv'],
    );
    expect((await b.listPeers(_hashA))!.single.address, '1.2.3.4');
    expect(
      (await b.listTrackers(_hashA))!.single.status,
      TorrentTrackerStatus.working,
    );
    expect((await b.pieceStates(_hashA))!.states, <int>[2, 0, 1]);
    expect((await b.sessionStatus())!.listenPort, 6881);
    expect(await b.addTrackers(_hashA, <String>['udp://x']), isTrue);
    expect(backend.torrents[_hashA]!.trackers, <String>['udp://x']);

    expect(await b.removeTorrent(_hashA), isTrue);
    expect(await leases.contains(_hashA), isFalse);
    expect(await b.listTorrents(), isEmpty);
  });

  test('.torrent 以暂停态交给对端：hash 由 host 自己从字节算', () async {
    final RemoteFushiTorrentBackend b = await client();
    final Uint8List bytes = _torrentBytes();
    final String hash = _infoHashOf(bytes);
    final bool ok = await b.addTorrentMetainfoPaused(
      TorrentMetainfoPayload(
        bytes: bytes,
        fileName: 'a.torrent',
        // client 报一个假 id：host 不信它。
        torrentId: 'c' * 40,
      ),
      category: 'fushi',
    );
    expect(ok, isTrue);
    expect(await leases.hashes(), <String>{hash});
    expect(backend.torrents[hash]!.paused, isTrue);
  });

  test('共享 token（非已配对设备凭据）→ 403，客户端只得到失败值', () async {
    final RemoteFushiTorrentBackend b = await client(token: _sharedToken);
    expect(await b.addTorrent(magnet(_hashA), category: 'fushi'), isFalse);
    expect(await b.listTorrents(), isEmpty);
    expect(backend.addCalls, 0);
  });

  group('app 当 host（AppPeerTorrentEngine）', () {
    test('下载中心没起（租约位置未定）→ 503、能力报不支持、不建后端', () async {
      int built = 0;
      await restartWith(
        AppPeerTorrentEngine(
          leases: () => null,
          roots: () async => <String>[allowedRoot],
          backend: () {
            built++;
            return backend;
          },
          traits: () => (backend: 'embedded', pause: true, detail: true),
        ),
      );
      final RemoteFushiTorrentBackend b = await client();
      final TorrentEngineCapability? cap = await b.refreshCapability();
      expect(cap?.supported, isFalse);
      expect(await b.addTorrent(magnet(_hashA), category: 'fushi'), isFalse);
      expect(await b.listTorrents(), isEmpty);
      expect(built, 0);
      expect(backend.addCalls, 0);
    });

    test('就绪：与服务端同契约，落盘根取本机根，后端每次用完即关', () async {
      await restartWith(
        AppPeerTorrentEngine(
          leases: () => leases,
          roots: () async => <String>[allowedRoot],
          backend: () => backend,
          // 内置引擎没起 session 时详情能力未知：如实报 null。
          traits: () => (backend: 'embedded', pause: true, detail: null),
        ),
      );
      final RemoteFushiTorrentBackend b = await client();
      final TorrentEngineCapability? cap = await b.refreshCapability();
      expect(cap?.supported, isTrue);
      expect(cap?.backend, 'embedded');
      expect(cap?.features, kAllTorrentEngineFeatures);
      expect(cap?.detailAvailable, isNull);
      expect(b.detailAvailable, isTrue); // 未知按乐观处理
      expect(cap?.allowedRoots, <String>[p.normalize(allowedRoot)]);

      final String save = p.join(allowedRoot, 'Show');
      expect(
        await b.addTorrent(magnet(_hashA), category: 'fushi', savePath: save),
        isTrue,
      );
      expect(await leases.contains(_hashA), isTrue);
      expect(backend.closeCalls, greaterThan(0));
      expect(
        await b.addTorrent(
          magnet('c' * 40),
          category: 'fushi',
          savePath: p.join(tmp.path, 'outside'),
        ),
        isFalse,
      );
      expect(
        (await b.listTorrents()).map((TorrentSnapshot t) => t.hash),
        <String>[_hashA],
      );
    });

    test('本机没有可借的后端（例如自己也在借别人的）→ 不支持', () async {
      await restartWith(
        AppPeerTorrentEngine(
          leases: () => leases,
          roots: () async => <String>[allowedRoot],
          backend: () => null,
          traits: () => null,
        ),
      );
      final RemoteFushiTorrentBackend b = await client();
      expect((await b.refreshCapability())?.supported, isFalse);
      expect(await b.addTorrent(magnet(_hashA), category: 'fushi'), isFalse);
    });
  });

  test('租约变更回调带着全部 hash（宿主据此即时更新 resume 保留集合）', () async {
    final List<Set<String>> seen = <Set<String>>[];
    final PeerTorrentLeaseStore store = PeerTorrentLeaseStore(
      File(p.join(tmp.path, 'cb.json')),
      onChanged: seen.add,
    );
    await store.add(_hashA, owner: 'o');
    await store.add(_hostOwnHash, owner: 'o');
    await store.remove(_hashA);
    expect(seen, <Set<String>>[
      <String>{_hashA},
      <String>{_hashA, _hostOwnHash},
      <String>{_hostOwnHash},
    ]);
  });
}
