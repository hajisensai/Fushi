import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_directory_key.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_utils.dart' show kSyncRootFolderName;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/sync2/srs_host_directory.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

import '../srs/srs_test_support.dart' show openSrsTestStorage;

const String kProfile = '01928c3e-0000-7000-8000-0000000000dd';
const String kHostId = 'srs-two-way-host';
const String kToken = 'srs-two-way-token';

/// 复习（SRS）经互联双向同步：真 host（FushiSyncServer）+ 真互联客户端
/// （InterconnectSyncBackend）。host 自己经本机目录（`<sync-data>/fushi-data`，与生产
/// `FushiSyncServerController.clientSyncRoot` 同一块）同步，客户端经 WebDAV 同步——
/// 两边各建的笔记都要到对面。
///
/// 第二个用例是用户报的真实失败路径：两台设备各自装好、各自打开过复习模块，profileUid 是各自
/// 本机随机生成的（`FushiDatabase.profileUidOf`），同步目录按 uid 分区——以前两边各写各的
/// `fushi-srs/<uid>/`，「同步成功」但谁也看不到谁的卡。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late FushiSyncServer server;
  late Directory dataDir;
  late FushiDatabase clientAppDb;
  late String base;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('fushi_srs_two_way_srv');
    server = FushiSyncServer(
      syncDataDir: dataDir.path,
      port: 0,
      token: kToken,
      allowLan: false,
    );
    server.hostId = kHostId;
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
    clientAppDb = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
  });

  tearDown(() async {
    await server.stop();
    await clientAppDb.close();
    try {
      dataDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  Future<SrsDbStore> device(String id) async {
    final SrsStorage srs = await openSrsTestStorage();
    return SrsDbStore.open(
      db: srs.db,
      core: srs.core,
      profileUid: kProfile,
      deviceId: id,
    );
  }

  Future<String> addNote(SrsDbStore s, String expression) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kProfile, 'Expression'): expression,
    },
  );

  String? expressionOf(SrsNoteView? n) =>
      n?.field(srsLapisFieldId(kProfile, 'Expression'));

  test('客户端与 host 各建的笔记经互联互通', () async {
    final SyncRepository repo = SyncRepository(clientAppDb);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: base, enabled: true),
    ]);
    await repo.setFushiClientToken(kToken);
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
      (String url, String tok) async => true,
    );
    expect(await backend.restoreAuth(repo), isTrue);
    await backend.authenticate(repo: repo);

    // 目录身份只是各设备自己记进度用的键（老配置条目没有 hostId 时退到地址）。
    final String? clientKey = await srsDirectoryKeyOf(backend, repo);
    expect(clientKey, isNotNull);
    final String hostKey = srsInterconnectDirectoryKey(kHostId);

    final SrsDbStore phone = await device('phone');
    final SrsDbStore host = await device('host');
    final String fromPhone = await addNote(phone, '雨');
    final String fromHost = await addNote(host, '雪');

    final Directory hostRoot = Directory(
      p.join(server.syncDataDir, kSyncRootFolderName),
    );
    // 两边各自的位置视图：手机经互联（WebDAV），host 经本机目录——同一块 `fushi-srs/<uid>/v2/`。
    final SrsAssetLocationStore phoneLoc = SrsAssetLocationStore(
      store: backend,
      profileUid: kProfile,
    );
    final SrsAssetLocationStore hostLoc = SrsAssetLocationStore(
      store: LocalDirectoryAssetStore(hostRoot),
      profileUid: kProfile,
    );
    Future<SrsSync2Report> syncPhone() => srsSync2Round(
      host: phone,
      location: phoneLoc,
      locationId: clientKey!,
      nowMs: () => phone.now().$1,
    );
    Future<SrsSync2Report> syncHost() => srsSync2Round(
      host: host,
      location: hostLoc,
      locationId: hostKey,
      nowMs: () => host.now().$1,
    );

    for (int round = 0; round < 3; round++) {
      final SrsSync2Report a = await syncPhone();
      expect(a.error, isNull, reason: 'phone round $round');
      expect(a.errors, isEmpty, reason: 'phone round $round');
      final SrsSync2Report b = await syncHost();
      expect(b.error, isNull, reason: 'host round $round');
      expect(b.errors, isEmpty, reason: 'host round $round');
    }
    expect(expressionOf(await host.note(fromPhone)), '雨');
    expect(expressionOf(await phone.note(fromHost)), '雪');
    // 两份真实 v2 副本收敛：摘要一致。
    expect(
      (await phone.sync2Digest())['digest'],
      (await host.sync2Digest())['digest'],
    );
    // 落盘布局是 v2：host 的本机目录下每台设备一个 `v2/devices/<设备 ID>/`。
    final Directory devices = Directory(
      p.join(
        hostRoot.path,
        kSrsSync2Namespace,
        kProfile,
        kSrsSync2Folder,
        'devices',
      ),
    );
    expect(
      devices
          .listSync()
          .whereType<Directory>()
          .map((Directory d) => p.basename(d.path))
          .toSet(),
      <String>{phone.sync2Device!, host.sync2Device!},
    );

    // 之后的增量也接得上（第二轮起写入者目录只能靠 PROPFIND 找到）。
    final String later = await addNote(phone, '霧');
    for (int round = 0; round < 2; round++) {
      expect((await syncPhone()).error, isNull);
      expect((await syncHost()).error, isNull);
    }
    expect(expressionOf(await host.note(later)), '霧');
  });

  test('各自生成 profileUid 的两台设备：没有笔记的一边（已同步发布过）采用对方 uid 后互通', () async {
    final SyncRepository repo = SyncRepository(clientAppDb);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: base, enabled: true),
    ]);
    await repo.setFushiClientToken(kToken);
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
      (String url, String tok) async => true,
    );
    expect(await backend.restoreAuth(repo), isTrue);
    await backend.authenticate(repo: repo);
    final String clientKey = (await srsDirectoryKeyOf(backend, repo))!;
    final LocalDirectoryAssetStore hostDir = LocalDirectoryAssetStore(
      Directory(p.join(server.syncDataDir, kSyncRootFolderName)),
    );
    final String hostKey = srsInterconnectDirectoryKey(kHostId);

    final _LinkedDevice host = await _LinkedDevice.open('host');
    final _LinkedDevice phone = await _LinkedDevice.open('phone');
    final String phoneOldUid = phone.store.profileUid;
    expect(host.store.profileUid, isNot(phoneOldUid));

    // 手机先单独同步过（内置行批次已发布在它自己的 uid 下）。
    expect(
      (await phone.scheduler.syncWithBackend(
        backend,
        directoryKey: clientKey,
      )).error,
      isNull,
    );
    final Object? locations = (await phone.store.sync2Status())['locations'];
    expect(
      locations is List &&
          locations.any(
            (Object? l) => l is Map && ((l['uploaded'] as int?) ?? 0) > 0,
          ),
      isTrue,
      reason: '手机在自己的 uid 下传出过段',
    );

    final String fromHost = await _addNote(host.store, '雪');
    for (int round = 0; round < 3; round++) {
      expect(
        (await host.scheduler.syncWithBackend(
          hostDir,
          directoryKey: hostKey,
        )).error,
        isNull,
        reason: 'host round $round',
      );
      expect(
        (await phone.scheduler.syncWithBackend(
          backend,
          directoryKey: clientKey,
        )).error,
        isNull,
        reason: 'phone round $round',
      );
    }
    expect(phone.store.profileUid, host.store.profileUid);
    expect(await phone.db.profileUidOf(phone.profileId), host.store.profileUid);
    expect(_expressionOf(phone.store, await phone.store.note(fromHost)), '雪');
    // 本设备在旧 uid 下的孤儿目录已清掉。
    expect(
      Directory(
        p.join(hostDir.root.path, kSrsSync2Namespace, phoneOldUid),
      ).existsSync(),
      isFalse,
    );

    final String fromPhone = await _addNote(phone.store, '雨');
    for (int round = 0; round < 3; round++) {
      expect(
        (await phone.scheduler.syncWithBackend(
          backend,
          directoryKey: clientKey,
        )).error,
        isNull,
      );
      expect(
        (await host.scheduler.syncWithBackend(
          hostDir,
          directoryKey: hostKey,
        )).error,
        isNull,
      );
    }
    expect(_expressionOf(host.store, await host.store.note(fromPhone)), '雨');
    // host 有用户笔记、目录里已有别的设备：不会被反过来改 uid。
    expect(await host.db.profileUidOf(host.profileId), host.store.profileUid);
  });

  test('两边都有用户笔记：不自动关联，提示一次', () async {
    final LocalDirectoryAssetStore dir = LocalDirectoryAssetStore(
      Directory(p.join(server.syncDataDir, kSyncRootFolderName)),
    );
    final _LinkedDevice a = await _LinkedDevice.open('a');
    final _LinkedDevice b = await _LinkedDevice.open('b');
    await _addNote(a.store, '雪');
    await _addNote(b.store, '雨');
    final String aUid = a.store.profileUid;
    final String bUid = b.store.profileUid;
    for (int round = 0; round < 2; round++) {
      expect(
        (await a.scheduler.syncWithBackend(dir, directoryKey: 'k')).error,
        isNull,
      );
      expect(
        (await b.scheduler.syncWithBackend(dir, directoryKey: 'k')).error,
        isNull,
      );
    }
    expect(a.store.profileUid, aUid);
    expect(b.store.profileUid, bUid);
    expect(b.notices, <SrsSyncNotice>[SrsSyncNotice.profileNotLinked]);
  });

  // 用户报的真实路径：两台设备各有自己的 profile 与笔记 → 两边都检出冲突；host 在弹窗里采用了客户端的 profile
  // （并入），之后客户端不该再被问起 host 那个已经并走的旧 profile，弹窗里的笔记数也不能是检出那一刻的旧数。
  test('两边都有笔记、host 采用客户端的 profile 之后：客户端不再有冲突，拿旧冲突采用被拒、两边不分叉', () async {
    final SyncRepository repo = SyncRepository(clientAppDb);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: base, enabled: true),
    ]);
    await repo.setFushiClientToken(kToken);
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
      (String url, String tok) async => true,
    );
    expect(await backend.restoreAuth(repo), isTrue);
    await backend.authenticate(repo: repo);
    final String clientKey = (await srsDirectoryKeyOf(backend, repo))!;
    final LocalDirectoryAssetStore hostDir = LocalDirectoryAssetStore(
      Directory(p.join(server.syncDataDir, kSyncRootFolderName)),
    );
    final String hostKey = srsInterconnectDirectoryKey(kHostId);

    final _LinkedDevice host = await _LinkedDevice.open(
      'host',
      localDirectory: hostDir,
      localKey: hostKey,
    );
    final _LinkedDevice phone = await _LinkedDevice.open(
      'phone',
      channel: backend,
      channelKey: clientKey,
    );
    final String hostOldUid = host.store.profileUid;
    final String phoneUid = phone.store.profileUid;
    await _addNote(host.store, '雪');
    final String fromPhone = await _addNote(phone.store, '雨');

    Future<void> rounds(int n) async {
      for (int round = 0; round < n; round++) {
        final SrsSyncNowResult h = await host.scheduler.syncLocalDirectories();
        expect(h.errors, isEmpty, reason: 'host round $round');
        expect(
          (await phone.scheduler.syncWithBackend(
            backend,
            directoryKey: clientKey,
          )).error,
          isNull,
          reason: 'phone round $round',
        );
      }
    }

    await rounds(2);
    final SrsProfileConflict hostConflict = host.scheduler.profileConflict!;
    final SrsProfileConflict stale = phone.scheduler.profileConflict!;
    expect(hostConflict.candidates.map((SrsRemoteProfile c) => c.uid), <String>[
      phoneUid,
    ]);
    expect(stale.candidates.map((SrsRemoteProfile c) => c.uid), <String>[
      hostOldUid,
    ]);
    expect(stale.localNoteCount, 1);
    // 检出之后客户端又建了一条：弹窗前重判报的是现在的数，不是检出那一刻的。
    await _addNote(phone.store, '霞');
    final SrsProfileConflict? fresh = await phone.scheduler
        .recheckProfileConflict(stale);
    expect(fresh?.localNoteCount, 2);
    expect(fresh?.candidates.map((SrsRemoteProfile c) => c.uid), <String>[
      hostOldUid,
    ]);

    // host 在弹窗里选了客户端的 profile：并入，之后那一轮立即同步。
    await host.scheduler.adoptProfile(hostConflict, phoneUid);
    expect(host.store.profileUid, phoneUid);
    expect(host.scheduler.profileConflict, isNull);
    await rounds(2);
    // host 的笔记并入后换了新 uid 下的 ID：按内容核对两边都是同一套三条。
    expect(await phone.store.userNoteCount(), 3);
    expect(await host.store.userNoteCount(), 3);
    expect(_expressionOf(host.store, await host.store.note(fromPhone)), '雨');
    // host 离开的旧 profile 目录只有它自己写过：已清掉。
    expect(
      Directory(
        p.join(hostDir.root.path, kSrsSync2Namespace, hostOldUid),
      ).existsSync(),
      isFalse,
    );

    // 客户端：后台轮次已经看到 host 加入了自己的 profile，检出时缓存的冲突不能还挂着。
    expect(phone.scheduler.profileConflict, isNull);
    // 弹窗之前按当前同步位置重判：旧冲突已经不成立。
    expect(await phone.scheduler.recheckProfileConflict(stale), isNull);
    // 用户手里还开着旧弹窗、选了那个旧候选：按当前位置重判后拒绝，本机什么都不动（不会把自己并进已经没人用的旧
    // profile、与 host 分叉）。
    await expectLater(
      phone.scheduler.adoptProfile(stale, hostOldUid),
      throwsA(isA<SrsProfileConflictStale>()),
    );
    expect(phone.store.profileUid, phoneUid);
    expect(await phone.db.profileUidOf(phone.profileId), phoneUid);
    await rounds(1);
    expect(phone.scheduler.profileConflict, isNull);
    expect(host.store.profileUid, phone.store.profileUid);
  });
}

