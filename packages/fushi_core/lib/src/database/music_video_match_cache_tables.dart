import 'package:drift/drift.dart';

// ── music_video_prints / music_video_match_checks（schema v173）────────────────
//
// 本地 MV 自动匹配（曲目 ↔ 附近视频 / 蓝光流的声纹对齐）的两张缓存：让「一个视频一辈子
// 只解码一次、一对（歌, 视频）只对齐一次」。
//
// - `music_video_prints`：视频音轨的声纹（Chromaprint 原始 u32 序列，小端字节），键是
//   本机路径；文件大小 / 修改时刻变了即失效重算（与 `video_content_fingerprints` 同一组
//   判据）。专辑十首歌对同一张盘时，盘里每条流只解码一次。
// - `music_video_match_checks`：某首歌已经和某个视频文件（按大小 + 修改时刻认版本）对齐
//   过——没对上也记，文件不变就不再对。手动「找本地 MV」不看这张表（强制重对）。
//
// **纯缓存**、设备本地（不进备份 / 同步 / 合并导入）：内容全由本机文件算出，路径与
// track_uid 都是本机的。无外键，删曲目 / 删文件留下的孤行只是用不上的缓存。
@DataClassName('MusicVideoPrintRow')
class MusicVideoPrints extends Table {
  /// 视频文件的本机绝对路径。
  TextColumn get path => text()();

  /// 算声纹当时的文件大小（字节），失效判据。
  IntColumn get fileSizeBytes => integer()();

  /// 算声纹当时的文件修改时刻（毫秒），失效判据。
  IntColumn get fileModifiedAt => integer()();

  /// 声纹：u32 序列按小端存成字节。
  BlobColumn get print => blob()();

  /// 本行写入时刻（毫秒）。
  IntColumn get computedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{path};
}

@DataClassName('MusicVideoMatchCheckRow')
class MusicVideoMatchChecks extends Table {
  /// `music_tracks.track_uid`（无外键，见文件头）。
  TextColumn get trackUid => text()();

  /// 对过的视频文件本机路径。
  TextColumn get videoPath => text()();

  /// 对齐当时视频文件的大小（字节）：文件换了就要重对。
  IntColumn get fileSizeBytes => integer()();

  /// 对齐当时视频文件的修改时刻（毫秒）。
  IntColumn get fileModifiedAt => integer()();

  /// 对齐时刻（毫秒）。
  IntColumn get checkedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{trackUid, videoPath};
}
