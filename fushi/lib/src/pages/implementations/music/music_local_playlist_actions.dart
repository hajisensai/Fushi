/// 本地歌单与「加入音乐库」的动作（v148，反馈 0tRY-D2JgG）。
///
/// - [MusicLocalPlaylistEditor]：本地歌单的 [MusicPlaylistEditor]，选歌单 / 新建歌单的流程、
///   提示文案与在线来源共用 [musicAddToPlaylist]；
/// - 远程曲目（YouTube / 在线插件，判据 `music_remote_tracks.dart`）的「加入音乐库 / 从音乐库
///   移除 / 加入本地歌单」：远程曲目行与歌单条目在同一个事务里落库；
/// - 合规门：YouTube / 插件曲目的这些入口只在 [musicRemoteTracksAvailable] 时出现（iOS 上
///   不存在）；
/// - 服务器曲目（Jellyfin / Subsonic，v149，反馈 se3Fw8HmOX）：服务器曲目菜单同样有「加入
///   音乐库 / 加入本地歌单」，落库的只有服务器配置身份 + 条目 id + 元数据
///   （[musicServerRemoteTrackCompanion]），不受上面的合规门约束。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart'
    show musicServerPlayItem;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

int _now() => DateTime.now().millisecondsSinceEpoch;

/// 本地歌单（`music_playlists`，智能歌单不算可加歌的）。[remote] 是这次要加的曲目里远程
/// 曲目的元数据：加歌 / 新建时同事务落库，歌单条目永远解析得到。
class MusicLocalPlaylistEditor implements MusicPlaylistEditor {
  MusicLocalPlaylistEditor(
    this.db, {
    this.remote = const <MusicRemoteTracksCompanion>[],
    int Function()? clock,
  }) : _clock = clock ?? _now;

  final FushiDatabase db;
  final List<MusicRemoteTracksCompanion> remote;
  final int Function() _clock;

  @override
  Future<List<MusicPlaylistTarget>> editablePlaylists() async {
    final Map<String, int> counts = await db.countMusicPlaylistEntries();
    return <MusicPlaylistTarget>[
      for (final MusicPlaylistRow p in await db.listMusicPlaylists())
        if (p.rulesJson == null)
          MusicPlaylistTarget(
            id: p.playlistUid,
            title: p.name,
            trackCount: counts[p.playlistUid] ?? 0,
          ),
    ];
  }

  @override
  Future<MusicPlaylistTarget> createPlaylist(
    String name, {
    List<String> trackIds = const <String>[],
  }) async {
    final MusicPlaylistRow p = await db.createMusicPlaylist(
      name,
      at: _clock(),
      trackUids: trackIds,
      remote: remote,
    );
    return MusicPlaylistTarget(
      id: p.playlistUid,
      title: p.name,
      trackCount: trackIds.length,
    );
  }

  @override
  Future<void> addToPlaylist(String playlistId, List<String> trackIds) =>
      db.addMusicPlaylistEntries(
        playlistId,
        trackIds,
        at: _clock(),
        remote: remote,
      );
}

/// 把播放项加进本地歌单（选 / 新建）。远程曲目在门没过的平台上被滤掉；全被滤掉时什么都
/// 不做、回 false。用户取消也回 false。
Future<bool> musicAddItemsToLocalPlaylist(
  BuildContext context,
  FushiDatabase db,
  List<MusicPlayItem> items,
) {
  final List<String> uids = <String>[];
  final List<MusicRemoteTracksCompanion> remote =
      <MusicRemoteTracksCompanion>[];
  for (final MusicPlayItem item in items) {
    final MusicRemoteTracksCompanion? r = musicRemoteTrackCompanionOf(item);
    if (r != null) {
      if (!musicRemoteTracksAvailable) continue;
      remote.add(r);
    }
    uids.add(item.trackUid);
  }
  if (uids.isEmpty) return Future<bool>.value(false);
  return musicAddToPlaylist(
    context,
    MusicLocalPlaylistEditor(db, remote: remote),
    uids,
  );
}