Future<String> _addNote(SrsDbStore s, String expression) => s.createNote(
  noteTypeId: s.lapisNoteTypeId,
  fieldsById: <String, String>{
    srsLapisFieldId(s.profileUid, 'Expression'): expression,
  },
);

String? _expressionOf(SrsDbStore s, SrsNoteView? n) =>
    n?.field(srsLapisFieldId(s.profileUid, 'Expression'));

/// 一台独立设备：自己的数据库、自己的 profile（名字相同、uid 各自随机生成）、真 [SrsDbProfileLinker]。
class _LinkedDevice {
  _LinkedDevice._(this.db, this.srs, this.deviceId, this.profileId);

  final FushiDatabase db;
  final SrsStorage srs;
  final String deviceId;
  final int profileId;
  late SrsDbStore store;
  late final SrsSyncScheduler scheduler;
  final List<SrsSyncNotice> notices = <SrsSyncNotice>[];

  /// [channel] / [channelKey]：这台设备的同步通道（互联客户端）；[localDirectory] / [localKey]：本机直接读写的
  /// 目录（互联 host）。都不给时只能直接调 [SrsSyncScheduler.syncWithBackend]。
  static Future<_LinkedDevice> open(
    String deviceId, {
    SyncAssetStore? channel,
    String? channelKey,
    SyncAssetStore? localDirectory,
    String? localKey,
  }) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final SrsStorage srs = await openSrsTestStorage();
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int profileId = await db.insertProfile(
      ProfilesCompanion.insert(name: 'Default', createdAt: now, updatedAt: now),
    );
    final _LinkedDevice d = _LinkedDevice._(db, srs, deviceId, profileId);
    d.store = await d._openStore();
    d.scheduler = SrsSyncScheduler(
      readStore: () async => d.store,
      channels: (Future<void> Function(SyncAssetStore backend) body) async {
        if (channel == null) return (ran: 0, errors: <Object>[]);
        await body(channel);
        return (ran: 1, errors: <Object>[]);
      },
      directoryKeyOf: (SyncAssetStore backend) async =>
          identical(backend, channel) ? channelKey : null,
      localDirectories: localDirectory == null
          ? null
          : () async => <SrsLocalDirectory>[
              SrsLocalDirectory(directoryKey: localKey!, store: localDirectory),
            ],
      onDataChanged: () {},
      onNotice: d.notices.add,
      profileLinker: SrsDbProfileLinker(
        db: db,
        activeProfileId: () async => profileId,
        reopenStore: () async => d.store = await d._openStore(),
      ),
    );
    return d;
  }

  Future<SrsDbStore> _openStore() async => SrsDbStore.open(
    db: srs.db,
    core: srs.core,
    profileUid: await db.profileUidOf(profileId),
    deviceId: deviceId,
  );
}
