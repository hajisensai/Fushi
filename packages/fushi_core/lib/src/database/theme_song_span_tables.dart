import 'package:drift/drift.dart';

// ── video_theme_song_spans（schema v131，作品图谱 L2）──────────────────────
//
// docs/specs/2026-10-24-cross-media-links.md §2：音乐库里有某作品的 OP / ED（作品图谱
// `media_links` 的 `theme_song` 连接）时，用声纹在该作品每集音轨上滑窗比对，得到每集
// OP / ED 的起止。这张表是**比对结果的按集缓存**。
//
// 为什么新开一张表而不复用既有结构：
// - 视频章节来自容器（mpv `chapter-list`），没有持久化表可写；
// - `video_metadata_episodes` 是刮削骨架（季 / 集号 / AniDB），一个文件可绑多条、一条也
//   可不绑任何文件，挂不住「这个文件里第几秒是 OP」；
// - `video_file_specs` 是 ffprobe 探测缓存，一行一文件、列是固定规格字段，塞进
//   「文件 × 曲目」的多行结果要改它的主键。
//
// 身份是 `(book_uid, episode_index, track_uid)`，不是文件路径：
// - `VideoBooks` 一行可能是多集播放列表，`episode_index` 是 `playlist_json` 里的下标
//   （单文件为 0），与视频页 `currentEpisode` 同语义；
// - 不存路径就不进数据根迁移的路径改写清单；文件被换掉由 [fileSizeBytes] /
//   [fileModifiedAt] 判失效（与 `video_file_specs` 同一组判据），列表重排后下标对应的
//   文件变了，同样因为大小 / 时刻对不上而失效、重算，不会张冠李戴；
// - [detectorVersion] = `fushi_music` 的声纹算法版本（`ffm_fp_version`），算法或判据
//   改了整表自然失效。
//
// **纯缓存**：所有行都能由重新比对算出来。设备本地（不进备份 / 同步）：两台设备的文件
// 可能是不同片源（BD / TV 版 OP 位置不同）。删视频时 `deleteVideoBooks` 同事务清掉。
//
// 没命中也写一行（[startMs] 为 NULL）：否则每次打开合集都会把没有 OP 的那几集重新解码一遍
// （一集 BD 原盘音轨解码约 20 s）。
@DataClassName('VideoThemeSongSpanRow')
class VideoThemeSongSpans extends Table {
  /// `video_books.book_uid`。**没有外键**：设备本地表在覆盖恢复后按
  /// `INSERT … SELECT * FROM devbak` 原样回灌，挂外键会让「备份里已没有这部视频」的
  /// 一行把整批设备本地表的回灌打断。删视频时由 `deleteVideoBooks` 同事务清掉。
  TextColumn get bookUid => text()();

  /// 播放列表下标（单文件视频为 0）。
  IntColumn get episodeIndex => integer()();

  /// 音乐曲目 `music_tracks.track_uid`（逻辑外键：曲库重扫按 uid upsert）。
  TextColumn get trackUid => text()();

  /// 比对当时的视频文件大小 / 修改时刻（毫秒）：失效判据。
  IntColumn get fileSizeBytes => integer()();
  IntColumn get fileModifiedAt => integer()();

  /// 声纹算法版本：失效判据。
  IntColumn get detectorVersion => integer()();

  /// 这首歌在这一集里的起止（毫秒，视频时间轴）。NULL = 比对过、没出现。
  IntColumn get startMs => integer().nullable()();
  IntColumn get endMs => integer().nullable()();

  /// 声纹对齐置信度 0..1（没出现时 NULL）。
  RealColumn get confidence => real().nullable()();

  IntColumn get detectedAt => integer()();

  @override
  Set<Column> get primaryKey => <Column>{bookUid, episodeIndex, trackUid};

  @override
  List<String> get customConstraints => <String>[
    'CHECK ((start_ms IS NULL) = (end_ms IS NULL))',
    'CHECK (start_ms IS NULL OR end_ms > start_ms)',
  ];
}
