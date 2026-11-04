// BUG（srs-store-same-uid-retired）：`srsStoreProvider` 每次重建都经 SrsProfileStores.activate 交接，哪怕还是同一个
// profile——旧副本被作废（「profile … is no longer the active SRS profile」），在跑的同步收段、样式去重、媒体回收
// 全部报错作废。启动时 ProfileViewModel 的激活 id 从初值 -1 变成真实 id，就必然重建一次。
//
// 钉住：① 同一 uid 再激活复用原副本、就地换参数；② provider 等配置装载完才打开，只开一次；③ 调度器的一轮遇到副本
// 被换掉按收手结束、用新副本重排一轮。全程真实 srs.db + Rust 内核。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/srs/srs_profile_stores.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_sync_scheduler.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_crypto.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

/// 首次装载卡在 [gate] 上的配置仓库：一个配置（id 1），激活的就是它。
class _GatedProfileRepository implements ProfileRepository {
  _GatedProfileRepository(this.gate);

  final Future<void> gate;

  @override
  Future<void> ensureDefaultProfile() => gate;

  @override
  Future<List<ProfileRow>> getAllProfiles() async => const <ProfileRow>[
    ProfileRow(id: 1, name: 'Default', createdAt: 0, updatedAt: 0),
  ];

  @override
  Future<int> getActiveProfileId() async => 1;

  @override
  Future<Map<String, int>> getAllMediaTypeBindings() async =>
      const <String, int>{};

  @override
  Future<Map<String, int>> getAllLanguageBindings() async =>
      const <String, int>{};

  @override
  Stream<void> watchProfilesChanged() => const Stream<void>.empty();

