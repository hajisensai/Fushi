/// Apple Music 资料库来源（MusicKit 方案 §3.6「用户私有数据」）：已登录用户自己资料库里的
/// 专辑 / 艺人 / 歌曲，`MusicServerBrowser` 的又一个 Apple Music 实现。
///
/// - 请求 `api.music.apple.com/v1/me/library/...`，要两枚 token：developer token（`Authorization`）
///   与 Music-User-Token（`Music-User-Token` 头）。两者必须是**同一套**：网页桥用 Worker 代签的
///   developer token 配 MusicKit JS 授权得到的用户 token；Apple 原生用系统为 App ID 生成的那对。
///   取用由 app 侧的 [AppleMusicUserCredentialsProvider] 负责（桥授权后才有）。
/// - 播放：资料库曲目经 `playParams.catalogId` 对到 catalog 曲目，走与 catalog 来源相同的整曲地址
///   （[appleMusicSongUri]）。没有 catalogId 的曲目（用户自己上传 / 已下架）MusicKit 单曲队列
///   放不了，不列出。
/// - 没有预览：资料库来源只在已登录且能整曲播放时出现。
///
/// 纯 Dart、不碰 Flutter（引擎纯度守卫）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

/// 访问用户私有数据的一对 token。
class AppleMusicUserCredentials {
  const AppleMusicUserCredentials({
    required this.developerToken,
    required this.userToken,
  });

  final String developerToken;
  final String userToken;
}

/// 取当前的一对 token；未登录 / 授权失效时抛（页面显示错误）。
typedef AppleMusicUserCredentialsProvider =
    Future<AppleMusicUserCredentials> Function();

/// 资料库列表单页上限（Apple 文档：library 资源 `limit` 最大 100）。
const int _kLibraryPageLimit = 100;

/// 资料库搜索单类上限（Apple 文档：library search `limit` 最大 25）。
const int _kLibrarySearchLimit = 25;

/// 关系 / 列表跟 `next` 最多翻几页（艺人表等，防异常回包无限翻页）。
const int _kMaxLibraryPages = 30;

