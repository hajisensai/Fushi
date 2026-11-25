// 服务器曲库的发现分区（Jellyfin 家族 / OpenSubsonic）：主页（最近添加 / 最常播放 /
// 最近播放）、流派（列表 → 流派页：专辑 + 曲目）、收藏。只对实现了对应能力的服务器出现
// （[MusicServerDiscovery] / [MusicServerFavoriteEditing]），嵌在 [MusicServerBrowsePage]
// 的分区里；播放统计是服务器按本账号记的，本机播放经播放上报计入。
part of 'music_server_pages.dart';

/// 主页每个货架取多少条。
const int kMusicServerHomeShelfLimit = 30;

void _push(BuildContext context, Widget page) => unawaited(
  Navigator.of(
    context,
  ).push<void>(adaptivePageRoute<void>(context: context, builder: (_) => page)),
);

/// 一组曲目 / 专辑排成的段：曲目走「先露几首 + 查看全部」的曲目段，专辑走横排卡。
/// [title] 是整组的标题（主页「最常播放」等）：落在排在最前的那一段上，后面的段用
/// 类别名；null（流派页 / 收藏）= 各段一律用类别名（歌曲 / 专辑 / 艺人）。
List<Widget> _itemsSections(
  BuildContext context,
  MusicServerBrowser browser,
  String? title,
  MusicServerItems items,
  String keyPrefix,
) => <Widget>[
  if (items.tracks.isNotEmpty)
    MusicServerSongSection(
      key: ValueKey<String>('$keyPrefix-tracks'),
      title: title ?? t.music_section_songs,
      browser: browser,
      tracks: items.tracks,
    ),
  if (items.albums.isNotEmpty)
    MusicShelfRow(
      key: ValueKey<String>('$keyPrefix-albums'),
      title: items.tracks.isEmpty && title != null
          ? title
          : t.music_section_albums,
      children: <Widget>[
        for (final MusicServerAlbum a in items.albums)
          MusicServerAlbumCard(
            key: ValueKey<String>('$keyPrefix-album-${a.id}'),
            browser: browser,
            album: a,
          ),
      ],
    ),
  if (items.artists.isNotEmpty && isGlassDesign(context))
    // Cupertino：圆形头像货架（设计稿③「艺人」）。
    appleMusicFitShelf(
      context,
      AppleMusicCoverShelfSection(
        key: ValueKey<String>('$keyPrefix-artists'),
        title: t.music_section_artists,
        circular: true,
        children: <Widget>[
          for (final MusicServerArtist a in items.artists)
            AppleMusicAutoCoverTile(
              key: ValueKey<String>('$keyPrefix-artist-${a.id}'),
              title: a.name,
              cover: browser.coverUri(a.coverRef)?.toString(),
              circular: true,
              onTap: () => _push(
                context,
                MusicServerArtistPage(browser: browser, artist: a),
              ),
            ),
        ],
      ),
    )
  else if (items.artists.isNotEmpty) ...<Widget>[
    FushiSectionTitle(t.music_section_artists),
    for (final MusicServerArtist a in items.artists)
      MusicCollectionRow(
        key: ValueKey<String>('$keyPrefix-artist-${a.id}'),
        title: a.name,
        coverPath: browser.coverUri(a.coverRef)?.toString(),
        circular: true,
        onTap: () =>
            _push(context, MusicServerArtistPage(browser: browser, artist: a)),
      ),
  ],
];

/// 一列分段（错峰入场），没有内容时显示 [empty]。
Widget _sectionList(
  BuildContext context,
  List<Widget> sections, {
  required String empty,
  IconData icon = FushiIcons.music,
}) {
  if (sections.isEmpty) {
    return Center(
      child: FushiPlaceholderMessage(icon: icon, message: empty),
    );
  }
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  if (isGlassDesign(context)) {
    // Cupertino：段头 / 货架自带页边与段距，列表左右不留页边。
    return AppleMusicFullBleed(
      child: FushiEntranceScope(
        child: ListView.builder(
          padding: musicBrowsePagePadding(context).copyWith(left: 0, right: 0),
          itemCount: sections.length,
          itemBuilder: fushiStaggeredItemBuilder(
            (BuildContext context, int i) => sections[i],
          ),
        ),
      ),
    );
  }
  return FushiEntranceScope(
    child: ListView.separated(
      padding: musicBrowsePagePadding(context),
      itemCount: sections.length,
      separatorBuilder: (_, _) => SizedBox(height: tokens.spacing.section),
      itemBuilder: fushiStaggeredItemBuilder(
        (BuildContext context, int i) => sections[i],
      ),
    ),
  );
}

