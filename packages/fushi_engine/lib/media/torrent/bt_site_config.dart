/// 用户自己添加的 BT 站（资源搜索与发现页的 torrent 来源）。
///
/// Fushi **不内置任何 BT 站地址**：没有用户站点（也没配 Torznab）时 BT 搜索就是
/// 没有来源。用户只填地址；站点是哪种接口（[BtSiteFormat]）由添加时的自动探测
/// （`bt_site_probe.dart`）决定并记进配置，界面上不展示格式。
///
/// 整份列表存进一个偏好键 [kResourceBtSitesPref] 的 JSON 数组，app 的
/// `PreferencesRepository` 与无头服务端的 `ServerPrefs` 都经这里读写（同一份编码）。
library;

import 'dart:convert';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart'
    show NyaaCategoryOption;
import 'package:fushi_engine/media/torrent/torznab_client.dart'
    show isSafeExternalProviderEndpoint;
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';

/// 用户 BT 站清单（JSON 数组，见 [BtSiteConfig.toJson]）。设备本地 + 按凭据处理
/// （地址可能带站点 passkey），归类与 `video_resource_torznab_config` 一致。
const String kResourceBtSitesPref = 'resource_bt_sites';

/// 站点接口格式（内部字段，不展示）。[name] 同时是 provider id 前缀与持久化的
/// 订阅 / 任务 provider id 前缀（`nyaa:<siteId>`），与旧内置源的 id（`nyaa` /
/// `apibay` / `knaben`）同名——存量订阅据此解析到同格式的用户站点。
enum BtSiteFormat {
  /// HTML 搜索页 + `table.torrent-list`（可排序 / 翻页 / 有做种数与分类）。
  nyaa,

  /// `GET /q.php` 回 JSON 数组。
  apibay,

  /// `POST` JSON 查询回 `{hits: [...]}`。
  knaben;

  static BtSiteFormat? fromWire(String? raw) {
    final String value = (raw ?? '').trim().toLowerCase();
    for (final BtSiteFormat format in values) {
      if (format.name == value) return format;
    }
    return null;
  }

  /// 这种接口本身能服务哪些域。JSON 两家的客户端只会按电影 / 剧集分类搜；
  /// Nyaa 式由站点分类下拉决定（见 [mapNyaaCategoriesToDomains]）。
  Set<BtSiteDomain> get supportedDomains => switch (this) {
    BtSiteFormat.nyaa => BtSiteDomain.values.toSet(),
    BtSiteFormat.apibay || BtSiteFormat.knaben => const <BtSiteDomain>{
      BtSiteDomain.movie,
      BtSiteDomain.tv,
    },
  };
}

/// 站点适用的媒体域：三个视频域（资源搜索 / 订阅）+ 四个发现域（发现页）。
enum BtSiteDomain {
  anime,
  movie,
  tv,
  novel,
  audiobook,
  manga,
  game;

  static BtSiteDomain? fromWire(String? raw) {
    for (final BtSiteDomain domain in values) {
      if (domain.name == raw) return domain;
    }
    return null;
  }

  /// 对应的视频资源域；发现域返回 null。
  VideoDiscoveryCategory? get videoCategory => switch (this) {
    BtSiteDomain.anime => VideoDiscoveryCategory.anime,
    BtSiteDomain.movie => VideoDiscoveryCategory.movie,
    BtSiteDomain.tv => VideoDiscoveryCategory.tv,
    _ => null,
  };

  /// 对应的发现页域；视频域返回 null。
  DiscoveryMediaKind? get discoveryKind => switch (this) {
    BtSiteDomain.novel => DiscoveryMediaKind.novel,
    BtSiteDomain.audiobook => DiscoveryMediaKind.audiobook,
    BtSiteDomain.manga => DiscoveryMediaKind.manga,
    BtSiteDomain.game => DiscoveryMediaKind.game,
    _ => null,
  };

  static BtSiteDomain fromVideoCategory(VideoDiscoveryCategory category) =>
      switch (category) {
        VideoDiscoveryCategory.anime => BtSiteDomain.anime,
        VideoDiscoveryCategory.movie => BtSiteDomain.movie,
        VideoDiscoveryCategory.tv => BtSiteDomain.tv,
      };
}

