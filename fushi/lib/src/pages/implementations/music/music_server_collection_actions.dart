/// 服务器专辑 / 艺人整体「加入 / 移出音乐库」与离线下载（Jellyfin / Subsonic）。
///
/// - 入库：逐曲落 `music_remote_tracks`（[musicServerRemoteTrackCompanion]，与单曲「加入音乐库」
///   同一条路径），整批在一个事务里（[FushiDatabase.addMusicRemoteTracksToLibrary]）。状态按这批
///   曲目里在库的个数算「全部 / 部分 / 都不在」，随任何写路径实时更新（Drift watch）。
/// - 移出：只清入库时刻，在跑的下载随之取消；提示带「撤销」，离线副本等撤销窗口过去再删
///   （下载 ⊂ 音乐库，[musicRemoveRemoteTracksWithUndo]）。
/// - 下载：[MusicServerDownloadService]（进度 / 暂停 / 重试在下载中心；这里的按钮同时显示进度、
///   可取消，iOS 没有下载中心也停得下来）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/server/music_server_download_index.dart';
import 'package:fushi/src/media/music/server/music_server_downloads.dart';
import 'package:fushi/src/pages/implementations/music/music_library_removal.dart'
    show musicRemoveRemoteTracksWithUndo;
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart'
    show FushiButtonSize;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiFilledButton;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

int _now() => DateTime.now().millisecondsSinceEpoch;

/// 一批曲目在音乐库 / 离线副本里的覆盖程度。
enum MusicServerCoverage { none, partial, all }

/// [have] / [total] → 覆盖程度（空集合算「都不在」）。
MusicServerCoverage musicServerCoverageOf(int have, int total) {
  if (total == 0 || have <= 0) return MusicServerCoverage.none;
  return have >= total ? MusicServerCoverage.all : MusicServerCoverage.partial;
}

/// 这批服务器曲目的播放身份（与入库行 / 离线副本同一个 uid）。
List<String> musicServerTrackUids(
  MusicServerBrowser browser,
  Iterable<MusicServerTrack> tracks,
) => <String>[
  for (final MusicServerTrack t in tracks)
    musicServerTrackUid(browser.serverId, t.id),
];

/// 这批曲目的入库行；不能入库的来源回空。[albumTitleOf] 给出每首的专辑名（专辑页传专辑名，
/// 艺人页按各专辑传）。
List<MusicRemoteTracksCompanion> musicServerLibraryRowsOf(
  MusicServerBrowser browser,
  Iterable<MusicServerTrack> tracks, {
  String? Function(MusicServerTrack track)? albumTitleOf,
}) => <MusicRemoteTracksCompanion>[
  for (final MusicServerTrack t in tracks)
    ?musicServerRemoteTrackCompanion(
      browser,
      t,
      albumTitle: albumTitleOf?.call(t),
    ),
];

/// 整批加入音乐库（一个事务，已在库的不改入库时刻），提示加了几首。
Future<void> musicServerAddTracksToLibrary(
  FushiDatabase db,
  MusicServerBrowser browser,
  List<MusicServerTrack> tracks, {
  String? Function(MusicServerTrack track)? albumTitleOf,
}) async {
  final List<MusicRemoteTracksCompanion> rows = musicServerLibraryRowsOf(
    browser,
    tracks,
    albumTitleOf: albumTitleOf,
  );
  if (rows.isEmpty) return;
  await db.addMusicRemoteTracksToLibrary(rows, at: _now());
  FushiToast.show(
    msg: t.music_server_library_added_count(count: rows.length),
    severity: ToastSeverity.success,
  );
}

/// 整批移出音乐库（只清入库时刻），提示带「撤销」（按原入库时刻放回）；在跑的下载随之取消，
/// 离线副本等撤销窗口过去再删。[messenger] 由调用方在第一个 await 之前取。
Future<void> musicServerRemoveTracksFromLibrary(
  ScaffoldMessengerState? messenger,
  FushiDatabase db,
  MusicServerBrowser browser,
  List<MusicServerTrack> tracks, {
  MusicServerDownloadIndex? index,
}) async {
  final List<String> uids = musicServerTrackUids(browser, tracks);
  if (uids.isEmpty) return;
  await musicRemoveRemoteTracksWithUndo(
    messenger,
    db,
    uids,
    message: (int n) => t.music_server_library_removed_count(count: n),
    index: index,
  );
}

