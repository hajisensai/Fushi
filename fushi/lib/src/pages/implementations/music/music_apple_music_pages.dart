/// Apple Music 专属页面与动作（MusicKit 方案的「完整 Apple Music」）：
///
/// - **主页**（catalog 来源的第一个分区，[AppleMusicHomeView]）：已登录时有个人电台、为你推荐、
///   最近播放（专辑 / 歌单 / 电台 + 歌曲）、重度轮播；始终有直播电台（需整曲权限才放得了，未
///   登录时不显示）、该地区榜单（歌曲 / 专辑 / 歌单）与流派入口（[AppleMusicGenrePage]）。
/// - **艺人页**（[AppleMusicArtistPage]）：热门歌曲、专辑、精选歌单、相似艺人、艺人电台。
/// - **资料库歌曲**（资料库来源的「歌曲」分区，[AppleMusicLibrarySongsView]）。
/// - **曲目菜单**（[appleMusicTrackMenuButton]）：喜欢 / 不喜欢、加入资料库、加入歌单（含新建）、
///   以这首起电台、去艺人 / 去专辑。
/// - **专辑 / 歌单的更多操作**（[appleMusicCollectionActions]）与资料库「新建歌单」。
///
/// 所有写操作都只在已连接账号、订阅有效时出现（[AppleMusicLinkedSources.signedIn]）。Apple Music
/// 公开 API 不支持从歌单删歌 / 删歌单 / 改名，所以没有这些入口。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_items.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart';
import 'package:fushi_engine/media/music/apple_music/apple_music_personal_client.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';

import 'package:fushi/src/media/music/apple_music/apple_music_favorites.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_station_item.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 横排卡片的宽 / 行高（与服务器搜索页的专辑横排同一几何）。
const double _kRowCardWidth = 160;
const double _kRowHeight = 220;

/// 主页「榜单歌曲」「最近播放的歌曲」先露几首（其余进「查看全部」）。
const int _kInlineSongs = 6;

AppModel _app(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false).read(appProvider);

void _push(BuildContext context, Widget page) => unawaited(
  Navigator.of(
    context,
  ).push<void>(adaptivePageRoute<void>(context: context, builder: (_) => page)),
);

void _toastError(Object e) => FushiToast.show(
  msg: t.music_apple_music_action_failed(error: '$e'),
  severity: ToastSeverity.error,
);

/// 一组服务器曲目从 [start] 开始播（专辑 / 歌单以外的「混排」队列）。
void _playTracks(
  BuildContext context,
  MusicServerBrowser browser,
  List<MusicServerTrack> tracks, {
  int start = 0,
  bool shuffle = false,
}) {
  if (tracks.isEmpty) return;
  final AppModel app = _app(context);
  final int? limit = musicServerBitrateLimit(
    app.isPreferencesReady ? app.prefsRepo.musicServerMaxBitrate : 0,
  );
  unawaited(
    app.musicSession.engine.playQueue(
      <MusicPlayItem>[
        for (final MusicServerTrack t in tracks)
          musicServerPlayItem(browser, t, maxBitrateKbps: limit),
      ],
      startIndex: start,
      shuffle: shuffle,
    ),
  );
}

/// 放一个电台（电台单独成一个队列，由 MusicKit 自己往下放）。要整曲权限。
void playAppleMusicStation(
  BuildContext context,
  AppleMusicCatalogClient catalog,
  AppleMusicStation station,
) {
  final AppModel app = _app(context);
  if (!app.appleMusicAccount.canPlayFullTracks) {
    FushiToast.show(
      msg: t.music_apple_music_station_needs_account,
      severity: ToastSeverity.warning,
    );
    return;
  }
  unawaited(
    app.musicSession.engine.playQueue(<MusicPlayItem>[
      appleMusicStationPlayItem(
        stationId: station.id,
        storefront: catalog.storefront,
        name: station.name,
        coverUrl: catalog.coverUri(station.coverRef)?.toString(),
      ),
    ]),
  );
}

/// 找 [seed] 对应的电台并放；没有电台时提示。
Future<void> _startStationFor(
  BuildContext context,
  AppleMusicCatalogClient catalog,
  AppleMusicStationSeed seed,
  String id,
) async {
  try {
    final AppleMusicStation? st = await catalog.stationFor(seed, id);
    if (!context.mounted) return;
    if (st == null) {
      FushiToast.show(
        msg: t.music_action_station_unavailable,
        severity: ToastSeverity.warning,
      );
      return;
    }
    playAppleMusicStation(context, catalog, st);
  } on Object catch (e) {
    _toastError(e);
  }
}

// =========================================================================
// 卡片与横排
// =========================================================================

/// 电台卡（方形封面 + 名称；直播电台副行标「直播」——封面不压角标）。
class AppleMusicStationCard extends StatelessWidget {
  const AppleMusicStationCard({
    super.key,
    required this.catalog,
    required this.station,
  });

  final AppleMusicCatalogClient catalog;
  final AppleMusicStation station;

