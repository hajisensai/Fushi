/// 旧「内置 BT 站」→ 用户 BT 站的一次性升级迁移（app 与无头服务端共用）。
///
/// PR #2563 把 BT 资源搜索改成「只有用户自己添加的 BT 站」（[kResourceBtSitesPref]），
/// 同时删掉了全部内置站点。没有这一步的话，老用户升级上来资源搜索 / 发现页的 BT 来源
/// 变空，存的是 `nyaa:nyaa.si` 之类旧 provider id 的订阅找不到站点就暂停。
///
/// 旧内置站点（以 #2563 合入前 develop 的代码为准）：
///
/// | 旧入口 | 地址 | 格式 | 旧 id（停用清单记名 / 持久化 provider id） | 媒体域 → 分类 |
/// |---|---|---|---|---|
/// | 资源索引器 Nyaa | `https://nyaa.si` | nyaa | `nyaa` / `nyaa:nyaa.si` | 动画 `1_0` |
/// | 发现源 Nyaa | `https://nyaa.si` | nyaa | 发现源 `nyaa` | 小说 `3_0`、有声书 `2_0` |
/// | 发现源 Sukebei | `https://sukebei.nyaa.si` | nyaa | 发现源 `sukebei` | 游戏 `1_3` |
/// | 资源索引器 apibay | `https://apibay.org` | apibay | `apibay` / `apibay:apibay.org` | 电影、剧集 |
/// | 资源索引器 Knaben | `https://api.knaben.org/v1` | knaben | `knaben` / `knaben:knaben.org` | 电影、剧集 |
///
/// 旧启停偏好：资源索引器 `video_resource_disabled_sources`（逗号分隔停用 id，缺省空 =
/// 全部启用）；发现源 `discovery_disabled_sources`（缺省 `sukebei` = 成人站默认不进聚合）。
///
/// 迁出的站点 id 就是旧持久化 provider id 的实例部分（`nyaa.si` / `apibay.org` /
/// `knaben.org`），于是旧订阅 / 任务 / 订阅条目上存的 `nyaa:nyaa.si` 经
/// `VideoResourceRegistry.resolveProvider` 第一条规则就**精确**命中迁出的站点；裸
/// `nyaa` 之类走它的「同格式第一个站点」回退规则。
library;

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';

/// 迁移已跑标记（设备本地）：`migrated` = 判成老用户并迁过；`fresh` = 判成新装，
/// 不迁。标记在就不再跑——用户之后删掉迁出的站点不会被加回来。
const String kBtSitesLegacyMigrationPref = 'resource_bt_sites_legacy_migrated';

/// 旧资源索引器停用清单（冻结键，只读）。
const String kLegacyVideoResourceDisabledSourcesPref =
    'video_resource_disabled_sources';

/// 发现源「全部源」聚合停用清单（仍在用；这里只读旧内置源的两个 id）。
const String kLegacyDiscoveryDisabledSourcesPref = 'discovery_disabled_sources';

/// 旧版 [kLegacyDiscoveryDisabledSourcesPref] 键缺省时的值（#2563 前的默认）。
const String kLegacyDiscoveryDisabledSourcesDefault = 'sukebei';

const String _markerMigrated = 'migrated';
const String _markerFresh = 'fresh';

/// 旧内置源用过的实例名（持久化 provider id 的 `:` 后半段）。
const Map<BtSiteFormat, Set<String>> _legacyInstanceIds =
    <BtSiteFormat, Set<String>>{
      BtSiteFormat.nyaa: <String>{'nyaa.si', 'default'},
      BtSiteFormat.apibay: <String>{'apibay.org'},
      BtSiteFormat.knaben: <String>{'knaben.org'},
    };

/// [providerId] 是不是旧内置 BT 源写下的持久化 id（`nyaa` / `nyaa:nyaa.si` /
/// `apibay:apibay.org` / `knaben:knaben.org` 等）。用户站点的 id（`nyaa:bt…`）不算。
BtSiteFormat? legacyBuiltinBtProviderFormat(String providerId) {
  final String trimmed = providerId.trim();
  final int colon = trimmed.indexOf(':');
  final BtSiteFormat? format = BtSiteFormat.fromWire(
    colon < 0 ? trimmed : trimmed.substring(0, colon),
  );
  if (format == null) return null;
  if (colon < 0) return format;
  return _legacyInstanceIds[format]!.contains(trimmed.substring(colon + 1))
      ? format
      : null;
}

