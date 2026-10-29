/// 音乐库页（设计 §11.2）：分区 专辑 · 艺人 · 歌曲 · 作品 · 歌单。不做统计概况卡（D9）。
/// 「作品」分区的数据来自作品图谱（docs/specs/2026-10-24-cross-media-links.md），P0 先空态。
library;

import 'dart:async';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdate, TableUpdateQuery;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart'
    show
        InstalledMusicPlugin,
        MusicPluginCapability,
        MusicPluginManifest,
        MusicPluginSearchType;

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/media/music/music_format_badge.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_album_page.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_disc_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_pages.dart';
import 'package:fushi/src/pages/implementations/music/music_now_playing_bar.dart'
    show MusicBarReserve, MusicFloatingBarHost;
import 'package:fushi/src/media/music/plugin/music_plugin_gate.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/pages/implementations/music/music_unified_search.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/sync/sync_progress_banner.dart';
import 'package:fushi/utils.dart';

/// 曲库分区（浏览维度）。格式 / 来源 / 有无逐字歌词是筛选条件，不做成分区（§11.2）。
///
/// [recommend] 是插件音源的推荐页（docs/specs/2026-10-28-music-plugins.md §4 `home`）：只在
/// 装了声明 `home` 能力的插件时出现，没配音源不显示。
///
/// 页签只表示「看什么类型」（用户 2026-10-29 拍板，设计稿
/// `fushi/build/music_design/music_ia.html`）。首页只负责浏览：搜索一律走右上角按钮推入的
/// 二级搜索页（宽窄屏同一套，用户 2026-10-29 拍板），不在页签里就地过滤。
enum MusicLibrarySection { recommend, songs, albums, artists, playlists, works }

String musicLibrarySectionLabel(MusicLibrarySection s) => switch (s) {
  MusicLibrarySection.recommend => t.music_section_recommend,
  MusicLibrarySection.albums => t.music_section_albums,
  MusicLibrarySection.artists => t.music_section_artists,
  MusicLibrarySection.songs => t.music_section_songs,
  MusicLibrarySection.works => t.music_section_works,
  MusicLibrarySection.playlists => t.music_section_playlists,
};

/// 音乐页的键盘派发：把按键按 [ShortcutScope.music] 解析成动作并交给引擎。返回是否
/// 消费。纯逻辑（不依赖页面状态），单测直接喂按键。
bool dispatchMusicShortcut(ShortcutAction? action, MusicPlayerEngine engine) {
  switch (action) {
    case ShortcutAction.musicTogglePlayPause:
      if (!engine.isActive) return false;
      unawaited(engine.togglePlayPause());
      return true;
    case ShortcutAction.musicNextTrack:
      if (!engine.isActive) return false;
      unawaited(engine.skipNext());
      return true;
    case ShortcutAction.musicPreviousTrack:
      if (!engine.isActive) return false;
      unawaited(engine.skipPrevious());
      return true;
    case ShortcutAction.musicSeekForward:
      if (!engine.isActive) return false;
      unawaited(engine.seekRelative(const Duration(seconds: 5)));
      return true;
    case ShortcutAction.musicSeekBackward:
      if (!engine.isActive) return false;
      unawaited(engine.seekRelative(const Duration(seconds: -5)));
      return true;
    default:
      return false;
  }
}

/// 生效的来源过滤：指向的插件已不在（被停用 / 卸载）时回到全部来源（`null`）。
String? _musicEffectiveSourceFilter(
  String? filter,
  List<MusicPluginManifest> searchPlugins,
) {
  if (filter == null || filter == kMusicSearchLocalSource) return filter;
  return searchPlugins.any((MusicPluginManifest m) => m.id == filter)
      ? filter
      : null;
}

/// 按来源过滤后参与搜索的插件；[type] 非空时只留支持该类型的。[effectiveFilter] 取
/// [_musicEffectiveSourceFilter] 的结果。
List<MusicPluginManifest> _musicFilteredSources(
  String? effectiveFilter,
  List<MusicPluginManifest> searchPlugins, [
  MusicPluginSearchType? type,
]) {
  if (effectiveFilter == kMusicSearchLocalSource) {
    return const <MusicPluginManifest>[];
  }
  return <MusicPluginManifest>[
    for (final MusicPluginManifest m in searchPlugins)
      if ((type == null || m.searchTypes.contains(type.wire)) &&
          (effectiveFilter == null || m.id == effectiveFilter))
        m,
  ];
}

/// 来源过滤是否保留本地结果（全部来源 / 只看本地）。
bool _musicSearchIncludesLocal(String? effectiveFilter) =>
    effectiveFilter == null || effectiveFilter == kMusicSearchLocalSource;