  @override
  Widget build(BuildContext context) => FushiHoverLift(
    scale: kMusicHoverLiftScale,
    builder: (BuildContext context, bool _) => shelfCoverCard(
      onTap: () => playAppleMusicStation(context, catalog, station),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AspectRatio(
            aspectRatio: kShelfAlbumAspectRatio,
            child: ShelfCoverFrame(
              child: MusicCover(
                coverPath: catalog.coverUri(station.coverRef)?.toString(),
              ),
            ),
          ),
          ShelfCardMeta(
            key: ValueKey<String>('apple-music-station-meta-${station.id}'),
            title: station.name,
            leadingIcon: FushiIcons.cast,
            subtitle: <String>[
              if (station.isLive) t.music_apple_music_station_live,
              ?station.subtitle,
            ].join(' · '),
          ),
        ],
      ),
    ),
  );
}

/// 推荐 / 最近播放里的单曲卡：点了从这首开始放整行歌曲。
class _SongCard extends StatelessWidget {
  const _SongCard({
    super.key,
    required this.catalog,
    required this.track,
    required this.onTap,
  });

  final AppleMusicCatalogClient catalog;
  final MusicServerTrack track;
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
            aspectRatio: kShelfAlbumAspectRatio,
            child: ShelfCoverFrame(
              child: MusicCover(
                coverPath: catalog.coverUri(track.coverRef)?.toString(),
              ),
            ),
          ),
          ShelfCardMeta(
            key: ValueKey<String>('apple-music-song-meta-${track.id}'),
            title: track.title,
            leadingIcon: FushiIcons.music,
            subtitle: track.artist ?? t.music_artist_unknown,
          ),
        ],
      ),
    ),
  );
}

