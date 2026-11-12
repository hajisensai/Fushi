// 集合绑定状态（srs_collection_binding.dart，内核 store/binding.rs）：一台设备的几个同步位置上各有一个别的集合时，
// 第一个跑完关联的位置把绑定定为 settled，之后别的位置只交给用户选、不再自动采用，不来回改 uid。
//
// 真数据库 + 真同步引擎，按 SrsSyncScheduler 的顺序跑：关联（link）→ 同步 v2 的一轮 → 发布说明文件（publish）。
import 'dart:io';

import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_collection_binding.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

class _Device {
  _Device._(this.db, this.srs, this.deviceId, this.profileId);

  final FushiDatabase db;
  final SrsStorage srs;
  final String deviceId;
  final int profileId;
  late SrsDbStore store;
  late final SrsDbProfileLinker linker;
  final List<String> chose = <String>[];

  static Future<_Device> open(String deviceId) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final SrsStorage srs = await openTestSrsStorage();
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
      writeLock: SrsCurrentStoreWriteLock(() => d.store),
    );
    return d;
  }

  Future<SrsDbStore> _openStore() async => SrsDbStore.open(
    db: srs.db,
    core: srs.core,
    profileUid: await db.profileUidOf(profileId),
    deviceId: deviceId,
  );

  /// 与 SrsSyncScheduler 同序：关联 → 同步 v2 的一轮 → 发布说明文件。[key] = 位置身份。
  Future<void> sync(LocalDirectoryAssetStore dir, String key) async {
    final SrsProfileLinkOutcome link = await linker.link(
      dir,
      store,
      directoryKey: key,
    );
    store = link.store;
    final List<SrsRemoteProfile>? choose = link.choose;
    if (choose != null) chose.addAll(choose.map((SrsRemoteProfile c) => c.uid));
    final SrsSync2Report r = await srsSync2Round(
      host: store,
      location: SrsAssetLocationStore(store: dir, profileUid: store.profileUid),
      locationId: key,
      nowMs: () => store.now().$1,
    );
    expect(r.error, isNull, reason: '$deviceId sync $key');
    await linker.publish(dir, store, key);
  }

  Future<String> addNote(String expression) => store.createNote(
    noteTypeId: store.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(store.profileUid, 'Expression'): expression,
    },
  );

  Future<int> metaKeys(String uid) async =>
      (await srs.db
              .customSelect(
                'SELECT COUNT(*) AS c FROM srs_meta WHERE key = ?',
                variables: <Variable<Object>>[
                  Variable<String>('srs_collection_bound/$uid'),
                ],
              )
              .getSingle())
          .read<int>('c');
}

SrsRemoteProfile _remote(String uid, {required bool hasNotes}) =>
    SrsRemoteProfile(
      uid: uid,
      writers: <String>['other#1'],
      names: const <String>{'Default'},
      hasNotes: hasNotes,
    );

