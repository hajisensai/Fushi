/// 插件音源浏览页（docs/specs/2026-10-28-music-plugins.md §5）：搜索（歌曲 / 专辑 / 艺人 /
/// 歌单）→ 专辑 / 歌单曲目、艺人热门曲与专辑 → 播放。插件是「搜索为主」的来源，不套服务器曲库
/// 「先列全库」的页面形态；外壳、错误视图与页边距与服务器曲库共用。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, MusicAlbumRow, MusicTrackRow;
import 'package:fushi_music/fushi_music.dart';
import 'package:intl/intl.dart' show Intl, NumberFormat;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/music_history.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_favorites.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_album_page.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_mv_page.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_login.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_settings.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';

part 'music_plugin_detail_pages.dart';

/// 打开某个插件音源的浏览页。
Future<void> openMusicPluginBrowse(
  BuildContext context, {
  required MusicPluginManifest manifest,
  String? initialQuery,
  MusicPluginSearchType? initialType,
}) => Navigator.of(context).push<void>(
  adaptivePageRoute<void>(
    context: context,
    builder: (_) => MusicPluginBrowsePage(
      manifest: manifest,
      initialQuery: initialQuery,
      initialType: initialType,
    ),
  ),
);

/// 打开插件管理（安装 / 启停 / 登录）：服务器曲库与「我的歌单」的登录提示都走这里。
Future<void> openMusicPluginManagement(
  BuildContext context, {
  required AppModel appModel,
}) => _push(context, _MusicPluginManagementPage(appModel: appModel));

class _MusicPluginManagementPage extends StatelessWidget {
  const _MusicPluginManagementPage({required this.appModel});

  final AppModel appModel;

  @override
  Widget build(BuildContext context) => musicBrowseScaffold(
    context,
    title: t.music_plugins_title,
    // 留白要在脚手架之下量：页头让位（MediaQuery 顶部 padding）只在那里才有。
    body: Builder(
      builder: (BuildContext context) => SingleChildScrollView(
        padding: musicBrowsePagePadding(context),
        child: MusicPluginSettingsBody(appModel: appModel),
      ),
    ),
  );
}

Future<void> _push(BuildContext context, Widget page) => Navigator.of(
  context,
).push<void>(adaptivePageRoute<void>(context: context, builder: (_) => page));

/// 一组插件曲目交给音乐引擎（不可播放的跳过；起点按跳过后的位置换算）。
void _playTracks(
  WidgetRef ref,
  String pluginId,
  List<MusicPluginTrack> tracks, {
  int start = 0,
  bool shuffle = false,
  MusicQueueContext context = MusicQueueContext.mixed,
  String? albumTitle,
  String? coverUrl,
  MusicPlaySource? source,
}) {
  final List<MusicPlayItem> items = <MusicPlayItem>[];
  int startIndex = 0;
  for (int i = 0; i < tracks.length; i++) {
    if (!tracks[i].playable) continue;
    if (i == start) startIndex = items.length;
    items.add(
      musicPluginPlayItem(
        pluginId,
        tracks[i],
        albumTitle: albumTitle,
        coverUrl: coverUrl,
      ),
    );
  }
  if (items.isEmpty) {
    FushiToast.show(msg: t.music_plugin_unplayable);
    return;
  }
  final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
  unawaited(
    engine.playQueue(
      items,
      startIndex: startIndex,
      context: context,
      shuffle: shuffle,
      source: source,
    ),
  );
}

Widget _thumb(String? url, {bool round = false}) => round
    // 艺人头像是圆的，不是唱片，不套专辑材质。
    ? SizedBox.square(
        dimension: 48,
        child: MusicCover(
          coverPath: url,
          size: 48,
          // 48dp 头像是正圆（半径 = 尺寸 / 2），几何而非圆角档位。
          borderRadius: const BorderRadius.all(Radius.circular(24)),
        ),
      )
    : musicMaterialCover(
        MusicCover(coverPath: url, size: 48),
        size: 48,
        compact: true,
      );

