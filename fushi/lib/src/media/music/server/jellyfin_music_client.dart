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
import 'package:fushi_engine/media/music/server/music_server_loudness.dart';

import 'package:fushi/src/sync/jellyfin_video_client.dart';

class JellyfinMusicClient
    implements
        MusicServerBrowser,
        MusicServerPlaylistEditing,
        MusicServerDownloading,
        MusicServerFavoriteEditing,
        MusicServerDiscovery,
        MusicServerInstantMix,
        MusicServerPlaybackReporting,
        MusicServerPlayMarking,
        MusicServerLyricsProvider,
        MusicServerLoudnessLookup {
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

  /// 从音乐库 / 歌单还原的曲目（行里不存响度）起播时补查：一次 `Items?Ids=<曲目>,<专辑>`
  /// 同时取曲目与专辑条目的 `NormalizationGain`（媒体库没开 LUFS 扫描时都没有，回 null）。
  @override
  Future<MusicServerLoudness?> loudnessOf(MusicServerTrackRef track) async {
    final String? albumId = track.albumId;
    final Object? json = await _api.getDecodedJson(
      '$_userPath/Items',
      <String, String>{
        'Ids': <String>[track.trackId, ?albumId].join(','),
        'EnableImages': 'false',
        'EnableUserData': 'false',
      },
    );
    return jellyfinLoudnessOfItems(
      jellyfinItemsOf(json),
      trackId: track.trackId,
      albumId: albumId,
    );
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

  /// 原文件（`/Items/{id}/Download`：服务器上存的那份字节，支持 Range 续传；账号没有
  /// 「允许下载媒体」权限时服务器回 401 / 403）。
  @override
  MusicServerDownloadSource downloadSourceFor(
    MusicServerTrack track,
  ) => MusicServerDownloadSource(
    uri: Uri.parse(
      '${config.effectiveServerUrl}/Items/${Uri.encodeComponent(track.id)}/Download',
    ).replace(queryParameters: <String, String>{'api_key': config.accessToken}),
    extensionHint: (track.container ?? track.codec)?.toLowerCase(),
  );

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

  // ---------------------------------------------------------------------------
  // 收藏（[MusicServerFavoriteEditing]）：`/Users/{uid}/FavoriteItems/{id}`（Emby 与
  // Jellyfin 各版本都认；10.9 起的 `/UserFavoriteItems` 旧版与兼容层不认）。
  // ---------------------------------------------------------------------------

  @override
  Future<void> setFavorite(
    MusicServerItemKind kind,
    String id, {
    required bool favorite,
  }) => _api.sendJson(
    favorite ? 'POST' : 'DELETE',
    '$_userPath/FavoriteItems/${Uri.encodeComponent(id)}',
  );

  @override
  Future<bool?> trackFavorite(String trackId) async {
    final List<Map<String, Object?>> items = jellyfinItemsOf(
      await _api.getDecodedJson('$_userPath/Items', <String, String>{
        'Ids': trackId,
        'EnableImages': 'false',
        'EnableUserData': 'true',
      }),
    );
    if (items.isEmpty) return null;
    return jellyfinIsFavorite(items.first) ?? false;
  }

  @override
  Future<MusicServerItems> listFavorites({
    int limit = kMusicServerPageSize,
  }) async {
    Future<List<Map<String, Object?>>> favs(String type, String fields) async =>
        jellyfinItemsOf(
          await _api.getDecodedJson('$_userPath/Items', <String, String>{
            'IncludeItemTypes': type,
            'Recursive': 'true',
            'Filters': 'IsFavorite',
            'SortBy': 'SortName',
            'SortOrder': 'Ascending',
            'Limit': '$limit',
            'Fields': fields,
          }),
        );
    final List<Map<String, Object?>> albums = await favs(
      'MusicAlbum',
      _albumFields,
    );
    final List<Map<String, Object?>> artists = await favs(
      'MusicArtist',
      'ChildCount',
    );
    final List<Map<String, Object?>> tracks = await favs('Audio', _trackFields);
    return MusicServerItems(
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
    );
  }

  // ---------------------------------------------------------------------------
  // 流派 / 最近添加 / 播放统计（[MusicServerDiscovery]）。播放统计是服务器按本账号
  // 记的（`UserData.PlayCount` / `LastPlayedDate`，本机播放经 [reportPlaybackStarted]
  // 计入）。
  // ---------------------------------------------------------------------------

  @override
  Future<List<MusicServerGenre>> listGenres() async {
    final Object? json = await _api
        .getDecodedJson('/MusicGenres', <String, String>{
          'UserId': config.userId,
          'SortBy': 'SortName',
          'SortOrder': 'Ascending',
          'EnableImageTypes': 'Primary',
        });
    return <MusicServerGenre>[
      for (final Map<String, Object?> r in jellyfinItemsOf(json))
        ?parseJellyfinMusicGenre(r),
    ];
  }

  @override
  Future<List<MusicServerAlbum>> genreAlbums(
    MusicServerGenre genre, {
    int limit = kMusicServerPageSize,
  }) async => _albums(<String, String>{
    'GenreIds': genre.id,
    'SortBy': 'SortName',
    'SortOrder': 'Ascending',
    'Limit': '$limit',
  });

  @override
  Future<List<MusicServerTrack>> genreTracks(
    MusicServerGenre genre, {
    int limit = kMusicServerPageSize,
  }) => _tracks(<String, String>{
    'GenreIds': genre.id,
    'SortBy': 'AlbumArtist,Album,ParentIndexNumber,IndexNumber,SortName',
    'SortOrder': 'Ascending',
    'Limit': '$limit',
  });

  @override
  Future<List<MusicServerAlbum>> recentlyAddedAlbums({int limit = 30}) =>
      _albums(<String, String>{
        'SortBy': 'DateCreated,SortName',
        'SortOrder': 'Descending',
        'Limit': '$limit',
      });

  @override
  Future<MusicServerItems> mostPlayed({int limit = 30}) async =>
      MusicServerItems(
        tracks: await _tracks(<String, String>{
          'Filters': 'IsPlayed',
          'SortBy': 'PlayCount,SortName',
          'SortOrder': 'Descending',
          'Limit': '$limit',
        }),
      );

  @override
  Future<MusicServerItems> recentlyPlayed({int limit = 30}) async =>
      MusicServerItems(
        tracks: await _tracks(<String, String>{
          'Filters': 'IsPlayed',
          'SortBy': 'DatePlayed',
          'SortOrder': 'Descending',
          'Limit': '$limit',
        }),
      );

  Future<List<MusicServerAlbum>> _albums(Map<String, String> query) async {
    final Object? json = await _api
        .getDecodedJson('$_userPath/Items', <String, String>{
          'IncludeItemTypes': 'MusicAlbum',
          'Recursive': 'true',
          'Fields': _albumFields,
          'EnableImageTypes': 'Primary',
          ...query,
        });
    return <MusicServerAlbum>[
      for (final Map<String, Object?> r in jellyfinItemsOf(json))
        ?parseJellyfinMusicAlbum(r),
    ];
  }

  /// 曲目列表保持服务器排序（不经 [sortMusicServerTracks]：最常 / 最近播放的顺序就是内容）。
  Future<List<MusicServerTrack>> _tracks(Map<String, String> query) async {
    final Object? json = await _api
        .getDecodedJson('$_userPath/Items', <String, String>{
          'IncludeItemTypes': 'Audio',
          'Recursive': 'true',
          'Fields': _trackFields,
          ...query,
        });
    return <MusicServerTrack>[
      for (final Map<String, Object?> r in jellyfinItemsOf(json))
        ?parseJellyfinMusicTrack(r),
    ];
  }

  // ---------------------------------------------------------------------------
  // 即时混音（[MusicServerInstantMix]）：`/Items/{id}/InstantMix` 对曲目 / 专辑 / 艺人 /
  // 流派都按条目种类出混音。
  // ---------------------------------------------------------------------------

  @override
  Future<List<MusicServerTrack>> instantMix(
    MusicServerItemKind kind,
    String id, {
    int limit = 50,
  }) async {
    final Object? json = await _api.getDecodedJson(
      '/Items/${Uri.encodeComponent(id)}/InstantMix',
      <String, String>{
        'UserId': config.userId,
        'Limit': '$limit',
        'Fields': _trackFields,
      },
    );
    return <MusicServerTrack>[
      for (final Map<String, Object?> r in jellyfinItemsOf(json))
        if ((r['Type'] as String? ?? 'Audio') == 'Audio')
          ?parseJellyfinMusicTrack(r),
    ];
  }

  // ---------------------------------------------------------------------------
  // 播放上报（[MusicServerPlaybackReporting]）：复用视频的 `/Sessions/Playing*` 实现
  // （[JellyfinApi.reportStarted] / [JellyfinApi.reportProgress] /
  // [JellyfinApi.reportStopped]）。会话 id 由本机生成（音乐流不经 PlaybackInfo），
  // MediaSourceId 就是条目 id（音频条目只有一个源）。
  // ---------------------------------------------------------------------------

  @override
  MusicServerStreamRef? streamRefOf(Uri uri) => jellyfinStreamRefOf(uri);

  static JellyfinPlaybackSession _session(MusicServerPlaybackReport r) =>
      JellyfinPlaybackSession(
        itemId: r.trackId,
        mediaSourceId: r.trackId,
        playSessionId: r.playSessionId,
        playMethod: r.transcoded ? 'Transcode' : 'DirectPlay',
      );

  @override
  Future<void> reportPlaybackStarted(MusicServerPlaybackReport report) => _api
      .reportStarted(session: _session(report), positionMs: report.positionMs);

  @override
  Future<void> reportPlaybackProgress(
    MusicServerPlaybackReport report, {
    MusicServerPlaybackEvent? event,
  }) => _api.reportProgress(
    itemId: report.trackId,
    positionMs: report.positionMs,
    session: _session(report),
    isPaused: report.paused,
    eventName: event?.name,
  );

  @override
  Future<void> reportPlaybackStopped(MusicServerPlaybackReport report) =>
      _api.reportStopped(
        itemId: report.trackId,
        positionMs: report.positionMs,
        session: _session(report),
      );

  /// 补记离线时的一次播放（[MusicServerPlayMarking]）：`PlayedItems` 带 `datePlayed`，服务器把
  /// 播放次数 +1、最近播放时刻设成给的时刻（10.10 实测；Emby 同一个端点）。
  @override
  Future<void> markPlayed(String trackId, DateTime playedAt) async {
    await _api.sendJson(
      'POST',
      '$_userPath/PlayedItems/${Uri.encodeComponent(trackId)}',
      query: <String, String>{'datePlayed': playedAt.toUtc().toIso8601String()},
    );
  }

  /// Jellyfin 开播上报（`/Sessions/Playing`）时就计一次播放。
  @override
  bool get countsPlayOnStart => true;

  // ---------------------------------------------------------------------------
  // 服务器歌词（[MusicServerLyricsProvider]）：`/Audio/{id}/Lyrics`（Jellyfin 10.9+，读
  // 音频旁的 .lrc / 内嵌歌词 / 歌词插件结果）。404 = 这首没有歌词。
  // ---------------------------------------------------------------------------

  @override
  Future<MusicServerLyrics?> lyricsFor(String trackId) async {
    final Object? json;
    try {
      json = await _api.getDecodedJson(
        '/Audio/${Uri.encodeComponent(trackId)}/Lyrics',
      );
    } on JellyfinApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    } on FormatException {
      return null; // 不认这个路由的兼容层（回 HTML 首页）：当没有。
    }
    return parseJellyfinLyrics(json);
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
