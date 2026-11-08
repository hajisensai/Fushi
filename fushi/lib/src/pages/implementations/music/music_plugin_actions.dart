part of 'music_plugin_pages.dart';

// 在线插件的「更多」动作（菜单外观与选歌单流程在 music_track_actions.dart，与 Apple Music 共用）：
// 曲目：喜欢 / 不喜欢（不再推荐）/ 加入歌单（含新建）/ 从当前歌单移除 / 以这首起电台 /
// 去艺人 / 去专辑。专辑 / 歌单的收藏、删除自己的歌单与艺人的关注平铺在头部按钮行；
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

/// 插件曲目的菜单（行尾「更多」+ 整行右键）；一项动作都没有时回 null（行尾不留空位）。
/// [inPlaylist] 是这首所在的歌单页（自己的歌单时多出「从这个歌单移除」，移除后调
/// [onChanged] 重拉）。
MusicItemMenu? musicPluginTrackMenu(
  BuildContext context,
  WidgetRef ref,
  MusicPluginManifest manifest,
  MusicPluginTrack track, {
  MusicPluginPlaylist? inPlaylist,
  VoidCallback? onChanged,
}) {
  List<MusicMenuAction> actions({bool inLibrary = false}) =>
      _pluginTrackActions(
        ref,
        manifest,
        track,
        inPlaylist: inPlaylist,
        onChanged: onChanged,
        inLibrary: inLibrary,
      );
  if (actions().isEmpty) return null;
  return MusicItemMenu(
    buttonKey: ValueKey<String>('music-plugin-track-menu-${track.id}'),
    open: (MusicMenuAnchor? anchor) => unawaited(() async {
      // 右键坐标只在同步派发期间可读：第一个 await 之前取好。
      final MusicMenuAnchor? at = anchor ?? musicContextMenuAnchor();
      final bool inLibrary = await _inMusicLibrary(ref, manifest, track);
      if (!context.mounted) return;
      await showMusicActionMenu(
        context,
        anchor: at,
        // 菜单打开时重算：喜欢 / 入库状态可能刚在别处变过。
        actions: actions(inLibrary: inLibrary),
        errorText: (Object e) => _pluginActionError(manifest, e),
      );
    }()),
  );
}

/// 这首插件曲目是否已加入音乐库（远程曲目，v148）；库没就绪时按不在库。
Future<bool> _inMusicLibrary(
  WidgetRef ref,
  MusicPluginManifest manifest,
  MusicPluginTrack track,
) async {
  final AppModel app = ref.read(appProvider);
  if (!app.isDatabaseReady || !musicRemoteTracksAvailable) return false;
  final MusicRemoteTrackRow? row = await app.database.getMusicRemoteTrack(
    musicPluginTrackUid(manifest.id, track.id),
  );
  return row?.libraryAddedAt != null;
}

