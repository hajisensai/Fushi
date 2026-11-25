// 视频内容指纹缓存（v165，搬家识别）。表语义见 video_content_fingerprint_tables.dart。
part of 'database.dart';

mixin _FushiDbVideoContentFingerprints on _$FushiDatabase {
  /// 全部指纹行，按 `book_uid` 索引（来源扫描一次取齐，不逐行查）。
  Future<Map<String, VideoContentFingerprintRow>>
  allVideoContentFingerprints() async => <String, VideoContentFingerprintRow>{
    for (final VideoContentFingerprintRow row in await select(
      videoContentFingerprints,
    ).get())
      row.bookUid: row,
  };

  /// 写一行指纹（同 `book_uid` 覆盖：首次记录 / 文件换了重算 / 搬家后刷新修改时刻）。
  Future<void> upsertVideoContentFingerprint(
    VideoContentFingerprintsCompanion row,
  ) => into(videoContentFingerprints).insertOnConflictUpdate(row);

  /// 清掉已经没有对应视频行的指纹（行被别的路径删掉、或合并搬家残留时删了旧行），
  /// 返回删掉的行数。
  Future<int> pruneOrphanVideoContentFingerprints() => customUpdate(
    'DELETE FROM video_content_fingerprints WHERE book_uid NOT IN '
    '(SELECT book_uid FROM video_books)',
    updates: <TableInfo<Table, Object?>>{videoContentFingerprints},
    updateKind: UpdateKind.delete,
  );
}