/// 当前 app 的下载编排；库没就绪（[db] 为 null）/ 这台服务器不支持下载原文件时回 null。
/// 库由调用方给（本文件不读 AppModel：不把它接进 import 大环）。
MusicServerDownloadService? musicServerDownloadServiceOf(
  BuildContext context,
  FushiDatabase? db,
  MusicServerBrowser browser,
) {
  if (db == null || !MusicServerDownloadService.supports(browser)) return null;
  return MusicServerDownloadService.forApp(
    downloads: ProviderScope.containerOf(
      context,
      listen: false,
    ).read(interconnectDownloadManagerProvider),
    db: db,
  );
}

/// 下载一批（单首直接发起；多首成批串行），提示已开始。不等下载结束。
Future<void> musicServerDownloadTracks(
  MusicServerDownloadService service,
  MusicServerBrowser browser,
  List<MusicServerTrack> tracks, {
  required String batchTitle,
  required String scope,
  required String scopeId,
  MusicServerAlbum? album,
}) async {
  if (tracks.isEmpty) return;
  if (tracks.length == 1) {
    final MusicServerDownloadStart outcome = await service.download(
      browser,
      tracks.single,
      album: album,
    );
    FushiToast.show(
      msg: switch (outcome) {
        MusicServerDownloadStart.started => t.music_download_started,
        MusicServerDownloadStart.alreadyRunning =>
          t.music_download_already_running,
        MusicServerDownloadStart.alreadyDownloaded =>
          t.music_download_already_done,
        MusicServerDownloadStart.unsupported =>
          t.music_server_download_unsupported,
      },
      severity: outcome == MusicServerDownloadStart.unsupported
          ? ToastSeverity.warning
          : ToastSeverity.success,
    );
    return;
  }
  FushiToast.show(
    msg: t.music_download_all_started(count: tracks.length),
    severity: ToastSeverity.success,
  );
  // 整批串行跑完才返回；结果以各首的任务状态为准（下载中心可见、可重试）。
  unawaited(
    service
        .downloadAll(
          browser,
          tracks,
          batchId: musicServerDownloadBatchId(browser.serverId, scope, scopeId),
          batchTitle: batchTitle,
          album: album,
        )
        .then((_) {}, onError: (Object _) {}),
  );
}

/// 取消这批里正在下 / 停着的下载（删掉半成品）。
Future<void> musicServerCancelDownloads(
  InterconnectDownloadManager manager,
  Iterable<String> trackUids,
) async {
  for (final String uid in trackUids) {
    await manager.cancel(musicServerDownloadTaskId(uid));
  }
}

/// 删掉这批的离线副本（曲目仍在音乐库里，之后串流），提示删了几首。
Future<void> musicServerRemoveDownloads(
  MusicServerDownloadService service,
  Iterable<String> trackUids,
) async {
  final int n = await service.removeDownloads(trackUids);
  FushiToast.show(
    msg: t.music_server_download_removed(count: n),
    severity: ToastSeverity.success,
  );
}

/// 一批曲目此刻的下载进度（只看有任务的；没有在跑的回 null）。
InterconnectDownloadAggregate? musicServerRunningDownloads(
  InterconnectDownloadManager manager,
  Iterable<String> trackUids,
) {
  final InterconnectDownloadAggregate? agg = manager.aggregateFor(<String>[
    for (final String uid in trackUids) musicServerDownloadTaskId(uid),
  ]);
  return agg != null && agg.isRunning ? agg : null;
}

