part of 'music_plugin_pages.dart';

// 在线插件的「更多」动作（菜单外观与选歌单流程在 music_track_actions.dart，与 Apple Music 共用）：
// 曲目：喜欢 / 不喜欢（不再推荐）/ 加入歌单（含新建）/ 从当前歌单移除 / 以这首起电台 /
// 去艺人 / 去专辑；专辑 / 歌单：收藏 / 取消收藏、删除自己的歌单；艺人：关注 / 取消关注；
// 「我的歌单」新建歌单；推荐页的个人电台。每项只在插件声明了对应能力时出现
// （docs/specs/2026-10-28-music-plugins.md §4）。

MusicPluginSource _sourceOf(WidgetRef ref, String pluginId) =>
    ref.read(appProvider).musicPluginManager.source(pluginId);

/// 插件「我的歌单」里能加歌的歌单（`playlistEdit`）。
class _PluginPlaylistEditor implements MusicPlaylistEditor {
  _PluginPlaylistEditor(this.src);

  final MusicPluginSource src;

  /// 「我的歌单」一次最多看这么多张（够选；更多的去平台客户端整理）。
  static const int _pageSize = 200;

  static MusicPlaylistTarget _target(MusicPluginPlaylist p) =>
      MusicPlaylistTarget(id: p.id, title: p.title, trackCount: p.trackCount);

  @override
  Future<List<MusicPlaylistTarget>> editablePlaylists() async =>
      <MusicPlaylistTarget>[
        for (final MusicPluginPlaylist p in (await src.library(
          pageSize: _pageSize,
        )).items)
          if (p.editable) _target(p),
      ];

  @override
  Future<MusicPlaylistTarget> createPlaylist(
    String name, {
    List<String> trackIds = const <String>[],
  }) async => _target(await src.createPlaylist(name, trackIds: trackIds));

  @override
  Future<void> addToPlaylist(String playlistId, List<String> trackIds) =>
      src.addToPlaylist(playlistId, trackIds);
}

/// 收藏失败的提示：没登录说清楚是哪个平台，其余带插件的原话。
String _pluginActionError(MusicPluginManifest manifest, Object e) =>
    switch (e) {
      MusicFavoriteLoginRequired() => t.music_favorite_login_required(
        name: manifest.name,
      ),
      _ => musicPluginErrorText(e),
    };

// -------------------------------------------------------------------------
// 电台
// -------------------------------------------------------------------------

/// 插件电台（`radio`）当作续播队列：每次取下一批可播的曲目。
class _PluginRadioFeed implements MusicQueueFeed {
  _PluginRadioFeed(this.src, this.pluginId, {this.seedTrackId});

  final MusicPluginSource src;
  final String pluginId;
  final String? seedTrackId;

  @override
  Future<List<MusicPlayItem>> next() async {
    final MusicPluginRadioBatch batch = await src.radioNext(
      seedTrackId: seedTrackId,
    );
    return <MusicPlayItem>[
      for (final MusicPluginTrack tr in batch.tracks)
        if (tr.playable) musicPluginPlayItem(pluginId, tr),
    ];
  }
}

/// 放插件电台：不给 [seed] = 个人电台（网易云私人 FM），给了 = 以这首起电台。
Future<void> playMusicPluginRadio(
  BuildContext context,
  WidgetRef ref,
  MusicPluginManifest manifest, {
  MusicPluginTrack? seed,
}) async {
  final MusicPluginSource src = _sourceOf(ref, manifest.id);
  final String title = seed == null
      ? '${manifest.name} · ${t.music_plugin_radio_personal}'
      : t.music_plugin_radio_seeded(title: seed.title);
  final bool started = await ref
      .read(appProvider)
      .musicSession
      .queueFeeds
      .play(
        _PluginRadioFeed(src, manifest.id, seedTrackId: seed?.id),
        source: MusicPlaySource(
          kind: MusicPlaySourceKind.other,
          id: 'radio:${manifest.id}${seed == null ? '' : ':${seed.id}'}',
          title: title,
          cover: seed?.coverUrl,
        ),
      );
  if (!started) {
    FushiToast.show(
      msg: t.music_plugin_radio_empty,
      severity: ToastSeverity.warning,
    );
  }
}

/// 推荐页插件段头的「个人电台」按钮；插件没有 `radio` 能力回 null。
Widget? _pluginRadioButton(
  BuildContext context,
  WidgetRef ref,
  MusicPluginManifest manifest,
) {
  if (!manifest.can(MusicPluginCapability.radio)) return null;
  return FushiPressScale(
    child: FushiFilledButton.tonalIcon(
      key: ValueKey<String>('music-plugin-radio-${manifest.id}'),
      size: FushiButtonSize.s,
      onPressed: () async {
        try {
          await playMusicPluginRadio(context, ref, manifest);
        } on Object catch (e) {
          FushiToast.show(
            msg: _pluginActionError(manifest, e),
            severity: ToastSeverity.error,
          );
        }
      },
      icon: const FushiIcon(FushiIcons.cast),
      label: Text(t.music_plugin_radio_personal),
    ),
  );
}

