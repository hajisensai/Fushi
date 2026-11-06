/// WebUI「资源索引器」卡片的读写面：用户 BT 站 + 自配 Torznab indexer 清单。
///
/// 存储与 app 完全同一份：`preferences` 表的 `resource_bt_sites`（JSON 数组，编解码走引擎
/// `BtSiteConfig`）与 `video_resource_torznab_config`（JSON 数组，编解码走引擎
/// `TorznabIndexerConfig`），所以服务端改的配置 app 读得懂、反之亦然。Fushi 不内置任何
/// BT 站；旧的内置源停用清单键已冻结，这里不读也不写。
///
/// 规则：
/// - API key 永不回显（只报 `apiKeySet`）；提交时留空 = 沿用同 id 旧值，
///   `clearApiKey: true` 才清空；endpoint 里带 `?apikey=` 会被拆进 key 栏（与 app 同一 codec）。
/// - BT 站只回显主机名与用户起的名字：地址可能带站点 passkey，整串永不出境；站点接口格式
///   是探测得来的内部字段，也不出境。
/// - 整个请求先全部校验、构造成功再落库：任何一条非法 → [FormatException]（admin API 回 400），
///   一个字节都不写。
library;

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';
import 'package:fushi_engine/media/video/download/video_resource_prefs.dart';

/// GET 的 JSON 形状（不含运行态栏 `providers` / `applied` / BT 站的 `active`，
/// 那些由调用方按运行中的 registry 补）。
Map<String, Object?> resourceIndexerSettingsToJson(
  PrefStore prefs, {
  Set<String>? activeBtSiteIds,
}) {
  return <String, Object?>{
    'btSites': <Object?>[
      for (final BtSiteConfig site in readBtSiteConfigs(prefs))
        btSiteToJson(site, active: activeBtSiteIds?.contains(site.id)),
    ],
    'torznab': <Object?>[
      for (final TorznabIndexerConfig c in readTorznabIndexerConfigs(prefs))
        <String, Object?>{
          ...c.toJson(includeSecrets: false),
          'apiKeySet': c.apiKey.isNotEmpty,
        },
    ],
  };
}

/// 一个 BT 站的对外形状：不含地址整串（只有主机名）与接口格式。
/// `effectiveDomains` = 实际生效的域（站点没有对应分类 / 接口不支持的域会被去掉），
/// 界面据此提示「这个站点对某域不生效」。`active`：当前是否在运行中的搜索面里（未知为 null）。
Map<String, Object?> btSiteToJson(BtSiteConfig site, {bool? active}) =>
    <String, Object?>{
      'id': site.id,
      'name': site.name,
      'host': site.baseUrl.host,
      'displayName': site.displayName,
      'domains': <String>[
        for (final BtSiteDomain d in BtSiteDomain.values)
          if (site.domains.contains(d)) d.name,
      ],
      'effectiveDomains': <String>[
        for (final BtSiteDomain d in BtSiteDomain.values)
          if (site.effectiveDomains.contains(d)) d.name,
      ],
      'enabled': site.enabled,
      'allowInsecureHttp': site.allowInsecureHttp,
      'active': active,
    };

/// 解析 `domains` 字段：媒体域名数组（`anime` / `movie` / `tv` / `novel` / `audiobook` /
/// `manga` / `game`），至少一个。
Set<BtSiteDomain> parseBtSiteDomains(Object? raw) {
  if (raw is! List) {
    throw const FormatException('domains must be an array of media domains');
  }
  final Set<BtSiteDomain> out = <BtSiteDomain>{};
  for (final Object? item in raw) {
    final BtSiteDomain? domain = BtSiteDomain.fromWire(
      item is String ? item : null,
    );
    if (domain == null) {
      throw FormatException(
        'unknown media domain "$item"; known: ${BtSiteDomain.values.map((BtSiteDomain d) => d.name).join(', ')}',
      );
    }
    out.add(domain);
  }
  if (out.isEmpty) {
    throw const FormatException('select at least one media domain');
  }
  return out;
}

/// 一次校验好的待写入内容；null 字段 = 请求没带、不改。
class ResourceIndexerUpdate {
  const ResourceIndexerUpdate({this.torznab});

  final List<TorznabIndexerConfig>? torznab;

  bool get isEmpty => torznab == null;
}

/// 解析 + 校验 PUT body（不落库）。body 形状：
/// `{"torznab": [{id?, name, endpoint, apiKey?, clearApiKey?, enabled?, priority?,
/// allowInsecureHttp?, categories?}, ...]}`，键可省。BT 站走单独的
/// `/api/admin/resource-indexers/bt-sites` 路由（要联网探测，不进整表替换）。
ResourceIndexerUpdate parseResourceIndexerUpdate(
  PrefStore prefs,
  Map<String, dynamic> body, {
  DateTime Function()? now,
}) {
  // 旧版的内置源开关：已经没有内置源了，明说而不是静默忽略（否则调用方以为改成了）。
  if (body.containsKey('builtin')) {
    throw const FormatException(
      '"builtin" is no longer supported; manage BT sites via /api/admin/resource-indexers/bt-sites',
    );
  }
  List<TorznabIndexerConfig>? torznab;
  final Object? rawList = body['torznab'];
  if (rawList != null) {
    if (rawList is! List) {
      throw const FormatException('torznab must be an array');
    }
    final Map<String, TorznabIndexerConfig> existing =
        <String, TorznabIndexerConfig>{
          for (final TorznabIndexerConfig c in readTorznabIndexerConfigs(prefs))
            c.id: c,
        };
    final int stamp = (now ?? DateTime.now)().microsecondsSinceEpoch;
    final Set<String> seen = <String>{};
    torznab = <TorznabIndexerConfig>[];
    for (int i = 0; i < rawList.length; i++) {
      final Object? raw = rawList[i];
      if (raw is! Map) throw FormatException('torznab[$i] must be an object');
      final TorznabIndexerConfig config = _parseIndexer(
        Map<String, dynamic>.from(raw),
        i,
        existing,
        '$stamp-$i',
      );
      if (!seen.add(config.id)) {
        throw FormatException('torznab[$i]: duplicate id "${config.id}"');
      }
      torznab.add(config);
    }
  }
  return ResourceIndexerUpdate(torznab: torznab);
}

