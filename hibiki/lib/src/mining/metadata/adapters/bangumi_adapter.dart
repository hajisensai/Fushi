/// Bangumi（番组计划）元数据 adapter（契约 §2.3）。
///
/// 端点 `https://api.bgm.tv/v0`：`GET /subjects/{id}`、`POST /search/subjects`
/// （`filter.type = [4]` 限定「游戏」）。token 可选，只有 R18 条目才必须带。
///
/// 代理：`package:http` 走 `dart:io` 的 `HttpClient`，自动尊重系统 / 环境代理，本层不管。
library;

import 'dart:async';
import 'dart:convert';

import 'package:hibiki/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_rate_limit.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_source.dart';
import 'package:http/http.dart' as http;

/// Bangumi 条目类型：4 = 游戏。
const int kBangumiSubjectTypeGame = 4;

/// infobox 里表示「别名」的 key（不同条目写法不一，全收）。
const Set<String> _kAliasKeys = <String>{'别名', '别號', '别号'};

/// infobox 里表示「开发商」的 key。
const Set<String> _kDeveloperKeys = <String>{'开发', '開發', '开发商', '游戏开发商'};

/// 标签保留上限（与 vndb 侧对齐）。
const int kBangumiMaxTags = 30;

class BangumiMetadataAdapter implements GalgameMetadataAdapter {
  BangumiMetadataAdapter({
    http.Client? client,
    GalgameRateLimiter? rateLimiter,
    String? accessToken,
    String baseUrl = 'https://api.bgm.tv/v0',
    Duration timeout = const Duration(seconds: 15),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _rateLimiter = rateLimiter ?? GalgameRateLimiter(),
        _accessToken = accessToken,
        _baseUrl = baseUrl,
        _timeout = timeout;

  final http.Client _client;
  final bool _ownsClient;
  final GalgameRateLimiter _rateLimiter;
  final String? _accessToken;
  final String _baseUrl;
  final Duration _timeout;

  /// Bangumi 要求可识别的 User-Agent，否则可能被限流 / 拒绝。
  static const String _userAgent =
      'hibiki-reader/galgame-library (https://github.com/hajisensai)';

  @override
  GalgameMetadataSource get source => GalgameMetadataSource.bgm;

  @override
  bool validateId(String id) => RegExp(r'^\d+$').hasMatch(id.trim());

  @override
  String externalUrl(String id) => 'https://bgm.tv/subject/${id.trim()}';

  @override
  Future<GalgameMetadataDraft?> fetchById(String id) async {
    final String trimmed = id.trim();
    if (!validateId(trimmed)) {
      throw GalgameMetadataException(
        'invalid Bangumi subject id: "$id"',
        source: source,
      );
    }
    final http.Response response = await _send(
      () => _client
          .get(Uri.parse('$_baseUrl/subjects/$trimmed'), headers: _headers())
          .timeout(_timeout),
    );
    if (response.statusCode == 404) {
      return null; // 条目不存在是正常结果，不是异常。
    }
    _ensureOk(response, 'fetch subject $trimmed');
    final Object? decoded = _decodeJson(response, 'subject $trimmed');
    if (decoded is! Map) {
      throw GalgameMetadataException(
        'subject $trimmed response is not a JSON object',
        source: source,
      );
    }
    final GalgameMetadataDraft draft =
        parseBangumiSubject(Map<Object?, Object?>.from(decoded));
    return draft.isEmpty && draft.externalId == null ? null : draft;
  }

  @override
  Future<List<SourceCandidate>> searchByName(
    String name, {
    int limit = 10,
  }) async {
    final String keyword = name.trim();
    if (keyword.isEmpty) {
      return const <SourceCandidate>[];
    }
    final Uri uri = Uri.parse('$_baseUrl/search/subjects').replace(
      queryParameters: <String, String>{'limit': '${limit.clamp(1, 50)}'},
    );
    final String body = jsonEncode(<String, Object?>{
      'keyword': keyword,
      'filter': <String, Object?>{
        'type': <int>[kBangumiSubjectTypeGame],
      },
    });
    final http.Response response = await _send(
      () => _client
          .post(uri, headers: _headers(json: true), body: body)
          .timeout(_timeout),
    );
    if (response.statusCode == 404) {
      return const <SourceCandidate>[]; // 无命中时 Bangumi 偶尔回 404。
    }
    _ensureOk(response, 'search "$keyword"');
    return parseBangumiSearchResults(
      _decodeJson(response, 'search "$keyword"'),
      limit: limit,
    );
  }

  @override
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  Map<String, String> _headers({bool json = false}) {
    final Map<String, String> headers = <String, String>{
      'User-Agent': _userAgent,
      'Accept': 'application/json',
    };
    if (json) {
      headers['Content-Type'] = 'application/json';
    }
    final String? token = _accessToken;
    if (token != null && token.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${token.trim()}';
    }
    return headers;
  }

  /// 过限流器发一次请求，并把 429/503 的 `Retry-After` 记回桶里。
  Future<http.Response> _send(Future<http.Response> Function() send) {
    return _rateLimiter.run(() async {
      final http.Response response;
      try {
        response = await send();
      } on TimeoutException {
        throw GalgameMetadataException('Bangumi request timed out',
            source: source);
      } on GalgameMetadataException {
        rethrow;
      } catch (e) {
        throw GalgameMetadataException('Bangumi request failed: $e',
            source: source);
      }
      _rateLimiter.noteResponse(response.statusCode, response.headers);
      return response;
    });
  }

  void _ensureOk(http.Response response, String what) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    throw GalgameMetadataException(
      'Bangumi $what failed',
      source: source,
      statusCode: response.statusCode,
    );
  }

  /// 用 bodyBytes + utf8 解码：缺 charset 时 `http.Response.body` 会按 latin1 解，毁中日文。
  Object? _decodeJson(http.Response response, String what) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (e) {
      throw GalgameMetadataException(
        'Bangumi $what returned malformed JSON: $e',
        source: source,
      );
    }
  }
}

