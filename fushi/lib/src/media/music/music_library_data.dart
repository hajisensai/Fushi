/// 曲库页一次读出的快照 + 行 → 播放项的换算（纯 Dart，可单测）。
library;

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';

/// 曲库快照。
class MusicLibrarySnapshot {
  MusicLibrarySnapshot({
    required this.albums,
    required this.tracks,
    required this.artists,
    required this.playlists,
    List<MusicDiscSourceRow> discs = const <MusicDiscSourceRow>[],
    this.remoteTracks = const <MusicRemoteTrackRow>[],
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

  /// 加入了音乐库的远程曲目（YouTube / 在线插件，最近加入的在前；v148）。合规门没过的平台
  /// 上恒为空（[load] 不读）。
  final List<MusicRemoteTrackRow> remoteTracks;

  /// 「歌曲」分区的条目：本地曲目在前，远程曲目随后（同一条队列）。快照不可变，算一次。
  late final List<MusicLibraryEntry> songEntries = <MusicLibraryEntry>[
    for (final MusicTrackRow t in tracks) MusicLocalEntry(t),
    for (final MusicRemoteTrackRow r in remoteTracks) MusicRemoteEntry(r),
  ];

  /// 光盘来源（`music_disc_sources`）：盘是一张带 `DVD` / `BD` 角标的专辑（§9.2）。
  final Map<String, MusicDiscSourceRow> discByUid;

  /// 专辑的光盘来源；不是光盘专辑为 null。
  MusicDiscSourceRow? discOf(MusicAlbumRow album) {
    final String? uid = album.discUid;
    return uid == null ? null : discByUid[uid];
  }

  final Map<String, MusicTrackRow> _trackByUid;

  /// 曲库里什么都没有：没有曲目，也没有（还没导入章节的）光盘专辑、加入的远程曲目与本地
  /// 歌单（歌单可以只装远程曲目，此时曲库没有一首本地曲目也不是空的）。
  bool get isEmpty =>
      tracks.isEmpty &&
      albums.isEmpty &&
      remoteTracks.isEmpty &&
      playlists.isEmpty;

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

  /// [remoteAvailable] 缺省按真实平台的合规门（[musicRemoteTracksAvailable]）。
  static Future<MusicLibrarySnapshot> load(
    FushiDatabase db, {
    bool? remoteAvailable,
  }) async => MusicLibrarySnapshot(
    albums: await db.listMusicAlbums(),
    tracks: await db.listMusicTracks(),
    artists: await db.listMusicArtists(),
    playlists: await db.listMusicPlaylists(),
    discs: await db.listMusicDiscSources(),
    remoteTracks: (remoteAvailable ?? musicRemoteTracksAvailable)
        ? await db.listMusicRemoteLibraryTracks()
        : const <MusicRemoteTrackRow>[],
  );
}

/// 曲库 / 歌单里的一首：本地曲库曲目，或只能串流的远程曲目（v148）。两者 uid 命名空间不同，
/// 播放项的 uid 就是这里的 [trackUid]。
sealed class MusicLibraryEntry {
  const MusicLibraryEntry();

  String get trackUid;
  String get title;
  String? get artist;
  int? get durationMs;

  /// 换成播放项；远程曲目的种类不认识（将来版本写的）时回 null。
  MusicPlayItem? playItem(Map<String, MusicAlbumRow> albums);
}

/// 本地曲库曲目。
final class MusicLocalEntry extends MusicLibraryEntry {
  const MusicLocalEntry(this.track);

  final MusicTrackRow track;

  @override
  String get trackUid => track.trackUid;
  @override
  String get title => track.title;
  @override
  String? get artist => track.artistCredit;
  @override
  int? get durationMs => track.durationMs;

  @override
  MusicPlayItem playItem(Map<String, MusicAlbumRow> albums) => musicPlayItemOf(
    track,
    album: track.albumUid == null ? null : albums[track.albumUid!],
  );
}

/// 远程曲目（YouTube / 在线插件）。
final class MusicRemoteEntry extends MusicLibraryEntry {
  const MusicRemoteEntry(this.track);

  final MusicRemoteTrackRow track;

  @override
  String get trackUid => track.trackUid;
  @override
  String get title => track.title;
  @override
  String? get artist => track.artist;
  @override
  int? get durationMs => track.durationMs;

  @override
  MusicPlayItem? playItem(Map<String, MusicAlbumRow> albums) =>
      musicPlayItemOfRemote(track);
}

/// 歌单里的一条：条目 id（删这一条用；同一首可以出现两次）+ 解析出的曲目。
class MusicPlaylistItem {
  const MusicPlaylistItem({required this.entryId, required this.entry});

  final int entryId;
  final MusicLibraryEntry entry;
}

/// 读一个本地歌单的条目并解析成曲目（按位置排）。解析不到的条目跳过、不删行：本地曲目
/// 在这台设备的曲库里没有（歌单来自别的设备的备份），或远程曲目在这个平台上不可用
/// （[remoteAvailable] 为 false，缺省按真实平台的合规门）。
Future<List<MusicPlaylistItem>> loadMusicPlaylistItems(
  FushiDatabase db,
  String playlistUid, {
  bool? remoteAvailable,
}) async {
  final List<MusicPlaylistEntryRow> rows = await db.listMusicPlaylistEntries(
    playlistUid,
  );
  final Iterable<String> uids = rows.map(
    (MusicPlaylistEntryRow r) => r.trackUid,
  );
  final Map<String, MusicTrackRow> local = await db.listMusicTracksByUid(uids);
  final Map<String, MusicRemoteTrackRow> remote =
      (remoteAvailable ?? musicRemoteTracksAvailable)
      ? await db.listMusicRemoteTracks(uids)
      : const <String, MusicRemoteTrackRow>{};
  return <MusicPlaylistItem>[
    for (final MusicPlaylistEntryRow r in rows)
      if (local[r.trackUid] case final MusicTrackRow t)
        MusicPlaylistItem(entryId: r.id, entry: MusicLocalEntry(t))
      else if (remote[r.trackUid] case final MusicRemoteTrackRow t
          when MusicRemoteTrackKind.fromWire(t.kind) != null)
        MusicPlaylistItem(entryId: r.id, entry: MusicRemoteEntry(t)),
  ];
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
  sourceId: track.sourceId,
);
