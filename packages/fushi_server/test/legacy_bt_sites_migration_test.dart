// 无头服务端的旧内置 BT 站升级迁移：老服务端（设备身份已存在）迁出三个资源索引器，
// 新装服务端不迁；身份由 ServerIdentity.loadOrCreate 写下后再跑也不会补迁。
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/bt_site_legacy_migration.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:test/test.dart';

void main() {
  late FushiDatabase db;
  late ServerPrefs prefs;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = ServerPrefs(db);
    await prefs.warmUp();
  });

  tearDown(() => db.close());

  test('老服务端（设备身份已在）：迁出 Nyaa / apibay / Knaben，按旧停用清单启停', () async {
    await prefs.setRaw(ServerIdentity.kDeviceIdKey, 'device-1');
    await prefs.setPref(kLegacyVideoResourceDisabledSourcesPref, 'knaben');
    await prefs.warmUp();

    await settleServerLegacyBuiltinBtSites(db, prefs);

    final Map<String, BtSiteConfig> sites = <String, BtSiteConfig>{
      for (final BtSiteConfig s in readBtSiteConfigs(prefs)) s.id: s,
    };
    expect(sites.keys, <String>['nyaa.si', 'apibay.org', 'knaben.org']);
    expect(sites['nyaa.si']!.enabled, isTrue);
    expect(sites['apibay.org']!.enabled, isTrue);
    expect(sites['knaben.org']!.enabled, isFalse);

    // 重启再跑：标记已在，不重复。
    await ServerIdentity.loadOrCreate(prefs);
    await settleServerLegacyBuiltinBtSites(db, prefs);
    expect(readBtSiteConfigs(prefs), hasLength(3));
  });

  test('新装服务端：不迁；身份写下后的下一次启动也不补迁', () async {
    await settleServerLegacyBuiltinBtSites(db, prefs);
    expect(readBtSiteConfigs(prefs), isEmpty);

    await ServerIdentity.loadOrCreate(prefs);
    await settleServerLegacyBuiltinBtSites(db, prefs);
    expect(readBtSiteConfigs(prefs), isEmpty);
  });
}