/// 一行横排卡片（标题 + 横向滚动的卡片）。
class _ShelfRow extends StatelessWidget {
  const _ShelfRow({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiSectionTitle(title),
        SizedBox(
          height: _kRowHeight,
          child: ShelfCoverMaterialScope(
            material: ShelfCoverMaterial.glossyAlbum,
            // 桌面端默认 dragDevices 不含鼠标：横排要鼠标也拖得动。
            child: HorizontalDragScrollable(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: children.length,
                separatorBuilder: (_, _) => SizedBox(width: tokens.spacing.gap),
                itemBuilder: fushiStaggeredItemBuilder(
                  (BuildContext context, int i) =>
                      SizedBox(width: _kRowCardWidth, child: children[i]),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 一组混排条目 → 卡片（资料库条目用资料库来源打开，其余用 catalog）。
List<Widget> _itemCards(
  BuildContext context,
  AppleMusicLinkedSources sources,
  List<AppleMusicItem> items,
) {
  final List<MusicServerTrack> songs = <MusicServerTrack>[
    for (final AppleMusicItem i in items)
      if (i is AppleMusicSongItem) i.track,
  ];
  final List<Widget> out = <Widget>[];
  for (final AppleMusicItem item in items) {
    final MusicServerBrowser? owner = item.library
        ? sources.library
        : sources.catalog;
    if (owner == null) continue;
    out.add(switch (item) {
      AppleMusicAlbumItem(:final MusicServerAlbum album) =>
        MusicServerAlbumCard(
          key: ValueKey<String>('apple-music-item-${item.key}'),
          browser: owner,
          album: album,
        ),
      AppleMusicPlaylistItem(:final MusicServerPlaylist playlist) =>
        MusicServerPlaylistCard(
          key: ValueKey<String>('apple-music-item-${item.key}'),
          browser: owner,
          playlist: playlist,
        ),
      AppleMusicStationItem(:final AppleMusicStation station) =>
        AppleMusicStationCard(
          key: ValueKey<String>('apple-music-item-${item.key}'),
          catalog: sources.catalog,
          station: station,
        ),
      AppleMusicSongItem(:final MusicServerTrack track) => _SongCard(
        key: ValueKey<String>('apple-music-item-${item.key}'),
        catalog: sources.catalog,
        track: track,
        onTap: () => _playTracks(
          context,
          sources.catalog,
          songs,
          start: songs.indexOf(track),
        ),
      ),
    });
  }
  return out;
}

/// 几首歌（先露 [_kInlineSongs] 首，「查看全部」进整表）。
class _SongSection extends StatelessWidget {
  const _SongSection({
    required this.title,
    required this.browser,
    required this.tracks,
  });

  final String title;
  final MusicServerBrowser browser;
  final List<MusicServerTrack> tracks;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    final int shown = tracks.length.clamp(0, _kInlineSongs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiSectionTitle(
          title,
          trailing: tracks.length <= shown
              ? null
              : FushiTextButton(
                  onPressed: () => _push(
                    context,
                    AppleMusicTrackListPage(
                      title: title,
                      browser: browser,
                      tracks: tracks,
                    ),
                  ),
                  child: Text(t.music_apple_music_see_all),
                ),
        ),
        for (int i = 0; i < shown; i++)
          MusicServerTrackTile(
            browser: browser,
            tracks: tracks.sublist(0, shown),
            index: i,
            showAlbum: true,
            onPlay: (int i) => _playTracks(context, browser, tracks, start: i),
          ),
      ],
    );
  }
}

/// 一个异步分区：加载中占一行高度，出错显示一行可重试的提示（不连坐整页）。
class _AsyncSection<T> extends StatelessWidget {
  const _AsyncSection({
    super.key,
    required this.future,
    required this.builder,
    required this.onRetry,
  });

  final Future<T>? future;
  final Widget Function(BuildContext context, T value) builder;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<T>(
      future: future,
      builder: (BuildContext context, AsyncSnapshot<T> snap) {
        if (snap.hasError) {
          return FushiListItem(
            leading: const FushiListLeadingIcon(FushiIcons.cloudOff),
            title: Text(t.music_server_load_failed),
            subtitle: Text(
              '${snap.error}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: FushiIconButton(
              icon: FushiIcons.refresh,
              tooltip: t.music_server_retry,
              padTouchTarget: true,
              onTap: onRetry,
            ),
          );
        }
        if (!snap.hasData) {
          return const SizedBox(
            height: 96,
            child: Center(child: FushiLoadingView()),
          );
        }
        return builder(context, snap.data as T);
      },
    );
  }
}

/// 电台搜索结果的一行（搜索页用；整曲权限才有意义，没有时不显示）。
class AppleMusicStationsFutureRow extends StatelessWidget {
  const AppleMusicStationsFutureRow({
    super.key,
    required this.catalog,
    required this.stations,
  });

  final AppleMusicCatalogClient catalog;
  final Future<List<AppleMusicStation>> stations;

  @override
  Widget build(BuildContext context) {
    if (!catalog.fullTracks) return const SizedBox.shrink();
    return FutureBuilder<List<AppleMusicStation>>(
      future: stations,
      builder:
          (BuildContext context, AsyncSnapshot<List<AppleMusicStation>> snap) {
            final List<AppleMusicStation> list =
                snap.data ?? const <AppleMusicStation>[];
            return _ShelfRow(
              title: t.music_apple_music_section_stations,
              children: <Widget>[
                for (final AppleMusicStation s in list)
                  AppleMusicStationCard(
                    key: ValueKey<String>('apple-music-search-station-${s.id}'),
                    catalog: catalog,
                    station: s,
                  ),
              ],
            );
          },
    );
  }
}

// =========================================================================
// 主页
// =========================================================================

/// Apple Music catalog 的主页分区。
class AppleMusicHomeView extends StatefulWidget {
  const AppleMusicHomeView({super.key, required this.catalog});

  final AppleMusicCatalogClient catalog;

  @override
  State<AppleMusicHomeView> createState() => _AppleMusicHomeViewState();
}

class _AppleMusicHomeViewState extends State<AppleMusicHomeView> {
  AppleMusicLinkedSources? _sources;

  Future<List<AppleMusicShelf>>? _recommendations;
  Future<List<AppleMusicItem>>? _recent;
  Future<List<MusicServerTrack>>? _recentTracks;
  Future<List<AppleMusicItem>>? _heavy;
  Future<List<AppleMusicStation>>? _radio;
  Future<AppleMusicStation?>? _personalStation;
  late Future<AppleMusicCharts> _charts;
  late Future<List<AppleMusicGenre>> _genres;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sources != null) return;
    _sources = appleMusicLinkedSourcesFor(_app(context), widget.catalog);
    _loadAll();
  }

  void _loadAll() {
    final AppleMusicPersonalClient? me = _sources?.personal;
    _recommendations = me?.recommendations();
    _recent = me?.recentlyPlayed();
    _recentTracks = me?.recentTracks();
    _heavy = me?.heavyRotation();
    _personalStation = me?.personalStation();
    _radio = widget.catalog.fullTracks ? widget.catalog.liveStations() : null;
    _charts = widget.catalog.charts();
    _genres = widget.catalog.genres();
  }

  @override
  void dispose() {
    _sources?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppleMusicLinkedSources? sources = _sources;
    if (sources == null) return const FushiLoadingView();
    final AppleMusicCatalogClient catalog = widget.catalog;
    final List<Widget> sections = <Widget>[
      if (!sources.signedIn)
        FushiListItem(
          key: const ValueKey<String>('apple-music-home-signed-out'),
          leading: const FushiListLeadingIcon(FushiIcons.info),
          title: Text(t.music_apple_music_account_disconnected),
          subtitle: Text(t.music_apple_music_home_connect_hint),
        ),
      if (_radio != null || _personalStation != null)
        _AsyncSection<List<Object?>>(
          key: const ValueKey<String>('apple-music-home-radio'),
          future: Future.wait(<Future<Object?>>[
            _personalStation ?? Future<AppleMusicStation?>.value(),
            _radio ??
                Future<List<AppleMusicStation>>.value(<AppleMusicStation>[]),
          ]),
          onRetry: () => setState(() {
            _personalStation = sources.personal?.personalStation();
            _radio = catalog.liveStations();
          }),
          builder: (BuildContext context, List<Object?> v) {
            final AppleMusicStation? mine = v[0] as AppleMusicStation?;
            final List<AppleMusicStation> live =
                v[1]! as List<AppleMusicStation>;
            return _ShelfRow(
              title: t.music_apple_music_section_radio,
              children: <Widget>[
                if (mine != null)
                  AppleMusicStationCard(
                    key: ValueKey<String>('apple-music-personal-${mine.id}'),
                    catalog: catalog,
                    station: mine,
                  ),
                for (final AppleMusicStation s in live)
                  AppleMusicStationCard(
                    key: ValueKey<String>('apple-music-radio-${s.id}'),
                    catalog: catalog,
                    station: s,
                  ),
              ],
            );
          },
        ),
      _AsyncSection<List<AppleMusicShelf>>(
        key: const ValueKey<String>('apple-music-home-for-you'),
        future: _recommendations,
        onRetry: () => setState(() {
          _recommendations = sources.personal?.recommendations();
        }),
        builder: (BuildContext context, List<AppleMusicShelf> shelves) =>
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final AppleMusicShelf s in shelves)
                  _ShelfRow(
                    key: ValueKey<String>('apple-music-shelf-${s.title}'),
                    title: s.title,
                    children: _itemCards(context, sources, s.items),
                  ),
              ],
            ),
      ),
      _AsyncSection<List<AppleMusicItem>>(
        key: const ValueKey<String>('apple-music-home-recent'),
        future: _recent,
        onRetry: () => setState(() {
          _recent = sources.personal?.recentlyPlayed();
        }),
        builder: (BuildContext context, List<AppleMusicItem> items) =>
            _ShelfRow(
              title: t.music_recent_plays_title,
              children: _itemCards(context, sources, items),
            ),
      ),
      _AsyncSection<List<MusicServerTrack>>(
        key: const ValueKey<String>('apple-music-home-recent-tracks'),
        future: _recentTracks,
        onRetry: () => setState(() {
          _recentTracks = sources.personal?.recentTracks();
        }),
        builder: (BuildContext context, List<MusicServerTrack> tracks) =>
            _SongSection(
              title: t.music_apple_music_section_recent_songs,
              browser: catalog,
              tracks: tracks,
            ),
      ),
      _AsyncSection<List<AppleMusicItem>>(
        key: const ValueKey<String>('apple-music-home-heavy'),
        future: _heavy,
        onRetry: () => setState(() {
          _heavy = sources.personal?.heavyRotation();
        }),
        builder: (BuildContext context, List<AppleMusicItem> items) =>
            _ShelfRow(
              title: t.music_apple_music_section_heavy_rotation,
              children: _itemCards(context, sources, items),
            ),
      ),
      _AsyncSection<AppleMusicCharts>(
        key: const ValueKey<String>('apple-music-home-charts'),
        future: _charts,
        onRetry: () => setState(() => _charts = catalog.charts()),
        builder: (BuildContext context, AppleMusicCharts c) =>
            _ChartsSections(catalog: catalog, charts: c),
      ),
      _AsyncSection<List<AppleMusicGenre>>(
        key: const ValueKey<String>('apple-music-home-genres'),
        future: _genres,
        onRetry: () => setState(() => _genres = catalog.genres()),
        builder: (BuildContext context, List<AppleMusicGenre> genres) =>
            _GenreChips(catalog: catalog, genres: genres),
      ),
    ];
    return FushiRefreshIndicator(
      onRefresh: () async => setState(_loadAll),
      child: FushiEntranceScope(
        child: ListView.builder(
          padding: musicBrowsePagePadding(context),
          itemCount: sections.length,
          itemBuilder: fushiStaggeredItemBuilder(
            (BuildContext context, int i) => sections[i],
          ),
        ),
      ),
    );
  }
}

