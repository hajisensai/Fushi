/// Wikidata **人物 id 桥**（作品图谱 L5，spec `docs/specs/2026-10-24-cross-media-links.md`
/// §5；与 `wikidata_anime_bridge.dart` 同一授权口径：只作 id 桥接，不取姓名、简介、
/// 图片等元数据）。给定若干人物外部 id，找出它们所在的 Wikidata 人物条目，读出同一
/// 条目上的其它外部 id——视频侧只有 AniDB / MAL / TMDB、音乐侧只有 MusicBrainz 时，
/// 靠它把同一位声优连起来。
///
/// 属性编号 2026-10-24 经 `wbgetentities` 实测核对（不是凭记忆写的；样本 Q1155136
/// 笠原弘子：P434 = MBID、P3180 = `s566`、P4985 = 554512、P4084 = 690）：
/// - P5649 = AniDB person ID；
/// - P4084 = MyAnimeList people ID；
/// - P4985 = TMDB person ID；
/// - P434 = MusicBrainz artist ID；
/// - P3180 = Visual Novel Database ID（人物值形如 `s566`；同一属性也装 VN / 角色
///   id，解析时只收 `s` 前缀）。
///
/// 纪律：全局串行 + 最小请求间隔；规范 UA；所有 id 先过 [normalizePersonExternalId]
/// 再拼进 SPARQL，杜绝注入。结果由调用方持久化（`person_identity_bridges`），
/// 本类不做内存缓存。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/people/person_identity.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';

/// scheme → Wikidata 属性（不含 wikidata 本身，它是条目 QID）。
const Map<String, String> kWikidataPersonIdProperties = <String, String>{
  PersonIdScheme.anidb: 'P5649',
  PersonIdScheme.mal: 'P4084',
  PersonIdScheme.tmdb: 'P4985',
  PersonIdScheme.musicbrainz: 'P434',
  PersonIdScheme.vndb: 'P3180',
};

/// 一次 SPARQL 最多带几个 id。
const int kWikidataPersonBatchSize = 40;

class WikidataPersonBridgeException implements Exception {
  const WikidataPersonBridgeException(this.message);

  final String message;

  @override
  String toString() => 'WikidataPersonBridgeException: $message';
}

/// 「这些 id → 所在人物条目的全部 id」的 SPARQL（纯函数）。不合法 / 不支持的节点
/// 被丢弃；全都不合法时返回 null。
String? buildWikidataPersonQuery(Iterable<String> idNodes) {
  final Map<String, Set<String>> byScheme = <String, Set<String>>{};
  for (final String node in idNodes) {
    final ({String kind, String head, String value})? p = parsePersonNode(node);
    if (p == null || p.kind != 'id') continue;
    final String? v = normalizePersonExternalId(p.head, p.value);
    if (v == null) continue;
    byScheme.putIfAbsent(p.head, () => <String>{}).add(v);
  }
  if (byScheme.isEmpty) return null;
  final List<String> branches = <String>[];
  for (final MapEntry<String, Set<String>> e in byScheme.entries) {
    final List<String> values = e.value.toList()..sort();
    if (e.key == PersonIdScheme.wikidata) {
      branches.add(
        '{ VALUES ?item { ${values.map((String q) => 'wd:$q').join(' ')} } }',
      );
      continue;
    }
    final String? prop = kWikidataPersonIdProperties[e.key];
    if (prop == null) continue;
    branches.add(
      '{ VALUES ?k { ${values.map((String v) => '"$v"').join(' ')} } '
      '?item wdt:$prop ?k . }',
    );
  }
  if (branches.isEmpty) return null;
  final StringBuffer optional = StringBuffer();
  kWikidataPersonIdProperties.forEach((String scheme, String prop) {
    optional.write('OPTIONAL { ?item wdt:$prop ?$scheme . } ');
  });
  return 'SELECT ?item ${kWikidataPersonIdProperties.keys.map((String s) => '?$s').join(' ')} '
      'WHERE { ${branches.join(' UNION ')} $optional}';
}

