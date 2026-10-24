/// 音乐库页（设计 §11.2）：分区 专辑 · 艺人 · 歌曲 · 作品 · 歌单。不做统计概况卡（D9）。
/// 「作品」分区的数据来自作品图谱（docs/specs/2026-10-24-cross-media-links.md），P0 先空态。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdate, TableUpdateQuery;
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/music/lyrics/music_lyrics_coverage_index.dart';
import 'package:fushi/src/media/music/music_format_badge.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_album_page.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
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
  const MusicLibraryPage({super.key, this.snapshotLoader});

  /// 测试注入：替代读数据库。
  final Future<MusicLibrarySnapshot> Function()? snapshotLoader;

  @override
  ConsumerState<MusicLibraryPage> createState() => _MusicLibraryPageState();
}

class _MusicLibraryPageState extends ConsumerState<MusicLibraryPage> {
  MusicLibrarySection _section = MusicLibrarySection.albums;
  MusicLibrarySnapshot? _snapshot;
  bool _scanning = false;
  StreamSubscription<Set<TableUpdate>>? _dbSub;

  /// 「歌曲」分区的排序（按歌词生词覆盖率，设计 §12）。
  MusicTrackSort _sort = MusicTrackSort.library;
  Map<String, MusicTrackDifficulty> _difficulty =
      const <String, MusicTrackDifficulty>{};
  MusicCoverageRunResult? _coverageResult;

  AppModel get _app => ref.read(appProvider);
  MusicLyricsCoverageIndex get _coverage =>
      ref.read(musicLyricsCoverageIndexProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
    if (_app.isPreferencesReady) {
      _sort = MusicTrackSort.parse(_app.prefsRepo.musicTrackSort);
    }
    if (_sort.byDifficulty) unawaited(_runCoverage());
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
              ],
            ),
          )
          .listen((_) => unawaited(_reload()));
    }
  }

  @override
  void dispose() {
    unawaited(_dbSub?.cancel());
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
    if (!mounted) return;
    setState(() => _snapshot = snap);
  }

  /// 先把已落库的难度显示出来，再增量计算（没变的曲目不重算），算完重读。
  Future<void> _runCoverage({bool force = false}) async {
    final MusicLyricsCoverageIndex index = _coverage;
    final Map<String, MusicTrackDifficulty> cached = await index
        .loadDifficulty();
    if (!mounted) return;
    setState(() => _difficulty = cached);
    final MusicCoverageRunResult result = await index.run(force: force);
    final Map<String, MusicTrackDifficulty> fresh = await index
        .loadDifficulty();
    if (!mounted) return;
    setState(() {
      _coverageResult = result;
      _difficulty = fresh;
    });
  }

  void _setSort(MusicTrackSort sort) {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    if (_app.isPreferencesReady) {
      unawaited(_app.prefsRepo.setMusicTrackSort(sort.prefValue));
    }
    if (sort.byDifficulty) unawaited(_runCoverage());
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
            SizedBox(height: tokens.spacing.gap),
            if (_scanning) const LinearProgressIndicator(),
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
    if (snap.isEmpty && _section != MusicLibrarySection.works) {
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
    return switch (_section) {
      MusicLibrarySection.albums => _AlbumGrid(
        snapshot: snap,
        onOpen: _openAlbum,
      ),
      MusicLibrarySection.artists => _ArtistList(
        artists: snap.artists,
        onOpen: (MusicArtistRow a) => unawaited(_openArtist(a)),
      ),
      MusicLibrarySection.songs => _buildSongs(context, snap),
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

  Widget _buildSongs(BuildContext context, MusicLibrarySnapshot snap) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool byDifficulty = _sort.byDifficulty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
          child: Row(
            children: <Widget>[
              Expanded(
                child: HorizontalDragScrollable(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Semantics(
                      label: t.music_sort_label,
                      child: adaptiveSegmentedButton<MusicTrackSort>(
                        context: context,
                        segments: <ButtonSegment<MusicTrackSort>>[
                          for (final MusicTrackSort s in MusicTrackSort.values)
                            ButtonSegment<MusicTrackSort>(
                              value: s,
                              label: Text(musicTrackSortLabel(s)),
                            ),
                        ],
                        selected: <MusicTrackSort>{_sort},
                        onSelectionChanged: (Set<MusicTrackSort> v) =>
                            _setSort(v.first),
                      ),
                    ),
                  ),
                ),
              ),
              AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.short),
                child: byDifficulty
                    ? FushiIconButton(
                        key: const ValueKey<String>(
                          'music_difficulty_recompute',
                        ),
                        icon: FushiIcons.refresh,
                        tooltip: t.music_difficulty_recompute,
                        onTap: () => unawaited(_runCoverage(force: true)),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
        FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: byDifficulty
              ? _MusicCoverageStatus(
                  progress: _coverage.progress,
                  result: _coverageResult,
                  onStop: _coverage.cancel,
                )
              : const SizedBox(width: double.infinity),
        ),
        Expanded(
          child: MusicTrackList(
            // 换排序时整表重建，错峰进场重播一次。
            key: ValueKey<MusicTrackSort>(_sort),
            tracks: sortMusicTracksByDifficulty(
              snap.tracks,
              _difficulty,
              _sort,
            ),
            albums: snap.albumByUid,
            context: MusicQueueContext.mixed,
            difficulty: byDifficulty ? _difficulty : null,
          ),
        ),
      ],
    );
  }
}

