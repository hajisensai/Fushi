/// Apple Music catalog 来源（MusicKit 方案 §3.2 / §3.6，P1b）：`MusicServerBrowser` 的
/// Apple Music 实现，**只读浏览 + 30 秒试听**。
///
/// - 浏览：Dart 直接调公开的 Apple Music API（`api.music.apple.com/v1/catalog/{storefront}`），
///   developer token 来自 [AppleMusicTokenSource]（Worker 代签）。不需要用户登录。
///   Apple 没有「列出全部专辑 / 艺人」的接口，所以专辑分区是该 storefront 的热门专辑榜
///   （`charts?types=albums`），艺人分区是榜单专辑的艺人；真正的入口是搜索。
/// - 播放：曲目自带的预览片段（`previews[0].url`，约 30 秒 AAC m4a）交给 mpv，五端都能放。
///   整曲播放要经 Apple 授权的播放器解密（P2 原生 MusicKit / P3 网页桥），不在这一层。
///   没有预览的曲目（未发行 / 区域受限）不列出，免得点了才报错。
/// - 不用私有接口（amp-api、逐字 TTML 等），也不缓存、不下载音频。
///
/// 纯 Dart、不碰 Flutter（引擎纯度守卫）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi_engine/media/music/apple_music/apple_music_token_source.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

/// Apple Music API 根。
final Uri kAppleMusicApiBase = Uri.parse('https://api.music.apple.com');

/// 缺省 storefront（Fushi 是日语学习应用：日区曲库最全）。
const String kAppleMusicDefaultStorefront = 'jp';

/// 设置里可选的 storefront（ISO 3166-1 alpha-2 小写，Apple 的 storefront id 即此）。
const List<String> kAppleMusicStorefrontChoices = <String>[
  'jp',
  'us',
  'gb',
  'cn',
  'tw',
  'hk',
  'kr',
  'sg',
  'ca',
  'au',
  'de',
  'fr',
];

/// 单个请求的超时。
const Duration kAppleMusicRequestTimeout = Duration(seconds: 15);

/// 榜单单页上限（Apple 文档：charts `limit` 最大 50）。
const int _kChartPageLimit = 50;

/// 搜索单类上限（Apple 文档：search `limit` 最大 25）。
const int _kSearchLimit = 25;

/// 关系分页（艺人专辑）单页上限。
const int _kRelationshipPageLimit = 100;

/// 关系分页最多跟几页（防异常回包无限翻页）。
const int _kMaxRelationshipPages = 10;

/// Apple Music API 回了非 2xx。
class AppleMusicApiException implements Exception {
  const AppleMusicApiException(this.httpStatus, this.path);

  final int httpStatus;

  /// 请求路径（不含 token：token 只在头里）。
  final String path;

  @override
  String toString() => 'AppleMusicApiException(http $httpStatus, $path)';
}

/// storefront 归一化：两位字母小写，不合法回缺省。
String normalizeAppleMusicStorefront(String? raw) {
  final String s = (raw ?? '').trim().toLowerCase();
  return RegExp(r'^[a-z]{2}$').hasMatch(s) ? s : kAppleMusicDefaultStorefront;
}

/// 一首 catalog 曲目及其预览地址。
class AppleMusicSong {
  const AppleMusicSong({required this.track, this.previewUri, this.isrc});

  final MusicServerTrack track;
  final Uri? previewUri;
  final String? isrc;
}

