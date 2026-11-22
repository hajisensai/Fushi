// 曲目列表的多选与「从音乐库移除」（拍板台 IDeN5PYaI7，反馈 IDeN5PYaI7）。
//
// - 批量动作（[MusicTrackSelectionBar]）：接着播 / 加入队列 / 加入本地歌单 / 从这个歌单
//   移除（歌单页）/ 从音乐库移除；
// - 从音乐库移除：本地曲目写墓碑（`music_tracks.hidden_at`，schema v158）只从曲库隐藏、
//   **不碰磁盘文件**，重扫不复活；在库的远程曲目清入库时刻（原有语义）。移除与从歌单
//   批量移除都带「撤销」；本地曲目事后还能在「已移除的曲目」页恢复
//   （[MusicHiddenTracksPage]）。
part of 'music_track_list.dart';

int _selectionNow() => DateTime.now().millisecondsSinceEpoch;

/// 完成提示 + 「撤销」：有 [messenger] 时走 SnackBar（带撤销钮），没有（独立弹窗等）退回
/// 普通 toast（撤销不可达，本地曲目仍可在「已移除的曲目」页恢复）。
///
/// [onCommitted]：撤销窗口过去（提示没被点「撤销」就关了，或根本没有撤销钮）后才做的、撤销
/// 不了的收尾（删服务器曲目的离线副本文件，v172）。
void musicShowUndoableNotice(
  ScaffoldMessengerState? messenger,
  String message,
  Future<void> Function() undo, {
  Future<void> Function()? onCommitted,
}) {
  if (messenger == null) {
    FushiToast.show(msg: message, severity: ToastSeverity.success);
    if (onCommitted != null) unawaited(onCommitted());
    return;
  }
  messenger.hideCurrentSnackBar();
  final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> shown =
      messenger.showSnackBar(
        FushiSnackBar(
          content: Text(message),
          action: SnackBarAction(
            key: const ValueKey<String>('music-undo-action'),
            label: t.undo,
            onPressed: () => unawaited(undo()),
          ),
        ),
      );
  if (onCommitted != null) {
    unawaited(
      shown.closed.then((SnackBarClosedReason reason) async {
        if (reason != SnackBarClosedReason.action) await onCommitted();
      }),
    );
  }
}

/// [entries] 里能「从音乐库移除」的：本地曲目，以及在库、种类认得的远程曲目（只在歌单里
/// 的远程条目不在库，跳过）。
({List<String> local, List<MusicRemoteTrackRow> remote}) musicLibraryRemovable(
  Iterable<MusicLibraryEntry> entries,
) {
  final List<String> local = <String>[];
  final List<MusicRemoteTrackRow> remote = <MusicRemoteTrackRow>[];
  final Set<String> seen = <String>{};
  for (final MusicLibraryEntry e in entries) {
    if (!seen.add(e.trackUid)) continue;
    switch (e) {
      case MusicLocalEntry(:final MusicTrackRow track):
        local.add(track.trackUid);
      case final MusicRemoteEntry r:
        if (r.kind != null && r.track.libraryAddedAt != null) {
          remote.add(r.track);
        }
    }
  }
  return (local: local, remote: remote);
}

/// 从音乐库移除 [entries]：本地曲目写墓碑隐藏（磁盘文件不动、重扫不复活），在库的远程
/// 曲目清入库时刻。提示带「撤销」（本地取消隐藏、远程按原入库时刻放回）。返回移除的条数。
/// [notice] 换掉默认的「已移除 N 首」提示（整张专辑移除用）。
Future<int> musicRemoveEntriesFromLibrary(
  BuildContext context,
  FushiDatabase db,
  Iterable<MusicLibraryEntry> entries, {
  String? notice,
}) async {
  // 第一个 await 之前取：动作跑完时调用方（菜单 / 多选条）可能已经卸载。
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final ({List<String> local, List<MusicRemoteTrackRow> remote}) targets =
      musicLibraryRemovable(entries);
  final int count = targets.local.length + targets.remote.length;
  if (count == 0) return 0;
  final int at = _selectionNow();
  await db.hideMusicTracks(targets.local, at: at);
  for (final MusicRemoteTrackRow r in targets.remote) {
    await db.removeMusicRemoteTrackFromLibrary(r.trackUid, at: at);
  }
  musicShowUndoableNotice(
    messenger,
    notice ??
        (count == 1
            ? t.music_action_removed_from_library
            : t.music_selection_removed_from_library(n: count)),
    () async {
      await db.unhideMusicTracks(targets.local);
      for (final MusicRemoteTrackRow r in targets.remote) {
        await db.upsertMusicRemoteTrack(
          musicRemoteTrackCompanionOfRow(
            r,
          ).copyWith(libraryAddedAt: Value<int?>(r.libraryAddedAt)),
          at: _selectionNow(),
        );
      }
    },
    // 下载 ⊂ 音乐库：没撤销的话，移出曲库的服务器曲目连离线副本一起删（撤销期间文件留着，
    // 撤销后照旧离线可放）。
    onCommitted: targets.remote.isEmpty
        ? null
        : () => MusicServerDownloadIndex.instance.dropDownloadsOutsideLibrary(
            <String>[
              for (final MusicRemoteTrackRow r in targets.remote) r.trackUid,
            ],
          ),
  );
  return count;
}

