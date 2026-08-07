/// VNDB 元数据 adapter（契约 §2.3）。
///
/// 端点 `https://api.vndb.org/kana`，只用 `POST /vn`：按 ID 取用 `filters: ["id","=",id]`，
/// 按名搜用 `filters: ["search","=",name]` + `sort: "searchrank"`。
///
/// 两处**必须归一**：`rating` 源侧是 0-100（落 draft 前 /10），`length_minutes` 是分钟
/// （落 draft 前 /60 成小时）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi/src/mining/metadata/galgame_metadata_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_rate_limit.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_source.dart';
import 'package:http/http.dart' as http;

/// 详情请求要的字段集（契约 §2.3 逐字给定）。
const String kVndbDetailFields =
    'id,titles{title,lang,main},aliases,image{url},released,rating,'
    'tags{name,rating,spoiler},description,developers{name},length_minutes';

/// 搜索候选只要够展示的字段，少拉一大坨 tags/description 全文。
const String kVndbSearchFields =
    'id,titles{title,lang,main},image{url},released,description';

/// 标签保留上限。
const int kVndbMaxTags = 30;

/// 中文标题语言码优先级（VNDB 用 BCP-47 风格）。
const List<String> _kChineseLangs = <String>['zh-Hans', 'zh-Hant', 'zh'];

