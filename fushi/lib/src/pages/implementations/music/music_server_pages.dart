/// 服务器曲库页（音乐方案 §13 P5）：专辑 / 艺人 / 搜索 → 专辑曲目 → 播放。入口是曲库页
/// 「推荐」的来源 chip（内嵌 [MusicServerBrowsePage]）与「来源」页。
/// 只读浏览；每一层都按服务器分页原样取（不把整库拍平成本地行），播放交给音乐引擎一条流。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_token_source.dart'
    show AppleMusicUnavailableException;
import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_items.dart'
    show AppleMusicStation;
import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';

import 'package:fushi/src/media/music/apple_music/apple_music_account.dart'
    show AppleMusicNotSignedInException;
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_apple_music_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart'
    show MusicFloatingBarHost;
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_local_playlist_page.dart'
    show MusicPlaylistTrackColumn, MusicPlaylistTrackRowData;
import 'package:fushi/src/pages/implementations/music/music_playlist_actions.dart';
import 'package:fushi/src/media/music/music_local_playlists.dart'
    show MusicPlaylistExportItem;
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 专辑网格的列宽上限（本地曲库与服务器曲库同一套几何）。
const double kMusicAlbumGridMaxExtent = 200;

/// 专辑网格的列数与行高：唱片封面（[kShelfAlbumAspectRatio]，方形）+ 封面下文字块
/// （[ShelfCardMeta.heightFor]，随文字缩放变高），按 `MaxCrossAxisExtent` 同一列数
/// 公式复算卡宽（与游戏库 / 媒体服务器同一做法，不用死比例）。[width] 是网格视口宽，
/// 左右各让一个页边（[FushiSpacingTokens.page]）。
SliverGridDelegate musicAlbumGridDelegate(BuildContext context, double width) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final double spacing = tokens.spacing.gap * 1.5;
  final double available = math.max(1, width - tokens.spacing.page * 2);
  final int columns = (available / (kMusicAlbumGridMaxExtent + spacing))
      .ceil()
      .clamp(1, 1 << 10);
  final double cardWidth = (available - (columns - 1) * spacing) / columns;
  return SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: kMusicAlbumGridMaxExtent,
    mainAxisSpacing: spacing,
    crossAxisSpacing: spacing,
    mainAxisExtent:
        cardWidth / kShelfAlbumAspectRatio + ShelfCardMeta.heightFor(context),
  );
}

/// 专辑详情页大封面的边长。
const double kMusicAlbumDetailCoverSize = 200;

/// 专辑详情页大封面：与网格同一份「唱片」材质（regular 密度：投影 + 接触阴影 +
/// 光泽），墨水屏退回描边封面框。本地专辑页与服务器专辑页共用。
Widget musicAlbumDetailCover(Widget cover) =>
    musicMaterialCover(cover, size: kMusicAlbumDetailCoverSize, tilt: true);

/// 服务器曲目 → 播放项（按设置的码率上限）。
List<MusicPlayItem> musicServerPlayItems(
  WidgetRef ref,
  MusicServerBrowser browser,
  List<MusicServerTrack> tracks, {
  MusicServerAlbum? album,
}) {
  final AppModel app = ref.read(appProvider);
  final int? limit = musicServerBitrateLimit(
    app.isPreferencesReady ? app.prefsRepo.musicServerMaxBitrate : 0,
  );
  final String? cover = album == null
      ? null
      : browser.coverUri(album.coverRef)?.toString();
  return <MusicPlayItem>[
    for (final MusicServerTrack t in tracks)
      musicServerPlayItem(
        browser,
        t,
        maxBitrateKbps: limit,
        albumTitle: album?.title,
        coverPath: cover,
      ),
  ];
}

/// 统一的页面外壳：MD3 用悬浮顶栏（动作默认平铺、放不下才收），Apple 用系统页头。
/// 服务器曲库与插件音源（`music_plugin_pages.dart`）共用。
Widget musicBrowseScaffold(
  BuildContext context, {
  required String title,
  required Widget body,
  List<FushiToolbarItem> actions = const <FushiToolbarItem>[],
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final NavigatorState? navigator = Navigator.maybeOf(context);
  return MusicFloatingBarHost(
    child: FushiPageScaffold(
      title: title,
      header: isGlassDesign(context)
          ? null
          : Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.gap,
                tokens.spacing.page,
                tokens.spacing.gap,
              ),
              child: FushiFloatingTopBar(
                title: title,
                leading: <FushiToolbarItem>[
                  if (navigator != null && navigator.canPop())
                    FushiToolbarItem(
                      icon: FushiIcons.back,
                      label: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      onPressed: () => unawaited(navigator.maybePop()),
                    ),
                ],
                actions: <List<FushiToolbarItem>>[
                  if (actions.isNotEmpty) actions,
                ],
              ),
            ),
      body: body,
    ),
  );
}

Widget musicBrowseErrorView(
  BuildContext context,
  Object error,
  VoidCallback retry,
) => Center(
  child: FushiPlaceholderMessage(
    icon: FushiIcons.cloudOff,
    message: switch (error) {
      AppleMusicUnavailableException() => t.music_apple_music_unavailable,
      AppleMusicNotSignedInException() => t.music_apple_music_signed_out,
      _ => t.music_server_load_failed,
    },
    detail: '$error',
    action: FushiFilledButton.icon(
      onPressed: retry,
      icon: const FushiIcon(FushiIcons.refresh),
      label: Text(t.music_server_retry),
    ),
  ),
);

EdgeInsets musicBrowsePagePadding(BuildContext context) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  return withBottomSafeInset(
    context,
    EdgeInsets.fromLTRB(
      tokens.spacing.page,
      MediaQuery.paddingOf(context).top + tokens.spacing.gap,
      tokens.spacing.page,
      tokens.spacing.section,
    ),
  );
}

enum _BrowseSection { home, albums, artists, playlists, songs }

