import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/aggregate_sync_service.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 通道分槽守卫（BUG-1576 / BUG-1578 / BUG-1579 / BUG-1580）。
///
/// 互联从「互斥的 backendType」解耦成「与云备份并存的第二通道」之后，一轮 sweep 会
/// 在同一把锁里依次跑两条通道。凡是「一台设备对一个远端」的持久化状态——folder
/// 缓存、合集/删除墓碑因果基线、同步冷却戳、聚合快照哈希——共用一份全局键就会互相
/// 覆盖。最严重的一例不是丢状态而是**外发凭据**：互联/WebDAV 的 folderId 是绝对
/// URL，被另一条通道读回后会被当成自己的路径直接请求出去，Basic 头一起带上。
///
/// 这批用例钉的是「分槽」这件事本身：槽位怎么从后端推导、不同槽位互不可见、迁移
/// 语义（旧全局键作初值 / folder 缓存丢弃重建）、以及键目录跟着一起展开。
FushiDatabase _memDb() {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  // 内存库默认关外键（cascade 用例会假绿）；本文件只碰 preferences，但仍按纪律开。
  db.customStatement('PRAGMA foreign_keys = ON');
  return db;
}

void main() {
  final SyncChannelScope drive =
      SyncChannelScope.forBackendType(SyncBackendType.googleDrive);
  final SyncChannelScope inter =
      SyncChannelScope.forBackendType(SyncBackendType.fushiServer);
  final SyncChannelScope dav =
      SyncChannelScope.forBackendType(SyncBackendType.webDav);
  group('syncChannelScopeOf 是 resolveSyncBackend 的逆', () {
    test('每个 SyncBackendType 解析出的后端都能反查回自己（新增后端漏改在此当场红）', () {
      for (final SyncBackendType type in SyncBackendType.values) {
        expect(
          syncChannelScopeOf(resolveSyncBackend(type)).id,
          SyncChannelScope.forBackendType(type).id,
          reason: '$type 的后端反查不回自己的槽位：它会和别的通道共用一格持久化键，'
              '互联/WebDAV 的绝对 URL folderId 就此串到另一条通道的请求上',
        );
      }
    });

    test('认不出的实例（测试 fake）落 unscoped，绝不与真实通道共用一格', () {
      final SyncChannelScope scope = syncChannelScopeOf(_UnknownBackend());
      expect(scope.id, 'unscoped');
      for (final SyncBackendType type in SyncBackendType.values) {
        expect(scope.id, isNot(SyncChannelScope.forBackendType(type).id));
      }
      expect(scope.id, isNot(SyncChannelScope.host.id));
    });

    test('槽位 id 两两不同（撞 id = 两条通道共用一把锁）', () {
      final List<String> ids =
          SyncChannelScope.all.map((SyncChannelScope s) => s.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
    });
  });

  group('folder 缓存分槽（BUG-1576）', () {
    late FushiDatabase db;
    late SyncRepository repo;

    setUp(() {
      db = _memDb();
      repo = SyncRepository(db);
    });
    tearDown(() => db.close());

    test('一条通道写的根 folderId 对另一条通道不可见', () async {
      // 互联通道的 folderId 是**绝对 URL**：这正是串槽后会被云后端当 fileId、
      // 被 WebDAV 当自己的路径直接请求（并附上自己的 Basic 凭据）的那个值。
      await repo.setRootFolderId(inter, 'https://peer.lan:8443/hibiki-data/');
      await repo.setFolderCache(
          inter, <String, String>{'書': 'https://peer.lan:8443/hibiki-data/書/'});

      expect(await repo.getRootFolderId(drive), isNull);
      expect(await repo.getFolderCache(drive), isEmpty);
      expect(await repo.getRootFolderId(dav), isNull);
      expect(await repo.getRootFolderId(inter),
          'https://peer.lan:8443/hibiki-data/');
    });

    test('清一条通道的缓存不动其它通道', () async {
      await repo.setRootFolderId(drive, 'drive-root');
      await repo.setRootFolderId(inter, 'https://peer.lan/hibiki-data/');

      await repo.clearFolderCache(drive);

      expect(await repo.getRootFolderId(drive), isNull);
      expect(
          await repo.getRootFolderId(inter), 'https://peer.lan/hibiki-data/');
    });

    test('clearAllFolderCaches 清掉全部槽位 + 解耦前的旧全局键（备份导入用）', () async {
      await db.setPref('sync_root_folder_id', 'legacy-root');
      await db.setPref('sync_folder_cache', '{"A":"legacy"}');
      await repo.setRootFolderId(drive, 'drive-root');
      await repo.setRootFolderId(inter, 'peer-root');

      await repo.clearAllFolderCaches();

      expect(await db.getPref('sync_root_folder_id'), isNull);
      expect(await db.getPref('sync_folder_cache'), isNull);
      for (final SyncChannelScope s in SyncChannelScope.all) {
        expect(await repo.getRootFolderId(s), isNull);
        expect(await repo.getFolderCache(s), isEmpty);
      }
    });

    test('迁移丢弃旧全局键、且**不搬运**到任何槽位（值已无法归因）', () async {
      await db.setPref('sync_root_folder_id', 'https://peer.lan/hibiki-data/');
      await db.setPref('sync_folder_cache', '{"A":"https://peer.lan/a/"}');
      await repo.setRootFolderId(drive, 'drive-root');

      await repo.migrateFolderCacheToPerChannel();

      expect(await db.getPref('sync_root_folder_id'), isNull);
      expect(await db.getPref('sync_folder_cache'), isNull);
      // 搬运才是错的：那个值可能是任一条通道写的，塞进哪一格都等于固化污染。
      for (final SyncChannelScope s in SyncChannelScope.all) {
        expect(await repo.getRootFolderId(s),
            isNot('https://peer.lan/hibiki-data/'));
      }
      // 已有的分槽值不受影响（迁移只删旧全局键）。
      expect(await repo.getRootFolderId(drive), 'drive-root');
      // 幂等。
      await repo.migrateFolderCacheToPerChannel();
      expect(await repo.getRootFolderId(drive), 'drive-root');
    });

    test('hasStoredBackendConfig(googleDrive) 不被互联那格的缓存污染', () async {
      // 一台从未登录过 Drive 的设备，只跑过互联同步。
      await repo.setRootFolderId(inter, 'https://peer.lan/hibiki-data/');
      expect(
        await repo.hasStoredBackendConfig(SyncBackendType.googleDrive),
        isFalse,
        reason: '判成「云已配置」会让删除确认框放行「从所有设备删除」，'
            '而根本没有云通道去发布墓碑——用户以为删干净了，实际只删了本机',
      );

      // Drive 自己那格有值才算配置过。
      await repo.setRootFolderId(drive, 'drive-root');
      expect(await repo.hasStoredBackendConfig(SyncBackendType.googleDrive),
          isTrue);
    });
  });

  group('因果基线与冷却戳分槽（BUG-1579 / BUG-1580）', () {
    late FushiDatabase db;
    late SyncRepository repo;

    setUp(() {
      db = _memDb();
      repo = SyncRepository(db);
    });
    tearDown(() => db.close());

    test('合集基线：三条轴（云 / 互联 / host）互不影响', () async {
      await repo.setCollectionsSyncBaselineMs(drive, 5000);
      expect(await repo.getCollectionsSyncBaselineMs(inter), 0);
      expect(await repo.getCollectionsSyncBaselineMs(SyncChannelScope.host), 0);

      await repo.setCollectionsSyncBaselineMs(inter, 7000);
      await repo.setCollectionsSyncBaselineMs(SyncChannelScope.host, 9000);
      expect(await repo.getCollectionsSyncBaselineMs(drive), 5000);
      expect(await repo.getCollectionsSyncBaselineMs(inter), 7000);
      expect(
          await repo.getCollectionsSyncBaselineMs(SyncChannelScope.host), 9000);
    });

    test('合集基线迁移：旧全局键作各槽位初值，写侧只写本槽位', () async {
      await db.setPref('sync_collections_baseline_ms', '4242');

      expect(await repo.getCollectionsSyncBaselineMs(drive), 4242,
          reason: '升级后第一轮若从 0 起，所有历史墓碑会被当成新闻重裁一遍');
      expect(await repo.getCollectionsSyncBaselineMs(inter), 4242);

      await repo.setCollectionsSyncBaselineMs(drive, 9000);
      expect(await repo.getCollectionsSyncBaselineMs(drive), 9000);
      expect(await repo.getCollectionsSyncBaselineMs(inter), 4242,
          reason: '一条通道推进基线不得连带压住另一条通道还没见过的墓碑');
      expect(await db.getPref('sync_collections_baseline_ms'), '4242',
          reason: '旧全局键只读不写（它是所有槽位的共同初值）');
    });

    test('删除墓碑消费基线：分槽 + 旧全局键作初值', () async {
      await db.setPref('sync_deletion_tombstones_baseline_ms', '1000');
      expect(await repo.getDeletionTombstonesBaselineMs(drive), 1000);

      await repo.setDeletionTombstonesBaselineMs(drive, 8000);
      expect(await repo.getDeletionTombstonesBaselineMs(drive), 8000);
      expect(await repo.getDeletionTombstonesBaselineMs(inter), 1000,
          reason: '云通道确认框推进的基线压住互联对端的老墓碑 = 那些条目永远不再弹，'
              '用户却以为「所有设备都删了」');
    });

    test('冷却戳：分槽 + 旧全局键作初值', () async {
      await db.setPref('sync_last_sync_ms', '111');
      expect(await repo.getLastSyncMs(drive), 111);
      expect(await repo.getLastSyncMs(inter), 111);

      await repo.setLastSyncMs(drive, 222);
      expect(await repo.getLastSyncMs(drive), 222);
      expect(await repo.getLastSyncMs(inter), 111,
          reason: '一条通道跑完不得把另一条通道一起压进 5 分钟冷却窗');
    });

    test('聚合快照哈希按通道分槽（云通道推完不得让互联通道跳过 PUT）', () async {
      final AggregateSyncService cloud = AggregateSyncService(db, scope: drive);
      final AggregateSyncService lan = AggregateSyncService(db, scope: inter);
      expect(cloud.scope.id, isNot(lan.scope.id));
    });

    test('设备本地键目录展开到每个槽位（漏展开 = 基线随备份跨设备泄漏）', () {
      for (final SyncChannelScope s in SyncChannelScope.all) {
        expect(SyncRepository.deviceLocalPrefKeys,
            contains(s.key('sync_collections_baseline_ms')));
        expect(SyncRepository.deviceLocalPrefKeys,
            contains(s.key('sync_deletion_tombstones_baseline_ms')));
      }
    });
  });

  group('删除高水位按通道分开记（BUG-1579）', () {
    test('mergeFrom 逐槽位取 max，绝不折成一个标量', () {
      final SyncRunReport a = SyncRunReport();
      a.noteDeletionHighWater(drive, 5000);
      a.noteDeletionHighWater(drive, 3000); // 只升不降

      final SyncRunReport b = SyncRunReport();
      b.noteDeletionHighWater(inter, 9000);

      a.mergeFrom(b);

      expect(a.deletionTombstonesHighWaterMsByScope, <String, int>{
        drive.id: 5000,
        inter.id: 9000,
      });
    });
  });

  group('鉴权失败的通道归属（BUG-1578）', () {
    SyncChannelAuthError err(SyncChannel c, SyncAuthFailureKind kind) =>
        SyncChannelAuthError(
          channel: c,
          error: SyncAuthError('rejected', kind: kind),
        );

    final SyncChannel cloudChannel = SyncChannel(
      resolveSyncBackend(SyncBackendType.googleDrive),
      type: SyncBackendType.googleDrive,
      isInterconnect: false,
    );
    final SyncChannel lanChannel = SyncChannel(
      resolveSyncBackend(SyncBackendType.fushiServer),
      type: SyncBackendType.fushiServer,
      isInterconnect: true,
    );

    test('互联通道的凭据类失败**不**触发登出（signOut 会清空整份配对配置）', () {
      expect(
        shouldSignOutChannelOnAuthError(
            err(lanChannel, SyncAuthFailureKind.credentials)),
        isFalse,
        reason: 'InterconnectSyncBackend.signOut 会抹掉全部对端地址/指纹/per-peer '
            'token；一台对端的 401 株连其余对端正是 BUG-1550 要消灭的行为',
      );
    });

    test('云通道保持原判据：credentials 登出、forbidden / browserTimeout 不登出', () {
      expect(
          shouldSignOutChannelOnAuthError(
              err(cloudChannel, SyncAuthFailureKind.credentials)),
          isTrue);
      expect(
          shouldSignOutChannelOnAuthError(
              err(cloudChannel, SyncAuthFailureKind.forbidden)),
          isFalse);
      expect(
          shouldSignOutChannelOnAuthError(
              err(cloudChannel, SyncAuthFailureKind.browserTimeout)),
          isFalse);
    });

    test('通道身份随异常一起流出：登出的对象由它决定，不再靠 backendType 猜', () {
      final SyncChannelAuthError e =
          err(lanChannel, SyncAuthFailureKind.credentials);
      expect(e.channel.type, SyncBackendType.fushiServer);
      expect(e.channel.scope.id,
          SyncChannelScope.forBackendType(SyncBackendType.fushiServer).id);
      expect(e.error.kind, SyncAuthFailureKind.credentials);
      // 原始错误信息一字不丢（UI 仍拿它给用户看）。
      expect(e.error.message, 'rejected');
    });

    test('通道槽位与 orchestrator/manager 的推导同源', () {
      expect(
          cloudChannel.scope.id, syncChannelScopeOf(cloudChannel.backend).id);
      expect(lanChannel.scope.id, syncChannelScopeOf(lanChannel.backend).id);
    });
  });
}

/// 谁都不是的后端（模拟测试 fake / 将来忘记登记的实现）。
class _UnknownBackend implements SyncBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