// =========================================================================
// 主页
// =========================================================================

class _HomeData {
  const _HomeData(this.added, this.mostPlayed, this.recent);

  final List<MusicServerAlbum> added;
  final MusicServerItems mostPlayed;
  final MusicServerItems recent;
}

/// 服务器主页：最近添加的专辑、最常播放、最近播放（三项并行取，任一失败整页可重试）。
class MusicServerHomeView extends StatefulWidget {
  const MusicServerHomeView({super.key, required this.browser});

  /// 必须实现 [MusicServerDiscovery]。
  final MusicServerBrowser browser;

  @override
  State<MusicServerHomeView> createState() => _MusicServerHomeViewState();
}

class _MusicServerHomeViewState extends State<MusicServerHomeView> {
  late Future<_HomeData> _data = _load();

  Future<_HomeData> _load() async {
    final MusicServerDiscovery d = widget.browser as MusicServerDiscovery;
    final Future<List<MusicServerAlbum>> added = d.recentlyAddedAlbums(
      limit: kMusicServerHomeShelfLimit,
    );
    final Future<MusicServerItems> most = d.mostPlayed(
      limit: kMusicServerHomeShelfLimit,
    );
    final Future<MusicServerItems> recent = d.recentlyPlayed(
      limit: kMusicServerHomeShelfLimit,
    );
    // 并行取；等齐再抛第一个错（不留没人接的失败 future）。
    await Future.wait<Object>(<Future<Object>>[added, most, recent]);
    return _HomeData(await added, await most, await recent);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_HomeData>(
    future: _data,
    builder: (BuildContext context, AsyncSnapshot<_HomeData> snap) {
      if (snap.hasError) {
        return musicBrowseErrorView(
          context,
          snap.error!,
          () => setState(() => _data = _load()),
        );
      }
      final _HomeData? d = snap.data;
      if (d == null) return const FushiLoadingView();
      final MusicServerBrowser b = widget.browser;
      return _sectionList(context, <Widget>[
        if (d.added.isNotEmpty)
          MusicShelfRow(
            key: const ValueKey<String>('music-server-home-added'),
            title: t.music_server_recently_added,
            children: <Widget>[
              for (final MusicServerAlbum a in d.added)
                MusicServerAlbumCard(
                  key: ValueKey<String>('music-server-home-added-${a.id}'),
                  browser: b,
                  album: a,
                ),
            ],
          ),
        ..._itemsSections(
          context,
          b,
          t.music_server_most_played,
          d.mostPlayed,
          'music-server-home-most',
        ),
        ..._itemsSections(
          context,
          b,
          t.music_server_recently_played,
          d.recent,
          'music-server-home-recent',
        ),
      ], empty: t.music_server_home_empty);
    },
  );
}

// =========================================================================
// 流派
// =========================================================================

/// 流派列表（点进 [MusicServerGenrePage]）。
class MusicServerGenresView extends StatefulWidget {
  const MusicServerGenresView({super.key, required this.browser});

  /// 必须实现 [MusicServerDiscovery]。
  final MusicServerBrowser browser;

  @override
  State<MusicServerGenresView> createState() => _MusicServerGenresViewState();
}

class _MusicServerGenresViewState extends State<MusicServerGenresView> {
  late Future<List<MusicServerGenre>> _genres = _load();

  Future<List<MusicServerGenre>> _load() =>
      (widget.browser as MusicServerDiscovery).listGenres();

  void _open(BuildContext context, MusicServerGenre g) =>
      _push(context, MusicServerGenrePage(browser: widget.browser, genre: g));

  @override
  Widget build(BuildContext context) => FutureBuilder<List<MusicServerGenre>>(
    future: _genres,
    builder:
        (BuildContext context, AsyncSnapshot<List<MusicServerGenre>> snap) {
          if (snap.hasError) {
            return musicBrowseErrorView(
              context,
              snap.error!,
              () => setState(() => _genres = _load()),
            );
          }
          final List<MusicServerGenre>? genres = snap.data;
          if (genres == null) return const FushiLoadingView();
          if (genres.isEmpty) {
            return Center(
              child: FushiPlaceholderMessage(
                icon: FushiIcons.tag,
                message: t.music_server_genres_empty,
              ),
            );
          }
          return _genreList(context, genres);
        },
  );

