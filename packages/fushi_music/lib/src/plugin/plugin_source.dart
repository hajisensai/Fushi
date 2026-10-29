import 'plugin_instance.dart';
import 'plugin_manager.dart';
import 'plugin_models.dart';

/// 登录挑战里 `appUrl` 允许的自定义 scheme：只收各音乐平台 / 其账号体系的官方 App，宿主
/// 只在用户点按钮后外部打开。其它 scheme（file / content / intent / javascript …）一律丢弃。
const Set<String> kMusicPluginAppSchemes = <String>{
  'orpheus',
  'qqmusic',
  'mqqapi',
  'wtloginmqq',
  'kugou',
  'kuwo',
  'migu',
  'snssdk1128',
};

/// 某个插件的类型化能力调用（返回值按契约 §4 解析；形状不对抛 [MusicPluginException]）。
///
/// 插件给的封面 / 流地址都按其网络授权核对（每次结果整批一次 FFI）：越权的封面当没有，越权的
/// 流地址当不可播放。
class MusicPluginSource {
  MusicPluginSource(this._manager, this.pluginId);

  final MusicPluginManager _manager;
  final String pluginId;

  Future<(MusicPluginInstance, Object?)> _call(
    MusicPluginCapability cap,
    Map<String, Object?> args,
  ) async {
    final MusicPluginInstance inst = await _manager.instance(pluginId);
    if (!inst.info.manifest.can(cap)) {
      throw MusicPluginException('插件不支持 ${cap.wire}', pluginId: pluginId);
    }
    return (inst, await inst.invoke(cap.wire, args));
  }

  Map<String, Object?> _object(Object? v, String what) {
    if (v is Map<Object?, Object?>) return v.cast<String, Object?>();
    throw MusicPluginException('插件 $what 返回值不是对象', pluginId: pluginId);
  }

  /// 整批核对封面地址，返回查表函数（越权 / 缺失 → null）。
  String? Function(String?) _covers(
    MusicPluginInstance inst,
    Iterable<String?> urls,
  ) {
    final Map<String, String> ok = inst.checkMediaUrls(
      urls.whereType<String>(),
    );
    return (String? url) => url == null ? null : ok[url];
  }

  Future<(MusicPluginInstance, Map<String, Object?>)> _search(
    MusicPluginSearchType type,
    String query,
    int page,
    int pageSize,
  ) async {
    final (MusicPluginInstance inst, Object? v) = await _call(
      MusicPluginCapability.search,
      <String, Object?>{
        'query': query,
        'type': type.wire,
        'page': page,
        'pageSize': pageSize,
      },
    );
    final Map<String, Object?> r = _object(v, 'search');
    if (r['items'] is! List<Object?>) {
      throw MusicPluginException('插件 search 返回值缺 items', pluginId: pluginId);
    }
    return (inst, r);
  }

  MusicPluginPage<T> _page<T>(Map<String, Object?> r, List<T> items) =>
      MusicPluginPage<T>(
        items: items,
        hasMore: r['hasMore'] == true,
        total: (r['total'] as num?)?.toInt(),
      );

  Future<MusicPluginPage<MusicPluginTrack>> searchTracks(
    String query, {
    int page = 0,
    int pageSize = 30,
  }) async {
    final (MusicPluginInstance inst, Map<String, Object?> r) = await _search(
      MusicPluginSearchType.song,
      query,
      page,
      pageSize,
    );
    final List<MusicPluginTrack> tracks = MusicPluginTrack.listFrom(r['items']);
    final String? Function(String?) cover = _covers(
      inst,
      tracks.map((MusicPluginTrack t) => t.coverUrl),
    );
    return _page(r, _withTrackCovers(tracks, cover));
  }

  Future<MusicPluginPage<MusicPluginAlbum>> searchAlbums(
    String query, {
    int page = 0,
    int pageSize = 30,
  }) async {
    final (MusicPluginInstance inst, Map<String, Object?> r) = await _search(
      MusicPluginSearchType.album,
      query,
      page,
      pageSize,
    );
    final List<MusicPluginAlbum> albums = MusicPluginAlbum.listFrom(r['items']);
    final String? Function(String?) cover = _covers(
      inst,
      albums.map((MusicPluginAlbum a) => a.coverUrl),
    );
    return _page(r, _withAlbumCovers(albums, cover));
  }

