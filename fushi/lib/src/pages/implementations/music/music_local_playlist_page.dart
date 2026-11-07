/// 本地歌单页（v148，反馈 0tRY-D2JgG）：歌单里的本地曲目与远程曲目（YouTube / 在线插件）
/// 排在同一条队列里，可播放 / 随机播放 / 改名 / 删除，每行可「从这个歌单移除」。
///
/// 条目解析见 `loadMusicPlaylistItems`（解析不到的条目跳过、不删）；表级变更流驱动重读
/// （与曲库页同一做法，不订阅 drift `.watch()`）。
library;

import 'dart:async';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdate, TableUpdateQuery;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart'
    show
        kMusicAlbumDetailCoverSize,
        musicAlbumDetailCover,
        musicBrowsePagePadding,
        musicBrowseScaffold;
import 'package:fushi/src/pages/implementations/music/music_track_list.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 推入一个本地歌单页。
void openMusicLocalPlaylist(BuildContext context, MusicPlaylistRow playlist) =>
    unawaited(
      Navigator.of(context).push<void>(
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => MusicLocalPlaylistPage(playlist: playlist),
        ),
      ),
    );

class MusicLocalPlaylistPage extends ConsumerStatefulWidget {
  const MusicLocalPlaylistPage({
    super.key,
    required this.playlist,
    this.itemsLoader,
  });

  /// 打开时的歌单行（改名后以重读到的为准）。
  final MusicPlaylistRow playlist;

  /// 测试注入：替代读库。
  final Future<List<MusicPlaylistItem>> Function()? itemsLoader;

  @override
  ConsumerState<MusicLocalPlaylistPage> createState() =>
      _MusicLocalPlaylistPageState();
}

typedef _PlaylistData = ({
  MusicPlaylistRow? playlist,
  List<MusicPlaylistItem> items,
  Map<String, MusicAlbumRow> albums,
});