  Widget _genreList(BuildContext context, List<MusicServerGenre> genres) {
    ValueKey<String> keyOf(MusicServerGenre g) =>
        ValueKey<String>('music-server-genre-${g.id}');
    String? subtitleOf(MusicServerGenre g) => <String>[
      if (g.albumCount != null)
        t.music_server_album_count(count: g.albumCount!),
      if (g.trackCount != null) t.music_tracks_count(count: g.trackCount!),
    ].join(' · ').nullIfEmpty;
    String? coverOf(MusicServerGenre g) =>
        widget.browser.coverUri(g.coverRef)?.toString();
    if (isGlassDesign(context)) {
      // Cupertino：彩色渐变流派块网格（Apple Music「按类别浏览」）。
      return AppleMusicCategoryGrid(
        itemCount: genres.length,
        itemBuilder: (BuildContext context, int i) => AppleMusicCategoryTile(
          key: keyOf(genres[i]),
          label: genres[i].name,
          seed: genres[i].id,
          subtitle: subtitleOf(genres[i]),
          icon: FushiIcons.tag,
          onTap: () => _open(context, genres[i]),
        ),
      );
    }
    if (musicTrackRowSurfaceActive(context)) {
      return MusicStyledCollection(
        style: MusicViewStyle.blocks,
        itemCount: genres.length,
        padding: musicBrowsePagePadding(context),
        blockBuilder: (BuildContext context, int i, FushiCoverBlockSize size) =>
            MusicCollectionBlock(
              key: keyOf(genres[i]),
              size: size,
              title: genres[i].name,
              subtitle: subtitleOf(genres[i]),
              coverPath: coverOf(genres[i]),
              leadingIcon: FushiIcons.tag,
              onTap: () => _open(context, genres[i]),
            ),
        rowBuilder: (BuildContext context, int i) => MusicCollectionRow(
          key: keyOf(genres[i]),
          title: genres[i].name,
          subtitle: subtitleOf(genres[i]),
          coverPath: coverOf(genres[i]),
          onTap: () => _open(context, genres[i]),
        ),
      );
    }
    // 墨水屏：分组列表。
    return FushiEntranceScope(
      child: ListView.builder(
        padding: musicBrowsePagePadding(context),
        itemCount: genres.length,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          final MusicServerGenre g = genres[i];
          final String? sub = subtitleOf(g);
          return FushiPressScale(
            child: FushiGroupedListItem(
              key: keyOf(g),
              index: i,
              count: genres.length,
              onTap: () => _open(context, g),
              child: FushiListItem(
                leading: const FushiListLeadingIcon(FushiIcons.tag),
                title: Text(g.name),
                subtitle: sub == null ? null : Text(sub),
                trailing: const FushiIcon(FushiIcons.chevronRight),
              ),
            ),
          );
        }),
      ),
    );
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

/// 一个流派：整个流派播放 / 随机、专辑横排、曲目段。
class MusicServerGenrePage extends StatefulWidget {
  const MusicServerGenrePage({
    super.key,
    required this.browser,
    required this.genre,
  });

  /// 必须实现 [MusicServerDiscovery]。
  final MusicServerBrowser browser;
  final MusicServerGenre genre;

  @override
  State<MusicServerGenrePage> createState() => _MusicServerGenrePageState();
}

class _MusicServerGenrePageState extends State<MusicServerGenrePage> {
  late Future<MusicServerItems> _items = _load();

  Future<MusicServerItems> _load() async {
    final MusicServerDiscovery d = widget.browser as MusicServerDiscovery;
    final Future<List<MusicServerAlbum>> albums = d.genreAlbums(widget.genre);
    final Future<List<MusicServerTrack>> tracks = d.genreTracks(widget.genre);
    await Future.wait<Object>(<Future<Object>>[albums, tracks]);
    return MusicServerItems(albums: await albums, tracks: await tracks);
  }