/// 一行插件曲目（搜索结果 / 专辑 / 歌单 / 艺人热门曲共用）。
class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.track,
    required this.index,
    required this.count,
    required this.onTap,
    this.leadingNumber = false,
    this.onPlayMv,
  });

  final MusicPluginTrack track;
  final int index;
  final int count;
  final VoidCallback onTap;
  final bool leadingNumber;

  /// 这首歌有 MV 且插件能取 MV 流时的「播放 MV」（[_mvAction]）。
  final VoidCallback? onPlayMv;

  @override
  Widget build(BuildContext context) {
    final String subtitle = <String>[
      if (track.artists.isNotEmpty) track.artistText,
      ?track.albumTitle,
      if (!track.playable) t.music_plugin_unplayable else ?track.note,
    ].join(' · ');
    return Opacity(
      opacity: track.playable ? 1 : 0.5,
      child: FushiPressScale(
        child: FushiGroupedListItem(
          key: ValueKey<String>('music-plugin-track-${track.id}'),
          index: index,
          count: count,
          onTap: track.playable ? onTap : null,
          child: FushiListItem(
            leading: leadingNumber
                ? SizedBox(
                    width: 28,
                    child: Text(
                      '${track.trackNo ?? index + 1}',
                      textAlign: TextAlign.end,
                      style: context.fushiType.bodySmall,
                    ),
                  )
                : _thumb(track.coverUrl),
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
                if (onPlayMv case final VoidCallback playMv)
                  FushiIconButton(
                    key: ValueKey<String>('music-plugin-track-mv-${track.id}'),
                    icon: FushiIcons.video,
                    tooltip: t.music_mv_play,
                    onTap: playMv,
                  ),
                Text(
                  formatMusicDuration(track.durationMs),
                  style: context.fushiType.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一个插件音源：搜索框 + 类型分段 + 分页结果。
class MusicPluginBrowsePage extends ConsumerStatefulWidget {
  const MusicPluginBrowsePage({
    super.key,
    required this.manifest,
    this.initialQuery,
    this.initialType,
  });

  final MusicPluginManifest manifest;

  /// 从曲库搜索框带过来的关键词：进页即搜。
  final String? initialQuery;

  /// 从曲库带过来的搜索类型（与当时所在的分区对应）；插件不支持时用它的第一种。
  final MusicPluginSearchType? initialType;

  @override
  ConsumerState<MusicPluginBrowsePage> createState() =>
      _MusicPluginBrowsePageState();
}

class _MusicPluginBrowsePageState extends ConsumerState<MusicPluginBrowsePage> {
  static const int _pageSize = 30;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  late MusicPluginSearchType _type = _types.contains(widget.initialType)
      ? widget.initialType!
      : _types.first;
  String _query = '';
  final List<Object> _items = <Object>[];
  int _page = 0;
  bool _hasMore = false;
  bool _loading = false;
  Object? _error;

  /// 本次搜索的代次：换关键词 / 类型后，在途的旧请求结果丢弃。
  int _generation = 0;

  List<MusicPluginSearchType> get _types => <MusicPluginSearchType>[
    for (final MusicPluginSearchType st in MusicPluginSearchType.values)
      if (widget.manifest.searchTypes.contains(st.wire)) st,
  ];

  MusicPluginSource get _source =>
      ref.read(appProvider).musicPluginManager.source(widget.manifest.id);

  @override
  void initState() {
    super.initState();
    final String q = widget.initialQuery?.trim() ?? '';
    if (q.isNotEmpty) {
      _controller.text = q;
      _query = q;
      unawaited(_loadMore());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String q) {
    if (q.trim().isEmpty) return;
    _query = q.trim();
    _restart();
  }

  void _restart() {
    _generation++;
    setState(() {
      _items.clear();
      _page = 0;
      _hasMore = false;
      _error = null;
      _loading = false;
    });
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    if (_loading || _query.isEmpty) return;
    final int gen = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final MusicPluginSource src = _source;
      final MusicPluginPage<Object> page = switch (_type) {
        MusicPluginSearchType.song => await src.searchTracks(
          _query,
          page: _page,
          pageSize: _pageSize,
        ),
        MusicPluginSearchType.album => await src.searchAlbums(
          _query,
          page: _page,
          pageSize: _pageSize,
        ),
        MusicPluginSearchType.artist => await src.searchArtists(
          _query,
          page: _page,
          pageSize: _pageSize,
        ),
        MusicPluginSearchType.playlist => await src.searchPlaylists(
          _query,
          page: _page,
          pageSize: _pageSize,
        ),
      };
      if (!mounted || gen != _generation) return;
      setState(() {
        _items.addAll(page.items);
        _page++;
        _hasMore = page.hasMore && page.items.isNotEmpty;
      });
    } on Object catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e);
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  String _typeLabel(MusicPluginSearchType type) => switch (type) {
    MusicPluginSearchType.song => t.music_section_songs,
    MusicPluginSearchType.album => t.music_section_albums,
    MusicPluginSearchType.artist => t.music_section_artists,
    MusicPluginSearchType.playlist => t.music_section_playlists,
  };

  Widget _itemTile(BuildContext context, int i) =>
      musicPluginItemTile(context, ref, widget.manifest, _items, i);

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<MusicPluginSearchType> types = _types;
    final Widget header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        FushiSearchField(
          key: const ValueKey<String>('music_plugin_search_field'),
          controller: _controller,
          focusNode: _focus,
          autofocus: true,
          hintText: t.music_plugin_search_hint,
          onChanged: (_) {},
          onSubmitted: _submit,
        ),
        if (types.length > 1)
          Align(
            alignment: Alignment.centerLeft,
            child: adaptiveSegmentedButton<MusicPluginSearchType>(
              context: context,
              segments: <ButtonSegment<MusicPluginSearchType>>[
                for (final MusicPluginSearchType st in types)
                  ButtonSegment<MusicPluginSearchType>(
                    value: st,
                    label: Text(_typeLabel(st)),
                  ),
              ],
              selected: <MusicPluginSearchType>{_type},
              onSelectionChanged: (Set<MusicPluginSearchType> v) {
                if (v.first == _type) return;
                _type = v.first;
                _restart();
              },
            ),
          ),
      ],
    );
    final Widget results;
    if (_error != null && _items.isEmpty) {
      results = musicBrowseErrorView(
        context,
        musicPluginErrorText(_error!),
        () {
          _restart();
        },
      );
    } else if (_items.isEmpty && _loading) {
      results = const FushiLoadingView();
    } else if (_items.isEmpty) {
      results = Center(
        child: FushiPlaceholderMessage(
          icon: _query.isEmpty ? FushiIcons.search : FushiIcons.searchOff,
          message: _query.isEmpty
              ? t.music_plugin_search_prompt
              : t.music_server_search_empty,
        ),
      );
    } else {
      results = NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification n) {
          if (_hasMore && n.metrics.extentAfter < 600) unawaited(_loadMore());
          return false;
        },
        child: FushiEntranceScope(
          child: ListView.builder(
            key: ValueKey<String>('music-plugin-results-${_type.wire}'),
            padding: withBottomSafeInset(
              context,
              EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.gap,
                tokens.spacing.page,
                tokens.spacing.section,
              ),
            ),
            itemCount: _items.length + (_loading || _hasMore ? 1 : 0),
            itemBuilder: fushiStaggeredItemBuilder((
              BuildContext context,
              int i,
            ) {
              if (i >= _items.length) {
                return Padding(
                  padding: EdgeInsets.all(tokens.spacing.gap),
                  child: const FushiLinearProgressIndicator(),
                );
              }
              return _itemTile(context, i);
            }),
          ),
        ),
      );
    }
    return musicBrowseScaffold(
      context,
      title: widget.manifest.name,
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
                  child: header,
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: fushiMotionDuration(context, FushiMotion.medium),
                    child: KeyedSubtree(
                      key: ValueKey<String>('${_type.wire}|$_query'),
                      child: results,
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
}

/// 专辑 / 艺人 / 歌单一行（小封面 + 标题 + 副行 + 箭头）。
class _EntityRow extends StatelessWidget {
  const _EntityRow({
    super.key,
    required this.index,
    required this.count,
    required this.title,
    required this.onTap,
    this.cover,
    this.subtitle = '',
    this.roundCover = false,
  });

  final int index;
  final int count;
  final String title;
  final String subtitle;
  final String? cover;
  final bool roundCover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FushiPressScale(
    child: FushiGroupedListItem(
      index: index,
      count: count,
      onTap: onTap,
      child: FushiListItem(
        leading: _thumb(cover, round: roundCover),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: subtitle.isEmpty
            ? null
            : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const FushiIcon(FushiIcons.chevronRight),
      ),
    ),
  );
}

/// 插件条目一行（曲目 / 专辑 / 艺人 / 歌单）：搜索结果、推荐、我的歌单共用。
Widget musicPluginItemTile(
  BuildContext context,
  WidgetRef ref,
  MusicPluginManifest manifest,
  List<Object> items,
  int i,
) {
  final Object item = items[i];
  final String pluginId = manifest.id;
  return switch (item) {
    MusicPluginTrack track => _TrackRow(
      track: track,
      index: i,
      count: items.length,
      onPlayMv: _mvAction(context, ref, manifest, track),
      onTap: () => _playTracks(
        ref,
        pluginId,
        items.whereType<MusicPluginTrack>().toList(),
        start: items.take(i).whereType<MusicPluginTrack>().length,
      ),
    ),
    MusicPluginAlbum album => _EntityRow(
      key: ValueKey<String>('music-plugin-album-${album.id}'),
      index: i,
      count: items.length,
      cover: album.coverUrl,
      title: album.title,
      subtitle: <String>[
        if (album.artists.isNotEmpty) album.artistText,
        if (album.year != null) '${album.year}',
      ].join(' · '),
      onTap: () => unawaited(
        _push(
          context,
          MusicPluginCollectionPage.album(manifest: manifest, album: album),
        ),
      ),
    ),
    MusicPluginArtist artist => _EntityRow(
      key: ValueKey<String>('music-plugin-artist-${artist.id}'),
      index: i,
      count: items.length,
      cover: artist.coverUrl,
      roundCover: true,
      title: artist.name,
      onTap: () => unawaited(
        _push(
          context,
          MusicPluginArtistPage(manifest: manifest, artist: artist),
        ),
      ),
    ),
    MusicPluginPlaylist playlist => _EntityRow(
      key: ValueKey<String>('music-plugin-playlist-${playlist.id}'),
      index: i,
      count: items.length,
      cover: playlist.coverUrl,
      title: playlist.title,
      subtitle: <String>[
        ?playlist.owner,
        if (playlist.trackCount != null)
          t.music_tracks_count(count: playlist.trackCount!),
      ].join(' · '),
      onTap: () => unawaited(
        _push(
          context,
          MusicPluginCollectionPage.playlist(
            manifest: manifest,
            playlist: playlist,
          ),
        ),
      ),
    ),
    _ => const SizedBox.shrink(),
  };
}

/// 段标题行：标题 + 可选副标题 + 右侧动作。推荐 / 我的歌单共用。
/// 推荐页段落标题（插件段与服务器来源段同一套样式）。
Widget musicRecommendSectionHeader({
  required String title,
  String? subtitle,
  List<Widget> actions = const <Widget>[],
  bool eyebrow = false,
}) => _SectionHeader(
  title: title,
  subtitle: subtitle,
  actions: actions,
  eyebrow: eyebrow,
);

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.subtitle,
    this.actions = const <Widget>[],
    this.eyebrow = false,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  /// 插件名那一行：小号眉标，不抢段落标题。
  final bool eyebrow;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(
        top: tokens.spacing.section,
        bottom: tokens.spacing.gap,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: eyebrow
                      ? context.fushiType.labelLarge.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        )
                      : context.fushiType.titleLarge.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: context.fushiType.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// 横向一排封面卡（推荐歌单 / 榜单 / 新碟）。
class _CoverCarousel extends StatelessWidget {
  const _CoverCarousel({
    super.key,
    required this.manifest,
    required this.items,
  });

  static const double _size = 144;

  final MusicPluginManifest manifest;
  final List<Object> items;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return SizedBox(
      height: _size + 52,
      child: HorizontalDragScrollable(
        child: FushiEntranceScope(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, _) => SizedBox(width: tokens.spacing.gap),
            itemBuilder: fushiStaggeredItemBuilder((
              BuildContext context,
              int i,
            ) {
              final Object item = items[i];
              final (
                String id,
                String title,
                String? cover,
                Widget page,
              ) = switch (item) {
                MusicPluginPlaylist p => (
                  'playlist-${p.id}',
                  p.title,
                  p.coverUrl,
                  MusicPluginCollectionPage.playlist(
                    manifest: manifest,
                    playlist: p,
                  ),
                ),
                MusicPluginAlbum a => (
                  'album-${a.id}',
                  a.title,
                  a.coverUrl,
                  MusicPluginCollectionPage.album(manifest: manifest, album: a),
                ),
                _ => ('', '', null, const SizedBox.shrink()),
              };
              return SizedBox(
                key: ValueKey<String>('music-plugin-card-$id'),
                width: _size,
                // 按压下沉与 3D 倾斜都由 [FushiHoverLift] 提供，封面是专辑材质。
                child: FushiHoverLift(
                  scale: kMusicHoverLiftScale,
                  builder: (BuildContext context, bool hovering) => InkWell(
                    borderRadius: tokens.radii.cardRadius,
                    onTap: () => unawaited(_push(context, page)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        musicMaterialCover(
                          MusicCover(coverPath: cover, size: _size),
                          size: _size,
                        ),
                        SizedBox(height: tokens.spacing.gap * 0.5),
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.fushiType.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

/// 一组条目的竖排列表（不自己滚动，嵌在外层列表里）。
class _ItemColumn extends ConsumerWidget {
  const _ItemColumn({required this.manifest, required this.items});

  final MusicPluginManifest manifest;
  final List<Object> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      for (int i = 0; i < items.length; i++)
        musicPluginItemTile(context, ref, manifest, items, i),
    ],
  );
}

/// 音乐页「推荐」页签：各插件 `home()` 的内容。只在有声明 `home` 能力的插件时出现。
class MusicPluginRecommendView extends ConsumerStatefulWidget {
  const MusicPluginRecommendView({
    super.key,
    required this.sources,
    this.trailing = const <Widget>[],
    this.showPersonal = true,
  });

  final List<MusicPluginManifest> sources;

  /// 插件段落之后追加的块（「推荐 › 全部」里各服务器来源的一排专辑）。
  final List<Widget> trailing;

  /// 是否显示「我喜欢 / 最近播放」两行（只看单个来源时不显示）。
  final bool showPersonal;

  @override
  ConsumerState<MusicPluginRecommendView> createState() =>
      _MusicPluginRecommendViewState();
}

typedef _HomeResult = ({
  MusicPluginManifest manifest,
  List<MusicPluginHomeSection> sections,
  Object? error,
});

class _MusicPluginRecommendViewState
    extends ConsumerState<MusicPluginRecommendView> {
  /// 曲目段最多直接列出的条数（其余进「播放全部」的队列）。
  static const int _trackPreview = 12;

  late Future<List<_HomeResult>> _data = _load();

  /// 最近一次拿到的内容：刷新期间继续显示它。
  List<_HomeResult>? _shown;
  bool _refreshing = false;

  Future<List<_HomeResult>> _load({bool refresh = false}) {
    final MusicPluginManager manager = ref.read(appProvider).musicPluginManager;
    return Future.wait(<Future<_HomeResult>>[
      for (final MusicPluginManifest m in widget.sources)
        manager
            .source(m.id)
            .home(refresh: refresh)
            .then<_HomeResult>(
              (List<MusicPluginHomeSection> s) =>
                  (manifest: m, sections: s, error: null),
            )
            .catchError(
              (Object e) => (
                manifest: m,
                sections: const <MusicPluginHomeSection>[],
                error: e,
              ),
            ),
    ]);
  }

  @override
  void didUpdateWidget(MusicPluginRecommendView old) {
    super.didUpdateWidget(old);
    final Set<String> a = <String>{
      for (final MusicPluginManifest m in old.sources) m.id,
    };
    final Set<String> b = <String>{
      for (final MusicPluginManifest m in widget.sources) m.id,
    };
    if (a.length != b.length || !a.containsAll(b)) _reload();
  }

  /// 「刷新」也让最近播放重新读库（传给 [_RecentPlays]，它读到前保留旧内容）。
  int _generation = 0;

  void _reload({bool refresh = false}) {
    final Future<List<_HomeResult>> next = _load(refresh: refresh);
    setState(() {
      _data = next;
      _refreshing = _shown != null;
      _generation++;
    });
    unawaited(
      next.whenComplete(() {
        if (mounted && identical(_data, next)) {
          setState(() => _refreshing = false);
        }
      }),
    );
  }

  List<Widget> _pluginBlocks(BuildContext context, _HomeResult r) {
    final MusicPluginManifest m = r.manifest;
    final List<Widget> out = <Widget>[
      _SectionHeader(
        title: m.name,
        eyebrow: true,
        actions: <Widget>[
          // 刷新中按钮换成小转圈，旧内容留在原地，新一批到了再整体换上
          // （之前整页先换成加载圈再重画，界面闪一下）。
          if (_refreshing)
            const Padding(
              padding: EdgeInsets.all(10),
              child: SizedBox.square(
                dimension: 20,
                child: FushiCircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            FushiPressScale(
              child: FushiIconButton(
                key: ValueKey<String>('music-plugin-home-refresh-${m.id}'),
                tooltip: t.music_plugin_home_refresh,
                icon: FushiIcons.refresh,
                onTap: () => _reload(refresh: true),
              ),
            ),
        ],
      ),
    ];
    if (r.error != null) {
      out.add(
        Padding(
          padding: EdgeInsets.only(
            bottom: FushiDesignTokens.of(context).spacing.gap,
          ),
          child: Text(
            musicPluginErrorText(r.error!),
            style: context.fushiType.bodySmall,
          ),
        ),
      );
      return out;
    }
    if (r.sections.isEmpty) {
      out.add(
        Text(t.music_plugin_home_empty, style: context.fushiType.bodySmall),
      );
      return out;
    }
    // 推荐页 A（用户 2026-10-29 定版，设计稿
    // fushi/build/music_design/m3e_recommend_and_bar.html）：主卡（第一个曲目段，
    // 未登录时退成第一个歌单段的头一张）+ 右侧两张色调榜单卡（带前三首预览），
    // 其余段落按种类排：歌单 / 专辑横滑、曲目三列网格。
    final List<MusicPluginHomeSection> secs = r.sections;
    final MusicPluginHomeSection? heroTracks = secs
        .where(
          (MusicPluginHomeSection s) => s.kind == MusicPluginHomeKind.tracks,
        )
        .firstOrNull;
    final MusicPluginHomeSection? ranks = secs
        .where(
          (MusicPluginHomeSection s) =>
              s.kind == MusicPluginHomeKind.playlists &&
              s.items.whereType<MusicPluginPlaylist>().any(
                (MusicPluginPlaylist p) => p.previewTracks.isNotEmpty,
              ),
        )
        .firstOrNull;
    final MusicPluginHomeSection? heroPlaylists = heroTracks != null
        ? null
        : secs
              .where(
                (MusicPluginHomeSection s) =>
                    s != ranks &&
                    s.kind == MusicPluginHomeKind.playlists &&
                    s.items.isNotEmpty,
              )
              .firstOrNull;
    final List<MusicPluginPlaylist> rankCards = ranks == null
        ? const <MusicPluginPlaylist>[]
        : ranks.items
              .whereType<MusicPluginPlaylist>()
              .where((MusicPluginPlaylist p) => p.previewTracks.isNotEmpty)
              .take(2)
              .toList();
    final Widget hero = heroTracks != null
        ? _RecommendHero.tracks(
            key: ValueKey<String>('music-plugin-hero-${m.id}-${heroTracks.id}'),
            manifest: m,
            section: heroTracks,
            onPlay: ({bool shuffle = false}) => _playTracks(
              ref,
              m.id,
              heroTracks.items.whereType<MusicPluginTrack>().toList(),
              shuffle: shuffle,
            ),
          )
        : _RecommendHero.playlist(
            key: ValueKey<String>('music-plugin-hero-${m.id}'),
            manifest: m,
            section: heroPlaylists,
          );
    out.add(
      _HeroRow(
        hero: hero,
        side: <Widget>[
          for (final MusicPluginPlaylist p in rankCards)
            _RankCard(
              key: ValueKey<String>('music-plugin-rank-${m.id}-${p.id}'),
              manifest: m,
              playlist: p,
            ),
        ],
      ),
    );
    for (final MusicPluginHomeSection sec in secs) {
      if (sec == heroTracks) continue;
      final List<Object> items = sec == heroPlaylists
          ? sec.items.skip(1).toList()
          : sec == ranks
          ? sec.items.where((Object o) => !rankCards.contains(o)).toList()
          : sec.items;
      if (items.isEmpty) continue;
      final List<MusicPluginTrack> tracks = items
          .whereType<MusicPluginTrack>()
          .toList();
      out.add(
        _SectionHeader(
          title: sec.title,
          subtitle: sec.subtitle,
          actions: <Widget>[
            if (sec.kind == MusicPluginHomeKind.tracks)
              FushiPressScale(
                child: FushiTextButton.icon(
                  key: ValueKey<String>(
                    'music-plugin-home-play-${m.id}-${sec.id}',
                  ),
                  onPressed: () => _playTracks(ref, m.id, tracks),
                  icon: const FushiIcon(FushiIcons.play),
                  label: Text(t.music_play_all),
                ),
              ),
          ],
        ),
      );
      out.add(switch (sec.kind) {
        MusicPluginHomeKind.tracks => _TrackGrid(
          key: ValueKey<String>('music-plugin-home-${m.id}-${sec.id}'),
          manifest: m,
          items: tracks.take(_trackPreview).toList(),
        ),
        MusicPluginHomeKind.playlists ||
        MusicPluginHomeKind.albums => _CoverCarousel(
          key: ValueKey<String>('music-plugin-home-${m.id}-${sec.id}'),
          manifest: m,
          items: items,
        ),
      });
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_HomeResult>>(
      future: _data,
      builder: (BuildContext context, AsyncSnapshot<List<_HomeResult>> snap) {
        if (snap.hasData) _shown = snap.data;
        final List<_HomeResult>? data = snap.data ?? _shown;
        if (data == null) return const FushiLoadingView();
        final List<Widget> blocks = <Widget>[
          // 不按刷新代数换 key：换 key 会重建、加载期间整行塌成 0 高，下面所有
          // 内容先上跳再落回（用户 2026-10-29 录屏「刷新抖动」）。
          if (widget.showPersonal) ...<Widget>[
            _LikedMusic(
              key: const ValueKey<String>('music-liked'),
              sources: widget.sources,
            ),
            _RecentPlays(
              key: const ValueKey<String>('music-recent-plays'),
              generation: _generation,
              sources: widget.sources,
            ),
          ],
          for (final _HomeResult r in data) ..._pluginBlocks(context, r),
          ...widget.trailing,
        ];
        return FushiEntranceScope(
          child: ListView.builder(
            key: const ValueKey<String>('music-plugin-recommend'),
            padding: musicBrowsePagePadding(context),
            itemCount: blocks.length,
            itemBuilder: fushiStaggeredItemBuilder(
              (BuildContext context, int i) => blocks[i],
            ),
          ),
        );
      },
    );
  }
}

/// 歌单页签里的「<插件> · 我的歌单」：已登录才列出；未登录给一句去插件管理登录的提示。
class MusicPluginLibrarySection extends ConsumerStatefulWidget {
  const MusicPluginLibrarySection({super.key, required this.manifest});

  final MusicPluginManifest manifest;

  @override
  ConsumerState<MusicPluginLibrarySection> createState() =>
      _MusicPluginLibrarySectionState();
}

class _MusicPluginLibrarySectionState
    extends ConsumerState<MusicPluginLibrarySection> {
  static const int _pageSize = 100;

  late Future<List<MusicPluginPlaylist>?> _data = _load();

  /// null = 未登录。
  Future<List<MusicPluginPlaylist>?> _load() async {
    final MusicPluginSource src = ref
        .read(appProvider)
        .musicPluginManager
        .source(widget.manifest.id);
    if (!(await src.account()).loggedIn) return null;
    return (await src.library(pageSize: _pageSize)).items;
  }

  void _reload() => setState(() {
    _data = _load();
  });

  @override
  Widget build(BuildContext context) {
    final MusicPluginManifest m = widget.manifest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SectionHeader(
          title: t.music_plugin_library_title(name: m.name),
          actions: <Widget>[
            FushiPressScale(
              child: FushiIconButton(
                key: ValueKey<String>('music-plugin-library-refresh-${m.id}'),
                tooltip: t.refresh,
                icon: FushiIcons.refresh,
                onTap: _reload,
              ),
            ),
          ],
        ),
        FutureBuilder<List<MusicPluginPlaylist>?>(
          future: _data,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<MusicPluginPlaylist>?> snap,
              ) {
                if (snap.hasError) {
                  return Text(
                    musicPluginErrorText(snap.error!),
                    style: context.fushiType.bodySmall,
                  );
                }
                if (snap.connectionState != ConnectionState.done) {
                  return const FushiLinearProgressIndicator();
                }
                final List<MusicPluginPlaylist>? lists = snap.data;
                if (lists == null) {
                  return Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          t.music_plugin_library_login_hint(name: m.name),
                          style: context.fushiType.bodySmall,
                        ),
                      ),
                      FushiPressScale(
                        child: FushiTextButton(
                          key: ValueKey<String>(
                            'music-plugin-library-manage-${m.id}',
                          ),
                          onPressed: () async {
                            await openMusicPluginManagement(
                              context,
                              appModel: ref.read(appProvider),
                            );
                            if (mounted) _reload();
                          },
                          child: Text(t.music_plugins_title),
                        ),
                      ),
                    ],
                  );
                }
                if (lists.isEmpty) {
                  return Text(
                    t.music_playlists_empty,
                    style: context.fushiType.bodySmall,
                  );
                }
                return _ItemColumn(manifest: m, items: lists);
              },
        ),
      ],
    );
  }
}

/// 推荐页顶行：宽屏主卡在左、榜单卡竖排在右；窄屏上下排。
class _HeroRow extends StatelessWidget {
  const _HeroRow({required this.hero, required this.side});

  final Widget hero;
  final List<Widget> side;

  @override
  Widget build(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        if (side.isEmpty) return hero;
        if (c.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: gap,
            children: <Widget>[hero, ...side],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: gap,
            children: <Widget>[
              Expanded(flex: 135, child: hero),
              Expanded(
                flex: 100,
                child: Column(
                  spacing: gap,
                  children: <Widget>[
                    for (final Widget w in side) Expanded(child: w),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 按 M3E 形状裁一张封面（推荐页主卡的拼贴、榜单卡）。
Widget _shapeCover(RoundedPolygon shape, String? url, double size) => ClipPath(
  clipper: ShapeBorderClipper(shape: MaterialShapeBorder(shape: shape)),
  child: SizedBox.square(
    dimension: size,
    child: MusicCover(coverPath: url, size: size),
  ),
);

/// 悬停时圆角收紧的 M3E 卡壳（主卡 / 榜单卡 / 快捷格共用）：静止大圆角，悬停
/// 变小，弹簧过渡；外层 [FushiHoverLift] 只给悬停态——不放大、也不做 3D 倾斜
/// （用户 2026-10-29：大卡片倾斜太晃）。
class _MorphCard extends StatelessWidget {
  const _MorphCard({
    required this.color,
    required this.radius,
    required this.hoverRadius,
    required this.onTap,
    required this.child,
    this.background,
  });

  final Color color;
  final BorderRadius radius;
  final BorderRadius hoverRadius;
  final VoidCallback? onTap;
  final Widget child;

  /// 铺在底色之上、内容之下的一层（主卡的封面墙）。
  final Widget? background;

  @override
  Widget build(BuildContext context) => FushiHoverLift(
    scale: kMusicHoverLiftScale,
    builder: (BuildContext context, bool hovering) {
      final BorderRadius r = hovering ? hoverRadius : radius;
      final Widget content = Material(
        type: MaterialType.transparency,
        child: InkWell(onTap: onTap, child: child),
      );
      return AnimatedContainer(
        duration: fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.standard,
        decoration: BoxDecoration(color: color, borderRadius: r),
        clipBehavior: Clip.antiAlias,
        child: background == null
            ? content
            : Stack(
                children: <Widget>[
                  Positioned.fill(child: IgnorePointer(child: background)),
                  content,
                ],
              ),
      );
    },
  );
}

/// 推荐页主卡：primaryContainer 大卡、超粗标题、三张不同形状的封面拼贴、
/// 连接式「播放全部 / 随机」按钮组。曲目段（每日推荐）是主卡的首选；没有曲目
/// 段（未登录）时用第一个歌单段的头一张，点开进歌单。
class _RecommendHero extends ConsumerWidget {
  const _RecommendHero.tracks({
    super.key,
    required this.manifest,
    required MusicPluginHomeSection this.section,
    required void Function({bool shuffle}) this.onPlay,
  }) : playlistMode = false;

  const _RecommendHero.playlist({
    super.key,
    required this.manifest,
    required this.section,
  }) : playlistMode = true,
       onPlay = null;

  final MusicPluginManifest manifest;
  final MusicPluginHomeSection? section;
  final void Function({bool shuffle})? onPlay;
  final bool playlistMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final MusicPluginHomeSection? sec = section;
    final MusicPluginPlaylist? first = playlistMode
        ? sec?.items.whereType<MusicPluginPlaylist>().firstOrNull
        : null;
    final String eyebrow = playlistMode
        ? (sec?.title ?? manifest.name)
        : manifest.name;
    final String title = playlistMode
        ? (first?.title ?? manifest.name)
        : (sec?.title ?? manifest.name);
    final String meta = playlistMode
        ? (first?.owner ?? '')
        : t.music_plugin_hero_track_count(n: sec?.items.length ?? 0);
    final TextStyle titleStyle = context.fushiType.displaySmall.copyWith(
      fontWeight: FontWeight.w900,
      height: 1.05,
      color: cs.onPrimaryContainer,
    );
    // 封面墙（用户 2026-10-29：「纯色块有点无聊，用封面覆盖点」）：这一段的
    // 封面斜铺在卡片右侧，往左渐隐进 primaryContainer，标题区保持可读。
    final List<String> wall = <String>{
      for (final Object o in sec?.items ?? const <Object>[])
        if (switch (o) {
              MusicPluginTrack tr => tr.coverUrl,
              MusicPluginPlaylist pl => pl.coverUrl,
              MusicPluginAlbum al => al.coverUrl,
              _ => null,
            }
            case final String url)
          url,
    }.toList();
    final Widget? background = wall.isEmpty
        ? null
        : _CoverWall(covers: wall, tint: cs.primaryContainer);
    final Widget buttons = playlistMode
        ? FushiFilledButton.icon(
            onPressed: first == null
                ? null
                : () => unawaited(
                    _push(
                      context,
                      MusicPluginCollectionPage.playlist(
                        manifest: manifest,
                        playlist: first,
                      ),
                    ),
                  ),
            icon: const FushiIcon(FushiIcons.playlist),
            label: Text(t.music_plugin_hero_open),
          )
        : FushiButtonGroup(
            spacing: 2,
            children: <Widget>[
              FushiFilledButton.icon(
                key: ValueKey<String>('music-plugin-hero-play-${manifest.id}'),
                onPressed: () => onPlay!(),
                icon: const FushiIcon(FushiIcons.play),
                label: Text(t.music_play_all),
              ),
              FushiIconButtonControl.filledTonal(
                tooltip: t.music_shuffle_play,
                onPressed: () => onPlay!(shuffle: true),
                icon: const FushiIcon(FushiIcons.repeat),
              ),
            ],
          );
    return _MorphCard(
      color: cs.primaryContainer,
      radius: const BorderRadius.only(
        topLeft: Radius.circular(40),
        topRight: Radius.circular(40),
        bottomRight: Radius.circular(40),
        bottomLeft: Radius.circular(12),
      ),
      hoverRadius: const BorderRadius.all(Radius.circular(24)),
      background: background,
      onTap: first == null
          ? null
          : () => unawaited(
              _push(
                context,
                MusicPluginCollectionPage.playlist(
                  manifest: manifest,
                  playlist: first,
                ),
              ),
            ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 24, 20, 24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Flexible(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    eyebrow,
                    style: context.fushiType.labelLarge.copyWith(
                      color: cs.onPrimaryContainer.withValues(alpha: 0.8),
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle.copyWith(
                      shadows: <Shadow>[
                        Shadow(color: cs.primaryContainer, blurRadius: 16),
                      ],
                    ),
                  ),
                  if (meta.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.bodyMedium.copyWith(
                        color: cs.onPrimaryContainer.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  buttons,
                ],
              ),
            ),
            // 右侧留给封面墙。
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

/// 色调榜单卡：拱形封面 + 榜名 + 前三首（第一名饼干形徽章）。点开进歌单。
class _RankCard extends StatelessWidget {
  const _RankCard({super.key, required this.manifest, required this.playlist});

  final MusicPluginManifest manifest;
  final MusicPluginPlaylist playlist;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return _MorphCard(
      color: FushiDesignTokens.of(context).surfaces.card,
      radius: const BorderRadius.all(Radius.circular(28)),
      hoverRadius: const BorderRadius.all(Radius.circular(16)),
      onTap: () => unawaited(
        _push(
          context,
          MusicPluginCollectionPage.playlist(
            manifest: manifest,
            playlist: playlist,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: <Widget>[
            _shapeCover(MaterialShapes.arch, playlist.coverUrl, 92),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    playlist.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.titleMedium.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (int i = 0; i < playlist.previewTracks.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: <Widget>[
                          _RankBadge(rank: i + 1),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text.rich(
                              TextSpan(
                                text: playlist.previewTracks[i].title,
                                children: <InlineSpan>[
                                  TextSpan(
                                    text:
                                        '  ${playlist.previewTracks[i].artistText}',
                                    style: TextStyle(
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.fushiType.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 榜单名次徽章：第一名饼干形 tertiary，其余圆形 tertiaryContainer。
class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.rank});

  final int rank;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool top = rank == 1;
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: top ? cs.tertiary : cs.tertiaryContainer,
        shape: MaterialShapeBorder(
          shape: top ? MaterialShapes.cookie9Sided : MaterialShapes.circle,
        ),
      ),
      child: Text(
        '$rank',
        style: context.fushiType.labelSmall.copyWith(
          fontWeight: FontWeight.w800,
          color: top ? cs.onTertiary : cs.onTertiaryContainer,
        ),
      ),
    );
  }
}

/// 曲目段：宽屏三列网格，窄屏单列（新歌速递等）。
class _TrackGrid extends ConsumerWidget {
  const _TrackGrid({super.key, required this.manifest, required this.items});

  final MusicPluginManifest manifest;
  final List<Object> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      final int cols = c.maxWidth >= 960
          ? 3
          : c.maxWidth >= 600
          ? 2
          : 1;
      final int rows = (items.length / cols).ceil();
      return Column(
        children: <Widget>[
          for (int r = 0; r < rows; r++)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (int k = 0; k < cols; k++)
                  Expanded(
                    child: r * cols + k < items.length
                        ? musicPluginItemTile(
                            context,
                            ref,
                            manifest,
                            items,
                            r * cols + k,
                          )
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
        ],
      );
    },
  );
}

/// 推荐页「最近播放」快捷格（用户 2026-10-29：「B 播放历史也加一下」）：最近
/// 播放过的专辑 / 歌单在前，不够再补最近播放的单曲，最多 [_max] 格。点专辑 /
/// 歌单进详情，点单曲从这首起播放最近播放列表。没有记录时整块不出现。
class _RecentPlays extends ConsumerStatefulWidget {
  const _RecentPlays({
    super.key,
    required this.generation,
    required this.sources,
    this.full = false,
  });

  /// 推荐页刷新代数：变了就重读最近播放（读到之前继续显示旧的）。
  final int generation;

  final List<MusicPluginManifest> sources;

  /// true：「查看全部」二级页——不带标题、列出全部；false：推荐页里只露一行
  /// （用户 2026-10-29：「最近播放太多了，只显示一首，然后二级菜单」）。
  final bool full;

  @override
  ConsumerState<_RecentPlays> createState() => _RecentPlaysState();
}

typedef _Recent = ({
  List<MusicRecentPlaySource> sources,
  List<MusicRecentTrack> tracks,
});

class _RecentPlaysState extends ConsumerState<_RecentPlays> {
  /// 读多少条（推荐页只露一行，其余在「查看全部」里）。
  static const int _max = 50;

  /// 能点回去的来源种类（服务器来源要现连服务器，先不进快捷格）。
  static const Set<MusicPlaySourceKind> _kinds = <MusicPlaySourceKind>{
    MusicPlaySourceKind.album,
    MusicPlaySourceKind.pluginAlbum,
    MusicPlaySourceKind.pluginPlaylist,
  };

  late Future<_Recent> _data = _load();

  /// 最近一次读到的内容：重读期间继续显示，行高不塌。
  _Recent? _shown;

  @override
  void didUpdateWidget(covariant _RecentPlays oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.generation != widget.generation) _data = _load();
  }

  Future<_Recent> _load() async {
    final AppModel app = ref.read(appProvider);
    final List<MusicRecentPlaySource> sources =
        (await app.musicSession.recentSources(
          limit: _max,
          kinds: _kinds,
        )).where(_reachable).toList();
    final List<MusicRecentTrack> tracks = await app.musicSession.recentTracks(
      limit: _max,
    );
    return (sources: sources, tracks: tracks);
  }

  /// 插件来源只在该插件仍在推荐源里（已装且启用）时出现。
  bool _reachable(MusicRecentPlaySource r) {
    final String? host = r.source.hostRef?.hostId;
    if (host == null) return true;
    return widget.sources.any((MusicPluginManifest m) => m.id == host);
  }

  Future<void> _openSource(MusicPlaySource src) async {
    switch (src.kind) {
      case MusicPlaySourceKind.album:
        final FushiDatabase db = ref.read(appProvider).database;
        final MusicAlbumRow? album = await db.getMusicAlbum(src.id);
        if (album == null || !mounted) return;
        final List<MusicTrackRow> tracks = await db.listMusicTracks(
          albumUid: album.albumUid,
        );
        if (!mounted) return;
        await _push(context, MusicAlbumPage(album: album, tracks: tracks));
      case MusicPlaySourceKind.pluginAlbum ||
          MusicPlaySourceKind.pluginPlaylist:
        final ({String hostId, String itemId})? ref_ = src.hostRef;
        final MusicPluginManifest? m = ref_ == null
            ? null
            : widget.sources
                  .where((MusicPluginManifest m) => m.id == ref_.hostId)
                  .firstOrNull;
        if (m == null || ref_ == null) return;
        final String title = src.title ?? '';
        await _push(
          context,
          src.kind == MusicPlaySourceKind.pluginAlbum
              ? MusicPluginCollectionPage.album(
                  manifest: m,
                  album: MusicPluginAlbum(
                    id: ref_.itemId,
                    title: title,
                    coverUrl: src.cover,
                  ),
                )
              : MusicPluginCollectionPage.playlist(
                  manifest: m,
                  playlist: MusicPluginPlaylist(
                    id: ref_.itemId,
                    title: title,
                    coverUrl: src.cover,
                  ),
                ),
        );
      default:
        return;
    }
  }

  void _playTrack(List<MusicRecentTrack> tracks, int i) {
    final MusicPlayerEngine engine = ref.read(appProvider).musicSession.engine;
    unawaited(
      engine.playQueue(<MusicPlayItem>[
        for (final MusicRecentTrack t in tracks) t.item,
      ], startIndex: i),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_Recent>(
    future: _data,
    builder: (BuildContext context, AsyncSnapshot<_Recent> snap) {
      if (snap.hasData) _shown = snap.data;
      final _Recent? r = snap.data ?? _shown;
      if (r == null || (r.sources.isEmpty && r.tracks.isEmpty)) {
        return const SizedBox.shrink();
      }
      final List<Widget> tiles = <Widget>[
        for (final MusicRecentPlaySource src in r.sources)
          _QuickTile(
            key: ValueKey<String>(
              'music-recent-source-${src.source.kind.wire}-${src.source.id}',
            ),
            title: src.source.title ?? '',
            cover: src.source.cover,
            onTap: () => unawaited(_openSource(src.source)),
          ),
      ];
      for (int i = 0; i < r.tracks.length && tiles.length < _max; i++) {
        final MusicRecentTrack tr = r.tracks[i];
        // 来源已在格子里的单曲不重复列。
        if (tr.source != null &&
            r.sources.any((MusicRecentPlaySource s) => s.source == tr.source)) {
          continue;
        }
        tiles.add(
          _QuickTile(
            key: ValueKey<String>('music-recent-track-${tr.item.trackUid}'),
            title: tr.item.title,
            subtitle: tr.item.artist,
            cover: tr.item.coverPath,
            onTap: () => _playTrack(r.tracks, i),
            playOnTap: true,
          ),
        );
      }
      final double gap = FushiDesignTokens.of(context).spacing.gap;
      return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final int cols = _quickTileColumns(c.maxWidth);
          final double w = (c.maxWidth - gap * (cols - 1)) / cols;
          // 推荐页只露一行（窄屏就是一首），其余进「查看全部」。
          final int shown = widget.full ? tiles.length : cols;
          final Widget grid = Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              for (final Widget tile in tiles.take(shown))
                SizedBox(width: w, child: tile),
            ],
          );
          if (widget.full) return grid;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _SectionHeader(
                title: t.music_recent_plays_title,
                actions: <Widget>[
                  if (tiles.length > shown)
                    FushiPressScale(
                      child: FushiTextButton(
                        key: const ValueKey<String>('music-recent-view-all'),
                        onPressed: () => unawaited(
                          _push(
                            context,
                            _RecentPlaysPage(
                              generation: widget.generation,
                              sources: widget.sources,
                            ),
                          ),
                        ),
                        child: Text(t.collection_view_all),
                      ),
                    ),
                ],
              ),
              grid,
            ],
          );
        },
      );
    },
  );
}

/// 「最近播放」二级页：全部来源与单曲。
class _RecentPlaysPage extends StatelessWidget {
  const _RecentPlaysPage({required this.generation, required this.sources});

  final int generation;
  final List<MusicPluginManifest> sources;

  @override
  Widget build(BuildContext context) => musicBrowseScaffold(
    context,
    title: t.music_recent_plays_title,
    body: Builder(
      builder: (BuildContext context) => SingleChildScrollView(
        padding: musicBrowsePagePadding(context),
        child: FushiEntranceScope(
          child: _RecentPlays(
            generation: generation,
            sources: sources,
            full: true,
          ),
        ),
      ),
    ),
  );
}

/// 快捷格的列数（推荐页「我喜欢的音乐」与「最近播放」同一套栅格）。
int _quickTileColumns(double width) => width >= 960
    ? 4
    : width >= 520
    ? 2
    : 1;

/// 推荐页「我喜欢的音乐」：每个声明了 `like` 的插件一格。收藏就是平台账号的「喜欢」，
/// 所以已登录时直接打开平台的喜欢歌单（复用插件歌单详情页），未登录时去登录。
/// 没有这样的插件时整块不出现。
class _LikedMusic extends ConsumerWidget {
  const _LikedMusic({super.key, required this.sources});

  final List<MusicPluginManifest> sources;

  Future<void> _open(
    BuildContext context,
    AppModel app,
    MusicPluginLikeState s,
  ) async {
    if (!s.loggedIn) {
      await openMusicPluginLogin(context, appModel: app, manifest: s.manifest);
      return;
    }
    final MusicPluginPlaylist? playlist = s.playlist;
    if (playlist == null) {
      FushiToast.show(msg: t.music_liked_unavailable(name: s.manifest.name));
      return;
    }
    await _push(
      context,
      MusicPluginCollectionPage.playlist(
        manifest: s.manifest,
        playlist: playlist,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppModel app = ref.watch(appProvider);
    final MusicPluginFavorites? favorites = app.musicSession.favorites;
    if (favorites == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: favorites,
      builder: (BuildContext context, _) {
        final List<MusicPluginLikeState> states = <MusicPluginLikeState>[
          for (final MusicPluginLikeState s in favorites.states)
            if (sources.any((MusicPluginManifest m) => m.id == s.manifest.id))
              s,
        ];
        if (states.isEmpty) return const SizedBox.shrink();
        final double gap = FushiDesignTokens.of(context).spacing.gap;
        return Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final int cols = _quickTileColumns(c.maxWidth);
              final double w = (c.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: <Widget>[
                  for (final MusicPluginLikeState s in states)
                    SizedBox(
                      width: w,
                      child: _QuickTile(
                        key: ValueKey<String>('music-liked-${s.manifest.id}'),
                        title: t.music_liked_title,
                        subtitle: s.loggedIn
                            ? s.manifest.name
                            : t.music_liked_login_hint(name: s.manifest.name),
                        cover: s.playlist?.coverUrl,
                        onTap: () => unawaited(_open(context, app, s)),
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// 快捷格一格：左边方形材质封面贴边，右边标题；悬停时右侧冒出形变播放键
/// （单曲）或箭头（专辑 / 歌单），圆角收紧。
class _QuickTile extends StatelessWidget {
  const _QuickTile({
    super.key,
    required this.title,
    required this.cover,
    required this.onTap,
    this.subtitle,
    this.playOnTap = false,
  });

  final String title;
  final String? subtitle;
  final String? cover;
  final VoidCallback onTap;
  final bool playOnTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 64,
      child: _MorphCard(
        color: FushiDesignTokens.of(context).surfaces.card,
        radius: const BorderRadius.all(Radius.circular(16)),
        hoverRadius: const BorderRadius.all(Radius.circular(32)),
        onTap: onTap,
        child: Row(
          children: <Widget>[
            SizedBox.square(
              dimension: 64,
              child: MusicCover(
                coverPath: cover,
                size: 64,
                borderRadius: BorderRadius.zero,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.titleSmallEmphasized,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.bodySmall.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FushiIcon(
                playOnTap ? FushiIcons.play : FushiIcons.chevronRight,
                color: cs.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 主卡背景的封面墙：封面按行斜铺（每行错开半格），整体向右上倾斜，左侧用
/// [tint] 渐变压住，越往右封面越清楚。封面不足时循环补满。
class _CoverWall extends StatelessWidget {
  const _CoverWall({required this.covers, required this.tint});

  final List<String> covers;
  final Color tint;

  static const double _tile = 112;
  static const double _gap = 10;
  static const int _rows = 4;
  static const int _cols = 7;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      int k = 0;
      String next() => covers[k++ % covers.length];
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          OverflowBox(
            alignment: Alignment.centerRight,
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: Transform.rotate(
              angle: -0.16,
              alignment: Alignment.centerRight,
              child: Transform.translate(
                offset: const Offset(_tile * 0.6, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  spacing: _gap,
                  children: <Widget>[
                    for (int r = 0; r < _rows; r++)
                      Padding(
                        padding: EdgeInsets.only(
                          right: r.isOdd ? (_tile + _gap) / 2 : 0,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: _gap,
                          children: <Widget>[
                            for (int i = 0; i < _cols; i++)
                              ClipRRect(
                                borderRadius: FushiM3eShape.smallRadius,
                                child: SizedBox.square(
                                  dimension: _tile,
                                  child: MusicCover(
                                    coverPath: next(),
                                    size: _tile,
                                    borderRadius: BorderRadius.zero,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: <Color>[
                  tint,
                  tint.withValues(alpha: 0.92),
                  tint.withValues(alpha: 0.35),
                  tint.withValues(alpha: 0.05),
                ],
                stops: const <double>[0, 0.32, 0.62, 1],
              ),
            ),
          ),
        ],
      );
    },
  );
}
