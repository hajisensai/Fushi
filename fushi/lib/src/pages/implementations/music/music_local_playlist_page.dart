/// 本地歌单页：封面、整单播放 / 随机、改名 / 导出 `.m3u8` / 删除，曲目可拖拽重排、可从
/// 歌单移除。曲目文件暂时不在（来源没挂上 / 文件被挪走）的条目不显示、不删，底部注明
/// 条数；文件回来后重扫即重新出现。
///
/// [MusicPlaylistTrackColumn] 是可重排的曲目列，服务器（Jellyfin）歌单页共用。
library;

import 'dart:async';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdate, TableUpdateQuery;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_local_playlists.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_playlist_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart'
    show
        musicAlbumDetailCover,
        musicBrowsePagePadding,
        musicBrowseScaffold,
        kMusicAlbumDetailCoverSize;
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 可重排曲目列里的一行。
class MusicPlaylistTrackRowData {
  const MusicPlaylistTrackRowData({
    required this.key,
    required this.title,
    this.subtitle,
    this.durationMs,
  });

  /// 行身份（条目 id 派生；同一首放两次是两行）。
  final String key;
  final String title;
  final String? subtitle;
  final int? durationMs;
}

/// 歌单曲目列：点一行播放；[onReorder] 非空时行尾有拖拽把手（只从把手起拖，整行仍可点、
/// 可右键）；[menuOf] 给每行的「更多」菜单（行尾按钮 + 整行右键）。
class MusicPlaylistTrackColumn extends StatelessWidget {
  const MusicPlaylistTrackColumn({
    super.key,
    required this.rows,
    required this.onPlay,
    this.onReorder,
    this.menuOf,
  });

  final List<MusicPlaylistTrackRowData> rows;
  final void Function(int index) onPlay;
  final void Function(int from, int to)? onReorder;
  final MusicItemMenu? Function(BuildContext context, int index)? menuOf;