  Future<MusicPluginPage<MusicPluginArtist>> searchArtists(
    String query, {
    int page = 0,
    int pageSize = 30,
  }) async {
    final (MusicPluginInstance inst, Map<String, Object?> r) = await _search(
      MusicPluginSearchType.artist,
      query,
      page,
      pageSize,
    );
    final List<MusicPluginArtist> artists = MusicPluginArtist.listFrom(
      r['items'],
    );
    final String? Function(String?) cover = _covers(
      inst,
      artists.map((MusicPluginArtist a) => a.coverUrl),
    );
    return _page(r, <MusicPluginArtist>[
      for (final MusicPluginArtist a in artists) a.withCover(cover(a.coverUrl)),
    ]);
  }

  Future<MusicPluginPage<MusicPluginPlaylist>> searchPlaylists(
    String query, {
    int page = 0,
    int pageSize = 30,
  }) async {
    final (MusicPluginInstance inst, Map<String, Object?> r) = await _search(
      MusicPluginSearchType.playlist,
      query,
      page,
      pageSize,
    );
    final List<MusicPluginPlaylist> lists = MusicPluginPlaylist.listFrom(
      r['items'],
    );
    final String? Function(String?) cover = _covers(
      inst,
      lists.map((MusicPluginPlaylist p) => p.coverUrl),
    );
    return _page(r, <MusicPluginPlaylist>[
      for (final MusicPluginPlaylist p in lists) _withPlaylistCover(p, cover),
    ]);
  }

  /// 推荐页：整批核对全部封面一次。空段、未知种类的段丢弃。
  /// [refresh] = 用户点了「换一批」：插件可以借此换掉可替换的段（推荐歌单等），
  /// 每日推荐这类按天固定的内容照旧。
  Future<List<MusicPluginHomeSection>> home({bool refresh = false}) async {
    final (MusicPluginInstance inst, Object? v) = await _call(
      MusicPluginCapability.home,
      <String, Object?>{if (refresh) 'refresh': true},
    );
    final Object? raw = _object(v, 'home')['sections'];
    if (raw is! List<Object?>) {
      throw MusicPluginException('插件 home 返回值缺 sections', pluginId: pluginId);
    }
    final List<MusicPluginHomeSection> parsed = <MusicPluginHomeSection>[];
    for (final Object? e in raw) {
      if (parsed.length >= MusicPluginHomeSection.maxSections) break;
      if (e is! Map<Object?, Object?>) continue;
      final Object? id = e['id'];
      final Object? title = e['title'];
      final MusicPluginHomeKind? kind = MusicPluginHomeKind.parse(e['kind']);
      if (id is! String || title is! String || kind == null) continue;
      final List<Object> items = switch (kind) {
        MusicPluginHomeKind.tracks => MusicPluginTrack.listFrom(e['items']),
        MusicPluginHomeKind.playlists => MusicPluginPlaylist.listFrom(
          e['items'],
        ),
        MusicPluginHomeKind.albums => MusicPluginAlbum.listFrom(e['items']),
      };
      if (items.isEmpty) continue;
      final Object? subtitle = e['subtitle'];
      parsed.add(
        MusicPluginHomeSection(
          id: id,
          title: title,
          subtitle: subtitle is String && subtitle.isNotEmpty ? subtitle : null,
          kind: kind,
          items: items.take(MusicPluginHomeSection.maxItems).toList(),
        ),
      );
    }
    final String? Function(String?) cover = _covers(inst, <String?>[
      for (final MusicPluginHomeSection s in parsed)
        for (final Object x in s.items)
          switch (x) {
            MusicPluginTrack t => t.coverUrl,
            MusicPluginPlaylist p => p.coverUrl,
            MusicPluginAlbum a => a.coverUrl,
            _ => null,
          },
    ]);
    return <MusicPluginHomeSection>[
      for (final MusicPluginHomeSection s in parsed)
        MusicPluginHomeSection(
          id: s.id,
          title: s.title,
          subtitle: s.subtitle,
          kind: s.kind,
          items: switch (s.kind) {
            MusicPluginHomeKind.tracks => _withTrackCovers(
              s.items.cast<MusicPluginTrack>(),
              cover,
            ),
            MusicPluginHomeKind.playlists => <MusicPluginPlaylist>[
              for (final MusicPluginPlaylist p
                  in s.items.cast<MusicPluginPlaylist>())
                _withPlaylistCover(p, cover),
            ],
            MusicPluginHomeKind.albums => _withAlbumCovers(
              s.items.cast<MusicPluginAlbum>(),
              cover,
            ),
          },
        ),
    ];
  }

