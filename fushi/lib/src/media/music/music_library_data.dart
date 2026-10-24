/// 曲库页一次读出的快照 + 行 → 播放项的换算（纯 Dart，可单测）。
library;

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';

/// 曲库快照。
class MusicLibrarySnapshot {
  MusicLibrarySnapshot({
    required this.albums,
    required this.tracks,
    required this.artists,
    required this.playlists,
    List<MusicDiscSourceRow> discs = const <MusicDiscSourceRow>[],
  }) : albumByUid = <String, MusicAlbumRow>{
         for (final MusicAlbumRow a in albums) a.albumUid: a,
       },
       discByUid = <String, MusicDiscSourceRow>{
         for (final MusicDiscSourceRow d in discs) d.discUid: d,
       },
       _trackByUid = <String, MusicTrackRow>{
         for (final MusicTrackRow t in tracks) t.trackUid: t,
       };

  static final MusicLibrarySnapshot empty = MusicLibrarySnapshot(
    albums: const <MusicAlbumRow>[],
    tracks: const <MusicTrackRow>[],
    artists: const <MusicArtistRow>[],
    playlists: const <MusicPlaylistRow>[],
  );

  final List<MusicAlbumRow> albums;
  final List<MusicTrackRow> tracks;
  final List<MusicArtistRow> artists;
  final List<MusicPlaylistRow> playlists;
  final Map<String, MusicAlbumRow> albumByUid;

  /// 光盘来源（`music_disc_sources`）：盘是一张带 `DVD` / `BD` 角标的专辑（§9.2）。
  final Map<String, MusicDiscSourceRow> discByUid;

  /// 专辑的光盘来源；不是光盘专辑为 null。
  MusicDiscSourceRow? discOf(MusicAlbumRow album) {
    final String? uid = album.discUid;
    return uid == null ? null : discByUid[uid];
  }

  final Map<String, MusicTrackRow> _trackByUid;

  /// 曲库里什么都没有：没有曲目，也没有（还没导入章节的）光盘专辑。
  bool get isEmpty => tracks.isEmpty && albums.isEmpty;

  /// 专辑内嵌封面所在的音频文件（[MusicAlbumRow.coverTrackUid] → 路径）。
  String? embeddedCoverPathOf(MusicAlbumRow album) {
    final String? uid = album.coverTrackUid;
    return uid == null ? null : _trackByUid[uid]?.path;
  }

  /// 某张专辑的曲目，按碟号 / 轨号排。
  List<MusicTrackRow> tracksOfAlbum(String albumUid) =>
      sortAlbumTracks(<MusicTrackRow>[
        for (final MusicTrackRow t in tracks)
          if (t.albumUid == albumUid) t,
      ]);

  static Future<MusicLibrarySnapshot> load(FushiDatabase db) async =>
      MusicLibrarySnapshot(
        albums: await db.listMusicAlbums(),
        tracks: await db.listMusicTracks(),
        artists: await db.listMusicArtists(),
        playlists: await db.listMusicPlaylists(),
        discs: await db.listMusicDiscSources(),
      );
}

/// 专辑曲目排序：碟号 → 轨号 → CUE 起点 → 标题（缺号排后）。
List<MusicTrackRow> sortAlbumTracks(List<MusicTrackRow> tracks) {
  int cmpNullable(int? a, int? b) {
    if (a == b) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  return List<MusicTrackRow>.of(tracks)
    ..sort((MusicTrackRow a, MusicTrackRow b) {
      final int disc = cmpNullable(a.discNo, b.discNo);
      if (disc != 0) return disc;
      final int no = cmpNullable(a.trackNo, b.trackNo);
      if (no != 0) return no;
      final int cue = cmpNullable(a.cueStartMs, b.cueStartMs);
      if (cue != 0) return cue;
      return a.title.compareTo(b.title);
    });
}

/// 按碟号分组（专辑页「碟 1 / 碟 2」）。只有一碟（或都没碟号）时返回单组 key null。
Map<int?, List<MusicTrackRow>> groupTracksByDisc(List<MusicTrackRow> sorted) {
  final Map<int?, List<MusicTrackRow>> out = <int?, List<MusicTrackRow>>{};
  final Set<int?> discs = sorted.map((MusicTrackRow t) => t.discNo).toSet();
  if (discs.length <= 1) {
    out[null] = sorted;
    return out;
  }
  for (final MusicTrackRow t in sorted) {
    out.putIfAbsent(t.discNo, () => <MusicTrackRow>[]).add(t);
  }
  return out;
}

/// 曲目行 → 播放项。
MusicPlayItem musicPlayItemOf(
  MusicTrackRow track, {
  MusicAlbumRow? album,
  String? coverPath,
}) => MusicPlayItem(
  trackUid: track.trackUid,
  path: track.path,
  title: track.title,
  startMs: track.cueStartMs,
  endMs: track.cueEndMs,
  artist: track.artistCredit ?? album?.albumArtistCredit,
  album: album?.title,
  albumUid: track.albumUid,
  discNo: track.discNo,
  trackNo: track.trackNo,
  durationMs: track.durationMs,
  coverPath: coverPath ?? album?.coverPath,
  codec: track.codec,
  sampleRate: track.sampleRate,
  bitDepth: track.bitDepth,
  channels: track.channels,
  rgTrackGain: track.rgTrackGain,
  rgTrackPeak: track.rgTrackPeak,
  rgAlbumGain: track.rgAlbumGain,
  rgAlbumPeak: track.rgAlbumPeak,
);
