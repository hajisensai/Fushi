// 设计稿 §6.3「客户端先升级，服务端还是旧版本」「服务端一直不升级」（规划 §6「§6.3 每一行一个测试」，交接「第六波 服务端
// 收尾」）：新代客户端用真内核、生产的同步执行端（[srsDefaultSyncRunner]）和真 HTTP 的远程复习探测 / 握手，对着一台还在
// 协议 3 上的服务端。
//
// 「旧服务端」= 协议 3 上最后一版带服务端复习的 fushi_server：换代分支的基线 develop `6dd38cb92d`（v3.3.0 的服务端还
// 没有复习库——`server_srs.dart` 是之后才加的——谈不上被围栏挡住）。树里没有冻结的那一版，它在这里是对外的两样东西：
// - 互联 host 目录（本地目录）：旧服务端读的是旧根 `v3/`，规则是 meta 的 `minReader` 大于自己（3）就整轮停下、复习服务
//   进「需要升级」（`srs_location_store.dart` 的 meta 判据、`server_srs.dart` 的 needsUpgrade 状态，按基线源码核）；
// - HTTP 主机：能力位只声明远程复习 V1，不认 V2 前缀（404，无机读码）——与基线的 `fushi_sync_server.dart` 相同。
//   制卡：needsUpgrade 的 profile 不就绪（`ServerSrsProfile.store` 只在 ready 时非空），复习这条落点没了；没带 Anki
//   helper 时 `ServerRemoteMiningService.miningAvailable` 为假，`capabilities.mining: false`、`/api/mine/forward` 在读请求体
//   之前回 404 `Mining off`（`remote_lookup_routes.dart` `handleMineForward`）。带了 Anki helper 的旧服务端照旧把卡落进
//   自己的 Anki（`resolveRemoteMiningTarget` 从复习退到 Anki），与库代无关，不在这里测。
//
// 「服务端先升级，客户端还是旧版本」在 packages/fushi_server/test/server_srs_generation_e2e_test.dart（真 HeadlessHost）。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/delegating_anki_repository.dart';
import 'package:fushi/src/anki/forwarded_mine_codec.dart';
import 'package:fushi/src/anki/pending_mining/pending_mine_store.dart';
import 'package:fushi/src/anki/pending_mining/pending_mining_anki_repository.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:fushi/src/srs/srs_remote_store_client.dart';
import 'package:fushi/src/sync/fushi_remote_mining_client.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_targets.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart' show srsLapisFieldId;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart'
    show kSrsRemoteStoreCapability;
import 'package:fushi_engine/srs/sync2/srs_host_directory.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart'
    show kSrsSync2Namespace;
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:path/path.dart' as p;

import 'srs_test_support.dart';

/// 协议 3 的读者版本：位置 meta 的 `minReader` 大于它就停下。
const int kProtocol3Reader = 3;

const String kOldHostId = 'old-protocol3-server';

/// 还在协议 3 上的服务端对外的 HTTP 面：能力位只有远程复习 V1；V2 前缀不认识（404 无机读码）。记下收到的请求。
class _OldHost {
  _OldHost._(this._server) {
    _server.listen((HttpRequest r) async {
      seen.add('${r.method} ${r.uri.path}');
      await r.drain<void>();
      if (r.method == 'GET' && r.uri.path == '/api/capabilities') {
        r.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, Object?>{
              kSrsRemoteStoreCapability: true,
              // 复习库「需要升级」、没带 Anki helper：没有可写的落点。
              'mining': false,
            }),
          );
      } else if (r.uri.path.startsWith('/api/mine') ||
          r.uri.path == '/api/duplicate') {
        r.response
          ..statusCode = HttpStatus.notFound
          ..write('Mining off');
      } else {
        r.response
          ..statusCode = HttpStatus.notFound
          ..write('Not Found');
      }
      await r.response.close();
    });
  }

  static Future<_OldHost> start() async =>
      _OldHost._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final List<String> seen = <String>[];

  FushiClientUrl get peer => FushiClientUrl(
    url: 'http://127.0.0.1:${_server.port}',
    token: 't',
    hostId: kOldHostId,
  );

  Future<void> close() => _server.close(force: true);
}