  @override
  Future<void> snapshotCurrentSettings(int profileId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AppModel extends AppModel {
  _AppModel(this._db) : super(testPlatformServices());

  final FushiDatabase _db;

  @override
  FushiDatabase get database => _db;
}

/// 记下真正打开了几次副本的登记处。
class _CountingStores extends SrsProfileStores {
  _CountingStores(super.deps);

  int opened = 0;

  @override
  Future<SrsDbStore> activate(
    String profileUid,
    Future<SrsDbStore> Function() open, {
    bool Function(SrsDbStore current)? reuse,
  }) => super.activate(profileUid, () {
    opened++;
    return open();
  }, reuse: reuse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SrsStorage storage;

  setUp(() async {
    storage = await openSrsTestStorage();
  });

  SrsProfileStoresDeps deps() => SrsProfileStoresDeps(
    storage: () async => storage,
    deviceId: () async => 'dev',
    supportRoot: () async => Directory.systemTemp,
    engine: () => const SrsTestEngine(),
  );

  Future<SrsDbStore> openOn(String uid) => SrsDbStore.open(
    db: storage.db,
    core: storage.core,
    profileUid: uid,
    deviceId: 'dev',
    engine: const SrsTestEngine(),
  );

  group('SrsProfileStores.activate', () {
    test('同一 uid 再激活：原样复用、仍可写、参数就地换上；换 uid 照旧交接作废', () async {
      final _CountingStores stores = _CountingStores(deps());
      final SrsDbStore first = await stores.activate(
        kSrsTestProfile,
        () => openOn(kSrsTestProfile),
      );
      // 在跑的写入不受再激活影响。
      final Future<String> inflight = first.createDeck('在途');
      int rebound = 0;
      final SrsDbStore again = await stores.activate(
        kSrsTestProfile,
        () => openOn(kSrsTestProfile),
        reuse: (SrsDbStore current) {
          rebound++;
          current.rebind(engine: null, fallbackRolloverHour: () => 7);
          return true;
        },
      );
      expect(identical(again, first), isTrue);
      expect(stores.opened, 1, reason: '同一 uid 不再开第二份副本');
      expect(rebound, 1);
      expect(first.isUsable, isTrue);
      expect(first.isWindingDown, isFalse);
      expect(first.engine, isNull, reason: '参数就地换上');
      await inflight;
      await first.createDeck('之后');

      // reuse 说不是同一份（连接变了）：交接重开。
      final SrsDbStore reopened = await stores.activate(
        kSrsTestProfile,
        () => openOn(kSrsTestProfile),
        reuse: (SrsDbStore current) => false,
      );
      expect(identical(reopened, first), isFalse);
      expect(first.isUsable, isFalse);
      expect(stores.opened, 2);

      // 真切换配置：旧副本作废，错误是带副本的 SrsStoreRetiredError。
      const String other = '01928c3e-0000-7000-8000-0000000000ef';
      final SrsDbStore b = await stores.activate(other, () => openOn(other));
      expect(b.profileUid, other);
      expect(reopened.isUsable, isFalse);
      await expectLater(
        reopened.createDeck('过期'),
        throwsA(
          isA<SrsStoreRetiredError>().having(
            (SrsStoreRetiredError e) => identical(e.store, reopened),
            'store',
            isTrue,
          ),
        ),
      );
    });
  });

  group('srsStoreProvider', () {
    late FushiDatabase db;
    late Directory support;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      await db.customStatement(
        'INSERT INTO profiles (id, name, uid, created_at, updated_at) '
        "VALUES (1, 'Default', '$kSrsTestProfile', 0, 0)",
      );
      support = Directory.systemTemp.createTempSync('fushi_srs_same_uid_');
      addTearDown(() async {
        await db.close();
        try {
          support.deleteSync(recursive: true);
        } on FileSystemException {
          // Windows 句柄滞后：临时目录留给系统清理。
        }
      });
    });

    test('配置装载期间不提前打开；装载完只开一次，配置视图重建也沿用同一份副本', () async {
      final Completer<void> gate = Completer<void>();
      final _GatedProfileRepository repo = _GatedProfileRepository(gate.future);
      final _CountingStores stores = _CountingStores(deps());
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => _AppModel(db)),
          srsModuleEnabledProvider.overrideWithValue(true),
          srsStorageProvider.overrideWith((Ref ref) async => storage),
          srsEngineProvider.overrideWithValue(const SrsTestEngine()),
          srsSupportRootProvider.overrideWithValue(() async => support),
          srsProfileStoresProvider.overrideWithValue(stores),
          profileRepositoryProvider.overrideWithValue(repo),
          profileViewModelProvider.overrideWith(
            (Ref ref) =>
                ProfileViewModel(repo, () async {}, ProfileDraftCoordinator()),
          ),
        ],
      );
      addTearDown(c.dispose);
      c.listen<AsyncValue<SrsDbStore?>>(
        srsStoreProvider,
        (AsyncValue<SrsDbStore?>? previous, AsyncValue<SrsDbStore?> next) {},
      );
      final Future<SrsDbStore?> pending = c.read(srsStoreProvider.future);
      await pumpEventQueue();
      expect(stores.opened, 0, reason: '激活 id 还是 -1：不自己解析一次去打开');

      gate.complete();
      final SrsDbStore store = (await pending)!;
      await pumpEventQueue();
      expect(stores.opened, 1);
      expect(identical(await c.read(srsStoreProvider.future), store), isTrue);
      expect(store.isUsable, isTrue, reason: '装载完成不再重建、不作废');

      // 配置视图整个重建（另一个 engine 改过偏好时 invalidate）：provider 重建，同一个配置沿用原副本。
      c.invalidate(profileViewModelProvider);
      final SrsDbStore after = (await c.read(srsStoreProvider.future))!;
      await pumpEventQueue();
      expect(identical(after, store), isTrue);
      expect(stores.opened, 1);
      expect(store.isUsable, isTrue);
      expect(store.isWindingDown, isFalse);
    });
  });

  group('SrsSyncScheduler', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('fushi_srs_same_uid_sched_');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } on FileSystemException {
          // Windows 句柄滞后：临时目录留给系统清理。
        }
      });
    });

    SrsSyncScheduler scheduler({
      required Future<SrsDbStore?> Function() readStore,
      required SrsSyncRunner runner,
    }) => SrsSyncScheduler(
      readStore: readStore,
      channels: (Future<void> Function(SyncAssetStore) body) async {
        await body(LocalDirectoryAssetStore(root));
        return (ran: 1, errors: const <Object>[]);
      },
      directoryKeyOf: (SyncAssetStore b) async => 'local:${root.path}',
      runner: runner,
      onDataChanged: () {},
      onNotice: (SrsSyncNotice n) {},
    );

    test('一轮途中副本被换掉：按收手结束（不算失败），用新副本马上重排一轮', () async {
      final SrsDbStore a = await openOn(kSrsTestProfile);
      SrsDbStore current = a;
      final List<SrsDbStore> ran = <SrsDbStore>[];
      final SrsSyncScheduler s = scheduler(
        readStore: () async => current,
        runner:
            (
              SyncAssetStore backend,
              SrsDbStore store,
              String key, {
              SrsLocationKey? locationKey,
            }) async {
              ran.add(store);
              if (ran.length == 1) {
                // 途中切配置 / 重开：交接作废这份副本，之后它的写入明确失败。
                current = await store.retire(
                  () => openOn(kSrsTestProfile),
                  reason: 'test handover',
                );
                await store.createDeck('过期');
              }
              return SrsSync2Report();
            },
      );
      addTearDown(s.dispose);
      final SrsSync2Report r = await s.syncWithBackend(
        LocalDirectoryAssetStore(root),
      );
      expect(r.error, isNull);
      expect(ran, hasLength(2));
      expect(identical(ran[0], a), isTrue);
      expect(identical(ran[1], current), isTrue);
      expect(ran[1].isUsable, isTrue);
      expect(
        s.roundStatsFor(LocalDirectoryAssetStore(root)).consecutiveFailures,
        0,
      );
    });

    test('新副本还没出来（读到的仍是被换掉的那份）：不打转，按副本不可用交回', () async {
      final SrsDbStore a = await openOn(kSrsTestProfile);
      int calls = 0;
      final SrsSyncScheduler s = scheduler(
        readStore: () async => a,
        runner:
            (
              SyncAssetStore backend,
              SrsDbStore store,
              String key, {
              SrsLocationKey? locationKey,
            }) async {
              calls++;
              await store.retire(() async {}, reason: 'test retire');
              await store.createDeck('过期');
              return SrsSync2Report();
            },
      );
      addTearDown(s.dispose);
      final SrsSync2Report r = await s.syncWithBackend(
        LocalDirectoryAssetStore(root),
      );
      expect(calls, 1);
      expect(r.error, kSrsSyncStoreUnavailable);
    });
  });
}
