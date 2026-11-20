/// 视频库「加入收听」：把视频交给音乐播放器只放声音（拍板台 oo_8_5z6Aw，反馈
/// oo_8_5z6Aw「播放列表 · 后台听 · 随机播放 · 被动收听」，维护者 2026-11-17「按照a来做」）。
///
/// 方案 A：不另起一个播放引擎、不加新的前台服务类型。视频按曲库收音乐来源里视频容器
/// 的同一条路径当 MV 收进音乐库（[MusicAudioIntake.importMusicFiles] →「仅此一次」导入
/// / 重扫覆盖它的音乐来源，`music_local_video.dart`），音乐引擎只放音轨（libmpv
/// `vid=no`）——队列、随机播放、后台媒体会话 / 锁屏控制、睡眠定时、歌单全是现成的。
/// 收听列表就是音乐库「歌单」区里的本地歌单（混放视频与歌曲），不新增主导航页签；
/// 想看画面时曲目菜单里的「观看 MV」回到视频播放页（同一个文件复用视频库那一行）。
///
/// 入口在视频库：单集菜单、合集菜单与多选批量栏都有「加入收听」，选随机播放 / 下一首
/// 播放 / 加入播放队列 / 加入歌单。音乐是可关闭的模块：没开时先提示一键开启（维护者
/// 选的入口方案 A），不在视频页签里另放一个只读入口。
library;

import 'dart:math';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_extensions.dart'
    show isAudioOnlyMediaPath, isVideoMediaPath;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_audio_intake.dart';
import 'package:fushi/src/media/music/music_library_data.dart'
    show musicPlayItemOf;
import 'package:fushi/src/media/music/music_local_video.dart'
    show isMusicLocalFilePath;
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/music/music_local_playlist_actions.dart'
    show MusicLocalPlaylistEditor;
import 'package:fushi/src/pages/implementations/music/music_track_actions.dart'
    show musicAddToPlaylist;
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 「加入收听」之后放到哪儿。
enum MusicListenTarget {
  /// 用这些条目替换播放队列并随机播放。
  shuffle,

  /// 插到当前曲之后。
  playNext,

  /// 排到队尾。
  queue,

  /// 加进本地歌单（选已有 / 新建）——这就是长期的「收听列表」。
  playlist,
}

/// 能交给音乐播放器只放声音的路径：本机绝对路径上的视频容器（或纯音频）。网络流
/// （`https://…`）、`.strm`、播放列表清单、原盘目录 / 蓝光分集虚拟路径都不算——曲库按
/// 本机文件入库，音乐引擎也只认文件。按首次出现的顺序去重（同一个文件按
/// [musicTrackPathKey] 认）。纯函数，不碰文件系统。
List<String> musicListenablePaths(Iterable<String> paths) {
  final Set<String> seen = <String>{};
  final List<String> out = <String>[];
  for (final String raw in paths) {
    final String path = raw.trim();
    if (!isMusicLocalFilePath(path)) continue;
    if (!isVideoMediaPath(path) && !isAudioOnlyMediaPath(path)) continue;
    if (seen.add(musicTrackPathKey(path))) out.add(path);
  }
  return out;
}

/// 把 [paths] 对成曲库曲目（[library] 是在库曲目），保持 [paths] 的顺序；还不在曲库里
/// 的路径进 `missing`。同一个文件按 [musicTrackPathKey] 认（Windows 上大小写 / 分隔符
/// 不同的拼法是同一首）；一个文件对出多条（CUE 整轨）时按起点顺序全收。纯函数。
({List<MusicTrackRow> tracks, List<String> missing}) musicTracksForPaths(
  List<String> paths,
  List<MusicTrackRow> library,
) {
  final Map<String, List<MusicTrackRow>> byKey =
      <String, List<MusicTrackRow>>{};
  for (final MusicTrackRow t in library) {
    byKey
        .putIfAbsent(musicTrackPathKey(t.path), () => <MusicTrackRow>[])
        .add(t);
  }
  final List<MusicTrackRow> tracks = <MusicTrackRow>[];
  final List<String> missing = <String>[];
  for (final String path in paths) {
    final List<MusicTrackRow>? hit = byKey[musicTrackPathKey(path)];
    if (hit == null || hit.isEmpty) {
      missing.add(path);
      continue;
    }
    tracks.addAll(
      List<MusicTrackRow>.of(hit)..sort(
        (MusicTrackRow a, MusicTrackRow b) =>
            (a.cueStartMs ?? 0).compareTo(b.cueStartMs ?? 0),
      ),
    );
  }
  return (tracks: tracks, missing: missing);
}

/// 视频库「加入收听」该不该出：至少有一条能只放声音的本机文件。纯函数。
bool musicListenAvailableFor(Iterable<String> videoPaths) =>
    musicListenablePaths(videoPaths).isNotEmpty;

/// 音乐模块没开时提示一键开启；用户拒绝回 false。
Future<bool> _ensureMusicModule(BuildContext context, AppModel appModel) async {
  if (appModel.moduleEnabled(ModuleId.music)) return true;
  final bool ok = await showFushiConfirmDialog(
    context: context,
    title: t.video_listen_enable_music_title,
    message: t.video_listen_enable_music_message,
    icon: FushiIcons.music,
    confirmLabel: t.video_listen_enable_music_confirm,
    cancelLabel: t.cancel,
  );
  if (!ok) return false;
  await appModel.setModuleEnabled(ModuleId.music, true);
  return true;
}