class _MusicLocalPlaylistPageState
    extends ConsumerState<MusicLocalPlaylistPage> {
  late Future<_PlaylistData> _data = _load();
  _PlaylistData? _shown;
  StreamSubscription<Set<TableUpdate>>? _dbSub;

  AppModel get _app => ref.read(appProvider);

  @override
  void initState() {
    super.initState();
    if (widget.itemsLoader == null && _app.isDatabaseReady) {
      final FushiDatabase db = _app.database;
      _dbSub = db
          .tableUpdates(
            TableUpdateQuery.onAllTables(
              <ResultSetImplementation<Object?, Object?>>[
                db.musicPlaylists,
                db.musicPlaylistEntries,
                db.musicRemoteTracks,
                db.musicTracks,
              ],
            ),
          )
          .listen((_) {
            if (mounted) setState(() => _data = _load());
          });
    }
  }

  @override
  void dispose() {
    unawaited(_dbSub?.cancel());
    super.dispose();
  }

  Future<_PlaylistData> _load() async {
    final Future<List<MusicPlaylistItem>> Function()? loader =
        widget.itemsLoader;
    if (loader != null) {
      return (
        playlist: widget.playlist,
        items: await loader(),
        albums: const <String, MusicAlbumRow>{},
      );
    }
    final FushiDatabase db = _app.database;
    final String uid = widget.playlist.playlistUid;
    final List<MusicPlaylistItem> items = await loadMusicPlaylistItems(db, uid);
    final Map<String, MusicAlbumRow> albums = <String, MusicAlbumRow>{};
    for (final MusicPlaylistItem i in items) {
      if (i.entry case MusicLocalEntry(:final MusicTrackRow track)) {
        final String? a = track.albumUid;
        if (a != null && !albums.containsKey(a)) {
          final MusicAlbumRow? row = await db.getMusicAlbum(a);
          if (row != null) albums[a] = row;
        }
      }
    }
    return (
      playlist: await db.getMusicPlaylist(uid),
      items: items,
      albums: albums,
    );
  }

  MusicPlaySource _source(MusicPlaylistRow p) =>
      MusicPlaySource.playlist(p.playlistUid, title: p.name);

  void _playAll(_PlaylistData d, {bool shuffle = false}) {
    final MusicPlaylistRow p = d.playlist ?? widget.playlist;
    final List<MusicPlayItem> items = <MusicPlayItem>[
      for (final MusicPlaylistItem i in d.items) ?i.entry.playItem(d.albums),
    ];
    unawaited(
      _app.musicSession.engine.playQueue(
        items,
        shuffle: shuffle,
        source: _source(p),
      ),
    );
  }

  Future<void> _rename(MusicPlaylistRow p) async {
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.music_action_rename_playlist,
      labelText: t.music_action_playlist_name,
      initialValue: p.name,
      icon: FushiIcons.edit,
    );
    if (name == null || name.isEmpty || name == p.name) return;
    await _app.database.renameMusicPlaylist(
      p.playlistUid,
      name,
      at: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _delete(MusicPlaylistRow p) async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.music_action_delete_playlist,
      message: t.music_action_delete_playlist_confirm(name: p.name),
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _app.database.deleteMusicPlaylist(
      p.playlistUid,
      at: DateTime.now().millisecondsSinceEpoch,
    );
    FushiToast.show(
      msg: t.music_action_playlist_deleted(name: p.name),
      severity: ToastSeverity.success,
    );
    if (mounted) unawaited(Navigator.of(context).maybePop());
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return musicBrowseScaffold(
      context,
      title: _shown?.playlist?.name ?? widget.playlist.name,
      body: FutureBuilder<_PlaylistData>(
        future: _data,
        builder: (BuildContext context, AsyncSnapshot<_PlaylistData> snap) {
          final _PlaylistData? d = snap.data ?? _shown;
          if (d == null) return const FushiLoadingView();
          _shown = d;
          final MusicPlaylistRow p = d.playlist ?? widget.playlist;
          final List<MusicPlaylistItem> items = d.items;
          final String? cover = <String?>[
            for (final MusicPlaylistItem i in items)
              switch (i.entry) {
                MusicRemoteEntry(:final MusicRemoteTrackRow track) =>
                  track.coverUrl,
                MusicLocalEntry(:final MusicTrackRow track) =>
                  d.albums[track.albumUid]?.coverPath,
              },
          ].nonNulls.firstOrNull;
          final List<Widget> children = <Widget>[
            Wrap(
              spacing: tokens.spacing.section,
              runSpacing: tokens.spacing.gap,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: <Widget>[
                musicAlbumDetailCover(
                  MusicCover(
                    coverPath: cover,
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
                      Text(p.name, style: context.fushiType.headlineSmall),
                      Text(
                        <String>[
                          t.music_playlists_local,
                          t.music_tracks_count(count: items.length),
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
                                'music_local_playlist_play',
                              ),
                              onPressed: items.isEmpty
                                  ? null
                                  : () => _playAll(d),
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
                              onPressed: items.isEmpty
                                  ? null
                                  : () => _playAll(d, shuffle: true),
                              icon: const FushiIcon(FushiIcons.shuffle),
                              label: Text(t.music_shuffle_play),
                            ),
                          ),
                          FushiPressScale(
                            child: FushiFilledButton.tonalIcon(
                              size: FushiButtonSize.m,
                              key: const ValueKey<String>(
                                'music_local_playlist_rename',
                              ),
                              onPressed: () => unawaited(_rename(p)),
                              icon: const FushiIcon(FushiIcons.edit),
                              label: Text(t.music_action_rename_playlist),
                            ),
                          ),
                          FushiPressScale(
                            child: FushiFilledButton.tonalIcon(
                              size: FushiButtonSize.m,
                              key: const ValueKey<String>(
                                'music_local_playlist_delete',
                              ),
                              onPressed: () => unawaited(_delete(p)),
                              icon: const FushiIcon(FushiIcons.delete),
                              label: Text(t.music_action_delete_playlist),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (items.isEmpty)
              FushiPlaceholderMessage(
                icon: FushiIcons.playlist,
                message: t.music_server_playlist_empty,
              )
            else
              MusicTrackList.entries(
                key: const ValueKey<String>('music-local-playlist-tracks'),
                entries: <MusicLibraryEntry>[
                  for (final MusicPlaylistItem i in items) i.entry,
                ],
                albums: d.albums,
                context: MusicQueueContext.mixed,
                shrinkWrap: true,
                playlist: MusicTrackListPlaylist(
                  playlist: p,
                  entryIds: <int>[
                    for (final MusicPlaylistItem i in items) i.entryId,
                  ],
                ),
                source: _source(p),
              ),
          ];
          return FushiEntranceScope(
            child: ListView.separated(
              padding: musicBrowsePagePadding(context),
              itemCount: children.length,
              separatorBuilder: (_, int i) =>
                  SizedBox(height: i == 0 ? tokens.spacing.section : 0),
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
