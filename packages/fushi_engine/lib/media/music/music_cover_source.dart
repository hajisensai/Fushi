/// 本地曲目 / 专辑用哪张封面（BUG-5300）：app 的曲目行、专辑页、详情页、首页速览与互联 host
/// （`EngineMusicLibraryHost.cover`）共用这一条规则——
/// 专辑的目录封面（[MusicAlbumRow.coverPath]）优先，其次专辑选定的内嵌封面曲目
/// （[MusicAlbumRow.coverTrackUid]），那首查不到时退回这首自己的内嵌封面；都没有为两个 null。
library;

import 'package:fushi_core/fushi_core.dart';

/// 封面来源：目录 / 远程封面路径，或「从这个音频文件读内嵌封面」。
typedef MusicCoverSource = ({String? coverPath, String? embeddedFromPath});

/// 纯规则：[albumEmbeddedPath] 是 [MusicAlbumRow.coverTrackUid] 那首的路径（调用方已查好，查不到为 null）。
MusicCoverSource musicCoverSourceOf({
  MusicTrackRow? track,
  MusicAlbumRow? album,
  String? albumEmbeddedPath,
}) {
  final String? dirCover = album?.coverPath;
  return (
    coverPath: dirCover == null || dirCover.isEmpty ? null : dirCover,
    embeddedFromPath:
        albumEmbeddedPath ??
        (track != null && track.hasEmbeddedCover ? track.path : null),
  );
}

/// 专辑选定的内嵌封面曲目的路径（[MusicAlbumRow.coverTrackUid] → 路径；没有为 null）。
Future<String?> musicAlbumEmbeddedCoverPath(
  FushiDatabase db,
  MusicAlbumRow? album,
) async {
  final String? uid = album?.coverTrackUid;
  if (uid == null) return null;
  return (await db.getMusicTrack(uid))?.path;
}

/// 查库版：[track] 与它的 [album]（专辑页只给 [album]）。
Future<MusicCoverSource> loadMusicCoverSource(
  FushiDatabase db, {
  MusicTrackRow? track,
  MusicAlbumRow? album,
}) async => musicCoverSourceOf(
  track: track,
  album: album,
  albumEmbeddedPath: await musicAlbumEmbeddedCoverPath(db, album),
);