// -------------------------------------------------------------------------
// 曲目菜单
// -------------------------------------------------------------------------

/// 插件曲目的「更多」按钮；一项动作都没有时回 null（行尾不留空位）。[inPlaylist] 是这首所在的
/// 歌单页（自己的歌单时多出「从这个歌单移除」，移除后调 [onChanged] 重拉）。
Widget? musicPluginTrackMenuButton(
  BuildContext context,
  WidgetRef ref,
  MusicPluginManifest manifest,
  MusicPluginTrack track, {
  MusicPluginPlaylist? inPlaylist,
  VoidCallback? onChanged,
}) {
  final List<MusicMenuAction> actions = _pluginTrackActions(
    ref,
    manifest,
    track,
    inPlaylist: inPlaylist,
    onChanged: onChanged,
  );
  if (actions.isEmpty) return null;
  return musicMoreButton(
    key: ValueKey<String>('music-plugin-track-menu-${track.id}'),
    onTap: () => unawaited(
      showMusicActionMenu(
        context,
        title: track.title,
        // 菜单打开时重算：喜欢状态可能刚在别处变过。
        actions: _pluginTrackActions(
          ref,
          manifest,
          track,
          inPlaylist: inPlaylist,
          onChanged: onChanged,
        ),
        errorText: (Object e) => _pluginActionError(manifest, e),
      ),
    ),
  );
}

List<MusicMenuAction> _pluginTrackActions(
  WidgetRef ref,
  MusicPluginManifest manifest,
  MusicPluginTrack track, {
  MusicPluginPlaylist? inPlaylist,
  VoidCallback? onChanged,
}) {
  bool can(MusicPluginCapability c) => manifest.can(c);
  final MusicSession session = ref.read(appProvider).musicSession;
  final MusicPlayItem item = musicPluginPlayItem(manifest.id, track);
  final bool likeable = track.playable && session.canFavorite(item);
  final bool liked = likeable && session.isFavorite(item);
  final MusicPluginArtistRef? artist = track.artists
      .where((MusicPluginArtistRef a) => a.id != null)
      .firstOrNull;
  return <MusicMenuAction>[
    if (likeable)
      MusicMenuAction(
        id: liked ? 'unlove' : 'love',
        label: liked ? t.music_action_unlove : t.music_action_love,
        icon: FushiIcons.favorite,
        run: (_) => session.toggleFavorite(item),
      ),
    if (can(MusicPluginCapability.radio))
      MusicMenuAction(
        id: 'dislike',
        label: t.music_action_dislike,
        icon: FushiIcons.block,
        run: (_) async {
          await _sourceOf(ref, manifest.id).radioTrash(track.id);
          FushiToast.show(
            msg: t.music_action_disliked,
            severity: ToastSeverity.success,
          );
        },
      ),
    if (can(MusicPluginCapability.playlistEdit)) ...<MusicMenuAction>[
      MusicMenuAction(
        id: 'addToPlaylist',
        label: t.music_action_add_to_playlist,
        icon: FushiIcons.playlist,
        run: (BuildContext c) async {
          final bool added = await musicAddToPlaylist(
            c,
            _PluginPlaylistEditor(_sourceOf(ref, manifest.id)),
            <String>[track.id],
          );
          // 加进的可能正是当前这张歌单。
          if (added) onChanged?.call();
        },
      ),
      if (inPlaylist != null && inPlaylist.editable)
        MusicMenuAction(
          id: 'removeFromPlaylist',
          label: t.music_action_remove_from_playlist,
          icon: FushiIcons.close,
          run: (_) async {
            await _sourceOf(
              ref,
              manifest.id,
            ).removeFromPlaylist(inPlaylist.id, <String>[track.id]);
            FushiToast.show(
              msg: t.music_action_removed_from_playlist(name: inPlaylist.title),
              severity: ToastSeverity.success,
            );
            onChanged?.call();
          },
        ),
    ],
    if (can(MusicPluginCapability.radio) && track.playable)
      MusicMenuAction(
        id: 'station',
        label: t.music_action_start_station,
        icon: FushiIcons.cast,
        run: (BuildContext c) =>
            playMusicPluginRadio(c, ref, manifest, seed: track),
      ),
    if (artist != null && can(MusicPluginCapability.artist))
      MusicMenuAction(
        id: 'artist',
        label: t.music_action_go_to_artist,
        subtitle: artist.name,
        icon: FushiIcons.person,
        run: (BuildContext c) => _push(
          c,
          MusicPluginArtistPage(
            manifest: manifest,
            artist: MusicPluginArtist(id: artist.id!, name: artist.name),
          ),
        ),
      ),
    if (track.albumId != null && can(MusicPluginCapability.album))
      MusicMenuAction(
        id: 'album',
        label: t.music_action_go_to_album,
        subtitle: track.albumTitle,
        icon: FushiIcons.music,
        run: (BuildContext c) => _push(
          c,
          MusicPluginCollectionPage.album(
            manifest: manifest,
            album: MusicPluginAlbum(
              id: track.albumId!,
              title: track.albumTitle ?? track.title,
              artists: track.artists,
              coverUrl: track.coverUrl,
            ),
          ),
        ),
      ),
  ];
}