List<MusicMenuAction> _pluginTrackActions(
  WidgetRef ref,
  MusicPluginManifest manifest,
  MusicPluginTrack track, {
  MusicPluginPlaylist? inPlaylist,
  VoidCallback? onChanged,
  bool inLibrary = false,
}) {
  bool can(MusicPluginCapability c) => manifest.can(c);
  final AppModel app = ref.read(appProvider);
  final MusicSession session = app.musicSession;
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
    // 加入音乐库 / 本地歌单（远程曲目，v148）：与账号歌单并列时写明「本地」。
    if (track.playable && app.isDatabaseReady)
      ...musicRemoteLibraryActions(
        app.database,
        item,
        inLibrary: inLibrary,
        playlistLabel: t.music_action_add_to_local_playlist,
      ),
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

/// 一个插件条目的收藏 / 关注键。
typedef _PluginCollectKey = ({
  String pluginId,
  MusicPluginCollectType type,
  String id,
});

/// 本次运行里用户改过的插件收藏 / 关注状态（写给插件成功之后记一笔）。
///
/// 列表行、卡片、详情页手里的 `collected` 都是加载那一刻的快照，改过之后不会自己变。
/// 所以收藏状态只有这一处可写：卡片右键菜单与详情页头部的切换按钮都先查这里、
/// 查不到才用快照——同一条目在哪个入口改，别的入口（包括下次右键）都跟着变。
final StateProvider<Map<_PluginCollectKey, bool>> _pluginCollectedProvider =
    StateProvider<Map<_PluginCollectKey, bool>>(
      (Ref ref) => const <_PluginCollectKey, bool>{},
    );

/// [id] 当前的收藏状态：本次运行改过的为准，否则用条目快照 [snapshot]（null = 未知）。
bool? _pluginCollectedOf(
  Map<_PluginCollectKey, bool> overrides,
  MusicPluginManifest manifest,
  MusicPluginCollectType type,
  String id,
  bool? snapshot,
) => overrides[(pluginId: manifest.id, type: type, id: id)] ?? snapshot;

/// 收藏 / 取消收藏（艺人 = 关注 / 取消关注）：写给插件，成功后记进
/// [_pluginCollectedProvider] 并提示。失败照常抛给调用方提示。
Future<void> _setPluginCollected(
  WidgetRef ref,
  MusicPluginManifest manifest,
  MusicPluginCollectType type,
  String id, {
  required bool on,
}) async {
  // await 之后调用方控件可能已卸载：先取好控制器。
  final StateController<Map<_PluginCollectKey, bool>> overrides = ref.read(
    _pluginCollectedProvider.notifier,
  );
  await _sourceOf(ref, manifest.id).setCollected(type, id, on: on);
  overrides.state = <_PluginCollectKey, bool>{
    ...overrides.state,
    (pluginId: manifest.id, type: type, id: id): on,
  };
  final bool artist = type == MusicPluginCollectType.artist;
  FushiToast.show(
    msg: artist
        ? (on ? t.music_action_followed : t.music_action_unfollowed)
        : (on ? t.music_action_collected : t.music_action_uncollected),
    severity: ToastSeverity.success,
  );
}

/// 插件专辑 / 歌单 / 艺人卡片（列表行、横滑卡、网格卡）的右键菜单：打开、收藏 / 关注、
/// 去艺人。[item] 不是这三类时回 null。收藏状态以本次运行里改过的为准
/// （[_pluginCollectedProvider]），没改过用条目自带的 `collected`；未知时两项都给
/// （插件的收藏是幂等写）。
MusicItemMenu? musicPluginEntityMenu(
  BuildContext context,
  WidgetRef ref,
  MusicPluginManifest manifest,
  Object item,
) {
  final (
    String id,
    MusicPluginCollectType type,
    bool? snapshot,
    Widget page,
  ) = switch (item) {
    MusicPluginAlbum a => (
      a.id,
      MusicPluginCollectType.album,
      a.collected,
      MusicPluginCollectionPage.album(manifest: manifest, album: a),
    ),
    MusicPluginPlaylist p => (
      p.id,
      MusicPluginCollectType.playlist,
      p.collected,
      MusicPluginCollectionPage.playlist(manifest: manifest, playlist: p),
    ),
    MusicPluginArtist a => (
      a.id,
      MusicPluginCollectType.artist,
      a.collected,
      MusicPluginArtistPage(manifest: manifest, artist: a),
    ),
    _ => ('', MusicPluginCollectType.album, null, const SizedBox.shrink()),
  };
  if (id.isEmpty) return null;
  final bool artist = type == MusicPluginCollectType.artist;
  // 自己建的歌单不出「收藏」（与歌单页按钮行一致）。
  final bool own =
      item is MusicPluginPlaylist &&
      item.editable &&
      manifest.can(MusicPluginCapability.playlistEdit);
  final bool canCollect = !own && manifest.can(MusicPluginCapability.collect);
  Future<void> setCollected(bool on) =>
      _setPluginCollected(ref, manifest, type, id, on: on);

  final MusicPluginArtistRef? albumArtist = item is MusicPluginAlbum
      ? item.artists.where((MusicPluginArtistRef a) => a.id != null).firstOrNull
      : null;
  // 收藏状态在弹出那一刻读（本次运行改过的为准），不冻结在卡片构建时。
  List<MusicMenuAction> actions() {
    final bool? collected = _pluginCollectedOf(
      ref.read(_pluginCollectedProvider),
      manifest,
      type,
      id,
      snapshot,
    );
    return <MusicMenuAction>[
      MusicMenuAction(
        id: 'open',
        label: t.music_action_open,
        icon: FushiIcons.openInNew,
        run: (BuildContext c) => _push(c, page),
      ),
      if (canCollect && collected != true)
        MusicMenuAction(
          id: 'collect',
          label: artist ? t.music_action_follow : t.music_action_collect,
          icon: artist ? FushiIcons.personAdd : FushiIcons.libraryAdd,
          run: (_) => setCollected(true),
        ),
      if (canCollect && collected != false)
        MusicMenuAction(
          id: 'uncollect',
          label: artist ? t.music_action_unfollow : t.music_action_uncollect,
          icon: artist ? FushiIcons.personRemove : FushiIcons.close,
          run: (_) => setCollected(false),
        ),
      if (albumArtist != null && manifest.can(MusicPluginCapability.artist))
        MusicMenuAction(
          id: 'artist',
          label: t.music_action_go_to_artist,
          subtitle: albumArtist.name,
          icon: FushiIcons.person,
          run: (BuildContext c) => _push(
            c,
            MusicPluginArtistPage(
              manifest: manifest,
              artist: MusicPluginArtist(
                id: albumArtist.id!,
                name: albumArtist.name,
              ),
            ),
          ),
        ),
    ];
  }

  return MusicItemMenu(
    buttonKey: ValueKey<String>('music-plugin-entity-menu-${type.name}-$id'),
    open: (MusicMenuAnchor? anchor) => unawaited(
      showMusicActionMenu(
        context,
        anchor: anchor,
        errorText: (Object e) => _pluginActionError(manifest, e),
        actions: actions(),
      ),
    ),
  );
}

/// 专辑 / 歌单 / 艺人头部按钮行里平铺的「收藏 / 关注」切换按钮（`collect`）。
///
/// 收藏是这类页面的主动作，直接摆在按钮行里，不收进「更多」（用户 2026-11-06）。
/// 未收藏 = 描边「收藏 / 关注」，已收藏 = 色调「已收藏 / 已关注」、再点取消。
/// 状态以本次运行里改过的为准（[_pluginCollectedProvider]，卡片右键改的也算），
/// 没改过用页面加载时的 [collected]；未知（null）按未收藏显示：再收藏一次是幂等的。
class _PluginCollectToggle extends ConsumerStatefulWidget {
  const _PluginCollectToggle({
    super.key,
    required this.manifest,
    required this.type,
    required this.id,
    required this.collected,
  });

  final MusicPluginManifest manifest;
  final MusicPluginCollectType type;
  final String id;

  /// 页面加载时插件给的状态快照。
  final bool? collected;

  @override
  ConsumerState<_PluginCollectToggle> createState() =>
      _PluginCollectToggleState();
}

class _PluginCollectToggleState extends ConsumerState<_PluginCollectToggle> {
  bool _busy = false;

  bool get _artist => widget.type == MusicPluginCollectType.artist;

  Future<void> _set(bool on) async {
    setState(() => _busy = true);
    try {
      await _setPluginCollected(
        ref,
        widget.manifest,
        widget.type,
        widget.id,
        on: on,
      );
    } on Object catch (e) {
      FushiToast.show(
        msg: _pluginActionError(widget.manifest, e),
        severity: ToastSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool on =
        _pluginCollectedOf(
          ref.watch(_pluginCollectedProvider),
          widget.manifest,
          widget.type,
          widget.id,
          widget.collected,
        ) ??
        false;
    final VoidCallback? onPressed = _busy ? null : () => unawaited(_set(!on));
    final Widget button = on
        ? FushiFilledButton.tonalIcon(
            onPressed: onPressed,
            icon: FushiIcon(
              _artist ? FushiIcons.personCheck : FushiIcons.check,
            ),
            label: Text(
              _artist ? t.music_action_followed : t.music_action_collected,
            ),
          )
        : FushiOutlinedButton.icon(
            onPressed: onPressed,
            icon: FushiIcon(
              _artist ? FushiIcons.personAdd : FushiIcons.libraryAdd,
            ),
            label: Text(
              _artist ? t.music_action_follow : t.music_action_collect,
            ),
          );
    return FushiTooltip(
      message: on
          ? (_artist ? t.music_action_unfollow : t.music_action_uncollect)
          : (_artist ? t.music_action_follow : t.music_action_collect),
      child: FushiPressScale(child: button),
    );
  }
}

/// 艺人页按钮行里的「关注」切换；插件没有 `collect` 时为空。
List<Widget> _pluginFollowActions(
  MusicPluginManifest manifest,
  String artistId, {
  required bool? followed,
}) {
  if (!manifest.can(MusicPluginCapability.collect)) return const <Widget>[];
  return <Widget>[
    _PluginCollectToggle(
      key: const ValueKey<String>('music-plugin-artist-follow'),
      manifest: manifest,
      type: MusicPluginCollectType.artist,
      id: artistId,
      collected: followed,
    ),
  ];
}

/// 专辑 / 歌单页按钮行里平铺的动作：别人的专辑 / 歌单给「收藏」切换；自己的歌单给「删除歌单」
/// （删完退出页面）。没有可做的动作时回空列表。
List<Widget> _pluginCollectionActions(
  BuildContext context,
  WidgetRef ref,
  MusicPluginManifest manifest, {
  MusicPluginAlbum? album,
  MusicPluginPlaylist? playlist,
  required bool? collected,
}) {
  final bool own =
      playlist != null &&
      playlist.editable &&
      manifest.can(MusicPluginCapability.playlistEdit);
  if (own) {
    return <Widget>[
      FushiPressScale(
        child: FushiOutlinedButton.icon(
          key: const ValueKey<String>('music-plugin-playlist-delete'),
          onPressed: () =>
              unawaited(_deleteOwnPlaylist(context, ref, manifest, playlist)),
          icon: const FushiIcon(FushiIcons.delete),
          label: Text(t.music_action_delete_playlist),
        ),
      ),
    ];
  }
  // 自己建的歌单不需要「收藏」。
  if (!manifest.can(MusicPluginCapability.collect)) return const <Widget>[];
  return <Widget>[
    _PluginCollectToggle(
      key: const ValueKey<String>('music-plugin-collection-collect'),
      manifest: manifest,
      type: album != null
          ? MusicPluginCollectType.album
          : MusicPluginCollectType.playlist,
      id: album?.id ?? playlist!.id,
      collected: collected,
    ),
  ];
}

Future<void> _deleteOwnPlaylist(
  BuildContext context,
  WidgetRef ref,
  MusicPluginManifest manifest,
  MusicPluginPlaylist playlist,
) async {
  final bool ok = await showFushiConfirmDialog(
    context: context,
    title: t.music_action_delete_playlist,
    message: t.music_action_delete_playlist_confirm(name: playlist.title),
    icon: FushiIcons.delete,
    destructive: true,
  );
  if (!ok) return;
  try {
    await _sourceOf(ref, manifest.id).deletePlaylist(playlist.id);
  } on Object catch (e) {
    FushiToast.show(
      msg: _pluginActionError(manifest, e),
      severity: ToastSeverity.error,
    );
    return;
  }
  FushiToast.show(
    msg: t.music_action_playlist_deleted(name: playlist.title),
    severity: ToastSeverity.success,
  );
  if (context.mounted) Navigator.of(context).maybePop();
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