/// 本机数据里对旧内置 BT 源的引用（订阅 / 下载任务上存的 provider id）。
class LegacyBtSourceUsage {
  const LegacyBtSourceUsage({
    this.referencesLegacySources = false,
    this.formatsUsedByEnabledSubscriptions = const <BtSiteFormat>{},
  });

  /// 任一订阅 / 任务引用了旧内置源：这台机器在升级前确实用过它们。
  final bool referencesLegacySources;

  /// 启用中的订阅依赖的旧内置源格式。旧版的停用清单只管「搜索时参不参与」，订阅
  /// 照样能用停用的源（订阅服务看的是未过滤的 provider 表）；新模型里一个站点只有
  /// 一个启用开关，所以这些格式迁出的站点必须启用，否则订阅升级后就断了。
  final Set<BtSiteFormat> formatsUsedByEnabledSubscriptions;

  /// 由订阅（provider id + 是否启用）与任务的 provider id 算出（纯函数）。
  factory LegacyBtSourceUsage.fromProviderIds({
    required Iterable<(String providerId, bool enabled)> subscriptions,
    Iterable<String> jobProviderIds = const <String>[],
  }) {
    bool references = false;
    final Set<BtSiteFormat> inUse = <BtSiteFormat>{};
    for (final (String providerId, bool enabled) in subscriptions) {
      final BtSiteFormat? format = legacyBuiltinBtProviderFormat(providerId);
      if (format == null) continue;
      references = true;
      if (enabled) inUse.add(format);
    }
    if (!references) {
      references = jobProviderIds.any(
        (String id) => legacyBuiltinBtProviderFormat(id) != null,
      );
    }
    return LegacyBtSourceUsage(
      referencesLegacySources: references,
      formatsUsedByEnabledSubscriptions: Set<BtSiteFormat>.unmodifiable(inUse),
    );
  }
}

/// 扫一遍数据库里的视频下载订阅与任务（app 与服务端同一张表）。
Future<LegacyBtSourceUsage> scanLegacyBtSourceUsage(FushiDatabase db) async =>
    LegacyBtSourceUsage.fromProviderIds(
      subscriptions: <(String, bool)>[
        for (final VideoDownloadSubscriptionRow row
            in await db.getVideoDownloadSubscriptions())
          (row.resourceProvider, row.enabled),
      ],
      jobProviderIds: <String>[
        for (final VideoDownloadJobRow row in await db.getVideoDownloadJobs())
          row.resourceProvider,
      ],
    );

/// 逗号分隔的 id 清单 → 集合（去空白、丢空项）。
Set<String> _idSet(Object? raw) => <String>{
  for (final String id in (raw ?? '').toString().split(','))
    if (id.trim().isNotEmpty) id.trim(),
};