/// 本地（含混排服务器专辑）按 [query] 筛出的条目。搜索走统一归一化
/// （[filterByMediaSearch]）：大小写 / 全半角 / 假名同口径。
MusicSearchLocalItems _musicLocalMatches(
  MusicLibrarySnapshot snap,
  List<MusicServerAlbumRef> serverAlbums,
  String query,
) => MusicSearchLocalItems(
  albums: filterByMediaSearch<MusicAlbumRow>(
    snap.albums,
    query,
    (MusicAlbumRow a) => <String>[a.title, ?a.albumArtistCredit],
  ),
  serverAlbums: filterByMediaSearch<MusicServerAlbumRef>(
    serverAlbums,
    query,
    (MusicServerAlbumRef a) => <String>[a.album.title, ?a.album.artist],
  ),
  artists: filterByMediaSearch<MusicArtistRow>(
    snap.artists,
    query,
    (MusicArtistRow a) => <String>[a.name],
  ),
  tracks: filterByMediaSearch<MusicTrackRow>(
    snap.tracks,
    query,
    (MusicTrackRow r) => <String>[r.title, ?r.artistCredit],
  ),
  playlists: filterByMediaSearch<MusicPlaylistRow>(
    snap.playlists,
    query,
    (MusicPlaylistRow p) => <String>[p.name],
  ),
  albumByUid: snap.albumByUid,
);

/// 二级搜索页要的曲库数据：曲库页数据变化（扫描完成 / 插件启停）时推给已打开的搜索页。
typedef _MusicSearchInputs = ({
  MusicLibrarySnapshot snapshot,
  List<MusicServerAlbumRef> serverAlbums,
  List<MusicPluginManifest> searchPlugins,
});

class MusicLibraryPage extends ConsumerStatefulWidget {
  const MusicLibraryPage({
    super.key,
    this.snapshotLoader,
    this.serverAlbumsLoader,
  });

  /// 测试注入：替代读数据库。
  final Future<MusicLibrarySnapshot> Function()? snapshotLoader;

  /// 测试注入：替代读「混排进曲库」的服务器专辑。
  final Future<List<MusicServerAlbumRef>> Function()? serverAlbumsLoader;