/// 一个来源有哪些分区（第一个是缺省）：Apple Music catalog 多一个「主页」（推荐 / 榜单 /
/// 电台 / 流派），Apple Music 资料库多一个「歌曲」（资料库全部歌曲）。
List<_BrowseSection> _sectionsOf(MusicServerBrowser b) => switch (b) {
  AppleMusicCatalogClient() => const <_BrowseSection>[
    _BrowseSection.home,
    _BrowseSection.albums,
    _BrowseSection.playlists,
    _BrowseSection.artists,
  ],
  AppleMusicLibraryClient() => const <_BrowseSection>[
    _BrowseSection.albums,
    _BrowseSection.playlists,
    _BrowseSection.songs,
    _BrowseSection.artists,
  ],
  _ => const <_BrowseSection>[
    _BrowseSection.albums,
    _BrowseSection.artists,
    _BrowseSection.playlists,
  ],
};

String _sectionLabel(_BrowseSection s) => switch (s) {
  _BrowseSection.home => t.music_apple_music_section_home,
  _BrowseSection.albums => t.music_section_albums,
  _BrowseSection.artists => t.music_section_artists,
  _BrowseSection.playlists => t.music_section_playlists,
  _BrowseSection.songs => t.music_section_songs,
};

/// 一台服务器：专辑 / 艺人两个分区 + 搜索。
///
/// [embedded] 时不带页面外壳（曲库页「推荐」里选中单个服务器来源时就地显示），搜索钮与
/// [trailing]（如 Apple Music 的地区选择）跟在分区切换后面。
class MusicServerBrowsePage extends ConsumerStatefulWidget {
  const MusicServerBrowsePage({
    super.key,
    required this.browser,
    this.embedded = false,
    this.trailing,
  });

  final MusicServerBrowser browser;
  final bool embedded;
  final Widget? trailing;

  @override
  ConsumerState<MusicServerBrowsePage> createState() =>
      _MusicServerBrowsePageState();
}

class _MusicServerBrowsePageState extends ConsumerState<MusicServerBrowsePage> {
  late _BrowseSection _section = _sectionsOf(widget.browser).first;
  final List<MusicServerAlbum> _albums = <MusicServerAlbum>[];
  int? _next = 0;
  bool _loading = false;
  Object? _error;
  Future<List<MusicServerArtist>>? _artists;

  @override
  void initState() {
    super.initState();
    if (_section == _BrowseSection.albums) unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    final int? offset = _next;
    if (_loading || offset == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final MusicServerPage<MusicServerAlbum> page = await widget.browser
          .listAlbums(offset: offset);
      if (!mounted) return;
      setState(() {
        _albums.addAll(page.items);
        _next = page.nextOffset;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget segmented = adaptiveSegmentedButton<_BrowseSection>(
      context: context,
      segments: <ButtonSegment<_BrowseSection>>[
        for (final _BrowseSection s in _sectionsOf(widget.browser))
          ButtonSegment<_BrowseSection>(
            value: s,
            label: Text(_sectionLabel(s)),
          ),
      ],
      selected: <_BrowseSection>{_section},
      onSelectionChanged: (Set<_BrowseSection> v) => setState(() {
        _section = v.first;
        if (_section == _BrowseSection.artists) {
          _artists ??= widget.browser.listArtists();
        }
        if (_section == _BrowseSection.albums && _albums.isEmpty) {
          unawaited(_loadMore());
        }
      }),
    );
    final Widget content = switch (_section) {
      _BrowseSection.home => switch (widget.browser) {
        final AppleMusicCatalogClient c => AppleMusicHomeView(catalog: c),
        _ => const SizedBox.shrink(),
      },
      _BrowseSection.playlists => MusicServerPlaylistsView(
        browser: widget.browser,
      ),
      _BrowseSection.songs => switch (widget.browser) {
        final AppleMusicLibraryClient l => AppleMusicLibrarySongsView(
          library: l,
        ),
        _ => const SizedBox.shrink(),
      },
      _BrowseSection.albums =>
        _error != null && _albums.isEmpty
            ? _albumsErrorView(context)
            : NotificationListener<ScrollNotification>(
                onNotification: (ScrollNotification n) {
                  if (n.metrics.extentAfter < 600) unawaited(_loadMore());
                  return false;
                },
                child: _AlbumGrid(
                  browser: widget.browser,
                  albums: _albums,
                  loading: _loading,
                ),
              ),
      _BrowseSection.artists => FutureBuilder<List<MusicServerArtist>>(
        future: _artists,
        builder:
            (
              BuildContext context,
              AsyncSnapshot<List<MusicServerArtist>> snap,
            ) {
              if (snap.hasError) {
                return musicBrowseErrorView(
                  context,
                  snap.error!,
                  () => setState(() {
                    _artists = widget.browser.listArtists();
                  }),
                );
              }
              final List<MusicServerArtist>? artists = snap.data;
              if (artists == null) return const FushiLoadingView();
              return _ArtistList(browser: widget.browser, artists: artists);
            },
      ),
    };
    void openSearch() => unawaited(
      Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => MusicServerSearchPage(browser: widget.browser),
        ),
      ),
    );
    final Widget animated = AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      child: KeyedSubtree(
        key: ValueKey<_BrowseSection>(_section),
        child: content,
      ),
    );
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.page,
              vertical: tokens.spacing.gap / 2,
            ),
            child: Row(
              spacing: tokens.spacing.gap,
              children: <Widget>[
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: HorizontalDragScrollable(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: segmented,
                      ),
                    ),
                  ),
                ),
                ?widget.trailing,
                FushiIconButton(
                  key: const ValueKey<String>('music_server_search'),
                  icon: FushiIcons.search,
                  tooltip: t.music_server_search,
                  padTouchTarget: true,
                  onTap: openSearch,
                ),
              ],
            ),
          ),
          Expanded(child: animated),
        ],
      );
    }
    return musicBrowseScaffold(
      context,
      title: widget.browser.displayName,
      actions: <FushiToolbarItem>[
        FushiToolbarItem(
          key: const ValueKey<String>('music_server_search'),
          icon: FushiIcons.search,
          label: t.music_server_search,
          onPressed: openSearch,
        ),
      ],
      body: Builder(
        builder: (BuildContext context) => Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.page,
                    vertical: tokens.spacing.gap,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: HorizontalDragScrollable(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: segmented,
                      ),
                    ),
                  ),
                ),
                Expanded(child: animated),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _albumsErrorView(BuildContext context) =>
      musicBrowseErrorView(context, _error!, () {
        setState(() => _next = 0);
        unawaited(_loadMore());
      });
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({
    required this.browser,
    required this.albums,
    this.loading = false,
  });

  final MusicServerBrowser browser;
  final List<MusicServerAlbum> albums;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (albums.isEmpty && loading) return const FushiLoadingView();
    if (albums.isEmpty) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.music,
          message: t.music_server_no_albums,
        ),
      );
    }
    // 专辑一律是方形「唱片」材质（用户 2026-10-26 拍板）。
    return ShelfCoverMaterialScope(
      material: ShelfCoverMaterial.glossyAlbum,
      child: FushiEntranceScope(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) =>
              GridView.builder(
                padding: withBottomSafeInset(
                  context,
                  EdgeInsets.fromLTRB(
                    tokens.spacing.page,
                    MediaQuery.paddingOf(context).top + tokens.spacing.gap,
                    tokens.spacing.page,
                    tokens.spacing.section,
                  ),
                ),
                gridDelegate: musicAlbumGridDelegate(
                  context,
                  constraints.maxWidth,
                ),
                itemCount: albums.length,
                itemBuilder: fushiStaggeredItemBuilder((
                  BuildContext context,
                  int i,
                ) {
                  final MusicServerAlbum a = albums[i];
                  return MusicServerAlbumCard(
                    key: ValueKey<String>('music-server-album-${a.id}'),
                    browser: browser,
                    album: a,
                  );
                }),
              ),
        ),
      ),
    );
  }
}