/// 纯函数：把 `GET /v0/subjects/{id}` 的响应体映射成 draft。抽成顶层便于单测。
GalgameMetadataDraft parseBangumiSubject(Map<Object?, Object?> subject) {
  final String? name = draftString(subject['name']);
  final String? nameCn = draftString(subject['name_cn']);
  final _Infobox infobox = _parseInfobox(subject['infobox']);

  // allTitles = 原名 ∪ 中文名 ∪ 别名（去重保序），供搜索匹配。
  final List<String> allTitles = draftStringList(<Object?>[
    name,
    nameCn,
    ...infobox.aliases,
  ]);

  final Object? rating = subject['rating'];
  double? score;
  int? rank;
  if (rating is Map) {
    score = draftDouble(rating['score']);
    rank = draftInt(rating['rank']);
  }
  // 有些响应把 rank 放在顶层。
  rank ??= draftInt(subject['rank']);
  if (score != null && score <= 0) {
    score = null; // 0 分 = 没人评过，不是真评分。
  }
  if (rank != null && rank <= 0) {
    rank = null;
  }

  return GalgameMetadataDraft(
    name: name,
    nameCn: nameCn,
    aliases: infobox.aliases,
    allTitles: allTitles,
    summary: draftString(subject['summary']),
    tags: _parseTags(subject['tags']),
    developer: infobox.developer,
    releaseDate: draftDate(subject['date']),
    score: score,
    rank: rank,
    nsfw: draftBool(subject['nsfw']),
    coverUrl: bangumiCoverUrl(subject),
    externalId: draftString(subject['id']?.toString()),
  );
}