/// 一批服务器曲目（整张专辑 / 一位艺人的全部专辑）的入库 + 下载动作，按当前状态给：
/// 不全在库 → 加入（部分在库时写「把其余曲目加入」）；有在库的 → 移出；有服务就给下载 /
/// 下载其余 / 取消 / 删除下载。
List<MusicMenuAction> musicServerCollectionActions({
  required FushiDatabase db,
  required MusicServerBrowser browser,
  required List<MusicServerTrack> tracks,
  required Set<String> libraryUids,
  required String batchTitle,
  required String scope,
  required String scopeId,
  MusicServerDownloadService? downloads,
  MusicServerAlbum? album,
  String? Function(MusicServerTrack track)? albumTitleOf,
  MusicServerDownloadIndex? index,
}) {
  final MusicServerDownloadIndex idx =
      index ?? MusicServerDownloadIndex.instance;
  if (!musicServerKindStorable(browser.kind)) return const <MusicMenuAction>[];
  final List<String> uids = musicServerTrackUids(browser, tracks);
  final MusicServerCoverage library = musicServerCoverageOf(
    uids.where(libraryUids.contains).length,
    uids.length,
  );
  final List<MusicServerTrack> notDownloaded = <MusicServerTrack>[
    for (int i = 0; i < tracks.length; i++)
      if (!idx.isDownloaded(uids[i])) tracks[i],
  ];
  final MusicServerCoverage downloaded = musicServerCoverageOf(
    tracks.length - notDownloaded.length,
    tracks.length,
  );
  final InterconnectDownloadManager? manager = downloads?.downloads;
  final bool running =
      manager != null && musicServerRunningDownloads(manager, uids) != null;
  return <MusicMenuAction>[
    if (library != MusicServerCoverage.all)
      MusicMenuAction(
        id: 'serverCollectionAddToLibrary',
        label: library == MusicServerCoverage.none
            ? t.music_action_add_to_library
            : t.music_server_library_add_rest,
        icon: FushiIcons.libraryAdd,
        run: (_) => musicServerAddTracksToLibrary(
          db,
          browser,
          tracks,
          albumTitleOf: albumTitleOf,
        ),
      ),
    if (library != MusicServerCoverage.none)
      MusicMenuAction(
        id: 'serverCollectionRemoveFromLibrary',
        label: t.music_action_remove_from_library,
        icon: FushiIcons.close,
        run: (BuildContext context) => musicServerRemoveTracksFromLibrary(
          ScaffoldMessenger.maybeOf(context),
          db,
          browser,
          tracks,
          index: idx,
        ),
      ),
    if (downloads != null && running)
      MusicMenuAction(
        id: 'serverCollectionCancelDownload',
        label: t.music_server_download_cancel,
        icon: FushiIcons.cancel,
        run: (_) => musicServerCancelDownloads(downloads.downloads, uids),
      )
    else if (downloads != null && downloaded != MusicServerCoverage.all)
      MusicMenuAction(
        id: 'serverCollectionDownload',
        label: downloaded == MusicServerCoverage.none
            ? t.music_action_download
            : t.music_server_download_rest,
        icon: FushiIcons.download,
        run: (_) => musicServerDownloadTracks(
          downloads,
          browser,
          notDownloaded,
          batchTitle: batchTitle,
          scope: scope,
          scopeId: scopeId,
          album: album,
        ),
      ),
    if (downloads != null && downloaded != MusicServerCoverage.none)
      MusicMenuAction(
        id: 'serverCollectionRemoveDownload',
        label: t.music_server_download_remove,
        icon: FushiIcons.delete,
        run: (_) => musicServerRemoveDownloads(downloads, uids),
      ),
  ];
}

/// 单首服务器曲目的下载动作（曲目菜单并进去）：下载 / 取消下载 / 删除下载。
List<MusicMenuAction> musicServerTrackDownloadActions(
  MusicServerDownloadService? downloads,
  MusicServerBrowser browser,
  MusicServerTrack track, {
  String? albumTitle,
}) {
  if (downloads == null) return const <MusicMenuAction>[];
  final String uid = musicServerTrackUid(browser.serverId, track.id);
  final String taskId = musicServerDownloadTaskId(uid);
  if (downloads.downloads.isRunning(taskId)) {
    return <MusicMenuAction>[
      MusicMenuAction(
        id: 'serverTrackCancelDownload',
        label: t.music_server_download_cancel,
        icon: FushiIcons.cancel,
        run: (_) =>
            musicServerCancelDownloads(downloads.downloads, <String>[uid]),
      ),
    ];
  }
  if (downloads.index.isDownloaded(uid)) {
    return <MusicMenuAction>[
      MusicMenuAction(
        id: 'serverTrackRemoveDownload',
        label: t.music_server_download_remove,
        icon: FushiIcons.delete,
        run: (_) => musicServerRemoveDownloads(downloads, <String>[uid]),
      ),
    ];
  }
  return <MusicMenuAction>[
    MusicMenuAction(
      id: 'serverTrackDownload',
      label: t.music_action_download,
      icon: FushiIcons.download,
      run: (_) => musicServerDownloadTracks(
        downloads,
        browser,
        <MusicServerTrack>[track],
        batchTitle: track.title,
        scope: 'track',
        scopeId: track.id,
        album: albumTitle == null
            ? null
            : MusicServerAlbum(id: track.albumId ?? '', title: albumTitle),
      ),
    ),
  ];
}

