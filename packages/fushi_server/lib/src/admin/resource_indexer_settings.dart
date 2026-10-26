/// WebUI「资源索引器」卡片的读写面：用户自配的 RSS 搜索站清单 + Torznab indexer 清单。
///
/// 仓库不内置任何 BT 搜索站（旧的内置源与其停用清单已移除），也不给预设或模板：
/// 用户要搜什么站就自己加它的 RSS 地址模板（形如 `https://example.com/rss?q={query}`）。
///
/// 存储与 app 完全同一份：`preferences` 表的 `resource_rss_sites`（JSON 数组，编解码走引擎
/// `RssSearchSiteConfig`）与 `video_resource_torznab_config`（JSON 数组，走 `TorznabIndexerConfig`），
/// 读写都经 `video_resource_prefs.dart`，所以服务端改的配置 app 读得懂、反之亦然。
///
/// 规则：
/// - API key 永不回显（只报 `apiKeySet`）；提交时留空 = 沿用同 id 旧值，
///   `clearApiKey: true` 才清空；endpoint 里带 `?apikey=` 会被拆进 key 栏（与 app 同一 codec）。
/// - RSS 站的 `urlTemplate` 必须含 `{query}`（可选 `{page}`），校验与 app 同一处
///   （`validateRssSearchUrlTemplate`）。
/// - 整个请求先全部校验、构造成功再落库：任何一条非法 → [FormatException]（admin API 回 400），
///   一个字节都不写。
library;

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';
import 'package:fushi_engine/media/video/download/video_resource_prefs.dart';

/// GET 的 JSON 形状（不含 `providers` 能力位，那一栏由调用方按运行中的 registry 补）。
Map<String, Object?> resourceIndexerSettingsToJson(PrefStore prefs) => <String, Object?>{
      'rss': <Object?>[for (final RssSearchSiteConfig c in readRssSearchSiteConfigs(prefs)) c.toJson()],
      'rssDomains': <String>[for (final RssSearchDomain d in RssSearchDomain.values) d.name],
      'torznab': <Object?>[
        for (final TorznabIndexerConfig c in readTorznabIndexerConfigs(prefs))
          <String, Object?>{
            ...c.toJson(includeSecrets: false),
            'apiKeySet': c.apiKey.isNotEmpty,
          },
      ],
    };

/// 一次校验好的待写入内容；null 字段 = 请求没带、不改。
class ResourceIndexerUpdate {
  const ResourceIndexerUpdate({this.rss, this.torznab});

  final List<RssSearchSiteConfig>? rss;
  final List<TorznabIndexerConfig>? torznab;

  bool get isEmpty => rss == null && torznab == null;
}

/// 解析 + 校验 PUT body（不落库）。body 形状：
/// `{"rss": [{id?, name, urlTemplate, enabled?, priority?, domains?, allowInsecureHttp?}, ...],
/// "torznab": [{id?, name, endpoint, apiKey?, clearApiKey?, enabled?, priority?, allowInsecureHttp?,
/// categories?}, ...]}`，两键都可省、都是整表替换。旧版 WebUI 发来的 `builtin` 键按 400 拒
/// （内置源已移除，静默忽略会让用户以为开关还有效）。
ResourceIndexerUpdate parseResourceIndexerUpdate(PrefStore prefs, Map<String, dynamic> body, {DateTime Function()? now}) {
  if (body.containsKey('builtin')) {
    throw const FormatException('builtin resource sources were removed; add RSS search sites under "rss" instead');
  }
  final int stamp = (now ?? DateTime.now)().microsecondsSinceEpoch;

  List<RssSearchSiteConfig>? rss;
  final Object? rawRss = body['rss'];
  if (rawRss != null) {
    if (rawRss is! List) throw const FormatException('rss must be an array');
    final Set<String> seen = <String>{};
    rss = <RssSearchSiteConfig>[];
    for (int i = 0; i < rawRss.length; i++) {
      final Object? raw = rawRss[i];
      if (raw is! Map) throw FormatException('rss[$i] must be an object');
      final RssSearchSiteConfig config = _parseRssSite(Map<String, dynamic>.from(raw), i, '$stamp-$i');
      if (!seen.add(config.id)) throw FormatException('rss[$i]: duplicate id "${config.id}"');
      rss.add(config);
    }
  }

  List<TorznabIndexerConfig>? torznab;
  final Object? rawList = body['torznab'];
  if (rawList != null) {
    if (rawList is! List) throw const FormatException('torznab must be an array');
    final Map<String, TorznabIndexerConfig> existing = <String, TorznabIndexerConfig>{
      for (final TorznabIndexerConfig c in readTorznabIndexerConfigs(prefs)) c.id: c,
    };
    final Set<String> seen = <String>{};
    torznab = <TorznabIndexerConfig>[];
    for (int i = 0; i < rawList.length; i++) {
      final Object? raw = rawList[i];
      if (raw is! Map) throw FormatException('torznab[$i] must be an object');
      final TorznabIndexerConfig config = _parseIndexer(Map<String, dynamic>.from(raw), i, existing, '$stamp-$i');
      if (!seen.add(config.id)) throw FormatException('torznab[$i]: duplicate id "${config.id}"');
      torznab.add(config);
    }
  }
  return ResourceIndexerUpdate(rss: rss, torznab: torznab);
}