/// 旧内置站点按当时的启停状态转成等价的用户 BT 站（纯函数）。
///
/// - 资源索引器的启用状态来自 [disabledResourceSourceIds]（旧停用清单），但被
///   [formatsUsedByEnabledSubscriptions] 里的格式一律启用（理由见
///   [LegacyBtSourceUsage.formatsUsedByEnabledSubscriptions]）。
/// - [disabledDiscoverySourceIds] 为 null = 这台主机上从来没有发现源（无头服务端 /
///   iOS），只迁资源索引器那几个域；否则 nyaa.si 的小说 / 有声书域与 Sukebei 按
///   发现源的启停迁。
/// - nyaa.si 在旧版是资源索引器 + 发现源两个入口，新模型一个站点只有一个开关：
///   哪个入口启用就勾哪几个域；两个都停用 → 站点停用但勾回全部域（用户重新启用就
///   全部回来）。
/// - [includeResourceSites] 为 false（主机上从没有资源搜索，如 iOS）时不迁资源域。
///
/// 停用的站点也迁过来（保持停用），这样用户在设置里还能找回它。
List<BtSiteConfig> legacyBuiltinBtSites({
  required Set<String> disabledResourceSourceIds,
  required Set<String>? disabledDiscoverySourceIds,
  bool includeResourceSites = true,
  Set<BtSiteFormat> formatsUsedByEnabledSubscriptions = const <BtSiteFormat>{},
}) {
  bool resourceEnabled(BtSiteFormat format) =>
      formatsUsedByEnabledSubscriptions.contains(format) ||
      !disabledResourceSourceIds.contains(format.name);
  final Set<String>? discoveryDisabled = disabledDiscoverySourceIds;
  final List<BtSiteConfig> sites = <BtSiteConfig>[];

  // nyaa.si：资源（动画）+ 发现（小说 / 有声书）。
  final Set<BtSiteDomain> nyaaAll = <BtSiteDomain>{
    if (includeResourceSites) BtSiteDomain.anime,
    if (discoveryDisabled != null) ...<BtSiteDomain>{
      BtSiteDomain.novel,
      BtSiteDomain.audiobook,
    },
  };
  if (nyaaAll.isNotEmpty) {
    final Set<BtSiteDomain> nyaaOn = <BtSiteDomain>{
      if (includeResourceSites && resourceEnabled(BtSiteFormat.nyaa))
        BtSiteDomain.anime,
      if (discoveryDisabled != null &&
          !discoveryDisabled.contains('nyaa')) ...<BtSiteDomain>{
        BtSiteDomain.novel,
        BtSiteDomain.audiobook,
      },
    };
    sites.add(
      BtSiteConfig(
        id: 'nyaa.si',
        name: 'Nyaa',
        baseUrl: Uri.parse('https://nyaa.si'),
        format: BtSiteFormat.nyaa,
        domains: nyaaOn.isEmpty ? nyaaAll : nyaaOn,
        nyaaCategories: const <BtSiteDomain, String>{
          BtSiteDomain.anime: '1_0',
          BtSiteDomain.audiobook: '2_0',
          BtSiteDomain.novel: '3_0',
        },
        enabled: nyaaOn.isNotEmpty,
      ),
    );
  }

  // sukebei.nyaa.si：只有发现页的游戏域（成人站，旧版默认不进聚合）。
  if (discoveryDisabled != null) {
    sites.add(
      BtSiteConfig(
        id: 'sukebei.nyaa.si',
        name: 'Sukebei',
        baseUrl: Uri.parse('https://sukebei.nyaa.si'),
        format: BtSiteFormat.nyaa,
        domains: const <BtSiteDomain>{BtSiteDomain.game},
        nyaaCategories: const <BtSiteDomain, String>{BtSiteDomain.game: '1_3'},
        enabled: !discoveryDisabled.contains('sukebei'),
      ),
    );
  }

  if (includeResourceSites) {
    sites.add(
      BtSiteConfig(
        id: 'apibay.org',
        name: 'apibay',
        baseUrl: Uri.parse('https://apibay.org'),
        format: BtSiteFormat.apibay,
        domains: const <BtSiteDomain>{BtSiteDomain.movie, BtSiteDomain.tv},
        enabled: resourceEnabled(BtSiteFormat.apibay),
      ),
    );
    sites.add(
      BtSiteConfig(
        id: 'knaben.org',
        name: 'Knaben',
        baseUrl: Uri.parse('https://api.knaben.org/v1'),
        format: BtSiteFormat.knaben,
        domains: const <BtSiteDomain>{BtSiteDomain.movie, BtSiteDomain.tv},
        enabled: resourceEnabled(BtSiteFormat.knaben),
      ),
    );
  }
  return sites;
}

/// 地址身份：同格式 + 同主机 + 同路径（忽略结尾 `/` 与大小写）算同一个站。
String _siteAddressKey(BtSiteConfig site) {
  String path = site.baseUrl.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return '${site.format.name}|${site.baseUrl.host.toLowerCase()}|'
      '${path.toLowerCase()}';
}

/// 把 [legacy] 并进 [current]（纯函数）：同 id 或同地址（见 [_siteAddressKey]）的
/// 已有站点保持原样、不重复添加——用户在 #2563 版本里自己加过 nyaa.si 的也不会多出
/// 一条。返回值保持 [current] 原序，新站点追加在后。
List<BtSiteConfig> mergeLegacyBtSites(
  Iterable<BtSiteConfig> current,
  Iterable<BtSiteConfig> legacy,
) {
  final List<BtSiteConfig> merged = current.toList();
  final Set<String> ids = <String>{
    for (final BtSiteConfig site in merged) site.id,
  };
  final Set<String> addresses = <String>{
    for (final BtSiteConfig site in merged) _siteAddressKey(site),
  };
  for (final BtSiteConfig site in legacy) {
    if (ids.contains(site.id) || addresses.contains(_siteAddressKey(site))) {
      continue;
    }
    merged.add(site);
    ids.add(site.id);
    addresses.add(_siteAddressKey(site));
  }
  return merged;
}