  /// 已登录账号的歌单（自建 + 收藏）；未登录时插件返回空页。
  Future<MusicPluginPage<MusicPluginPlaylist>> library({
    int page = 0,
    int pageSize = 50,
  }) async {
    final (MusicPluginInstance inst, Object? v) = await _call(
      MusicPluginCapability.library,
      <String, Object?>{'page': page, 'pageSize': pageSize},
    );
    final Map<String, Object?> r = _object(v, 'library');
    final List<MusicPluginPlaylist> lists = MusicPluginPlaylist.listFrom(
      r['items'],
    );
    final String? Function(String?) cover = _covers(
      inst,
      lists.map((MusicPluginPlaylist p) => p.coverUrl),
    );
    return _page(r, <MusicPluginPlaylist>[
      for (final MusicPluginPlaylist p in lists) _withPlaylistCover(p, cover),
    ]);
  }

  Future<({MusicPluginAlbum album, List<MusicPluginTrack> tracks})> album(
    String id,
  ) async {
    final (MusicPluginInstance inst, Object? v) = await _call(
      MusicPluginCapability.album,
      <String, Object?>{'id': id},
    );
    final Map<String, Object?> r = _object(v, 'album');
    final MusicPluginAlbum? album = MusicPluginAlbum.fromJson(r['album']);
    if (album == null) {
      throw MusicPluginException('插件 album 返回值缺 album', pluginId: pluginId);
    }
    final List<MusicPluginTrack> tracks = MusicPluginTrack.listFrom(
      r['tracks'],
    );
    final String? Function(String?) cover = _covers(inst, <String?>[
      album.coverUrl,
      ...tracks.map((MusicPluginTrack t) => t.coverUrl),
    ]);
    final MusicPluginAlbum clean = _withAlbumCovers(<MusicPluginAlbum>[
      album,
    ], cover).single;
    return (
      album: clean,
      tracks: _withTrackCovers(
        tracks,
        cover,
        albumId: clean.id,
        albumTitle: clean.title,
        albumCover: clean.coverUrl,
      ),
    );
  }

  Future<({MusicPluginPlaylist playlist, List<MusicPluginTrack> tracks})>
  playlist(String id) async {
    final (MusicPluginInstance inst, Object? v) = await _call(
      MusicPluginCapability.playlist,
      <String, Object?>{'id': id},
    );
    final Map<String, Object?> r = _object(v, 'playlist');
    final MusicPluginPlaylist? p = MusicPluginPlaylist.fromJson(r['playlist']);
    if (p == null) {
      throw MusicPluginException(
        '插件 playlist 返回值缺 playlist',
        pluginId: pluginId,
      );
    }
    final List<MusicPluginTrack> tracks = MusicPluginTrack.listFrom(
      r['tracks'],
    );
    final String? Function(String?) cover = _covers(inst, <String?>[
      p.coverUrl,
      ...tracks.map((MusicPluginTrack t) => t.coverUrl),
    ]);
    return (
      playlist: _withPlaylistCover(p, cover),
      tracks: _withTrackCovers(tracks, cover),
    );
  }

  Future<
    ({
      MusicPluginArtist artist,
      List<MusicPluginAlbum> albums,
      List<MusicPluginTrack> tracks,
    })
  >
  artist(String id) async {
    final (MusicPluginInstance inst, Object? v) = await _call(
      MusicPluginCapability.artist,
      <String, Object?>{'id': id},
    );
    final Map<String, Object?> r = _object(v, 'artist');
    final MusicPluginArtist? a = MusicPluginArtist.fromJson(r['artist']);
    if (a == null) {
      throw MusicPluginException('插件 artist 返回值缺 artist', pluginId: pluginId);
    }
    final List<MusicPluginAlbum> albums = MusicPluginAlbum.listFrom(
      r['albums'],
    );
    final List<MusicPluginTrack> tracks = MusicPluginTrack.listFrom(
      r['tracks'],
    ).take(maxArtistHotTracks).toList();
    final String? Function(String?) cover = _covers(inst, <String?>[
      a.coverUrl,
      ...albums.map((MusicPluginAlbum x) => x.coverUrl),
      ...tracks.map((MusicPluginTrack t) => t.coverUrl),
    ]);
    return (
      artist: a.withCover(cover(a.coverUrl)),
      albums: _withAlbumCovers(albums, cover),
      tracks: _withTrackCovers(tracks, cover),
    );
  }