/// 整张本地专辑「从音乐库移除」（拍板台 mmXVwo0Ibv）：走曲目批量移除同一条路径——
/// [tracks] 全部写墓碑隐藏、磁盘文件不动、重扫不复活；专辑没了在库曲目就从专辑墙消失。
/// 提示写明「磁盘上的文件不动」并带「撤销」，事后也能在「已移除的曲目」页逐首恢复。
/// 光盘专辑不走这里（整张盘的移除是 `removeMusicDiscFromLibrary`）。返回移除的曲目数。
Future<int> musicRemoveAlbumFromLibrary(
  BuildContext context,
  FushiDatabase db, {
  required MusicAlbumRow album,
  required List<MusicTrackRow> tracks,
}) => musicRemoveEntriesFromLibrary(context, db, <MusicLibraryEntry>[
  for (final MusicTrackRow tr in tracks) MusicLocalEntry(tr),
], notice: t.music_album_removed_from_library(title: album.title));

/// 从本地歌单 [playlist] 一次移除 [entryIds] 这几条，提示带「撤销」（按原位置放回）。
Future<int> musicRemoveEntriesFromPlaylist(
  BuildContext context,
  FushiDatabase db,
  MusicPlaylistRow playlist,
  Iterable<int> entryIds,
) async {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final List<MusicPlaylistEntryRow> removed = await db
      .removeMusicPlaylistEntries(
        playlist.playlistUid,
        entryIds,
        at: _selectionNow(),
      );
  if (removed.isEmpty) return 0;
  musicShowUndoableNotice(
    messenger,
    removed.length == 1
        ? t.music_action_removed_from_playlist(name: playlist.name)
        : t.music_selection_removed_from_playlist(
            n: removed.length,
            name: playlist.name,
          ),
    () => db.restoreMusicPlaylistEntries(
      playlist.playlistUid,
      removed,
      at: _selectionNow(),
    ),
  );
  return removed.length;
}

/// 把 [entries] 加进本地歌单（选 / 新建）：本地曲目按 uid，远程曲目连元数据同事务落库
/// （与单首「加入歌单」同一条路，[MusicLocalPlaylistEditor]）。用户取消回 false。
Future<bool> musicAddEntriesToLocalPlaylist(
  BuildContext context,
  FushiDatabase db,
  Iterable<MusicLibraryEntry> entries,
) {
  final List<String> uids = <String>[];
  final List<MusicRemoteTracksCompanion> remote =
      <MusicRemoteTracksCompanion>[];
  for (final MusicLibraryEntry e in entries) {
    switch (e) {
      case MusicLocalEntry():
        uids.add(e.trackUid);
      case final MusicRemoteEntry r:
        // 种类不认识（将来版本写的）的条目没法重建元数据，不加。
        if (r.kind == null) continue;
        remote.add(musicRemoteTrackCompanionOfRow(r.track));
        uids.add(e.trackUid);
    }
  }
  if (uids.isEmpty) return Future<bool>.value(false);
  return musicAddToPlaylist(
    context,
    MusicLocalPlaylistEditor(db, remote: remote),
    uids,
  );
}

/// 当前队列能不能插歌（空队列 / 可编辑的队列）；与单首菜单的「接着播 / 加入队列」同一判据。
bool musicQueueEditable(MusicPlayerEngine engine) =>
    engine.queue.isEmpty || engine.canEditQueue;

