// 旧内置 BT 站 → 用户 BT 站的一次性升级迁移：老用户启用 / 停用状态、幂等、新装
// 不迁、旧订阅 provider id 迁移后经注册表解析到迁出的站点。
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/bt_site_legacy_migration.dart';
import 'package:fushi_engine/media/torrent/bt_site_providers.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';

class _MapPrefs implements PrefStore {
  final Map<String, Object?> values = <String, Object?>{};
  int writes = 0;

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async {
    writes++;
    values[key] = value;
  }
}

Map<String, BtSiteConfig> _byId(PrefStore prefs) => <String, BtSiteConfig>{
  for (final BtSiteConfig site in readBtSiteConfigs(prefs)) site.id: site,
};

Future<BtSitesLegacyMigrationOutcome> _migrate(
  _MapPrefs prefs, {
  bool existingInstall = true,
  LegacyBtSourceUsage usage = const LegacyBtSourceUsage(),
  bool hostHadDiscoverySources = true,
}) => runLegacyBuiltinBtSitesMigration(
  prefs,
  existingInstall: existingInstall,
  usage: usage,
  hostHadDiscoverySources: hostHadDiscoverySources,
);

Future<VideoResourceRegistry> _registryFor(PrefStore prefs) async =>
    VideoResourceRegistry(
      await createBtSiteResourceProviders(
        readBtSiteConfigs(prefs),
        () async => MockClient((_) async => http.Response('[]', 200)),
      ),
    );