  /// 艺人热门曲上限（契约 §4：`artist` 的 tracks）。
  static const int maxArtistHotTracks = 50;

  /// 艺人专辑分页（`artistAlbums`）。
  Future<MusicPluginPage<MusicPluginAlbum>> artistAlbums(
    String artistId, {
    int page = 0,
    int pageSize = 30,
  }) async {
    final (MusicPluginInstance inst, Object? v) = await _call(
      MusicPluginCapability.artistAlbums,
      <String, Object?>{'id': artistId, 'page': page, 'pageSize': pageSize},
    );
    final Map<String, Object?> r = _pageObject(v, 'artistAlbums');
    final List<MusicPluginAlbum> albums = MusicPluginAlbum.listFrom(r['items']);
    final String? Function(String?) cover = _covers(
      inst,
      albums.map((MusicPluginAlbum a) => a.coverUrl),
    );
    return _page(r, _withAlbumCovers(albums, cover));
  }

  /// 艺人 MV 分页（`artistMvs`）。
  Future<MusicPluginPage<MusicPluginMv>> artistMvs(
    String artistId, {
    int page = 0,
    int pageSize = 30,
  }) async {
    final (MusicPluginInstance inst, Object? v) = await _call(
      MusicPluginCapability.artistMvs,
      <String, Object?>{'id': artistId, 'page': page, 'pageSize': pageSize},
    );
    final Map<String, Object?> r = _pageObject(v, 'artistMvs');
    final List<MusicPluginMv> mvs = MusicPluginMv.listFrom(r['items']);
    final String? Function(String?) cover = _covers(
      inst,
      mvs.map((MusicPluginMv m) => m.coverUrl),
    );
    return _page(r, <MusicPluginMv>[
      for (final MusicPluginMv m in mvs) m.withCover(cover(m.coverUrl)),
    ]);
  }

  /// MV 取流（`mvStream`）：地址同样必须在插件网络授权内（`purpose = media`）。
  Future<MusicPluginMvStream> mvStream(
    String mvId, {
    MusicPluginQuality quality = MusicPluginQuality.high,
  }) async {
    final (MusicPluginInstance inst, Object? v) = await _call(
      MusicPluginCapability.mvStream,
      <String, Object?>{'id': mvId, 'quality': quality.wire},
    );
    final MusicPluginMvStream? s = MusicPluginMvStream.fromJson(v);
    if (s == null) {
      throw MusicPluginException('插件没有给出 MV 播放地址', pluginId: pluginId);
    }
    final String? url = inst.checkMediaUrls(<String>[s.url])[s.url];
    if (url == null) {
      throw MusicPluginException('MV 地址不在插件声明的网络授权内', pluginId: pluginId);
    }
    return MusicPluginMvStream(
      url: url,
      headers: s.headers,
      expiresAt: s.expiresAt,
      width: s.width,
      height: s.height,
    );
  }

  /// 搜索最佳匹配（`searchBest`）；插件不支持或返回 null 时为 [MusicPluginSearchBest.none]。
  Future<MusicPluginSearchBest> searchBest(String query) async {
    final MusicPluginInstance probe = await _manager.instance(pluginId);
    if (!probe.info.manifest.can(MusicPluginCapability.searchBest)) {
      return MusicPluginSearchBest.none;
    }
    final (MusicPluginInstance inst, Object? v) = await _call(
      MusicPluginCapability.searchBest,
      <String, Object?>{'query': query},
    );
    if (v == null) return MusicPluginSearchBest.none;
    final Map<String, Object?> r = _object(v, 'searchBest');
    final MusicPluginArtist? artist = MusicPluginArtist.fromJson(r['artist']);
    final MusicPluginPlaylist? playlist = MusicPluginPlaylist.fromJson(
      r['playlist'],
    );
    final MusicPluginAlbum? album = MusicPluginAlbum.fromJson(r['album']);
    final String? Function(String?) cover = _covers(inst, <String?>[
      artist?.coverUrl,
      playlist?.coverUrl,
      album?.coverUrl,
    ]);
    return MusicPluginSearchBest(
      artist: artist?.withCover(cover(artist.coverUrl)),
      playlist: playlist == null ? null : _withPlaylistCover(playlist, cover),
      album: album?.withCover(cover(album.coverUrl)),
    );
  }