class VndbMetadataAdapter implements GalgameMetadataAdapter {
  VndbMetadataAdapter({
    http.Client? client,
    GalgameRateLimiter? rateLimiter,
    String baseUrl = 'https://api.vndb.org/kana',
    Duration timeout = const Duration(seconds: 15),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        // VNDB 官方限流约 1 req/s、突发 200；这里取远比它保守的稳态。
        _rateLimiter = rateLimiter ??
            GalgameRateLimiter(
              capacity: 2,
              refillInterval: const Duration(milliseconds: 1100),
            ),
        _baseUrl = baseUrl,
        _timeout = timeout;

  final http.Client _client;
  final bool _ownsClient;
  final GalgameRateLimiter _rateLimiter;
  final String _baseUrl;
  final Duration _timeout;

  static const String _userAgent =
      'fushi-reader/galgame-library (https://github.com/hajisensai)';

  @override
  GalgameMetadataSource get source => GalgameMetadataSource.vndb;

  @override
  bool validateId(String id) => RegExp(r'^v\d+$').hasMatch(id.trim());

  @override
  String externalUrl(String id) => 'https://vndb.org/${id.trim()}';

  @override
  Future<GalgameMetadataDraft?> fetchById(String id) async {
    final String trimmed = id.trim();
    if (!validateId(trimmed)) {
      throw GalgameMetadataException(
        'invalid VNDB id: "$id"',
        source: source,
      );
    }
    final List<Object?> results = await _queryVn(
      <String, Object?>{
        'filters': <Object?>['id', '=', trimmed],
        'fields': kVndbDetailFields,
        'results': 1,
      },
      what: 'fetch $trimmed',
    );
    if (results.isEmpty) {
      return null; // 不存在的 ID：VNDB 回 200 + 空 results，不是异常。
    }
    final Object? first = results.first;
    if (first is! Map) {
      return null;
    }
    return parseVndbVisualNovel(Map<Object?, Object?>.from(first));
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
    final List<Object?> results = await _queryVn(
      <String, Object?>{
        'filters': <Object?>['search', '=', keyword],
        'fields': kVndbSearchFields,
        'sort': 'searchrank',
        'results': limit.clamp(1, 100),
      },
      what: 'search "$keyword"',
    );
    return parseVndbSearchResults(results, limit: limit);
  }

  @override
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  /// 发一次 `POST /vn` 并取出 `results` 数组。404 → 空表；其余非 2xx → 抛。
  Future<List<Object?>> _queryVn(
    Map<String, Object?> body, {
    required String what,
  }) async {
    final http.Response response = await _send(
      () => _client
          .post(
            Uri.parse('$_baseUrl/vn'),
            headers: const <String, String>{
              'User-Agent': _userAgent,
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout),
    );
    if (response.statusCode == 404) {
      return const <Object?>[];
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GalgameMetadataException(
        'VNDB $what failed',
        source: source,
        statusCode: response.statusCode,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (e) {
      throw GalgameMetadataException(
        'VNDB $what returned malformed JSON: $e',
        source: source,
      );
    }
    if (decoded is! Map) {
      throw GalgameMetadataException(
        'VNDB $what response is not a JSON object',
        source: source,
      );
    }
    final Object? results = decoded['results'];
    return results is List ? results : const <Object?>[];
  }

  Future<http.Response> _send(Future<http.Response> Function() send) {
    return _rateLimiter.run(() async {
      final http.Response response;
      try {
        response = await send();
      } on TimeoutException {
        throw GalgameMetadataException('VNDB request timed out',
            source: source);
      } on GalgameMetadataException {
        rethrow;
      } catch (e) {
        throw GalgameMetadataException('VNDB request failed: $e',
            source: source);
      }
      _rateLimiter.noteResponse(response.statusCode, response.headers);
      return response;
    });
  }
}

/// 纯函数：把一条 VN 记录映射成 draft。
GalgameMetadataDraft parseVndbVisualNovel(Map<Object?, Object?> vn) {
  final _Titles titles = _parseTitles(vn['titles']);
  final List<String> aliases = draftStringList(vn['aliases']);

  return GalgameMetadataDraft(
    name: titles.main,
    nameCn: titles.chinese,
    aliases: aliases,
    allTitles: draftStringList(<Object?>[...titles.all, ...aliases]),
    summary: draftString(vn['description']),
    tags: parseVndbTags(vn['tags']),
    developer: _parseDevelopers(vn['developers']),
    releaseDate: draftDate(vn['released']),
    score: vndbRatingToScore(vn['rating']),
    averageHours: vndbMinutesToHours(vn['length_minutes']),
    coverUrl: _parseImage(vn['image']),
    externalId: draftString(vn['id']),
  );
}

/// 纯函数：把 `results` 数组映射成候选列表。
List<SourceCandidate> parseVndbSearchResults(
  List<Object?> results, {
  int limit = 10,
}) {
  final List<SourceCandidate> out = <SourceCandidate>[];
  for (final Object? item in results) {
    if (item is! Map) {
      continue;
    }
    final Map<Object?, Object?> vn = Map<Object?, Object?>.from(item);
    final String? id = draftString(vn['id']);
    if (id == null) {
      continue;
    }
    final _Titles titles = _parseTitles(vn['titles']);
    out.add(SourceCandidate(
      source: GalgameMetadataSource.vndb,
      externalId: id,
      name: titles.main,
      nameCn: titles.chinese,
      coverUrl: _parseImage(vn['image']),
      releaseDate: draftDate(vn['released']),
      summary: summaryExcerpt(vn['description']),
    ));
    if (out.length >= limit) {
      break;
    }
  }
  return out;
}

/// VNDB `rating` 是 0-100，归一到 0-10（保留两位，避免二进制浮点噪声）。
/// 0 / 越界 / 非数字 → null。纯函数。
double? vndbRatingToScore(Object? rating) {
  final double? raw = draftDouble(rating);
  if (raw == null || raw <= 0) {
    return null;
  }
  final double clamped = raw > 100 ? 100 : raw;
  return double.parse((clamped / 10).toStringAsFixed(2));
}

/// `length_minutes` → 小时（保留一位）。非正 / 非数字 → null。纯函数。
double? vndbMinutesToHours(Object? minutes) {
  final double? raw = draftDouble(minutes);
  if (raw == null || raw <= 0) {
    return null;
  }
  return double.parse((raw / 60).toStringAsFixed(1));
}

/// `tags: [{name, rating, spoiler}]` → 过滤 `spoiler > 0`，按 rating 降序取前 N。纯函数。
List<String> parseVndbTags(Object? value, {int maxTags = kVndbMaxTags}) {
  if (value is! List) {
    return const <String>[];
  }
  final List<({String name, double rating})> kept =
      <({String name, double rating})>[];
  for (final Object? item in value) {
    if (item is! Map) {
      continue;
    }
    final String? name = draftString(item['name']);
    if (name == null) {
      continue;
    }
    // spoiler 缺省当 0（不剧透）；>0 一律丢，标签墙不该剧透。
    if ((draftInt(item['spoiler']) ?? 0) > 0) {
      continue;
    }
    kept.add((name: name, rating: draftDouble(item['rating']) ?? 0));
  }
  // 稳定排序：rating 相同保持源顺序。
  final List<int> order = List<int>.generate(kept.length, (int i) => i);
  order.sort((int a, int b) {
    final int byRating = kept[b].rating.compareTo(kept[a].rating);
    return byRating != 0 ? byRating : a.compareTo(b);
  });
  return draftStringList(<Object?>[
    for (final int i in order.take(maxTags)) kept[i].name,
  ]);
}

/// 标题解析结果。
typedef _Titles = ({String? main, String? chinese, List<String> all});

/// `titles: [{title, lang, main}]` → 主标题 / 中文名 / 全部标题。
_Titles _parseTitles(Object? value) {
  if (value is! List) {
    return (main: null, chinese: null, all: const <String>[]);
  }
  String? main;
  String? chinese;
  int chineseRank = _kChineseLangs.length; // 越小越优先
  final List<String> all = <String>[];
  String? firstTitle;

  for (final Object? item in value) {
    if (item is! Map) {
      continue;
    }
    final String? title = draftString(item['title']);
    if (title == null) {
      continue;
    }
    all.add(title);
    final String? latin = draftString(item['latin']);
    if (latin != null) {
      all.add(latin);
    }
    firstTitle ??= title;
    if (main == null && draftBool(item['main']) == true) {
      main = title;
    }
    final String? lang = draftString(item['lang']);
    if (lang != null) {
      final int rank = _kChineseLangs.indexOf(lang);
      if (rank >= 0 && rank < chineseRank) {
        chinese = title;
        chineseRank = rank;
      }
    }
  }
  return (
    main: main ?? firstTitle,
    chinese: chinese,
    all: draftStringList(all),
  );
}

/// `image: {url}` → URL；也容忍直接给字符串。
String? _parseImage(Object? value) {
  if (value is Map) {
    return draftString(value['url']);
  }
  return draftString(value);
}

/// `developers: [{name}]` → 用 `, ` 连接；空 → null。
String? _parseDevelopers(Object? value) {
  if (value is! List) {
    return null;
  }
  final List<String> names = <String>[];
  for (final Object? item in value) {
    final String? name =
        item is Map ? draftString(item['name']) : draftString(item);
    if (name != null && !names.contains(name)) {
      names.add(name);
    }
  }
  return names.isEmpty ? null : names.join(', ');
}