  @override
  ConsumerState<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends ConsumerState<MusicLibraryPage> {
  MusicLibrarySection _section = MusicLibrarySection.albums;

  /// 用户是否自己点过分区：没点过时，推荐页出现即默认落在推荐页。
  bool _sectionTouched = false;
  MusicLibrarySnapshot? _snapshot;

  /// 显式 opt-in 混排进曲库的服务器专辑（服务器曲库 P5）。与本地快照分开取：服务器慢或
  /// 不在线不拖住本地曲库。
  List<MusicServerAlbumRef> _serverAlbums = const <MusicServerAlbumRef>[];
  bool _scanning = false;
  StreamSubscription<Set<TableUpdate>>? _dbSub;

  /// 已启用、校验通过的插件音源（合规门没过的平台恒为空）。
  List<MusicPluginManifest> _pluginSources = const <MusicPluginManifest>[];

  List<MusicPluginManifest> _pluginsWith(MusicPluginCapability cap) =>
      <MusicPluginManifest>[
        for (final MusicPluginManifest m in _pluginSources)
          if (m.can(cap)) m,
      ];

  bool get _hasRecommend => _pluginsWith(MusicPluginCapability.home).isNotEmpty;

  /// 有搜索能力的插件（来源 chip 列它们）。
  List<MusicPluginManifest> get _searchPlugins =>
      _pluginsWith(MusicPluginCapability.search);

  /// 已打开的二级搜索页读这里；曲库数据变化时经 [_publishSearchInputs] 推新值。
  final ValueNotifier<_MusicSearchInputs> _searchInputs =
      ValueNotifier<_MusicSearchInputs>((
        snapshot: MusicLibrarySnapshot.empty,
        serverAlbums: const <MusicServerAlbumRef>[],
        searchPlugins: const <MusicPluginManifest>[],
      ));

  void _publishSearchInputs() {
    _searchInputs.value = (
      snapshot: _snapshot ?? MusicLibrarySnapshot.empty,
      serverAlbums: _serverAlbums,
      searchPlugins: _searchPlugins,
    );
  }

  /// 右上角搜索按钮：推入二级搜索页（首页只负责浏览，不做就地搜索）。查询词只活在那一页里，返回后曲库页原样。
  Future<void> _openSearchPage() async {
    _publishSearchInputs();
    // 插件可能刚在设置里装上 / 启用：搜索页打开时顺手重读，读完经 notifier 推过去。
    unawaited(_reloadOnlineSources());
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => _MusicLibrarySearchPage(
          inputs: _searchInputs,
          localActions: _localActions,
        ),
      ),
    );
  }

  /// 最近播放的那首（播放事件流最新一条）；null = 没听过 / 测试注入快照。
  MusicTrackRow? _lastPlayed;

  AppModel get _app => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
    unawaited(_reloadServerAlbums());
    unawaited(_reloadOnlineSources());
    if (widget.snapshotLoader == null && _app.isDatabaseReady) {
      final FushiDatabase db = _app.database;
      // 表级变更流（不是 drift .watch()：长驻页面订阅 watch 会在 dispose 时挂死测试）。
      _dbSub = db
          .tableUpdates(
            TableUpdateQuery.onAllTables(
              <ResultSetImplementation<Object?, Object?>>[
                db.musicTracks,
                db.musicAlbums,
                db.musicPlaylists,
                db.musicDiscSources,
                db.musicPlayEvents,
              ],
            ),
          )
          .listen((_) => unawaited(_reload()));
    }
  }

  @override
  void dispose() {
    unawaited(_dbSub?.cancel());
    _searchInputs.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final Future<MusicLibrarySnapshot> Function()? loader =
        widget.snapshotLoader;
    final MusicLibrarySnapshot snap = loader != null
        ? await loader()
        : (_app.isDatabaseReady
              ? await MusicLibrarySnapshot.load(_app.database)
              : MusicLibrarySnapshot.empty);
    final List<MusicTrackRow> recent = loader == null && _app.isDatabaseReady
        ? await _app.database.listRecentlyPlayedMusicTracks(limit: 1)
        : const <MusicTrackRow>[];
    if (!mounted) return;
    setState(() {
      _snapshot = snap;
      _lastPlayed = recent.isEmpty ? null : recent.first;
    });
    _publishSearchInputs();
  }

  /// 「继续收听」：从上次那首所在专辑、那一首起播（引擎不持久化播放位置，曲内
  /// 从头开始）；散曲只播它自己。
  void _continueListening(MusicTrackRow track, MusicLibrarySnapshot snap) {
    final MusicAlbumRow? album = track.albumUid == null
        ? null
        : snap.albumByUid[track.albumUid];
    final List<MusicTrackRow> tracks = album == null
        ? <MusicTrackRow>[track]
        : snap.tracksOfAlbum(album.albumUid);
    final int start = tracks.indexWhere(
      (MusicTrackRow t) => t.trackUid == track.trackUid,
    );
    unawaited(
      _app.musicSession.engine.playQueue(
        <MusicPlayItem>[
          for (final MusicTrackRow t in tracks)
            musicPlayItemOf(t, album: album),
        ],
        startIndex: start < 0 ? 0 : start,
        context: album == null
            ? MusicQueueContext.mixed
            : MusicQueueContext.album,
      ),
    );
  }

  /// 曲库顶部「继续收听」卡：与书架 / 视频 / 游戏同一张 [FushiContinueHero]。
  /// 点按 = 续播，长按 / 右键 = 打开专辑（卡上不放按钮）。
  Widget? _buildContinueHero(MusicLibrarySnapshot snap) {
    final MusicTrackRow? track = _lastPlayed;
    if (track == null) return null;
    final MusicAlbumRow? album = track.albumUid == null
        ? null
        : snap.albumByUid[track.albumUid];
    final Widget cover = MusicCover(
      coverPath: album?.coverPath,
      embeddedFromPath: album == null
          ? track.path
          : snap.embeddedCoverPathOf(album),
    );
    return FushiContinueHero(
      cardKey: const ValueKey<String>('music-continue-hero'),
      focusId: const FushiFocusId('music-continue-hero'),
      cover: cover,
      coverAspectRatio: 1,
      eyebrow: t.music_continue_listening,
      title: album?.title ?? track.title,
      metaLines: <String>[
        <String>[
          if (album != null) track.title,
          if ((track.artistCredit ?? album?.albumArtistCredit) != null)
            (track.artistCredit ?? album!.albumArtistCredit)!,
        ].join(' · '),
      ],
      onOpen: () => _continueListening(track, snap),
      onLongPress: album == null ? null : () => _openAlbum(album),
    );
  }

  Future<void> _reloadServerAlbums() async {
    final Future<List<MusicServerAlbumRef>> Function()? loader =
        widget.serverAlbumsLoader;
    final List<MusicServerAlbumRef> albums = loader != null
        ? await loader()
        : (_app.isDatabaseReady
              ? await loadMixedServerAlbums(_app)
              : const <MusicServerAlbumRef>[]);
    if (!mounted) return;
    setState(() => _serverAlbums = albums);
    _publishSearchInputs();
  }

  Future<void> _openServers() async {
    await openMusicServerList(context);
    // 设置页可能改了混排开关 / 服务器清单。
    await _reloadServerAlbums();
  }

  Future<void> _addFolder() async {
    final String? path = await pickRealDirectoryPath(
      context: context,
      appModel: _app,
      dialogTitle: t.music_folder_add,
    );
    if (path == null || !mounted) return;
    setState(() => _scanning = true);
    try {
      final AddLocalFolderResult result = await addLocalFolderAsSource(
        db: _app.database,
        mediaKind: SourceLibraryKind.music.dbValue,
        path: path,
      );
      if (result.outcome == AddLocalFolderOutcome.duplicate) {
        FushiToast.show(msg: t.music_folder_duplicate);
      } else {
        await _reportScan();
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    await _reload();
  }

  Future<void> _rescan() async {
    setState(() => _scanning = true);
    try {
      final SourceLibraryScanner scanner = SourceLibraryScanner(_app.database);
      String? error;
      for (final MediaSourceRow source
          in await _app.database.getMediaSourcesByKind(
            SourceLibraryKind.music.dbValue,
          )) {
        final SourceScanSummary summary = await scanner.scan(source);
        error ??= summary.error;
      }
      if (error != null) {
        FushiToast.show(msg: t.music_scan_failed(error: error));
      } else {
        await _reportScan();
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    await _reload();
  }

  Future<void> _addDisc() async {
    setState(() => _scanning = true);
    try {
      await pickAndAddMusicDiscs(context: context, app: _app);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    await _reload();
  }

  Future<void> _readCd() async {
    setState(() => _scanning = true);
    try {
      await readAudioCdIntoLibrary(context: context, app: _app);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    await _reload();
  }

  Future<void> _reportScan() async {
    final int count = (await _app.database.listMusicTracks()).length;
    FushiToast.show(msg: t.music_scan_done(count: count));
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final Set<ModifierKey> modifiers = <ModifierKey>{
      if (HardwareKeyboard.instance.isControlPressed) ModifierKey.ctrl,
      if (HardwareKeyboard.instance.isShiftPressed) ModifierKey.shift,
      if (HardwareKeyboard.instance.isAltPressed) ModifierKey.alt,
      if (HardwareKeyboard.instance.isMetaPressed) ModifierKey.meta,
    };
    final ShortcutAction? action = _app.shortcutRegistry.resolveKeyboard(
      event.logicalKey,
      modifiers: modifiers,
      scope: ShortcutScope.music,
    );
    return dispatchMusicShortcut(action, _app.musicSession.engine)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  void _openAlbum(MusicAlbumRow album) {
    final MusicLibrarySnapshot snap = _snapshot ?? MusicLibrarySnapshot.empty;
    unawaited(
      Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => MusicAlbumPage(
            album: album,
            tracks: snap.tracksOfAlbum(album.albumUid),
            embeddedCoverPath: snap.embeddedCoverPathOf(album),
            disc: snap.discOf(album),
          ),
        ),
      ),
    );
  }

  Future<void> _openArtist(MusicArtistRow artist) async {
    final List<MusicTrackRow> tracks = await _app.database
        .listMusicTracksByArtist(artist.artistUid);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => MusicTrackListPage(
          title: artist.name,
          tracks: tracks,
          albums: (_snapshot ?? MusicLibrarySnapshot.empty).albumByUid,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MusicLibrarySnapshot? snap = _snapshot;
    // 首页的悬浮条宿主不给各 tab 加底部留白（会截短别的 tab 的列表），音乐页自己让位。
    return MusicBarReserve(
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: _handleKey,
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  tokens.spacing.gap,
                  tokens.spacing.page,
                  tokens.spacing.gap,
                ),
                child: FushiFloatingTopBar(
                  title: t.nav_music,
                  actions: <List<FushiToolbarItem>>[
                    // 搜索排最前：放不下时最后才收进「⋯」。
                    <FushiToolbarItem>[
                      FushiToolbarItem(
                        key: const ValueKey<String>('music_open_search'),
                        icon: FushiIcons.search,
                        label: t.music_library_search_hint,
                        onPressed: () => unawaited(_openSearchPage()),
                      ),
                    ],
                    <FushiToolbarItem>[
                      FushiToolbarItem(
                        key: const ValueKey<String>('music_add_folder'),
                        icon: FushiIcons.libraryAdd,
                        label: t.music_folder_add,
                        onPressed: _scanning
                            ? null
                            : () => unawaited(_addFolder()),
                      ),
                      FushiToolbarItem(
                        key: const ValueKey<String>('music_add_disc'),
                        icon: FushiIcons.storage,
                        label: t.music_disc_add,
                        onPressed: _scanning
                            ? null
                            : () => unawaited(_addDisc()),
                      ),
                      if (musicAudioCdSupported())
                        FushiToolbarItem(
                          key: const ValueKey<String>('music_read_cd'),
                          icon: FushiIcons.audio,
                          label: t.music_cd_read,
                          onPressed: _scanning
                              ? null
                              : () => unawaited(_readCd()),
                        ),
                      FushiToolbarItem(
                        key: const ValueKey<String>('music_servers'),
                        icon: FushiIcons.cloud,
                        label: t.music_servers_title,
                        onPressed: () => unawaited(_openServers()),
                      ),
                      FushiToolbarItem(
                        key: const ValueKey<String>('music_rescan'),
                        icon: FushiIcons.refresh,
                        label: t.music_library_rescan,
                        onPressed: _scanning
                            ? null
                            : () => unawaited(_rescan()),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
                // 桌面端默认 dragDevices 不含鼠标：分段放不下时鼠标也得拖得动。
                child: HorizontalDragScrollable(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: adaptiveSegmentedButton<MusicLibrarySection>(
                      context: context,
                      segments: <ButtonSegment<MusicLibrarySection>>[
                        for (final MusicLibrarySection s
                            in MusicLibrarySection.values)
                          if (s != MusicLibrarySection.recommend ||
                              _hasRecommend)
                            ButtonSegment<MusicLibrarySection>(
                              value: s,
                              label: Text(musicLibrarySectionLabel(s)),
                            ),
                      ],
                      selected: <MusicLibrarySection>{_section},
                      onSelectionChanged: (Set<MusicLibrarySection> v) =>
                          setState(() {
                            _sectionTouched = true;
                            _section = v.first;
                          }),
                    ),
                  ),
                ),
              ),
              SizedBox(height: tokens.spacing.gap),
              if (snap == null ? null : _buildContinueHero(snap)
                  case final Widget hero)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    tokens.spacing.page,
                    0,
                    tokens.spacing.page,
                    tokens.spacing.gap * 1.5,
                  ),
                  child: hero,
                ),
              // 常规同步 / 复习同步在跑时的进度条（全局状态，不只本页触发的）；没在跑时零高度。
              SyncProgressBanner(
                key: const ValueKey<String>('music-sync-progress'),
                margin: EdgeInsets.only(bottom: tokens.spacing.gap),
              ),
              if (_scanning) const FushiLinearProgressIndicator(),
              Expanded(
                child: snap == null
                    ? const FushiLoadingView()
                    : AnimatedSwitcher(
                        duration: fushiMotionDuration(
                          context,
                          FushiMotion.medium,
                        ),
                        child: KeyedSubtree(
                          key: ValueKey<MusicLibrarySection>(_section),
                          child: _buildSection(context, snap),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _reloadOnlineSources() async {
    if (widget.snapshotLoader != null || !isMusicPluginSourcesAvailable) {
      return;
    }
    final List<InstalledMusicPlugin> all = await _app.musicPluginManager.list();
    if (!mounted) return;
    setState(() {
      _pluginSources = <MusicPluginManifest>[
        for (final InstalledMusicPlugin p in all)
          if (p.usable) p.info!.manifest,
      ];
      if (_hasRecommend && !_sectionTouched) {
        _section = MusicLibrarySection.recommend;
      } else if (!_hasRecommend && _section == MusicLibrarySection.recommend) {
        _section = MusicLibrarySection.albums;
      }
    });
    _publishSearchInputs();
  }

  /// 统一搜索里本地条目的卡片与跳转（本地专辑卡带光盘菜单 / 格式徽章，复用曲库网格的）。
  MusicSearchLocalActions _localActions(MusicLibrarySnapshot snap) =>
      MusicSearchLocalActions(
        albumCard: (BuildContext context, MusicAlbumRow album) => _AlbumCard(
          key: ValueKey<String>('music-album-${album.albumUid}'),
          album: album,
          tracks: snap.tracksOfAlbum(album.albumUid),
          embeddedCoverPath: snap.embeddedCoverPathOf(album),
          disc: snap.discOf(album),
          onTap: () => _openAlbum(album),
        ),
        openAlbum: _openAlbum,
        openArtist: (MusicArtistRow a) => unawaited(_openArtist(a)),
      );

  Widget _buildSection(BuildContext context, MusicLibrarySnapshot snap) {
    if (_section == MusicLibrarySection.recommend) {
      return MusicPluginRecommendView(
        sources: _pluginsWith(MusicPluginCapability.home),
      );
    }
    final List<MusicPluginManifest> accountLists = _pluginsWith(
      MusicPluginCapability.library,
    );
    final bool accountPlaylists =
        _section == MusicLibrarySection.playlists && accountLists.isNotEmpty;
    if (snap.isEmpty &&
        _serverAlbums.isEmpty &&
        !accountPlaylists &&
        _section != MusicLibrarySection.works) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.music,
          message: t.music_library_empty,
          detail: t.music_library_empty_hint,
          action: FushiFilledButton.icon(
            key: const ValueKey<String>('music_empty_add_folder'),
            onPressed: _scanning ? null : () => unawaited(_addFolder()),
            icon: const FushiIcon(FushiIcons.libraryAdd),
            label: Text(t.music_folder_add),
          ),
        ),
      );
    }
    if (accountPlaylists) {
      return _playlistsWithAccounts(context, accountLists, snap.playlists);
    }
    return _localSection(context, _section, snap);
  }

  /// 本地（含混排服务器专辑）分区内容。
  Widget _localSection(
    BuildContext context,
    MusicLibrarySection section,
    MusicLibrarySnapshot snap,
  ) {
    return switch (section) {
      MusicLibrarySection.albums => _AlbumGrid(
        snapshot: snap,
        albums: snap.albums,
        serverAlbums: _serverAlbums,
        onOpen: _openAlbum,
      ),
      MusicLibrarySection.artists => _ArtistList(
        artists: snap.artists,
        onOpen: (MusicArtistRow a) => unawaited(_openArtist(a)),
      ),
      MusicLibrarySection.songs ||
      MusicLibrarySection.recommend => MusicTrackList(
        tracks: snap.tracks,
        albums: snap.albumByUid,
        context: MusicQueueContext.mixed,
      ),
      MusicLibrarySection.works => Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.music,
          message: t.music_section_works,
          detail: t.music_works_empty,
        ),
      ),
      MusicLibrarySection.playlists =>
        snap.playlists.isEmpty
            ? Center(
                child: FushiPlaceholderMessage(
                  icon: FushiIcons.playlist,
                  message: t.music_playlists_empty,
                ),
              )
            : _PlaylistList(playlists: snap.playlists),
    };
  }

  Widget _groupTitle(BuildContext context, String text) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(
        top: tokens.spacing.section,
        bottom: tokens.spacing.gap,
      ),
      child: Text(text, style: context.fushiType.titleMedium),
    );
  }

  /// 歌单页签：先列已登录账号的歌单（每个声明 `library` 的插件一段），再列本地歌单。
  Widget _playlistsWithAccounts(
    BuildContext context,
    List<MusicPluginManifest> accounts,
    List<MusicPlaylistRow> local,
  ) {
    final List<Widget> blocks = <Widget>[
      for (final MusicPluginManifest m in accounts)
        MusicPluginLibrarySection(
          key: ValueKey<String>('music-plugin-library-${m.id}'),
          manifest: m,
        ),
      _groupTitle(context, t.music_playlists_local),
      if (local.isEmpty)
        Text(t.music_playlists_empty, style: context.fushiType.bodySmall)
      else
        _PlaylistList(playlists: local, shrinkWrap: true),
    ];
    return FushiEntranceScope(
      child: ListView.builder(
        key: const ValueKey<String>('music-library-playlists-accounts'),
        padding: musicBrowsePagePadding(context),
        itemCount: blocks.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int i) => blocks[i],
        ),
      ),
    );
  }
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({
    required this.snapshot,
    required this.albums,
    required this.onOpen,
    this.serverAlbums = const <MusicServerAlbumRef>[],
  });

  final MusicLibrarySnapshot snapshot;

  /// 本地专辑（[snapshot] 用来取各专辑的曲目）。
  final List<MusicAlbumRow> albums;
  final ValueChanged<MusicAlbumRow> onOpen;

  /// 混排进来的服务器专辑：排在本地专辑之后，卡片带云朵、点开走服务器专辑页。
  final List<MusicServerAlbumRef> serverAlbums;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 专辑一律是方形「唱片」材质（用户 2026-10-26 拍板）；行高按新卡算
    // （[musicAlbumGridDelegate]：方形封面 + ShelfCardMeta 文字块）。
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
                    tokens.spacing.gap,
                    tokens.spacing.page,
                    tokens.spacing.section,
                  ),
                ),
                gridDelegate: musicAlbumGridDelegate(
                  context,
                  constraints.maxWidth,
                ),
                itemCount: albums.length + serverAlbums.length,
                itemBuilder: fushiStaggeredItemBuilder((
                  BuildContext context,
                  int i,
                ) {
                  if (i >= albums.length) {
                    final MusicServerAlbumRef ref =
                        serverAlbums[i - albums.length];
                    return MusicServerAlbumCard(
                      key: ValueKey<String>(
                        'music-server-album-${ref.browser.serverId}-${ref.album.id}',
                      ),
                      browser: ref.browser,
                      album: ref.album,
                    );
                  }
                  final MusicAlbumRow album = albums[i];
                  return _AlbumCard(
                    key: ValueKey<String>('music-album-${album.albumUid}'),
                    album: album,
                    tracks: snapshot.tracksOfAlbum(album.albumUid),
                    embeddedCoverPath: snapshot.embeddedCoverPathOf(album),
                    disc: snapshot.discOf(album),
                    onTap: () => onOpen(album),
                  );
                }),
              ),
        ),
      ),
    );
  }
}