  /// 已登录账号的喜欢集合（`like` 的 `op: 'list'`）；未登录时插件返回 null，这里也返回 null。
  /// 歌单封面照常按网络授权核对。
  Future<MusicPluginLikes?> likes() async {
    final (MusicPluginInstance inst, Object? v) = await _call(
      MusicPluginCapability.like,
      const <String, Object?>{'op': 'list'},
    );
    if (v == null) return null;
    final MusicPluginLikes? r = MusicPluginLikes.fromJson(v);
    if (r == null) {
      throw MusicPluginException('插件 like 返回值缺 ids', pluginId: pluginId);
    }
    final MusicPluginPlaylist? p = r.playlist;
    if (p == null) return r;
    return MusicPluginLikes(
      trackIds: r.trackIds,
      playlist: _withPlaylistCover(p, _covers(inst, <String?>[p.coverUrl])),
    );
  }

  /// 在平台上喜欢 / 取消喜欢一首（`like` 的 `op: 'set'`）。失败（含未登录）抛
  /// [MusicPluginException]，消息给用户看。
  Future<void> setLiked(String trackId, {required bool liked}) async {
    await _call(MusicPluginCapability.like, <String, Object?>{
      'op': 'set',
      'id': trackId,
      'liked': liked,
    });
  }

  /// 分页返回值：必须是带 items 数组的对象。
  Map<String, Object?> _pageObject(Object? v, String what) {
    final Map<String, Object?> r = _object(v, what);
    if (r['items'] is! List<Object?>) {
      throw MusicPluginException('插件 $what 返回值缺 items', pluginId: pluginId);
    }
    return r;
  }

  /// 取流：地址必须在插件网络授权内（`purpose = media`），否则当不可播放。
  Future<MusicPluginStream> stream(
    String trackId, {
    MusicPluginQuality quality = MusicPluginQuality.high,
  }) async {
    final (MusicPluginInstance inst, Object? v) = await _call(
      MusicPluginCapability.stream,
      <String, Object?>{'id': trackId, 'quality': quality.wire},
    );
    final MusicPluginStream? s = MusicPluginStream.fromJson(v);
    if (s == null) {
      throw MusicPluginException('插件没有给出播放地址', pluginId: pluginId);
    }
    final String? url = inst.checkMediaUrls(<String>[s.url])[s.url];
    if (url == null) {
      throw MusicPluginException('播放地址不在插件声明的网络授权内', pluginId: pluginId);
    }
    return MusicPluginStream(
      url: url,
      headers: s.headers,
      expiresAt: s.expiresAt,
      codec: s.codec,
      bitrateKbps: s.bitrateKbps,
      sampleRate: s.sampleRate,
      bitDepth: s.bitDepth,
      sizeBytes: s.sizeBytes,
      trialStartMs: s.trialStartMs,
      trialEndMs: s.trialEndMs,
    );
  }

  /// 歌词；没有返回 null。
  Future<MusicPluginLyrics?> lyrics(String trackId) async {
    final (_, Object? v) = await _call(
      MusicPluginCapability.lyrics,
      <String, Object?>{'id': trackId},
    );
    return v == null ? null : MusicPluginLyrics.fromJson(v);
  }

  /// 当前账号状态；插件不支持登录时恒为未登录。
  Future<MusicPluginAccount> account() async {
    final MusicPluginInstance inst = await _manager.instance(pluginId);
    if (!inst.info.manifest.can(MusicPluginCapability.account)) {
      return MusicPluginAccount.anonymous;
    }
    final (_, Object? v) = await _call(
      MusicPluginCapability.account,
      const <String, Object?>{},
    );
    return MusicPluginAccount.fromJson(v);
  }

  /// 插件提供的登录方式（[platform] = `windows` / `macos` / `linux` / `android`）。
  Future<List<MusicPluginLoginMethod>> loginMethods(String platform) async {
    final (_, Object? v) = await _call(
      MusicPluginCapability.login,
      <String, Object?>{'op': 'methods', 'platform': platform},
    );
    return MusicPluginLoginMethod.listFrom(v);
  }