/// 专辑 / 艺人页头部的两颗状态按钮：入库（「加入音乐库」/「已在音乐库」/「已在音乐库：3 / 10
/// 首」）与下载（「下载」/「下载中 40%」/「已下载」/「已下载：3 / 10 首」）。都不在 / 没下时点一下
/// 直接做；其余状态点开菜单（加入其余 / 移出、下载其余 / 取消 / 删除下载）。状态随写路径实时
/// 更新：入库看 Drift watch，下载看进程内索引与下载管理器。
class MusicServerCollectionButtons extends ConsumerStatefulWidget {
  const MusicServerCollectionButtons({
    super.key,
    required this.db,
    required this.browser,
    required this.tracks,
    required this.title,
    required this.scope,
    required this.scopeId,
    this.album,
    this.albumTitleOf,
  });

  /// 用户库（库没就绪为 null：不画）。
  final FushiDatabase? db;
  final MusicServerBrowser browser;
  final List<MusicServerTrack> tracks;

  /// 下载中心的批标题（专辑名 / 艺人名）。
  final String title;

  /// 批键的作用域（`album` / `artist`）与 id。
  final String scope;
  final String scopeId;
  final MusicServerAlbum? album;
  final String? Function(MusicServerTrack track)? albumTitleOf;

  @override
  ConsumerState<MusicServerCollectionButtons> createState() =>
      _MusicServerCollectionButtonsState();
}

