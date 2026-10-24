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
import 'package:fushi_engine/srs/srs_asset_store_directory.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
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
    Future<SrsSyncReport> syncPhone() => SrsSyncEngine(
      directory: SrsAssetStoreDirectory(store: backend, profileUid: kProfile),
      directoryKey: clientKey!,
      replica: phone,
    ).syncOnce();
    Future<SrsSyncReport> syncHost() => SrsSyncEngine(
      directory: SrsAssetStoreDirectory(
        store: LocalDirectoryAssetStore(hostRoot),
        profileUid: kProfile,
      ),
      directoryKey: hostKey,
      replica: host,
    ).syncOnce();

    for (int round = 0; round < 3; round++) {
      final SrsSyncReport a = await syncPhone();
      expect(a.error, isNull, reason: 'phone round $round');
      final SrsSyncReport b = await syncHost();
      expect(b.error, isNull, reason: 'host round $round');
    }
    expect(expressionOf(await host.note(fromPhone)), '雨');
    expect(expressionOf(await phone.note(fromHost)), '雪');

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
    expect(phone.store.everPublished, isTrue);

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
        p.join(hostDir.root.path, kSrsSyncNamespace, phoneOldUid),
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

  static Future<_LinkedDevice> open(String deviceId) async {
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
      channels: (Future<void> Function(SyncAssetStore backend) body) async =>
          (ran: 0, errors: <Object>[]),
      directoryKeyOf: (SyncAssetStore backend) async => null,
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
