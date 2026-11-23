// 本地 MV 自动匹配的缓存（v172）。表语义见 music_video_match_cache_tables.dart。
part of 'database.dart';

mixin _FushiDbMusicVideoMatchCache on _$FushiDatabase {
  /// 视频 [path] 的声纹缓存；文件大小 / 修改时刻对不上（文件换过）当没有。
  Future<Uint8List?> getMusicVideoPrint(
    String path, {
    required int fileSizeBytes,
    required int fileModifiedAt,
  }) async {
    final MusicVideoPrintRow? row =
        await (select(musicVideoPrints)
              ..where(($MusicVideoPrintsTable t) => t.path.equals(path)))
            .getSingleOrNull();
    if (row == null ||
        row.fileSizeBytes != fileSizeBytes ||
        row.fileModifiedAt != fileModifiedAt) {
      return null;
    }
    return row.print;
  }

  /// 写 / 覆盖视频 [path] 的声纹。
  Future<void> putMusicVideoPrint(
    String path, {
    required int fileSizeBytes,
    required int fileModifiedAt,
    required Uint8List print,
    required int computedAt,
  }) => into(musicVideoPrints).insertOnConflictUpdate(
    MusicVideoPrintsCompanion.insert(
      path: path,
      fileSizeBytes: fileSizeBytes,
      fileModifiedAt: fileModifiedAt,
      print: print,
      computedAt: computedAt,
    ),
  );

  /// 全部「已对齐过」记录，按 `(track_uid, video_path)` 索引（后台匹配一次取齐）。
  Future<Map<(String, String), MusicVideoMatchCheckRow>>
  allMusicVideoMatchChecks() async =>
      <(String, String), MusicVideoMatchCheckRow>{
        for (final MusicVideoMatchCheckRow row in await select(
          musicVideoMatchChecks,
        ).get())
          (row.trackUid, row.videoPath): row,
      };

  /// 记一次对齐（同一对覆盖）。
  Future<void> putMusicVideoMatchCheck({
    required String trackUid,
    required String videoPath,
    required int fileSizeBytes,
    required int fileModifiedAt,
    required int checkedAt,
  }) => into(musicVideoMatchChecks).insertOnConflictUpdate(
    MusicVideoMatchChecksCompanion.insert(
      trackUid: trackUid,
      videoPath: videoPath,
      fileSizeBytes: fileSizeBytes,
      fileModifiedAt: fileModifiedAt,
      checkedAt: checkedAt,
    ),
  );

  /// 已有任一 MV 绑定的曲目（后台匹配跳过它们：已绑定的不再自动找）。
  Future<Set<String>> musicTrackUidsWithVideos() async => <String>{
    for (final TypedResult r in await (selectOnly(
      musicVideos,
      distinct: true,
    )..addColumns(<Expression<Object>>[musicVideos.trackUid])).get())
      r.read(musicVideos.trackUid)!,
  };
}