class _MusicServerCollectionButtonsState
    extends ConsumerState<MusicServerCollectionButtons> {
  late List<String> _uids = musicServerTrackUids(widget.browser, widget.tracks);
  Stream<Set<String>>? _library;

  @override
  void didUpdateWidget(MusicServerCollectionButtons old) {
    super.didUpdateWidget(old);
    if (!identical(old.tracks, widget.tracks) ||
        !identical(old.db, widget.db) ||
        old.browser.serverId != widget.browser.serverId) {
      _uids = musicServerTrackUids(widget.browser, widget.tracks);
      _library = null;
    }
  }

  void _openMenu(
    BuildContext context,
    FushiDatabase db,
    MusicServerDownloadService? downloads,
    Set<String> inLibrary,
  ) => unawaited(
    showMusicActionMenu(
      context,
      errorText: (Object e) => t.music_action_failed(error: '$e'),
      actions: musicServerCollectionActions(
        db: db,
        browser: widget.browser,
        tracks: widget.tracks,
        libraryUids: inLibrary,
        batchTitle: widget.title,
        scope: widget.scope,
        scopeId: widget.scopeId,
        downloads: downloads,
        album: widget.album,
        albumTitleOf: widget.albumTitleOf,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final FushiDatabase? db = widget.db;
    if (db == null ||
        !musicServerKindStorable(widget.browser.kind) ||
        widget.tracks.isEmpty) {
      return const SizedBox.shrink();
    }
    final MusicServerDownloadService? downloads = musicServerDownloadServiceOf(
      context,
      db,
      widget.browser,
    );
    final InterconnectDownloadManager manager = ref.watch(
      interconnectDownloadManagerProvider,
    );
    final Stream<Set<String>> library = _library ??= db
        .watchMusicRemoteLibraryUidsOf(_uids);
    return StreamBuilder<Set<String>>(
      stream: library,
      builder: (BuildContext context, AsyncSnapshot<Set<String>> snap) {
        final Set<String> inLibrary = snap.data ?? const <String>{};
        final int have = _uids.where(inLibrary.contains).length;
        final MusicServerCoverage coverage = musicServerCoverageOf(
          have,
          _uids.length,
        );
        final Widget libraryButton = FushiPressScale(
          child: FushiFilledButton.tonalIcon(
            key: const ValueKey<String>('music-server-collection-library'),
            size: FushiButtonSize.m,
            onPressed: !snap.hasData
                ? null
                : coverage == MusicServerCoverage.none
                ? () => unawaited(
                    musicServerAddTracksToLibrary(
                      db,
                      widget.browser,
                      widget.tracks,
                      albumTitleOf: widget.albumTitleOf,
                    ),
                  )
                : () => _openMenu(context, db, downloads, inLibrary),
            icon: FushiIcon(
              coverage == MusicServerCoverage.all
                  ? FushiIcons.check
                  : FushiIcons.libraryAdd,
            ),
            label: Text(switch (coverage) {
              MusicServerCoverage.none => t.music_action_add_to_library,
              MusicServerCoverage.partial =>
                t.music_server_library_state_partial(
                  have: have,
                  total: _uids.length,
                ),
              MusicServerCoverage.all => t.music_server_library_state_all,
            }),
          ),
        );
        if (downloads == null) return libraryButton;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            libraryButton,
            ListenableBuilder(
              listenable: downloads.index,
              builder: (BuildContext context, _) {
                final InterconnectDownloadAggregate? running =
                    musicServerRunningDownloads(manager, _uids);
                final int done = downloads.index.countDownloaded(_uids);
                final MusicServerCoverage dl = musicServerCoverageOf(
                  done,
                  _uids.length,
                );
                final bool startDirectly =
                    running == null &&
                    dl == MusicServerCoverage.none &&
                    snap.hasData;
                return FushiPressScale(
                  child: FushiFilledButton.tonalIcon(
                    key: const ValueKey<String>(
                      'music-server-collection-download',
                    ),
                    size: FushiButtonSize.m,
                    onPressed: startDirectly
                        ? () => unawaited(
                            musicServerDownloadTracks(
                              downloads,
                              widget.browser,
                              widget.tracks,
                              batchTitle: widget.title,
                              scope: widget.scope,
                              scopeId: widget.scopeId,
                              album: widget.album,
                            ),
                          )
                        : () => _openMenu(context, db, downloads, inLibrary),
                    icon: running != null
                        ? SizedBox.square(
                            dimension: 18,
                            child: FushiCircularProgressIndicator(
                              strokeWidth: 2,
                              value: running.progress,
                            ),
                          )
                        : FushiIcon(
                            dl == MusicServerCoverage.all
                                ? FushiIcons.downloadDone
                                : FushiIcons.download,
                          ),
                    label: Text(
                      running != null
                          ? t.music_server_download_state_running(
                              percent: (running.progress * 100).round(),
                            )
                          : switch (dl) {
                              MusicServerCoverage.none =>
                                t.music_action_download,
                              MusicServerCoverage.partial =>
                                t.music_server_download_state_partial(
                                  have: done,
                                  total: _uids.length,
                                ),
                              MusicServerCoverage.all =>
                                t.music_server_download_state_all,
                            },
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

/// 曲目行上的离线状态角标：下载中是进度环，有离线副本是「已下载」图标，都没有不画。
class MusicServerTrackDownloadBadge extends ConsumerWidget {
  const MusicServerTrackDownloadBadge({
    super.key,
    required this.browser,
    required this.track,
  });

  final MusicServerBrowser browser;
  final MusicServerTrack track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!MusicServerDownloadService.supports(browser)) {
      return const SizedBox.shrink();
    }
    final String uid = musicServerTrackUid(browser.serverId, track.id);
    final InterconnectDownloadManager manager = ref.watch(
      interconnectDownloadManagerProvider,
    );
    return ListenableBuilder(
      listenable: MusicServerDownloadIndex.instance,
      builder: (BuildContext context, _) {
        final InterconnectDownloadTask? task =
            manager.tasks[musicServerDownloadTaskId(uid)];
        if (task != null && task.isRunning) {
          return Semantics(
            label: t.music_server_download_state_running(
              percent: ((task.progress ?? 0) * 100).round(),
            ),
            child: SizedBox.square(
              key: ValueKey<String>('music-server-track-downloading-$uid'),
              dimension: 14,
              child: FushiCircularProgressIndicator(
                strokeWidth: 2,
                value: task.progress,
              ),
            ),
          );
        }
        if (!MusicServerDownloadIndex.instance.isDownloaded(uid)) {
          return const SizedBox.shrink();
        }
        return Tooltip(
          message: t.music_server_download_state_all,
          child: FushiIcon(
            FushiIcons.downloadDone,
            key: ValueKey<String>('music-server-track-downloaded-$uid'),
            size: 16,
            semanticLabel: t.music_server_download_state_all,
          ),
        );
      },
    );
  }
}