/// 本机 Anki：远端制卡模式下一律不该被叫到（[RemoteMiningAnkiRepository] 只在成功回包缺牌组名时读它的设置）。
class _NoLocalAnki extends BaseAnkiRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('local Anki must not run: ${invocation.memberName}');
}

/// 打开了「连不上时暂存」（[AnkiSettings.queueUndeliveredMinesEnabled]）的用户：其余照原链路。
class _QueueUndelivered extends DelegatingAnkiRepository {
  _QueueUndelivered(BaseAnkiRepository inner) : super(inner: inner);

  @override
  Future<AnkiSettings> loadSettings() async =>
      const AnkiSettings(queueUndeliveredMinesEnabled: true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory hostDir;
  late SrsDbStore client;
  late FushiDatabase db;
  late FushiDatabase repoDb;
  late SyncRepository repo;
  late _OldHost oldHost;

  setUp(() async {
    hostDir = Directory.systemTemp.createTempSync('fushi_srs_old_server_');
    final (FushiDatabase main, SrsDbStore store) = await openSrsTestStore(
      deviceId: 'new-client',
    );
    db = main;
    client = store;
    repoDb = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(repoDb);
    oldHost = await _OldHost.start();
    // 已配对的旧服务端：远程复习的请求只发给配对清单里的主机。明文地址拿凭据前的 hostId 核对（ping）由测试缝放行——
    // 旧服务端的 ping 与这里要测的代际协商无关。
    await repo.setFushiClientUrls(<FushiClientUrl>[oldHost.peer]);
    await repo.setInterconnectEnabled(true);
    resetInterconnectRaceCache();
    debugInterconnectAddressProbeOverride =
        (FushiClientUrl candidate, String? hostId) async => true;
  });

  tearDown(() async {
    debugInterconnectAddressProbeOverride = null;
    resetInterconnectRaceCache();
    await oldHost.close();
    await db.close();
    await repoDb.close();
    try {
      hostDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  Future<SrsSync2Report> syncToOldServer() => srsDefaultSyncRunner(
    LocalDirectoryAssetStore(hostDir),
    client,
    srsInterconnectDirectoryKey(kOldHostId),
  );

  File meta3() => File(
    p.join(
      hostDir.path,
      kSrsSync2Namespace,
      client.sync2Dir!,
      'v3',
      'meta.json',
    ),
  );

  Map<String, Object?> fence() =>
      (jsonDecode(meta3().readAsStringSync()) as Map).cast<String, Object?>();

  Future<String> addNote(String expression) => client.createNote(
    noteTypeId: client.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(client.profileUid, 'Expression'): expression,
    },
  );

  InterconnectHostTarget target() => InterconnectHostTarget(
    hostId: kOldHostId,
    displayName: 'old server',
    peer: oldHost.peer,
  );

  /// 远程复习对旧主机的两步：探测判「主机需要升级」、列出来；绕过探测直接握手也只拿到 426 `upgrade_required`。
  Future<void> expectRemoteReviewRefusesOldHost() async {
    expect(
      await probeSrsRemoteHosts(repo, <InterconnectHostTarget>[target()]),
      <String, SrsRemoteHostCompat>{
        kOldHostId: SrsRemoteHostCompat.hostNeedsUpgrade,
      },
    );
    await expectLater(
      SrsRemoteStore.connect(
        SrsRemoteHostClient(repository: repo, peer: oldHost.peer),
      ),
      throwsA(
        isA<InterconnectHostError>()
            .having(
              (InterconnectHostError e) => e.message,
              'message',
              SrsRemoteStoreError.upgradeRequired,
            )
            .having((InterconnectHostError e) => e.statusCode, 'status', 426),
      ),
    );
  }

  /// 新客户端经生产的互联制卡链路（[FushiRemoteMiningClient] → [RemoteMiningAnkiRepository] → 待发队列
  /// [PendingMiningAnkiRepository]）往旧主机制卡：请求真发到了 `/api/mine/forward`，用户拿到「主机不收卡（可能要升级）」
  /// 的明确失败，而不是「连不上」或「主机可能收到了」；开着「连不上时暂存」时卡进待发队列，不丢。
  Future<void> expectMiningRefusedWithoutLosingTheCard(String word) async {
    final RemoteMiningAnkiRepository remote = RemoteMiningAnkiRepository(
      local: _NoLocalAnki(),
      client: FushiRemoteMiningClient(repo: repo),
      fileByteLoader: (String path) async => null,
      dictMediaLoader: (String dict, String path) => null,
    );
    String payload(String w) =>
        jsonEncode(<String, String>{'expression': w, 'reading': ''});
    final int before = oldHost.seen.length;

    final MineOutcome direct = await remote.mineEntry(
      rawPayloadJson: payload(word),
      context: AnkiMiningContext(sentence: '$wordの例文'),
    );
    expect(direct.result, MineResult.error);
    expect(direct.errorCode, AnkiErrorCode.pairedDeviceMiningUnavailable);
    expect(
      direct.errorDetail,
      RemoteMiningAnkiRepository.pairedDeviceMiningUnavailableMessage,
    );
    expect(
      oldHost.seen.skip(before),
      contains('POST /api/mine/forward'),
      reason: '请求真的发到了旧主机',
    );

    final PendingMineStore queue = PendingMineStore(
      db: () => repoDb,
      root: () async =>
          Directory(p.join(hostDir.path, 'client', PendingMineStore.dirName)),
    );
    PendingMiningAnkiRepository.debugReset();
    final MineOutcome queued =
        await PendingMiningAnkiRepository(
          inner: _QueueUndelivered(remote),
          store: queue,
          payloadBuilder: ForwardedMinePayloadBuilder(
            dictMediaLoader: (String dict, String path) => null,
          ),
        ).mineEntry(
          rawPayloadJson: payload(word),
          context: AnkiMiningContext(sentence: '$wordの例文'),
        );
    expect(queued.result, MineResult.queued);
    expect(
      (await queue.all()).map((PendingMineRow r) => r.expression),
      contains(word),
    );
  }

  test('客户端先升级、服务端还是旧版本：host 目录立了围栏（旧服务端读到即停），远程复习标「主机需要升级」', () async {
    await addNote('食べる');
    final SrsSync2Report first = await syncToOldServer();
    expect(first.error, isNull);

    // 新根写好，旧根立了围栏：协议 3 的服务端读旧根 meta，minReader 大于 3 → 整轮停下、复习服务进「需要升级」。
    final String dir = client.sync2Dir!;
    expect(
      File(
        p.join(hostDir.path, kSrsSync2Namespace, dir, 'v4', 'meta.json'),
      ).existsSync(),
      isTrue,
    );
    expect(meta3().existsSync(), isTrue);
    expect(
      fence()['minReader'] as int,
      greaterThan(kProtocol3Reader),
      reason: '${fence()}',
    );

    await expectRemoteReviewRefusesOldHost();
    expect(
      oldHost.seen.where((String s) => s.contains('/api/srs/remote/')),
      isEmpty,
      reason: '新客户端从不发 V1 请求',
    );
    await expectMiningRefusedWithoutLosingTheCard('猫');
  });

  test('服务端一直不升级：每轮照常同步、围栏被旧版本拆掉就写回，远程复习一直拒绝，本机数据一张不少', () async {
    await addNote('食べる');
    expect((await syncToOldServer()).error, isNull);
    final List<int> fenceBytes = meta3().readAsBytesSync();

    for (final String word in <String>['飲む', '走る', '泳ぐ']) {
      // 还在协议 3 上的一端（旧服务端在围栏立起之前排着的写、云盘先删后传）把旧根 meta 重建成 minReader 3。
      meta3().writeAsStringSync(
        jsonEncode(<String, Object?>{
          'collection': fence()['collection'],
          'minReader': kProtocol3Reader,
          'v': 3,
        }),
      );
      await addNote(word);
      final SrsSync2Report r = await syncToOldServer();
      expect(r.error, isNull, reason: word);
      expect(r.needsUpgrade, isFalse, reason: '新客户端自己不受围栏影响');
      expect(meta3().readAsBytesSync(), fenceBytes, reason: '围栏写回原样（$word）');
    }

    await expectRemoteReviewRefusesOldHost();
    await expectMiningRefusedWithoutLosingTheCard('犬');
    expect(await client.userNoteCount(), 4);
  });
}