/// 纯函数：把 `POST /v0/search/subjects` 的响应映射成候选列表。
///
/// 结构异常（非对象 / 无数组）当作**空结果**而非异常——搜不到是正常情况。
List<SourceCandidate> parseBangumiSearchResults(
  Object? decoded, {
  int limit = 10,
}) {
  if (decoded is! Map) {
    return const <SourceCandidate>[];
  }
  // v0 用 `data`，个别旧端点用 `list`，都收。
  final Object? items = decoded['data'] ?? decoded['list'];
  if (items is! List) {
    return const <SourceCandidate>[];
  }
  final List<SourceCandidate> out = <SourceCandidate>[];
  for (final Object? item in items) {
    if (item is! Map) {
      continue;
    }
    final Map<Object?, Object?> subject = Map<Object?, Object?>.from(item);
    final String? id = draftString(subject['id']?.toString());
    if (id == null) {
      continue; // 没 ID 就无法 fetchById，这条候选没用。
    }
    out.add(SourceCandidate(
      source: GalgameMetadataSource.bgm,
      externalId: id,
      name: draftString(subject['name']),
      nameCn: draftString(subject['name_cn']),
      coverUrl: bangumiCoverUrl(subject),
      releaseDate: draftDate(subject['date']),
      summary: summaryExcerpt(subject['summary']),
    ));
    if (out.length >= limit) {
      break;
    }
  }
  return out;
}

/// 取封面 URL：`images.large` → `common` → `medium`；搜索结果里可能退化成 `image` 字符串。
String? bangumiCoverUrl(Map<Object?, Object?> subject) {
  final Object? images = subject['images'];
  if (images is Map) {
    final String? url = draftString(images['large']) ??
        draftString(images['common']) ??
        draftString(images['medium']) ??
        draftString(images['small']);
    if (url != null) {
      return url;
    }
  }
  return draftString(subject['image']);
}

/// `tags: [{name, count}]` → 按 count 降序取前 [kBangumiMaxTags] 个名字。
List<String> _parseTags(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  final List<({String name, int count})> entries =
      <({String name, int count})>[];
  for (final Object? item in value) {
    if (item is Map) {
      final String? name = draftString(item['name']);
      if (name != null) {
        entries.add((name: name, count: draftInt(item['count']) ?? 0));
      }
    } else {
      // 少数响应直接给字符串数组。
      final String? name = draftString(item);
      if (name != null) {
        entries.add((name: name, count: 0));
      }
    }
  }
  // 稳定排序：count 相同保持源顺序（List.sort 不稳定，故用带下标的比较）。
  final List<int> order = List<int>.generate(entries.length, (int i) => i);
  order.sort((int a, int b) {
    final int byCount = entries[b].count.compareTo(entries[a].count);
    return byCount != 0 ? byCount : a.compareTo(b);
  });
  return draftStringList(<Object?>[
    for (final int i in order.take(kBangumiMaxTags)) entries[i].name,
  ]);
}

/// infobox 解析结果。
typedef _Infobox = ({List<String> aliases, String? developer});

/// 解析 `infobox: [{key, value}]`。
///
/// `value` 有两种形状：纯字符串，或 `[{v: "..."}]` 数组（别名几乎都是后者）。
_Infobox _parseInfobox(Object? value) {
  if (value is! List) {
    return (aliases: const <String>[], developer: null);
  }
  final List<String> aliases = <String>[];
  String? developer;
  for (final Object? item in value) {
    if (item is! Map) {
      continue;
    }
    final String? key = draftString(item['key']);
    if (key == null) {
      continue;
    }
    if (_kAliasKeys.contains(key)) {
      aliases.addAll(_infoboxValues(item['value']));
    } else if (developer == null && _kDeveloperKeys.contains(key)) {
      final List<String> devs = _infoboxValues(item['value']);
      if (devs.isNotEmpty) {
        developer = devs.join(', ');
      }
    }
  }
  return (aliases: draftStringList(aliases), developer: developer);
}

/// 把 infobox 单项的 value 摊平成字符串列表（字符串 → 单元素；`[{v}]` → 各 v）。
List<String> _infoboxValues(Object? value) {
  final String? single = draftString(value);
  if (single != null) {
    return <String>[single];
  }
  if (value is! List) {
    return const <String>[];
  }
  final List<String> out = <String>[];
  for (final Object? item in value) {
    if (item is Map) {
      final String? v = draftString(item['v']) ?? draftString(item['value']);
      if (v != null) {
        out.add(v);
      }
    } else {
      final String? v = draftString(item);
      if (v != null) {
        out.add(v);
      }
    }
  }
  return out;
}