Map<String, Object?> _attrs(Map<String, Object?> res) {
  final Object? a = res['attributes'];
  return a is Map<String, Object?> ? a : const <String, Object?>{};
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _int(Object? v) => v is num ? v.toInt() : null;

String? _artwork(Map<String, Object?> attrs) {
  final Object? art = attrs['artwork'];
  return art is Map<String, Object?> ? _str(art['url']) : null;
}

List<Object?> _dataOf(Object? container) {
  if (container is! Map<String, Object?>) return const <Object?>[];
  final Object? d = container['data'];
  return d is List<Object?> ? d : const <Object?>[];
}

/// 一首资料库曲目：曲目本身（id 是资料库 id）与它对应的 catalog id。
class AppleMusicLibrarySong {
  const AppleMusicLibrarySong({required this.track, required this.catalogId});

  final MusicServerTrack track;
  final String catalogId;
}

/// `library-songs` 资源 → 曲目。没有 `playParams.catalogId`（放不了）或缺 id / 名回 null。
AppleMusicLibrarySong? parseAppleMusicLibrarySong(Object? raw) {
  if (raw is! Map<String, Object?> || raw['type'] != 'library-songs') {
    return null;
  }
  final String? id = _str(raw['id']);
  final Map<String, Object?> a = _attrs(raw);
  final String? name = _str(a['name']);
  final Object? play = a['playParams'];
  final String? catalogId = play is Map<String, Object?>
      ? _str(play['catalogId'])
      : null;
  if (id == null || name == null || catalogId == null) return null;
  return AppleMusicLibrarySong(
    catalogId: catalogId,
    track: MusicServerTrack(
      id: id,
      title: name,
      artist: _str(a['artistName']),
      album: _str(a['albumName']),
      discNo: _int(a['discNumber']),
      trackNo: _int(a['trackNumber']),
      durationMs: _int(a['durationInMillis']),
      container: 'm4a',
      codec: 'aac',
      bitrateKbps: kAppleMusicFullTrackBitrateKbps,
      coverRef: _artwork(a),
    ),
  );
}

/// `library-albums` 资源 → 专辑。
MusicServerAlbum? parseAppleMusicLibraryAlbum(Object? raw) {
  if (raw is! Map<String, Object?> || raw['type'] != 'library-albums') {
    return null;
  }
  final String? id = _str(raw['id']);
  final Map<String, Object?> a = _attrs(raw);
  final String? name = _str(a['name']);
  if (id == null || name == null) return null;
  final String? date = _str(a['releaseDate']);
  return MusicServerAlbum(
    id: id,
    title: name,
    artist: _str(a['artistName']),
    year: date != null && date.length >= 4
        ? int.tryParse(date.substring(0, 4))
        : null,
    trackCount: _int(a['trackCount']),
    coverRef: _artwork(a),
  );
}

/// `library-artists` 资源 → 艺人。
MusicServerArtist? parseAppleMusicLibraryArtist(Object? raw) {
  if (raw is! Map<String, Object?> || raw['type'] != 'library-artists') {
    return null;
  }
  final String? id = _str(raw['id']);
  final String? name = _str(_attrs(raw)['name']);
  if (id == null || name == null) return null;
  return MusicServerArtist(id: id, name: name);
}

class AppleMusicLibraryClient implements MusicServerBrowser {
  AppleMusicLibraryClient({
    required AppleMusicUserCredentialsProvider credentials,
    String? displayName,
    http.Client? client,
    Uri? apiBase,
  }) : _credentials = credentials,
       _displayName = displayName,
       _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null,
       _apiBase = apiBase ?? kAppleMusicApiBase;

  final AppleMusicUserCredentialsProvider _credentials;
  final String? _displayName;
  final http.Client _client;
  final bool _ownsClient;
  final Uri _apiBase;

  /// 本实例列出过的资料库曲目 id → catalog id（[streamFor] 只收本实例列出的曲目）。
  final Map<String, String> _catalogIds = <String, String>{};

  @override
  MusicServerKind get kind => MusicServerKind.appleMusic;

  /// 资料库跟着 Apple ID 走、与 storefront 无关；与 catalog 来源（`apple-music:<sf>`）分开。
  @override
  String get serverId => 'apple-music-library';

  @override
  String get displayName => _displayName ?? 'Apple Music Library';

  // ---------------------------------------------------------------- 请求

  /// GET `me/library/...`（或回包里以 `/v1/` 开头的 `next`）并解析 JSON。
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
        path: '/v1/me/library/$pathOrNext',
        queryParameters: query.isEmpty ? null : query,
      );
    }
    final AppleMusicUserCredentials c = await _credentials();
    final http.Response res = await _client
        .get(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer ${c.developerToken}',
            'Music-User-Token': c.userToken,
            'Accept': 'application/json',
          },
        )
        .timeout(kAppleMusicRequestTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw AppleMusicApiException(res.statusCode, uri.path);
    }
    // 空资料库的某些端点回 204 / 空体。
    if (res.bodyBytes.isEmpty) return const <String, Object?>{};
    final Object? decoded = jsonDecode(
      utf8.decode(res.bodyBytes, allowMalformed: true),
    );
    if (decoded is! Map<String, Object?>) {
      throw AppleMusicApiException(res.statusCode, uri.path);
    }
    return decoded;
  }

  /// 跟 `next` 翻完（至多 [_kMaxLibraryPages] 页）。
  Future<List<Object?>> _getAll(String path) async {
    final List<Object?> out = <Object?>[];
    Map<String, Object?> page = await _get(path, const <String, String>{
      'limit': '$_kLibraryPageLimit',
    });
    for (int i = 0; ; i++) {
      out.addAll(_dataOf(page));
      final String? next = _str(page['next']);
      if (next == null || i + 1 >= _kMaxLibraryPages) break;
      page = await _get(next);
    }
    return out;
  }

  List<MusicServerTrack> _keepPlayable(Iterable<Object?> raw) {
    final List<MusicServerTrack> out = <MusicServerTrack>[];
    for (final Object? r in raw) {
      final AppleMusicLibrarySong? s = parseAppleMusicLibrarySong(r);
      if (s == null) continue;
      _catalogIds[s.track.id] = s.catalogId;
      out.add(s.track);
    }
    return out;
  }

  // ---------------------------------------------------------------- 浏览

  /// 资料库专辑（Apple 的顺序：最近加入在前；[sort] 不支持，按名排交给页面）。
  @override
  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  }) async {
    final int n = limit.clamp(1, _kLibraryPageLimit);
    final Map<String, Object?> body = await _get('albums', <String, String>{
      'limit': '$n',
      'offset': '$offset',
    });
    final List<Object?> data = _dataOf(body);
    final List<MusicServerAlbum> items = <MusicServerAlbum>[
      for (final Object? r in data)
        if (parseAppleMusicLibraryAlbum(r) case final MusicServerAlbum a) a,
    ];
    final Object? meta = body['meta'];
    final int? total = meta is Map<String, Object?>
        ? _int(meta['total'])
        : null;
    return MusicServerPage<MusicServerAlbum>(
      items: items,
      total: total,
      nextOffset: _str(body['next']) != null && data.isNotEmpty
          ? offset + data.length
          : null,
    );
  }

  @override
  Future<List<MusicServerTrack>> albumTracks(String albumId) async {
    final List<MusicServerTrack> out = _keepPlayable(
      await _getAll('albums/${Uri.encodeComponent(albumId)}/tracks'),
    );
    out.sort((MusicServerTrack a, MusicServerTrack b) {
      final int d = (a.discNo ?? 1).compareTo(b.discNo ?? 1);
      return d != 0 ? d : (a.trackNo ?? 0).compareTo(b.trackNo ?? 0);
    });
    return <MusicServerTrack>[
      for (final MusicServerTrack t in out)
        MusicServerTrack(
          id: t.id,
          title: t.title,
          artist: t.artist,
          album: t.album,
          albumId: albumId,
          discNo: t.discNo,
          trackNo: t.trackNo,
          durationMs: t.durationMs,
          container: t.container,
          codec: t.codec,
          bitrateKbps: t.bitrateKbps,
          coverRef: t.coverRef,
        ),
    ];
  }

  @override
  Future<List<MusicServerArtist>> listArtists() async {
    final List<MusicServerArtist> out = <MusicServerArtist>[
      for (final Object? r in await _getAll('artists'))
        if (parseAppleMusicLibraryArtist(r) case final MusicServerArtist a) a,
    ];
    out.sort(
      (MusicServerArtist a, MusicServerArtist b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return out;
  }

  @override
  Future<List<MusicServerAlbum>> artistAlbums(String artistId) async =>
      <MusicServerAlbum>[
        for (final Object? r in await _getAll(
          'artists/${Uri.encodeComponent(artistId)}/albums',
        ))
          if (parseAppleMusicLibraryAlbum(r) case final MusicServerAlbum a) a,
      ];

  @override
  Future<MusicServerSearchResult> search(String query, {int limit = 30}) async {
    final String q = query.trim();
    if (q.isEmpty) return const MusicServerSearchResult();
    final Map<String, Object?> body = await _get('search', <String, String>{
      'term': q,
      'types': 'library-songs,library-albums,library-artists',
      'limit': '${limit.clamp(1, _kLibrarySearchLimit)}',
    });
    final Object? results = body['results'];
    final Map<String, Object?> r = results is Map<String, Object?>
        ? results
        : const <String, Object?>{};
    return MusicServerSearchResult(
      albums: <MusicServerAlbum>[
        for (final Object? x in _dataOf(r['library-albums']))
          if (parseAppleMusicLibraryAlbum(x) case final MusicServerAlbum a) a,
      ],
      artists: <MusicServerArtist>[
        for (final Object? x in _dataOf(r['library-artists']))
          if (parseAppleMusicLibraryArtist(x) case final MusicServerArtist a) a,
      ],
      tracks: _keepPlayable(_dataOf(r['library-songs'])),
    );
  }

  // ---------------------------------------------------------------- 播放 / 封面

  /// 整曲地址（按 catalog id）。只收本实例列出过的曲目，别处来的 id 抛 [StateError]。
  @override
  MusicServerStream streamFor(MusicServerTrack track, {int? maxBitrateKbps}) {
    final String? catalogId = _catalogIds[track.id];
    if (catalogId == null) {
      throw StateError('Apple Music library track ${track.id} is not playable');
    }
    return MusicServerStream(
      uri: appleMusicSongUri(catalogId),
      transcoded: false,
      codec: 'aac',
      bitrateKbps: kAppleMusicFullTrackBitrateKbps,
    );
  }

  @override
  Uri? coverUri(String? coverRef, {int size = kMusicServerCoverSize}) =>
      appleMusicArtworkUri(coverRef, size: size);

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}
