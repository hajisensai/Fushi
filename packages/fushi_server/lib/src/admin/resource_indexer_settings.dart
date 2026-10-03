/// WebUI「资源索引器」卡片的读写面：内置源启停 + 自配 Torznab indexer 清单。
///
/// 存储与 app 完全同一份：`preferences` 表的 `video_resource_torznab_config`（JSON 数组，
/// 编解码走引擎 `TorznabIndexerConfig`）与 `video_resource_disabled_sources`（排序逗号串），
/// 读写都经 `video_resource_prefs.dart`，所以服务端改的配置 app 读得懂、反之亦然。
///
/// 规则：
/// - API key 永不回显（只报 `apiKeySet`）；提交时留空 = 沿用同 id 旧值，
///   `clearApiKey: true` 才清空；endpoint 里带 `?apikey=` 会被拆进 key 栏（与 app 同一 codec）。
/// - 整个请求先全部校验、构造成功再落库：任何一条非法 → [FormatException]（admin API 回 400），
///   一个字节都不写。
/// - 停用清单里不认识的 id（比如新版 app 同步来的新内置源）原样保留，不因服务端表旧而丢。
library;

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/torrent/builtin_video_resource_providers.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';
import 'package:fushi_engine/media/video/download/video_resource_prefs.dart';

/// GET 的 JSON 形状（不含 `providers` 能力位，那一栏由调用方按运行中的 registry 补）。
Map<String, Object?> resourceIndexerSettingsToJson(PrefStore prefs) {
  final Set<String> disabled = readVideoResourceDisabledSourceIds(prefs);
  return <String, Object?>{
    'builtin': <Object?>[
      for (final BuiltinVideoResourceProviderSpec spec in kBuiltinVideoResourceProviderSpecs)
        <String, Object?>{'id': spec.id, 'name': spec.displayName, 'enabled': !disabled.contains(spec.id)},
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

/// 一次校验好的待写入内容；null 字段 = 请求没带、不改。
class ResourceIndexerUpdate {
  const ResourceIndexerUpdate({this.disabledSourceIds, this.torznab});

  final Set<String>? disabledSourceIds;
  final List<TorznabIndexerConfig>? torznab;

  bool get isEmpty => disabledSourceIds == null && torznab == null;
}

/// 解析 + 校验 PUT body（不落库）。body 形状：
/// `{"builtin": {"<id>": bool, ...}, "torznab": [{id?, name, endpoint, apiKey?, clearApiKey?,
/// enabled?, priority?, allowInsecureHttp?, categories?}, ...]}`，两键都可省。
ResourceIndexerUpdate parseResourceIndexerUpdate(PrefStore prefs, Map<String, dynamic> body, {DateTime Function()? now}) {
  Set<String>? disabled;
  final Object? builtin = body['builtin'];
  if (builtin != null) {
    if (builtin is! Map) throw const FormatException('builtin must be an object of {id: enabled}');
    final Set<String> known = <String>{for (final BuiltinVideoResourceProviderSpec s in kBuiltinVideoResourceProviderSpecs) s.id};
    disabled = <String>{...readVideoResourceDisabledSourceIds(prefs)};
    for (final MapEntry<Object?, Object?> e in builtin.entries) {
      final String id = '${e.key}';
      if (!known.contains(id)) throw FormatException('unknown builtin resource source "$id"; known: ${known.join(', ')}');
      if (e.value is! bool) throw FormatException('builtin.$id must be a boolean');
      if (e.value! as bool) {
        disabled.remove(id);
      } else {
        disabled.add(id);
      }
    }
  }

  List<TorznabIndexerConfig>? torznab;
  final Object? rawList = body['torznab'];
  if (rawList != null) {
    if (rawList is! List) throw const FormatException('torznab must be an array');
    final Map<String, TorznabIndexerConfig> existing = <String, TorznabIndexerConfig>{
      for (final TorznabIndexerConfig c in readTorznabIndexerConfigs(prefs)) c.id: c,
    };
    final int stamp = (now ?? DateTime.now)().microsecondsSinceEpoch;
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
  return ResourceIndexerUpdate(disabledSourceIds: disabled, torznab: torznab);
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
  final Object? priorityRaw = m['priority'];
  final int priority;
  if (priorityRaw == null) {
    priority = 100;
  } else if (priorityRaw is int) {
    priority = priorityRaw;
  } else if (priorityRaw is double && priorityRaw == priorityRaw.truncateToDouble()) {
    priority = priorityRaw.toInt();
  } else {
    throw FormatException('${where('priority')} must be an integer');
  }
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
  final List<TorznabIndexerConfig>? torznab = update.torznab;
  if (torznab != null) await writeTorznabIndexerConfigs(prefs, torznab);
  final Set<String>? disabled = update.disabledSourceIds;
  if (disabled != null) await writeVideoResourceDisabledSourceIds(prefs, disabled);
}
