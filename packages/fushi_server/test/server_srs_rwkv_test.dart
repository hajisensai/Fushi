// 服务端的 RWKV 排程：与 app 同一份装配（fushi_engine/srs/srs_rwkv_attach.dart），RWKV 牌组同一个出卡口径。
//
// - 同一组数据，app 的装配与服务端的装配下 RWKV 牌组出卡序列相同（后台 runtime 都换成按卡给同样 R 的替身）；
// - 服务端 RWKV 没就绪（下不到权重）时 RWKV 牌组的复习卡一张不出、标 rwkvPending，**不**退回按 FSRS-7 存下的
//   到期日出卡；远程复习的信封带准备状态与错误，客户端经 `rwkvStart` 让主机重试；
// - 关库顺序：先关 RWKV（存快照、关后台 runtime）再退役库；
// - 模型档位与 app 同一个设置文件（`<support>/srs_rwkv/model_size`）：选了 Tiny，服务端加载 sm101、快照进 Tiny 的目录；
//   WebUI / admin API 换档位当场生效，手改文件在下一次对齐配置时生效；
// - 同一份快照的新服务等上一个服务关完（存好快照）才起内核（快速来回切档位不让两个内核同时碰一个快照）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_attach.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_host_directory.dart';
import 'package:fushi_engine/srs/sync2/srs_location_runner.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/server_srs.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_rwkv.dart';

const String kJa = '01928c3e-0000-7000-8000-00000000a0a0';
const String kHostId = 'server-srs-rwkv-test-host';
const int _dayMs = 24 * 3600 * 1000;