Future<MusicListenTarget?> _pickTarget(
  BuildContext context,
  MusicPlayerEngine engine,
  int count,
) {
  // 与音乐库多选的「接着播 / 加入队列」同一判据：当前项由后端自管队列（电台等）时
  // 插不进去，不画点了没反应的两项。
  final bool queueEditable = engine.queue.isEmpty || engine.canEditQueue;
  return showFushiChoiceDialog<MusicListenTarget>(
    context: context,
    title: t.video_listen_title(n: count),
    message: t.video_listen_message,
    icon: FushiIcons.audiobook,
    options: <FushiChoiceOption<MusicListenTarget>>[
      FushiChoiceOption<MusicListenTarget>(
        value: MusicListenTarget.shuffle,
        label: t.music_shuffle_play,
        icon: FushiIcons.shuffle,
      ),
      if (queueEditable) ...<FushiChoiceOption<MusicListenTarget>>[
        FushiChoiceOption<MusicListenTarget>(
          value: MusicListenTarget.playNext,
          label: t.music_queue_play_next,
          icon: FushiIcons.skipNext,
        ),
        FushiChoiceOption<MusicListenTarget>(
          value: MusicListenTarget.queue,
          label: t.music_queue_add,
          icon: FushiIcons.add,
        ),
      ],
      FushiChoiceOption<MusicListenTarget>(
        value: MusicListenTarget.playlist,
        label: t.music_action_add_to_playlist,
        icon: FushiIcons.playlist,
      ),
    ],
  );
}

/// 确保 [paths] 都在曲库里（缺的经 [MusicAudioIntake.importMusicFiles] 收进来），返回
/// 按 [paths] 顺序的曲目。一条都没收进来且有入库错误时抛 [StateError]（带第一条错误）。
Future<List<MusicTrackRow>> _ensureInMusicLibrary(
  FushiDatabase db,
  List<String> paths,
) async {
  final ({List<MusicTrackRow> tracks, List<String> missing}) first =
      musicTracksForPaths(paths, await db.listMusicTracks());
  if (first.missing.isEmpty) return first.tracks;
  final MusicAudioIntakeResult r = await MusicAudioIntake(
    db,
  ).importMusicFiles(first.missing);
  final ({List<MusicTrackRow> tracks, List<String> missing}) after =
      musicTracksForPaths(paths, await db.listMusicTracks());
  if (after.tracks.isEmpty && r.errors.isNotEmpty) {
    throw StateError(r.errors.first);
  }
  return after.tracks;
}

/// 视频库「加入收听」的完整流程：（音乐模块没开时先提示开启）→ 选放到哪儿 → 收进
/// 曲库 → 交给音乐播放器 / 加进歌单。[videoPaths] 按用户看到的顺序（加歌单、加队列时
/// 照这个顺序排）。
Future<void> musicListenToVideos(
  BuildContext context, {
  required AppModel appModel,
  required List<String> videoPaths,
}) async {
  final List<String> paths = musicListenablePaths(videoPaths);
  if (paths.isEmpty) {
    FushiToast.show(
      msg: t.video_listen_no_local_files,
      severity: ToastSeverity.warning,
    );
    return;
  }
  if (!await _ensureMusicModule(context, appModel) || !context.mounted) {
    return;
  }
  final MusicPlayerEngine engine = appModel.musicPlayerEngine;
  final MusicListenTarget? target = await _pickTarget(
    context,
    engine,
    paths.length,
  );
  if (target == null || !context.mounted) return;

  final FushiDatabase db = appModel.database;
  final List<MusicTrackRow> tracks;
  try {
    tracks = await _ensureInMusicLibrary(db, paths);
  } on StateError catch (e) {
    FushiToast.show(
      msg: t.video_listen_import_failed(error: e.message),
      severity: ToastSeverity.error,
    );
    return;
  }
  if (tracks.isEmpty) {
    FushiToast.show(
      msg: t.video_listen_no_local_files,
      severity: ToastSeverity.warning,
    );
    return;
  }
  if (!context.mounted) return;

  final List<MusicPlayItem> items = <MusicPlayItem>[
    for (final MusicTrackRow track in tracks) musicPlayItemOf(track),
  ];
  switch (target) {
    case MusicListenTarget.shuffle:
      await engine.playQueue(
        items,
        startIndex: Random().nextInt(items.length),
        shuffle: true,
      );
    case MusicListenTarget.playNext:
      await engine.playNext(items);
      FushiToast.show(
        msg: t.music_selection_queued_next(n: items.length),
        severity: ToastSeverity.success,
      );
    case MusicListenTarget.queue:
      await engine.addToQueue(items);
      FushiToast.show(
        msg: t.music_selection_added_to_queue(n: items.length),
        severity: ToastSeverity.success,
      );
    case MusicListenTarget.playlist:
      await musicAddToPlaylist(context, MusicLocalPlaylistEditor(db), <String>[
        for (final MusicTrackRow track in tracks) track.trackUid,
      ]);
  }
}
