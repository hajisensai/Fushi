/// 「从音乐库移除」的共用收尾：带「撤销」的完成提示，以及远程曲目（YouTube / 插件 / 服务器
/// 曲目）移出曲库的唯一写路径。单首菜单、多选条、服务器专辑 / 艺人整体移除都走这里。
///
/// - 移出：[MusicServerDownloadIndex.removeTracksFromLibrary]——先记「移出」（在跑的下载下完
///   也不加回曲库），清入库时刻，取消在跑 / 停着的下载（删半成品）。
/// - 撤销：按原入库时刻放回（元数据原样写回）。
/// - 离线副本（v173）只在撤销窗口过去之后删（[MusicRemoteLibraryRemoval.commit]）：撤销期间
///   文件留着，撤销后照旧离线可放；撤销窗口里进程被杀 = 没提交，下次启动对账把曲目放回曲库。
library;

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart'
    show musicRemoteTrackCompanionOfRow;
import 'package:fushi/src/media/music/server/music_server_download_index.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiSnackBar;
import 'package:fushi/src/utils/misc/fushi_toast.dart';

int _now() => DateTime.now().millisecondsSinceEpoch;

/// 完成提示 + 「撤销」：有 [messenger] 时走 SnackBar（带撤销钮），没有（独立弹窗等）退回
/// 普通 toast（撤销不可达，本地曲目仍可在「已移除的曲目」页恢复）。
///
/// [onCommitted]：撤销窗口过去（提示没被点「撤销」就关了，或根本没有撤销钮）后才做的、撤销
/// 不了的收尾（删服务器曲目的离线副本文件）。
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

/// 一次远程曲目移出曲库的撤销与提交。
typedef MusicRemoteLibraryRemoval = ({
  /// 按原入库时刻放回。
  Future<void> Function() undo,

  /// 撤销窗口过去后：删这些曲目里服务器曲目的离线副本（行 + 文件）。
  Future<void> Function() commit,
});

/// 把 [rows]（移出前读到的、在库的远程曲目行）移出音乐库，返回撤销 / 提交两步。不出提示：
/// 调用方把它们交给 [musicShowUndoableNotice]（或 [musicRemoveRemoteTracksWithUndo]）。
Future<MusicRemoteLibraryRemoval> musicRemoveRemoteTracksFromLibrary(
  FushiDatabase db,
  List<MusicRemoteTrackRow> rows, {
  int? at,
  MusicServerDownloadIndex? index,
}) async {
  final MusicServerDownloadIndex idx =
      index ?? MusicServerDownloadIndex.instance;
  final List<String> uids = <String>[
    for (final MusicRemoteTrackRow r in rows) r.trackUid,
  ];
  await idx.removeTracksFromLibrary(db, uids, at: at ?? _now());
  return (
    undo: () async {
      for (final MusicRemoteTrackRow r in rows) {
        await db.upsertMusicRemoteTrack(
          musicRemoteTrackCompanionOfRow(
            r,
          ).copyWith(libraryAddedAt: Value<int?>(r.libraryAddedAt)),
          at: _now(),
        );
      }
    },
    commit: () async {
      if (uids.isEmpty) return;
      await idx.dropDownloadsOutsideLibrary(uids);
    },
  );
}

/// 移出一批远程曲目（按 uid；不在库 / 没有行的跳过）并出带「撤销」的提示。[messenger] 必须在
/// 调用方的第一个 await 之前取（菜单动作跑完时菜单可能已经卸载）。[message] 按实际移出的
/// 首数给文案。返回移出的首数。
Future<int> musicRemoveRemoteTracksWithUndo(
  ScaffoldMessengerState? messenger,
  FushiDatabase db,
  Iterable<String> trackUids, {
  required String Function(int count) message,
  MusicServerDownloadIndex? index,
}) async {
  final List<MusicRemoteTrackRow> rows = <MusicRemoteTrackRow>[
    for (final MusicRemoteTrackRow r in (await db.listMusicRemoteTracks(
      trackUids,
    )).values)
      if (r.libraryAddedAt != null) r,
  ];
  if (rows.isEmpty) return 0;
  final MusicRemoteLibraryRemoval removal =
      await musicRemoveRemoteTracksFromLibrary(db, rows, index: index);
  musicShowUndoableNotice(
    messenger,
    message(rows.length),
    removal.undo,
    onCommitted: removal.commit,
  );
  return rows.length;
}