RssSearchSiteConfig _parseRssSite(Map<String, dynamic> m, int i, String idSuffix) {
  String where(String field) => 'rss[$i].$field';
  final Object? rawId = m['id'];
  if (rawId != null && rawId is! String) throw FormatException('${where('id')} must be a string');
  final String givenId = (rawId as String? ?? '').trim();
  // 新行的 id 与 app 设置页同形（`rss-<微秒>`）；客户端发来的订阅 provider 是 `rss:<id>`。
  final String id = givenId.isEmpty ? 'rss-$idSuffix' : givenId;
  if (id.contains(':') || id.contains(',')) throw FormatException('${where('id')} must not contain ":" or ","');
  final String name = (m['name'] is String ? m['name'] as String : '').trim();
  if (name.isEmpty) throw FormatException('${where('name')} is required');
  final Object? templateRaw = m['urlTemplate'];
  if (templateRaw is! String || templateRaw.trim().isEmpty) throw FormatException('${where('urlTemplate')} is required');
  final bool enabled = _bool(m, 'enabled', where, fallback: true);
  final bool allowInsecureHttp = _bool(m, 'allowInsecureHttp', where, fallback: false);
  final int priority = _priority(m['priority'], where('priority'));
  final String? problem = validateRssSearchUrlTemplate(templateRaw, allowInsecureHttp: allowInsecureHttp);
  if (problem != null) throw FormatException('${where('urlTemplate')}: $problem');
  return RssSearchSiteConfig(
    id: id,
    name: name,
    urlTemplate: templateRaw,
    enabled: enabled,
    priority: priority,
    domains: _domains(m['domains'], where('domains')),
    allowInsecureHttp: allowInsecureHttp,
  );
}

/// 与 app 设置页同口径：域名数组，或逗号串（表单直接交文本框内容）；不认识的域按 400 拒。
List<RssSearchDomain> _domains(Object? raw, String where) {
  if (raw == null) return const <RssSearchDomain>[];
  final Iterable<Object?> items;
  if (raw is String) {
    items = raw.split(',').map((String s) => s.trim()).where((String s) => s.isNotEmpty);
  } else if (raw is List) {
    items = raw;
  } else {
    throw FormatException('$where must be an array of domain names');
  }
  final List<RssSearchDomain> out = <RssSearchDomain>[];
  for (final Object? item in items) {
    final RssSearchDomain? domain = item is String ? RssSearchDomain.tryParse(item.trim()) : null;
    if (domain == null) {
      throw FormatException('$where: unknown domain "$item"; known: ${RssSearchDomain.values.map((RssSearchDomain d) => d.name).join(', ')}');
    }
    out.add(domain);
  }
  return out;
}

int _priority(Object? raw, String where) {
  if (raw == null) return 100;
  if (raw is int) return raw;
  if (raw is double && raw == raw.truncateToDouble()) return raw.toInt();
  throw FormatException('$where must be an integer');
}

TorznabIndexerConfig _parseIndexer(Map<String, dynamic> m, int i, Map<String, TorznabIndexerConfig> existing, String idSuffix) {
  String where(String field) => 'torznab[$i].$field';
  final Object? rawId = m['id'];
  if (rawId != null && rawId is! String) throw FormatException('${where('id')} must be a string');
  final String givenId = (rawId as String? ?? '').trim();
  // 新行的 id 与 app 设置页同形（`torznab-<微秒>`）；客户端发来的订阅 provider 是 `torznab:<id>`。
  final String id = givenId.isEmpty ? 'torznab-$idSuffix' : givenId;
  if (id.contains(':') || id.contains(',')) throw FormatException('${where('id')} must not contain ":" or ","');
  final String name = (m['name'] is String ? m['name'] as String : '').trim();
  if (name.isEmpty) throw FormatException('${where('name')} is required');
  final Object? endpointRaw = m['endpoint'];
  if (endpointRaw is! String || endpointRaw.trim().isEmpty) throw FormatException('${where('endpoint')} is required');
  final Object? apiKeyRaw = m['apiKey'];
  if (apiKeyRaw != null && apiKeyRaw is! String) throw FormatException('${where('apiKey')} must be a string');
  final bool clearApiKey = m['clearApiKey'] == true;
  final bool enabled = _bool(m, 'enabled', where, fallback: true);
  final bool allowInsecureHttp = _bool(m, 'allowInsecureHttp', where, fallback: false);
  final int priority = _priority(m['priority'], where('priority'));
  final List<int> categories = _categories(m['categories'], where('categories'));

  final TorznabEndpointParts parts;
  try {
    parts = splitTorznabEndpointCredentials(endpointRaw, apiKey: apiKeyRaw as String?);
  } on FormatException catch (e) {
    throw FormatException('${where('endpoint')}: ${e.message}');
  }
  // 留空 = 沿用同 id 的旧 key（表单不回显）；显式 clearApiKey 才清空。
  final String apiKey = parts.apiKey.isNotEmpty ? parts.apiKey : (clearApiKey ? '' : existing[id]?.apiKey ?? '');
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

bool _bool(Map<String, dynamic> m, String key, String Function(String) where, {required bool fallback}) {
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
    items = raw.split(',').map((String s) => s.trim()).where((String s) => s.isNotEmpty);
  } else if (raw is List) {
    items = raw;
  } else {
    throw FormatException('$where must be an array of non-negative integers');
  }
  final List<int> out = <int>[];
  for (final Object? item in items) {
    final int? value = item is int ? item : (item is String ? int.tryParse(item) : null);
    if (value == null || value < 0) throw FormatException('$where: "$item" is not a non-negative integer');
    out.add(value);
  }
  return out;
}

/// 落库（调用方先 [parseResourceIndexerUpdate] 成功才走到这里）。
Future<void> writeResourceIndexerUpdate(PrefStore prefs, ResourceIndexerUpdate update) async {
  final List<RssSearchSiteConfig>? rss = update.rss;
  if (rss != null) await writeRssSearchSiteConfigs(prefs, rss);
  final List<TorznabIndexerConfig>? torznab = update.torznab;
  if (torznab != null) await writeTorznabIndexerConfigs(prefs, torznab);
}
