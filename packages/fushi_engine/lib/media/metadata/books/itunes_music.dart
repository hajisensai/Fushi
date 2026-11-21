/// iTunes Search API（`https://itunes.apple.com/search`、`/lookup`）：歌曲 / 专辑封面源，
/// 免 key。给「以有声书形式导入的歌曲」（LRC 歌词 + 音频）刮专辑封面——Bangumi / DLsite
/// 等书籍源搜歌名只会出动画 / 漫画条目（应用内反馈 T_KdsLEY9l，拍板台同号）。
///
/// 为什么是 iTunes 而不是 MusicBrainz + Cover Art Archive：MusicBrainz 搜索结果不带「有没有
/// 封面」，每个候选还要再查一次 CAA 索引，而两者共用 1 req/s 的闸门（十个候选 ≈ 十秒），
/// 且不少发行没有封面；iTunes 一次请求就带每条的封面，可按 URL 取到 1200px 以上，日文
/// 歌曲收录全。曲库自己的识别仍走 MusicBrainz（`media/music/metadata/`），两边不混。
///
/// 店区固定 JP（`country=JP&lang=ja_jp`）：本应用的歌曲多为日文，日区给日文原标题与日区
/// 发行的封面。Apple 公开的限额约 20 次 / 分钟，节流见 [kBookCatalogMinIntervals]。
///
/// 映射：`trackName`（专辑条目用 `collectionName`）→ 标题，`artistName` → 作者，专辑名
/// → 系列，`releaseDate` → 日期 / 年份，`primaryGenreName` → 标签，`artworkUrl100` 改尺寸
/// 段为 [kItunesCoverSize] → 封面，`trackViewUrl` / `collectionViewUrl` → 详情页。
library;

import 'dart:convert';

import 'package:fushi_engine/media/metadata/books/book_catalog.dart';

/// 封面取的边长（px）。iTunes 封面 URL 末段是 `100x100bb.jpg`，换成更大的尺寸由 CDN 现缩，
/// 原图不足时给原图大小（2026-11-21 实测 1200 稳定可取，约 300 KB）。
const int kItunesCoverSize = 1200;

/// 店区与界面语言（见库注释）。
const Map<String, String> _kItunesStore = <String, String>{
  'country': 'JP',
  'lang': 'ja_jp',
};

/// iTunes 歌曲 / 专辑客户端。
class ItunesMusicClient {
  ItunesMusicClient(this._http);

  final BookCatalogHttp _http;

  /// 按关键词搜歌曲（`media=music&entity=song`），返回带封面的记录（最多 [limit] 条）。
  Future<List<BookCatalogRecord>> search(
    String keyword, {
    int limit = 15,
  }) async {
    final String term = keyword.trim();
    if (term.isEmpty) return const <BookCatalogRecord>[];
    final BookCatalogResponse res = await _http.get(
      Uri.https('itunes.apple.com', '/search', <String, String>{
        'term': term,
        'media': 'music',
        'entity': 'song',
        'limit': '${limit.clamp(1, 50)}',
        ..._kItunesStore,
      }),
      headers: const <String, String>{'Accept': 'application/json'},
    );
    if (!res.isOk) {
      throw BookCatalogException(
        'iTunes search HTTP ${res.statusCode}',
        statusCode: res.statusCode,
      );
    }
    return parseItunesResponse(res.body);
  }

  /// 按 iTunes id（歌曲 trackId 或专辑 collectionId）直取；非数字 / 查无返回 null。
  Future<BookCatalogRecord?> fetchById(String id) async {
    final String trimmed = id.trim();
    if (!RegExp(r'^\d+$').hasMatch(trimmed)) return null;
    final BookCatalogResponse res = await _http.get(
      Uri.https('itunes.apple.com', '/lookup', <String, String>{
        'id': trimmed,
        ..._kItunesStore,
      }),
      headers: const <String, String>{'Accept': 'application/json'},
    );
    if (!res.isOk) {
      throw BookCatalogException(
        'iTunes lookup HTTP ${res.statusCode}',
        statusCode: res.statusCode,
      );
    }
    final List<BookCatalogRecord> found = parseItunesResponse(res.body);
    return found.isEmpty ? null : found.first;
  }
}

