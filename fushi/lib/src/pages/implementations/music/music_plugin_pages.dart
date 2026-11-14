/// 插件音源浏览页（docs/specs/2026-10-28-music-plugins.md §5）：搜索（歌曲 / 专辑 / 艺人 /
/// 歌单）→ 专辑 / 歌单曲目、艺人热门曲与专辑 → 播放。插件是「搜索为主」的来源，不套服务器曲库
/// 「先列全库」的页面形态；外壳、错误视图与页边距与服务器曲库共用。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show SliverConstraints;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        FushiDatabase,
        MusicAlbumRow,
        MusicPlaylistRow,
        MusicRemoteTrackRow,
        MusicTrackRow;
import 'package:fushi_music/fushi_music.dart';
import 'package:intl/intl.dart' show Intl, NumberFormat;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_continue_card_row.dart';
import 'package:fushi/src/media/music/music_history.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_queue_feed.dart';
import 'package:fushi/src/media/music/music_session.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_favorites.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_intro_text.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_album_page.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_mv_page.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_login.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_settings.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_local_playlist_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_local_playlist_page.dart'
    show openMusicLocalPlaylist;
import 'package:fushi/src/media/music/music_remote_tracks.dart'
    show musicRemoteTracksAvailable;
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/pages/implementations/music/music_track_row_surface.dart';
import 'package:fushi/src/pages/implementations/music/music_collection_view.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show
        ShellClip,
        ShellContentLayout,
        shellContentLayoutOf,
        shellRedesignActive,
        shellShape;
import 'package:fushi/src/pages/shared/library_section_tabs.dart';
import 'package:fushi/src/utils/components/library_section_tab.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show FushiToolbarItem;
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart';
import 'package:fushi/src/utils/components/fushi_poster_block.dart'
    show
        FushiPosterBlock,
        FushiPosterChip,
        FushiPosterText,
        FushiPosterWatermarkEdge;
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
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show showFushiConfirmDialog;

