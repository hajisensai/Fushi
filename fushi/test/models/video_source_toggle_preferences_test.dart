import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/sync/interconnect_service_config.dart';

/// 来源开关的偏好层：默认值即**兼容契约**，所以每一条默认值都要有断言。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });

  tearDown(() async {
    prefs.dispose();
    await db.close();
  });

  test('jimakuEnabled defaults to true so existing keys keep working', () {
    // 本键出现之前「填了 key」即启用。默认 false 会让所有已填 key 的存量用户在
    // 升级后 Jimaku 无声失效，且他们无从知道是新加了一个开关。
    expect(prefs.jimakuEnabled, isTrue);
  });

  test('jimakuEnabled round-trips', () async {
    await prefs.setJimakuEnabled(false);
    expect(prefs.jimakuEnabled, isFalse);
    await prefs.setJimakuEnabled(true);
    expect(prefs.jimakuEnabled, isTrue);
  });

  test('no BT site is built in: btSites is empty out of the box', () async {
    // Fushi 不内置任何 BT 站；没有用户站点 = BT 搜索没有来源。
    expect(prefs.btSites, isEmpty);
    final BtSiteConfig site = BtSiteConfig(
      id: 'site-1',
      name: 'My mirror',
      baseUrl: Uri.parse('https://nyaa.example'),
      format: BtSiteFormat.nyaa,
      domains: const <BtSiteDomain>{BtSiteDomain.anime, BtSiteDomain.novel},
      nyaaCategories: const <BtSiteDomain, String>{
        BtSiteDomain.anime: '1_0',
        BtSiteDomain.novel: '3_0',
      },
    );
    await prefs.setBtSites(<BtSiteConfig>[site]);
    final List<BtSiteConfig> back = prefs.btSites;
    expect(back, hasLength(1));
    expect(back.single.toJson(), site.toJson());
    expect(back.single.providerId, 'nyaa:site-1');
    // 落在新键上，旧停用清单键不再被写。
    expect(prefs.getPref(kResourceBtSitesPref, defaultValue: ''), isNotEmpty);
    expect(
      prefs.getPref('video_resource_disabled_sources', defaultValue: ''),
      '',
    );
    await prefs.setBtSites(const <BtSiteConfig>[]);
    expect(prefs.btSites, isEmpty);
  });

  test('a malformed BT site list reads as empty instead of throwing', () async {
    await prefs.setPref(kResourceBtSitesPref, '{not json');
    expect(prefs.btSites, isEmpty);
  });

  test('discovery excludes nothing by default (no built-in adult source)', () {
    // 内置 nyaa / sukebei 发现源已不存在；用户站点各自带 enabled。
    expect(prefs.discoveryDisabledSources, '');
  });

  test('keys are registered as known preference keys', () {
    // 未登记的键会被偏好审计当成孤儿清掉。旧停用清单键冻结但仍登记，防止键名
    // 被别的功能复用。
    expect(kKnownPreferenceKeys, contains('jimaku_enabled'));
    expect(kKnownPreferenceKeys, contains('video_resource_disabled_sources'));
    expect(kKnownPreferenceKeys, contains(kResourceBtSitesPref));
    expect(kResourceBtSitesPref, 'resource_bt_sites');
  });

  test('BT site list is device-local and treated as a credential', () {
    // 站点地址可能带 passkey：与 video_resource_torznab_config 同样归类。
    expect(SyncRepository.deviceLocalPrefKeys, contains(kResourceBtSitesPref));
    expect(PrefRedactionPolicy.sensitiveKeys, contains(kResourceBtSitesPref));
    expect(
      PrefRedactionPolicy.isDeviceLocalOrCredential(kResourceBtSitesPref),
      isTrue,
    );
  });

  test(
    'the Jimaku switch travels with the key across interconnected devices',
    () {
      // 只搬 key 不搬开关，子设备会拿到一把配好却处于关闭状态的 key。
      expect(
        InterconnectServiceConfigSnapshot.sharedPreferenceKeys,
        containsAll(<String>['jimaku_api_key', 'jimaku_enabled']),
      );
      // 用户 BT 站与 Torznab 同类，随互联服务配置同步到子设备。
      expect(
        InterconnectServiceConfigSnapshot.sharedPreferenceKeys,
        containsAll(<String>[
          'video_resource_torznab_config',
          kResourceBtSitesPref,
        ]),
      );
      // 冻结的旧停用清单与发现页停用清单是设备本地口味，不跨设备携带。
      expect(
        InterconnectServiceConfigSnapshot.sharedPreferenceKeys,
        isNot(contains('video_resource_disabled_sources')),
      );
      expect(
        InterconnectServiceConfigSnapshot.sharedPreferenceKeys,
        isNot(contains('discovery_disabled_sources')),
      );
    },
  );
}
