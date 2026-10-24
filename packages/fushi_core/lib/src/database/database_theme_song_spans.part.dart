// OP / ED 声纹比对结果的按集缓存（v127，作品图谱 L2）。表语义见
// theme_song_span_tables.dart。
part of 'database.dart';

/// 一集视频里的一个缓存键（`episodeIndex` = 播放列表下标，单文件为 0）。
typedef ThemeSongEpisodeKey = ({String bookUid, int episodeIndex});

mixin _FushiDbThemeSongSpans on _$FushiDatabase {
  /// 某集（多首歌）的全部缓存行，含「比对过没出现」的行。
  Future<List<VideoThemeSongSpanRow>> themeSongSpansForEpisode(
    ThemeSongEpisodeKey episode,
  ) =>
      (select(videoThemeSongSpans)..where(
            (VideoThemeSongSpans t) =>
                t.bookUid.equals(episode.bookUid) &
                t.episodeIndex.equals(episode.episodeIndex),
          ))
          .get();

  /// 某首歌在哪些集里出现（只回命中行），按 `book_uid`、`episode_index` 排。
  Future<List<VideoThemeSongSpanRow>> themeSongSpansForTrack(String trackUid) =>
      (select(videoThemeSongSpans)
            ..where(
              (VideoThemeSongSpans t) =>
                  t.trackUid.equals(trackUid) & t.startMs.isNotNull(),
            )
            ..orderBy(<OrderClauseGenerator<VideoThemeSongSpans>>[
              (VideoThemeSongSpans t) => OrderingTerm.asc(t.bookUid),
              (VideoThemeSongSpans t) => OrderingTerm.asc(t.episodeIndex),
            ]))
          .get();

  /// 写一行比对结果（同键覆盖：重新比对 / 失效重算）。
  Future<void> upsertThemeSongSpan(VideoThemeSongSpansCompanion row) =>
      into(videoThemeSongSpans).insertOnConflictUpdate(row);

  /// 清某集的全部缓存（文件换了之外的显式重算入口：用户点「重新识别」）。
  Future<int> clearThemeSongSpansForBook(String bookUid) => (delete(
    videoThemeSongSpans,
  )..where((VideoThemeSongSpans t) => t.bookUid.equals(bookUid))).go();
}
