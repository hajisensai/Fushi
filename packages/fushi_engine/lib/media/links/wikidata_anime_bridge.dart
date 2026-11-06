/// Wikidata **id 桥接**：VNDB VN id → 改编动画的 AniDB anime id（作品图谱 L1，
/// spec `docs/specs/2026-10-24-cross-media-links.md`；所有者 2026-10-24 批准接入，
/// 只作 id 桥接、不作元数据主源——这里只读三类 id 与两条关系，不取标题、简介等）。
///
/// 为什么需要它：VNDB kana API 的 `/vn` 没有 `anime` 字段（2026-10-24 实测
/// `api.vndb.org/kana/schema`，请求 `anime{id}` 回「Field 'anime' not found」），
/// 游戏侧的 VNDB id 与视频侧的 AniDB id 之间没有直接通路。
///
/// 属性编号 2026-10-24 经 `wbgetentities` 实测核对（不是凭记忆写的）：
/// - [kWikidataVndbIdProperty] `P3180` = Visual Novel Database ID（值形如 `v4`）；
/// - [kWikidataAnidbAnimeIdProperty] `P5646` = AniDB anime ID；
/// - [kWikidataBasedOnProperty] `P144` = based on（动画 → 原作 VN）；
/// - [kWikidataDerivativeWorkProperty] `P4969` = derivative work（VN → 动画）。
/// 两条关系都表示「VN 是原作、动画是改编」，所以桥出来的连接方向确定。
///
/// 纪律：全局串行 + 最小请求间隔（Wikidata 查询服务对匿名客户端限流）；规范 UA
/// （[fushiUserAgent]，带项目主页）；按 VN 缓存结果（含「没有改编」的空结果），
/// 一部 VN 在 [cacheTtl] 内只查一次；VNDB id 先过格式校验再拼进 SPARQL，杜绝注入。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';

const String kWikidataVndbIdProperty = 'P3180';
const String kWikidataAnidbAnimeIdProperty = 'P5646';
const String kWikidataBasedOnProperty = 'P144';
const String kWikidataDerivativeWorkProperty = 'P4969';

/// 一次 SPARQL 最多带几部 VN（VALUES 子句长度上限，远低于查询服务的 URL 限制）。
const int kWikidataBridgeBatchSize = 50;

final RegExp _vndbIdPattern = RegExp(r'^v[1-9][0-9]{0,8}$');

/// Wikidata 查询失败（非 2xx / 回复不是合法的 SPARQL JSON）。调用方提示用户、
/// 本轮不写这条判据的建议；不缓存失败。
class WikidataBridgeException implements Exception {
  const WikidataBridgeException(this.message);

  final String message;

  @override
  String toString() => 'WikidataBridgeException: $message';
}

/// 规范化游戏侧存的 VNDB id（`v12345` / `V12345` / 裸数字都认）；不合法返回 null。
String? normalizeVndbVnId(String raw) {
  final String t = raw.trim().toLowerCase();
  final String id = RegExp(r'^[0-9]+$').hasMatch(t) ? 'v$t' : t;
  return _vndbIdPattern.hasMatch(id) ? id : null;
}

/// 「VN → 改编动画 AniDB id」的 SPARQL（纯函数，便于测试与核对）。
String buildWikidataVndbToAnidbQuery(Iterable<String> vndbIds) {
  final String values = vndbIds.map((String id) => '"$id"').join(' ');
  return 'SELECT ?vndb ?anidb WHERE { '
      'VALUES ?vndb { $values } '
      '?vn wdt:$kWikidataVndbIdProperty ?vndb . '
      '{ ?anime wdt:$kWikidataBasedOnProperty ?vn . } UNION '
      '{ ?vn wdt:$kWikidataDerivativeWorkProperty ?anime . } '
      '?anime wdt:$kWikidataAnidbAnimeIdProperty ?anidb . }';
}

/// 解析 SPARQL JSON 回复 → VNDB id → AniDB anime id 集合。
Map<String, Set<String>> parseWikidataVndbToAnidb(Object? json) {
  if (json is! Map) throw const WikidataBridgeException('not a JSON object');
  final Object? results = json['results'];
  final Object? bindings = results is Map ? results['bindings'] : null;
  if (bindings is! List) throw const WikidataBridgeException('no bindings');
  final Map<String, Set<String>> out = <String, Set<String>>{};
  for (final Object? b in bindings) {
    if (b is! Map) continue;
    final Object? vndb = b['vndb'];
    final Object? anidb = b['anidb'];
    final Object? vn = vndb is Map ? vndb['value'] : null;
    final Object? aid = anidb is Map ? anidb['value'] : null;
    if (vn is! String || aid is! String) continue;
    if (!RegExp(r'^[0-9]+$').hasMatch(aid.trim())) continue;
    out.putIfAbsent(vn, () => <String>{}).add(aid.trim());
  }
  return out;
}