/// 榜单三段：热门歌曲（先露几首）、热门专辑、热门歌单。
class _ChartsSections extends StatelessWidget {
  const _ChartsSections({required this.catalog, required this.charts});

  final AppleMusicCatalogClient catalog;
  final AppleMusicCharts charts;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      _SongSection(
        title: charts.songsTitle ?? t.music_apple_music_chart_songs,
        browser: catalog,
        tracks: charts.songs,
      ),
      _ShelfRow(
        title: charts.albumsTitle ?? t.music_apple_music_chart_albums,
        children: <Widget>[
          for (final MusicServerAlbum a in charts.albums)
            MusicServerAlbumCard(
              key: ValueKey<String>('apple-music-chart-album-${a.id}'),
              browser: catalog,
              album: a,
            ),
        ],
      ),
      _ShelfRow(
        title: charts.playlistsTitle ?? t.music_apple_music_chart_playlists,
        children: <Widget>[
          for (final MusicServerPlaylist p in charts.playlists)
            MusicServerPlaylistCard(
              key: ValueKey<String>('apple-music-chart-playlist-${p.id}'),
              browser: catalog,
              playlist: p,
            ),
        ],
      ),
    ],
  );
}

/// 流派入口（点进该流派的榜单页）。
class _GenreChips extends StatelessWidget {
  const _GenreChips({required this.catalog, required this.genres});

  final AppleMusicCatalogClient catalog;
  final List<AppleMusicGenre> genres;