/// 一个用户 BT 站。
class BtSiteConfig {
  BtSiteConfig({
    required this.id,
    required this.baseUrl,
    required this.format,
    this.name = '',
    Set<BtSiteDomain> domains = const <BtSiteDomain>{},
    Map<BtSiteDomain, String> nyaaCategories = const <BtSiteDomain, String>{},
    this.enabled = true,
    this.allowInsecureHttp = false,
  }) : domains = Set<BtSiteDomain>.unmodifiable(domains),
       nyaaCategories = Map<BtSiteDomain, String>.unmodifiable(nyaaCategories) {
    if (!isValidBtSiteId(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'BT site id must be non-empty and '
            'must not contain ":" or ","',
      );
    }
    if (baseUrl.scheme != 'http' && baseUrl.scheme != 'https') {
      throw ArgumentError('BT site URL must use HTTP or HTTPS');
    }
    if (baseUrl.host.isEmpty || baseUrl.userInfo.isNotEmpty) {
      throw ArgumentError(
        'BT site URL must have a host and carry no user info',
      );
    }
    if (!isSafeExternalProviderEndpoint(
      baseUrl,
      allowInsecureHttp: allowInsecureHttp,
    )) {
      throw ArgumentError(
        'BT site URL must use HTTPS unless plain HTTP is explicitly allowed '
        'or the host is loopback',
      );
    }
  }

  /// 稳定身份：provider id 由它派生（`<format>:<id>`），订阅与下载任务按它持久化。
  final String id;

  /// 用户起的名字；空 = 用主机名。
  final String name;

  /// 探测时打通的接口根地址（Nyaa / apibay 式是 origin；Knaben 式含路径）。
  final Uri baseUrl;

  /// 自动探测出的接口格式（内部字段）。
  final BtSiteFormat format;

  /// 用户勾选的媒体域。
  final Set<BtSiteDomain> domains;

  /// Nyaa 式站点：媒体域 → 站点分类号（探测时从分类下拉映射，见
  /// [mapNyaaCategoriesToDomains]）。其它格式为空。
  final Map<BtSiteDomain, String> nyaaCategories;

  final bool enabled;

  /// 明文 HTTP 的显式放行（局域网自建站）。
  final bool allowInsecureHttp;

  /// 界面显示名：用户起的名字，否则主机名（地址可能带 passkey，从不显示整串）。
  String get displayName => name.trim().isNotEmpty ? name.trim() : baseUrl.host;

  /// 资源 provider id（`nyaa:<id>` / `apibay:<id>` / `knaben:<id>`）。
  String get providerId => '${format.name}:$id';

  /// 发现页源 id（同 [providerId]，发现源与资源 provider 各成一张注册表，不撞）。
  String get discoverySourceId => 'bt-$id';

  /// 实际生效的域：用户勾选 ∩ 格式能力 ∩（Nyaa 式）站点确有对应分类。
  Set<BtSiteDomain> get effectiveDomains => <BtSiteDomain>{
    for (final BtSiteDomain domain in domains)
      if (format.supportedDomains.contains(domain) &&
          (format != BtSiteFormat.nyaa || nyaaCategories.containsKey(domain)))
        domain,
  };

  /// 生效的视频域（资源搜索 / 订阅）。
  Set<VideoDiscoveryCategory> get effectiveVideoCategories =>
      <VideoDiscoveryCategory>{
        for (final BtSiteDomain domain in effectiveDomains)
          if (domain.videoCategory case final VideoDiscoveryCategory category)
            category,
      };

  /// 生效的发现页域（只有 Nyaa 式站点能进发现页）。
  Set<DiscoveryMediaKind> get effectiveDiscoveryKinds => <DiscoveryMediaKind>{
    for (final BtSiteDomain domain in effectiveDomains)
      if (domain.discoveryKind case final DiscoveryMediaKind kind) kind,
  };