/// 远程曲目加入音乐库（已在库只刷新元数据）。不是远程曲目 / 门没过时抛 [StateError]。
Future<void> musicAddRemoteItemToLibrary(
  FushiDatabase db,
  MusicPlayItem item,
) async {
  final MusicRemoteTracksCompanion? r = musicRemoteTrackCompanionOf(item);
  if (r == null || !musicRemoteTracksAvailable) {
    throw StateError('not a remote track: ${item.path}');
  }
  await musicAddRemoteTrackToLibrary(db, r);
}

/// 一行远程曲目加入音乐库（已在库只刷新元数据）。调用方负责种类 / 平台判据。
Future<void> musicAddRemoteTrackToLibrary(
  FushiDatabase db,
  MusicRemoteTracksCompanion track,
) async {
  await db.addMusicRemoteTrackToLibrary(track, at: _now());
  FushiToast.show(
    msg: t.music_action_added_to_library,
    severity: ToastSeverity.success,
  );
}

/// 远程曲目移出音乐库（行留着：歌单可能还引用它）。
Future<void> musicRemoveRemoteTrackFromLibrary(
  FushiDatabase db,
  String trackUid,
) async {
  await db.removeMusicRemoteTrackFromLibrary(trackUid, at: _now());
  FushiToast.show(
    msg: t.music_action_removed_from_library,
    severity: ToastSeverity.success,
  );
}

/// 远程曲目的「加入 / 移出音乐库」「加入本地歌单」两项菜单动作；不是远程曲目或门没过回空。
/// [inLibrary] 是打开菜单时读到的入库状态。[playlistLabel] 用于与来源账号歌单并列时区分
/// （插件菜单里已有「加入歌单」= 账号歌单，这里就写「加入本地歌单」）。
List<MusicMenuAction> musicRemoteLibraryActions(
  FushiDatabase db,
  MusicPlayItem item, {
  required bool inLibrary,
  String? playlistLabel,
}) {
  if (!musicRemoteTracksAvailable || !musicItemIsRemoteTrack(item)) {
    return const <MusicMenuAction>[];
  }
  return musicRemoteTrackLibraryActions(
    db,
    musicRemoteTrackCompanionOf(item)!,
    inLibrary: inLibrary,
    playlistLabel: playlistLabel,
  );
}

/// 一行远程曲目（YouTube / 插件 / 服务器曲目）的「加入 / 移出音乐库」「加入本地歌单」。
/// 不做种类 / 平台判据：调用方只在这一种在本平台可用时调用（[musicRemoteKindAvailable]）。
List<MusicMenuAction> musicRemoteTrackLibraryActions(
  FushiDatabase db,
  MusicRemoteTracksCompanion track, {
  required bool inLibrary,
  String? playlistLabel,
}) => <MusicMenuAction>[
  if (inLibrary)
    MusicMenuAction(
      id: 'removeFromLibrary',
      label: t.music_action_remove_from_library,
      icon: FushiIcons.close,
      run: (_) => musicRemoveRemoteTrackFromLibrary(db, track.trackUid.value),
    )
  else
    MusicMenuAction(
      id: 'addToLibrary',
      label: t.music_action_add_to_library,
      icon: FushiIcons.libraryAdd,
      run: (_) => musicAddRemoteTrackToLibrary(db, track),
    ),
  MusicMenuAction(
    id: 'addToLocalPlaylist',
    label: playlistLabel ?? t.music_action_add_to_playlist,
    icon: FushiIcons.playlist,
    run: (BuildContext c) async {
      await musicAddToPlaylist(
        c,
        MusicLocalPlaylistEditor(
          db,
          remote: <MusicRemoteTracksCompanion>[track],
        ),
        <String>[track.trackUid.value],
      );
    },
  ),
];