  @override
  Widget build(BuildContext context) {
    if (genres.isEmpty) return const SizedBox.shrink();
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiSectionTitle(t.music_apple_music_section_genres),
        Wrap(
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            for (final AppleMusicGenre g in genres)
              FushiPressScale(
                child: FushiFilledButton.tonal(
                  key: ValueKey<String>('apple-music-genre-${g.id}'),
                  onPressed: () => _push(
                    context,
                    AppleMusicGenrePage(catalog: catalog, genre: g),
                  ),
                  child: Text(g.name),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 一个流派的榜单（歌曲全表 + 专辑 + 歌单）。
class AppleMusicGenrePage extends StatefulWidget {
  const AppleMusicGenrePage({
    super.key,
    required this.catalog,
    required this.genre,
  });

  final AppleMusicCatalogClient catalog;
  final AppleMusicGenre genre;

  @override
  State<AppleMusicGenrePage> createState() => _AppleMusicGenrePageState();
}

class _AppleMusicGenrePageState extends State<AppleMusicGenrePage> {
  late Future<AppleMusicCharts> _charts = widget.catalog.charts(
    genreId: widget.genre.id,
    limit: 50,
  );

  @override
  Widget build(BuildContext context) => musicBrowseScaffold(
    context,
    title: widget.genre.name,
    body: FutureBuilder<AppleMusicCharts>(
      future: _charts,
      builder: (BuildContext context, AsyncSnapshot<AppleMusicCharts> snap) {
        if (snap.hasError) {
          return musicBrowseErrorView(
            context,
            snap.error!,
            () => setState(() {
              _charts = widget.catalog.charts(
                genreId: widget.genre.id,
                limit: 50,
              );
            }),
          );
        }
        final AppleMusicCharts? c = snap.data;
        if (c == null) return const FushiLoadingView();
        if (c.isEmpty) {
          return Center(
            child: FushiPlaceholderMessage(
              icon: FushiIcons.music,
              message: t.music_server_no_albums,
            ),
          );
        }
        return FushiEntranceScope(
          child: ListView(
            padding: musicBrowsePagePadding(context),
            children: <Widget>[
              _ChartsSections(catalog: widget.catalog, charts: c),
            ],
          ),
        );
      },
    ),
  );
}

/// 一列曲目（「查看全部」）。
class AppleMusicTrackListPage extends StatelessWidget {
  const AppleMusicTrackListPage({
    super.key,
    required this.title,
    required this.browser,
    required this.tracks,
  });

  final String title;
  final MusicServerBrowser browser;
  final List<MusicServerTrack> tracks;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return musicBrowseScaffold(
      context,
      title: title,
      body: FushiEntranceScope(
        child: ListView.builder(
          padding: musicBrowsePagePadding(context),
          itemCount: tracks.length + 1,
          itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
            if (i == 0) {
              return Padding(
                padding: EdgeInsets.only(bottom: tokens.spacing.gap),
                child: Wrap(
                  spacing: tokens.spacing.gap,
                  children: <Widget>[
                    FushiPressScale(
                      child: FushiFilledButton.icon(
                        size: FushiButtonSize.m,
                        onPressed: () => _playTracks(context, browser, tracks),
                        icon: const FushiIcon(FushiIcons.play),
                        label: Text(t.music_play_all),
                      ),
                    ),
                    FushiPressScale(
                      child: FushiFilledButton.tonalIcon(
                        size: FushiButtonSize.m,
                        onPressed: () => _playTracks(
                          context,
                          browser,
                          tracks,
                          shuffle: true,
                        ),
                        icon: const FushiIcon(FushiIcons.shuffle),
                        label: Text(t.music_shuffle_play),
                      ),
                    ),
                  ],
                ),
              );
            }
            return MusicServerTrackTile(
              browser: browser,
              tracks: tracks,
              index: i - 1,
              leading: MusicServerTrackLeading.position,
              showAlbum: true,
              onPlay: (int j) =>
                  _playTracks(context, browser, tracks, start: j),
            );
          }),
        ),
      ),
    );
  }
}

// =========================================================================
// 资料库歌曲
// =========================================================================

/// 资料库来源的「歌曲」分区：资料库全部歌曲，往下翻页。点一首从这首起放已加载的那些。
class AppleMusicLibrarySongsView extends StatefulWidget {
  const AppleMusicLibrarySongsView({super.key, required this.library});

  final AppleMusicLibraryClient library;

  @override
  State<AppleMusicLibrarySongsView> createState() =>
      _AppleMusicLibrarySongsViewState();
}

class _AppleMusicLibrarySongsViewState
    extends State<AppleMusicLibrarySongsView> {
  final List<MusicServerTrack> _tracks = <MusicServerTrack>[];
  int? _next = 0;
  bool _loading = false;
  Object? _error;

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
      final MusicServerPage<MusicServerTrack> page = await widget.library
          .listSongs(offset: offset);
      if (!mounted) return;
      setState(() {
        _tracks.addAll(page.items);
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
    if (_error != null && _tracks.isEmpty) {
      return musicBrowseErrorView(context, _error!, () {
        setState(() => _next = 0);
        unawaited(_loadMore());
      });
    }
    if (_tracks.isEmpty && (_loading || _next != null)) {
      return const FushiLoadingView();
    }
    if (_tracks.isEmpty) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.music,
          message: t.music_apple_music_library_songs_empty,
        ),
      );
    }
    final List<MusicServerTrack> tracks = List<MusicServerTrack>.of(_tracks);
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification n) {
        if (n.metrics.extentAfter < 600) unawaited(_loadMore());
        return false;
      },
      child: FushiEntranceScope(
        child: ListView.builder(
          padding: musicBrowsePagePadding(context),
          itemCount: tracks.length + (_loading ? 1 : 0),
          itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
            if (i >= tracks.length) {
              return const SizedBox(
                height: 64,
                child: Center(child: FushiLoadingView()),
              );
            }
            return MusicServerTrackTile(
              key: ValueKey<String>('apple-music-library-song-${tracks[i].id}'),
              browser: widget.library,
              tracks: tracks,
              index: i,
              showAlbum: true,
              onPlay: (int j) =>
                  _playTracks(context, widget.library, tracks, start: j),
            );
          }),
        ),
      ),
    );
  }
}

