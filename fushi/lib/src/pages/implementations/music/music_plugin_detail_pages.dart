part of 'music_plugin_pages.dart';

// ---------------------------------------------------------------------------
// 插件音源的艺人 / 专辑 / 歌单详情与在线 MV（契约 docs/specs/2026-10-28-music-plugins.md §4）。
// 新字段 / 新能力都是可选的：旧插件没给的信息不显示，没声明的能力对应页签不出现。
// ---------------------------------------------------------------------------

/// 大数字的紧凑写法（79万 / 793K），按当前界面语言；intl 不认识的语言退回英文。
String formatMusicCompactCount(BuildContext context, int n) {
  final Locale l = Localizations.localeOf(context);
  final String locale =
      Intl.verifiedLocale(
        l.toLanguageTag(),
        NumberFormat.localeExists,
        onFailure: (_) => Intl.verifiedLocale(
          l.languageCode,
          NumberFormat.localeExists,
          onFailure: (_) => 'en',
        ),
      ) ??
      'en';
  return NumberFormat.compact(locale: locale).format(n);
}

/// 艺人统计一行（单曲 / 专辑 / MV / 粉丝；0 与缺失不显示）。
String musicPluginArtistStatsText(
  BuildContext context,
  MusicPluginArtistStats s,
) {
  String n(int v) => formatMusicCompactCount(context, v);
  return <String>[
    if (s.trackCount case final int c when c > 0)
      t.music_tracks_count(count: n(c)),
    if (s.albumCount case final int c when c > 0)
      t.music_server_album_count(count: n(c)),
    if (s.mvCount case final int c when c > 0)
      t.music_plugin_stat_mvs(count: n(c)),
    if (s.fanCount case final int c when c > 0)
      t.music_plugin_stat_fans(count: n(c)),
  ].join(' · ');
}

/// 曲目行上的「播放 MV」：曲目有 MV 且插件声明了 `mvStream` 才有。
VoidCallback? _mvAction(
  BuildContext context,
  WidgetRef ref,
  MusicPluginManifest manifest,
  MusicPluginTrack track,
) {
  final String? mvId = track.mvId;
  if (mvId == null || !manifest.can(MusicPluginCapability.mvStream)) {
    return null;
  }
  return () => unawaited(
    _openPluginMv(
      context,
      ref,
      manifest,
      mvId: mvId,
      title: track.title,
      artist: track.artists.isEmpty ? null : track.artistText,
      coverUrl: track.coverUrl,
    ),
  );
}

/// 在线 MV 交给视频播放页播放（[openMusicOnlineMvPage]，进入时暂停音乐）；
/// 进页时才取流（地址有时效）。
Future<void> _openPluginMv(
  BuildContext context,
  WidgetRef ref,
  MusicPluginManifest manifest, {
  required String mvId,
  required String title,
  String? artist,
  String? coverUrl,
}) {
  final MusicPluginSource src = ref
      .read(appProvider)
      .musicPluginManager
      .source(manifest.id);
  return openMusicOnlineMvPage(
    context: context,
    key: '${manifest.id}/$mvId',
    title: title,
    artist: artist,
    coverUrl: coverUrl,
    source: MusicOnlineMv(
      resolve: () async {
        final MusicPluginMvStream s = await src.mvStream(
          mvId,
          quality: MusicPluginQuality.lossless,
        );
        return (url: s.url, headers: s.headers);
      },
      describeError: musicPluginErrorText,
    ),
  );
}

/// 可展开的长文本（专辑 / 歌单简介）：超过 [maxLines] 才出「展开 / 收起」。
class _ExpandableText extends StatefulWidget {
  const _ExpandableText(this.text, {super.key});

  /// 收起时最多显示的行数。
  static const int maxLines = 3;

