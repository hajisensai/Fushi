import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  // 互联从「互斥的 backendType==hibikiServer 单选」解耦成独立开关
  // （interconnectEnabled）：迁移把旧互联用户搬到独立开关 + 云默认 backendType，
  // 使互联与云备份可并存（用户诉求「互联和同步后端不冲突」）。
  group('migrateInterconnectBackendToToggle', () {
    test('migrates a hibikiServer backend to the independent toggle', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await db.setPref('sync_backend_type', 'hibikiServer');
      // 互联自身的独立字段本就不依赖 backendType，迁移不该动它们。
      await repo.setServerEnabled(true);
      await repo.addFushiClientUrl('https://peer.local:38765/');

      expect(await repo.isInterconnectEnabled(), isFalse);

      await repo.migrateInterconnectBackendToToggle();

      // 互联开关打开；backendType 迁到云默认（云通道未认证时自动 no-op）。
      expect(await repo.isInterconnectEnabled(), isTrue);
      expect(await repo.getBackendType(), SyncBackendType.googleDrive);
      // 互联独立配置原样保留。
      expect(await repo.isServerEnabled(), isTrue);
      expect((await repo.getFushiClientUrls()).isNotEmpty, isTrue);
    });

    test('is a no-op for a cloud backend (interconnect stays off)', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await db.setPref('sync_backend_type', 'webDav');

      await repo.migrateInterconnectBackendToToggle();

      expect(await repo.getBackendType(), SyncBackendType.webDav);
      expect(await repo.isInterconnectEnabled(), isFalse);
    });

    test('is idempotent (running twice does not flip anything back)', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await db.setPref('sync_backend_type', 'hibikiServer');

      await repo.migrateInterconnectBackendToToggle();
      // 第二次：迁移已标记跑过 → 直接 no-op，不会误关互联开关。
      await repo.migrateInterconnectBackendToToggle();

      expect(await repo.isInterconnectEnabled(), isTrue);
      expect(await repo.getBackendType(), SyncBackendType.googleDrive);
    });

    test('后续用户主动选回互联做备份后端，不会被下次启动的迁移抹掉', () async {
      // 互联页的「用互联做备份后端」按钮把 backendType 写成 hibikiServer。迁移若还只看
      // 「backendType 是不是 hibikiServer」，下次启动就会把这个用户选择当成旧数据改回
      // googleDrive——按钮变成重启即失效的假开关。一次性标记正是为此。
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      // 首次启动（云用户，无旧互联数据）：迁移跑过并落标记。
      await repo.migrateInterconnectBackendToToggle();
      expect(await repo.getBackendType(), SyncBackendType.googleDrive);

      // 用户按下按钮。
      await repo.setInterconnectEnabled(true);
      await repo.setBackendType(SyncBackendType.hibikiServer);

      // 下次启动再跑迁移。
      await repo.migrateInterconnectBackendToToggle();

      expect(await repo.getBackendType(), SyncBackendType.hibikiServer,
          reason: '用户主动选的备份后端必须活过重启');
      expect(await repo.isInterconnectEnabled(), isTrue);
    });

    test('旧互联用户即使升级后才首次启动，仍能被迁移一次', () async {
      // 标记只在迁移真跑过一次后才存在：存量 hibikiServer 用户的第一次启动必须仍然
      // 被搬到独立开关（Never break userspace）。
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await db.setPref('sync_backend_type', 'hibikiServer');
      await repo.migrateInterconnectBackendToToggle();

      expect(await repo.isInterconnectEnabled(), isTrue);
      expect(await repo.getBackendType(), SyncBackendType.googleDrive);
    });

    test('does not force interconnect on for a fresh install', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      // 全新安装：无 backend_type 记录 → getBackendType 默认 googleDrive。
      await repo.migrateInterconnectBackendToToggle();

      expect(await repo.isInterconnectEnabled(), isFalse);
      expect(await repo.getBackendType(), SyncBackendType.googleDrive);
    });
  });
}