  Future<MusicPluginLoginChallenge> loginBegin(
    String method,
    String platform,
  ) => _challenge(<String, Object?>{
    'op': 'begin',
    'method': method,
    'platform': platform,
  });

  Future<MusicPluginLoginChallenge> loginPoll(
    String method,
    String? session,
    String platform,
  ) => _challenge(<String, Object?>{
    'op': 'poll',
    'method': method,
    'platform': platform,
    'session': ?session,
  });

  Future<MusicPluginLoginChallenge> loginSubmit(
    String method,
    String? session,
    String platform, {
    required String action,
    required Map<String, String> inputs,
  }) => _challenge(<String, Object?>{
    'op': 'submit',
    'method': method,
    'platform': platform,
    'session': ?session,
    'action': action,
    'inputs': inputs,
  });

  Future<void> logout() async {
    await _call(MusicPluginCapability.login, const <String, Object?>{
      'op': 'logout',
    });
  }

  /// 解析一步登录，并按宿主规则清洗：
  /// - `web` 需要 `webAuth` 权限，登录页与 Cookie 地址都必须在插件网络授权内，否则去掉；
  /// - `appUrl` 只收网络授权内的 https，或 [kMusicPluginAppSchemes] 里的官方 App scheme。
  Future<MusicPluginLoginChallenge> _challenge(
    Map<String, Object?> args,
  ) async {
    final (MusicPluginInstance inst, Object? v) = await _call(
      MusicPluginCapability.login,
      args,
    );
    final MusicPluginLoginChallenge c = MusicPluginLoginChallenge.fromJson(v);
    bool webOk = false;
    if (c.hasWeb && inst.info.manifest.permissions.contains('webAuth')) {
      final Map<String, String> ok = inst.checkRequestUrls(<String>[
        c.webUrl!,
        c.webCookieUrl!,
      ]);
      webOk = ok.containsKey(c.webUrl) && ok.containsKey(c.webCookieUrl);
    }
    String? appUrl = c.appUrl;
    if (appUrl != null) {
      final Uri? u = Uri.tryParse(appUrl);
      final bool allowed =
          u != null &&
          (kMusicPluginAppSchemes.contains(u.scheme) ||
              (u.scheme == 'https' &&
                  inst.checkRequestUrls(<String>[appUrl]).isNotEmpty));
      if (!allowed) appUrl = null;
    }
    return MusicPluginLoginChallenge(
      state: c.state,
      session: c.session,
      message: c.message,
      qrContent: c.qrContent,
      qrImageBase64: c.qrImageBase64,
      qrScanned: c.qrScanned,
      pollMs: c.pollMs,
      appUrl: appUrl,
      fields: c.fields,
      actions: c.actions,
      webUrl: webOk ? c.webUrl : null,
      webCookieUrl: webOk ? c.webCookieUrl : null,
      webDoneCookie: webOk ? c.webDoneCookie : null,
      account: c.account,
    );
  }

  static MusicPluginPlaylist _withPlaylistCover(
    MusicPluginPlaylist p,
    String? Function(String?) cover,
  ) => p.withCover(cover(p.coverUrl));

  static List<MusicPluginTrack> _withTrackCovers(
    List<MusicPluginTrack> tracks,
    String? Function(String?) cover, {
    String? albumId,
    String? albumTitle,
    String? albumCover,
  }) => <MusicPluginTrack>[
    for (final MusicPluginTrack t in tracks)
      MusicPluginTrack(
        id: t.id,
        title: t.title,
        artists: t.artists,
        albumId: t.albumId ?? albumId,
        albumTitle: t.albumTitle ?? albumTitle,
        durationMs: t.durationMs,
        coverUrl: cover(t.coverUrl) ?? albumCover,
        trackNo: t.trackNo,
        discNo: t.discNo,
        isrc: t.isrc,
        playable: t.playable,
        note: t.note,
        mvId: t.mvId,
      ),
  ];

  static List<MusicPluginAlbum> _withAlbumCovers(
    List<MusicPluginAlbum> albums,
    String? Function(String?) cover,
  ) => <MusicPluginAlbum>[
    for (final MusicPluginAlbum a in albums) a.withCover(cover(a.coverUrl)),
  ];
}