  BtSiteConfig copyWith({
    String? name,
    Uri? baseUrl,
    BtSiteFormat? format,
    Set<BtSiteDomain>? domains,
    Map<BtSiteDomain, String>? nyaaCategories,
    bool? enabled,
    bool? allowInsecureHttp,
  }) => BtSiteConfig(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    format: format ?? this.format,
    domains: domains ?? this.domains,
    nyaaCategories: nyaaCategories ?? this.nyaaCategories,
    enabled: enabled ?? this.enabled,
    allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'url': baseUrl.toString(),
    'enabled': enabled,
    'domains': <String>[
      for (final BtSiteDomain domain in BtSiteDomain.values)
        if (domains.contains(domain)) domain.name,
    ],
    'format': format.name,
    if (nyaaCategories.isNotEmpty)
      'nyaaCategories': <String, String>{
        for (final BtSiteDomain domain in BtSiteDomain.values)
          if (nyaaCategories[domain] case final String value)
            domain.name: value,
      },
    'allowInsecureHttp': allowInsecureHttp,
  };

  /// 解析一条；畸形即抛（列表层逐条丢弃，见 [decodeBtSiteConfigs]）。
  factory BtSiteConfig.fromJson(Map<String, Object?> json) {
    final Object? rawId = json['id'];
    final Object? rawUrl = json['url'];
    final BtSiteFormat? format = BtSiteFormat.fromWire(
      json['format'] is String ? json['format'] as String : null,
    );
    final Uri? url = rawUrl is String ? Uri.tryParse(rawUrl.trim()) : null;
    if (rawId is! String || url == null || format == null) {
      throw const FormatException('BT site entry is missing id, url or format');
    }
    final Object? rawDomains = json['domains'];
    final Object? rawCategories = json['nyaaCategories'];
    return BtSiteConfig(
      id: rawId,
      name: json['name'] is String ? json['name'] as String : '',
      baseUrl: url,
      format: format,
      domains: <BtSiteDomain>{
        if (rawDomains is List)
          for (final Object? raw in rawDomains)
            if (BtSiteDomain.fromWire(raw is String ? raw : null)
                case final BtSiteDomain domain)
              domain,
      },
      nyaaCategories: <BtSiteDomain, String>{
        if (rawCategories is Map)
          for (final MapEntry<Object?, Object?> entry in rawCategories.entries)
            if (BtSiteDomain.fromWire('${entry.key}')
                case final BtSiteDomain domain
                when entry.value is String &&
                    _nyaaCategoryValue.hasMatch(entry.value! as String))
              domain: entry.value! as String,
      },
      enabled: json['enabled'] != false,
      allowInsecureHttp: json['allowInsecureHttp'] == true,
    );
  }
}

final RegExp _nyaaCategoryValue = RegExp(r'^\d+_\d+$');

/// 站点 id 形状：非空，不含 provider id 分隔符 `:` 与旧停用清单分隔符 `,`。
bool isValidBtSiteId(String id) =>
    id.trim().isNotEmpty &&
    id == id.trim() &&
    !id.contains(':') &&
    !id.contains(',');

/// 新站点 id（`bt<微秒 base36>`）。与旧内置源的实例名（`nyaa.si` / `default` /
/// `apibay.org` / `knaben.org`）结构上不可能相撞——那些要么带点、要么是 `default`。
String newBtSiteId({DateTime Function()? now}) =>
    'bt${(now ?? DateTime.now)().microsecondsSinceEpoch.toRadixString(36)}';

/// 解码清单；坏条目逐条丢弃（交给 [onEntryError]），一条坏配置不拖垮整张表。
List<BtSiteConfig> decodeBtSiteConfigs(
  Object? decoded, {
  void Function(Object error, StackTrace stack)? onEntryError,
}) {
  if (decoded is! List) return const <BtSiteConfig>[];
  final List<BtSiteConfig> sites = <BtSiteConfig>[];
  final Set<String> seen = <String>{};
  for (final Object? entry in decoded) {
    if (entry is! Map) continue;
    try {
      final BtSiteConfig site = BtSiteConfig.fromJson(
        Map<String, Object?>.from(entry),
      );
      if (seen.add(site.id)) sites.add(site);
    } on Object catch (error, stack) {
      onEntryError?.call(error, stack);
    }
  }
  return List<BtSiteConfig>.unmodifiable(sites);
}

