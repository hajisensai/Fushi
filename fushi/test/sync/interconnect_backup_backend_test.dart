import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 用户诉求：「hibiki 互联里面加一个按钮，把备份后端设置为 hibiki 互联」。
///
/// 互联解耦（PR#223）后 hibikiServer 从后端选择器里被摘掉，「备份写到已配对设备而不是
/// 云盘」这条能力还在（[resolveSyncBackend] 仍解析成 [InterconnectSyncBackend]）但没有
/// 入口。互联页新增的按钮走 [applyBackupBackendChange] 把它放回来，本测试守住这条路径的
/// 两个真实落点：切换副作用、以及切换后同步通道的归属。
void main() {
  group('applyBackupBackendChange', () {
    test('把备份后端设成互联：写穿 backendType，并清掉离开 FTP 时的专属 TLS 标记', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setBackendType(SyncBackendType.ftp);
      await repo.setFtpTlsEnabled(true);

      await applyBackupBackendChange(
        repo,
        previous: SyncBackendType.ftp,
        next: SyncBackendType.hibikiServer,
      );

      expect(await repo.getBackendType(), SyncBackendType.hibikiServer);
      expect(await repo.isFtpTlsEnabled(), isFalse,
          reason: 'FTP 专属的 TLS 标记不该在切走后残留');
    });

    test('非 FTP 起点不误动 FTP TLS 标记', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setFtpTlsEnabled(true);

      await applyBackupBackendChange(
        repo,
        previous: SyncBackendType.googleDrive,
        next: SyncBackendType.hibikiServer,
      );

      expect(await repo.getBackendType(), SyncBackendType.hibikiServer);
      expect(await repo.isFtpTlsEnabled(), isTrue);
    });
  });

  group('enabledSyncChannelBackends', () {
    test('备份后端选成互联时只跑一条通道，且按互联通道计（读互联专属上传开关）', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setInterconnectEnabled(true);
      await repo.setBackendType(SyncBackendType.hibikiServer);

      final List<SyncChannel> channels = await enabledSyncChannelBackends(repo);

      expect(channels, hasLength(1), reason: '同一单例后端不得跑两遍');
      expect(channels.single.backend, isA<InterconnectSyncBackend>());
      // 关键：这条通道跑的是互联链路，分资产开关就必须读互联专属上传开关，否则用户在
      // 互联页看到的四个上传开关会被静默忽略、改由云备份开关决定。
      expect(channels.single.isInterconnect, isTrue);
    });

    test('云后端 + 互联启用仍是两条通道，各自归属不变', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setInterconnectEnabled(true);
      await repo.setBackendType(SyncBackendType.googleDrive);

      final List<SyncChannel> channels = await enabledSyncChannelBackends(repo);

      expect(channels, hasLength(2));
      expect(channels[0].isInterconnect, isFalse);
      expect(channels[1].isInterconnect, isTrue);
      expect(channels[1].backend, isA<InterconnectSyncBackend>());
    });

    test('互联未启用时只有云通道', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);

      await repo.setBackendType(SyncBackendType.googleDrive);

      final List<SyncChannel> channels = await enabledSyncChannelBackends(repo);

      expect(channels, hasLength(1));
      expect(channels.single.isInterconnect, isFalse);
    });
  });

  group('mine_to_server 偏好', () {
    // 「制卡到已配对设备」从「制卡」分类移进互联分类后落在 interconnectEnabled 门控之后，
    // 设置覆盖 harness（默认互联关）不再遍历到它，那条写穿/持久化验证随之丢失。这里把它
    // 补回来：显式 setter（取代原来只能盲翻的 toggle）的往返 + 跨 reload 持久化。
    test('默认关；set 往返并跨 reload 持久化', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final PreferencesRepository repo = PreferencesRepository(db);
      await repo.loadFromDb();

      expect(repo.mineToServer, isFalse, reason: '默认本地制卡，零回归');

      await repo.setMineToServer(true);
      expect(repo.mineToServer, isTrue);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.mineToServer, isTrue);

      await reloaded.setMineToServer(false);
      expect(reloaded.mineToServer, isFalse);
    });
  });
}
