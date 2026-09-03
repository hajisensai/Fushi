import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import 'fake_asset_store.dart';
import 'sync_orchestrator_test.dart' show FakeSyncBackend;

/// 「合集经常没同步」根修守卫（BUG-938）：
///
/// 根因：合集维度只搭载在低频全量 sweep（app 冷启动 + 5 分钟冷却 / 手动同步）上，
/// 用户高频触发的关书/切后台同步走单本路径、从不同步合集。修复 =
/// ① [SyncOrchestrator.runCollectionsOnly] 轻量入口（只跑合集维度，不写冷却戳）；
/// ② `installCollectionsSyncWatcher` 观察合集表写入 → 防抖调度轻量同步。
FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

void main() {
  group('SyncOrchestrator.runCollectionsOnly', () {
    late Directory work;
    late FakeAssetStore store;
    late FushiDatabase dbA;
    late FushiDatabase dbB;

    SyncOrchestrator orch(FushiDatabase db, String deviceId) =>
        SyncOrchestrator(
          db: db,
          backend: FakeSyncBackend(store),
          dictionaryResourceRoot: work,
          audioDatabaseRoot: work,
          tempDir: work,
          deviceId: deviceId,
          syncStats: false,
          syncAudioBookPosition: false,
          syncContent: false,
          syncAudioBookFiles: false,
          syncDictionary: false,
        );

    setUp(() async {
      work = await Directory.systemTemp.createTemp('coll_light_');
      store = FakeAssetStore();
      dbA = _memDb();
      dbB = _memDb();
      addTearDown(() async {
        await dbA.close();
        await dbB.close();
        if (work.existsSync()) await work.delete(recursive: true);
      });
    });

    test('A 建合集 → 双方 runCollectionsOnly → B 收到合集', () async {
      final int id = await dbA.createMediaCollection('Fav');
      await dbA.addToCollection(id, MediaKind.epub, 'book-1');

      await orch(dbA, 'devA').runCollectionsOnly();
      await orch(dbB, 'devB').runCollectionsOnly();

      final MediaCollectionRow? got =
          await dbB.getMediaCollectionByNaturalKey('Fav', 'collection');
      expect(got, isNotNull, reason: '轻量路径必须把合集传到对端');
      final List<MediaCollectionItemRow> items =
          await dbB.getCollectionItems(got!.id);
      expect(items.map((MediaCollectionItemRow m) => m.entryKey), ['book-1']);
    });

    test('runCollectionsOnly 不写全量 sweep 冷却戳 lastSyncMs', () async {
      await orch(dbA, 'devA').runCollectionsOnly();
      expect(await SyncRepository(dbA).getLastSyncMs(SyncChannelScope.unscoped),
          isNull,
          reason: '冷却戳属于完整 sweep 语义（TODO-1332），'
              '轻量路径写它会压制下一次 app-open 全量同步');
    });
  });

  group('installCollectionsSyncWatcher', () {
    test('合集表写入触发防抖调度；uninstall 后不再触发', () async {
      final FushiDatabase db = _memDb();
      addTearDown(() async {
        uninstallCollectionsSyncWatcher();
        await db.close();
      });

      final int before = collectionsSyncScheduledForTest;
      // 防抖窗给足够长，测试只断言「排定」，绝不真正跑同步（跑了会去解析真实后端）。
      installCollectionsSyncWatcher(
        db: db,
        debounce: const Duration(days: 1),
      );

      final int id = await db.createMediaCollection('Watch');
      await db.addToCollection(id, MediaKind.video, 'video/x');
      // drift tableUpdates 是异步流，让事件跑完。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(collectionsSyncScheduledForTest, greaterThan(before),
          reason: '合集写入必须触发轻量同步调度——这是「合集经常没同步」的根修');

      uninstallCollectionsSyncWatcher();
      final int after = collectionsSyncScheduledForTest;
      await db.addToCollection(id, MediaKind.video, 'video/y');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(collectionsSyncScheduledForTest, after,
          reason: 'uninstall 后不得再调度（测试 teardown / DB 关闭前的安全性）');
    });

    test('AppModel 初始化接线守卫（源码级）', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(src, contains('installCollectionsSyncWatcher(db: database)'),
          reason: 'AppModel.initialise 必须装载合集变更观察者，'
              '否则合集又退回「只有冷启动/手动才同步」的旧病');
    });
  });
}
