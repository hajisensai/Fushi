/// Apple Music 资料库来源（MusicKit 方案 §3.6「用户私有数据」）：已登录用户自己资料库里的
/// 专辑 / 艺人 / 歌曲 / 歌单，`MusicServerBrowser` 的又一个 Apple Music 实现；外加资料库写操作
/// （新建歌单、往自己的歌单里加歌）。
///
/// - 请求 `api.music.apple.com/v1/me/library/...`，要两枚 token（[AppleMusicUserApi]）。
/// - 播放：资料库曲目经 `playParams.catalogId` 对到 catalog 曲目，走与 catalog 来源相同的整曲地址
///   （[appleMusicSongUri]）。没有 catalogId 的曲目（用户自己上传 / 已下架）MusicKit 单曲队列
///   放不了，不列出。
/// - 没有预览：资料库来源只在已登录且能整曲播放时出现。
/// - Apple Music API 不支持从歌单删歌、删歌单、改歌单名（公开 API 没有这些端点），所以这里没有。
///
/// 纯 Dart、不碰 Flutter（引擎纯度守卫）。
library;

import 'dart:async';

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_items.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_user_api.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:http/http.dart' as http;

export 'package:fushi_engine/media/music/apple_music/apple_music_user_api.dart'
    show AppleMusicUserCredentials, AppleMusicUserCredentialsProvider;

/// 资料库列表单页上限（Apple 文档：library 资源 `limit` 最大 100）。
const int _kLibraryPageLimit = 100;

/// 资料库搜索单类上限（Apple 文档：library search `limit` 最大 25）。
const int _kLibrarySearchLimit = 25;