void main() {
  group('runLegacyBuiltinBtSitesMigration', () {
    test('老用户没动过开关：五个旧内置站全部迁出，启停沿用旧默认（Sukebei 默认停用）', () async {
      final _MapPrefs prefs = _MapPrefs();
      expect(await _migrate(prefs), BtSitesLegacyMigrationOutcome.migrated);
      final Map<String, BtSiteConfig> sites = _byId(prefs);
      expect(sites.keys, <String>[
        'nyaa.si',
        'sukebei.nyaa.si',
        'apibay.org',
        'knaben.org',
      ]);

      final BtSiteConfig nyaa = sites['nyaa.si']!;
      expect(nyaa.enabled, isTrue);
      expect(nyaa.format, BtSiteFormat.nyaa);
      expect(nyaa.baseUrl.toString(), 'https://nyaa.si');
      expect(nyaa.providerId, 'nyaa:nyaa.si');
      expect(nyaa.effectiveDomains, <BtSiteDomain>{
        BtSiteDomain.anime,
        BtSiteDomain.novel,
        BtSiteDomain.audiobook,
      });
      expect(nyaa.nyaaCategories[BtSiteDomain.anime], '1_0');
      expect(nyaa.nyaaCategories[BtSiteDomain.novel], '3_0');
      expect(nyaa.nyaaCategories[BtSiteDomain.audiobook], '2_0');

      final BtSiteConfig sukebei = sites['sukebei.nyaa.si']!;
      expect(sukebei.enabled, isFalse);
      expect(sukebei.baseUrl.toString(), 'https://sukebei.nyaa.si');
      expect(sukebei.effectiveDiscoveryKinds, <DiscoveryMediaKind>{
        DiscoveryMediaKind.game,
      });
      expect(sukebei.nyaaCategories[BtSiteDomain.game], '1_3');

      final BtSiteConfig apibay = sites['apibay.org']!;
      expect(apibay.enabled, isTrue);
      expect(apibay.format, BtSiteFormat.apibay);
      expect(apibay.baseUrl.toString(), 'https://apibay.org');
      expect(apibay.providerId, 'apibay:apibay.org');
      expect(apibay.effectiveVideoCategories, <VideoDiscoveryCategory>{
        VideoDiscoveryCategory.movie,
        VideoDiscoveryCategory.tv,
      });

      final BtSiteConfig knaben = sites['knaben.org']!;
      expect(knaben.enabled, isTrue);
      expect(knaben.format, BtSiteFormat.knaben);
      expect(knaben.baseUrl.toString(), 'https://api.knaben.org/v1');
      expect(knaben.providerId, 'knaben:knaben.org');

      expect(prefs.values[kBtSitesLegacyMigrationPref], 'migrated');
    });

    test('用户在旧版关掉的源迁过来保持停用；打开的保持启用', () async {
      final _MapPrefs prefs = _MapPrefs()
        ..values[kLegacyVideoResourceDisabledSourcesPref] = 'apibay,nyaa'
        // 用户把成人站打开、把 nyaa 发现源关掉。
        ..values[kLegacyDiscoveryDisabledSourcesPref] = 'nyaa';
      await _migrate(prefs, existingInstall: false);
      final Map<String, BtSiteConfig> sites = _byId(prefs);

      // nyaa 两个入口都关了：站点停用，但域勾回全部，重新启用就全回来。
      expect(sites['nyaa.si']!.enabled, isFalse);
      expect(sites['nyaa.si']!.domains, <BtSiteDomain>{
        BtSiteDomain.anime,
        BtSiteDomain.novel,
        BtSiteDomain.audiobook,
      });
      expect(sites['sukebei.nyaa.si']!.enabled, isTrue);
      expect(sites['apibay.org']!.enabled, isFalse);
      expect(sites['knaben.org']!.enabled, isTrue);
    });

    test('nyaa 只关了资源搜索：站点启用、只勾发现域（动画不再参与资源搜索）', () async {
      final _MapPrefs prefs = _MapPrefs()
        ..values[kLegacyVideoResourceDisabledSourcesPref] = 'nyaa';
      await _migrate(prefs);
      final BtSiteConfig nyaa = _byId(prefs)['nyaa.si']!;
      expect(nyaa.enabled, isTrue);
      expect(nyaa.effectiveVideoCategories, isEmpty);
      expect(nyaa.effectiveDiscoveryKinds, <DiscoveryMediaKind>{
        DiscoveryMediaKind.novel,
        DiscoveryMediaKind.audiobook,
      });
    });

    test('旧版停用清单不挡订阅：启用订阅依赖的格式迁出后必须启用', () async {
      final _MapPrefs prefs = _MapPrefs()
        ..values[kLegacyVideoResourceDisabledSourcesPref] = 'nyaa,apibay';
      await _migrate(
        prefs,
        usage: LegacyBtSourceUsage.fromProviderIds(
          subscriptions: <(String, bool)>[('nyaa:nyaa.si', true)],
        ),
      );
      final Map<String, BtSiteConfig> sites = _byId(prefs);
      expect(sites['nyaa.si']!.enabled, isTrue);
      expect(
        sites['nyaa.si']!.effectiveVideoCategories,
        contains(VideoDiscoveryCategory.anime),
      );
      // 没有订阅依赖 apibay：照旧停用。
      expect(sites['apibay.org']!.enabled, isFalse);
    });

    test('幂等：跑两次不重复添加，第二次什么都不写', () async {
      final _MapPrefs prefs = _MapPrefs();
      await _migrate(prefs);
      final Object? after = prefs.values[kResourceBtSitesPref];
      final int writes = prefs.writes;
      expect(await _migrate(prefs), BtSitesLegacyMigrationOutcome.alreadyDone);
      expect(prefs.values[kResourceBtSitesPref], after);
      expect(prefs.writes, writes);
    });

    test('标记之前崩溃（站点已写、标记没写）：重跑按 id 去重，不出重复站', () async {
      final _MapPrefs prefs = _MapPrefs();
      await _migrate(prefs);
      prefs.values.remove(kBtSitesLegacyMigrationPref);
      await _migrate(prefs);
      expect(readBtSiteConfigs(prefs), hasLength(4));
    });

    test('用户删掉迁出的站点后不会被加回来', () async {
      final _MapPrefs prefs = _MapPrefs();
      await _migrate(prefs);
      await writeBtSiteConfigs(prefs, <BtSiteConfig>[
        for (final BtSiteConfig site in readBtSiteConfigs(prefs))
          if (site.id != 'apibay.org') site,
      ]);
      await _migrate(prefs);
      expect(_byId(prefs).containsKey('apibay.org'), isFalse);
    });

    test('已自己加过同地址的站：保留用户那条，不再添加旧站', () async {
      final _MapPrefs prefs = _MapPrefs();
      await writeBtSiteConfigs(prefs, <BtSiteConfig>[
        BtSiteConfig(
          id: 'btmine',
          name: 'mine',
          baseUrl: Uri.parse('https://NYAA.si/'),
          format: BtSiteFormat.nyaa,
          domains: const <BtSiteDomain>{BtSiteDomain.anime},
          nyaaCategories: const <BtSiteDomain, String>{
            BtSiteDomain.anime: '1_2',
          },
        ),
      ]);
      await _migrate(prefs);
      final List<String> ids = <String>[
        for (final BtSiteConfig site in readBtSiteConfigs(prefs)) site.id,
      ];
      expect(ids, <String>[
        'btmine',
        'sukebei.nyaa.si',
        'apibay.org',
        'knaben.org',
      ]);
    });

    test('新装用户（没有任何旧版痕迹）不迁，只写标记', () async {
      final _MapPrefs prefs = _MapPrefs();
      expect(
        await _migrate(prefs, existingInstall: false),
        BtSitesLegacyMigrationOutcome.freshInstall,
      );
      expect(prefs.values.containsKey(kResourceBtSitesPref), isFalse);
      expect(prefs.values[kBtSitesLegacyMigrationPref], 'fresh');
      // 之后再满足老用户条件也不补迁（判定只做一次）。
      expect(await _migrate(prefs), BtSitesLegacyMigrationOutcome.alreadyDone);
      expect(readBtSiteConfigs(prefs), isEmpty);
    });

    test('安装信号缺失但有旧版痕迹（旧启停键 / 引用旧 provider id 的数据）也算老用户', () async {
      final _MapPrefs byPref = _MapPrefs()
        ..values[kLegacyDiscoveryDisabledSourcesPref] = 'sukebei';
      expect(
        await _migrate(byPref, existingInstall: false),
        BtSitesLegacyMigrationOutcome.migrated,
      );

      final _MapPrefs byData = _MapPrefs();
      expect(
        await _migrate(
          byData,
          existingInstall: false,
          usage: LegacyBtSourceUsage.fromProviderIds(
            subscriptions: const <(String, bool)>[],
            jobProviderIds: <String>['knaben:knaben.org'],
          ),
        ),
        BtSitesLegacyMigrationOutcome.migrated,
      );
    });

    test('无头服务端（从来没有发现源）：只迁三个资源索引器，nyaa 只有动画域', () async {
      final _MapPrefs prefs = _MapPrefs();
      await _migrate(prefs, hostHadDiscoverySources: false);
      final Map<String, BtSiteConfig> sites = _byId(prefs);
      expect(sites.keys, <String>['nyaa.si', 'apibay.org', 'knaben.org']);
      expect(sites['nyaa.si']!.domains, <BtSiteDomain>{BtSiteDomain.anime});
    });

    test('现有清单解码失败：不覆盖、不写标记', () async {
      final _MapPrefs prefs = _MapPrefs()
        ..values[kResourceBtSitesPref] = '{not json';
      expect(
        await _migrate(prefs),
        BtSitesLegacyMigrationOutcome.skippedUnreadableSites,
      );
      expect(prefs.values[kResourceBtSitesPref], '{not json');
      expect(prefs.values.containsKey(kBtSitesLegacyMigrationPref), isFalse);
    });
  });

  group('legacyBuiltinBtProviderFormat', () {
    test('认旧内置写法，不认用户站点 id 与非 BT 格式', () {
      expect(legacyBuiltinBtProviderFormat('nyaa'), BtSiteFormat.nyaa);
      expect(legacyBuiltinBtProviderFormat('nyaa:nyaa.si'), BtSiteFormat.nyaa);
      expect(legacyBuiltinBtProviderFormat('nyaa:default'), BtSiteFormat.nyaa);
      expect(
        legacyBuiltinBtProviderFormat('apibay:apibay.org'),
        BtSiteFormat.apibay,
      );
      expect(
        legacyBuiltinBtProviderFormat('knaben:knaben.org'),
        BtSiteFormat.knaben,
      );
      expect(legacyBuiltinBtProviderFormat('nyaa:btabc123'), isNull);
      expect(legacyBuiltinBtProviderFormat('torznab:x'), isNull);
    });
  });

  group('迁移后旧 provider id 经 resolveProvider 解析到迁出的站点', () {
    test('nyaa:nyaa.si / 裸 nyaa → nyaa.si；apibay / knaben 旧 id 精确命中', () async {
      final _MapPrefs prefs = _MapPrefs();
      await _migrate(prefs);
      final VideoResourceRegistry registry = await _registryFor(prefs);
      addTearDown(registry.close);

      String? resolved(String id, VideoDiscoveryCategory category) =>
          registry.resolveProvider(id, category: category)?.id;

      expect(
        resolved('nyaa:nyaa.si', VideoDiscoveryCategory.anime),
        'nyaa:nyaa.si',
      );
      // 旧 JSON 番剧订阅导入成的 v78 订阅存的是裸 `nyaa`。
      expect(resolved('nyaa', VideoDiscoveryCategory.anime), 'nyaa:nyaa.si');
      expect(
        resolved('apibay:apibay.org', VideoDiscoveryCategory.movie),
        'apibay:apibay.org',
      );
      expect(
        resolved('knaben:knaben.org', VideoDiscoveryCategory.tv),
        'knaben:knaben.org',
      );
      // 迁移前（新装 / 没迁）同一个 id 解析不到——迁移确实是这条链路通的原因。
      final VideoResourceRegistry empty = await _registryFor(_MapPrefs());
      addTearDown(empty.close);
      expect(
        empty.resolveProvider(
          'nyaa:nyaa.si',
          category: VideoDiscoveryCategory.anime,
        ),
        isNull,
      );
    });
  });
}
