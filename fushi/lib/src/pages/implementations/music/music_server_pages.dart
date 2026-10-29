/// 服务器曲库页（音乐方案 §13 P5）：服务器清单 → 专辑 / 艺人 / 搜索 → 专辑曲目 → 播放。
/// 只读浏览；每一层都按服务器分页原样取（不把整库拍平成本地行），播放交给音乐引擎一条流。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 打开服务器清单页。
Future<void> openMusicServerList(BuildContext context) =>
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => const MusicServerListPage(),
      ),
    );

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
Widget musicAlbumDetailCover(Widget cover) => ShelfCoverMaterialScope(
  material: ShelfCoverMaterial.glossyAlbum,
  child: SizedBox.square(
    dimension: kMusicAlbumDetailCoverSize,
    child: AspectRatio(
      aspectRatio: kShelfAlbumAspectRatio,
      child: ShelfCoverFrame(child: cover),
    ),
  ),
);

/// 服务器曲目 → 播放项（按设置的码率上限）。
List<MusicPlayItem> _playItems(
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
Widget _scaffold(
  BuildContext context, {
  required String title,
  required Widget body,
  List<FushiToolbarItem> actions = const <FushiToolbarItem>[],
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final NavigatorState? navigator = Navigator.maybeOf(context);
  return FushiPageScaffold(
    title: title,
    bottomNavigationBar: const MusicNowPlayingBar(),
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
                    label: MaterialLocalizations.of(context).backButtonTooltip,
                    onPressed: () => unawaited(navigator.maybePop()),
                  ),
              ],
              actions: <List<FushiToolbarItem>>[
                if (actions.isNotEmpty) actions,
              ],
            ),
          ),
    body: body,
  );
}

Widget _errorView(BuildContext context, Object error, VoidCallback retry) =>
    Center(
      child: FushiPlaceholderMessage(
        icon: FushiIcons.cloudOff,
        message: t.music_server_load_failed,
        detail: '$error',
        action: FushiFilledButton.icon(
          onPressed: retry,
          icon: const FushiIcon(FushiIcons.refresh),
          label: Text(t.music_server_retry),
        ),
      ),
    );