/// 「最近加入」单页上限（Apple 文档：recently-added `limit` 最大 25）。
const int _kRecentlyAddedLimit = 25;

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
  }) : _api = AppleMusicUserApi(
         credentials: credentials,
         client: client,
         apiBase: apiBase,
       ),
       _displayName = displayName;

  final AppleMusicUserApi _api;
  final String? _displayName;

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

  static String _lib(String rest) => '/v1/me/library/$rest';

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

  /// 本实例列出过的资料库曲目对应的 catalog id（评分 / 加歌单 / 电台要 catalog id）；没列出过回 null。
  String? catalogIdOf(String libraryTrackId) => _catalogIds[libraryTrackId];

  /// 一页资料库资源：解析 `data`、`meta.total`，有 `next` 才给下一页 offset。
  Future<MusicServerPage<T>> _page<T>(
    String path,
    int offset,
    int limit,
    T? Function(Object?) parse,
  ) async {
    final int n = limit.clamp(1, _kLibraryPageLimit);
    final Map<String, Object?> body = await _api.get(
      _lib(path),
      <String, String>{'limit': '$n', 'offset': '$offset'},
    );
    final List<Object?> data = appleMusicDataOf(body);
    final List<T> items = <T>[
      for (final Object? r in data)
        if (parse(r) case final T x) x,
    ];
    final Object? meta = body['meta'];
    final int? total = meta is Map<String, Object?>
        ? _int(meta['total'])
        : null;
    return MusicServerPage<T>(
      items: items,
      total: total,
      nextOffset: _str(body['next']) != null && data.isNotEmpty
          ? offset + data.length
          : null,
    );
  }

  // ---------------------------------------------------------------- 浏览

  /// 资料库专辑（Apple 的顺序：最近加入在前；[sort] 不支持，按名排交给页面）。
  @override
  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  }) => _page<MusicServerAlbum>(
    'albums',
    offset,
    limit,
    parseAppleMusicLibraryAlbum,
  );

  @override
  Future<List<MusicServerTrack>> albumTracks(String albumId) async {
    final List<MusicServerTrack> out = _keepPlayable(
      await _api.getAll(
        _lib('albums/${Uri.encodeComponent(albumId)}/tracks'),
        query: const <String, String>{'limit': '$_kLibraryPageLimit'},
      ),
    );
    out.sort((MusicServerTrack a, MusicServerTrack b) {
      final int d = (a.discNo ?? 1).compareTo(b.discNo ?? 1);
      return d != 0 ? d : (a.trackNo ?? 0).compareTo(b.trackNo ?? 0);
    });
    return <MusicServerTrack>[
      for (final MusicServerTrack t in out)
        appleMusicTrackWithId(t, t.id, albumId: albumId),
    ];
  }

  @override
  Future<List<MusicServerArtist>> listArtists() async {
    final List<MusicServerArtist> out = <MusicServerArtist>[
      for (final Object? r in await _api.getAll(
        _lib('artists'),
        query: const <String, String>{'limit': '$_kLibraryPageLimit'},
      ))
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
        for (final Object? r in await _api.getAll(
          _lib('artists/${Uri.encodeComponent(artistId)}/albums'),
          query: const <String, String>{'limit': '$_kLibraryPageLimit'},
        ))
          if (parseAppleMusicLibraryAlbum(r) case final MusicServerAlbum a) a,
      ];

  /// 资料库歌单（Apple 的顺序：最近改动在前）。
  @override
  Future<MusicServerPage<MusicServerPlaylist>> listPlaylists({
    int offset = 0,
    int limit = kMusicServerPageSize,
  }) => _page<MusicServerPlaylist>(
    'playlists',
    offset,
    limit,
    parseAppleMusicPlaylist,
  );

  /// 资料库歌单曲目（歌单顺序）。
  @override
  Future<List<MusicServerTrack>> playlistTracks(String playlistId) async =>
      _keepPlayable(
        await _api.getAll(
          _lib('playlists/${Uri.encodeComponent(playlistId)}/tracks'),
          query: const <String, String>{'limit': '$_kLibraryPageLimit'},
        ),
      );

  /// 资料库里的全部歌曲（一页；Apple 的顺序）。
  Future<MusicServerPage<MusicServerTrack>> listSongs({
    int offset = 0,
    int limit = kMusicServerPageSize,
  }) async {
    final MusicServerPage<MusicServerTrack> page =
        await _page<MusicServerTrack>(
          'songs',
          offset,
          limit,
          (Object? r) => _keepPlayable(<Object?>[r]).firstOrNull,
        );
    return page;
  }

  /// 最近加入资料库的专辑 / 歌单 / 电台（混排；资料库与 catalog 资源都有）。
  Future<List<AppleMusicItem>> recentlyAdded({int limit = 50}) async {
    final List<Object?> raw = <Object?>[];
    int offset = 0;
    while (raw.length < limit) {
      final Map<String, Object?> body = await _api.get(
        _lib('recently-added'),
        <String, String>{'limit': '$_kRecentlyAddedLimit', 'offset': '$offset'},
      );
      final List<Object?> data = appleMusicDataOf(body);
      raw.addAll(data);
      if (data.isEmpty || _str(body['next']) == null) break;
      offset += data.length;
    }
    return parseAppleMusicItems(raw.take(limit));
  }

  @override
  Future<MusicServerSearchResult> search(String query, {int limit = 30}) async {
    final String q = query.trim();
    if (q.isEmpty) return const MusicServerSearchResult();
    final Map<String, Object?> body = await _api
        .get(_lib('search'), <String, String>{
          'term': q,
          'types':
              'library-songs,library-albums,library-artists,library-playlists',
          'limit': '${limit.clamp(1, _kLibrarySearchLimit)}',
        });
    final Object? results = body['results'];
    final Map<String, Object?> r = results is Map<String, Object?>
        ? results
        : const <String, Object?>{};
    return MusicServerSearchResult(
      albums: <MusicServerAlbum>[
        for (final Object? x in appleMusicDataOf(r['library-albums']))
          if (parseAppleMusicLibraryAlbum(x) case final MusicServerAlbum a) a,
      ],
      artists: <MusicServerArtist>[
        for (final Object? x in appleMusicDataOf(r['library-artists']))
          if (parseAppleMusicLibraryArtist(x) case final MusicServerArtist a) a,
      ],
      tracks: _keepPlayable(appleMusicDataOf(r['library-songs'])),
      playlists: <MusicServerPlaylist>[
        for (final Object? x in appleMusicDataOf(r['library-playlists']))
          if (parseAppleMusicPlaylist(x) case final MusicServerPlaylist p) p,
      ],
    );
  }

  // ---------------------------------------------------------------- 写操作

  /// 新建资料库歌单（可带初始曲目，按 catalog id）。回新歌单。
  Future<MusicServerPlaylist> createPlaylist(
    String name, {
    String? description,
    List<String> catalogSongIds = const <String>[],
  }) async {
    final String n = name.trim();
    if (n.isEmpty) throw ArgumentError.value(name, 'name', 'empty');
    final Map<String, Object?> body = await _api.send(
      'POST',
      _lib('playlists'),
      body: <String, Object?>{
        'attributes': <String, Object?>{
          'name': n,
          if (description != null && description.trim().isNotEmpty)
            'description': description.trim(),
        },
        if (catalogSongIds.isNotEmpty)
          'relationships': <String, Object?>{
            'tracks': <String, Object?>{'data': _songRefs(catalogSongIds)},
          },
      },
    );
    final MusicServerPlaylist? created = appleMusicDataOf(
      body,
    ).map(parseAppleMusicPlaylist).nonNulls.firstOrNull;
    // Apple 偶尔回 201 空体：按请求内容回一个最小歌单（id 未知时页面重读列表即可）。
    return created ??
        MusicServerPlaylist(
          id: '',
          title: n,
          description: description,
          editable: true,
          trackCount: catalogSongIds.length,
        );
  }

  /// 往自己的资料库歌单里追加曲目（按 catalog id，追加在末尾）。
  Future<void> addToPlaylist(
    String playlistId,
    List<String> catalogSongIds,
  ) async {
    if (catalogSongIds.isEmpty) return;
    await _api.send(
      'POST',
      _lib('playlists/${Uri.encodeComponent(playlistId)}/tracks'),
      body: <String, Object?>{'data': _songRefs(catalogSongIds)},
    );
  }

  static List<Map<String, String>> _songRefs(
    List<String> ids,
  ) => <Map<String, String>>[
    for (final String id in ids) <String, String>{'id': id, 'type': 'songs'},
  ];

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
  void close() => _api.close();
}