  @override
  Widget build(BuildContext context) => musicBrowseScaffold(
    context,
    title: widget.genre.name,
    body: (BuildContext context) => FutureBuilder<MusicServerItems>(
      future: _items,
      builder: (BuildContext context, AsyncSnapshot<MusicServerItems> snap) {
        if (snap.hasError) {
          return musicBrowseErrorView(
            context,
            snap.error!,
            () => setState(() => _items = _load()),
          );
        }
        final MusicServerItems? items = snap.data;
        if (items == null) return const FushiLoadingView();
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final List<MusicServerTrack> tracks = items.tracks;
        return _sectionList(
          context,
          <Widget>[
            if (tracks.isNotEmpty && isGlassDesign(context))
              appleMusicInset(
                context,
                Padding(
                  padding: EdgeInsets.only(top: tokens.spacing.gap),
                  child: Wrap(
                    spacing: tokens.spacing.gap,
                    runSpacing: tokens.spacing.gap,
                    children: <Widget>[
                      AppleMusicCapsuleButton(
                        key: const ValueKey<String>('music-server-genre-play'),
                        icon: FushiIcons.play,
                        label: t.music_play_all,
                        onTap: () => playMusicServerTracks(
                          context,
                          widget.browser,
                          tracks,
                        ),
                      ),
                      AppleMusicCapsuleButton(
                        icon: FushiIcons.shuffle,
                        label: t.music_shuffle_play,
                        onTap: () => playMusicServerTracks(
                          context,
                          widget.browser,
                          tracks,
                          shuffle: true,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else if (tracks.isNotEmpty)
              Wrap(
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: <Widget>[
                  FushiPressScale(
                    child: FushiFilledButton.icon(
                      key: const ValueKey<String>('music-server-genre-play'),
                      size: FushiButtonSize.m,
                      onPressed: () => playMusicServerTracks(
                        context,
                        widget.browser,
                        tracks,
                      ),
                      icon: const FushiIcon(FushiIcons.play),
                      label: Text(t.music_play_all),
                    ),
                  ),
                  FushiPressScale(
                    child: FushiFilledButton.tonalIcon(
                      size: FushiButtonSize.m,
                      onPressed: () => playMusicServerTracks(
                        context,
                        widget.browser,
                        tracks,
                        shuffle: true,
                      ),
                      icon: const FushiIcon(FushiIcons.shuffle),
                      label: Text(t.music_shuffle_play),
                    ),
                  ),
                ],
              ),
            ..._itemsSections(
              context,
              widget.browser,
              null,
              items,
              'music-server-genre',
            ),
          ],
          empty: t.music_server_no_albums,
          icon: FushiIcons.tag,
        );
      },
    ),
  );
}

// =========================================================================
// 收藏
// =========================================================================

/// 当前账号在这台服务器上收藏的专辑 / 艺人 / 曲目。本机切换收藏后（任何页面）重取一次。
class MusicServerFavoritesView extends StatefulWidget {
  const MusicServerFavoritesView({super.key, required this.browser});

  /// 必须实现 [MusicServerFavoriteEditing]。
  final MusicServerBrowser browser;

  @override
  State<MusicServerFavoritesView> createState() =>
      _MusicServerFavoritesViewState();
}

class _MusicServerFavoritesViewState extends State<MusicServerFavoritesView> {
  late Future<MusicServerItems> _items = _load();
  MusicServerItems? _last;

  Future<MusicServerItems> _load() async {
    final MusicServerItems items =
        await (widget.browser as MusicServerFavoriteEditing).listFavorites();
    _last = items;
    return items;
  }

  void _reload() {
    if (mounted) setState(() => _items = _load());
  }

  @override
  void initState() {
    super.initState();
    MusicServerFavoriteStore.instance.addListener(_reload);
  }

  @override
  void dispose() {
    MusicServerFavoriteStore.instance.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<MusicServerItems>(
    future: _items,
    builder: (BuildContext context, AsyncSnapshot<MusicServerItems> snap) {
      if (snap.hasError) {
        return musicBrowseErrorView(context, snap.error!, _reload);
      }
      // 重取期间先显示上一份（取消收藏后不闪加载圈）。
      final MusicServerItems? items = snap.data ?? _last;
      if (items == null) return const FushiLoadingView();
      return _sectionList(
        context,
        _itemsSections(
          context,
          widget.browser,
          null,
          items,
          'music-server-favorites',
        ),
        empty: t.music_server_favorites_empty,
        icon: FushiIcons.favorite,
      );
    },
  );
}
