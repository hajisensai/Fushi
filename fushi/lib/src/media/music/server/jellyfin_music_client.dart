/// Jellyfin（含 Emby / 飞牛等兼容层）音乐库的浏览器（音乐方案 §13 P5「服务器曲库」）。
///
/// **凭据复用视频的媒体服务器配置**（`JellyfinServerConfig`，`SyncRepository.getMediaServers`
/// 里那份）：同一台 Jellyfin、同一个账号、同一个令牌与 DeviceId，不再让用户登录第二次；传输
/// 复用 `JellyfinApi`（认证头双发、15 s 响应超时、错误文本凭据脱敏）。视频浏览器在实现侧
/// 滤掉的音乐库在这里用。
library;

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/music/server/jellyfin_music_parse.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';

import 'package:fushi/src/sync/jellyfin_video_client.dart';

class JellyfinMusicClient
    implements MusicServerBrowser, MusicServerPlaylistEditing {
  JellyfinMusicClient(this.config, {http.Client? httpClient})
    : _api = JellyfinApi(
        serverUrl: config.effectiveServerUrl,
        accessToken: config.accessToken,
        deviceId: config.deviceId,
        client: httpClient,
      );

  final JellyfinServerConfig config;
  final JellyfinApi _api;

  static const String _albumFields = 'ChildCount,ProductionYear,AlbumArtist';
  static const String _trackFields = 'MediaStreams,MediaSources,Container';
  static const String _playlistFields = 'ChildCount,Overview,CanDelete';

  String get _userPath => '/Users/${config.userId}';

  @override
  MusicServerKind get kind => MusicServerKind.jellyfin;

  @override
  String get serverId => config.sourceId;

  @override
  String get displayName => (config.serverName?.trim().isNotEmpty ?? false)
      ? config.serverName!.trim()
      : Uri.tryParse(config.serverUrl)?.host ?? config.serverUrl;

  /// 音乐媒体库的视图 id（`CollectionType == music`）；没有音乐库时为空。
  Future<List<String>> musicLibraryIds() async =>
      jellyfinMusicLibraryIds(await _api.getDecodedJson('$_userPath/Views'));

  @override
  Future<MusicServerPage<MusicServerAlbum>> listAlbums({
    int offset = 0,
    int limit = kMusicServerPageSize,
    MusicServerAlbumSort sort = MusicServerAlbumSort.name,
  }) async {
    final ({String sortBy, String sortOrder}) s = jellyfinAlbumSort(sort);
    final Object? json = await _api
        .getDecodedJson('$_userPath/Items', <String, String>{
          'IncludeItemTypes': 'MusicAlbum',
          'Recursive': 'true',
          'SortBy': s.sortBy,
          'SortOrder': s.sortOrder,
          'StartIndex': '$offset',
          'Limit': '$limit',
          'Fields': _albumFields,
          'EnableImageTypes': 'Primary',
        });
    final List<Map<String, Object?>> rows = jellyfinItemsOf(json);
    final int? total = jellyfinTotalOf(json);
    return MusicServerPage<MusicServerAlbum>(
      items: <MusicServerAlbum>[
        for (final Map<String, Object?> r in rows) ?parseJellyfinMusicAlbum(r),
      ],
      nextOffset: _nextOffset(offset, limit, rows.length, total),
      total: total,
    );
  }

  /// 翻页认服务器行数（解析失败 / 过滤丢掉的行不影响偏移）。总数缺失时满页即还有。
  static int? _nextOffset(int offset, int limit, int rowCount, int? total) {
    if (rowCount == 0) return null;
    final int next = offset + rowCount;
    if (total != null) return next < total ? next : null;
    return rowCount >= limit ? next : null;
  }

  @override
  Future<List<MusicServerTrack>> albumTracks(String albumId) async {
    final Object? json = await _api
        .getDecodedJson('$_userPath/Items', <String, String>{
          'ParentId': albumId,
          'IncludeItemTypes': 'Audio',
          'Recursive': 'true',
          'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
          'Fields': _trackFields,
        });
    return sortMusicServerTracks(<MusicServerTrack>[
      for (final Map<String, Object?> r in jellyfinItemsOf(json))
        ?parseJellyfinMusicTrack(r),
    ]);
  }

  @override
  Future<List<MusicServerArtist>> listArtists() async {
    final Object? json = await _api
        .getDecodedJson('/Artists/AlbumArtists', <String, String>{
          'UserId': config.userId,
          'SortBy': 'SortName',
          'SortOrder': 'Ascending',
          'Fields': 'ChildCount',
        });
    return <MusicServerArtist>[
      for (final Map<String, Object?> r in jellyfinItemsOf(json))
        ?parseJellyfinMusicArtist(r),
    ];
  }

  @override
  Future<List<MusicServerAlbum>> artistAlbums(String artistId) async {
    final Object? json = await _api
        .getDecodedJson('$_userPath/Items', <String, String>{
          'IncludeItemTypes': 'MusicAlbum',
          'Recursive': 'true',
          'AlbumArtistIds': artistId,
          'SortBy': 'ProductionYear,SortName',
          'SortOrder': 'Descending',
          'Fields': _albumFields,
        });
    return <MusicServerAlbum>[
      for (final Map<String, Object?> r in jellyfinItemsOf(json))
        ?parseJellyfinMusicAlbum(r),
    ];
  }

  @override
  Future<MusicServerPage<MusicServerPlaylist>> listPlaylists({
    int offset = 0,
    int limit = kMusicServerPageSize,
  }) async {
    final Object? json = await _api.getDecodedJson(
      '$_userPath/Items',
      <String, String>{
        'IncludeItemTypes': 'Playlist',
        // 只要音频歌单；不认这个参数的兼容层由解析侧按 MediaType 再滤一次。
        'MediaTypes': 'Audio',
        'Recursive': 'true',
        'SortBy': 'SortName',
        'SortOrder': 'Ascending',
        'StartIndex': '$offset',
        'Limit': '$limit',
        'Fields': _playlistFields,
        'EnableImageTypes': 'Primary',
      },
    );
    final List<Map<String, Object?>> rows = jellyfinItemsOf(json);
    final int? total = jellyfinTotalOf(json);
    return MusicServerPage<MusicServerPlaylist>(
      items: <MusicServerPlaylist>[
        for (final Map<String, Object?> r in rows)
          ?parseJellyfinMusicPlaylist(r),
      ],
      nextOffset: _nextOffset(offset, limit, rows.length, total),
      total: total,
    );
  }

  @override
  Future<List<MusicServerTrack>> playlistTracks(String playlistId) async {
    // `/Playlists/{id}/Items` 按歌单自身顺序返回（不传 SortBy，Jellyfin / Emby 都如此）。
    final Object? json = await _api.getDecodedJson(
      '/Playlists/${Uri.encodeComponent(playlistId)}/Items',
      <String, String>{
        'UserId': config.userId,
        // Path：导出 .m3u8 用（服务器只对有权限的账号报）。
        'Fields': '$_trackFields,Path',
      },
    );
    return parseJellyfinPlaylistTracks(json);
  }

  // ---------------------------------------------------------------------------
  // 歌单编辑（[MusicServerPlaylistEditing]）。参数同时按查询串发（Emby 与旧版 Jellyfin
  // 只认查询串），新建再带一份 JSON 体（新版 Jellyfin 优先读体）。
  // ---------------------------------------------------------------------------

  String _playlistPath(String playlistId) =>
      '/Playlists/${Uri.encodeComponent(playlistId)}';

  @override
  Future<MusicServerPlaylist> createPlaylist(
    String name, {
    List<String> trackIds = const <String>[],
  }) async {
    final Object? json = await _api.sendJson(
      'POST',
      '/Playlists',
      query: <String, String>{
        'Name': name,
        'UserId': config.userId,
        'MediaType': 'Audio',
        if (trackIds.isNotEmpty) 'Ids': trackIds.join(','),
      },
      body: <String, Object?>{
        'Name': name,
        'UserId': config.userId,
        'MediaType': 'Audio',
        'Ids': trackIds,
      },
    );
    final String? id = json is Map<String, Object?>
        ? json['Id'] as String?
        : null;
    if (id == null || id.isEmpty) {
      throw StateError('server did not return the new playlist id');
    }
    return MusicServerPlaylist(
      id: id,
      title: name,
      trackCount: trackIds.length,
      editable: true,
    );
  }

  @override
  Future<void> addToPlaylist(String playlistId, List<String> trackIds) async {
    if (trackIds.isEmpty) return;
    await _api.sendJson(
      'POST',
      '${_playlistPath(playlistId)}/Items',
      query: <String, String>{
        'Ids': trackIds.join(','),
        'UserId': config.userId,
      },
    );
  }

  @override
  Future<void> removeFromPlaylist(
    String playlistId,
    List<String> entryIds,
  ) async {
    if (entryIds.isEmpty) return;
    await _api.sendJson(
      'DELETE',
      '${_playlistPath(playlistId)}/Items',
      query: <String, String>{'EntryIds': entryIds.join(',')},
    );
  }

  @override
  Future<void> movePlaylistEntry(
    String playlistId,
    String entryId,
    int newIndex,
  ) async {
    if (!await _hasJellyfin1010MoveBug()) {
      await _sendMove(playlistId, entryId, newIndex);
      return;
    }
    final List<String> order = <String>[
      for (final MusicServerTrack t in await playlistTracks(playlistId))
        t.playlistEntryId ?? '',
    ];
    final int from = order.indexOf(entryId);
    if (from < 0) {
      throw StateError('playlist entry $entryId is no longer in the playlist');
    }
    for (final (String id, int index) in jellyfin1010MoveSteps(
      order,
      from,
      newIndex.clamp(0, order.length - 1),
    )) {
      await _sendMove(playlistId, id, index);
    }
  }

  Future<void> _sendMove(String playlistId, String entryId, int index) =>
      _api.sendJson(
        'POST',
        '${_playlistPath(playlistId)}/Items/${Uri.encodeComponent(entryId)}'
            '/Move/$index',
      );

  bool? _moveBug;

  /// 临时兼容层：Jellyfin 10.10.x 的 `Move` 落点算错（往下挪多一格、挪到第 0 位落在第 1
  /// 位；10.9 及更早、10.11 起都正确）。只认服务器自报 `Jellyfin` + `10.10.`；Emby / 飞牛
  /// 等兼容层不受影响。网络失败照常抛、不缓存。不再支持 10.10 时连同
  /// [jellyfin1010MoveSteps] 一起删。
  Future<bool> _hasJellyfin1010MoveBug() async {
    final bool? cached = _moveBug;
    if (cached != null) return cached;
    Object? info;
    try {
      info = await _api.getDecodedJson('/System/Info/Public');
    } on FormatException {
      info = null; // 不回 JSON 的兼容层：不是 Jellyfin。
    }
    final bool bug =
        info is Map<String, Object?> &&
        ((info['ProductName'] as String?) ?? '').toLowerCase().contains(
          'jellyfin',
        ) &&
        ((info['Version'] as String?) ?? '').startsWith('10.10.');
    return _moveBug = bug;
  }

  @override
  Future<void> renamePlaylist(String playlistId, String name) => _api.sendJson(
    'POST',
    _playlistPath(playlistId),
    body: <String, Object?>{'Name': name},
  );

  @override
  Future<void> deletePlaylist(String playlistId) =>
      _api.sendJson('DELETE', '/Items/${Uri.encodeComponent(playlistId)}');

  @override
  Future<MusicServerSearchResult> search(String query, {int limit = 30}) async {
    final String q = query.trim();
    if (q.isEmpty) return const MusicServerSearchResult();
    // 单值 IncludeItemTypes 各一轮：兼容层对多值的语义不一（视频侧 BUG-2254 同一结论）。
    Future<List<Map<String, Object?>>> items(
      String type,
      String fields,
    ) async => jellyfinItemsOf(
      await _api.getDecodedJson('$_userPath/Items', <String, String>{
        'SearchTerm': q,
        'IncludeItemTypes': type,
        'Recursive': 'true',
        'Limit': '$limit',
        'Fields': fields,
      }),
    );
    final List<Map<String, Object?>> albums = await items(
      'MusicAlbum',
      _albumFields,
    );
    final List<Map<String, Object?>> tracks = await items(
      'Audio',
      _trackFields,
    );
    final List<Map<String, Object?>> playlists = await items(
      'Playlist',
      _playlistFields,
    );
    final List<Map<String, Object?>> artists = jellyfinItemsOf(
      await _api.getDecodedJson('/Artists', <String, String>{
        'SearchTerm': q,
        'UserId': config.userId,
        'Limit': '$limit',
      }),
    );
    return MusicServerSearchResult(
      albums: <MusicServerAlbum>[
        for (final Map<String, Object?> r in albums)
          ?parseJellyfinMusicAlbum(r),
      ],
      artists: <MusicServerArtist>[
        for (final Map<String, Object?> r in artists)
          ?parseJellyfinMusicArtist(r),
      ],
      tracks: <MusicServerTrack>[
        for (final Map<String, Object?> r in tracks)
          ?parseJellyfinMusicTrack(r),
      ],
      playlists: <MusicServerPlaylist>[
        for (final Map<String, Object?> r in playlists)
          ?parseJellyfinMusicPlaylist(r),
      ],
    );
  }

  @override
  MusicServerStream streamFor(MusicServerTrack track, {int? maxBitrateKbps}) {
    final ({String path, Map<String, String> query, bool transcoded}) req =
        jellyfinMusicStreamRequest(
          trackId: track.id,
          userId: config.userId,
          deviceId: config.deviceId,
          token: config.accessToken,
          maxBitrateKbps: maxBitrateKbps,
        );
    return MusicServerStream(
      uri: Uri.parse(
        '${config.effectiveServerUrl}${req.path}',
      ).replace(queryParameters: req.query),
      transcoded: req.transcoded,
      codec: req.transcoded ? 'opus' : track.codec,
      bitrateKbps: req.transcoded ? maxBitrateKbps : track.bitrateKbps,
    );
  }

  @override
  Uri? coverUri(String? coverRef, {int size = kMusicServerCoverSize}) {
    if (coverRef == null) return null;
    return Uri.parse(
      '${config.effectiveServerUrl}/Items/$coverRef/Images/Primary',
    ).replace(
      queryParameters: <String, String>{
        'maxWidth': '$size',
        'quality': '90',
        'api_key': config.accessToken,
      },
    );
  }

  @override
  void close() {}
}