  Widget _row(BuildContext context, int i) {
    final MusicPlaylistTrackRowData r = rows[i];
    final MusicItemMenu? menu = menuOf?.call(context, i);
    return FushiStaggeredEntrance(
      index: i,
      child: musicWithContextMenu(
        menu,
        FushiPressScale(
          child: FushiGroupedListItem(
            key: ValueKey<String>('music-playlist-row-${r.key}'),
            index: i,
            count: rows.length,
            onTap: () => onPlay(i),
            child: FushiListItem(
              leading: SizedBox(
                width: 28,
                child: Text(
                  '${i + 1}',
                  textAlign: TextAlign.end,
                  style: context.fushiType.bodySmall,
                ),
              ),
              title: Text(
                r.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: r.subtitle == null || r.subtitle!.isEmpty
                  ? null
                  : Text(
                      r.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    formatMusicDuration(r.durationMs),
                    style: context.fushiType.bodySmall,
                  ),
                  ?menu?.button(),
                  if (onReorder != null)
                    Tooltip(
                      message: t.music_action_reorder,
                      child: const FushiReorderableDragHandle(
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: Center(
                            child: FushiIcon(FushiIcons.dragIndicator),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final void Function(int from, int to)? reorder = onReorder;
    if (reorder == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < rows.length; i++) _row(context, i),
        ],
      );
    }
    return FushiReorderableColumn(
      itemCount: rows.length,
      useDragHandles: true,
      keyForIndex: (int i) =>
          ValueKey<String>('music-playlist-reorder-${rows[i].key}'),
      onReorder: reorder,
      itemBuilder: _row,
    );
  }
}

/// 一条在库的歌单条目。
class _Entry {
  const _Entry(this.entry, this.track, this.album);

  final MusicPlaylistEntryRow entry;
  final MusicTrackRow track;
  final MusicAlbumRow? album;
}

class MusicLocalPlaylistPage extends ConsumerStatefulWidget {
  const MusicLocalPlaylistPage({
    super.key,
    required this.playlistUid,
    this.initialTitle,
  });

  final String playlistUid;

  /// 读库之前先显示的标题（列表页已知）。
  final String? initialTitle;

  @override
  ConsumerState<MusicLocalPlaylistPage> createState() =>
      _MusicLocalPlaylistPageState();
}

class _MusicLocalPlaylistPageState
    extends ConsumerState<MusicLocalPlaylistPage> {
  MusicPlaylistRow? _playlist;
  List<_Entry> _entries = <_Entry>[];
  int _missing = 0;
  bool _loaded = false;
  StreamSubscription<Set<TableUpdate>>? _dbSub;

  AppModel get _app => ref.read(appProvider);
  FushiDatabase get _db => _app.database;
  String get _uid => widget.playlistUid;

  @override
  void initState() {
    super.initState();
    // 表级变更流（同专辑页：长驻页面不用 drift .watch()）。加歌 / 重扫 / 备份合并都在别处
    // 落库，这里跟着重读。
    _dbSub = _db
        .tableUpdates(
          TableUpdateQuery.onAllTables(
            <ResultSetImplementation<Object?, Object?>>[
              _db.musicPlaylists,
              _db.musicPlaylistEntries,
              _db.musicTracks,
            ],
          ),
        )
        .listen((_) => unawaited(_reload()));
    unawaited(_reload());
  }

  @override
  void dispose() {
    unawaited(_dbSub?.cancel());
    super.dispose();
  }

  Future<void> _reload() async {
    final MusicPlaylistRow? pl = await _db.getMusicPlaylist(_uid);
    if (!mounted) return;
    if (pl == null || pl.deletedAt != null) {
      // 被删了（本页或别处 / 备份合并）：退回曲库。
      unawaited(Navigator.of(context).maybePop());
      return;
    }
    final List<MusicPlaylistEntryRow> rows = await _db.listMusicPlaylistEntries(
      _uid,
    );
    final Map<String, MusicTrackRow> tracks = await _db
        .listLiveMusicTracksByUid(
          rows.map((MusicPlaylistEntryRow e) => e.trackUid),
        );
    final Map<String, MusicAlbumRow?> albums = <String, MusicAlbumRow?>{};
    for (final MusicTrackRow tr in tracks.values) {
      final String? a = tr.albumUid;
      if (a != null && !albums.containsKey(a)) {
        albums[a] = await _db.getMusicAlbum(a);
      }
    }
    if (!mounted) return;
    final List<_Entry> entries = <_Entry>[
      for (final MusicPlaylistEntryRow e in rows)
        if (tracks[e.trackUid] case final MusicTrackRow tr)
          _Entry(e, tr, tr.albumUid == null ? null : albums[tr.albumUid!]),
    ];
    setState(() {
      _playlist = pl;
      _entries = entries;
      _missing = rows.length - entries.length;
      _loaded = true;
    });
  }

  String get _title => _playlist?.name ?? widget.initialTitle ?? '';

  String? get _coverPath {
    for (final _Entry e in _entries) {
      final String? c = e.album?.coverPath;
      if (c != null) return c;
    }
    return null;
  }

  void _play({int start = 0, bool shuffle = false}) {
    if (_entries.isEmpty) return;
    final MusicPlayerEngine engine = _app.musicSession.engine;
    unawaited(
      engine.playQueue(
        <MusicPlayItem>[
          for (final _Entry e in _entries)
            musicPlayItemOf(e.track, album: e.album),
        ],
        startIndex: start,
        shuffle: shuffle,
        source: MusicPlaySource.playlist(
          _uid,
          title: _title,
          cover: _coverPath,
        ),
      ),
    );
  }

  Future<void> _reorder(int from, int to) async {
    if (from == to) return;
    final List<_Entry> next = List<_Entry>.of(_entries);
    next.insert(to, next.removeAt(from));
    setState(() => _entries = next);
    try {
      await _db.reorderMusicPlaylist(_uid, <int>[
        for (final _Entry e in next) e.entry.id,
      ], now: DateTime.now().millisecondsSinceEpoch);
    } on Object catch (e) {
      FushiToast.show(
        msg: musicPlaylistErrorText(e),
        severity: ToastSeverity.error,
      );
      unawaited(_reload());
    }
  }

  Future<void> _remove(_Entry e) async {
    try {
      await _db.removeMusicPlaylistEntries(_uid, <int>{
        e.entry.id,
      }, now: DateTime.now().millisecondsSinceEpoch);
    } on Object catch (err) {
      FushiToast.show(
        msg: musicPlaylistErrorText(err),
        severity: ToastSeverity.error,
      );
      return;
    }
    FushiToast.show(
      msg: t.music_action_removed_from_playlist(name: _title),
      severity: ToastSeverity.success,
    );
  }

  void _export() => unawaited(
    musicExportPlaylistM3u8(
      name: _title,
      items: <MusicPlaylistExportItem>[
        for (final _Entry e in _entries)
          MusicPlaylistExportItem(
            location: e.track.path,
            title: e.track.title,
            artist: e.track.artistCredit ?? e.album?.albumArtistCredit,
            durationMs: e.track.durationMs,
          ),
      ],
    ),
  );

  MusicItemMenu _rowMenu(BuildContext context, int i) {
    final _Entry e = _entries[i];
    return MusicItemMenu(
      buttonKey: ValueKey<String>('music-playlist-row-menu-${e.entry.id}'),
      open: (MusicMenuAnchor? anchor) => unawaited(
        showMusicActionMenu(
          context,
          anchor: anchor,
          errorText: musicPlaylistErrorText,
          actions: <MusicMenuAction>[
            MusicMenuAction(
              id: 'remove',
              label: t.music_action_remove_from_playlist,
              icon: FushiIcons.removeCircle,
              run: (_) => _remove(e),
            ),
            MusicMenuAction(
              id: 'detail',
              label: t.music_track_detail,
              icon: FushiIcons.info,
              run: (BuildContext c) async =>
                  openMusicTrackDetail(c, e.track.trackUid),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (!_loaded) {
      return musicBrowseScaffold(
        context,
        title: _title,
        body: const FushiLoadingView(),
      );
    }
    final List<Widget> children = <Widget>[
      Wrap(
        spacing: tokens.spacing.section,
        runSpacing: tokens.spacing.gap,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: <Widget>[
          musicAlbumDetailCover(
            MusicCover(
              coverPath: _coverPath,
              embeddedFromPath: _entries.isEmpty
                  ? null
                  : _entries.first.track.path,
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
                  t.music_tracks_count(count: _entries.length),
                  style: context.fushiType.bodyMedium,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: tokens.spacing.gap,
                  runSpacing: tokens.spacing.gap,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    FushiPressScale(
                      child: FushiFilledButton.icon(
                        size: FushiButtonSize.m,
                        key: const ValueKey<String>(
                          'music_local_playlist_play',
                        ),
                        onPressed: _entries.isEmpty ? null : _play,
                        icon: const FushiIcon(FushiIcons.play),
                        label: Text(t.music_play_all),
                      ),
                    ),
                    FushiPressScale(
                      child: FushiFilledButton.tonalIcon(
                        size: FushiButtonSize.m,
                        key: const ValueKey<String>(
                          'music_local_playlist_shuffle',
                        ),
                        onPressed: _entries.isEmpty
                            ? null
                            : () => _play(shuffle: true),
                        icon: const FushiIcon(FushiIcons.shuffle),
                        label: Text(t.music_shuffle_play),
                      ),
                    ),
                    FushiIconButton(
                      key: const ValueKey<String>(
                        'music_local_playlist_rename',
                      ),
                      icon: FushiIcons.edit,
                      tooltip: t.music_action_rename_playlist,
                      padTouchTarget: true,
                      onTap: () => unawaited(
                        musicRenamePlaylist(
                          context,
                          current: _title,
                          rename: (String name) => _db.renameMusicPlaylist(
                            _uid,
                            name,
                            now: DateTime.now().millisecondsSinceEpoch,
                          ),
                        ),
                      ),
                    ),
                    FushiIconButton(
                      key: const ValueKey<String>(
                        'music_local_playlist_export',
                      ),
                      icon: FushiIcons.share,
                      tooltip: t.music_action_export_playlist,
                      padTouchTarget: true,
                      onTap: _entries.isEmpty ? null : _export,
                    ),
                    FushiIconButton(
                      key: const ValueKey<String>(
                        'music_local_playlist_delete',
                      ),
                      icon: FushiIcons.delete,
                      tooltip: t.music_action_delete_playlist,
                      padTouchTarget: true,
                      onTap: () => unawaited(
                        musicDeletePlaylist(
                          context,
                          name: _title,
                          delete: () => _db.softDeleteMusicPlaylist(
                            _uid,
                            now: DateTime.now().millisecondsSinceEpoch,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      if (_entries.isEmpty)
        FushiPlaceholderMessage(
          icon: FushiIcons.playlist,
          message: t.music_server_playlist_empty,
        )
      else
        MusicPlaylistTrackColumn(
          rows: <MusicPlaylistTrackRowData>[
            for (final _Entry e in _entries)
              MusicPlaylistTrackRowData(
                key: '${e.entry.id}',
                title: e.track.title,
                subtitle: <String>[
                  e.track.artistCredit ??
                      e.album?.albumArtistCredit ??
                      t.music_artist_unknown,
                  ?e.album?.title,
                ].join(' · '),
                durationMs: e.track.durationMs,
              ),
          ],
          onPlay: (int i) => _play(start: i),
          onReorder: (int from, int to) => unawaited(_reorder(from, to)),
          menuOf: _rowMenu,
        ),
      if (_missing > 0)
        Text(
          t.music_playlist_unavailable_tracks(count: _missing),
          key: const ValueKey<String>('music_local_playlist_missing'),
          style: context.fushiType.bodySmall,
        ),
    ];
    return musicBrowseScaffold(
      context,
      title: _title,
      body: FushiEntranceScope(
        child: ListView.separated(
          padding: musicBrowsePagePadding(context),
          itemCount: children.length,
          separatorBuilder: (_, int i) => SizedBox(
            height: i == 0 ? tokens.spacing.gap : tokens.spacing.gap * 0.5,
          ),
          itemBuilder: fushiStaggeredItemBuilder(
            (BuildContext context, int i) => children[i],
          ),
        ),
      ),
    );
  }
}