String encodeBtSiteConfigs(Iterable<BtSiteConfig> sites) => jsonEncode(
  <Map<String, Object?>>[for (final BtSiteConfig site in sites) site.toJson()],
);

/// 读用户 BT 站清单（app 与服务端共用）。坏 JSON → 空表 + [onDecodeError]。
List<BtSiteConfig> readBtSiteConfigs(
  PrefStore prefs, {
  void Function(Object error, StackTrace stack)? onDecodeError,
}) {
  final String raw =
      (prefs.getPref(kResourceBtSitesPref, defaultValue: '') ?? '').toString();
  if (raw.trim().isEmpty) return const <BtSiteConfig>[];
  try {
    return decodeBtSiteConfigs(jsonDecode(raw), onEntryError: onDecodeError);
  } on Object catch (error, stack) {
    onDecodeError?.call(error, stack);
    return const <BtSiteConfig>[];
  }
}

Future<void> writeBtSiteConfigs(
  PrefStore prefs,
  Iterable<BtSiteConfig> sites,
) => prefs.setPref(kResourceBtSitesPref, encodeBtSiteConfigs(sites));

/// 有没有至少一个启用、且对某个视频域生效的站点（资源搜索面是否有 BT 站来源）。
bool btSitesHaveVideoSource(Iterable<BtSiteConfig> sites) => sites.any(
  (BtSiteConfig site) =>
      site.enabled && site.effectiveVideoCategories.isNotEmpty,
);

/// 各域在 Nyaa 式站点分类下拉里的候选分类名（按序取第一个存在的；比较时忽略
/// 大小写与多余空白）。nyaa 主站是 `Anime` / `Literature` / `Audio` /
/// `Live Action` / `Software - Games`；成人分站是 `Art - Anime` / `Art - Manga` /
/// `Art - Games`；镜像沿用其中一套。
const Map<BtSiteDomain, List<String>> kNyaaDomainCategoryLabels =
    <BtSiteDomain, List<String>>{
      BtSiteDomain.anime: <String>['Anime', 'Art - Anime'],
      BtSiteDomain.movie: <String>['Live Action'],
      BtSiteDomain.tv: <String>['Live Action'],
      BtSiteDomain.novel: <String>['Literature'],
      BtSiteDomain.manga: <String>['Art - Manga', 'Literature'],
      BtSiteDomain.audiobook: <String>['Audio'],
      BtSiteDomain.game: <String>['Software - Games', 'Art - Games', 'Games'],
    };

/// 按分类名把媒体域映射到站点分类号。
///
/// 每个域按 [kNyaaDomainCategoryLabels] 的顺序找：先找完整名精确相同的选项；都
/// 没有再找「以该名为父类」的第一个子类（站点没有大类、只有 `Audio - Lossless`
/// 这类子类时用它）。找不到的域不进结果——该站对这个域不生效。
///
/// [options] 为空（页面没有分类下拉）时返回空表：分类未知，不替用户猜。
Map<BtSiteDomain, String> mapNyaaCategoriesToDomains(
  Iterable<NyaaCategoryOption> options,
) {
  String fold(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  final List<NyaaCategoryOption> all = options.toList(growable: false);
  final Map<BtSiteDomain, String> mapping = <BtSiteDomain, String>{};
  for (final MapEntry<BtSiteDomain, List<String>> entry
      in kNyaaDomainCategoryLabels.entries) {
    String? value;
    for (final String label in entry.value) {
      final String wanted = fold(label);
      value = all
          .where((NyaaCategoryOption o) => fold(o.label) == wanted)
          .map((NyaaCategoryOption o) => o.value)
          .firstOrNull;
      if (value != null) break;
    }
    if (value == null) {
      for (final String label in entry.value) {
        final String prefix = '${fold(label)} - ';
        value = all
            .where((NyaaCategoryOption o) => fold(o.label).startsWith(prefix))
            .map((NyaaCategoryOption o) => o.value)
            .firstOrNull;
        if (value != null) break;
      }
    }
    if (value != null) mapping[entry.key] = value;
  }
  return mapping;
}