Map<String, Object?> _attrs(Map<String, Object?> res) {
  final Object? a = res['attributes'];
  return a is Map<String, Object?> ? a : const <String, Object?>{};
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _int(Object? v) => v is num ? v.toInt() : null;

String? _artworkTemplate(Map<String, Object?> attrs) {
  final Object? art = attrs['artwork'];
  return art is Map<String, Object?> ? _str(art['url']) : null;
}

int? _yearOf(Object? releaseDate) {
  final String? d = _str(releaseDate);
  if (d == null || d.length < 4) return null;
  return int.tryParse(d.substring(0, 4));
}

/// `songs` 资源 → 曲目。不是 `songs`（如专辑里的 `music-videos`）或缺 id / 名回 null。
AppleMusicSong? parseAppleMusicSong(Object? raw) {
  if (raw is! Map<String, Object?> || raw['type'] != 'songs') return null;
  final String? id = _str(raw['id']);
  final Map<String, Object?> a = _attrs(raw);
  final String? name = _str(a['name']);
  if (id == null || name == null) return null;
  Uri? preview;
  final Object? previews = a['previews'];
  if (previews is List<Object?>) {
    for (final Object? p in previews) {
      final String? url = p is Map<String, Object?> ? _str(p['url']) : null;
      final Uri? u = url == null ? null : Uri.tryParse(url);
      if (u != null && (u.scheme == 'https' || u.scheme == 'http')) {
        preview = u;
        break;
      }
    }
  }
  String? albumId;
  final Object? rel = raw['relationships'];
  if (rel is Map<String, Object?>) {
    final Object? albums = rel['albums'];
    final Object? data = albums is Map<String, Object?> ? albums['data'] : null;
    if (data is List<Object?> && data.isNotEmpty) {
      final Object? first = data.first;
      if (first is Map<String, Object?>) albumId = _str(first['id']);
    }
  }
  return AppleMusicSong(
    track: MusicServerTrack(
      id: id,
      title: name,
      artist: _str(a['artistName']),
      album: _str(a['albumName']),
      albumId: albumId,
      discNo: _int(a['discNumber']),
      trackNo: _int(a['trackNumber']),
      durationMs: _int(a['durationInMillis']),
      // 预览片段是 AAC m4a（信号路径面板 / 格式徽章如实显示有损）。
      container: 'm4a',
      codec: 'aac',
      coverRef: _artworkTemplate(a),
    ),
    previewUri: preview,
    isrc: _str(a['isrc']),
  );
}

/// `albums` 资源 → 专辑。
MusicServerAlbum? parseAppleMusicAlbum(Object? raw) {
  if (raw is! Map<String, Object?> || raw['type'] != 'albums') return null;
  final String? id = _str(raw['id']);
  final Map<String, Object?> a = _attrs(raw);
  final String? name = _str(a['name']);
  if (id == null || name == null) return null;
  String? artistId;
  final Object? rel = raw['relationships'];
  if (rel is Map<String, Object?>) {
    final Object? artists = rel['artists'];
    final Object? data = artists is Map<String, Object?>
        ? artists['data']
        : null;
    if (data is List<Object?> && data.isNotEmpty) {
      final Object? first = data.first;
      if (first is Map<String, Object?>) artistId = _str(first['id']);
    }
  }
  return MusicServerAlbum(
    id: id,
    title: name,
    artist: _str(a['artistName']),
    artistId: artistId,
    year: _yearOf(a['releaseDate']),
    trackCount: _int(a['trackCount']),
    coverRef: _artworkTemplate(a),
  );
}

/// `artists` 资源 → 艺人。只有 id 没有属性（未 include）时回 null。
MusicServerArtist? parseAppleMusicArtist(Object? raw) {
  if (raw is! Map<String, Object?> || raw['type'] != 'artists') return null;
  final String? id = _str(raw['id']);
  final Map<String, Object?> a = _attrs(raw);
  final String? name = _str(a['name']);
  if (id == null || name == null) return null;
  return MusicServerArtist(id: id, name: name, coverRef: _artworkTemplate(a));
}

/// artwork 模板（`…/{w}x{h}bb.jpg`，新版还有 `{c}` / `{f}`）→ 指定边长的地址。
Uri? appleMusicArtworkUri(
  String? template, {
  int size = kMusicServerCoverSize,
}) {
  final String? t = _str(template);
  if (t == null) return null;
  final String s = '$size';
  return Uri.tryParse(
    t
        .replaceAll('{w}', s)
        .replaceAll('{h}', s)
        .replaceAll('{c}', 'bb')
        .replaceAll('{f}', 'jpg'),
  );
}

List<Object?> _dataOf(Object? container) {
  if (container is! Map<String, Object?>) return const <Object?>[];
  final Object? d = container['data'];
  return d is List<Object?> ? d : const <Object?>[];
}

class AppleMusicCatalogClient implements MusicServerBrowser {
  AppleMusicCatalogClient({
    required AppleMusicTokenSource tokens,
    String? storefront,
    http.Client? client,
    Uri? apiBase,
  }) : _tokens = tokens,
       storefront = normalizeAppleMusicStorefront(storefront),
       _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null,
       _apiBase = apiBase ?? kAppleMusicApiBase;

  final AppleMusicTokenSource _tokens;
  final http.Client _client;
  final bool _ownsClient;
  final Uri _apiBase;

  /// 当前 storefront（两位小写）。
  final String storefront;

  /// 本实例列出过的曲目 → 预览地址（[streamFor] 只收本实例列出的曲目）。
  final Map<String, Uri> _previews = <String, Uri>{};

  @override
  MusicServerKind get kind => MusicServerKind.appleMusic;

  /// 同一 storefront = 同一来源（换区后播放项 uid / 页面状态不混）。
  @override
  String get serverId => 'apple-music:$storefront';

  @override
  String get displayName => 'Apple Music (${storefront.toUpperCase()})';

  // ---------------------------------------------------------------- 请求

  /// GET 并解析 JSON。[pathOrNext] 可以是 `catalog/...` 相对段，也可以是回包里的 `next`
  /// （以 `/v1/` 开头的绝对路径，自带 query）。401 时丢弃 token 重取一次。
  Future<Map<String, Object?>> _get(
    String pathOrNext, [
    Map<String, String> query = const <String, String>{},
  ]) async {
    final Uri uri;
    if (pathOrNext.startsWith('/')) {
      final Uri rel = Uri.parse(pathOrNext);
      uri = _apiBase.replace(
        path: rel.path,
        queryParameters: <String, String>{...rel.queryParameters, ...query},
      );
    } else {
      uri = _apiBase.replace(
        path: '/v1/catalog/$storefront/$pathOrNext',
        queryParameters: query.isEmpty ? null : query,
      );
    }
    for (int attempt = 0; ; attempt++) {
      final String token = await _tokens.token();
      final http.Response res = await _client
          .get(
            uri,
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(kAppleMusicRequestTimeout);
      if (res.statusCode == 401 && attempt == 0) {
        _tokens.invalidate();
        continue;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw AppleMusicApiException(res.statusCode, uri.path);
      }
      final Object? decoded = jsonDecode(
        utf8.decode(res.bodyBytes, allowMalformed: true),
      );
      if (decoded is! Map<String, Object?>) {
        throw AppleMusicApiException(res.statusCode, uri.path);
      }
      return decoded;
    }
  }

  List<MusicServerTrack> _keepPlayable(Iterable<Object?> raw) {
    final List<MusicServerTrack> out = <MusicServerTrack>[];
    for (final Object? r in raw) {
      final AppleMusicSong? s = parseAppleMusicSong(r);
      final Uri? preview = s?.previewUri;
      if (s == null || preview == null) continue;
      _previews[s.track.id] = preview;
      out.add(s.track);
    }
    return out;
  }

  // ---------------------------------------------------------------- 浏览

  /// 热门专辑榜（[sort] 无意义：榜单自有顺序）。
  @override
  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  }) async {
    final int n = limit.clamp(1, _kChartPageLimit);
    final Map<String, Object?> body = await _get('charts', <String, String>{
      'types': 'albums',
      'limit': '$n',
      'offset': '$offset',
    });
    final Object? results = body['results'];
    final Object? charts = results is Map<String, Object?>
        ? results['albums']
        : null;
    if (charts is! List<Object?> || charts.isEmpty) {
      return const MusicServerPage<MusicServerAlbum>(
        items: <MusicServerAlbum>[],
      );
    }
    final Object? chart = charts.first;
    final List<MusicServerAlbum> items = <MusicServerAlbum>[
      for (final Object? r in _dataOf(chart))
        if (parseAppleMusicAlbum(r) case final MusicServerAlbum a) a,
    ];
    final bool more =
        chart is Map<String, Object?> && _str(chart['next']) != null;
    return MusicServerPage<MusicServerAlbum>(
      items: items,
      nextOffset: more && items.isNotEmpty
          ? offset + _dataOf(chart).length
          : null,
    );
  }

  @override
  Future<List<MusicServerTrack>> albumTracks(String albumId) async {
    final Map<String, Object?> body = await _get(
      'albums/${Uri.encodeComponent(albumId)}',
      const <String, String>{'include': 'tracks'},
    );
    final List<Object?> data = _dataOf(body);
    if (data.isEmpty) return const <MusicServerTrack>[];
    final Object? album = data.first;
    final Object? rel = album is Map<String, Object?>
        ? album['relationships']
        : null;
    Object? tracks = rel is Map<String, Object?> ? rel['tracks'] : null;
    final List<Object?> raw = <Object?>[..._dataOf(tracks)];
    // 超过一页（> 300 首）时跟 `next` 翻完。
    for (int page = 0; page < _kMaxRelationshipPages; page++) {
      final String? next = tracks is Map<String, Object?>
          ? _str(tracks['next'])
          : null;
      if (next == null) break;
      tracks = await _get(next);
      raw.addAll(_dataOf(tracks));
    }
    final List<MusicServerTrack> out = _keepPlayable(raw);
    out.sort((MusicServerTrack a, MusicServerTrack b) {
      final int d = (a.discNo ?? 1).compareTo(b.discNo ?? 1);
      return d != 0 ? d : (a.trackNo ?? 0).compareTo(b.trackNo ?? 0);
    });
    return out;
  }

  /// 榜单专辑的艺人（按榜单顺序去重）。
  @override
  Future<List<MusicServerArtist>> listArtists() async {
    final MusicServerPage<MusicServerAlbum> top = await listAlbums(
      limit: _kChartPageLimit,
    );
    if (top.items.isEmpty) return const <MusicServerArtist>[];
    final Map<String, Object?> body = await _get('albums', <String, String>{
      'ids': top.items.map((MusicServerAlbum a) => a.id).join(','),
      'include': 'artists',
    });
    final Map<String, MusicServerArtist> out = <String, MusicServerArtist>{};
    for (final Object? album in _dataOf(body)) {
      final Object? rel = album is Map<String, Object?>
          ? album['relationships']
          : null;
      final Object? artists = rel is Map<String, Object?>
          ? rel['artists']
          : null;
      for (final Object? r in _dataOf(artists)) {
        final MusicServerArtist? a = parseAppleMusicArtist(r);
        if (a != null) out.putIfAbsent(a.id, () => a);
      }
    }
    return out.values.toList(growable: false);
  }

  @override
  Future<List<MusicServerAlbum>> artistAlbums(String artistId) async {
    final List<MusicServerAlbum> out = <MusicServerAlbum>[];
    Map<String, Object?> page = await _get(
      'artists/${Uri.encodeComponent(artistId)}/albums',
      const <String, String>{'limit': '$_kRelationshipPageLimit'},
    );
    for (int i = 0; ; i++) {
      for (final Object? r in _dataOf(page)) {
        final MusicServerAlbum? a = parseAppleMusicAlbum(r);
        if (a != null) out.add(a);
      }
      final String? next = _str(page['next']);
      if (next == null || i + 1 >= _kMaxRelationshipPages) break;
      page = await _get(next);
    }
    // 新的在前（与服务器艺人页一致：按年份降序，同年保持 Apple 顺序）。
    final List<MusicServerAlbum> sorted = <MusicServerAlbum>[...out];
    sorted.sort(
      (MusicServerAlbum a, MusicServerAlbum b) =>
          (b.year ?? 0).compareTo(a.year ?? 0),
    );
    return sorted;
  }

  @override
  Future<MusicServerSearchResult> search(String query, {int limit = 30}) async {
    final String q = query.trim();
    if (q.isEmpty) return const MusicServerSearchResult();
    final Map<String, Object?> body = await _get('search', <String, String>{
      'term': q,
      'types': 'songs,albums,artists',
      'limit': '${limit.clamp(1, _kSearchLimit)}',
    });
    final Object? results = body['results'];
    final Map<String, Object?> r = results is Map<String, Object?>
        ? results
        : const <String, Object?>{};
    return MusicServerSearchResult(
      albums: <MusicServerAlbum>[
        for (final Object? x in _dataOf(r['albums']))
          if (parseAppleMusicAlbum(x) case final MusicServerAlbum a) a,
      ],
      artists: <MusicServerArtist>[
        for (final Object? x in _dataOf(r['artists']))
          if (parseAppleMusicArtist(x) case final MusicServerArtist a) a,
      ],
      tracks: _keepPlayable(_dataOf(r['songs'])),
    );
  }

  // ---------------------------------------------------------------- 播放 / 封面

  /// 预览片段（约 30 秒 AAC）。码率上限无意义：预览只有一档。只收本实例列出过的曲目
  /// （列表层已滤掉无预览的），别处来的 id 抛 [StateError]。
  @override
  MusicServerStream streamFor(MusicServerTrack track, {int? maxBitrateKbps}) {
    final Uri? preview = _previews[track.id];
    if (preview == null) {
      throw StateError('Apple Music track ${track.id} has no preview');
    }
    return MusicServerStream(uri: preview, transcoded: false, codec: 'aac');
  }

  @override
  Uri? coverUri(String? coverRef, {int size = kMusicServerCoverSize}) =>
      appleMusicArtworkUri(coverRef, size: size);

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}
