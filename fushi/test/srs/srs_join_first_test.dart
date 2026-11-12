// 先加入、后写入（SRS 集合身份定稿 PR-C）：用户确认开始同步之后，还没定下集合的新设备在迁移 / 上传任何东西之前，
// 逐个位置先只关联一遍（SrsSyncScheduler.joinExistingCollection）。软约束：有时限、不挡写入、确认之前不列目录
// （BUG-4011 的裁决）。
//
// 真数据库 + 真同步引擎 + 真关联（SrsDbProfileLinker），位置是本机目录（LocalDirectoryAssetStore）。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart' show srsLapisFieldId;
import 'package:fushi_engine/srs/srs_collection_binding.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';

import 'srs_test_support.dart';

/// 一台设备：主库（profiles 表）+ srs.db + 当前 store + 真 linker。
class _Device {
  _Device._(this.db, this.srs, this.deviceId, this.profileId);

  final FushiDatabase db;
  final SrsStorage srs;
  final String deviceId;
  final int profileId;
  late SrsDbStore store;
  late final SrsDbProfileLinker linker;

  static Future<_Device> open(String deviceId) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final SrsStorage srs = await openSrsTestStorage();
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int profileId = await db.insertProfile(
      ProfilesCompanion.insert(name: 'Default', createdAt: now, updatedAt: now),
    );
    final _Device d = _Device._(db, srs, deviceId, profileId);
    d.store = await d._openStore();
    d.linker = SrsDbProfileLinker(
      db: db,
      activeProfileId: () async => profileId,
      reopenStore: () async => d.store = await d._openStore(),
    );
    return d;
  }

  Future<SrsDbStore> _openStore() async => SrsDbStore.open(
    db: srs.db,
    core: srs.core,
    profileUid: await db.profileUidOf(profileId),
    deviceId: deviceId,
    engine: const SrsTestEngine(),
  );

  /// 只有一个位置（本机目录 [dir]，身份 [key]）的调度器，用生产的一轮同步。
  SrsSyncScheduler scheduler(
    SyncAssetStore dir,
    String key, {
    bool Function()? confirmed,
    Duration joinBudget = const Duration(minutes: 2),
  }) => SrsSyncScheduler(
    readStore: () async => store,
    channels: (Future<void> Function(SyncAssetStore) body) async =>
        (ran: 0, errors: const <Object>[]),
    directoryKeyOf: (SyncAssetStore _) async => key,
    localDirectories: () async => <SrsLocalDirectory>[
      SrsLocalDirectory(directoryKey: key, store: dir),
    ],
    onDataChanged: () {},
    onNotice: (SrsSyncNotice _) {},
    firstSyncConfirmed: confirmed ?? () => true,
    profileLinker: linker,
    joinBudget: joinBudget,
  );
}

/// 记下列目录的次数；[hold] 非 null 时列目录挂在它上面（位置卡住）。
class _ProbeDir extends LocalDirectoryAssetStore {
  _ProbeDir(super.root);

  int lists = 0;
  Completer<void>? hold;

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    lists++;
    final Completer<void>? h = hold;
    if (h != null) await h.future;
    return super.listChildren(namespaceId);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('fushi_srs_join_'));
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄滞后。
    }
  });

  test('两台空设备在同一目录上、都不写入：收敛到最小 uid，两边都定下', () async {
    final LocalDirectoryAssetStore dir = LocalDirectoryAssetStore(root);
    final _Device a = await _Device.open('a');
    final _Device b = await _Device.open('b');
    final String smallest = a.store.profileUid.compareTo(b.store.profileUid) < 0
        ? a.store.profileUid
        : b.store.profileUid;
    final SrsSyncScheduler sa = a.scheduler(dir, 'L');
    final SrsSyncScheduler sb = b.scheduler(dir, 'L');
    for (int i = 0; i < 3; i++) {
      await sa.syncNow();
      await sb.syncNow();
    }
    expect(a.store.profileUid, smallest);
    expect(b.store.profileUid, smallest);
    for (final _Device d in <_Device>[a, b]) {
      final SrsCollectionBinding? binding = await d.store.collectionBinding();
      expect(binding?.state, SrsCollectionBindingState.settled);
      expect(binding?.via, 'L');
      expect(await d.store.hasUserData(), isFalse);
    }
  });

  test('新设备确认同步后、写入之前先加入已有集合：第一条笔记就写在对方的集合里，不用事后合并', () async {
    final LocalDirectoryAssetStore dir = LocalDirectoryAssetStore(root);
    final _Device host = await _Device.open('host');
    final _Device phone = await _Device.open('phone');
    await host.store.createNote(
      noteTypeId: host.store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(host.store.profileUid, 'Expression'): '雪',
      },
    );
    await host.scheduler(dir, 'L').syncNow();

    final SrsSyncScheduler sp = phone.scheduler(dir, 'L');
    expect(await sp.joinExistingCollection(), SrsCollectionJoin.joined);
    expect(phone.store.profileUid, host.store.profileUid);
    expect(
      (await phone.store.collectionBinding())?.state,
      SrsCollectionBindingState.settled,
    );
    expect(await sp.joinExistingCollection(), SrsCollectionJoin.settled);
    // 之后的第一条笔记直接写在 host 的集合里：同步后 host 收到，不经冲突 / 并入。
    final String note = await phone.store.createNote(
      noteTypeId: phone.store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(phone.store.profileUid, 'Expression'): '雨',
      },
    );
    await sp.syncNow();
    await host.scheduler(dir, 'L').syncNow();
    expect(await host.store.note(note), isNotNull);
    expect(host.store.profileUid, phone.store.profileUid);
  });

  test('位置卡住：到点记为 provisional，照常写入、不挡', () async {
    final _ProbeDir dir = _ProbeDir(root)..hold = Completer<void>();
    final _Device phone = await _Device.open('phone');
    final SrsSyncScheduler sp = phone.scheduler(
      dir,
      'L',
      joinBudget: const Duration(milliseconds: 200),
    );
    final Stopwatch sw = Stopwatch()..start();
    expect(await sp.joinExistingCollection(), SrsCollectionJoin.provisional);
    expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
    final SrsCollectionBinding? binding = await phone.store.collectionBinding();
    expect(binding?.state, SrsCollectionBindingState.provisional);
    expect(binding?.via, 'L');
    // 卡住的那一遍还挂在锁里：写入不经调度器，照常落库。
    final String note = await phone.store.createNote(
      noteTypeId: phone.store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(phone.store.profileUid, 'Expression'): '雨',
      },
    );
    expect(await phone.store.note(note), isNotNull);
    expect(await phone.store.hasUserData(), isTrue);
    dir.hold!.complete();
    sp.dispose();
  });

  test('首次同步确认之前不列目录（BUG-4011），也不记任何绑定状态', () async {
    final _ProbeDir dir = _ProbeDir(root);
    final _Device phone = await _Device.open('phone');
    final SrsSyncScheduler sp = phone.scheduler(
      dir,
      'L',
      confirmed: () => false,
    );
    expect(
      await sp.joinExistingCollection(),
      SrsCollectionJoin.awaitingConfirm,
    );
    await sp.syncNow();
    expect(dir.lists, 0);
    expect(await phone.store.collectionBinding(), isNull);
  });
}