// -------------------------------------------------------------------------
// 专辑 / 歌单 / 艺人
// -------------------------------------------------------------------------

/// 收藏 / 取消收藏（`collect`）。[collected] 未知（null）时两项都给。
List<MusicMenuAction> _collectActions(
  WidgetRef ref,
  MusicPluginManifest manifest,
  MusicPluginCollectType type,
  String id, {
  required bool? collected,
  required ValueChanged<bool> onCollected,
}) {
  if (!manifest.can(MusicPluginCapability.collect)) {
    return const <MusicMenuAction>[];
  }
  final bool artist = type == MusicPluginCollectType.artist;
  Future<void> set(bool on) async {
    await _sourceOf(ref, manifest.id).setCollected(type, id, on: on);
    FushiToast.show(
      msg: artist
          ? (on ? t.music_action_followed : t.music_action_unfollowed)
          : (on ? t.music_action_collected : t.music_action_uncollected),
      severity: ToastSeverity.success,
    );
    onCollected(on);
  }

  return <MusicMenuAction>[
    if (collected != true)
      MusicMenuAction(
        id: 'collect',
        label: artist ? t.music_action_follow : t.music_action_collect,
        icon: artist ? FushiIcons.person : FushiIcons.libraryAdd,
        run: (_) => set(true),
      ),
    if (collected != false)
      MusicMenuAction(
        id: 'uncollect',
        label: artist ? t.music_action_unfollow : t.music_action_uncollect,
        icon: FushiIcons.close,
        run: (_) => set(false),
      ),
  ];
}

/// 专辑 / 歌单页按钮行里的「更多」：收藏 / 取消收藏；自己的歌单可删除（删完退出页面）。
/// 没有可做的动作时回空列表。
List<Widget> _pluginCollectionActions(
  BuildContext context,
  WidgetRef ref,
  MusicPluginManifest manifest, {
  MusicPluginAlbum? album,
  MusicPluginPlaylist? playlist,
  required bool? collected,
  required ValueChanged<bool> onCollected,
}) {
  final bool own =
      playlist != null &&
      playlist.editable &&
      manifest.can(MusicPluginCapability.playlistEdit);
  final MusicPluginCollectType type = album != null
      ? MusicPluginCollectType.album
      : MusicPluginCollectType.playlist;
  final String id = album?.id ?? playlist!.id;
  List<MusicMenuAction> actions() => <MusicMenuAction>[
    // 自己建的歌单不需要「收藏」。
    if (!own)
      ..._collectActions(
        ref,
        manifest,
        type,
        id,
        collected: collected,
        onCollected: onCollected,
      ),
    if (own)
      MusicMenuAction(
        id: 'deletePlaylist',
        label: t.music_action_delete_playlist,
        icon: FushiIcons.delete,
        run: (BuildContext c) async {
          final bool ok = await showFushiConfirmDialog(
            context: c,
            title: t.music_action_delete_playlist,
            message: t.music_action_delete_playlist_confirm(
              name: playlist.title,
            ),
            icon: FushiIcons.delete,
            destructive: true,
          );
          if (!ok) return;
          await _sourceOf(ref, manifest.id).deletePlaylist(playlist.id);
          FushiToast.show(
            msg: t.music_action_playlist_deleted(name: playlist.title),
            severity: ToastSeverity.success,
          );
          if (c.mounted) Navigator.of(c).maybePop();
        },
      ),
  ];
  if (actions().isEmpty) return const <Widget>[];
  return <Widget>[
    musicMoreButton(
      key: const ValueKey<String>('music-plugin-collection-more'),
      onTap: () => unawaited(
        showMusicActionMenu(
          context,
          title: album?.title ?? playlist!.title,
          icon: FushiIcons.moreHoriz,
          actions: actions(),
          errorText: (Object e) => _pluginActionError(manifest, e),
        ),
      ),
    ),
  ];
}

/// 「我的歌单」顶部的「新建歌单」；插件没有 `playlistEdit` 回 null。
Widget? _pluginCreatePlaylistButton(
  BuildContext context,
  WidgetRef ref,
  MusicPluginManifest manifest, {
  required VoidCallback onCreated,
}) {
  if (!manifest.can(MusicPluginCapability.playlistEdit)) return null;
  return musicCreatePlaylistButton(
    context,
    _PluginPlaylistEditor(_sourceOf(ref, manifest.id)),
    key: ValueKey<String>('music-plugin-new-playlist-${manifest.id}'),
    onCreated: onCreated,
    errorText: (Object e) => _pluginActionError(manifest, e),
  );
}