void main() {
  late Directory tmp;
  late Directory support;
  late Directory syncData;
  ServerSrs? srs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_srs_rwkv_');
    support = Directory(p.join(tmp.path, 'support'))..createSync();
    syncData = Directory(p.join(tmp.path, 'interconnect'))..createSync();
    srs = null;
  });

  tearDown(() async {
    await srs?.stop();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  ServerSrs server({FakeRwkvBackend? backend}) => srs = ServerSrs(
    support: support,
    syncData: syncData,
    deviceId: 'server-device',
    hostId: kHostId,
    config: () => const ServerSrsConfig(profiles: <String>[kJa]),
    rwkvHttpClient: noNetworkHttpClient,
    rwkvBackend: backend == null ? null : (File _) async => backend,
  );

  /// 一台手机：自己的 srs.db 与可拨的时钟，经互联写进服务端同步目录。
  Future<SrsDbStore> phone(String deviceId, List<int> clock) async {
    final Directory dir = Directory(p.join(tmp.path, 'phone_$deviceId'))
      ..createSync();
    final SrsStorage storage = await SrsStorage.open(directory: dir.path);
    addTearDown(storage.close);
    return SrsDbStore.open(
      core: storage.core,
      profileUid: kJa,
      deviceId: deviceId,
      engine: FfiFsrsEngine.tryCreate(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => clock[0],
        bootClockMs: () => clock[0],
        bootId: 'boot-$deviceId',
      ),
    );
  }

  Future<SrsSync2Report> phoneSync(SrsDbStore s) => srsRunLocationRound(
    SrsLocationBackend(LocalDirectoryAssetStore(srs!.syncRoot)),
    s,
    srsInterconnectDirectoryKey(kHostId),
  );

  /// 建 [n] 张卡并各答一次 Easy（直接毕业成复习卡）。
  Future<List<String>> seed(SrsDbStore s, int n, List<int> clock) async {
    final List<String> cards = <String>[];
    for (int i = 0; i < n; i++) {
      final String noteId = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(s.profileUid, 'Expression'): 'w$i',
        },
      );
      cards.add((await s.cardsOfNote(noteId)).single.id);
    }
    for (final String c in cards) {
      await s.answer(c, 4);
      clock[0] += 1000;
    }
    return cards;
  }

  Future<void> until(bool Function() done, String what) async {
    for (int i = 0; i < 2000 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(done(), isTrue, reason: 'timed out waiting for $what');
  }

  /// 连续「出下一张 → 答 Good」直到没卡（或 [max] 步）。
  Future<List<String>> study(SrsDbStore s, {int max = 20}) async {
    final List<String> out = <String>[];
    for (int i = 0; i < max; i++) {
      final String? c = await s.nextCard(s.defaultDeckId);
      if (c == null) break;
      out.add(c);
      final SrsReviewLog log = await s.answer(c, 3);
      expect(log.algorithm, SrsAlgorithm.rwkv.wire, reason: '日志记实际排它的算法');
    }
    return out;
  }

  test('同一组数据：app 的装配与服务端的装配下 RWKV 牌组出卡序列相同；关库先关 RWKV', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<int> clock = <int>[now - 2 * _dayMs];
    final FakeRwkvBackend serverBackend = FakeRwkvBackend();
    markRwkvWeightsReady(support);
    final ServerSrs host = server(backend: serverBackend);

    final SrsDbStore app = await phone('phone-a', clock);
    final List<String> cards = await seed(app, 6, clock);
    expect((await phoneSync(app)).error, isNull);
    await host.start();
    await host.syncNow();
    final SrsDbStore served = host.storeFor(kJa)!;
    expect(served.rwkv, isA<SrsRwkvService>(), reason: '库交出去之前就挂上了 RWKV');

    // app 那一侧：同一个装配函数，后台 runtime 同样换成替身。
    final Directory appSupport = Directory(p.join(tmp.path, 'app_support'))
      ..createSync();
    markRwkvWeightsReady(appSupport);
    final FakeRwkvBackend appBackend = FakeRwkvBackend();
    final SrsRwkvService appRwkv = srsAttachRwkv(
      app,
      support: appSupport,
      createClient: noNetworkHttpClient,
      openBackend: (File _) async => appBackend,
    );
    addTearDown(appRwkv.close);

    // 两边按卡给同样的 R（都低于目标保留率，彼此不同，顺序不是建卡顺序）。
    final List<int> numeric = SrsIds.ankiNumericIds(cards);
    for (int i = 0; i < cards.length; i++) {
      final double r = 0.10 + 0.05 * ((i * 5 + 2) % cards.length);
      appBackend.r[numeric[i]] = r;
      serverBackend.r[numeric[i]] = r;
    }

    clock[0] = now; // 手机的时钟拨到此刻（服务端用的是真实时钟）
    await appRwkv.start();
    expect(appRwkv.ready, isTrue);
    await until(
      () => host.profile(kJa)!.rwkvStatus?.phase == SrsRwkvPhase.ready,
      'server RWKV ready',
    );
    expect(serverBackend.replayedRows + serverBackend.appendedRows, 6);

    final List<String> onApp = await study(app);
    final List<String> onServer = await study(served);
    expect(
      onApp,
      hasLength(cards.length),
      reason: '按 R 合格的复习卡都出（FSRS-7 口径下它们今天都没到期）',
    );
    final List<String> byR = <String>[...cards]
      ..sort(
        (String a, String b) => appBackend.r[numeric[cards.indexOf(a)]]!
            .compareTo(appBackend.r[numeric[cards.indexOf(b)]]!),
      );
    expect(onApp, byR, reason: '按 R 升序');
    expect(onServer, onApp);

    expect(host.profile(kJa)!.toJson(isDefault: true)['rwkv'], 'ready');
    await host.stop();
    expect(serverBackend.closed, isTrue);
    expect(
      File(
        p.join(srsRwkvStateDir(support).path, 'rwkv-$kJa-small-int4.snap'),
      ).existsSync(),
      isTrue,
      reason: '关库时把作答后的状态存成快照',
    );
  });

  test('服务端与 app 读同一个模型档位设置：Tiny 时加载 sm101 权重、快照进 state-tiny', () async {
    final List<int> clock = <int>[
      DateTime.now().millisecondsSinceEpoch - 2 * _dayMs,
    ];
    await writeSrsRwkvModelSize(support, SrsRwkvModelSize.tiny);
    markRwkvWeightsReady(support, size: SrsRwkvModelSize.tiny);
    final FakeRwkvBackend backend = FakeRwkvBackend();
    final List<String> opened = <String>[];
    final ServerSrs host = srs = ServerSrs(
      support: support,
      syncData: syncData,
      deviceId: 'server-device',
      hostId: kHostId,
      config: () => const ServerSrsConfig(profiles: <String>[kJa]),
      rwkvHttpClient: noNetworkHttpClient,
      rwkvBackend: (File weights) async {
        opened.add(p.basename(weights.path));
        return backend;
      },
    );
    final SrsDbStore app = await phone('phone-a', clock);
    await seed(app, 2, clock);
    expect((await phoneSync(app)).error, isNull);
    await host.start();
    await host.syncNow();
    await until(
      () => host.profile(kJa)!.rwkvStatus?.phase == SrsRwkvPhase.ready,
      'server RWKV ready',
    );
    expect(opened, <String>[kSrsRwkvTinyWeightsName]);
    await host.stop();
    final String snap = 'rwkv-$kJa-small-int4.snap';
    expect(
      File(
        p.join(srsRwkvStateDir(support, SrsRwkvModelSize.tiny).path, snap),
      ).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(srsRwkvStateDir(support).path, snap)).existsSync(),
      isFalse,
    );
  });

  test('换档位当场生效（WebUI / admin API 走 setRwkvModelSize）：旧档位的服务关掉存快照、换成新档位的；'
      '手改设置文件在下一次对齐配置时生效，换回去恢复该档的快照而不全量重放（PR #3463 拍板）', () async {
    final List<int> clock = <int>[
      DateTime.now().millisecondsSinceEpoch - 2 * _dayMs,
    ];
    markRwkvWeightsReady(support);
    markRwkvWeightsReady(support, size: SrsRwkvModelSize.tiny);
    final List<String> opened = <String>[];
    final List<FakeRwkvBackend> backends = <FakeRwkvBackend>[];
    final ServerSrs host = srs = ServerSrs(
      support: support,
      syncData: syncData,
      deviceId: 'server-device',
      hostId: kHostId,
      config: () => const ServerSrsConfig(profiles: <String>[kJa]),
      rwkvHttpClient: noNetworkHttpClient,
      rwkvBackend: (File weights) async {
        opened.add(p.basename(weights.path));
        final FakeRwkvBackend b = FakeRwkvBackend();
        backends.add(b);
        return b;
      },
    );
    final SrsDbStore app = await phone('phone-a', clock);
    await seed(app, 3, clock);
    expect((await phoneSync(app)).error, isNull);
    await host.start();
    await host.syncNow();
    bool ready() => host.profile(kJa)!.rwkvStatus?.phase == SrsRwkvPhase.ready;
    await until(ready, 'small ready');
    expect(opened, <String>[kSrsRwkvSmallWeightsName]);
    expect(host.rwkvModelSize, SrsRwkvModelSize.small);
    final SrsDbStore served = host.storeFor(kJa)!;
    final Object? before = served.rwkv;

    await host.setRwkvModelSize(SrsRwkvModelSize.tiny);
    expect(readSrsRwkvModelSize(support), SrsRwkvModelSize.tiny);
    expect(host.rwkvModelSize, SrsRwkvModelSize.tiny);
    expect(identical(served.rwkv, before), isFalse, reason: '换成了新服务，不重启');
    expect((served.rwkv! as SrsRwkvService).models.size, SrsRwkvModelSize.tiny);
    expect(backends.first.closed, isTrue, reason: '旧档位的服务先关');
    await until(ready, 'tiny ready');
    expect(opened, <String>[kSrsRwkvSmallWeightsName, kSrsRwkvTinyWeightsName]);
    const String snap = 'rwkv-$kJa-small-int4.snap';
    expect(
      File(p.join(srsRwkvStateDir(support).path, snap)).existsSync(),
      isTrue,
      reason: '旧档位关掉时存了快照',
    );
    // 喂进 runtime 的历史行（整块回放的尾巴走 append，见 SrsRwkvService.journalSeed）。
    int fed(FakeRwkvBackend b) => b.replayedRows + b.appendedRows;
    expect(fed(backends[1]), 3, reason: 'Tiny 没有快照：按全部历史重放');

    // 不经 WebUI、直接改设置文件：下一次对齐配置（改任何复习配置 / 兜底定时器）时换过去。
    await writeSrsRwkvModelSize(support, SrsRwkvModelSize.small);
    await host.applyConfig();
    expect(
      (served.rwkv! as SrsRwkvService).models.size,
      SrsRwkvModelSize.small,
    );
    await until(ready, 'small ready again');
    expect(opened, <String>[
      kSrsRwkvSmallWeightsName,
      kSrsRwkvTinyWeightsName,
      kSrsRwkvSmallWeightsName,
    ]);
    expect(fed(backends.last), 0, reason: '恢复 Small 的快照，不全量重放');
    expect(
      File(
        p.join(srsRwkvStateDir(support, SrsRwkvModelSize.tiny).path, snap),
      ).existsSync(),
      isTrue,
    );
  });

  test('同一份快照的上一个服务还在关时，新服务等它关完（快照存好）才起内核：恢复刚存的快照而不是全量重放，'
      '两个内核不同时碰一个快照文件（PR #3463 审查：快速来回切档位）', () async {
    final List<int> clock = <int>[
      DateTime.now().millisecondsSinceEpoch - 2 * _dayMs,
    ];
    final SrsDbStore s = await phone('phone-a', clock);
    await seed(s, 3, clock);
    final Directory device = Directory(p.join(tmp.path, 'device'))
      ..createSync();
    markRwkvWeightsReady(device);
    final FakeRwkvBackend first = FakeRwkvBackend();
    final SrsRwkvService a = srsAttachRwkv(
      s,
      support: device,
      createClient: noNetworkHttpClient,
      openBackend: (File _) async => first,
    );
    await a.start();
    await until(() => a.status.phase == SrsRwkvPhase.ready, 'first ready');
    expect(first.replayedRows + first.appendedRows, 3);

    // 宿主不等旧服务关完就建新服务（app 换档位时 provider 的 onDispose 不 await close）。旧服务关 runtime
    // 挂在闸门上：顺序由闸门钉死，不靠两个 isolate 谁快谁慢。
    final Completer<void> gate = first.closeGate = Completer<void>();
    final Future<void> closing = a.close();
    await until(() => first.closeCalled, 'first close reached the runtime');
    final FakeRwkvBackend second = FakeRwkvBackend();
    bool? firstClosedWhenOpened;
    final SrsRwkvService b = srsAttachRwkv(
      s,
      support: device,
      createClient: noNetworkHttpClient,
      openBackend: (File _) async {
        firstClosedWhenOpened = first.closed;
        return second;
      },
    );
    try {
      final Future<void> starting = b.start();
      // 给新服务足够时间起 isolate、打开 runtime（没有交接时它会在这段时间里打开）。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(firstClosedWhenOpened, isNull, reason: '上一个服务没关完时不起内核');
      gate.complete();
      await starting;
      await until(() => b.status.phase == SrsRwkvPhase.ready, 'second ready');
      await closing;
      expect(firstClosedWhenOpened, isTrue, reason: '上一个服务关完才起内核');
      expect(
        second.replayedRows + second.appendedRows,
        0,
        reason: '恢复的是上一个服务关闭时存的快照',
      );
    } finally {
      await b.close();
    }
  });

  test('上一个服务关不完（runtime 挂住）时，排在后面的服务照样能关：交接只挡起内核、不挡关闭，'
      '不把宿主换档位 / 关库的串行队列拖住', () async {
    final List<int> clock = <int>[
      DateTime.now().millisecondsSinceEpoch - 2 * _dayMs,
    ];
    final SrsDbStore s = await phone('phone-a', clock);
    await seed(s, 3, clock);
    final Directory device = Directory(p.join(tmp.path, 'device'))
      ..createSync();
    markRwkvWeightsReady(device);
    final FakeRwkvBackend first = FakeRwkvBackend();
    final SrsRwkvService a = srsAttachRwkv(
      s,
      support: device,
      createClient: noNetworkHttpClient,
      openBackend: (File _) async => first,
    );
    await a.start();
    await until(() => a.status.phase == SrsRwkvPhase.ready, 'first ready');
    final Completer<void> gate = first.closeGate = Completer<void>();
    final Future<void> closingA = a.close();
    await until(() => first.closeCalled, 'first close reached the runtime');

    bool secondOpened = false;
    final SrsRwkvService b = srsAttachRwkv(
      s,
      support: device,
      createClient: noNetworkHttpClient,
      openBackend: (File _) async {
        secondOpened = true;
        return FakeRwkvBackend();
      },
    );
    final Future<void> startingB = b.start();
    bool closedB = false;
    final Future<void> closingB = b.close().then((_) => closedB = true);
    await until(() => closedB, 'second close while first is stuck');
    await startingB;
    expect(secondOpened, isFalse, reason: '关了的服务不再起内核');
    expect(b.ready, isFalse);

    gate.complete();
    await closingA;
    await closingB;
    expect(first.closed, isTrue);
  });

  test('服务端 RWKV 没就绪：RWKV 牌组的复习卡不出、标 rwkvPending，不退回 FSRS-7 的到期日；'
      '远程信封带状态与错误，rwkvStart 让主机重试', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    // 很久以前毕业的卡：按 FSRS-7 存下的到期日早就到期了。
    final List<int> clock = <int>[now - 1500 * _dayMs];
    final FakeRwkvBackend backend = FakeRwkvBackend()..defaultR = 0.1;
    final ServerSrs host = server(backend: backend); // 权重不在，也下不到

    final SrsDbStore app = await phone('phone-a', clock);
    final List<String> cards = await seed(app, 2, clock);
    expect((await phoneSync(app)).error, isNull);
    await host.start();
    await host.syncNow();
    final SrsDbStore served = host.storeFor(kJa)!;
    final String deck = served.defaultDeckId;
    final SrsDayContext day = await served.dayContext();
    for (final String c in cards) {
      expect(
        (await served.cardRow(c))!.dueDay!,
        lessThan(day.dayIndexOf(now)),
        reason: '按 FSRS-7 的到期日这张卡已到期：下面「不出」不是因为没到期',
      );
    }

    final ServerSrsProfile prof = host.profile(kJa)!;
    await until(
      () => prof.rwkvStatus?.phase == SrsRwkvPhase.failed,
      'server RWKV failed (no weights, no network)',
    );
    expect(await served.nextCard(deck), isNull);
    final SrsStudyState state = (await served.studyState(deck))!;
    expect(state.next, isNull);
    expect(state.rwkvPending, isTrue);
    expect(state.summary.reviewCount, 0);
    expect(prof.toJson(isDefault: true)['rwkv'], 'failed');
    expect(
      prof.toJson(isDefault: true)['rwkvError'],
      contains('network disabled in tests'),
    );

    // 远程复习：信封带主机的 RWKV 状态与错误。
    Map<String, Object?> env = await host.remoteStore!.call(
      profile: kJa,
      op: 'studyState',
      args: <String, Object?>{'deck': deck, 'exclude': const <String>[]},
    );
    expect(env['rwkv'], isFalse);
    expect((env['rk']! as Map<String, Object?>)['p'], 'failed');
    expect(
      (env['rk']! as Map<String, Object?>)['e'],
      contains('network disabled in tests'),
    );
    expect(
      jsonEncode(env['result']),
      contains('"rp":true'),
      reason: '牌组摘要标着「等 RWKV」',
    );

    // 管理员把权重放进目录后，客户端点「重试」（rwkvStart）：主机重新准备，就绪后按 RWKV 出卡。
    markRwkvWeightsReady(support);
    env = await host.remoteStore!.call(
      profile: kJa,
      op: 'rwkvStart',
      args: <String, Object?>{'force': true},
    );
    await until(
      () => prof.rwkvStatus?.phase == SrsRwkvPhase.ready,
      'server RWKV ready after retry',
    );
    env = await host.remoteStore!.call(
      profile: kJa,
      op: 'hello',
      args: const <String, Object?>{},
    );
    expect(env['rwkv'], isTrue);
    expect((env['rk']! as Map<String, Object?>)['p'], 'ready');
    expect(await served.nextCard(deck), isNotNull);
  });
}