/// 服务器专辑卡（服务器页的网格与混排进曲库的专辑都用它）：方形「唱片」材质
/// （[ShelfCoverMaterial.glossyAlbum]，由网格外的 [ShelfCoverMaterialScope] 给；
/// 墨水屏 / 无 Scope 时退回描边封面框）+ 封面下的 [ShelfCardMeta]。封面上不压角标
/// （用户 2026-10-25）：「在服务器上」的云朵进副行开头。悬停抬升与扫光来自
/// [FushiHoverLift] 与材质，按压下沉来自卡壳。
class MusicServerAlbumCard extends StatelessWidget {
  const MusicServerAlbumCard({
    super.key,
    required this.browser,
    required this.album,
  });

  final MusicServerBrowser browser;
  final MusicServerAlbum album;

  @override
  Widget build(BuildContext context) {
    return FushiHoverLift(
      scale: kMusicHoverLiftScale,
      builder: (BuildContext context, bool _) => shelfCoverCard(
        onTap: () => unawaited(
          Navigator.of(context).push<void>(
            adaptivePageRoute<void>(
              context: context,
              builder: (_) =>
                  MusicServerAlbumPage(browser: browser, album: album),
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AspectRatio(
              aspectRatio: kShelfAlbumAspectRatio,
              child: ShelfCoverFrame(
                child: MusicCover(
                  coverPath: browser.coverUri(album.coverRef)?.toString(),
                ),
              ),
            ),
            // 云朵只是图标，服务器名经语义标签读出（原封面角标的 Semantics 原样保留）。
            Semantics(
              label: browser.displayName,
              child: ShelfCardMeta(
                key: ValueKey<String>('music-server-album-meta-${album.id}'),
                title: album.title,
                leadingIcon: FushiIcons.cloud,
                subtitle: <String>[
                  album.artist ?? t.music_artist_unknown,
                  if (album.year != null) '${album.year}',
                ].join(' · '),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtistList extends StatelessWidget {
  const _ArtistList({required this.browser, required this.artists});

  final MusicServerBrowser browser;
  final List<MusicServerArtist> artists;

  @override
  Widget build(BuildContext context) {
    return FushiEntranceScope(
      child: ListView.builder(
        padding: musicBrowsePagePadding(context),
        itemCount: artists.length,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          final MusicServerArtist a = artists[i];
          return FushiPressScale(
            child: FushiGroupedListItem(
              key: ValueKey<String>('music-server-artist-${a.id}'),
              index: i,
              count: artists.length,
              onTap: () => unawaited(
                Navigator.of(context).push<void>(
                  adaptivePageRoute<void>(
                    context: context,
                    builder: (_) =>
                        MusicServerArtistPage(browser: browser, artist: a),
                  ),
                ),
              ),
              child: FushiListItem(
                leading: const FushiListLeadingIcon(FushiIcons.person),
                title: Text(a.name),
                subtitle: a.albumCount == null
                    ? null
                    : Text(t.music_server_album_count(count: a.albumCount!)),
                trailing: const FushiIcon(FushiIcons.chevronRight),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// 一位艺人的专辑。
class MusicServerArtistPage extends StatefulWidget {
  const MusicServerArtistPage({
    super.key,
    required this.browser,
    required this.artist,
  });

  final MusicServerBrowser browser;
  final MusicServerArtist artist;

  @override
  State<MusicServerArtistPage> createState() => _MusicServerArtistPageState();
}

class _MusicServerArtistPageState extends State<MusicServerArtistPage> {
  late Future<List<MusicServerAlbum>> _albums = widget.browser.artistAlbums(
    widget.artist.id,
  );

  @override
  Widget build(BuildContext context) => switch (widget.browser) {
    final AppleMusicCatalogClient c => AppleMusicArtistPage(
      catalog: c,
      artist: widget.artist,
    ),
    _ => _buildGeneric(context),
  };

  Widget _buildGeneric(BuildContext context) => musicBrowseScaffold(
    context,
    title: widget.artist.name,
    body: FutureBuilder<List<MusicServerAlbum>>(
      future: _albums,
      builder:
          (BuildContext context, AsyncSnapshot<List<MusicServerAlbum>> snap) {
            if (snap.hasError) {
              return musicBrowseErrorView(
                context,
                snap.error!,
                () => setState(
                  () => _albums = widget.browser.artistAlbums(widget.artist.id),
                ),
              );
            }
            final List<MusicServerAlbum>? albums = snap.data;
            if (albums == null) return const FushiLoadingView();
            return _AlbumGrid(browser: widget.browser, albums: albums);
          },
    ),
  );
}

/// 一张服务器专辑：封面、整碟播放 / 随机、曲目表。
class MusicServerAlbumPage extends ConsumerStatefulWidget {
  const MusicServerAlbumPage({
    super.key,
    required this.browser,
    required this.album,
  });

  final MusicServerBrowser browser;
  final MusicServerAlbum album;

  @override
  ConsumerState<MusicServerAlbumPage> createState() =>
      _MusicServerAlbumPageState();
}

class _MusicServerAlbumPageState extends ConsumerState<MusicServerAlbumPage> {
  late Future<List<MusicServerTrack>> _tracks = widget.browser.albumTracks(
    widget.album.id,
  );

  void _play(
    List<MusicServerTrack> tracks, {
    int start = 0,
    bool shuffle = false,
  }) {
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    unawaited(
      engine.playQueue(
        musicServerPlayItems(ref, widget.browser, tracks, album: widget.album),
        startIndex: start,
        context: MusicQueueContext.album,
        shuffle: shuffle,
        source: MusicPlaySource.serverAlbum(
          widget.browser.serverId,
          widget.album.id,
          title: widget.album.title,
          cover: widget.browser.coverUri(widget.album.coverRef)?.toString(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicServerAlbum album = widget.album;
    return musicBrowseScaffold(
      context,
      title: album.title,
      body: FutureBuilder<List<MusicServerTrack>>(
        future: _tracks,
        builder:
            (BuildContext context, AsyncSnapshot<List<MusicServerTrack>> snap) {
              if (snap.hasError) {
                return musicBrowseErrorView(
                  context,
                  snap.error!,
                  () => setState(
                    () => _tracks = widget.browser.albumTracks(album.id),
                  ),
                );
              }
              final List<MusicServerTrack>? tracks = snap.data;
              if (tracks == null) return const FushiLoadingView();
              final List<Widget> children = <Widget>[
                Wrap(
                  spacing: tokens.spacing.section,
                  runSpacing: tokens.spacing.gap,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: <Widget>[
                    musicAlbumDetailCover(
                      MusicCover(
                        coverPath: widget.browser
                            .coverUri(album.coverRef)
                            ?.toString(),
                        size: kMusicAlbumDetailCoverSize,
                      ),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        spacing: tokens.spacing.gap * 0.5,
                        children: <Widget>[
                          Text(
                            album.title,
                            style: context.fushiType.headlineSmall,
                          ),
                          Text(
                            <String>[
                              album.artist ?? t.music_artist_unknown,
                              if (album.year != null) '${album.year}',
                              t.music_tracks_count(count: tracks.length),
                              widget.browser.displayName,
                            ].join(' · '),
                            style: context.fushiType.bodyMedium,
                          ),
                          Wrap(
                            spacing: tokens.spacing.gap,
                            runSpacing: tokens.spacing.gap,
                            children: <Widget>[
                              FushiPressScale(
                                child: FushiFilledButton.icon(
                                  size: FushiButtonSize.m,
                                  key: const ValueKey<String>(
                                    'music_server_album_play',
                                  ),
                                  onPressed: tracks.isEmpty
                                      ? null
                                      : () => _play(tracks),
                                  icon: const FushiIcon(FushiIcons.play),
                                  label: Text(t.music_play_all),
                                ),
                              ),
                              FushiPressScale(
                                child: FushiFilledButton.tonalIcon(
                                  size: FushiButtonSize.m,
                                  onPressed: tracks.isEmpty
                                      ? null
                                      : () => _play(tracks, shuffle: true),
                                  icon: const FushiIcon(FushiIcons.shuffle),
                                  label: Text(t.music_shuffle_play),
                                ),
                              ),
                              ...appleMusicCollectionActions(
                                context,
                                ref,
                                widget.browser,
                                album: album,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                for (int i = 0; i < tracks.length; i++)
                  MusicServerTrackTile(
                    key: ValueKey<String>('music-server-track-${tracks[i].id}'),
                    browser: widget.browser,
                    tracks: tracks,
                    index: i,
                    onPlay: (int i) => _play(tracks, start: i),
                    leading: MusicServerTrackLeading.trackNo,
                    hideArtist: album.artist,
                  ),
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

/// 搜索一台服务器（专辑 / 艺人 / 曲目）。
class MusicServerSearchPage extends ConsumerStatefulWidget {
  const MusicServerSearchPage({super.key, required this.browser});

  final MusicServerBrowser browser;

  @override
  ConsumerState<MusicServerSearchPage> createState() =>
      _MusicServerSearchPageState();
}

class _MusicServerSearchPageState extends ConsumerState<MusicServerSearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  Future<MusicServerSearchResult>? _result;

  /// Apple Music catalog 的电台搜索结果（其它来源为 null）。
  Future<List<AppleMusicStation>>? _stations;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String q) {
    if (q.trim().isEmpty) return;
    setState(() {
      final MusicServerBrowser b = widget.browser;
      if (b is AppleMusicCatalogClient) {
        final Future<AppleMusicSearchResult> all = b.searchAll(q);
        _result = all.then((AppleMusicSearchResult r) => r.result);
        _stations = all.then((AppleMusicSearchResult r) => r.stations);
      } else {
        _result = b.search(q);
        _stations = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return musicBrowseScaffold(
      context,
      title: t.music_server_search,
      body: Builder(
        builder: (BuildContext context) => ListView(
          padding: musicBrowsePagePadding(context),
          children: <Widget>[
            FushiSearchField(
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              hintText: t.music_server_search_hint,
              onChanged: (_) {},
              onSubmitted: _submit,
            ),
            SizedBox(height: tokens.spacing.gap),
            if (_result != null)
              FutureBuilder<MusicServerSearchResult>(
                future: _result,
                builder:
                    (
                      BuildContext context,
                      AsyncSnapshot<MusicServerSearchResult> snap,
                    ) {
                      if (snap.hasError) {
                        return musicBrowseErrorView(
                          context,
                          snap.error!,
                          () => _submit(_controller.text),
                        );
                      }
                      final MusicServerSearchResult? r = snap.data;
                      if (r == null) return const FushiLoadingView();
                      if (r.isEmpty) {
                        return FushiPlaceholderMessage(
                          icon: FushiIcons.searchOff,
                          message: t.music_server_search_empty,
                        );
                      }
                      return FushiEntranceScope(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: tokens.spacing.gap,
                          children: <Widget>[
                            if (r.albums.isNotEmpty) ...<Widget>[
                              FushiSectionTitle(t.music_section_albums),
                              SizedBox(
                                height: 220,
                                // 桌面端默认 dragDevices 不含鼠标：专辑横排要鼠标也拖得动。
                                child: HorizontalDragScrollable(
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: r.albums.length,
                                    separatorBuilder: (_, _) =>
                                        SizedBox(width: tokens.spacing.gap),
                                    itemBuilder: fushiStaggeredItemBuilder(
                                      (BuildContext context, int i) => SizedBox(
                                        width: 160,
                                        child: MusicServerAlbumCard(
                                          browser: widget.browser,
                                          album: r.albums[i],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            if (r.playlists.isNotEmpty) ...<Widget>[
                              FushiSectionTitle(t.music_section_playlists),
                              SizedBox(
                                height: 220,
                                child: HorizontalDragScrollable(
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: r.playlists.length,
                                    separatorBuilder: (_, _) =>
                                        SizedBox(width: tokens.spacing.gap),
                                    itemBuilder: fushiStaggeredItemBuilder(
                                      (BuildContext context, int i) => SizedBox(
                                        width: 160,
                                        child: MusicServerPlaylistCard(
                                          browser: widget.browser,
                                          playlist: r.playlists[i],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            if (_stations
                                case final Future<List<AppleMusicStation>>
                                    stations)
                              AppleMusicStationsFutureRow(
                                catalog:
                                    widget.browser as AppleMusicCatalogClient,
                                stations: stations,
                              ),
                            if (r.tracks.isNotEmpty) ...<Widget>[
                              FushiSectionTitle(t.music_section_songs),
                              for (int i = 0; i < r.tracks.length; i++)
                                MusicServerTrackTile(
                                  browser: widget.browser,
                                  tracks: r.tracks,
                                  index: i,
                                  showAlbum: true,
                                  onPlay: (int i) => unawaited(
                                    ref
                                        .read(appProvider)
                                        .musicSession
                                        .engine
                                        .playQueue(
                                          musicServerPlayItems(
                                            ref,
                                            widget.browser,
                                            r.tracks,
                                          ),
                                          startIndex: i,
                                        ),
                                  ),
                                ),
                            ],
                            if (r.artists.isNotEmpty) ...<Widget>[
                              FushiSectionTitle(t.music_section_artists),
                              _ArtistColumn(
                                browser: widget.browser,
                                artists: r.artists,
                              ),
                            ],
                          ],
                        ),
                      );
                    },
              ),
          ],
        ),
      ),
    );
  }
}

class _ArtistColumn extends StatelessWidget {
  const _ArtistColumn({required this.browser, required this.artists});

  final MusicServerBrowser browser;
  final List<MusicServerArtist> artists;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      for (int i = 0; i < artists.length; i++)
        FushiPressScale(
          child: FushiGroupedListItem(
            index: i,
            count: artists.length,
            onTap: () => unawaited(
              Navigator.of(context).push<void>(
                adaptivePageRoute<void>(
                  context: context,
                  builder: (_) => MusicServerArtistPage(
                    browser: browser,
                    artist: artists[i],
                  ),
                ),
              ),
            ),
            child: FushiListItem(
              leading: const FushiListLeadingIcon(FushiIcons.person),
              title: Text(artists[i].name),
              trailing: const FushiIcon(FushiIcons.chevronRight),
            ),
          ),
        ),
    ],
  );
}

/// 曲目行最前面显示什么。
enum MusicServerTrackLeading { trackNo, position, icon }

/// 一首服务器曲目的列表行（专辑 / 歌单 / 搜索 / Apple Music 榜单共用）：标题、艺人（与
/// [hideArtist] 相同时不重复显示）、时长；Apple Music 曲目尾部多一个「更多」按钮（喜欢 /
/// 加入资料库 / 加入歌单 / 电台 / 去艺人 …）。点整行交给 [onPlay]（传行号）。
class MusicServerTrackTile extends StatelessWidget {
  const MusicServerTrackTile({
    super.key,
    required this.browser,
    required this.tracks,
    required this.index,
    required this.onPlay,
    this.leading = MusicServerTrackLeading.icon,
    this.hideArtist,
    this.showAlbum = false,
  });

  final MusicServerBrowser browser;
  final List<MusicServerTrack> tracks;
  final int index;
  final void Function(int index) onPlay;
  final MusicServerTrackLeading leading;
  final String? hideArtist;
  final bool showAlbum;

  @override
  Widget build(BuildContext context) {
    final MusicServerTrack track = tracks[index];
    final String subtitle = <String>[
      if (track.artist != null && track.artist != hideArtist) track.artist!,
      if (showAlbum && track.album != null) track.album!,
    ].join(' · ');
    final MusicItemMenu? menu =
        appleMusicTrackMenu(context, browser, track) ??
        musicServerTrackMenu(context, browser, track);
    return musicWithContextMenu(
      menu,
      FushiPressScale(
        child: FushiGroupedListItem(
          index: index,
          count: tracks.length,
          onTap: () => onPlay(index),
          child: FushiListItem(
            leading: switch (leading) {
              MusicServerTrackLeading.icon => const FushiListLeadingIcon(
                FushiIcons.music,
              ),
              MusicServerTrackLeading.trackNo ||
              MusicServerTrackLeading.position => SizedBox(
                width: 28,
                child: Text(
                  leading == MusicServerTrackLeading.position
                      ? '${index + 1}'
                      : track.trackNo?.toString() ?? '',
                  textAlign: TextAlign.end,
                  style: context.fushiType.bodySmall,
                ),
              ),
            },
            title: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: subtitle.isEmpty
                ? null
                : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  formatMusicDuration(track.durationMs),
                  style: context.fushiType.bodySmall,
                ),
                ?menu?.button(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 服务器歌单卡（与专辑卡同一套「唱片」几何，副行是作者 / 曲目数）。
class MusicServerPlaylistCard extends StatelessWidget {
  const MusicServerPlaylistCard({
    super.key,
    required this.browser,
    required this.playlist,
    this.onChanged,
  });

  final MusicServerBrowser browser;
  final MusicServerPlaylist playlist;

  /// 打开的歌单页里改了歌单（改名 / 删除 / 曲目）时调用。
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return FushiHoverLift(
      scale: kMusicHoverLiftScale,
      builder: (BuildContext context, bool _) => shelfCoverCard(
        onTap: () => unawaited(
          Navigator.of(context).push<void>(
            adaptivePageRoute<void>(
              context: context,
              builder: (_) => MusicServerPlaylistPage(
                browser: browser,
                playlist: playlist,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AspectRatio(
              aspectRatio: kShelfAlbumAspectRatio,
              child: ShelfCoverFrame(
                child: MusicCover(
                  coverPath: browser.coverUri(playlist.coverRef)?.toString(),
                ),
              ),
            ),
            Semantics(
              label: browser.displayName,
              child: ShelfCardMeta(
                key: ValueKey<String>(
                  'music-server-playlist-meta-${playlist.id}',
                ),
                title: playlist.title,
                leadingIcon: FushiIcons.playlist,
                subtitle: <String>[
                  ?playlist.curator,
                  if (playlist.trackCount != null)
                    t.music_tracks_count(count: playlist.trackCount!),
                ].join(' · '),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「歌单」分区：一台服务器的歌单网格（按服务器分页往下翻）。Apple Music 资料库在顶部多一个
/// 「新建歌单」。
class MusicServerPlaylistsView extends StatefulWidget {
  const MusicServerPlaylistsView({super.key, required this.browser});

  final MusicServerBrowser browser;

  @override
  State<MusicServerPlaylistsView> createState() =>
      _MusicServerPlaylistsViewState();
}

class _MusicServerPlaylistsViewState extends State<MusicServerPlaylistsView> {
  final List<MusicServerPlaylist> _items = <MusicServerPlaylist>[];
  int? _next = 0;
  bool _loading = false;
  Object? _error;

  /// 重读代次：新建歌单后整表重读，晚回来的旧页丢掉。
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    final int? offset = _next;
    if (_loading || offset == null) return;
    final int gen = _gen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final MusicServerPage<MusicServerPlaylist> page = await widget.browser
          .listPlaylists(offset: offset);
      if (!mounted || gen != _gen) return;
      setState(() {
        _items.addAll(page.items);
        _next = page.nextOffset;
      });
    } on Object catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e);
    } finally {
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  void _reload() {
    setState(() {
      _gen++;
      _items.clear();
      _next = 0;
      _loading = false;
      _error = null;
    });
    unawaited(_loadMore());
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (_error != null && _items.isEmpty) {
      return musicBrowseErrorView(context, _error!, _reload);
    }
    if (_items.isEmpty && (_loading || _next != null)) {
      return const FushiLoadingView();
    }
    final Widget? create =
        appleMusicCreatePlaylistButton(
          context,
          widget.browser,
          onCreated: _reload,
        ) ??
        _serverCreatePlaylistButton(
          context,
          widget.browser,
          onCreated: _reload,
        );
    if (_items.isEmpty) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.playlist,
          message: t.music_playlists_empty,
          action: create,
        ),
      );
    }
    final EdgeInsets padding = musicBrowsePagePadding(context);
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification n) {
        if (n.metrics.extentAfter < 600) unawaited(_loadMore());
        return false;
      },
      child: ShelfCoverMaterialScope(
        material: ShelfCoverMaterial.glossyAlbum,
        child: FushiEntranceScope(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                CustomScrollView(
                  slivers: <Widget>[
                    if (create != null)
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          padding.left,
                          padding.top,
                          padding.right,
                          tokens.spacing.gap,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: create,
                          ),
                        ),
                      ),
                    SliverPadding(
                      padding: create == null
                          ? padding
                          : padding.copyWith(top: 0),
                      sliver: SliverGrid.builder(
                        gridDelegate: musicAlbumGridDelegate(
                          context,
                          constraints.maxWidth,
                        ),
                        itemCount: _items.length,
                        itemBuilder: fushiStaggeredItemBuilder((
                          BuildContext context,
                          int i,
                        ) {
                          final MusicServerPlaylist p = _items[i];
                          return MusicServerPlaylistCard(
                            key: ValueKey<String>(
                              'music-server-playlist-${p.id}',
                            ),
                            browser: widget.browser,
                            playlist: p,
                            onChanged: _reload,
                          );
                        }),
                      ),
                    ),
                  ],
                ),
          ),
        ),
      ),
    );
  }
}

/// 能改歌单的服务器（Jellyfin / Emby）曲目的菜单：加入歌单（含新建）。Apple Music 走自己的
/// 菜单（[appleMusicTrackMenu]），其它来源回 null（行尾不留空位）。
MusicItemMenu? musicServerTrackMenu(
  BuildContext context,
  MusicServerBrowser browser,
  MusicServerTrack track,
) {
  final MusicServerPlaylistEditor? editor = MusicServerPlaylistEditor.of(
    browser,
  );
  if (editor == null) return null;
  return MusicItemMenu(
    buttonKey: ValueKey<String>('music-server-track-menu-${track.id}'),
    open: (MusicMenuAnchor? anchor) => unawaited(
      showMusicActionMenu(
        context,
        anchor: anchor,
        errorText: musicPlaylistErrorText,
        actions: <MusicMenuAction>[
          MusicMenuAction(
            id: 'addToPlaylist',
            label: t.music_action_add_to_playlist,
            icon: FushiIcons.playlist,
            run: (BuildContext c) =>
                musicAddToPlaylist(c, editor, <String>[track.id]),
          ),
        ],
      ),
    ),
  );
}

/// 「歌单」分区顶部的「新建歌单」（能改歌单的服务器）；其它来源回 null。
Widget? _serverCreatePlaylistButton(
  BuildContext context,
  MusicServerBrowser browser, {
  required VoidCallback onCreated,
}) {
  final MusicServerPlaylistEditor? editor = MusicServerPlaylistEditor.of(
    browser,
  );
  if (editor == null) return null;
  return musicCreatePlaylistButton(
    context,
    editor,
    key: const ValueKey<String>('music-server-new-playlist'),
    onCreated: onCreated,
    errorText: musicPlaylistErrorText,
  );
}

/// 一个服务器歌单：封面、简介、整单播放 / 随机、曲目表（歌单顺序）。能改歌单的服务器
/// （Jellyfin / Emby）且歌单可改时，曲目可拖拽重排、可从歌单移除，并能改名 / 删除；
/// 这类服务器都能导出 `.m3u8`（只收服务器报了文件路径的曲目）。
class MusicServerPlaylistPage extends ConsumerStatefulWidget {
  const MusicServerPlaylistPage({
    super.key,
    required this.browser,
    required this.playlist,
    this.onChanged,
  });

  final MusicServerBrowser browser;
  final MusicServerPlaylist playlist;

  /// 改名 / 删除 / 改了曲目之后调用（歌单网格据此重读）。
  final VoidCallback? onChanged;

  @override
  ConsumerState<MusicServerPlaylistPage> createState() =>
      _MusicServerPlaylistPageState();
}

class _MusicServerPlaylistPageState
    extends ConsumerState<MusicServerPlaylistPage> {
  List<MusicServerTrack>? _tracks;
  Object? _error;
  late String _title = widget.playlist.title;

  /// 重读代次：晚回来的旧请求丢掉。
  int _gen = 0;

  MusicServerPlaylistEditing? get _editing =>
      widget.browser is MusicServerPlaylistEditing
      ? widget.browser as MusicServerPlaylistEditing
      : null;

  /// 本页能不能改这个歌单。
  bool get _editable => _editing != null && widget.playlist.editable;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final int gen = ++_gen;
    setState(() => _error = null);
    try {
      final List<MusicServerTrack> tracks = await widget.browser.playlistTracks(
        widget.playlist.id,
      );
      if (mounted && gen == _gen) setState(() => _tracks = tracks);
    } on Object catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e);
    }
  }

  void _play(
    List<MusicServerTrack> tracks, {
    int start = 0,
    bool shuffle = false,
  }) {
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    final MusicServerPlaylist p = widget.playlist;
    unawaited(
      engine.playQueue(
        musicServerPlayItems(ref, widget.browser, tracks),
        startIndex: start,
        shuffle: shuffle,
        source: MusicPlaySource.serverPlaylist(
          widget.browser.serverId,
          p.id,
          title: _title,
          cover: widget.browser.coverUri(p.coverRef)?.toString(),
        ),
      ),
    );
  }

  /// 改动成功后：通知网格、按服务器结果重读（条目 id 以服务器为准）。
  void _changed() {
    widget.onChanged?.call();
    unawaited(_reload());
  }

  Future<void> _reorder(int from, int to) async {
    final List<MusicServerTrack>? tracks = _tracks;
    final MusicServerPlaylistEditing? editing = _editing;
    if (tracks == null || editing == null || from == to) return;
    final String? entryId = tracks[from].playlistEntryId;
    if (entryId == null) return;
    final List<MusicServerTrack> next = List<MusicServerTrack>.of(tracks);
    next.insert(to, next.removeAt(from));
    setState(() => _tracks = next);
    try {
      await editing.movePlaylistEntry(widget.playlist.id, entryId, to);
    } on Object catch (e) {
      FushiToast.show(
        msg: musicPlaylistErrorText(e),
        severity: ToastSeverity.error,
      );
    }
    _changed();
  }

  Future<void> _remove(MusicServerTrack track) async {
    final MusicServerPlaylistEditing? editing = _editing;
    final String? entryId = track.playlistEntryId;
    if (editing == null || entryId == null) return;
    await editing.removeFromPlaylist(widget.playlist.id, <String>[entryId]);
    FushiToast.show(
      msg: t.music_action_removed_from_playlist(name: _title),
      severity: ToastSeverity.success,
    );
    _changed();
  }

  MusicItemMenu? _rowMenu(BuildContext context, int i) {
    final MusicServerTrack track = _tracks![i];
    final MusicServerPlaylistEditor? editor = MusicServerPlaylistEditor.of(
      widget.browser,
    );
    if (editor == null) {
      return appleMusicTrackMenu(context, widget.browser, track);
    }
    return MusicItemMenu(
      buttonKey: ValueKey<String>(
        'music-server-playlist-row-menu-$i-${track.id}',
      ),
      open: (MusicMenuAnchor? anchor) => unawaited(
        showMusicActionMenu(
          context,
          anchor: anchor,
          errorText: musicPlaylistErrorText,
          actions: <MusicMenuAction>[
            if (_editable && track.playlistEntryId != null)
              MusicMenuAction(
                id: 'remove',
                label: t.music_action_remove_from_playlist,
                icon: FushiIcons.removeCircle,
                run: (_) => _remove(track),
              ),
            MusicMenuAction(
              id: 'addToPlaylist',
              label: t.music_action_add_to_playlist,
              icon: FushiIcons.playlist,
              run: (BuildContext c) async {
                if (await musicAddToPlaylist(c, editor, <String>[track.id])) {
                  widget.onChanged?.call();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _editActions(
    BuildContext context,
    List<MusicServerTrack> tracks,
  ) {
    final MusicServerPlaylistEditing? editing = _editing;
    if (editing == null) return const <Widget>[];
    return <Widget>[
      if (_editable)
        FushiIconButton(
          key: const ValueKey<String>('music_server_playlist_rename'),
          icon: FushiIcons.edit,
          tooltip: t.music_action_rename_playlist,
          padTouchTarget: true,
          onTap: () async {
            final String? name = await musicRenamePlaylist(
              context,
              current: _title,
              rename: (String name) =>
                  editing.renamePlaylist(widget.playlist.id, name),
            );
            if (name == null || !mounted) return;
            setState(() => _title = name);
            widget.onChanged?.call();
          },
        ),
      FushiIconButton(
        key: const ValueKey<String>('music_server_playlist_export'),
        icon: FushiIcons.share,
        tooltip: t.music_action_export_playlist,
        padTouchTarget: true,
        onTap: tracks.isEmpty
            ? null
            : () {
                final ({List<MusicPlaylistExportItem> items, int skipped}) r =
                    musicServerExportItems(tracks);
                unawaited(
                  musicExportPlaylistM3u8(
                    name: _title,
                    items: r.items,
                    skipped: r.skipped,
                  ),
                );
              },
      ),
      if (_editable)
        FushiIconButton(
          key: const ValueKey<String>('music_server_playlist_delete'),
          icon: FushiIcons.delete,
          tooltip: t.music_action_delete_playlist,
          padTouchTarget: true,
          onTap: () async {
            final bool deleted = await musicDeletePlaylist(
              context,
              name: _title,
              delete: () => editing.deletePlaylist(widget.playlist.id),
            );
            if (!deleted || !context.mounted) return;
            widget.onChanged?.call();
            unawaited(Navigator.of(context).maybePop());
          },
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicServerPlaylist p = widget.playlist;
    final List<MusicServerTrack>? tracks = _tracks;
    final Object? error = _error;
    final Widget body;
    if (error != null && tracks == null) {
      body = musicBrowseErrorView(context, error, () => unawaited(_reload()));
    } else if (tracks == null) {
      body = const FushiLoadingView();
    } else {
      final bool reorderable =
          _editable &&
          tracks.every((MusicServerTrack tr) => tr.playlistEntryId != null);
      final List<Widget> children = <Widget>[
        Wrap(
          spacing: tokens.spacing.section,
          runSpacing: tokens.spacing.gap,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: <Widget>[
            musicAlbumDetailCover(
              MusicCover(
                coverPath: widget.browser.coverUri(p.coverRef)?.toString(),
                size: kMusicAlbumDetailCoverSize,
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: tokens.spacing.gap * 0.5,
                children: <Widget>[
                  Text(_title, style: context.fushiType.headlineSmall),
                  Text(
                    <String>[
                      if (p.curator != null)
                        t.music_plugin_playlist_by(name: p.curator!),
                      t.music_tracks_count(count: tracks.length),
                      widget.browser.displayName,
                    ].join(' · '),
                    style: context.fushiType.bodyMedium,
                  ),
                  if (p.description != null)
                    Text(
                      p.description!,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.bodySmall,
                    ),
                  Wrap(
                    spacing: tokens.spacing.gap,
                    runSpacing: tokens.spacing.gap,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      FushiPressScale(
                        child: FushiFilledButton.icon(
                          size: FushiButtonSize.m,
                          key: const ValueKey<String>(
                            'music_server_playlist_play',
                          ),
                          onPressed: tracks.isEmpty
                              ? null
                              : () => _play(tracks),
                          icon: const FushiIcon(FushiIcons.play),
                          label: Text(t.music_play_all),
                        ),
                      ),
                      FushiPressScale(
                        child: FushiFilledButton.tonalIcon(
                          size: FushiButtonSize.m,
                          onPressed: tracks.isEmpty
                              ? null
                              : () => _play(tracks, shuffle: true),
                          icon: const FushiIcon(FushiIcons.shuffle),
                          label: Text(t.music_shuffle_play),
                        ),
                      ),
                      ...appleMusicCollectionActions(
                        context,
                        ref,
                        widget.browser,
                        playlist: p,
                      ),
                      ..._editActions(context, tracks),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (tracks.isEmpty)
          FushiPlaceholderMessage(
            icon: FushiIcons.playlist,
            message: t.music_server_playlist_empty,
          )
        else if (_editing != null)
          MusicPlaylistTrackColumn(
            rows: <MusicPlaylistTrackRowData>[
              for (int i = 0; i < tracks.length; i++)
                MusicPlaylistTrackRowData(
                  key: tracks[i].playlistEntryId ?? '$i-${tracks[i].id}',
                  title: tracks[i].title,
                  subtitle: <String>[
                    ?tracks[i].artist,
                    ?tracks[i].album,
                  ].join(' · '),
                  durationMs: tracks[i].durationMs,
                ),
            ],
            onPlay: (int i) => _play(tracks, start: i),
            onReorder: reorderable
                ? (int from, int to) => unawaited(_reorder(from, to))
                : null,
            menuOf: _rowMenu,
          )
        else
          for (int i = 0; i < tracks.length; i++)
            MusicServerTrackTile(
              key: ValueKey<String>(
                'music-server-playlist-track-$i-${tracks[i].id}',
              ),
              browser: widget.browser,
              tracks: tracks,
              index: i,
              onPlay: (int i) => _play(tracks, start: i),
              leading: MusicServerTrackLeading.position,
              showAlbum: true,
            ),
      ];
      body = FushiEntranceScope(
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
    }
    return musicBrowseScaffold(context, title: _title, body: body);
  }
}
