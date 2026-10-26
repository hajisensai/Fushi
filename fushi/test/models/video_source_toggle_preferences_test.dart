import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
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

  test('no BT search site ships with the app: RSS sites start empty', () async {
    // 仓库不内置任何 BT 搜索站、也不给预设：出厂一个都没有。
    expect(prefs.resourceRssSites, isEmpty);
    final RssSearchSiteConfig site = RssSearchSiteConfig(
      id: 'site1',
      name: 'Mine',
      urlTemplate: 'https://example.com/rss?q={query}',
      domains: const <RssSearchDomain>[
        RssSearchDomain.anime,
        RssSearchDomain.novel,
      ],
    );
    await prefs.setResourceRssSites(<RssSearchSiteConfig>[site]);
    expect(prefs.resourceRssSites.single.toJson(), site.toJson());
  });

  test('discovery aggregate excludes nothing by default', () {
    expect(prefs.discoveryDisabledSources, '');
  });

  test('keys are registered as known preference keys', () {
    // 未登记的键会被偏好审计当成孤儿清掉。
    expect(kKnownPreferenceKeys, contains('jimaku_enabled'));
    expect(kKnownPreferenceKeys, contains('resource_rss_sites'));
  });

  test('RSS sites are classified exactly like Torznab indexers', () {
    // 模板里可能带私有站 passkey：不随备份 / Profile 快照 / Profile 分享出境，
    // 但和 Torznab 一样经已认证的互联通道搬到用户自己的另一台设备。
    for (final String key in <String>[
      'video_resource_torznab_config',
      'resource_rss_sites',
    ]) {
      expect(
        PrefRedactionPolicy.isDeviceLocalOrCredential(key),
        isTrue,
        reason: key,
      );
      expect(PrefRedactionPolicy.sensitiveKeys, contains(key), reason: key);
      expect(SyncRepository.deviceLocalPrefKeys, contains(key), reason: key);
      expect(
        InterconnectServiceConfigSnapshot.sharedPreferenceKeys,
        contains(key),
        reason: key,
      );
    }
  });

  test(
    'the Jimaku switch travels with the key across interconnected devices',
    () {
      // 只搬 key 不搬开关，子设备会拿到一把配好却处于关闭状态的 key。
      expect(
        InterconnectServiceConfigSnapshot.sharedPreferenceKeys,
        containsAll(<String>['jimaku_api_key', 'jimaku_enabled']),
      );
      // 停用清单是设备本地口味，不跨设备携带。
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
