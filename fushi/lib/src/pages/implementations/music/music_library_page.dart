/// 音乐库页（设计 §11.2）：分区 专辑 · 艺人 · 歌曲 · 作品 · 歌单。不做统计概况卡（D9）。
/// 「作品」分区的数据来自作品图谱（docs/specs/2026-10-24-cross-media-links.md），P0 先空态。
library;

import 'dart:async';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdate, TableUpdateQuery;
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi_core/fushi_core.dart';

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
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
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
enum MusicLibrarySection { albums, artists, songs, works, playlists }

String musicLibrarySectionLabel(MusicLibrarySection s) => switch (s) {
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
  MusicLibrarySnapshot? _snapshot;

  /// 显式 opt-in 混排进曲库的服务器专辑（服务器曲库 P5）。与本地快照分开取：服务器慢或
  /// 不在线不拖住本地曲库。
  List<MusicServerAlbumRef> _serverAlbums = const <MusicServerAlbumRef>[];
  bool _scanning = false;
  StreamSubscription<Set<TableUpdate>>? _dbSub;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  /// 最近播放的那首（播放事件流最新一条）；null = 没听过 / 测试注入快照。
  MusicTrackRow? _lastPlayed;

  AppModel get _app => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
    unawaited(_reloadServerAlbums());
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
    _searchController.dispose();
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
    if (track == null || _query.isNotEmpty) return null;
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
    return Focus(
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
                      onPressed: _scanning ? null : () => unawaited(_addDisc()),
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
                      onPressed: _scanning ? null : () => unawaited(_rescan()),
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
                        ButtonSegment<MusicLibrarySection>(
                          value: s,
                          label: Text(musicLibrarySectionLabel(s)),
                        ),
                    ],
                    selected: <MusicLibrarySection>{_section},
                    onSelectionChanged: (Set<MusicLibrarySection> v) =>
                        setState(() => _section = v.first),
                  ),
                ),
              ),
            ),
            // 每个分区都保留搜索框槽位（作品分区无可筛内容，输入无副作用），切页签头部不跳动；查询词跨分区保留。
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.gap,
                tokens.spacing.page,
                0,
              ),
              // 与库页工具行同一形态：宽屏搜索框限宽靠左，窄屏撑满。
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: FushiSearchBar(
                    fieldKey: const ValueKey<String>('music-library-search'),
                    clearButtonKey: const ValueKey<String>(
                      'music-library-search-clear',
                    ),
                    controller: _searchController,
                    hintText: t.music_library_search_hint,
                    onQueryChanged: (String q) => setState(() => _query = q),
                    onClear: () => setState(() => _query = ''),
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
    );
  }

  Widget _buildSection(BuildContext context, MusicLibrarySnapshot snap) {
    if (snap.isEmpty &&
        _serverAlbums.isEmpty &&
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
    // 搜索走统一归一化（[filterByMediaSearch]）：大小写 / 全半角 / 假名同口径。
    final List<MusicAlbumRow> albums = filterByMediaSearch<MusicAlbumRow>(
      snap.albums,
      _query,
      (MusicAlbumRow a) => <String>[a.title, ?a.albumArtistCredit],
    );
    final List<MusicServerAlbumRef> serverAlbums =
        filterByMediaSearch<MusicServerAlbumRef>(
          _serverAlbums,
          _query,
          (MusicServerAlbumRef a) => <String>[a.album.title, ?a.album.artist],
        );
    final List<MusicArtistRow> artists = filterByMediaSearch<MusicArtistRow>(
      snap.artists,
      _query,
      (MusicArtistRow a) => <String>[a.name],
    );
    final List<MusicTrackRow> tracks = filterByMediaSearch<MusicTrackRow>(
      snap.tracks,
      _query,
      (MusicTrackRow r) => <String>[r.title, ?r.artistCredit],
    );
    final List<MusicPlaylistRow> playlists =
        filterByMediaSearch<MusicPlaylistRow>(
          snap.playlists,
          _query,
          (MusicPlaylistRow p) => <String>[p.name],
        );
    final bool noMatch =
        _query.trim().isNotEmpty &&
        switch (_section) {
          MusicLibrarySection.albums => albums.isEmpty && serverAlbums.isEmpty,
          MusicLibrarySection.artists => artists.isEmpty,
          MusicLibrarySection.songs => tracks.isEmpty,
          MusicLibrarySection.playlists => playlists.isEmpty,
          MusicLibrarySection.works => false,
        };
    if (noMatch) {
      return Center(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.search,
          message: t.music_library_search_empty,
        ),
      );
    }
    return switch (_section) {
      MusicLibrarySection.albums => _AlbumGrid(
        snapshot: snap,
        albums: albums,
        serverAlbums: serverAlbums,
        onOpen: _openAlbum,
      ),
      MusicLibrarySection.artists => _ArtistList(
        artists: artists,
        onOpen: (MusicArtistRow a) => unawaited(_openArtist(a)),
      ),
      MusicLibrarySection.songs => MusicTrackList(
        tracks: tracks,
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
            : _PlaylistList(playlists: playlists),
    };
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

  /// 已按搜索词筛过的本地专辑（[snapshot] 仍用来取各专辑的曲目）。
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
  const _PlaylistList({required this.playlists});

  final List<MusicPlaylistRow> playlists;

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