SrsProfileLinkDecision _decide({
  required bool settled,
  required bool localHasData,
  required List<SrsRemoteProfile> remote,
}) => srsDecideProfileLink(
  localUid: 'ffff',
  localName: 'Default',
  deviceId: 'me',
  localHasNotes: localHasData,
  localProfileCount: 1,
  remote: remote,
  settled: settled,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('srsDecideProfileLink(settled)', () {
    test('settled 遇到唯一有数据的候选判 Choose（未定下时是 Adopt）', () {
      final List<SrsRemoteProfile> one = <SrsRemoteProfile>[
        _remote('aaaa', hasNotes: true),
      ];
      expect(
        _decide(settled: false, localHasData: false, remote: one),
        isA<SrsProfileLinkAdopt>(),
      );
      final SrsProfileLinkDecision d = _decide(
        settled: true,
        localHasData: false,
        remote: one,
      );
      expect(d, isA<SrsProfileLinkChoose>());
      expect((d as SrsProfileLinkChoose).candidates.single.uid, 'aaaa');
    });

    test('settled 遇到全是空候选时保持，不收敛到最小 uid', () {
      final List<SrsRemoteProfile> empty = <SrsRemoteProfile>[
        _remote('aaaa', hasNotes: false),
      ];
      expect(
        _decide(settled: false, localHasData: false, remote: empty),
        isA<SrsProfileLinkAdopt>(),
      );
      expect(
        _decide(settled: true, localHasData: false, remote: empty),
        isA<SrsProfileLinkKeep>(),
      );
    });
  });

  group('绑定状态', () {
    test('隐式规则零迁移：老库（有用户数据、没有任何绑定记录）打开后不补写，关联照样不自动采用', () async {
      final _Device a = await _Device.open('a');
      await a.addNote('雪');
      // 重开 = 升级后第一次打开：不写任何绑定记录。
      a.store = await a._openStore();
      expect(await a.store.collectionBinding(), isNull);
      expect(await a.metaKeys(a.store.profileUid), 0);
      expect(
        _decide(
          settled: false,
          localHasData: await a.store.hasUserData(),
          remote: <SrsRemoteProfile>[_remote('aaaa', hasNotes: true)],
        ),
        isA<SrsProfileLinkChoose>(),
        reason: '有用户数据本身就等于已定下',
      );
    });

    test('只进不退：settled 之后写 provisional / 别的位置都不改', () async {
      final _Device a = await _Device.open('a');
      await a.store.setCollectionBinding(
        SrsCollectionBindingState.provisional,
        via: 'L1',
      );
      expect(
        (await a.store.collectionBinding())!.state,
        SrsCollectionBindingState.provisional,
      );
      await a.store.setCollectionBinding(
        SrsCollectionBindingState.settled,
        via: 'L1',
      );
      await a.store.setCollectionBinding(
        SrsCollectionBindingState.settled,
        via: 'L2',
      );
      await a.store.setCollectionBinding(
        SrsCollectionBindingState.provisional,
        via: 'L2',
      );
      final SrsCollectionBinding b = (await a.store.collectionBinding())!;
      expect(b.state, SrsCollectionBindingState.settled);
      expect(b.via, 'L1');
      expect(b.settledElsewhere('L1'), isFalse);
      expect(b.settledElsewhere('L2'), isTrue);
    });
  });

  group('一台设备两个位置各有一个别的集合', () {
    late Directory root1;
    late Directory root2;
    late LocalDirectoryAssetStore l1;
    late LocalDirectoryAssetStore l2;

    setUp(() {
      root1 = Directory.systemTemp.createTempSync('fushi_srs_binding_l1_');
      root2 = Directory.systemTemp.createTempSync('fushi_srs_binding_l2_');
      l1 = LocalDirectoryAssetStore(root1);
      l2 = LocalDirectoryAssetStore(root2);
    });
    tearDown(() {
      root1.deleteSync(recursive: true);
      root2.deleteSync(recursive: true);
    });

    test('第一个位置关联上后定为 settled，第二个位置上的别的集合只交给用户选，不来回改 uid', () async {
      // 只关联、还没跑同步（先加入、后写入：确认同步时逐个位置先关联，见 SrsSyncScheduler）：本机此刻仍没有用户数据。
      // 没有绑定状态时，L1 上采用 X 之后到 L2 又会采用 Y，再回 L1 又采用 X……
      final _Device x = await _Device.open('x');
      final _Device y = await _Device.open('y');
      final _Device phone = await _Device.open('phone');
      await x.addNote('雪');
      await x.sync(l1, 'L1');
      await y.addNote('雨');
      await y.sync(l2, 'L2');
      final String phoneOld = phone.store.profileUid;
      await phone.store.setCollectionBinding(
        SrsCollectionBindingState.provisional,
        via: 'L1',
      );
      Future<SrsProfileLinkOutcome> link(
        LocalDirectoryAssetStore dir,
        String key,
      ) async {
        final SrsProfileLinkOutcome o = await phone.linker.link(
          dir,
          phone.store,
          directoryKey: key,
        );
        phone.store = o.store;
        return o;
      }

      await link(l1, 'L1');
      expect(phone.store.profileUid, x.store.profileUid, reason: 'L1 上自动采用');
      expect(await phone.store.hasUserData(), isFalse, reason: '还没跑同步');
      final SrsCollectionBinding b = (await phone.store.collectionBinding())!;
      expect(b.state, SrsCollectionBindingState.settled);
      expect(b.via, 'L1');
      expect(await phone.metaKeys(phoneOld), 0, reason: '旧 uid 的绑定随 purge 删掉');

      for (int i = 0; i < 2; i++) {
        final SrsProfileLinkOutcome o = await link(l2, 'L2');
        expect(phone.store.profileUid, x.store.profileUid, reason: 'L2 不再自动采用');
        expect(o.choose?.map((SrsRemoteProfile c) => c.uid), <String>[
          y.store.profileUid,
        ], reason: 'L2 上交给用户选');
        await link(l1, 'L1');
        expect(phone.store.profileUid, x.store.profileUid);
      }
    });
  });
}
