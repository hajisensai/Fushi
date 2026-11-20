/// 一张专辑在曲库里的多个版本（设计稿 M3 CD 详情：「库里有同一张专辑的多个版本
/// ——不同目录、不同格式——时按版本分开列，不混排」）。
///
/// 有专辑艺人标签的专辑按（专辑艺人, 专辑名）聚成一个专辑 uid（`native/fushi_music`
/// `uid.rs` 的 `album_uid`），同一张专辑的 FLAC 与 MP3 两份目录因此落在同一张专辑里。
/// 这里按曲目的版本目录（[musicTrackVersionDirectory]：分碟目录并回上一级）切开。
/// 纯函数，可单测。
library;

import 'package:fushi_core/fushi_core.dart' show MusicTrackRow;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/music_disc_art.dart'
    show isLocalMusicTrackPath, musicTrackVersionDirectory;
import 'package:fushi/src/media/music/music_library_data.dart'
    show groupTracksByDisc;

/// 专辑的一个版本：版本目录名（显示用）+ 该版本的曲目（保持传入顺序）。
class MusicAlbumVersion {
  const MusicAlbumVersion({required this.label, required this.tracks});

  /// 版本目录的名字；远程 / 无目录的曲目为空串。
  final String label;
  final List<MusicTrackRow> tracks;

  /// 该版本按碟号分组（只有一碟时单组 key null，见 [groupTracksByDisc]）。
  Map<int?, List<MusicTrackRow>> get discs => groupTracksByDisc(tracks);

  /// 该版本的总时长（毫秒；缺时长的曲目不计）。
  int get totalDurationMs => tracks.fold<int>(
    0,
    (int sum, MusicTrackRow t) => sum + (t.durationMs ?? 0),
  );
}

/// 把 [sortedTracks]（已按碟号 / 轨号排好）按版本目录切开，按首次出现的顺序。只有
/// 一个版本时返回单个元素。
List<MusicAlbumVersion> musicAlbumVersions(List<MusicTrackRow> sortedTracks) {
  final Map<String, List<MusicTrackRow>> byDir =
      <String, List<MusicTrackRow>>{};
  for (final MusicTrackRow t in sortedTracks) {
    final String key = isLocalMusicTrackPath(t.path)
        ? musicTrackVersionDirectory(t.path)
        : '';
    byDir.putIfAbsent(key, () => <MusicTrackRow>[]).add(t);
  }
  return <MusicAlbumVersion>[
    for (final MapEntry<String, List<MusicTrackRow>> e in byDir.entries)
      MusicAlbumVersion(
        label: e.key.isEmpty ? '' : p.basename(e.key),
        tracks: e.value,
      ),
  ];
}