  final String text;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = context.fushiType.bodyMedium.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: _ExpandableText.maxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: c.maxWidth);
        final bool overflows = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedSize(
              duration: fushiMotionDuration(context, FushiMotion.medium),
              alignment: Alignment.topLeft,
              child: Text(
                widget.text,
                style: style,
                maxLines: _expanded ? null : _ExpandableText.maxLines,
                overflow: _expanded ? null : TextOverflow.ellipsis,
              ),
            ),
            if (overflows || _expanded)
              FushiPressScale(
                child: FushiTextButton(
                  key: const ValueKey<String>(
                    'music-plugin-description-toggle',
                  ),
                  onPressed: () => setState(() {
                    _expanded = !_expanded;
                  }),
                  child: Text(
                    _expanded
                        ? t.music_plugin_description_less
                        : t.music_plugin_description_more,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 可点的艺人名（进艺人页）；插件不支持 artist 或没有 id 时是普通文字。
Widget _artistLinks(
  BuildContext context,
  MusicPluginManifest manifest,
  List<MusicPluginArtistRef> artists,
  TextStyle style,
) {
  final bool linkable = manifest.can(MusicPluginCapability.artist);
  return Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: <Widget>[
      for (int i = 0; i < artists.length; i++) ...<Widget>[
        if (i > 0) Text(' / ', style: style),
        if (linkable && artists[i].id != null)
          FushiPressScale(
            child: InkWell(
              key: ValueKey<String>(
                'music-plugin-artist-link-${artists[i].id}',
              ),
              borderRadius: BorderRadius.circular(4),
              onTap: () => unawaited(
                _push(
                  context,
                  MusicPluginArtistPage(
                    manifest: manifest,
                    artist: MusicPluginArtist(
                      id: artists[i].id!,
                      name: artists[i].name,
                    ),
                  ),
                ),
              ),
              child: Text(
                artists[i].name,
                style: style.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          )
        else
          Text(artists[i].name, style: style),
      ],
    ],
  );
}

/// 专辑 / 歌单详情：封面、标题、艺人（可点）/ 创建者、发行信息 / 播放数、简介（可展开）、
/// 整组播放 / 随机、曲目表（多碟时按碟分组；有 MV 的曲目可直接看 MV）。
class MusicPluginCollectionPage extends ConsumerStatefulWidget {
  const MusicPluginCollectionPage.album({
    super.key,
    required this.manifest,
    required MusicPluginAlbum this.album,
  }) : playlist = null;

  const MusicPluginCollectionPage.playlist({
    super.key,
    required this.manifest,
    required MusicPluginPlaylist this.playlist,
  }) : album = null;

  final MusicPluginManifest manifest;
  final MusicPluginAlbum? album;
  final MusicPluginPlaylist? playlist;

  @override
  ConsumerState<MusicPluginCollectionPage> createState() =>
      _MusicPluginCollectionPageState();
}

typedef _Collection = ({
  MusicPluginAlbum? album,
  MusicPluginPlaylist? playlist,
  List<MusicPluginTrack> tracks,
});

/// 合集封面：平台没给（如「喜欢」歌单常常没有封面）时用第一首
/// 有封面的曲目顶上，和平台客户端的做法一致。
String? _collectionCover(_Collection c) =>
    c.album?.coverUrl ??
    c.playlist?.coverUrl ??
    c.tracks
        .map((MusicPluginTrack t) => t.coverUrl)
        .whereType<String>()
        .firstOrNull;

class _MusicPluginCollectionPageState
    extends ConsumerState<MusicPluginCollectionPage> {
  late Future<_Collection> _data = _load();

  Future<_Collection> _load() async {
    final MusicPluginSource src = ref
        .read(appProvider)
        .musicPluginManager
        .source(widget.manifest.id);
    final MusicPluginAlbum? album = widget.album;
    if (album != null) {
      final ({MusicPluginAlbum album, List<MusicPluginTrack> tracks}) r =
          await src.album(album.id);
      return (
        album: r.album.withCover(r.album.coverUrl ?? album.coverUrl),
        playlist: null,
        tracks: r.tracks,
      );
    }
    final ({MusicPluginPlaylist playlist, List<MusicPluginTrack> tracks}) r =
        await src.playlist(widget.playlist!.id);
    return (
      album: null,
      playlist: r.playlist.withCover(
        r.playlist.coverUrl ?? widget.playlist!.coverUrl,
      ),
      tracks: r.tracks,
    );
  }

  /// 曲目行（多碟专辑按碟分组，组内序号与圆角按组算）。
  List<Widget> _trackRows(
    _Collection c,
    void Function({int start, bool shuffle}) play,
  ) {
    final List<MusicPluginTrack> tracks = c.tracks;
    final bool isAlbum = c.album != null;
    final Set<int> discs = <int>{
      for (final MusicPluginTrack t in tracks) t.discNo ?? 1,
    };
    final bool grouped = isAlbum && discs.length > 1;
    final Map<int, List<int>> byDisc = <int, List<int>>{};
    for (int i = 0; i < tracks.length; i++) {
      (byDisc[grouped ? tracks[i].discNo ?? 1 : 0] ??= <int>[]).add(i);
    }
    return <Widget>[
      for (final MapEntry<int, List<int>> group in byDisc.entries) ...<Widget>[
        if (grouped)
          FushiSectionTitle.group(
            t.music_disc_label(n: group.key),
            key: ValueKey<String>('music-plugin-disc-${group.key}'),
          ),
        for (int j = 0; j < group.value.length; j++)
          _TrackRow(
            track: tracks[group.value[j]],
            index: j,
            count: group.value.length,
            leadingNumber: isAlbum,
            onPlayMv: _mvAction(
              context,
              ref,
              widget.manifest,
              tracks[group.value[j]],
            ),
            onTap: () => play(start: group.value[j]),
          ),
      ],
    ];
  }

  Widget _header(
    BuildContext context,
    _Collection c,
    void Function({int start, bool shuffle}) play,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicPluginAlbum? album = c.album;
    final MusicPluginPlaylist? playlist = c.playlist;
    final String title = album?.title ?? playlist!.title;
    final String? cover = _collectionCover(c);
    final String? description = album?.description ?? playlist?.description;
    final TextStyle body = context.fushiType.bodyMedium;
    final String meta = <String>[
      if (album != null) ...<String>[
        if (album.releaseDate != null)
          t.music_plugin_released_on(date: album.releaseDate!)
        else if (album.year != null)
          '${album.year}',
        ?album.company,
      ],
      if (playlist?.playCount case final int plays)
        t.music_plugin_play_count(
          count: formatMusicCompactCount(context, plays),
        ),
      t.music_tracks_count(count: c.tracks.length),
      widget.manifest.name,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        Wrap(
          spacing: tokens.spacing.section,
          runSpacing: tokens.spacing.gap,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: <Widget>[
            musicAlbumDetailCover(
              MusicCover(coverPath: cover, size: kMusicAlbumDetailCoverSize),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: tokens.spacing.gap * 0.5,
                children: <Widget>[
                  Text(title, style: context.fushiType.headlineSmall),
                  if (album != null && album.artists.isNotEmpty)
                    _artistLinks(
                      context,
                      widget.manifest,
                      album.artists,
                      context.fushiType.titleMedium,
                    ),
                  if (playlist?.owner case final String owner)
                    Text(
                      t.music_plugin_playlist_by(name: owner),
                      style: context.fushiType.titleMedium,
                    ),
                  Text(meta, style: body),
                  if (playlist != null && playlist.tags.isNotEmpty)
                    Text(
                      playlist.tags.map((String tag) => '#$tag').join('  '),
                      style: context.fushiType.bodySmall,
                    ),
                  Wrap(
                    spacing: tokens.spacing.gap,
                    runSpacing: tokens.spacing.gap,
                    children: <Widget>[
                      FushiPressScale(
                        child: FushiFilledButton.icon(
                          key: const ValueKey<String>(
                            'music_plugin_collection_play',
                          ),
                          onPressed: c.tracks.isEmpty ? null : play,
                          icon: const FushiIcon(FushiIcons.play),
                          label: Text(t.music_play_all),
                        ),
                      ),
                      FushiPressScale(
                        child: FushiOutlinedButton.icon(
                          onPressed: c.tracks.isEmpty
                              ? null
                              : () => play(shuffle: true),
                          icon: const FushiIcon(FushiIcons.repeat),
                          label: Text(t.music_shuffle_play),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (description != null)
          _ExpandableText(
            description,
            key: const ValueKey<String>('music-plugin-collection-description'),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool isAlbum = widget.album != null;
    return musicBrowseScaffold(
      context,
      title: widget.album?.title ?? widget.playlist!.title,
      body: FutureBuilder<_Collection>(
        future: _data,
        builder: (BuildContext context, AsyncSnapshot<_Collection> snap) {
          if (snap.hasError) {
            return musicBrowseErrorView(
              context,
              musicPluginErrorText(snap.error!),
              () => setState(() {
                _data = _load();
              }),
            );
          }
          final _Collection? c = snap.data;
          if (c == null) return const FushiLoadingView();
          final String title = c.album?.title ?? c.playlist!.title;
          final String? cover = _collectionCover(c);
          void play({int start = 0, bool shuffle = false}) => _playTracks(
            ref,
            widget.manifest.id,
            c.tracks,
            start: start,
            shuffle: shuffle,
            context: isAlbum
                ? MusicQueueContext.album
                : MusicQueueContext.mixed,
            albumTitle: isAlbum ? title : null,
            coverUrl: isAlbum ? cover : null,
            source: isAlbum
                ? MusicPlaySource.pluginAlbum(
                    widget.manifest.id,
                    widget.album!.id,
                    title: title,
                    cover: cover,
                  )
                : MusicPlaySource.pluginPlaylist(
                    widget.manifest.id,
                    widget.playlist!.id,
                    title: title,
                    cover: cover,
                  ),
          );
          final List<Widget> children = <Widget>[
            _header(context, c, play),
            ..._trackRows(c, play),
          ];
          return FushiEntranceScope(
            child: ListView.separated(
              padding: musicBrowsePagePadding(context),
              itemCount: children.length,
              separatorBuilder: (_, int i) =>
                  SizedBox(height: i == 0 ? tokens.spacing.gap : 0),
              itemBuilder: fushiStaggeredItemBuilder(
                (BuildContext context, int i) => children[i],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 艺人页的页签（插件没给对应数据 / 能力时不出现）。
enum _ArtistTab { popular, albums, mvs, details }

/// 一个分页列表（艺人专辑 / MV）的加载状态。
class _PagedFeed<T> {
  final List<T> items = <T>[];
  int page = 0;
  bool hasMore = true;
  bool loading = false;
  Object? error;

  bool get started => page > 0 || loading || error != null;
}

typedef _ArtistData = ({
  MusicPluginArtist artist,
  List<MusicPluginAlbum> albums,
  List<MusicPluginTrack> tracks,
});

/// 一位艺人：头部（头像 / 名字 / 别名 / 统计 / 播放热门）+ 分段页签：热门歌曲 / 专辑
/// （分页网格）/ MV（分页网格）/ 详情（简介与分段介绍）。
class MusicPluginArtistPage extends ConsumerStatefulWidget {
  const MusicPluginArtistPage({
    super.key,
    required this.manifest,
    required this.artist,
  });

  final MusicPluginManifest manifest;
  final MusicPluginArtist artist;

  @override
  ConsumerState<MusicPluginArtistPage> createState() =>
      _MusicPluginArtistPageState();
}

class _MusicPluginArtistPageState extends ConsumerState<MusicPluginArtistPage> {
  static const int _pageSize = 30;

  /// 离底部不到这么多就取下一页。
  static const double _loadMoreExtent = 600;

  late Future<_ArtistData> _data = _load();
  final ScrollController _scroll = ScrollController();
  _ArtistTab? _tab;
  List<_ArtistTab> _tabs = const <_ArtistTab>[];
  final _PagedFeed<MusicPluginAlbum> _albums = _PagedFeed<MusicPluginAlbum>();
  final _PagedFeed<MusicPluginMv> _mvs = _PagedFeed<MusicPluginMv>();

  MusicPluginSource get _src =>
      ref.read(appProvider).musicPluginManager.source(widget.manifest.id);

  bool _can(MusicPluginCapability c) => widget.manifest.can(c);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<_ArtistData> _load() async {
    final _ArtistData d = await _src.artist(widget.artist.id);
    if (mounted) {
      _tabs = _tabsFor(d);
      final _ArtistTab? first = _tab ?? _tabs.firstOrNull;
      if (first != null) _ensureLoaded(first);
    }
    return d;
  }

  List<_ArtistTab> _tabsFor(_ArtistData d) => <_ArtistTab>[
    if (d.tracks.isNotEmpty) _ArtistTab.popular,
    if (_can(MusicPluginCapability.artistAlbums) || d.albums.isNotEmpty)
      _ArtistTab.albums,
    if (_can(MusicPluginCapability.artistMvs)) _ArtistTab.mvs,
    if (d.artist.hasDetails) _ArtistTab.details,
  ];

  _PagedFeed<Object>? _feedOf(_ArtistTab? tab) => switch (tab) {
    _ArtistTab.albums when _can(MusicPluginCapability.artistAlbums) => _albums,
    _ArtistTab.mvs => _mvs,
    _ => null,
  };

  void _ensureLoaded(_ArtistTab tab) {
    final _PagedFeed<Object>? feed = _feedOf(tab);
    if (feed != null && !feed.started) unawaited(_loadMore(tab));
  }

  /// 当前页签滚到底附近（或首屏没填满）时取下一页。
  void _maybeLoadMore() {
    final _ArtistTab? tab = _tab ?? _tabs.firstOrNull;
    final _PagedFeed<Object>? feed = _feedOf(tab);
    if (feed == null || tab == null) return;
    if (feed.loading || !feed.hasMore || feed.error != null) return;
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < _loadMoreExtent) {
      unawaited(_loadMore(tab));
    }
  }

  Future<void> _loadMore(_ArtistTab tab) async {
    final _PagedFeed<Object>? feed = _feedOf(tab);
    if (feed == null || feed.loading || !feed.hasMore) return;
    setState(() {
      feed.loading = true;
      feed.error = null;
    });
    try {
      final MusicPluginPage<Object> page = tab == _ArtistTab.albums
          ? await _src.artistAlbums(
              widget.artist.id,
              page: feed.page,
              pageSize: _pageSize,
            )
          : await _src.artistMvs(
              widget.artist.id,
              page: feed.page,
              pageSize: _pageSize,
            );
      if (!mounted) return;
      setState(() {
        feed.items.addAll(page.items);
        feed.page++;
        feed.hasMore = page.hasMore && page.items.isNotEmpty;
        feed.loading = false;
      });
      // 一页没填满视口时滚动不会发生，帧后再看一次。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeLoadMore();
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        feed.error = e;
        feed.loading = false;
      });
    }
  }

  void _select(_ArtistTab tab) {
    setState(() {
      _tab = tab;
    });
    _ensureLoaded(tab);
  }

  String _tabLabel(_ArtistTab tab) => switch (tab) {
    _ArtistTab.popular => t.music_plugin_popular,
    _ArtistTab.albums => t.music_section_albums,
    _ArtistTab.mvs => t.music_mv_section,
    _ArtistTab.details => t.music_plugin_artist_tab_details,
  };

  Widget _header(BuildContext context, _ArtistData d) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicPluginArtist a = d.artist;
    const double avatar = 144;
    final String stats = musicPluginArtistStatsText(context, a.stats);
    final TextStyle muted = context.fushiType.bodyMedium.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    void play({bool shuffle = false}) =>
        _playTracks(ref, widget.manifest.id, d.tracks, shuffle: shuffle);
    return Wrap(
      spacing: tokens.spacing.section,
      runSpacing: tokens.spacing.gap,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        // 艺人头像是圆的，不是唱片，不套专辑材质（与列表行 / 搜索卡一致）。
        SizedBox.square(
          dimension: avatar,
          child: MusicCover(
            coverPath: a.coverUrl ?? widget.artist.coverUrl,
            size: avatar,
            borderRadius: BorderRadius.circular(avatar / 2),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: tokens.spacing.gap * 0.5,
            children: <Widget>[
              Text(
                a.name,
                style: context.fushiType.headlineMedium.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (a.aliases.isNotEmpty)
                Text(
                  a.aliases.join(' / '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              Text(
                <String>[
                  if (stats.isNotEmpty) stats,
                  widget.manifest.name,
                ].join(' · '),
                style: context.fushiType.bodyMedium,
              ),
              // 简介摘要：三行截断，点一下跳到「详情」页签看全文。
              if (a.description case final String bio)
                FushiPressScale(
                  child: InkWell(
                    key: const ValueKey<String>('music-plugin-artist-bio'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _select(_ArtistTab.details),
                    child: Text(
                      bio,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ),
                ),
              if (d.tracks.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: tokens.spacing.gap * 0.5),
                  child: Wrap(
                    spacing: tokens.spacing.gap,
                    runSpacing: tokens.spacing.gap,
                    children: <Widget>[
                      FushiPressScale(
                        child: FushiFilledButton.icon(
                          key: const ValueKey<String>(
                            'music-plugin-artist-play-popular',
                          ),
                          onPressed: play,
                          icon: const FushiIcon(FushiIcons.play),
                          label: Text(t.music_plugin_artist_play_popular),
                        ),
                      ),
                      FushiPressScale(
                        child: FushiOutlinedButton.icon(
                          onPressed: () => play(shuffle: true),
                          icon: const FushiIcon(FushiIcons.repeat),
                          label: Text(t.music_shuffle_play),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 分页列表尾部：加载中 / 出错重试 / 空。
  Widget _feedFooter(_ArtistTab tab, _PagedFeed<Object> feed) {
    if (feed.error case final Object e) {
      return Row(
        children: <Widget>[
          Expanded(
            child: Text(
              musicPluginErrorText(e),
              style: context.fushiType.bodySmall,
            ),
          ),
          FushiPressScale(
            child: FushiTextButton(
              onPressed: () => unawaited(_loadMore(tab)),
              child: Text(t.retry),
            ),
          ),
        ],
      );
    }
    if (feed.loading || feed.hasMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: FushiLinearProgressIndicator(),
      );
    }
    if (feed.items.isEmpty) {
      return FushiPlaceholderMessage(
        icon: FushiIcons.music,
        message: t.music_server_search_empty,
      );
    }
    return const SizedBox.shrink();
  }

  SliverGridDelegate _mvGridDelegate(BuildContext context, double width) {
    const double maxExtent = 280;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double spacing = tokens.spacing.gap * 1.5;
    final double available = math.max(1, width - tokens.spacing.page * 2);
    final int columns = (available / (maxExtent + spacing)).ceil().clamp(
      1,
      1 << 10,
    );
    final double cardWidth = (available - (columns - 1) * spacing) / columns;
    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxExtent,
      mainAxisSpacing: spacing,
      crossAxisSpacing: spacing,
      mainAxisExtent: cardWidth * 9 / 16 + ShelfCardMeta.heightFor(context),
    );
  }

  List<Widget> _detailChildren(MusicPluginArtist a) => <Widget>[
    if (a.description case final String desc) ...<Widget>[
      FushiSectionTitle(t.music_plugin_artist_bio),
      SelectableText(desc, style: context.fushiType.bodyMedium),
    ],
    for (final MusicPluginIntroSection s in a.intro) ...<Widget>[
      if (s.title case final String title) FushiSectionTitle(title),
      SelectableText(s.text, style: context.fushiType.bodyMedium),
    ],
    if (!a.hasDetails)
      FushiPlaceholderMessage(
        icon: FushiIcons.info,
        message: t.music_plugin_artist_no_details,
      ),
  ];

  /// 当前页签的内容（sliver）。
  List<Widget> _content(
    BuildContext context,
    _ArtistData d,
    _ArtistTab tab,
    double width,
  ) {
    switch (tab) {
      case _ArtistTab.popular:
        return <Widget>[
          SliverList(
            delegate: SliverChildBuilderDelegate(
              fushiStaggeredItemBuilder(
                (BuildContext context, int i) => _TrackRow(
                  track: d.tracks[i],
                  index: i,
                  count: d.tracks.length,
                  onPlayMv: _mvAction(
                    context,
                    ref,
                    widget.manifest,
                    d.tracks[i],
                  ),
                  onTap: () =>
                      _playTracks(ref, widget.manifest.id, d.tracks, start: i),
                ),
              ),
              childCount: d.tracks.length,
            ),
          ),
        ];
      case _ArtistTab.albums:
        final bool paged = _can(MusicPluginCapability.artistAlbums);
        final List<MusicPluginAlbum> albums = paged ? _albums.items : d.albums;
        return <Widget>[
          SliverGrid(
            gridDelegate: musicAlbumGridDelegate(context, width),
            delegate: SliverChildBuilderDelegate(
              fushiStaggeredItemBuilder(
                (BuildContext context, int i) => _PluginAlbumCard(
                  key: ValueKey<String>(
                    'music-plugin-artist-album-${albums[i].id}',
                  ),
                  manifest: widget.manifest,
                  album: albums[i],
                ),
              ),
              childCount: albums.length,
            ),
          ),
          if (paged) SliverToBoxAdapter(child: _feedFooter(tab, _albums)),
        ];
      case _ArtistTab.mvs:
        return <Widget>[
          SliverGrid(
            gridDelegate: _mvGridDelegate(context, width),
            delegate: SliverChildBuilderDelegate(
              fushiStaggeredItemBuilder(
                (BuildContext context, int i) => _PluginMvCard(
                  key: ValueKey<String>('music-plugin-mv-${_mvs.items[i].id}'),
                  mv: _mvs.items[i],
                  onTap: () => unawaited(
                    _openPluginMv(
                      context,
                      ref,
                      widget.manifest,
                      mvId: _mvs.items[i].id,
                      title: _mvs.items[i].title,
                      artist: _mvs.items[i].artists.isEmpty
                          ? d.artist.name
                          : _mvs.items[i].artistText,
                      coverUrl: _mvs.items[i].coverUrl,
                    ),
                  ),
                ),
              ),
              childCount: _mvs.items.length,
            ),
          ),
          SliverToBoxAdapter(child: _feedFooter(tab, _mvs)),
        ];
      case _ArtistTab.details:
        final List<Widget> children = _detailChildren(d.artist);
        return <Widget>[
          SliverList(
            delegate: SliverChildBuilderDelegate(
              fushiStaggeredItemBuilder(
                (BuildContext context, int i) => children[i],
              ),
              childCount: children.length,
            ),
          ),
        ];
    }
  }

  @override
  Widget build(BuildContext context) => musicBrowseScaffold(
    context,
    title: widget.artist.name,
    body: FutureBuilder<_ArtistData>(
      future: _data,
      builder: (BuildContext context, AsyncSnapshot<_ArtistData> snap) {
        if (snap.hasError) {
          return musicBrowseErrorView(
            context,
            musicPluginErrorText(snap.error!),
            () => setState(() {
              _data = _load();
            }),
          );
        }
        final _ArtistData? d = snap.data;
        if (d == null) return const FushiLoadingView();
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final List<_ArtistTab> tabs = _tabs;
        final _ArtistTab? tab = tabs.contains(_tab) ? _tab : tabs.firstOrNull;
        final EdgeInsets pad = musicBrowsePagePadding(context);
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) =>
              ShelfCoverMaterialScope(
                material: ShelfCoverMaterial.glossyAlbum,
                child: FushiEntranceScope(
                  replayKey: tab,
                  child: CustomScrollView(
                    key: const ValueKey<String>('music-plugin-artist-scroll'),
                    controller: _scroll,
                    slivers: <Widget>[
                      SliverPadding(
                        padding: pad.copyWith(bottom: 0),
                        sliver: SliverList.list(
                          children: <Widget>[
                            FushiStaggeredEntrance(
                              index: 0,
                              child: _header(context, d),
                            ),
                            SizedBox(height: tokens.spacing.section),
                            if (tabs.length > 1 && tab != null) ...<Widget>[
                              FushiStaggeredEntrance(
                                index: 1,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: adaptiveSegmentedButton<_ArtistTab>(
                                    context: context,
                                    segments: <ButtonSegment<_ArtistTab>>[
                                      for (final _ArtistTab x in tabs)
                                        ButtonSegment<_ArtistTab>(
                                          value: x,
                                          label: Text(_tabLabel(x)),
                                        ),
                                    ],
                                    selected: <_ArtistTab>{tab},
                                    onSelectionChanged: (Set<_ArtistTab> s) =>
                                        _select(s.first),
                                  ),
                                ),
                              ),
                              SizedBox(height: tokens.spacing.section),
                            ],
                          ],
                        ),
                      ),
                      if (tab == null)
                        SliverToBoxAdapter(
                          child: FushiPlaceholderMessage(
                            icon: FushiIcons.music,
                            message: t.music_server_search_empty,
                          ),
                        )
                      else
                        SliverPadding(
                          padding: pad.copyWith(top: 0),
                          sliver: SliverMainAxisGroup(
                            slivers: _content(context, d, tab, c.maxWidth),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
        );
      },
    ),
  );
}

/// 艺人页专辑网格的一张卡（专辑材质，悬停不放大）。
class _PluginAlbumCard extends StatelessWidget {
  const _PluginAlbumCard({
    super.key,
    required this.manifest,
    required this.album,
  });

  final MusicPluginManifest manifest;
  final MusicPluginAlbum album;

  @override
  Widget build(BuildContext context) => FushiHoverLift(
    scale: kMusicHoverLiftScale,
    builder: (BuildContext context, bool _) => shelfCoverCard(
      onTap: () => unawaited(
        _push(
          context,
          MusicPluginCollectionPage.album(manifest: manifest, album: album),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AspectRatio(
            aspectRatio: kShelfAlbumAspectRatio,
            child: ShelfCoverFrame(
              child: MusicCover(coverPath: album.coverUrl),
            ),
          ),
          ShelfCardMeta(
            title: album.title,
            subtitle: <String>[
              if (album.releaseDate != null)
                album.releaseDate!
              else if (album.year != null)
                '${album.year}',
              if (album.trackCount != null)
                t.music_tracks_count(count: album.trackCount!),
            ].join(' · '),
          ),
        ],
      ),
    ),
  );
}

/// MV 网格的一张卡：16:9 封面（同一份专辑材质框，只是横版），时长 / 播放量 / 发布日期
/// 进副行（封面不压角标）。
class _PluginMvCard extends StatelessWidget {
  const _PluginMvCard({super.key, required this.mv, required this.onTap});

  final MusicPluginMv mv;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FushiHoverLift(
    scale: kMusicHoverLiftScale,
    builder: (BuildContext context, bool _) => shelfCoverCard(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ShelfCoverFrame(child: MusicCover(coverPath: mv.coverUrl)),
          ),
          ShelfCardMeta(
            title: mv.title,
            leadingIcon: FushiIcons.video,
            subtitle: <String>[
              if (mv.durationMs != null) formatMusicDuration(mv.durationMs),
              if (mv.playCount case final int plays)
                t.music_plugin_play_count(
                  count: formatMusicCompactCount(context, plays),
                ),
              ?mv.publishDate,
            ].join(' · '),
          ),
        ],
      ),
    ),
  );
}