class _AlbumCard extends ConsumerWidget {
  const _AlbumCard({
    super.key,
    required this.album,
    required this.tracks,
    required this.embeddedCoverPath,
    required this.onTap,
    this.disc,
  });

  final MusicAlbumRow album;
  final List<MusicTrackRow> tracks;
  final String? embeddedCoverPath;
  final VoidCallback onTap;

  /// 光盘来源：盘是一张带 `DVD` / `BD` 角标的专辑，右键 / 长按菜单里有「章节导入为曲目」
  /// （§9.2）。
  final MusicDiscSourceRow? disc;

  void _showDiscMenu(BuildContext context, WidgetRef ref, Offset position) {
    final MusicDiscSourceRow? d = disc;
    if (d == null) return;
    unawaited(
      showMusicDiscAlbumMenu(
        context: context,
        app: ref.read(appProvider),
        globalPosition: position,
        album: album,
        disc: d,
        tracks: tracks,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MusicDiscSourceRow? disc = this.disc;
    final MusicTrackRow? first = tracks.isEmpty ? null : tracks.first;
    final String badge = first == null
        ? ''
        : musicFormatBadge(
            codec: first.codec,
            isLossless: first.isLossless,
            sampleRate: first.sampleRate,
            bitDepth: first.bitDepth,
            bitrateKbps: first.bitrate,
          );
    // 方形「唱片」材质卡（材质由网格外的 Scope 给）：封面上不压角标（用户
    // 2026-10-25），光盘规格徽标（CD / DVD / BD）进副行尾部，与视频库原盘卡同位。
    final Widget card = FushiHoverLift(
      scale: kMusicHoverLiftScale,
      builder: (BuildContext context, bool _) => shelfCoverCard(
        onTap: onTap,
        onLongPress: disc == null
            ? null
            : () {
                final RenderObject? box = context.findRenderObject();
                if (box is! RenderBox) return;
                _showDiscMenu(
                  context,
                  ref,
                  box.localToGlobal(box.size.center(Offset.zero)),
                );
              },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AspectRatio(
              aspectRatio: kShelfAlbumAspectRatio,
              child: ShelfCoverFrame(
                child: MusicCover(
                  coverPath: album.coverPath,
                  embeddedFromPath: embeddedCoverPath,
                ),
              ),
            ),
            ShelfCardMeta(
              key: ValueKey<String>('music-album-meta-${album.albumUid}'),
              title: album.title,
              subtitle: <String>[
                album.albumArtistCredit ?? t.music_artist_unknown,
                if (badge.isNotEmpty) badge,
                if (disc != null && tracks.isEmpty) t.music_disc_not_imported,
              ].join(' · '),
              trailing: disc == null
                  ? null
                  : IgnorePointer(child: MusicDiscBadge(disc: disc)),
            ),
          ],
        ),
      ),
    );
    if (disc == null) return card;
    // 右键菜单由绑定表决定唤出键（默认右键），右键被别的动作占用时自动让位。
    return ContextMenuTrigger(
      onInvoke: (Offset position) => _showDiscMenu(context, ref, position),
      child: card,
    );
  }
}