/// 选中的条目接在当前曲后面播（[next]）或排到队尾。换不成播放项的条目（这台设备上没配的
/// 服务器曲目等）跳过。
Future<void> musicQueueEntries(
  MusicPlayerEngine engine,
  Iterable<MusicLibraryEntry> entries,
  Map<String, MusicAlbumRow> albums, {
  required bool next,
}) async {
  final List<MusicPlayItem> items = <MusicPlayItem>[
    for (final MusicLibraryEntry e in entries)
      if (e.playItem(albums) case final MusicPlayItem item) item,
  ];
  if (items.isEmpty) return;
  if (next) {
    await engine.playNext(items);
  } else {
    await engine.addToQueue(items);
  }
  FushiToast.show(
    msg: next
        ? t.music_selection_queued_next(n: items.length)
        : t.music_selection_added_to_queue(n: items.length),
    severity: ToastSeverity.success,
  );
}

/// 多选态的底部动作条：已选数 + 全选 / 接着播 / 加入队列 / 加入歌单 / 从歌单移除 /
/// 从音乐库移除 / 退出。纯图标（文字进 tooltip 与无障碍名称），走共享
/// [FushiBottomActionBar]；null 回调的动作不出现（选空时动作按钮禁用，见 [count]）。
class MusicTrackSelectionBar extends StatelessWidget {
  const MusicTrackSelectionBar({
    super.key,
    required this.count,
    required this.onSelectAll,
    required this.onExit,
    this.onPlayNext,
    this.onAddToQueue,
    this.onAddToPlaylist,
    this.onRemoveFromPlaylist,
    this.onRemoveFromLibrary,
  });

  final int count;
  final VoidCallback onSelectAll;
  final VoidCallback onExit;
  final VoidCallback? onPlayNext;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onRemoveFromPlaylist;
  final VoidCallback? onRemoveFromLibrary;

  @override
  Widget build(BuildContext context) {
    final bool empty = count == 0;
    Widget action(
      String key,
      IconData icon,
      String tooltip,
      VoidCallback? on,
    ) => FushiIconButtonControl(
      key: ValueKey<String>(key),
      tooltip: tooltip,
      onPressed: empty ? null : on,
      icon: FushiIcon(icon),
    );
    return FushiBottomActionBar(
      key: const ValueKey<String>('music-selection-bar'),
      leading: Text(
        t.music_selection_count(n: count),
        key: const ValueKey<String>('music-selection-count'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: <Widget>[
        FushiIconButtonControl(
          key: const ValueKey<String>('music-selection-all'),
          tooltip: t.music_selection_select_all,
          onPressed: onSelectAll,
          icon: const FushiIcon(FushiIcons.selectAll),
        ),
        if (onPlayNext != null)
          action(
            'music-selection-play-next',
            FushiIcons.skipNext,
            t.music_queue_play_next,
            onPlayNext,
          ),
        if (onAddToQueue != null)
          action(
            'music-selection-add-to-queue',
            FushiIcons.add,
            t.music_queue_add,
            onAddToQueue,
          ),
        if (onAddToPlaylist != null)
          action(
            'music-selection-add-to-playlist',
            FushiIcons.playlist,
            t.music_action_add_to_playlist,
            onAddToPlaylist,
          ),
        if (onRemoveFromPlaylist != null)
          action(
            'music-selection-remove-from-playlist',
            FushiIcons.remove,
            t.music_action_remove_from_playlist,
            onRemoveFromPlaylist,
          ),
        if (onRemoveFromLibrary != null)
          action(
            'music-selection-remove-from-library',
            FushiIcons.removeCircle,
            t.music_action_remove_from_library,
            onRemoveFromLibrary,
          ),
        FushiIconButtonControl(
          key: const ValueKey<String>('music-selection-exit'),
          tooltip: t.music_selection_exit,
          onPressed: onExit,
          icon: const FushiIcon(FushiIcons.close),
        ),
      ],
    );
  }
}

/// [MusicTrackSelectionBar] 浮在屏幕底部的那一层（经 [OverlayPortal] 画进最近的
/// Overlay，与列表在页面里的位置无关——歌单页的列表是外层滚动里的一块）：限宽居中、
/// 让出底部安全区与悬浮播放条（读的是列表处的 MediaQuery），进出走
/// [FushiChromeReveal]（位移 + 淡入，减弱动态效果下瞬切；隐藏时不吃指针）。
/// MD3 下是一块圆角浮起的 surfaceContainer 面，Apple 由动作条自己画悬浮玻璃。
class MusicTrackSelectionBarHost extends StatelessWidget {
  const MusicTrackSelectionBarHost({
    super.key,
    required this.visible,
    required this.bar,
  });

  final bool visible;
  final Widget bar;

  @override
  Widget build(BuildContext context) {
    final Widget surface = isGlassDesign(context)
        ? bar
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              elevation: 3,
              shape: const RoundedRectangleBorder(
                borderRadius: FushiM3eShape.containerLargeRadius,
              ),
              clipBehavior: Clip.antiAlias,
              child: bar,
            ),
          );
    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: FushiChromeReveal(
            visible: visible,
            from: AxisDirection.down,
            child: surface,
          ),
        ),
      ),
    );
  }
}