String musicTrackSortLabel(MusicTrackSort s) => switch (s) {
  MusicTrackSort.library => t.music_sort_library,
  MusicTrackSort.easiestFirst => t.music_sort_easiest,
  MusicTrackSort.hardestFirst => t.music_sort_hardest,
};

/// 难度排序下的状态行：计算中（进度 + 停止）/ 缺词典 / 复习模块关着 / 口径说明。
class _MusicCoverageStatus extends StatelessWidget {
  const _MusicCoverageStatus({
    required this.progress,
    required this.result,
    required this.onStop,
  });

  final ValueListenable<MusicCoverageProgress> progress;
  final MusicCoverageRunResult? result;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap / 2,
        tokens.spacing.page,
        0,
      ),
      child: ValueListenableBuilder<MusicCoverageProgress>(
        valueListenable: progress,
        builder: (BuildContext context, MusicCoverageProgress p, _) {
          final Widget child;
          if (p.running) {
            child = Row(
              key: const ValueKey<String>('music_difficulty_running'),
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        t.music_difficulty_progress(
                          done: p.done,
                          total: p.total,
                        ),
                        style: context.fushiType.bodySmall,
                      ),
                      SizedBox(height: tokens.spacing.gap / 2),
                      LinearProgressIndicator(
                        value: p.total == 0 ? null : p.done / p.total,
                      ),
                    ],
                  ),
                ),
                FushiTextButton(
                  key: const ValueKey<String>('music_difficulty_stop'),
                  onPressed: onStop,
                  child: Text(t.music_difficulty_stop),
                ),
              ],
            );
          } else {
            final MusicCoverageRunResult? r = result;
            final String message =
                r?.outcome == MusicCoverageRunOutcome.noDictionary
                ? t.music_difficulty_needs_dictionary
                : r != null && !r.knownAvailable
                ? t.music_difficulty_needs_srs
                : t.music_difficulty_hint;
            child = Text(
              message,
              key: ValueKey<String>(message),
              style: context.fushiType.bodySmall,
            );
          }
          return AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
              alignment: Alignment.topLeft,
              children: <Widget>[...previous, ?current],
            ),
            child: child,
          );
        },
      ),
    );
  }
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({required this.snapshot, required this.onOpen});

  final MusicLibrarySnapshot snapshot;
  final ValueChanged<MusicAlbumRow> onOpen;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<MusicAlbumRow> albums = snapshot.albums;
    return FushiEntranceScope(
      child: GridView.builder(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            tokens.spacing.page,
            tokens.spacing.gap,
            tokens.spacing.page,
            tokens.spacing.section,
          ),
        ),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 200,
          mainAxisSpacing: tokens.spacing.gap * 1.5,
          crossAxisSpacing: tokens.spacing.gap * 1.5,
          childAspectRatio: 0.74,
        ),
        itemCount: albums.length,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          final MusicAlbumRow album = albums[i];
          return _AlbumCard(
            key: ValueKey<String>('music-album-${album.albumUid}'),
            album: album,
            tracks: snapshot.tracksOfAlbum(album.albumUid),
            embeddedCoverPath: snapshot.embeddedCoverPathOf(album),
            onTap: () => onOpen(album),
          );
        }),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    super.key,
    required this.album,
    required this.tracks,
    required this.embeddedCoverPath,
    required this.onTap,
  });

  final MusicAlbumRow album;
  final List<MusicTrackRow> tracks;
  final String? embeddedCoverPath;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
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
    return FushiHoverLift(
      builder: (BuildContext context, bool hovering) => FushiPressScale(
        child: InkWell(
          borderRadius: FushiDesignTokens.of(context).radii.cardRadius,
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: MusicCover(
                  coverPath: album.coverPath,
                  embeddedFromPath: embeddedCoverPath,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.titleSmallEmphasized,
              ),
              Text(
                <String>[
                  album.albumArtistCredit ?? t.music_artist_unknown,
                  if (badge.isNotEmpty) badge,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.bodySmall,
              ),
            ],
          ),
        ),
      ),
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