class _ArtistList extends StatelessWidget {
  const _ArtistList({required this.artists, required this.onOpen});

  final List<MusicArtistRow> artists;
  final ValueChanged<MusicArtistRow> onOpen;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiEntranceScope(
      child: ListView.builder(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.gap,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        itemCount: artists.length,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          final MusicArtistRow artist = artists[i];
          return FushiPressScale(
            child: FushiGroupedListItem(
              key: ValueKey<String>('music-artist-${artist.artistUid}'),
              index: i,
              count: artists.length,
              onTap: () => onOpen(artist),
              child: FushiListItem(
                leading: const FushiListLeadingIcon(FushiIcons.person),
                title: Text(artist.name),
                trailing: const FushiIcon(FushiIcons.chevronRight),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _PlaylistList extends StatelessWidget {
  const _PlaylistList({required this.playlists, this.shrinkWrap = false});

  final List<MusicPlaylistRow> playlists;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiEntranceScope(
      child: ListView.builder(
        shrinkWrap: shrinkWrap,
        primary: shrinkWrap ? false : null,
        physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
        padding: shrinkWrap
            ? EdgeInsets.zero
            : withBottomSafeInset(
                context,
                EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  tokens.spacing.gap,
                  tokens.spacing.page,
                  tokens.spacing.section,
                ),
              ),
        itemCount: playlists.length,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          final MusicPlaylistRow p = playlists[i];
          return FushiPressScale(
            child: FushiGroupedListItem(
              key: ValueKey<String>('music-playlist-${p.playlistUid}'),
              index: i,
              count: playlists.length,
              child: FushiListItem(
                leading: const FushiListLeadingIcon(FushiIcons.playlist),
                title: Text(p.name),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// 二级搜索页（宽窄屏同一套，曲库页右上角搜索按钮推入）：顶栏是带返回的搜索框（自动聚焦），正文是统一搜索的综合结果，段标题
/// 「全部」再推一层该类型的完整结果。查询词 / 来源过滤只活在本页，返回即丢，曲库页原样。
///
/// 键盘 / 手柄：回车立即提交（[FushiSearchBar.onSubmitted] 跳过防抖）；Esc 先清空，
/// 已空时不消费，交给全局「返回上一级」退出本页。
class _MusicLibrarySearchPage extends StatefulWidget {
  const _MusicLibrarySearchPage({
    required this.inputs,
    required this.localActions,
  });

  /// 曲库页持有的数据（快照 / 混排服务器专辑 / 搜索插件），变化时推过来。
  final ValueListenable<_MusicSearchInputs> inputs;

  /// 本地条目的卡片与跳转（本地专辑卡住在曲库页）。
  final MusicSearchLocalActions Function(MusicLibrarySnapshot snap)
  localActions;

  @override
  State<_MusicLibrarySearchPage> createState() =>
      _MusicLibrarySearchPageState();
}

class _MusicLibrarySearchPageState extends State<_MusicLibrarySearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode(debugLabel: 'music-search-page');
  String _query = '';

  /// 同曲库页：`null` = 全部来源，[kMusicSearchLocalSource] = 只看本地，其余为插件 id。
  String? _sourceFilter;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 「全部」：推入该类型的完整结果（本地在前、各插件分页接在后面）。
  void _openType(MusicPluginSearchType type) {
    final String query = _query;
    final String? filter = _sourceFilter;
    unawaited(
      Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (BuildContext context) =>
              ValueListenableBuilder<_MusicSearchInputs>(
                valueListenable: widget.inputs,
                builder:
                    (
                      BuildContext context,
                      _MusicSearchInputs inputs,
                      Widget? _,
                    ) {
                      final String? effective = _musicEffectiveSourceFilter(
                        filter,
                        inputs.searchPlugins,
                      );
                      return musicBrowseScaffold(
                        context,
                        title: musicLibrarySectionLabel(switch (type) {
                          MusicPluginSearchType.song =>
                            MusicLibrarySection.songs,
                          MusicPluginSearchType.album =>
                            MusicLibrarySection.albums,
                          MusicPluginSearchType.artist =>
                            MusicLibrarySection.artists,
                          MusicPluginSearchType.playlist =>
                            MusicLibrarySection.playlists,
                        }),
                        body: MusicSearchResultsView(
                          key: ValueKey<String>(
                            'music-search-page-${type.wire}',
                          ),
                          type: type,
                          query: query,
                          sources: _musicFilteredSources(
                            effective,
                            inputs.searchPlugins,
                            type,
                          ),
                          local: _musicSearchIncludesLocal(effective)
                              ? _musicLocalMatches(
                                  inputs.snapshot,
                                  inputs.serverAlbums,
                                  query,
                                )
                              : MusicSearchLocalItems.none,
                          localActions: widget.localActions(inputs.snapshot),
                        ),
                      );
                    },
              ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, List<MusicPluginManifest> plugins) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool searching = _query.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiSearchBar(
            fieldKey: const ValueKey<String>('music-search-page-field'),
            clearButtonKey: const ValueKey<String>('music-search-page-clear'),
            focusId: const FushiFocusId('music-search-page-field'),
            controller: _controller,
            focusNode: _focusNode,
            hintText: t.music_library_search_hint,
            autofocus: true,
            onBack: () => unawaited(Navigator.of(context).maybePop()),
            onQueryChanged: (String q) => setState(() => _query = q),
            onSubmitted: (String q) => setState(() => _query = q),
            onClear: () => setState(() => _query = ''),
          ),
          // 来源过滤：同曲库页，只在有搜索词且有在线源时出现。
          if (searching && plugins.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: tokens.spacing.gap),
              child: MusicSearchSourceChips(
                key: const ValueKey<String>('music-search-page-sources'),
                sources: plugins,
                selected: _musicEffectiveSourceFilter(_sourceFilter, plugins),
                onSelected: (String? v) => setState(() => _sourceFilter = v),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, _MusicSearchInputs inputs) {
    final String query = _query;
    if (query.trim().isEmpty) {
      return Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: Center(
          child: FushiPlaceholderMessage(
            icon: FushiIcons.search,
            message: t.music_library_search_hint,
          ),
        ),
      );
    }
    final String? effective = _musicEffectiveSourceFilter(
      _sourceFilter,
      inputs.searchPlugins,
    );
    return MusicSearchOverview(
      key: const ValueKey<String>('music-search-page-overview'),
      query: query,
      sources: _musicFilteredSources(effective, inputs.searchPlugins),
      local: _musicSearchIncludesLocal(effective)
          ? _musicLocalMatches(inputs.snapshot, inputs.serverAlbums, query)
          : MusicSearchLocalItems.none,
      localActions: widget.localActions(inputs.snapshot),
      onSeeAll: _openType,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_MusicSearchInputs>(
      valueListenable: widget.inputs,
      builder: (BuildContext context, _MusicSearchInputs inputs, Widget? _) {
        return MusicFloatingBarHost(
          child: FushiPageScaffold(
            title: t.music_library_search_hint,
            header: _header(context, inputs.searchPlugins),
            body: AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.medium),
              child: KeyedSubtree(
                key: ValueKey<bool>(_query.trim().isEmpty),
                child: _body(context, inputs),
              ),
            ),
          ),
        );
      },
    );
  }
}