/// 搜索结果里一首远程曲目（YouTube 内置音源）的菜单：加入 / 移出音乐库、加入歌单。
/// 不是远程曲目或门没过回 null（行尾不留空位）。
MusicItemMenu? musicRemoteSearchTrackMenu(
  BuildContext context,
  FushiDatabase db,
  MusicPlayItem item,
) {
  if (!musicRemoteTracksAvailable || !musicItemIsRemoteTrack(item)) {
    return null;
  }
  return MusicItemMenu(
    buttonKey: ValueKey<String>('music-remote-track-menu-${item.trackUid}'),
    open: (MusicMenuAnchor? anchor) =>
        unawaited(_showRemoteSearchMenu(context, db, item, anchor: anchor)),
  );
}

Future<void> _showRemoteSearchMenu(
  BuildContext context,
  FushiDatabase db,
  MusicPlayItem item, {
  MusicMenuAnchor? anchor,
}) async {
  // 右键坐标只在同步派发期间可读：第一个 await 之前取好。
  final MusicMenuAnchor? at = anchor ?? musicContextMenuAnchor();
  final bool inLibrary =
      (await db.getMusicRemoteTrack(item.trackUid))?.libraryAddedAt != null;
  if (!context.mounted) return;
  await showMusicActionMenu(
    context,
    anchor: at,
    errorText: (Object e) => t.music_action_failed(error: '$e'),
    actions: musicRemoteLibraryActions(db, item, inLibrary: inLibrary),
  );
}

/// 服务器来源曲目行（服务器页 / 统一搜索 / 来源搜索页）的「加入音乐库 / 本地歌单」菜单：
/// YouTube 内置音源走占位路径的远程曲目；Jellyfin / Subsonic 走服务器曲目
/// （[musicServerTrackLibraryActions]）。Apple Music 有自己的菜单；能改歌单的服务器
/// （Jellyfin）的曲目菜单由 `musicServerTrackMenu` 出、把这几项并进去。其它来源回 null。
MusicItemMenu? musicServerTrackLibraryMenu(
  BuildContext context,
  MusicServerBrowser browser,
  MusicServerTrack track, {
  String? albumTitle,
}) {
  final AppModel app = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appProvider);
  if (!app.isDatabaseReady) return null;
  if (browser.kind == MusicServerKind.youtube) {
    return musicRemoteSearchTrackMenu(
      context,
      app.database,
      musicServerPlayItem(browser, track),
    );
  }
  if (musicServerRemoteTrackCompanion(browser, track) == null) return null;
  return MusicItemMenu(
    buttonKey: ValueKey<String>('music-server-library-menu-${track.id}'),
    open: (MusicMenuAnchor? anchor) => unawaited(() async {
      // 右键坐标只在同步派发期间可读：第一个 await 之前取好。
      final MusicMenuAnchor? at = anchor ?? musicContextMenuAnchor();
      final List<MusicMenuAction> actions =
          await musicServerTrackLibraryActions(
            app.database,
            browser,
            track,
            albumTitle: albumTitle,
          );
      if (!context.mounted) return;
      await showMusicActionMenu(
        context,
        anchor: at,
        errorText: (Object e) => t.music_action_failed(error: '$e'),
        actions: actions,
      );
    }()),
  );
}

/// Jellyfin / Subsonic 曲目的「加入 / 移出音乐库」「加入本地歌单」（读一次入库状态）；
/// 不能入库的来源回空。[playlistLabel] 与服务器账号歌单并列时传「加入本地歌单」。
Future<List<MusicMenuAction>> musicServerTrackLibraryActions(
  FushiDatabase db,
  MusicServerBrowser browser,
  MusicServerTrack track, {
  String? albumTitle,
  String? playlistLabel,
}) async {
  final MusicRemoteTracksCompanion? row = musicServerRemoteTrackCompanion(
    browser,
    track,
    albumTitle: albumTitle,
  );
  if (row == null) return const <MusicMenuAction>[];
  final bool inLibrary =
      (await db.getMusicRemoteTrack(row.trackUid.value))?.libraryAddedAt !=
      null;
  return musicRemoteTrackLibraryActions(
    db,
    row,
    inLibrary: inLibrary,
    playlistLabel: playlistLabel,
  );
}