/// 纯函数：解析 `/search` 或 `/lookup` 响应（`{resultCount, results: [...]}`）。没有
/// 封面 / 标题 / id 的条目跳过；不是 JSON 对象抛 [BookCatalogException]。
List<BookCatalogRecord> parseItunesResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw BookCatalogException('iTunes malformed JSON: ${e.message}');
  }
  if (decoded is! Map<String, Object?>) {
    throw const BookCatalogException('iTunes response is not an object');
  }
  final Object? results = decoded['results'];
  if (results is! List<Object?>) return const <BookCatalogRecord>[];
  return <BookCatalogRecord>[
    for (final Object? r in results)
      if (r is Map<String, Object?>) ?mapItunesResult(r),
  ];
}

/// 单条 iTunes 结果（歌曲 `wrapperType: track` 或专辑 `wrapperType: collection`）→
/// [BookCatalogRecord]；无 id / 标题 / 封面返回 null，其它类型（艺人等）也返回 null。
BookCatalogRecord? mapItunesResult(Map<String, Object?> r) {
  final String? wrapper = catalogString(r['wrapperType']);
  final bool isTrack = wrapper == 'track';
  if (!isTrack && wrapper != 'collection') return null;
  final Object? rawId = isTrack ? r['trackId'] : r['collectionId'];
  if (rawId is! num) return null;
  final String? title = catalogString(
    isTrack ? r['trackName'] : r['collectionName'],
  );
  final String? cover = itunesArtworkUrl(
    catalogString(r['artworkUrl100']) ?? catalogString(r['artworkUrl60']),
  );
  if (title == null || cover == null) return null;
  final String? date = _isoDay(catalogString(r['releaseDate']));
  final String? genre = catalogString(r['primaryGenreName']);
  return BookCatalogRecord(
    id: '${rawId.toInt()}',
    title: title,
    author: catalogString(r['artistName']),
    series: isTrack ? catalogString(r['collectionName']) : null,
    year: catalogYear(date),
    date: date,
    tags: genre == null ? const <String>[] : <String>[genre],
    coverUrl: cover,
    pageUrl: _stripTracking(
      catalogString(isTrack ? r['trackViewUrl'] : r['collectionViewUrl']),
    ),
  );
}

/// iTunes 封面 URL 末段的尺寸（`…/100x100bb.jpg`）换成 [size]；认不出尺寸段原样返回，
/// null 进 null 出。
String? itunesArtworkUrl(String? url, {int size = kItunesCoverSize}) {
  if (url == null) return null;
  return url.replaceFirstMapped(
    RegExp(r'/\d+x\d+(bb|cc)?\.(jpg|jpeg|png|webp)$', caseSensitive: false),
    (Match m) => '/${size}x$size${m.group(1) ?? 'bb'}.${m.group(2)}',
  );
}

/// 用户贴的 Apple Music / iTunes 链接 → 可直取的 id：`?i=<trackId>`（专辑页里的一首）
/// 优先，否则取路径末尾的数字（`/album/<名>/<collectionId>`、`/song/<名>/<trackId>`）；
/// 纯数字原样返回；其余 null。
String? parseItunesUrl(String input) {
  final String trimmed = input.trim();
  if (RegExp(r'^\d+$').hasMatch(trimmed)) return trimmed;
  final Uri? uri = Uri.tryParse(
    trimmed.contains('://') ? trimmed : 'https://$trimmed',
  );
  if (uri == null) return null;
  final String host = uri.host.toLowerCase();
  if (host != 'music.apple.com' &&
      host != 'itunes.apple.com' &&
      host != 'geo.music.apple.com') {
    return null;
  }
  final String? track = uri.queryParameters['i'];
  if (track != null && RegExp(r'^\d+$').hasMatch(track)) return track;
  for (final String segment in uri.pathSegments.reversed) {
    final RegExpMatch? m = RegExp(r'^(?:id)?(\d+)$').firstMatch(segment);
    if (m != null) return m.group(1);
  }
  return null;
}

/// `2018-02-12T12:00:00Z` → `2018-02-12`。
String? _isoDay(String? raw) {
  if (raw == null) return null;
  final RegExpMatch? m = RegExp(r'^\d{4}(-\d{2}(-\d{2})?)?').firstMatch(raw);
  return m?.group(0);
}

/// 去掉 Apple 链接上的 `uo=4` 跟踪参数（保留 `i=` 等定位参数）。
String? _stripTracking(String? url) {
  if (url == null) return null;
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || !uri.queryParameters.containsKey('uo')) return url;
  final Map<String, String> rest = Map<String, String>.of(uri.queryParameters)
    ..remove('uo');
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    path: uri.path,
    queryParameters: rest.isEmpty ? null : rest,
  ).toString();
}