/// 在 Jellyfin 10.10.x 上把 [order] 里第 [from] 条挪到第 [to] 位所需的 `Move` 请求序列
/// （条目 id, 发给服务器的下标）。
///
/// 10.10 的算法（全部可见时）：先取「前一项」`prior = n > from ? n : max(n - 1, 0)`，
/// 在**移除前**的列表里得出插入点 `prior + 1`，再移除、插入（`n` 到末尾则追加）。于是
/// 往上挪到 `t ≥ 1`、挪到末尾都准；往下挪到中间要少报一格；落到下一格和第 0 位单步做不到，
/// 用两三步凑出来。
List<(String, int)> jellyfin1010MoveSteps(
  List<String> order,
  int from,
  int to,
) {
  final int last = order.length - 1;
  if (from == to) return const <(String, int)>[];
  final String x = order[from];
  if (to > from) {
    if (to == last) return <(String, int)>[(x, to)];
    if (to >= from + 2) return <(String, int)>[(x, to - 1)];
    // 往下一格：等于让下一条往上一格；from 为 0 时那一步做不到，先挪远再挪回。
    if (from >= 1) return <(String, int)>[(order[from + 1], from)];
    return <(String, int)>[(x, 1), (x, 1)];
  }
  if (to >= 1) return <(String, int)>[(x, to)];
  // 挪到第 0 位：把 x 放到第 1 位，再把原第一条挪到第 1 位之后。
  final String first = order[0];
  if (order.length == 2) return <(String, int)>[(first, 1)];
  return <(String, int)>[if (from > 1) (x, 1), (first, 1), (first, 1)];
}