// =========================================================================
// 艺人页
// =========================================================================

/// Apple Music catalog 艺人：热门歌曲、专辑、精选歌单、相似艺人、艺人电台。
class AppleMusicArtistPage extends StatefulWidget {
  const AppleMusicArtistPage({
    super.key,
    required this.catalog,
    required this.artist,
  });

  final AppleMusicCatalogClient catalog;
  final MusicServerArtist artist;

  @override
  State<AppleMusicArtistPage> createState() => _AppleMusicArtistPageState();
}

class _AppleMusicArtistPageState extends State<AppleMusicArtistPage> {
  late Future<List<MusicServerTrack>> _top;
  late Future<List<MusicServerAlbum>> _albums;
  late Future<List<MusicServerPlaylist>> _playlists;
  late Future<List<MusicServerArtist>> _similar;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final String id = widget.artist.id;
    _top = widget.catalog.artistTopSongs(id);
    _albums = widget.catalog.artistAlbums(id);
    _playlists = widget.catalog.artistPlaylists(id);
    _similar = widget.catalog.similarArtists(id);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final AppleMusicCatalogClient catalog = widget.catalog;
    final List<Widget> sections = <Widget>[
      Padding(
        padding: EdgeInsets.only(bottom: tokens.spacing.gap),
        child: Wrap(
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            FushiPressScale(
              child: FushiFilledButton.icon(
                key: const ValueKey<String>('apple-music-artist-play-top'),
                size: FushiButtonSize.m,
                onPressed: () async {
                  try {
                    final List<MusicServerTrack> top = await _top;
                    if (context.mounted) _playTracks(context, catalog, top);
                  } on Object catch (e) {
                    _toastError(e);
                  }
                },
                icon: const FushiIcon(FushiIcons.play),
                label: Text(t.music_apple_music_play_top_songs),
              ),
            ),
            if (catalog.fullTracks)
              FushiPressScale(
                child: FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('apple-music-artist-station'),
                  size: FushiButtonSize.m,
                  onPressed: () => unawaited(
                    _startStationFor(
                      context,
                      catalog,
                      AppleMusicStationSeed.artist,
                      widget.artist.id,
                    ),
                  ),
                  icon: const FushiIcon(FushiIcons.cast),
                  label: Text(t.music_action_start_station),
                ),
              ),
          ],
        ),
      ),
      _AsyncSection<List<MusicServerTrack>>(
        future: _top,
        onRetry: () => setState(_load),
        builder: (BuildContext context, List<MusicServerTrack> tracks) =>
            _SongSection(
              title: t.music_artist_top_songs,
              browser: catalog,
              tracks: tracks,
            ),
      ),
      _AsyncSection<List<MusicServerAlbum>>(
        future: _albums,
        onRetry: () => setState(_load),
        builder: (BuildContext context, List<MusicServerAlbum> albums) =>
            _ShelfRow(
              title: t.music_section_albums,
              children: <Widget>[
                for (final MusicServerAlbum a in albums)
                  MusicServerAlbumCard(
                    key: ValueKey<String>('apple-music-artist-album-${a.id}'),
                    browser: catalog,
                    album: a,
                  ),
              ],
            ),
      ),
      _AsyncSection<List<MusicServerPlaylist>>(
        future: _playlists,
        onRetry: () => setState(_load),
        builder: (BuildContext context, List<MusicServerPlaylist> ps) =>
            _ShelfRow(
              title: t.music_section_playlists,
              children: <Widget>[
                for (final MusicServerPlaylist p in ps)
                  MusicServerPlaylistCard(
                    key: ValueKey<String>(
                      'apple-music-artist-playlist-${p.id}',
                    ),
                    browser: catalog,
                    playlist: p,
                  ),
              ],
            ),
      ),
      _AsyncSection<List<MusicServerArtist>>(
        future: _similar,
        onRetry: () => setState(_load),
        builder: (BuildContext context, List<MusicServerArtist> artists) {
          if (artists.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiSectionTitle(t.music_artist_similar),
              for (int i = 0; i < artists.length; i++)
                FushiPressScale(
                  child: FushiGroupedListItem(
                    key: ValueKey<String>(
                      'apple-music-similar-${artists[i].id}',
                    ),
                    index: i,
                    count: artists.length,
                    onTap: () => _push(
                      context,
                      AppleMusicArtistPage(
                        catalog: catalog,
                        artist: artists[i],
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
        },
      ),
    ];
    return musicBrowseScaffold(
      context,
      title: widget.artist.name,
      body: FushiEntranceScope(
        child: ListView.builder(
          padding: musicBrowsePagePadding(context),
          itemCount: sections.length,
          itemBuilder: fushiStaggeredItemBuilder(
            (BuildContext context, int i) => sections[i],
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// 曲目菜单 / 专辑与歌单的更多操作 / 新建歌单（外观与流程在 music_track_actions.dart）
// =========================================================================

/// Apple Music 资料库当作「可加歌的歌单来源」。
class AppleMusicPlaylistEditor implements MusicPlaylistEditor {
  AppleMusicPlaylistEditor(this.library);

  final AppleMusicLibraryClient library;

  static MusicPlaylistTarget _target(MusicServerPlaylist p) =>
      MusicPlaylistTarget(id: p.id, title: p.title, trackCount: p.trackCount);

  @override
  Future<List<MusicPlaylistTarget>> editablePlaylists() async {
    final MusicServerPage<MusicServerPlaylist> page = await library
        .listPlaylists();
    return <MusicPlaylistTarget>[
      for (final MusicServerPlaylist p in page.items)
        if (p.editable) _target(p),
    ];
  }

  @override
  Future<MusicPlaylistTarget> createPlaylist(
    String name, {
    List<String> trackIds = const <String>[],
  }) async =>
      _target(await library.createPlaylist(name, catalogSongIds: trackIds));

  @override
  Future<void> addToPlaylist(String playlistId, List<String> trackIds) =>
      library.addToPlaylist(playlistId, trackIds);
}

String _appleErrorText(Object e) =>
    t.music_apple_music_action_failed(error: '$e');

/// Apple Music 曲目的「更多」按钮；其它来源回 null（行尾不留空位）。
Widget? appleMusicTrackMenuButton(
  BuildContext context,
  MusicServerBrowser browser,
  MusicServerTrack track,
) {
  if (browser.kind != MusicServerKind.appleMusic) return null;
  return musicMoreButton(
    key: ValueKey<String>('apple-music-track-menu-${track.id}'),
    onTap: () => unawaited(_showTrackMenu(context, browser, track)),
  );
}

Future<void> _showTrackMenu(
  BuildContext context,
  MusicServerBrowser browser,
  MusicServerTrack track,
) async {
  final AppModel app = _app(context);
  final AppleMusicLinkedSources? sources = appleMusicLinkedSourcesFor(
    app,
    browser,
  );
  if (sources == null) return;
  // catalog 交给了新推的艺人页时不能关（页面还要用它请求）。
  bool catalogHandedOff = false;
  try {
    final String? songId = sources.catalogSongIdOf(browser, track);
    final AppleMusicFavorites? favs = app.musicSession.appleMusicFavorites;
    final bool write = sources.signedIn && songId != null;
    final AppleMusicRating? rating = write && favs != null
        ? favs.ratingOf(songId)
        : null;
    // 只在 [write] 时用到（songId 非空）。
    final String sid = songId ?? '';
    final bool loved = rating == AppleMusicRating.love;
    final bool disliked = rating == AppleMusicRating.dislike;
    await showMusicActionMenu(
      context,
      title: track.title,
      errorText: _appleErrorText,
      actions: <MusicMenuAction>[
        if (write) ...<MusicMenuAction>[
          MusicMenuAction(
            id: loved ? 'unlove' : 'love',
            label: loved ? t.music_action_unlove : t.music_action_love,
            icon: FushiIcons.favorite,
            run: (_) async =>
                favs?.setRating(sid, loved ? null : AppleMusicRating.love),
          ),
          MusicMenuAction(
            id: disliked ? 'undislike' : 'dislike',
            label: disliked ? t.music_action_undislike : t.music_action_dislike,
            icon: FushiIcons.block,
            run: (_) async => favs?.setRating(
              sid,
              disliked ? null : AppleMusicRating.dislike,
            ),
          ),
          if (browser is! AppleMusicLibraryClient)
            MusicMenuAction(
              id: 'addToLibrary',
              label: t.music_apple_music_add_to_library,
              icon: FushiIcons.libraryAdd,
              run: (_) async {
                await sources.personal!.addToLibrary(
                  <AppleMusicResourceType, List<String>>{
                    AppleMusicResourceType.song: <String>[sid],
                  },
                );
                FushiToast.show(
                  msg: t.music_apple_music_added_to_library,
                  severity: ToastSeverity.success,
                );
              },
            ),
          MusicMenuAction(
            id: 'addToPlaylist',
            label: t.music_action_add_to_playlist,
            icon: FushiIcons.playlist,
            run: (BuildContext c) => musicAddToPlaylist(
              c,
              AppleMusicPlaylistEditor(sources.library!),
              <String>[sid],
            ),
          ),
          MusicMenuAction(
            id: 'station',
            label: t.music_action_start_station,
            icon: FushiIcons.cast,
            run: (BuildContext c) => _startStationFor(
              c,
              sources.catalog,
              AppleMusicStationSeed.song,
              sid,
            ),
          ),
        ],
        if (track.artist != null)
          MusicMenuAction(
            id: 'artist',
            label: t.music_action_go_to_artist,
            subtitle: track.artist,
            icon: FushiIcons.person,
            run: (BuildContext c) async {
              final MusicServerArtist? a = await sources.catalog.findArtist(
                track.artist!,
              );
              if (!c.mounted) return;
              if (a == null) {
                FushiToast.show(
                  msg: t.music_apple_music_artist_not_found,
                  severity: ToastSeverity.warning,
                );
                return;
              }
              catalogHandedOff = true;
              _push(
                c,
                AppleMusicArtistPage(catalog: sources.catalog, artist: a),
              );
            },
          ),
        if (track.albumId != null)
          MusicMenuAction(
            id: 'album',
            label: t.music_action_go_to_album,
            subtitle: track.album,
            icon: FushiIcons.music,
            run: (BuildContext c) async => _push(
              c,
              MusicServerAlbumPage(
                browser: browser,
                album: MusicServerAlbum(
                  id: track.albumId!,
                  title: track.album ?? track.title,
                  artist: track.artist,
                  coverRef: track.coverRef,
                ),
              ),
            ),
          ),
      ],
    );
  } finally {
    // 关掉只为这一次菜单新建的客户端（页面自己的浏览器不动；交给新页面的 catalog 归它，
    // 随进程回收——catalog 只持有一个空闲的 HTTP 连接池）。
    if (catalogHandedOff) {
      sources.personal?.close();
      if (sources.ownsLibrary) sources.library?.close();
    } else {
      sources.close();
    }
  }
}

/// 资料库「歌单」分区顶部的「新建歌单」；不是 Apple Music 资料库回 null。
Widget? appleMusicCreatePlaylistButton(
  BuildContext context,
  MusicServerBrowser browser, {
  required VoidCallback onCreated,
}) {
  if (browser is! AppleMusicLibraryClient) return null;
  return musicCreatePlaylistButton(
    context,
    AppleMusicPlaylistEditor(browser),
    key: const ValueKey<String>('apple-music-new-playlist'),
    onCreated: onCreated,
    errorText: _appleErrorText,
  );
}

/// 专辑 / 歌单页按钮行里 Apple Music 的「更多」：加入资料库、喜欢 / 不喜欢 / 清除评分、以它起电台。
/// 只对 catalog 资源（资料库专辑 / 歌单的 id 不在 catalog 空间）且已登录时出现。
List<Widget> appleMusicCollectionActions(
  BuildContext context,
  WidgetRef ref,
  MusicServerBrowser browser, {
  MusicServerAlbum? album,
  MusicServerPlaylist? playlist,
}) {
  if (browser is! AppleMusicCatalogClient || !browser.fullTracks) {
    return const <Widget>[];
  }
  final String? id = album?.id ?? playlist?.id;
  if (id == null) return const <Widget>[];
  final AppleMusicResourceType type = album != null
      ? AppleMusicResourceType.album
      : AppleMusicResourceType.playlist;
  return <Widget>[
    musicMoreButton(
      key: const ValueKey<String>('apple-music-collection-more'),
      onTap: () => unawaited(_showCollectionMenu(context, browser, type, id)),
    ),
  ];
}

Future<void> _showCollectionMenu(
  BuildContext context,
  AppleMusicCatalogClient catalog,
  AppleMusicResourceType type,
  String id,
) async {
  final AppleMusicLinkedSources? sources = appleMusicLinkedSourcesFor(
    _app(context),
    catalog,
  );
  final AppleMusicPersonalClient? me = sources?.personal;
  if (sources == null || me == null) {
    sources?.close();
    return;
  }
  try {
    final AppleMusicRating? rating = await me.rating(type, id);
    if (!context.mounted) return;
    await showMusicActionMenu(
      context,
      title: t.music_action_more,
      icon: FushiIcons.moreHoriz,
      errorText: _appleErrorText,
      actions: <MusicMenuAction>[
        MusicMenuAction(
          id: 'addToLibrary',
          label: t.music_apple_music_add_to_library,
          icon: FushiIcons.libraryAdd,
          run: (_) async {
            await me.addToLibrary(<AppleMusicResourceType, List<String>>{
              type: <String>[id],
            });
            FushiToast.show(
              msg: t.music_apple_music_added_to_library,
              severity: ToastSeverity.success,
            );
          },
        ),
        if (rating != AppleMusicRating.love)
          MusicMenuAction(
            id: 'love',
            label: t.music_action_love,
            icon: FushiIcons.favorite,
            run: (_) => me.setRating(type, id, AppleMusicRating.love),
          ),
        if (rating != AppleMusicRating.dislike)
          MusicMenuAction(
            id: 'dislike',
            label: t.music_action_dislike,
            icon: FushiIcons.block,
            run: (_) => me.setRating(type, id, AppleMusicRating.dislike),
          ),
        if (rating != null)
          MusicMenuAction(
            id: 'clearRating',
            label: rating == AppleMusicRating.love
                ? t.music_action_unlove
                : t.music_action_undislike,
            icon: FushiIcons.close,
            run: (_) => me.setRating(type, id, null),
          ),
        MusicMenuAction(
          id: 'station',
          label: t.music_action_start_station,
          icon: FushiIcons.cast,
          run: (BuildContext c) => _startStationFor(
            c,
            catalog,
            type == AppleMusicResourceType.album
                ? AppleMusicStationSeed.album
                : AppleMusicStationSeed.playlist,
            id,
          ),
        ),
      ],
    );
  } on Object catch (e) {
    _toastError(e);
  } finally {
    sources.close();
  }
}
