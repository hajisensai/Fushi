/// 下载入库的发布里随附的纯音频（BD 附带的 CD / OST / 特典 CD）交给音乐库。
///
/// 视频来源扫描会把扫到的纯音频交给音乐库（[MusicAudioIntakePort.adoptVideoSourceAudio]），
/// 但下载任务入库不走来源扫描：视频来源没开自动扫描时，新下载的发布里的 CD 永远进不了
/// 音乐库（用户库实况：MyGO OST、孤独摇滚 BD 附带 CD 都没进库）。这里给下载管线的
/// `onReleaseAudioImported` 钩子用，规划规则与来源扫描**同一份**（`music_audio_roots.dart`），
/// 只是「视频库认领的媒体目录」从库里该来源的视频行取，而不是重扫整个来源。
///
/// 不对账（`reconcile: false`）：这里只看到一个来源的库内视频行，不是来源根下的完整扫描
/// 结果，撤销自动来源只能由完整扫描凭正面证据做。
library;

import 'dart:io';

import 'package:fushi/src/media/music/music_audio_intake_port.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 一个视频行路径对应的「视频库媒体目录」：原盘流 / 播放列表（`…/BDMV/STREAM/x.m2ts`、
/// `…/BDMV/PLAYLIST/x.mpls`）算盘根（`BDMV` 的上一级，与扫描器的 `discRootPath` 同口径），
/// 其余算文件所在目录。纯函数。
String videoMediaDirOfLibraryPath(String videoPath, {p.Context? context}) {
  final p.Context ctx = context ?? p.context;
  final List<String> parts = ctx.split(ctx.normalize(videoPath));
  for (int i = parts.length - 2; i >= 1; i--) {
    if (parts[i].toUpperCase() == 'BDMV') {
      return ctx.joinAll(parts.sublist(0, i));
    }
  }
  return ctx.dirname(ctx.normalize(videoPath));
}

/// 把下载任务 [audioPaths]（本机绝对路径）交给音乐库，归属记为受管视频来源 [source]。
/// 磁盘上已不在的文件（任务被搬走 / 删掉）跳过；全都不在就什么也不做。
Future<MusicAudioIntakeResult> adoptDownloadedReleaseAudio({
  required FushiDatabase db,
  required MusicAudioIntakePort intake,
  required MediaSourceRow source,
  required List<String> audioPaths,
  bool Function(String path)? fileExists,
}) async {
  if (source.transport != 'local') return const MusicAudioIntakeResult();
  final bool Function(String path) exists =
      fileExists ?? ((String path) => File(path).existsSync());
  final List<String> audio = <String>[
    for (final String path in audioPaths)
      if (exists(path)) path,
  ];
  if (audio.isEmpty) return const MusicAudioIntakeResult();
  final List<String> videoFiles = <String>[];
  final Set<String> mediaDirs = <String>{};
  for (final VideoBookRow row in await db.allVideoBooks()) {
    if (row.sourceId != source.id) continue;
    final String path = row.videoPath;
    if (path.contains('://')) continue;
    mediaDirs.add(videoMediaDirOfLibraryPath(path));
    if (!path.toUpperCase().contains('${p.separator}BDMV${p.separator}')) {
      videoFiles.add(path);
    }
  }
  return intake.adoptVideoSourceAudio(
    owner: source,
    audioPaths: audio,
    videoMediaDirs: mediaDirs,
    videoFilePaths: videoFiles,
  );
}

/// 下载管线把滞留的外挂件从原发布目录搬走后（[movedFromPaths] 是搬走前的路径）：
/// 早先被当纯音频收进音乐库的那些文件现在不在原处了，重扫它们所在的音乐来源，
/// 让扫描按「文件已不在」对账掉曲目（每个来源一次）。返回重扫的来源数。
Future<int> rescanMusicSourcesOfMovedFiles({
  required FushiDatabase db,
  required List<String> movedFromPaths,
  required Future<void> Function(MediaSourceRow source) rescan,
}) async {
  final Set<String> moved = <String>{
    for (final String path in movedFromPaths) musicTrackPathKey(path),
  };
  final Set<int> sourceIds = <int>{
    for (final MusicTrackRow t in await db.listMusicTracks())
      if (t.deletedAt == null &&
          t.sourceId != null &&
          moved.contains(musicTrackPathKey(t.path)))
        t.sourceId!,
  };
  int done = 0;
  for (final int id in sourceIds) {
    final MediaSourceRow? source = await db.getMediaSourceById(id);
    if (source == null) continue;
    await rescan(source);
    done++;
  }
  return done;
}