part 'music_plugin_actions.dart';
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
    this.menu,
    this.pluginId,
    this.block,
  });

  final MusicPluginTrack track;
  final int index;
  final int count;
  final VoidCallback onTap;
  final bool leadingNumber;

  /// 非 null（且重设计外壳生效）时这首画成歌单详情网格里的一格封面色块
  /// （[MusicTrackBlock]），值是这一格的尺寸档；null = 曲目行。
  final FushiCoverBlockSize? block;

  /// 这首歌有 MV 且插件能取 MV 流时的「播放 MV」（[_mvAction]）。
  final VoidCallback? onPlayMv;

  /// 行尾「更多」+ 整行右键（[musicPluginTrackMenu]）；没有可做的动作时为 null。
  final MusicItemMenu? menu;

  /// 这首所属的插件：给了才能认出「正在播放」（引擎里的曲目按插件 + 曲目 id 的
  /// trackUid 记，[musicPluginTrackUid]）。没给的调用点不画正在播放态。
  final String? pluginId;

  /// 重设计外壳的曲目行（[MusicTrackRowSurface]）：独立圆角条、悬停 / 焦点铺封面
  /// 取色、正在播放常驻色块 + 标题水印。key / MV 键 / 菜单 / 右键与原行同一套。
  Widget _buildSurface(BuildContext context, String subtitle) {
    Widget row(bool playing) => MusicTrackRowSurface(
      key: ValueKey<String>('music-plugin-track-${track.id}'),
      title: track.title,
      subtitle: subtitle,
      coverPath: track.coverUrl,
      playing: playing,
      ordinal: leadingNumber ? '${track.trackNo ?? index + 1}' : null,
      leading: leadingNumber ? null : _thumb(track.coverUrl),
      durationText: formatMusicDuration(track.durationMs),
      onTap: track.playable ? onTap : null,
      trailing: <Widget>[
        if (onPlayMv case final VoidCallback playMv)
          FushiIconButton(
            key: ValueKey<String>('music-plugin-track-mv-${track.id}'),
            icon: FushiIcons.video,
            tooltip: t.music_mv_play,
            onTap: playMv,
          ),
        ?menu?.button(),
      ],
    );
    return _withPlaying(row);
  }

  /// 歌单详情网格里的一格（[block]）：封面色块，点块从这首起播，右键是行菜单。
  Widget _buildBlock(
    BuildContext context,
    String subtitle,
    FushiCoverBlockSize size,
  ) => _withPlaying(
    (bool playing) => MusicTrackBlock(
      key: ValueKey<String>('music-plugin-track-${track.id}'),
      size: size,
      title: track.title,
      subtitle: subtitle,
      coverPath: track.coverUrl,
      durationText: formatMusicDuration(track.durationMs),
      playing: playing,
      onTap: track.playable ? onTap : null,
    ),
  );

  /// 重设计外壳的外观件共用的外层：不可播半透明、整块右键菜单、按插件 + 曲目 id
  /// 认「正在播放」。
  Widget _withPlaying(Widget Function(bool playing) row) {
    final String? plugin = pluginId;
    return Opacity(
      opacity: track.playable ? 1 : 0.5,
      child: musicWithContextMenu(
        menu,
        plugin == null
            ? row(false)
            : Consumer(
                builder: (BuildContext context, WidgetRef ref, Widget? _) {
                  final MusicPlayerEngine engine = ref
                      .read(appProvider)
                      .musicSession
                      .engine;
                  final String uid = musicPluginTrackUid(plugin, track.id);
                  return MusicNowPlayingMatch(
                    listenable: engine,
                    isCurrent: () => engine.current?.trackUid == uid,
                    builder: (BuildContext context, bool playing) =>
                        row(playing),
                  );
                },
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String subtitle = <String>[
      if (track.artists.isNotEmpty) track.artistText,
      ?track.albumTitle,
      if (!track.playable) t.music_plugin_unplayable else ?track.note,
    ].join(' · ');
    if (musicTrackRowSurfaceActive(context)) {
      final FushiCoverBlockSize? size = block;
      return size == null
          ? _buildSurface(context, subtitle)
          : _buildBlock(context, subtitle, size);
    }
    return Opacity(
      opacity: track.playable ? 1 : 0.5,
      child: musicWithContextMenu(
        menu,
        FushiPressScale(
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
                  : Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (onPlayMv case final VoidCallback playMv)
                    FushiIconButton(
                      key: ValueKey<String>(
                        'music-plugin-track-mv-${track.id}',
                      ),
                      icon: FushiIcons.video,
                      tooltip: t.music_mv_play,
                      onTap: playMv,
                    ),
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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: MusicViewStyleStore.instance,
    builder: (BuildContext context, Widget? _) => _buildPage(context),
  );

  Widget _buildPage(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<MusicPluginSearchType> types = _types;
    // 结果按当前搜索类型记「色块 / 列表」（原有画法是单列行）。
    final MusicViewKind viewKind = _pluginSearchViewKind(_type);
    final MusicViewStyle style = musicViewStyleOf(
      context,
      viewKind,
      MusicViewStyle.list,
    );
    // 重设计外壳（页头大字）：搜索框 + 类型页签整块进页名下一行
    // （[musicBrowseScaffold] 的 mastheadBottom），类型页签与库页二级页签同一组件
    // （[LibrarySectionTabs] 在页头下方一行里画成连体按钮组）。墨水屏照旧在正文顶。
    final bool masthead = shellRedesignActive(context);
    void selectType(MusicPluginSearchType type) {
      if (type == _type) return;
      _type = type;
      _restart();
    }

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
        if (types.length > 1 && masthead)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: LibrarySectionTabs<MusicPluginSearchType>(
              tabs: <LibrarySectionTab<MusicPluginSearchType>>[
                for (final MusicPluginSearchType st in types)
                  LibrarySectionTab<MusicPluginSearchType>(
                    value: st,
                    label: _typeLabel(st),
                  ),
              ],
              selected: _type,
              onChanged: selectType,
              focusIdPrefix: 'music-plugin-search-type',
            ),
          )
        else if (types.length > 1)
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
              onSelectionChanged: (Set<MusicPluginSearchType> v) =>
                  selectType(v.first),
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
    } else if (style == MusicViewStyle.blocks) {
      results = NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification n) {
          if (_hasMore && n.metrics.extentAfter < 600) unawaited(_loadMore());
          return false;
        },
        child: MusicStyledCollection(
          scrollKey: ValueKey<String>('music-plugin-results-${_type.wire}'),
          style: style,
          itemCount: _items.length,
          padding: withBottomSafeInset(
            context,
            EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.section,
            ),
          ),
          rowBuilder: _itemTile,
          blockBuilder:
              (BuildContext context, int i, FushiCoverBlockSize size) =>
                  musicPluginItemBlock(
                    context,
                    ref,
                    widget.manifest,
                    _items,
                    i,
                    size,
                  ),
          footer: _loading || _hasMore
              ? Padding(
                  padding: EdgeInsets.all(tokens.spacing.gap),
                  child: const FushiLinearProgressIndicator(),
                )
              : null,
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
      actions: <FushiToolbarItem>[
        if (musicViewStyleSwitchable(context))
          musicViewStyleToggle(viewKind, style),
      ],
      mastheadBottom: masthead ? header : null,
      body: Builder(
        builder: (BuildContext context) => Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (!masthead)
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
  Widget build(BuildContext context) => musicTrackRowSurfaceActive(context)
      // 与曲目行混排在同一列表（搜索结果 / 推荐段）里：同一种圆角条，悬停铺
      // 封面取色。
      ? MusicTrackRowSurface(
          title: title,
          subtitle: subtitle,
          coverPath: cover,
          leading: _thumb(cover, round: roundCover),
          onTap: onTap,
          trailing: const <Widget>[FushiIcon(FushiIcons.chevronRight)],
        )
      : _buildClassic(context);

  Widget _buildClassic(BuildContext context) => FushiPressScale(
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
  if (item is! MusicPluginTrack) {
    return musicWithContextMenu(
      musicPluginEntityMenu(context, ref, manifest, item),
      _pluginEntityTile(context, manifest, items, i),
    );
  }
  return _TrackRow(
    track: item,
    index: i,
    count: items.length,
    pluginId: pluginId,
    onPlayMv: _mvAction(context, ref, manifest, item),
    menu: musicPluginTrackMenu(context, ref, manifest, item),
    onTap: () => _playTracks(
      ref,
      pluginId,
      items.whereType<MusicPluginTrack>().toList(),
      start: items.take(i).whereType<MusicPluginTrack>().length,
    ),
  );
}

/// 插件专辑 / 艺人 / 歌单一行（[musicPluginItemTile] 的非曲目分支）。
Widget _pluginEntityTile(
  BuildContext context,
  MusicPluginManifest manifest,
  List<Object> items,
  int i,
) {
  final Object item = items[i];
  return switch (item) {
    MusicPluginAlbum album => _EntityRow(
      key: ValueKey<String>('music-plugin-album-${album.id}'),
      index: i,
      count: items.length,
      cover: album.coverUrl,
      title: album.title,
      subtitle: _pluginAlbumSubtitle(album),
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
      subtitle: _pluginArtistSubtitle(artist) ?? '',
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
      subtitle: _pluginPlaylistSubtitle(playlist),
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

/// 插件专辑的副行：艺人 · 年份 · 曲目数。
String _pluginAlbumSubtitle(MusicPluginAlbum album) => <String>[
  if (album.artists.isNotEmpty) album.artistText,
  if (album.year != null) '${album.year}',
  if (album.trackCount != null) t.music_tracks_count(count: album.trackCount!),
].join(' · ');

/// 插件艺人的副行：专辑数（插件没给为 null）。
String? _pluginArtistSubtitle(MusicPluginArtist artist) =>
    switch (artist.stats.albumCount) {
      final int n => t.music_server_album_count(count: n),
      null => null,
    };

/// 插件歌单的副行：作者 · 曲目数。
String _pluginPlaylistSubtitle(MusicPluginPlaylist playlist) => <String>[
  ?playlist.owner,
  if (playlist.trackCount != null)
    t.music_tracks_count(count: playlist.trackCount!),
].join(' · ');

/// 插件条目的「色块」样式一格（[musicPluginItemTile] 的色块版）：曲目是
/// [MusicTrackBlock]（点块起播、右键菜单、正在播放），专辑 / 艺人 / 歌单是
/// [MusicCollectionBlock]（去处、右键菜单与行同一套；艺人是圆形头像）。key 与行相同。
Widget musicPluginItemBlock(
  BuildContext context,
  WidgetRef ref,
  MusicPluginManifest manifest,
  List<Object> items,
  int i,
  FushiCoverBlockSize size,
) {
  final Object item = items[i];
  if (item is MusicPluginTrack) {
    return _TrackRow(
      track: item,
      index: i,
      count: items.length,
      pluginId: manifest.id,
      block: size,
      menu: musicPluginTrackMenu(context, ref, manifest, item),
      onTap: () => _playTracks(
        ref,
        manifest.id,
        items.whereType<MusicPluginTrack>().toList(),
        start: items.take(i).whereType<MusicPluginTrack>().length,
      ),
    );
  }
  return musicWithContextMenu(
    musicPluginEntityMenu(context, ref, manifest, item),
    switch (item) {
      MusicPluginAlbum album => MusicCollectionBlock(
        key: ValueKey<String>('music-plugin-album-${album.id}'),
        size: size,
        title: album.title,
        subtitle: _pluginAlbumSubtitle(album),
        coverPath: album.coverUrl,
        onTap: () => unawaited(
          _push(
            context,
            MusicPluginCollectionPage.album(manifest: manifest, album: album),
          ),
        ),
      ),
      MusicPluginArtist artist => MusicCollectionBlock(
        key: ValueKey<String>('music-plugin-artist-${artist.id}'),
        size: size,
        title: artist.name,
        subtitle: _pluginArtistSubtitle(artist),
        coverPath: artist.coverUrl,
        circular: true,
        onTap: () => unawaited(
          _push(
            context,
            MusicPluginArtistPage(manifest: manifest, artist: artist),
          ),
        ),
      ),
      MusicPluginPlaylist playlist => MusicCollectionBlock(
        key: ValueKey<String>('music-plugin-playlist-${playlist.id}'),
        size: size,
        title: playlist.title,
        subtitle: _pluginPlaylistSubtitle(playlist),
        coverPath: playlist.coverUrl,
        leadingIcon: FushiIcons.playlist,
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
    },
  );
}

/// 插件搜索类型对应的记样式视图种类。
MusicViewKind _pluginSearchViewKind(MusicPluginSearchType type) =>
    switch (type) {
      MusicPluginSearchType.song => MusicViewKind.tracks,
      MusicPluginSearchType.album => MusicViewKind.albums,
      MusicPluginSearchType.artist => MusicViewKind.artists,
      MusicPluginSearchType.playlist => MusicViewKind.playlists,
    };

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

/// 段标题行：标题 + 可选副标题 + 右侧动作。推荐 / 我的歌单共用。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.subtitle,
    this.actions = const <Widget>[],
    this.eyebrow = false,
    this.group = false,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  /// 插件名那一行：小号眉标，不抢段落标题。
  final bool eyebrow;

  /// 库页分组标题（歌单页签的「<插件> · 我的歌单」）：与同页「本地歌单」等分组标题同级
  /// （titleMedium），不用推荐页的大段标题。
  final bool group;

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
                      : group
                      ? context.fushiType.titleMedium
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

/// 推荐页歌单 / 专辑栏目横排里最多直接列出的卡数；完整列表进「查看全部」网格页
/// （[MusicPluginHomeSectionPage]）。与服务器来源那一排（`_ServerShelf`）同一上限。
const int kMusicPluginShelfPreview = 12;

/// 栏目横排要显示的条目：前 [kMusicPluginShelfPreview] 个。
List<Object> musicPluginShelfPreview(List<Object> items) =>
    items.length <= kMusicPluginShelfPreview
    ? items
    : items.take(kMusicPluginShelfPreview).toList();

// -------------------------------------------------------------------------
// 推荐页的色块版式（重设计外壳「海报大字」）
// -------------------------------------------------------------------------

/// 推荐页（及其「查看全部」二级页）是否按重设计外壳的色块语言画：库页布局是拼贴 /
/// 规整色块时为 true；「封面网格（现有）」与墨水屏（[shellContentLayoutOf] 恒给
/// grid）保持原卡片 / 横排样式。与曲库专辑网格（`music_library_page.dart`）同一判据。
bool musicRecommendPosterMode(BuildContext context) =>
    shellContentLayoutOf(context) != ShellContentLayout.grid;

/// 推荐页歌单 / 专辑栏目在色块版式下最多排几行（其余进「查看全部」）。
const int kMusicRecommendShelfRows = 2;

/// [width] 宽、[layout] 布局（null = 等尺寸色块）下前 [rows] 行能放下几块色块（[computeFushiCoverBlockPlan]
/// 同一份几何，目标块宽取音乐的 [kFushiCoverBlockTargetWidthMedia]）。
int musicCoverBlockRowCapacity({
  required double width,
  required int itemCount,
  required ShellContentLayout? layout,
  required int rows,
}) =>
    computeFushiCoverBlockPlan(
          width: width,
          itemCount: itemCount,
          layout: layout,
          targetWidth: kFushiCoverBlockTargetWidthMedia,
        )
        .take(rows)
        .fold<int>(0, (int n, FushiCoverBlockRow row) => n + row.cells.length);

/// 推荐页一段封面色块：[SliverFushiCoverBlocks]（摆放 / 错峰进场都在里面），只排
/// 前 [maxRows] 行。默认等尺寸色块——拼贴首块留给页首的「最近播放」与每日推荐，栏目
/// 里不再各起一块加大块。
class SliverMusicRecommendBlocks extends StatelessWidget {
  const SliverMusicRecommendBlocks({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.layout,
    this.maxRows = kMusicRecommendShelfRows,
  });

  final int itemCount;
  final FushiCoverBlockItemBuilder itemBuilder;

  /// null = 等尺寸色块（默认）；[ShellContentLayout.collage] = 拼贴。
  final ShellContentLayout? layout;
  final int maxRows;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (BuildContext context, SliverConstraints constraints) =>
        SliverFushiCoverBlocks(
          layout: layout,
          itemCount: musicCoverBlockRowCapacity(
            width: constraints.crossAxisExtent,
            itemCount: itemCount,
            layout: layout,
            rows: maxRows,
          ),
          itemBuilder: itemBuilder,
        ),
  );
}

/// 封面取色后的色块配色（[FushiCoverBlockColors.resolve]，与 [FushiCoverBlock] 同一份
/// [coverColorSchemeCache] 与同一套 HSL）：给带按钮、不能整块套 [FushiCoverBlock] 的
/// 海报块（每日推荐主卡、榜单卡）用。与 [FushiCoverTint] 不同，Apple 设计系统下照样
/// 取色（色块在两套设计系统下都取封面色）；还没算好 / 没封面给中性色。
class _RecommendCoverPalette extends StatefulWidget {
  const _RecommendCoverPalette({required this.image, required this.builder});

  final ImageProvider? image;
  final Widget Function(BuildContext context, FushiCoverBlockColors colors)
  builder;

  @override
  State<_RecommendCoverPalette> createState() => _RecommendCoverPaletteState();
}

class _RecommendCoverPaletteState extends State<_RecommendCoverPalette> {
  ColorScheme? _scheme;
  ImageProvider? _resolvedFor;
  Brightness? _resolvedBrightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_RecommendCoverPalette oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    final ImageProvider? image = widget.image;
    final Brightness brightness = Theme.of(context).brightness;
    if (image == _resolvedFor && brightness == _resolvedBrightness) return;
    _resolvedFor = image;
    _resolvedBrightness = brightness;
    if (image == null) {
      _scheme = null;
      return;
    }
    // 换了封面：先取缓存里的（没有就 null = 中性色），不留上一张的配色。
    _scheme = coverColorSchemeCache.peek(image, brightness);
    if (_scheme != null) return;
    coverColorSchemeCache.resolve(image, brightness).then((ColorScheme? s) {
      if (!mounted ||
          _resolvedFor != image ||
          _resolvedBrightness != brightness) {
        return;
      }
      setState(() => _scheme = s);
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    FushiCoverBlockColors.resolve(Theme.of(context), _scheme),
  );
}

/// 海报块里压在色块上的一张方形封面（平滑圆角 + 投影，与 [FushiCoverBlock] 的前景
/// 封面同一套外观）。
class _RecommendPosterCover extends StatelessWidget {
  const _RecommendPosterCover({required this.cover, required this.size});

  final String? cover;
  final double size;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = BorderRadius.circular(size >= 120 ? 16 : 12);
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shellShape(context, radius),
        shadows: const <BoxShadow>[
          BoxShadow(
            color: Color(0x80000000),
            offset: Offset(0, 12),
            blurRadius: 28,
          ),
        ],
      ),
      child: ShellClip(
        radius: radius,
        child: SizedBox.square(
          dimension: size,
          child: MusicCover(
            coverPath: cover,
            size: size,
            borderRadius: BorderRadius.zero,
          ),
        ),
      ),
    );
  }
}

/// 每日推荐主卡右侧的封面扇（最多三张，最前那张在起始边、其余依次往后叠、各转
/// 一点；设计稿书架 `.bk .fan` 的摆法换成方形专辑封面）。
class _RecommendCoverFan extends StatelessWidget {
  const _RecommendCoverFan({required this.covers});

  final List<String> covers;

  /// 首个（最前）到最后一张的旋转角（度）。
  static const List<double> _rotation = <double>[-5, 4, 11];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      final int n = math.min(covers.length, _rotation.length);
      if (n == 0) return const SizedBox.shrink();
      final double size = math.min(c.maxHeight, c.maxWidth * 0.62);
      final double step = n == 1 ? 0 : (c.maxWidth - size) / (n - 1);
      return Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          // 后面的先画，最前那张最后画（压在最上面）。
          for (int i = n - 1; i >= 0; i--)
            PositionedDirectional(
              start: i * step,
              top: (c.maxHeight - size) / 2,
              width: size,
              height: size,
              child: Transform.rotate(
                angle: _rotation[i] * math.pi / 180,
                child: _RecommendPosterCover(cover: covers[i], size: size),
              ),
            ),
        ],
      );
    },
  );
}

/// 推荐页一块封面色块卡（歌单 / 专辑栏目、「最近播放」、「查看全部」网格）：
/// [FushiCoverBlock] 方形专辑摆法套在封面卡外壳里（点按 / 焦点 / 键盘激活由
/// [shelfCoverCard] 负责），悬停抬升走 [FushiHoverLift]。
Widget _musicRecommendCoverBlock({
  Key? key,
  required FushiCoverBlockSize size,
  required String title,
  required String? subtitle,
  required String? cover,
  required VoidCallback onTap,
  FushiCoverBlockAction? action,
}) => FushiHoverLift(
  scale: kMusicHoverLiftScale,
  builder: (BuildContext context, bool _) => shelfCoverCard(
    key: key,
    shape: fushiCoverBlockShape(context, size),
    onTap: onTap,
    child: FushiCoverBlock(
      size: size,
      art: FushiCoverBlockArt.square,
      title: title,
      subtitle: subtitle == null || subtitle.isEmpty ? null : subtitle,
      covers: <Widget>[
        MusicCover(coverPath: cover, borderRadius: BorderRadius.zero),
      ],
      tintImage: musicCoverImageProvider(cover, size: 128),
      // 主按钮外观只在拼贴首块画，且只是视觉（点卡就是这个动作）。
      action: size == FushiCoverBlockSize.hero ? action : null,
    ),
  ),
);

/// 插件歌单 / 专辑的封面色块卡（[_pluginCoverTarget] 同一份要素与去处，同一份右键 /
/// 长按菜单）。不是歌单 / 专辑的条目不画。
class _PluginCoverBlockCard extends ConsumerWidget {
  const _PluginCoverBlockCard({
    super.key,
    required this.manifest,
    required this.item,
    required this.size,
  });

  final MusicPluginManifest manifest;
  final Object item;
  final FushiCoverBlockSize size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final _PluginCoverTarget? target = _pluginCoverTarget(manifest, item);
    if (target == null) return const SizedBox.shrink();
    return musicWithContextMenu(
      musicPluginEntityMenu(context, ref, manifest, item),
      _musicRecommendCoverBlock(
        size: size,
        title: target.title,
        subtitle: target.subtitle,
        cover: target.cover,
        onTap: () => unawaited(_push(context, target.page)),
        action: FushiCoverBlockAction(
          icon: FushiIcons.playlist,
          label: t.music_plugin_hero_open,
        ),
      ),
    );
  }
}

/// 歌单 / 专辑卡的展示要素与点开后的详情页。
typedef _PluginCoverTarget = ({
  String id,
  String title,
  String? cover,
  String? subtitle,
  Widget page,
});

/// [item] 是歌单 / 专辑时给出卡片要素；其它类型返回 null（不画卡）。
_PluginCoverTarget? _pluginCoverTarget(
  MusicPluginManifest manifest,
  Object item,
) => switch (item) {
  MusicPluginPlaylist p => (
    id: 'playlist-${p.id}',
    title: p.title,
    cover: p.coverUrl,
    subtitle: p.owner,
    page: MusicPluginCollectionPage.playlist(manifest: manifest, playlist: p),
  ),
  MusicPluginAlbum a => (
    id: 'album-${a.id}',
    title: a.title,
    cover: a.coverUrl,
    subtitle: a.artists.isEmpty
        ? null
        : a.artists.map((MusicPluginArtistRef r) => r.name).join(' / '),
    page: MusicPluginCollectionPage.album(manifest: manifest, album: a),
  ),
  _ => null,
};

/// 横向一排封面卡（推荐歌单 / 榜单 / 新碟）。
class _CoverCarousel extends ConsumerWidget {
  const _CoverCarousel({
    super.key,
    required this.manifest,
    required this.items,
  });

  static const double _size = 144;

  final MusicPluginManifest manifest;
  final List<Object> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              final _PluginCoverTarget? target = _pluginCoverTarget(
                manifest,
                item,
              );
              if (target == null) return const SizedBox.shrink();
              final String id = target.id;
              final String title = target.title;
              final String? cover = target.cover;
              final Widget page = target.page;
              return musicWithContextMenu(
                musicPluginEntityMenu(context, ref, manifest, item),
                SizedBox(
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
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

/// 推荐页歌单 / 专辑栏目的「查看全部」：该栏目全部条目的封面网格，点卡片进专辑 /
/// 歌单详情（与横排卡同一个去处、同一份右键 / 长按菜单）。几何与服务器曲库专辑
/// 网格同一套（[musicAlbumGridDelegate]）。
class MusicPluginHomeSectionPage extends StatelessWidget {
  const MusicPluginHomeSectionPage({
    super.key,
    required this.manifest,
    required this.section,
  });

  final MusicPluginManifest manifest;
  final MusicPluginHomeSection section;

  @override
  Widget build(BuildContext context) {
    final List<Object> items = section.items
        .where((Object o) => _pluginCoverTarget(manifest, o) != null)
        .toList();
    // 栏目是专辑（新碟）还是歌单（推荐歌单 / 榜单）：按首项记样式。
    final MusicViewKind kind = items.firstOrNull is MusicPluginAlbum
        ? MusicViewKind.albums
        : MusicViewKind.playlists;
    return MusicViewStyleBuilder(
      kind: kind,
      fallback: MusicViewStyle.blocks,
      builder: (BuildContext context, MusicViewStyle style) =>
          musicBrowseScaffold(
            context,
            title: section.title,
            actions: <FushiToolbarItem>[
              if (musicViewStyleSwitchable(context))
                musicViewStyleToggle(kind, style),
            ],
            // 留白要在脚手架之下量：页头让位（MediaQuery 顶部 padding）只在那里才有。
            body: Builder(
              builder: (BuildContext context) {
                final FushiDesignTokens tokens = FushiDesignTokens.of(context);
                if (items.isEmpty) {
                  return Center(
                    child: FushiPlaceholderMessage(
                      icon: FushiIcons.music,
                      message: t.music_plugin_home_empty,
                    ),
                  );
                }
                // 色块：封面网格布局下是原有的唱片网格卡，色块布局下（拼贴 / 规整）
                // 与曲库专辑网格同一套色块；列表：单列行（与搜索结果同一种行）。
                return MusicStyledCollection(
                  scrollKey: ValueKey<String>(
                    'music-plugin-section-grid-${manifest.id}-${section.id}',
                  ),
                  style: style,
                  itemCount: items.length,
                  padding: withBottomSafeInset(
                    context,
                    EdgeInsets.fromLTRB(
                      tokens.spacing.page,
                      MediaQuery.paddingOf(context).top + tokens.spacing.gap,
                      tokens.spacing.page,
                      tokens.spacing.section,
                    ),
                  ),
                  gridMaterial: ShelfCoverMaterial.glossyAlbum,
                  gridDelegate: musicAlbumGridDelegate,
                  gridCardBuilder: (BuildContext context, int i) =>
                      _PluginGridCard(manifest: manifest, item: items[i]),
                  blockBuilder:
                      (BuildContext context, int i, FushiCoverBlockSize size) =>
                          _PluginCoverBlockCard(
                            key: ValueKey<String>(
                              'music-plugin-grid-card-'
                              '${_pluginCoverTarget(manifest, items[i])!.id}',
                            ),
                            manifest: manifest,
                            item: items[i],
                            size: size,
                          ),
                  rowBuilder: (BuildContext context, int i) => Consumer(
                    builder: (BuildContext context, WidgetRef ref, Widget? _) =>
                        musicPluginItemTile(context, ref, manifest, items, i),
                  ),
                );
              },
            ),
          ),
    );
  }
}

/// 「查看全部」网格里的一张歌单 / 专辑卡：唱片封面 + [ShelfCardMeta]（与服务器专辑卡
/// [MusicServerAlbumCard] 同一构成，网格行高按同一份文字块算）。
class _PluginGridCard extends ConsumerWidget {
  const _PluginGridCard({required this.manifest, required this.item});

  final MusicPluginManifest manifest;
  final Object item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final _PluginCoverTarget? target = _pluginCoverTarget(manifest, item);
    if (target == null) return const SizedBox.shrink();
    return musicWithContextMenu(
      musicPluginEntityMenu(context, ref, manifest, item),
      FushiHoverLift(
        key: ValueKey<String>('music-plugin-grid-card-${target.id}'),
        scale: kMusicHoverLiftScale,
        builder: (BuildContext context, bool _) => shelfCoverCard(
          onTap: () => unawaited(_push(context, target.page)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AspectRatio(
                aspectRatio: kShelfAlbumAspectRatio,
                child: ShelfCoverFrame(
                  child: MusicCover(coverPath: target.cover),
                ),
              ),
              ShelfCardMeta(title: target.title, subtitle: target.subtitle),
            ],
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
    this.trailing,
    this.showPersonal = true,
    this.leading,
  });

  final List<MusicPluginManifest> sources;

  /// 列表最前面跟着滚动的一块（音乐页把曲库「继续收听」交进来，见
  /// `MusicSourcesRecommendView.leading`）；null 不画。
  final Widget? leading;

  /// 插件段落之后追加的块（「推荐 › 全部」里各服务器来源的一排专辑）。参数是本页
  /// 这次用不用色块版式（[musicRecommendPosterMode]）：true 时页面是
  /// [CustomScrollView]，返回的必须是 sliver；false 时是原 [ListView] 的盒子。
  final List<Widget> Function(bool sliver)? trailing;

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

  /// 一个插件的推荐段落。[sliver] = 色块版式（[musicRecommendPosterMode]）：返回
  /// sliver，盒子段落包一层 [SliverToBoxAdapter] + 错峰进场，歌单 / 专辑栏目换成
  /// 封面色块（[SliverMusicRecommendBlocks]）；否则是原 [ListView] 的盒子。
  List<Widget> _pluginBlocks(
    BuildContext context,
    _HomeResult r, {
    bool sliver = false,
  }) {
    final MusicPluginManifest m = r.manifest;
    final List<Widget> out = <Widget>[];
    void add(Widget w) => out.add(
      sliver
          ? SliverToBoxAdapter(
              child: FushiStaggeredEntrance(index: out.length, child: w),
            )
          : w,
    );
    add(
      _SectionHeader(
        title: m.name,
        eyebrow: true,
        actions: <Widget>[
          ?_pluginRadioButton(context, ref, m),
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
    );
    if (r.error != null) {
      add(
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
      add(Text(t.music_plugin_home_empty, style: context.fushiType.bodySmall));
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
    add(
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
      add(
        _SectionHeader(
          title: sec.title,
          subtitle: sec.subtitle,
          actions: <Widget>[
            // 「播放」与「查看全部」同一种样式（[musicSectionAction]）。
            if (sec.kind == MusicPluginHomeKind.tracks)
              musicSectionAction(
                key: ValueKey<String>(
                  'music-plugin-home-play-${m.id}-${sec.id}',
                ),
                kind: MusicSectionActionKind.play,
                label: t.music_play_all,
                onPressed: () => _playTracks(ref, m.id, tracks),
              )
            else
              // 歌单 / 专辑栏目：与服务器来源那一排（`_ServerShelf`）同一个出口，
              // 进网格页看该栏目的完整列表（含被主卡 / 榜单卡占去的条目）。
              musicSectionAction(
                key: ValueKey<String>(
                  'music-plugin-home-view-all-${m.id}-${sec.id}',
                ),
                kind: MusicSectionActionKind.viewAll,
                label: t.music_sources_view_all,
                onPressed: () => unawaited(
                  _push(
                    context,
                    MusicPluginHomeSectionPage(manifest: m, section: sec),
                  ),
                ),
              ),
          ],
        ),
      );
      switch (sec.kind) {
        case MusicPluginHomeKind.tracks:
          // 曲目段是可播的行（行尾 MV / 更多菜单），不是封面卡，两种版式同一份：
          // 重设计外壳下整段装进一块色块面板（[MusicTrackGridPanel]）。
          add(
            _TrackGrid(
              key: ValueKey<String>('music-plugin-home-${m.id}-${sec.id}'),
              title: sec.title,
              manifest: m,
              items: tracks.take(_trackPreview).toList(),
            ),
          );
        case MusicPluginHomeKind.playlists || MusicPluginHomeKind.albums:
          if (sliver) {
            out.add(_shelfBlocks(m, sec, musicPluginShelfPreview(items)));
          } else {
            add(
              _CoverCarousel(
                key: ValueKey<String>('music-plugin-home-${m.id}-${sec.id}'),
                manifest: m,
                items: musicPluginShelfPreview(items),
              ),
            );
          }
      }
    }
    return out;
  }

  /// 色块版式下的歌单 / 专辑栏目：横排换成封面色块，只排前
  /// [kMusicRecommendShelfRows] 行，其余照旧进「查看全部」。
  Widget _shelfBlocks(
    MusicPluginManifest m,
    MusicPluginHomeSection sec,
    List<Object> preview,
  ) {
    final List<Object> cards = <Object>[
      for (final Object o in preview)
        if (_pluginCoverTarget(m, o) != null) o,
    ];
    return SliverMusicRecommendBlocks(
      key: ValueKey<String>('music-plugin-home-${m.id}-${sec.id}'),
      itemCount: cards.length,
      itemBuilder: (BuildContext context, int i, FushiCoverBlockSize size) =>
          _PluginCoverBlockCard(
            key: ValueKey<String>(
              'music-plugin-card-${_pluginCoverTarget(m, cards[i])!.id}',
            ),
            manifest: m,
            item: cards[i],
            size: size,
          ),
    );
  }

  /// 色块版式（[musicRecommendPosterMode]）：同一组段落排进 [CustomScrollView]，
  /// 「最近播放」与歌单 / 专辑栏目是封面色块 sliver，其余盒子段落逐个错峰进场。
  Widget _buildPoster(BuildContext context, List<_HomeResult> data) {
    final List<Widget> slivers = <Widget>[
      if (widget.leading case final Widget leading)
        SliverToBoxAdapter(
          child: FushiStaggeredEntrance(index: 0, child: leading),
        ),
      if (widget.showPersonal) ...<Widget>[
        SliverToBoxAdapter(
          child: FushiStaggeredEntrance(
            index: 0,
            child: _LikedMusic(
              key: const ValueKey<String>('music-liked'),
              sources: widget.sources,
            ),
          ),
        ),
        _RecentPlays(
          key: const ValueKey<String>('music-recent-plays'),
          generation: _generation,
          sources: widget.sources,
          sliver: true,
        ),
      ],
      for (final _HomeResult r in data)
        ..._pluginBlocks(context, r, sliver: true),
      ...?widget.trailing?.call(true),
    ];
    return FushiEntranceScope(
      child: CustomScrollView(
        key: const ValueKey<String>('music-plugin-recommend'),
        slivers: <Widget>[
          SliverPadding(
            padding: musicBrowsePagePadding(context),
            sliver: SliverMainAxisGroup(slivers: slivers),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_HomeResult>>(
      future: _data,
      builder: (BuildContext context, AsyncSnapshot<List<_HomeResult>> snap) {
        if (snap.hasData) _shown = snap.data;
        final List<_HomeResult>? data = snap.data ?? _shown;
        if (data == null) return const FushiLoadingView();
        if (musicRecommendPosterMode(context)) {
          return _buildPoster(context, data);
        }
        final List<Widget> blocks = <Widget>[
          ?widget.leading,
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
          ...?widget.trailing?.call(false),
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
          group: true,
          actions: <Widget>[
            ?_pluginCreatePlaylistButton(context, ref, m, onCreated: _reload),
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
                // 与曲库本地歌单同一份「色块 / 列表」样式（曲库页头的切换键）。
                return MusicViewStyleBuilder(
                  kind: MusicViewKind.playlists,
                  fallback: MusicViewStyle.list,
                  builder: (BuildContext context, MusicViewStyle style) =>
                      style == MusicViewStyle.blocks
                      ? FushiCoverBlocks(
                          layout: shellContentLayoutOf(context),
                          staggerEntrance: false,
                          itemCount: lists.length,
                          itemBuilder:
                              (
                                BuildContext context,
                                int i,
                                FushiCoverBlockSize size,
                              ) => musicPluginItemBlock(
                                context,
                                ref,
                                m,
                                lists,
                                i,
                                size,
                              ),
                        )
                      : _ItemColumn(manifest: m, items: lists),
                );
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

  /// 色块版式：主卡与拼贴首块同高（[kFushiCoverBlockHeroHeight]，窄窗
  /// [kFushiCoverBlockHeroHeightCompact]），榜单卡是旁边叠放的半高卡，间距与色块
  /// 布局同一档——与曲库 / 首页拼贴首行同一副骨架。高度钉死，不走 IntrinsicHeight。
  Widget _buildPoster(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      const double gap = kFushiCoverBlockSpacing;
      final bool narrow = c.maxWidth < 720;
      final double heroHeight = narrow
          ? kFushiCoverBlockHeroHeightCompact
          : kFushiCoverBlockHeroHeight;
      final double halfHeight = (heroHeight - gap) / 2;
      if (side.isEmpty) return SizedBox(height: heroHeight, child: hero);
      if (narrow) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: gap,
          children: <Widget>[
            SizedBox(height: heroHeight, child: hero),
            for (final Widget w in side) SizedBox(height: halfHeight, child: w),
          ],
        );
      }
      return SizedBox(
        height: heroHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: gap,
          children: <Widget>[
            Expanded(flex: 135, child: hero),
            Expanded(
              flex: 100,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
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

  @override
  Widget build(BuildContext context) {
    if (musicRecommendPosterMode(context)) return _buildPoster(context);
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

  /// 色块版式的主卡（与拼贴首块同一语言）：取头一张封面的色做底，段名（每日推荐）
  /// 是 900 字重的大字水印；左边插件名 chip + 大标题 + 首数 + 原样的「播放 / 随机」
  /// （或「打开」）按钮组，右边是这一段的封面扇压在色块上。块里有真按钮，整块不是
  /// 点按目标、不随悬停抬升（与复习页今日计划同一做法）。
  Widget _buildPoster({
    required String eyebrow,
    required String title,
    required String meta,
    required List<String> wall,
    required Widget buttons,
  }) => _RecommendCoverPalette(
    image: musicCoverImageProvider(wall.firstOrNull, size: 128),
    builder: (BuildContext context, FushiCoverBlockColors colors) =>
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final bool compact = c.maxHeight < kFushiCoverBlockHeroHeight;
            final double pad = compact ? 18 : 22;
            final bool fan = wall.isNotEmpty && c.maxWidth >= 440;
            final TextStyle base =
                Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
            return FushiPosterBlock(
              key: ValueKey<String>('music-plugin-hero-poster-${manifest.id}'),
              watermark: title,
              colors: colors,
              watermarkFontSize: c.maxHeight * 0.62,
              watermarkEdge: FushiPosterWatermarkEdge.bottom,
              hoverEnabled: false,
              padding: EdgeInsets.all(pad),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: pad,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        FushiPosterChip(
                          label: eyebrow,
                          colors: colors,
                          solid: true,
                        ),
                        SizedBox(height: compact ? 8 : 12),
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              (compact
                                      ? FushiPosterText.titleCompact
                                      : FushiPosterText.title)
                                  .on(base)
                                  .copyWith(color: colors.onContainer),
                        ),
                        if (meta.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 6),
                          Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: FushiPosterText.caption
                                .on(base)
                                .copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: colors.onContainer.withValues(
                                    alpha: 0.85,
                                  ),
                                ),
                          ),
                        ],
                        const Spacer(),
                        buttons,
                      ],
                    ),
                  ),
                  if (fan)
                    SizedBox(
                      width: c.maxWidth * 0.4,
                      child: _RecommendCoverFan(covers: wall),
                    ),
                ],
              ),
            );
          },
        ),
  );

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
    if (musicRecommendPosterMode(context)) {
      return _buildPoster(
        eyebrow: eyebrow,
        title: title,
        meta: meta,
        wall: wall,
        buttons: buttons,
      );
    }
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
class _RankCard extends ConsumerWidget {
  const _RankCard({super.key, required this.manifest, required this.playlist});

  final MusicPluginManifest manifest;
  final MusicPluginPlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) => musicWithContextMenu(
    musicPluginEntityMenu(context, ref, manifest, playlist),
    musicRecommendPosterMode(context) ? _poster(context) : _card(context),
  );

  void _open(BuildContext context) => unawaited(
    _push(
      context,
      MusicPluginCollectionPage.playlist(
        manifest: manifest,
        playlist: playlist,
      ),
    ),
  );

  /// 色块版式：主卡旁的半高色块。底色取榜单封面，榜名做大字水印；封面斜压在
  /// 色块左侧，右边榜名 + 放得下的前几首（名次用强调色大号数字，代替饼干徽章）。
  /// 整块是一个点按目标（进歌单），悬停抬升由 [FushiPosterBlock] 给。
  Widget _poster(BuildContext context) => _RecommendCoverPalette(
    image: musicCoverImageProvider(playlist.coverUrl, size: 128),
    builder: (BuildContext context, FushiCoverBlockColors colors) =>
        shelfCoverCard(
          shape: fushiCoverBlockShape(context, FushiCoverBlockSize.half),
          onTap: () => _open(context),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              const double pad = 14;
              final double cover = math.min(c.maxHeight - pad * 2, 120);
              return FushiPosterBlock(
                watermark: playlist.title,
                colors: colors,
                watermarkFontSize: c.maxHeight * 0.62,
                blockSize: FushiCoverBlockSize.half,
                padding: const EdgeInsets.all(pad),
                child: Row(
                  spacing: 18,
                  children: <Widget>[
                    Transform.rotate(
                      angle: -5 * math.pi / 180,
                      child: _RecommendPosterCover(
                        cover: playlist.coverUrl,
                        size: cover,
                      ),
                    ),
                    Expanded(
                      child: _RankPosterText(
                        playlist: playlist,
                        colors: colors,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
  );

  Widget _card(BuildContext context) {
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

/// 色块榜单卡的文字区：榜名 + 前几首。行数按可用高度与文字缩放算（半高卡在窄窗
/// 只有一百来 dp），放不下的预览行整行不画，不溢出。
class _RankPosterText extends StatelessWidget {
  const _RankPosterText({required this.playlist, required this.colors});

  final MusicPluginPlaylist playlist;
  final FushiCoverBlockColors colors;

  @override
  Widget build(BuildContext context) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextStyle base =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    const double titleSize = 17;
    const double lineSize = 12.5;
    const double gap = 4;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double titleHeight = scaler.scale(titleSize) * 1.15;
        final double lineHeight = scaler.scale(lineSize) * 1.35 + gap;
        final int lines = c.maxHeight.isFinite
            ? ((c.maxHeight - titleHeight - gap) / lineHeight).floor().clamp(
                0,
                playlist.previewTracks.length,
              )
            : playlist.previewTracks.length;
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: gap,
          children: <Widget>[
            Text(
              playlist.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: FushiPosterText.label
                  .on(base)
                  .copyWith(color: colors.onContainer),
            ),
            for (int i = 0; i < lines; i++)
              Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(
                      text: '${i + 1}  ',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: colors.accent,
                      ),
                    ),
                    TextSpan(text: playlist.previewTracks[i].title),
                    TextSpan(
                      text: '  ${playlist.previewTracks[i].artistText}',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: colors.onContainer.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: FushiPosterText.line
                    .on(base)
                    .copyWith(color: colors.onContainer),
              ),
          ],
        );
      },
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
  const _TrackGrid({
    super.key,
    required this.title,
    required this.manifest,
    required this.items,
  });

  /// 段标题（色块面板的水印字）。
  final String title;
  final MusicPluginManifest manifest;
  final List<Object> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget tile(BuildContext context, int i) =>
        musicPluginItemTile(context, ref, manifest, items, i);
    // 重设计外壳（两种库页布局同一份）：整段装进与上下封面色块同一层级的色块
    // 面板，底色取首曲封面，列数按面板内宽自适应（[MusicTrackGridPanel]）。
    if (musicTrackRowSurfaceActive(context)) {
      return MusicTrackGridPanel(
        title: title,
        coverPath: items.whereType<MusicPluginTrack>().firstOrNull?.coverUrl,
        itemCount: items.length,
        itemBuilder: tile,
      );
    }
    return _legacy(context, tile);
  }

  /// 墨水屏：原分组卡行网格。
  Widget _legacy(BuildContext context, IndexedWidgetBuilder tile) =>
      LayoutBuilder(
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
                            ? tile(context, r * cols + k)
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
    this.sliver = false,
  });

  /// true：色块版式（[musicRecommendPosterMode]），build 出 sliver——格子是封面色块
  /// （推荐页按库页布局排，拼贴首块 = 最近一条）；false：原快捷格，build 出盒子。
  final bool sliver;

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

/// 「最近播放」的一格（快捷格与封面色块共用的要素）。[play]：点了是从这首起播
/// （单曲）；否则是进专辑 / 歌单详情。
typedef _RecentEntry = ({
  Key key,
  String title,
  String? subtitle,
  String? cover,
  VoidCallback onTap,
  bool play,
});

class _RecentPlaysState extends ConsumerState<_RecentPlays> {
  /// 读多少条（推荐页只露一行，其余在「查看全部」里）。
  static const int _max = 50;

  /// 能点回去的来源种类（服务器来源要现连服务器，先不进快捷格）。
  static const Set<MusicPlaySourceKind> _kinds = <MusicPlaySourceKind>{
    MusicPlaySourceKind.album,
    MusicPlaySourceKind.playlist,
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
      case MusicPlaySourceKind.playlist:
        // 本地歌单（v148 起可建可播）：删了的歌单不再能点回去。
        final MusicPlaylistRow? playlist = await ref
            .read(appProvider)
            .database
            .getMusicPlaylist(src.id);
        if (playlist == null || !mounted) return;
        openMusicLocalPlaylist(context, playlist);
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

  /// 最近播放的格子：来源（专辑 / 歌单）在前，不够再补最近播放的单曲，最多 [_max]。
  List<_RecentEntry> _entries(_Recent r) {
    final List<_RecentEntry> out = <_RecentEntry>[
      for (final MusicRecentPlaySource src in r.sources)
        (
          key: ValueKey<String>(
            'music-recent-source-${src.source.kind.wire}-${src.source.id}',
          ),
          title: src.source.title ?? '',
          subtitle: null,
          cover: src.source.cover,
          onTap: () => unawaited(_openSource(src.source)),
          play: false,
        ),
    ];
    for (int i = 0; i < r.tracks.length && out.length < _max; i++) {
      final MusicRecentTrack tr = r.tracks[i];
      // 来源已在格子里的单曲不重复列。
      if (tr.source != null &&
          r.sources.any((MusicRecentPlaySource s) => s.source == tr.source)) {
        continue;
      }
      out.add((
        key: ValueKey<String>('music-recent-track-${tr.item.trackUid}'),
        title: tr.item.title,
        subtitle: tr.item.artist,
        cover: tr.item.coverPath,
        onTap: () => _playTrack(r.tracks, i),
        play: true,
      ));
    }
    return out;
  }

  /// 段标题（推荐页里才有；[more] = 还有没露出来的，给「查看全部」）。
  Widget _header(BuildContext context, {required bool more}) => _SectionHeader(
    title: t.music_recent_plays_title,
    actions: <Widget>[
      if (more)
        musicSectionAction(
          key: const ValueKey<String>('music-recent-view-all'),
          kind: MusicSectionActionKind.viewAll,
          label: t.music_sources_view_all,
          onPressed: () => unawaited(
            _push(
              context,
              _RecentPlaysPage(
                generation: widget.generation,
                sources: widget.sources,
              ),
            ),
          ),
        ),
    ],
  );

  /// 色块版式的一格：方形专辑摆法的封面色块，拼贴首块带「播放 / 打开」主按钮外观
  /// （点卡就是这个动作）。
  Widget _block(_RecentEntry e, FushiCoverBlockSize size) =>
      _musicRecommendCoverBlock(
        key: e.key,
        size: size,
        title: e.title,
        subtitle: e.subtitle,
        cover: e.cover,
        onTap: e.onTap,
        action: FushiCoverBlockAction(
          icon: e.play ? FushiIcons.play : FushiIcons.playlist,
          label: e.play ? t.music_play_all : t.music_plugin_hero_open,
        ),
      );

  /// 色块版式：推荐页按库页布局排一行（拼贴 = 最近一条是加大块、旁边叠半高卡），
  /// 其余进「查看全部」；二级页（[_RecentPlays.full]）全部列出。
  Widget _buildSliver(BuildContext context, List<_RecentEntry> entries) {
    final ShellContentLayout layout = shellContentLayoutOf(context);
    Widget block(BuildContext context, int i, FushiCoverBlockSize size) =>
        _block(entries[i], size);
    if (widget.full) {
      return SliverFushiCoverBlocks(
        layout: layout,
        itemCount: entries.length,
        itemBuilder: block,
      );
    }
    return SliverLayoutBuilder(
      builder: (BuildContext context, SliverConstraints constraints) {
        final int shown = musicCoverBlockRowCapacity(
          width: constraints.crossAxisExtent,
          itemCount: entries.length,
          layout: layout,
          rows: 1,
        );
        return SliverMainAxisGroup(
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: _header(context, more: entries.length > shown),
            ),
            SliverFushiCoverBlocks(
              layout: layout,
              itemCount: shown,
              itemBuilder: block,
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_Recent>(
    future: _data,
    builder: (BuildContext context, AsyncSnapshot<_Recent> snap) {
      if (snap.hasData) _shown = snap.data;
      final _Recent? r = snap.data ?? _shown;
      if (r == null || (r.sources.isEmpty && r.tracks.isEmpty)) {
        return widget.sliver
            ? const SliverToBoxAdapter(child: SizedBox.shrink())
            : const SizedBox.shrink();
      }
      final List<_RecentEntry> entries = _entries(r);
      if (widget.sliver) return _buildSliver(context, entries);
      final List<Widget> tiles = <Widget>[
        for (final _RecentEntry e in entries)
          _QuickTile(
            key: e.key,
            title: e.title,
            subtitle: e.subtitle,
            cover: e.cover,
            tinted: true,
            onTap: e.onTap,
            playOnTap: e.play,
          ),
      ];
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
              _header(context, more: tiles.length > shown),
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
      builder: (BuildContext context) => musicRecommendPosterMode(context)
          // 色块版式：与推荐页同一套封面色块，按库页布局排全部。
          ? FushiEntranceScope(
              child: CustomScrollView(
                slivers: <Widget>[
                  SliverPadding(
                    padding: musicBrowsePagePadding(context),
                    sliver: _RecentPlays(
                      generation: generation,
                      sources: sources,
                      full: true,
                      sliver: true,
                    ),
                  ),
                ],
              ),
            )
          : SingleChildScrollView(
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

  /// 色块版式：每个插件一块半高封面色块（拼贴首行旁叠的半高卡那一档），按音乐的
  /// 目标块宽定列——是页首的一条入口带，不抢下面「最近播放」拼贴首块的分量。
  Widget _posterStrip(
    BuildContext context,
    AppModel app,
    List<MusicPluginLikeState> states,
  ) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      const double spacing = kFushiCoverBlockSpacing;
      final int cols = fushiCoverBlockColumns(
        c.maxWidth,
        kFushiCoverBlockTargetWidthMedia,
        spacing,
      );
      final double w = (c.maxWidth - spacing * (cols - 1)) / cols;
      const double h = (kFushiCoverBlockHeroHeight - spacing) / 2;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: <Widget>[
          for (final MusicPluginLikeState s in states)
            SizedBox(
              width: w,
              height: h,
              child: _musicRecommendCoverBlock(
                key: ValueKey<String>('music-liked-${s.manifest.id}'),
                size: FushiCoverBlockSize.half,
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
  );

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
        if (musicRecommendPosterMode(context)) {
          return Padding(
            padding: EdgeInsets.only(top: gap),
            child: _posterStrip(context, app, states),
          );
        }
        // 推荐页第一块：离上方来源筛选条再空一个 gap（列表顶已有一个 gap，合 16dp）；
        // 底下不留白，与下一段（「最近播放」段头自带 section 上边距）之间正好一个 section，
        // 与其余各段同一节奏（用户 2026-11-06 截图：首块贴着筛选条、这里却多出 8dp）。
        return Padding(
          padding: EdgeInsets.only(top: gap),
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
    this.tinted = false,
  });

  final String title;
  final String? subtitle;
  final String? cover;
  final VoidCallback onTap;
  final bool playOnTap;

  /// 底色取自封面（「最近播放」格子，2026-11-01 用户：「音乐的继续播放也做个
  /// 取色」，与书架 / 视频 / 游戏的「继续」取色卡同一套配色）。
  final bool tinted;

  @override
  Widget build(BuildContext context) => tinted
      ? FushiCoverTint(image: musicCoverImageProvider(cover), builder: _build)
      : _build(context, null);

  Widget _build(BuildContext context, ColorScheme? tint) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color background =
        tint?.secondaryContainer ?? FushiDesignTokens.of(context).surfaces.card;
    final TextStyle titleStyle = context.fushiType.titleSmallEmphasized;
    return SizedBox(
      height: 64,
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: background),
        duration: fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.standard,
        builder: (BuildContext context, Color? color, Widget? child) =>
            _MorphCard(
              color: color ?? background,
              radius: const BorderRadius.all(Radius.circular(16)),
              hoverRadius: const BorderRadius.all(Radius.circular(32)),
              onTap: onTap,
              child: child!,
            ),
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
                    style: tint == null
                        ? titleStyle
                        : titleStyle.copyWith(color: tint.onSecondaryContainer),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.bodySmall.copyWith(
                        color:
                            tint?.onSecondaryContainer.withValues(
                              alpha: 0.72,
                            ) ??
                            cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FushiIcon(
                playOnTap ? FushiIcons.play : FushiIcons.chevronRight,
                color: tint?.primary ?? cs.primary,
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
