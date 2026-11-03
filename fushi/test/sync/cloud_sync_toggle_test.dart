import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 用户反馈：开了 Fushi 互联以后没办法关掉云盘同步，设置里找不到地方。
///
/// 云备份通道过去「只要选了后端就恒尝试」，唯一的停法是退出账号。现在它有一个与
/// 互联总开关对称的独立开关 [SyncRepository.isCloudSyncEnabled]。所有云同步路径（常规
/// 同步、复习同步、资产传输）都从 [enabledSyncChannelBackends] 取通道，所以开关的
/// 真实落点就是这份枚举：关掉后云通道不得出现，且凭据不动。
void main() {
  setUp(() => debugSyncChannelsOverride = null);

  test('默认开：没碰过开关时云通道照旧列出（升级不改既有行为）', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await repo.setBackendType(SyncBackendType.googleDrive);

    expect(await repo.isCloudSyncEnabled(), isTrue);
    final List<SyncChannel> channels = await enabledSyncChannelBackends(repo);
    expect(channels, hasLength(1));
    expect(channels.single.isInterconnect, isFalse);
    expect(channels.single.type, SyncBackendType.googleDrive);
  });

  test('关掉云通道 + 互联开着：只剩互联通道，云盘凭据与后端选择原样保留', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await repo.setBackendType(SyncBackendType.webDav);
    await repo.setWebDavUrl('https://dav.example.com/fushi');
    await repo.setWebDavUsername('alice');
    await repo.setInterconnectEnabled(true);

    await repo.setCloudSyncEnabled(false);

    final List<SyncChannel> channels = await enabledSyncChannelBackends(repo);
    expect(channels, hasLength(1));
    expect(channels.single.isInterconnect, isTrue);
    expect(channels.single.backend, isA<InterconnectSyncBackend>());
    expect(
      channels.where((SyncChannel c) => !c.isInterconnect),
      isEmpty,
      reason: '云通道关掉后不得出现在通道枚举里',
    );

    // 只停用、不登出：重新打开就能接着用。
    expect(await repo.getBackendType(), SyncBackendType.webDav);
    expect(await repo.getWebDavUrl(), 'https://dav.example.com/fushi');
    expect(await repo.getWebDavUsername(), 'alice');
  });

  test('关掉云通道 + 互联也关：没有任何通道，自动同步与复习同步都不跑', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await repo.setBackendType(SyncBackendType.googleDrive);
    await repo.setAutoSyncEnabled(true);

    await repo.setCloudSyncEnabled(false);

    expect(await enabledSyncChannelBackends(repo), isEmpty);
    expect(
      await autoSyncChannels(repo),
      isEmpty,
      reason: '云通道的自动同步开关开着也不得把关掉的通道带回来',
    );

    int calls = 0;
    final ({int ran, List<Object> errors}) result =
        await runOnAuthenticatedSyncChannels(
          db: db,
          body: (SyncBackend _) async => calls++,
        );
    expect(result.ran, 0);
    expect(result.errors, isEmpty);
    expect(calls, 0, reason: '复习同步经此入口，云通道关着时 body 不得被调用');
  });

  test('备份后端选成互联 + 云通道关：互联通道仍由互联总开关列出一次', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await repo.setBackendType(SyncBackendType.fushiServer);
    await repo.setInterconnectEnabled(true);

    await repo.setCloudSyncEnabled(false);

    final List<SyncChannel> channels = await enabledSyncChannelBackends(repo);
    expect(channels, hasLength(1));
    expect(channels.single.isInterconnect, isTrue);
  });

  test('重新打开：云通道回到第一格，排在互联之前', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await repo.setBackendType(SyncBackendType.dropbox);
    await repo.setInterconnectEnabled(true);
    await repo.setCloudSyncEnabled(false);

    await repo.setCloudSyncEnabled(true);

    final List<SyncChannel> channels = await enabledSyncChannelBackends(repo);
    expect(channels, hasLength(2));
    expect(channels[0].isInterconnect, isFalse);
    expect(channels[0].type, SyncBackendType.dropbox);
    expect(channels[1].isInterconnect, isTrue);
  });

  test('开关设备本地：不随备份 / 设置同步漂到别的设备', () {
    expect(SyncRepository.deviceLocalPrefKeys, contains('sync_cloud_enabled'));
  });
}