TorznabIndexerConfig _parseIndexer(
  Map<String, dynamic> m,
  int i,
  Map<String, TorznabIndexerConfig> existing,
  String idSuffix,
) {
  String where(String field) => 'torznab[$i].$field';
  final Object? rawId = m['id'];
  if (rawId != null && rawId is! String) {
    throw FormatException('${where('id')} must be a string');
  }
  final String givenId = (rawId as String? ?? '').trim();
  // 新行的 id 与 app 设置页同形（`torznab-<微秒>`）；客户端发来的订阅 provider 是 `torznab:<id>`。
  final String id = givenId.isEmpty ? 'torznab-$idSuffix' : givenId;
  if (id.contains(':') || id.contains(',')) {
    throw FormatException('${where('id')} must not contain ":" or ","');
  }
  final String name = (m['name'] is String ? m['name'] as String : '').trim();
  if (name.isEmpty) throw FormatException('${where('name')} is required');
  final Object? endpointRaw = m['endpoint'];
  if (endpointRaw is! String || endpointRaw.trim().isEmpty) {
    throw FormatException('${where('endpoint')} is required');
  }
  final Object? apiKeyRaw = m['apiKey'];
  if (apiKeyRaw != null && apiKeyRaw is! String) {
    throw FormatException('${where('apiKey')} must be a string');
  }
  final bool clearApiKey = m['clearApiKey'] == true;
  final bool enabled = _bool(m, 'enabled', where, fallback: true);
  final bool allowInsecureHttp = _bool(
    m,
    'allowInsecureHttp',
    where,
    fallback: false,
  );
  final Object? priorityRaw = m['priority'];
  final int priority;
  if (priorityRaw == null) {
    priority = 100;
  } else if (priorityRaw is int) {
    priority = priorityRaw;
  } else if (priorityRaw is double &&
      priorityRaw == priorityRaw.truncateToDouble()) {
    priority = priorityRaw.toInt();
  } else {
    throw FormatException('${where('priority')} must be an integer');
  }
  final List<int> categories = _categories(
    m['categories'],
    where('categories'),
  );

  final TorznabEndpointParts parts;
  try {
    parts = splitTorznabEndpointCredentials(
      endpointRaw,
      apiKey: apiKeyRaw as String?,
    );
  } on FormatException catch (e) {
    throw FormatException('${where('endpoint')}: ${e.message}');
  }
  // 留空 = 沿用同 id 的旧 key（表单不回显）；显式 clearApiKey 才清空。
  final String apiKey = parts.apiKey.isNotEmpty
      ? parts.apiKey
      : (clearApiKey ? '' : existing[id]?.apiKey ?? '');
  try {
    return TorznabIndexerConfig(
      id: id,
      name: name,
      endpoint: parts.endpoint,
      apiKey: apiKey,
      enabled: enabled,
      priority: priority,
      allowInsecureHttp: allowInsecureHttp,
      categories: categories,
    );
  } on ArgumentError catch (e) {
    throw FormatException('${where('endpoint')}: ${e.message}');
  }
}

bool _bool(
  Map<String, dynamic> m,
  String key,
  String Function(String) where, {
  required bool fallback,
}) {
  final Object? v = m[key];
  if (v == null) return fallback;
  if (v is! bool) throw FormatException('${where(key)} must be a boolean');
  return v;
}

/// 与 app 设置页同口径：非负整数；接受数组或逗号串（表单直接交文本框内容）。
List<int> _categories(Object? raw, String where) {
  if (raw == null) return const <int>[];
  final Iterable<Object?> items;
  if (raw is String) {
    items = raw
        .split(',')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty);
  } else if (raw is List) {
    items = raw;
  } else {
    throw FormatException('$where must be an array of non-negative integers');
  }
  final List<int> out = <int>[];
  for (final Object? item in items) {
    final int? value = item is int
        ? item
        : (item is String ? int.tryParse(item) : null);
    if (value == null || value < 0) {
      throw FormatException('$where: "$item" is not a non-negative integer');
    }
    out.add(value);
  }
  return out;
}

/// 落库（调用方先 [parseResourceIndexerUpdate] 成功才走到这里）。
Future<void> writeResourceIndexerUpdate(
  PrefStore prefs,
  ResourceIndexerUpdate update,
) async {
  final List<TorznabIndexerConfig>? torznab = update.torznab;
  if (torznab != null) await writeTorznabIndexerConfigs(prefs, torznab);
}