/// 本机是不是存过旧内置源的启停偏好（只有用户在旧版设置里动过开关才会落盘）。
bool hasLegacyBtSourcePrefs(PrefStore prefs) =>
    prefs.getPref(
          kLegacyVideoResourceDisabledSourcesPref,
          defaultValue: null,
        ) !=
        null ||
    prefs.getPref(kLegacyDiscoveryDisabledSourcesPref, defaultValue: null) !=
        null;

/// [runLegacyBuiltinBtSitesMigration] 的结果。
enum BtSitesLegacyMigrationOutcome {
  /// 标记已在：之前跑过，本次什么都不做。
  alreadyDone,

  /// 判成新装：只写标记，不迁（新装用户保持「没有内置站」）。
  freshInstall,

  /// 判成老用户：旧内置站点已并进用户 BT 站清单。
  migrated,

  /// 现有 BT 站清单解码失败：不覆盖、不写标记，下次启动再试。
  skippedUnreadableSites,
}

/// 启动时跑一次的迁移（幂等）。
///
/// [existingInstall]：调用方按各自最可靠的「升级前装过」信号判定（app：首页 /
/// 新手引导落过的标记；服务端：设备身份已存在），加上 [usage] 与
/// [hasLegacyBtSourcePrefs] 两类旧版特有的痕迹，任一即判老用户。
/// 必须在本次启动写下这些信号**之前**判定（app 在首页首帧前，服务端在
/// `ServerIdentity.loadOrCreate` 前）。
///
/// 站点先落盘、标记后落盘：两步之间崩溃时下次重跑，[mergeLegacyBtSites] 去重保证
/// 不会多出重复站点。
Future<BtSitesLegacyMigrationOutcome> runLegacyBuiltinBtSitesMigration(
  PrefStore prefs, {
  required bool existingInstall,
  required LegacyBtSourceUsage usage,
  required bool hostHadDiscoverySources,
  bool hostHadResourceSearch = true,
  void Function(Object error, StackTrace stack)? onDecodeError,
}) async {
  if (prefs.getPref(kBtSitesLegacyMigrationPref, defaultValue: null) != null) {
    return BtSitesLegacyMigrationOutcome.alreadyDone;
  }
  final bool oldUser =
      existingInstall ||
      usage.referencesLegacySources ||
      hasLegacyBtSourcePrefs(prefs);
  if (!oldUser) {
    await prefs.setPref(kBtSitesLegacyMigrationPref, _markerFresh);
    return BtSitesLegacyMigrationOutcome.freshInstall;
  }
  bool unreadable = false;
  final List<BtSiteConfig> current = readBtSiteConfigs(
    prefs,
    onDecodeError: (Object error, StackTrace stack) {
      unreadable = true;
      onDecodeError?.call(error, stack);
    },
  );
  if (unreadable) return BtSitesLegacyMigrationOutcome.skippedUnreadableSites;
  final List<BtSiteConfig> legacy = legacyBuiltinBtSites(
    disabledResourceSourceIds: _idSet(
      prefs.getPref(kLegacyVideoResourceDisabledSourcesPref, defaultValue: ''),
    ),
    disabledDiscoverySourceIds: hostHadDiscoverySources
        ? _idSet(
            prefs.getPref(
              kLegacyDiscoveryDisabledSourcesPref,
              defaultValue: kLegacyDiscoveryDisabledSourcesDefault,
            ),
          )
        : null,
    includeResourceSites: hostHadResourceSearch,
    formatsUsedByEnabledSubscriptions: usage.formatsUsedByEnabledSubscriptions,
  );
  final List<BtSiteConfig> merged = mergeLegacyBtSites(current, legacy);
  if (merged.length != current.length) {
    await writeBtSiteConfigs(prefs, merged);
  }
  await prefs.setPref(kBtSitesLegacyMigrationPref, _markerMigrated);
  return BtSitesLegacyMigrationOutcome.migrated;
}