/// 解析 SPARQL JSON → Wikidata 条目节点 → 该条目上全部外部 id 节点（含条目自身）。
Map<String, Set<String>> parseWikidataPersonBindings(Object? json) {
  if (json is! Map) {
    throw const WikidataPersonBridgeException('not a JSON object');
  }
  final Object? results = json['results'];
  final Object? bindings = results is Map ? results['bindings'] : null;
  if (bindings is! List) {
    throw const WikidataPersonBridgeException('no bindings');
  }
  final Map<String, Set<String>> out = <String, Set<String>>{};
  for (final Object? b in bindings) {
    if (b is! Map) continue;
    final Object? item = b['item'];
    final Object? uri = item is Map ? item['value'] : null;
    if (uri is! String) continue;
    final String q = uri.substring(uri.lastIndexOf('/') + 1);
    final String? itemNode = personIdNode(PersonIdScheme.wikidata, q);
    if (itemNode == null) continue;
    final Set<String> ids = out.putIfAbsent(itemNode, () => <String>{itemNode});
    for (final String scheme in kWikidataPersonIdProperties.keys) {
      final Object? cell = b[scheme];
      final Object? value = cell is Map ? cell['value'] : null;
      if (value is! String) continue;
      if (personIdNode(scheme, value) case final String n) ids.add(n);
    }
  }
  return out;
}

/// 把条目 → id 集合翻成「查询过的每个节点 → 与它等价的其它节点」（不含自身）。
/// 查无条目的节点映射到空集——调用方据此落「查过」标记。
Map<String, Set<String>> wikidataPersonEquivalents(
  Iterable<String> queried,
  Map<String, Set<String>> items,
) {
  final Map<String, Set<String>> out = <String, Set<String>>{};
  for (final String node in queried) {
    final Set<String> eq = <String>{};
    for (final Set<String> ids in items.values) {
      if (ids.contains(node)) eq.addAll(ids);
    }
    eq.remove(node);
    out[node] = eq;
  }
  return out;
}

/// Wikidata 人物 id 桥。应用内用 [shared]（进程级串行闸门）；测试注入 `client`。
class WikidataPersonBridge {
  WikidataPersonBridge({
    http.Client? client,
    this.endpoint = 'https://query.wikidata.org/sparql',
    this.minInterval = const Duration(seconds: 1),
    this.timeout = const Duration(seconds: 30),
  }) : _client = client;

  static final WikidataPersonBridge shared = WikidataPersonBridge();

  final http.Client? _client;
  final String endpoint;
  final Duration minInterval;
  final Duration timeout;

  Future<void> _tail = Future<void>.value();
  DateTime? _lastRequestAt;

  /// 每个（合法的）查询节点 → 等价节点集合（查无结果 = 空集）。不合法 / 不支持
  /// 的节点不出现在结果里。
  Future<Map<String, Set<String>>> equivalentsOf(
    Iterable<String> idNodes,
  ) async {
    final List<String> valid = <String>[
      for (final String n in <String>{...idNodes})
        if (buildWikidataPersonQuery(<String>[n]) != null) n,
    ]..sort();
    final Map<String, Set<String>> out = <String, Set<String>>{};
    for (int i = 0; i < valid.length; i += kWikidataPersonBatchSize) {
      final List<String> batch = valid.sublist(
        i,
        (i + kWikidataPersonBatchSize).clamp(0, valid.length),
      );
      final Map<String, Set<String>> items = await _serialized(
        () => _query(buildWikidataPersonQuery(batch)!),
      );
      out.addAll(wikidataPersonEquivalents(batch, items));
    }
    return out;
  }

  Future<T> _serialized<T>(Future<T> Function() body) {
    final Completer<T> done = Completer<T>();
    _tail = _tail.then((_) async {
      final DateTime? last = _lastRequestAt;
      if (last != null) {
        final Duration wait = minInterval - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      _lastRequestAt = DateTime.now();
      try {
        done.complete(await body());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<Map<String, Set<String>>> _query(String sparql) async {
    final http.Client client = _client ?? createAppHttpIoClient();
    try {
      final http.Response res = await client
          .post(
            Uri.parse(endpoint),
            headers: <String, String>{
              'User-Agent': fushiUserAgent('people-wikidata'),
              'Accept': 'application/sparql-results+json',
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: <String, String>{'query': sparql},
          )
          .timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw WikidataPersonBridgeException('HTTP ${res.statusCode}');
      }
      final Object? json;
      try {
        json = jsonDecode(utf8.decode(res.bodyBytes));
      } on FormatException catch (e) {
        throw WikidataPersonBridgeException('bad JSON: ${e.message}');
      }
      return parseWikidataPersonBindings(json);
    } on TimeoutException {
      throw const WikidataPersonBridgeException('timeout');
    } on http.ClientException catch (e) {
      throw WikidataPersonBridgeException(e.message);
    } finally {
      if (_client == null) client.close();
    }
  }
}