EdgeInsets _pagePadding(BuildContext context) {
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

/// 服务器清单。
class MusicServerListPage extends ConsumerStatefulWidget {
  const MusicServerListPage({super.key, this.loader});

  /// 测试注入：替代读配置。
  final Future<List<MusicServerBrowser>> Function()? loader;

  @override
  ConsumerState<MusicServerListPage> createState() =>
      _MusicServerListPageState();
}

class _MusicServerListPageState extends ConsumerState<MusicServerListPage> {
  late Future<List<MusicServerBrowser>> _servers = _load();

  Future<List<MusicServerBrowser>> _load() =>
      widget.loader?.call() ?? loadMusicServerBrowsers(ref.read(appProvider));

  @override
  Widget build(BuildContext context) {
    return _scaffold(
      context,
      title: t.music_servers_title,
      body: FutureBuilder<List<MusicServerBrowser>>(
        future: _servers,
        builder:
            (
              BuildContext context,
              AsyncSnapshot<List<MusicServerBrowser>> snap,
            ) {
              if (snap.hasError) {
                return _errorView(
                  context,
                  snap.error!,
                  () => setState(() => _servers = _load()),
                );
              }
              final List<MusicServerBrowser>? servers = snap.data;
              if (servers == null) return const FushiLoadingView();
              if (servers.isEmpty) {
                return Center(
                  child: FushiPlaceholderMessage(
                    icon: FushiIcons.server,
                    message: t.music_servers_empty,
                    detail: t.music_servers_empty_hint,
                  ),
                );
              }
              return FushiEntranceScope(
                child: ListView.builder(
                  padding: _pagePadding(context),
                  itemCount: servers.length,
                  itemBuilder: fushiStaggeredItemBuilder((
                    BuildContext context,
                    int i,
                  ) {
                    final MusicServerBrowser s = servers[i];
                    return FushiPressScale(
                      child: FushiGroupedListItem(
                        key: ValueKey<String>('music-server-${s.serverId}'),
                        index: i,
                        count: servers.length,
                        onTap: () => unawaited(
                          Navigator.of(context).push<void>(
                            adaptivePageRoute<void>(
                              context: context,
                              builder: (_) => MusicServerBrowsePage(browser: s),
                            ),
                          ),
                        ),
                        child: FushiListItem(
                          leading: const FushiListLeadingIcon(
                            FushiIcons.server,
                          ),
                          title: Text(s.displayName),
                          subtitle: Text(switch (s.kind) {
                            MusicServerKind.jellyfin => 'Jellyfin / Emby',
                            MusicServerKind.subsonic => 'OpenSubsonic',
                          }),
                          trailing: const FushiIcon(FushiIcons.chevronRight),
                        ),
                      ),
                    );
                  }),
                ),
              );
            },
      ),
    );
  }
}

enum _BrowseSection { albums, artists }

/// 一台服务器：专辑 / 艺人两个分区 + 搜索。
class MusicServerBrowsePage extends ConsumerStatefulWidget {
  const MusicServerBrowsePage({super.key, required this.browser});

  final MusicServerBrowser browser;

  @override
  ConsumerState<MusicServerBrowsePage> createState() =>
      _MusicServerBrowsePageState();
}

class _MusicServerBrowsePageState extends ConsumerState<MusicServerBrowsePage> {
  _BrowseSection _section = _BrowseSection.albums;
  final List<MusicServerAlbum> _albums = <MusicServerAlbum>[];
  int? _next = 0;
  bool _loading = false;
  Object? _error;
  Future<List<MusicServerArtist>>? _artists;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMore());
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
        ButtonSegment<_BrowseSection>(
          value: _BrowseSection.albums,
          label: Text(t.music_section_albums),
        ),
        ButtonSegment<_BrowseSection>(
          value: _BrowseSection.artists,
          label: Text(t.music_section_artists),
        ),
      ],
      selected: <_BrowseSection>{_section},
      onSelectionChanged: (Set<_BrowseSection> v) => setState(() {
        _section = v.first;
        if (_section == _BrowseSection.artists) {
          _artists ??= widget.browser.listArtists();
        }
      }),
    );
    final Widget content = switch (_section) {
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
                return _errorView(
                  context,
                  snap.error!,
                  () => setState(() => _artists = widget.browser.listArtists()),
                );
              }
              final List<MusicServerArtist>? artists = snap.data;
              if (artists == null) return const FushiLoadingView();
              return _ArtistList(browser: widget.browser, artists: artists);
            },
      ),
    };
    return _scaffold(
      context,
      title: widget.browser.displayName,
      actions: <FushiToolbarItem>[
        FushiToolbarItem(
          key: const ValueKey<String>('music_server_search'),
          icon: FushiIcons.search,
          label: t.music_server_search,
          onPressed: () => unawaited(
            Navigator.of(context).push<void>(
              adaptivePageRoute<void>(
                context: context,
                builder: (_) => MusicServerSearchPage(browser: widget.browser),
              ),
            ),
          ),
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
                    child: segmented,
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: fushiMotionDuration(context, FushiMotion.medium),
                    child: KeyedSubtree(
                      key: ValueKey<_BrowseSection>(_section),
                      child: content,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _albumsErrorView(BuildContext context) =>
      _errorView(context, _error!, () {
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
        padding: _pagePadding(context),
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
  Widget build(BuildContext context) => _scaffold(
    context,
    title: widget.artist.name,
    body: FutureBuilder<List<MusicServerAlbum>>(
      future: _albums,
      builder:
          (BuildContext context, AsyncSnapshot<List<MusicServerAlbum>> snap) {
            if (snap.hasError) {
              return _errorView(
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
        _playItems(ref, widget.browser, tracks, album: widget.album),
        startIndex: start,
        context: MusicQueueContext.album,
        shuffle: shuffle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicServerAlbum album = widget.album;
    return _scaffold(
      context,
      title: album.title,
      body: FutureBuilder<List<MusicServerTrack>>(
        future: _tracks,
        builder:
            (BuildContext context, AsyncSnapshot<List<MusicServerTrack>> snap) {
              if (snap.hasError) {
                return _errorView(
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
                for (int i = 0; i < tracks.length; i++)
                  FushiPressScale(
                    child: FushiGroupedListItem(
                      key: ValueKey<String>(
                        'music-server-track-${tracks[i].id}',
                      ),
                      index: i,
                      count: tracks.length,
                      onTap: () => _play(tracks, start: i),
                      child: FushiListItem(
                        leading: SizedBox(
                          width: 28,
                          child: Text(
                            tracks[i].trackNo?.toString() ?? '',
                            textAlign: TextAlign.end,
                            style: context.fushiType.bodySmall,
                          ),
                        ),
                        title: Text(
                          tracks[i].title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle:
                            tracks[i].artist == null ||
                                tracks[i].artist == album.artist
                            ? null
                            : Text(tracks[i].artist!),
                        trailing: Text(
                          formatMusicDuration(tracks[i].durationMs),
                          style: context.fushiType.bodySmall,
                        ),
                      ),
                    ),
                  ),
              ];
              return FushiEntranceScope(
                child: ListView.separated(
                  padding: _pagePadding(context),
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

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String q) {
    if (q.trim().isEmpty) return;
    setState(() => _result = widget.browser.search(q));
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return _scaffold(
      context,
      title: t.music_server_search,
      body: Builder(
        builder: (BuildContext context) => ListView(
          padding: _pagePadding(context),
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
                        return _errorView(
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
                            if (r.tracks.isNotEmpty) ...<Widget>[
                              FushiSectionTitle(t.music_section_songs),
                              for (int i = 0; i < r.tracks.length; i++)
                                FushiPressScale(
                                  child: FushiGroupedListItem(
                                    index: i,
                                    count: r.tracks.length,
                                    onTap: () => unawaited(
                                      ref
                                          .read(appProvider)
                                          .musicSession
                                          .engine
                                          .playQueue(
                                            _playItems(
                                              ref,
                                              widget.browser,
                                              r.tracks,
                                            ),
                                            startIndex: i,
                                          ),
                                    ),
                                    child: FushiListItem(
                                      leading: const FushiListLeadingIcon(
                                        FushiIcons.music,
                                      ),
                                      title: Text(r.tracks[i].title),
                                      subtitle: Text(
                                        <String>[
                                          ?r.tracks[i].artist,
                                          ?r.tracks[i].album,
                                        ].join(' · '),
                                      ),
                                      trailing: Text(
                                        formatMusicDuration(
                                          r.tracks[i].durationMs,
                                        ),
                                        style: context.fushiType.bodySmall,
                                      ),
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
