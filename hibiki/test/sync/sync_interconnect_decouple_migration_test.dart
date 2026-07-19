import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  // 互联从「互斥的 backendType==hibikiServer 单选」解耦成独立开关
  // （interconnectEnabled）：迁移把旧互联用户搬到独立开关 + 云默认 backendType，
  // 使互联与云备份可并存（用户诉求「互联和同步后端不冲突」）。
  group('migrateInterconnectBackendToToggle', () {
    test('migrates a hibikiServer backend to the independent toggle', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await db.setPref('sync_backend_type', 'hibikiServer');
      // 互联自身的独立字段本就不依赖 backendType，迁移不该动它们。
      await repo.setServerEnabled(true);
      await repo.addHibikiClientUrl('https://peer.local:38765/');

      expect(await repo.isInterconnectEnabled(), isFalse);

      await repo.migrateInterconnectBackendToToggle();

      // 互联开关打开；backendType 迁到云默认（云通道未认证时自动 no-op）。
      expect(await repo.isInterconnectEnabled(), isTrue);
      expect(await repo.getBackendType(), SyncBackendType.googleDrive);
      // 互联独立配置原样保留。
      expect(await repo.isServerEnabled(), isTrue);
      expect((await repo.getHibikiClientUrls()).isNotEmpty, isTrue);
    });

    test('is a no-op for a cloud backend (interconnect stays off)', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await db.setPref('sync_backend_type', 'webDav');

      await repo.migrateInterconnectBackendToToggle();

      expect(await repo.getBackendType(), SyncBackendType.webDav);
      expect(await repo.isInterconnectEnabled(), isFalse);
    });

    test('is idempotent (running twice does not flip anything back)', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await db.setPref('sync_backend_type', 'hibikiServer');

      await repo.migrateInterconnectBackendToToggle();
      // 第二次：backendType 已是 googleDrive → 直接 no-op，不会误关互联开关。
      await repo.migrateInterconnectBackendToToggle();

      expect(await repo.isInterconnectEnabled(), isTrue);
      expect(await repo.getBackendType(), SyncBackendType.googleDrive);
    });

    test('does not force interconnect on for a fresh install', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      // 全新安装：无 backend_type 记录 → getBackendType 默认 googleDrive。
      await repo.migrateInterconnectBackendToToggle();

      expect(await repo.isInterconnectEnabled(), isFalse);
      expect(await repo.getBackendType(), SyncBackendType.googleDrive);
    });
  });
}