/// 多选态行尾 / 色块角上的勾选圈（切换时按动效时长缩放）。
class MusicSelectionCheck extends StatelessWidget {
  const MusicSelectionCheck({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 48,
    child: Center(
      child: AnimatedSwitcher(
        duration: fushiMotionDuration(context, FushiMotion.short),
        switchInCurve: FushiMotion.enter,
        switchOutCurve: FushiMotion.exit,
        transitionBuilder: (Widget child, Animation<double> animation) =>
            ScaleTransition(scale: animation, child: child),
        child: ShelfSelectionCheck(
          key: ValueKey<bool>(selected),
          selected: selected,
        ),
      ),
    ),
  );
}

/// 「已移除的曲目」：从音乐库移除过的本地曲目（墓碑），逐首或全部恢复。磁盘上的文件
/// 一直没动过；文件已经不在的，恢复后下一次重扫照常软删。
class MusicHiddenTracksPage extends ConsumerWidget {
  const MusicHiddenTracksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FushiDatabase db = ref.read(appProvider).database;
    return StreamBuilder<List<MusicTrackRow>>(
      stream: db.watchHiddenMusicTracks(),
      builder: (BuildContext context, AsyncSnapshot<List<MusicTrackRow>> snap) {
        final List<MusicTrackRow>? rows = snap.data;
        return musicBrowseScaffold(
          context,
          title: t.music_hidden_tracks_title,
          actions: <FushiToolbarItem>[
            if (rows != null && rows.isNotEmpty)
              FushiToolbarItem(
                key: const ValueKey<String>('music-hidden-restore-all'),
                icon: FushiIcons.undo,
                label: t.music_hidden_tracks_restore_all,
                onPressed: () => unawaited(
                  _restore(<String>[
                    for (final MusicTrackRow r in rows) r.trackUid,
                  ], db),
                ),
              ),
          ],
          body: (BuildContext context) => rows == null
              ? const Center(child: FushiCircularProgressIndicator())
              : _body(context, db, rows),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    FushiDatabase db,
    List<MusicTrackRow> rows,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> children = <Widget>[
      Text(t.music_hidden_tracks_hint, style: context.fushiType.bodySmall),
      if (rows.isEmpty)
        FushiPlaceholderMessage(
          icon: FushiIcons.music,
          message: t.music_hidden_tracks_empty,
        )
      else
        for (int i = 0; i < rows.length; i++)
          FushiPressScale(
            child: FushiGroupedListItem(
              key: ValueKey<String>('music-hidden-${rows[i].trackUid}'),
              index: i,
              count: rows.length,
              child: FushiListItem(
                title: Text(
                  rows[i].title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  rows[i].path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: FushiIconButtonControl(
                  key: ValueKey<String>(
                    'music-hidden-restore-${rows[i].trackUid}',
                  ),
                  tooltip: t.music_hidden_tracks_restore,
                  onPressed: () =>
                      unawaited(_restore(<String>[rows[i].trackUid], db)),
                  icon: const FushiIcon(FushiIcons.undo),
                ),
              ),
            ),
          ),
    ];
    return FushiEntranceScope(
      child: ListView.builder(
        padding: musicBrowsePagePadding(context),
        itemCount: children.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int i) => Padding(
            padding: EdgeInsets.only(bottom: i == 0 ? tokens.spacing.gap : 0),
            child: children[i],
          ),
        ),
      ),
    );
  }

  static Future<void> _restore(List<String> uids, FushiDatabase db) async {
    final int n = await db.unhideMusicTracks(uids);
    if (n == 0) return;
    FushiToast.show(
      msg: t.music_hidden_tracks_restored(n: n),
      severity: ToastSeverity.success,
    );
  }
}