/// VNDB id → AniDB anime id 的 Wikidata 桥。应用内用 [shared]（进程级缓存与
/// 限流闸门）；测试注入 `client` 与 `now`。
class WikidataAnimeBridge {
  WikidataAnimeBridge({
    http.Client? client,
    this.endpoint = 'https://query.wikidata.org/sparql',
    this.minInterval = const Duration(seconds: 1),
    this.cacheTtl = const Duration(days: 7),
    this.timeout = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _client = client,
       _now = now ?? DateTime.now;

  /// 进程级共享实例：缓存与限流跨详情页复用（同一部 VN 不因换页重查）。
  static final WikidataAnimeBridge shared = WikidataAnimeBridge();

  final http.Client? _client;
  final String endpoint;
  final Duration minInterval;
  final Duration cacheTtl;
  final Duration timeout;
  final DateTime Function() _now;

  final Map<String, ({Set<String> anidbIds, DateTime fetchedAt})> _cache =
      <String, ({Set<String> anidbIds, DateTime fetchedAt})>{};
  Future<void> _tail = Future<void>.value();
  DateTime? _lastRequestAt;

  /// 每部 VN（规范化后的 id）对应的 AniDB anime id；查不到改编的 VN 映射到空集。
  /// 不合法的 id 不出现在结果里。
  Future<Map<String, Set<String>>> anidbIdsForVndb(
    Iterable<String> vndbIds,
  ) async {
    final Set<String> ids = <String>{
      for (final String raw in vndbIds)
        if (normalizeVndbVnId(raw) case final String id) id,
    };
    final DateTime now = _now();
    final List<String> missing = <String>[
      for (final String id in ids)
        if (!_isFresh(_cache[id], now)) id,
    ];
    for (int i = 0; i < missing.length; i += kWikidataBridgeBatchSize) {
      final List<String> batch = missing.sublist(
        i,
        (i + kWikidataBridgeBatchSize).clamp(0, missing.length),
      );
      final Map<String, Set<String>> got = await _serialized(
        () => _query(batch),
      );
      final DateTime at = _now();
      for (final String id in batch) {
        _cache[id] = (anidbIds: got[id] ?? <String>{}, fetchedAt: at);
      }
    }
    return <String, Set<String>>{
      for (final String id in ids) id: _cache[id]?.anidbIds ?? <String>{},
    };
  }

  bool _isFresh(
    ({Set<String> anidbIds, DateTime fetchedAt})? entry,
    DateTime now,
  ) => entry != null && now.difference(entry.fetchedAt) < cacheTtl;

  /// 全局串行：上一条请求结束后、且距上一条起手满 [minInterval] 才发下一条。
  Future<T> _serialized<T>(Future<T> Function() body) {
    final Completer<T> done = Completer<T>();
    _tail = _tail.then((_) async {
      final DateTime? last = _lastRequestAt;
      if (last != null) {
        final Duration wait = minInterval - _now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      _lastRequestAt = _now();
      try {
        done.complete(await body());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<Map<String, Set<String>>> _query(List<String> batch) async {
    final http.Client client = _client ?? createAppHttpIoClient();
    try {
      final http.Response res = await client
          .post(
            Uri.parse(endpoint),
            headers: <String, String>{
              'User-Agent': fushiUserAgent('media-links-wikidata'),
              'Accept': 'application/sparql-results+json',
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: <String, String>{
              'query': buildWikidataVndbToAnidbQuery(batch),
            },
          )
          .timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw WikidataBridgeException('HTTP ${res.statusCode}');
      }
      final Object? json;
      try {
        json = jsonDecode(utf8.decode(res.bodyBytes));
      } on FormatException catch (e) {
        throw WikidataBridgeException('bad JSON: ${e.message}');
      }
      return parseWikidataVndbToAnidb(json);
    } on TimeoutException {
      throw const WikidataBridgeException('timeout');
    } on http.ClientException catch (e) {
      throw WikidataBridgeException(e.message);
    } finally {
      if (_client == null) client.close();
    }
  }
}
