// 音乐刮削（v133，docs/specs/2026-10-23-music-module-design.md §8）：识别结论 / 原始快照 /
// 字段锁的读写，识别身份在曲库目录上的叠加（重扫后重放），MV 绑定。表语义见
// music_scrape_tables.dart。
part of 'database.dart';

/// 把 `music_scrape_meta` 的识别身份叠加到 [trackUids] 及其专辑上（一个语句组，调用方
/// 负责事务）。
///
/// - 曲目：录音 MBID 取识别结论（用户手选 / 搜到的新 id 胜过可能已失效的标签 id）；
///   作品 MBID / AcoustID 只补空。
/// - 专辑：发行 MBID / 发行组 / 目录编号只补空——标签里写了的永远以标签为准。
///
/// 为什么要重放：扫描批次按标签整行 upsert（`writeMusicScanBatch`），标签里没有 MBID 的
/// 文件每重扫一次身份列就被冲回 NULL。
Future<void> _reapplyMusicScrapeOverlaySql(
  DatabaseConnectionUser db,
  List<String> trackUids,
) async {
  for (int i = 0; i < trackUids.length; i += 400) {
    final List<String> chunk = trackUids.sublist(
      i,
      (i + 400).clamp(0, trackUids.length),
    );
    final String marks = List<String>.filled(chunk.length, '?').join(',');
    const String matched =
        "m.track_uid = music_tracks.track_uid AND m.status = 'matched'";
    await db.customStatement(
      'UPDATE music_tracks SET '
      'mb_recording_id = (SELECT m.mb_recording_id FROM music_scrape_meta m '
      'WHERE $matched), '
      'mb_work_id = COALESCE(mb_work_id, (SELECT m.mb_work_id FROM '
      'music_scrape_meta m WHERE $matched)), '
      'acoustid = COALESCE(acoustid, (SELECT m.acoustid FROM '
      'music_scrape_meta m WHERE $matched)) '
      'WHERE track_uid IN ($marks) AND EXISTS (SELECT 1 FROM '
      'music_scrape_meta m WHERE $matched AND m.mb_recording_id IS NOT NULL)',
      chunk,
    );
    String fromAlbum(String column) =>
        '(SELECT m.$column FROM music_scrape_meta m JOIN music_tracks t '
        'ON t.track_uid = m.track_uid WHERE t.album_uid = '
        "music_albums.album_uid AND m.status = 'matched' AND "
        'm.$column IS NOT NULL ORDER BY m.scraped_at DESC LIMIT 1)';
    await db.customStatement(
      'UPDATE music_albums SET '
      'mb_release_id = COALESCE(mb_release_id, ${fromAlbum('mb_release_id')}), '
      'mb_release_group_id = COALESCE(mb_release_group_id, '
      '${fromAlbum('mb_release_group_id')}), '
      'catalog_no = COALESCE(catalog_no, ${fromAlbum('catalog_no')}) '
      'WHERE album_uid IN (SELECT album_uid FROM music_tracks '
      'WHERE album_uid IS NOT NULL AND track_uid IN ($marks))',
      chunk,
    );
  }
}

mixin _FushiDbMusicScrape on _$FushiDatabase {
  /// 写一首的识别结论（整行覆盖）+ 这次识别取到的原始快照（按外部实体覆盖），并把身份
  /// 叠加到曲库目录上。一个事务。
  Future<void> writeMusicScrapeResult({
    required MusicScrapeMetaCompanion meta,
    List<MusicMetadataRawSnapshotsCompanion> snapshots =
        const <MusicMetadataRawSnapshotsCompanion>[],
  }) => transaction(() async {
    await into(musicScrapeMeta).insertOnConflictUpdate(meta);
    for (final MusicMetadataRawSnapshotsCompanion s in snapshots) {
      await into(musicMetadataRawSnapshots).insert(
        s,
        onConflict:
            DoUpdate<
              $MusicMetadataRawSnapshotsTable,
              MusicMetadataRawSnapshotRow
            >(
              (_) => MusicMetadataRawSnapshotsCompanion(
                rawJson: s.rawJson,
                fetchedAt: s.fetchedAt,
              ),
              target: <Column>[
                musicMetadataRawSnapshots.provider,
                musicMetadataRawSnapshots.snapshotKind,
                musicMetadataRawSnapshots.externalId,
              ],
            ),
      );
    }
    await _reapplyMusicScrapeOverlaySql(this, <String>[meta.trackUid.value]);
  });

  Future<MusicScrapeMetaRow?> getMusicScrapeMeta(String trackUid) =>
      (select(musicScrapeMeta)
            ..where(($MusicScrapeMetaTable t) => t.trackUid.equals(trackUid)))
          .getSingleOrNull();

  /// 清掉一首的识别结论（「取消识别」）：身份列回到标签值要等下次重扫，这里先把叠加上去
  /// 的录音 MBID 清空，避免界面继续显示旧身份。
  Future<void> clearMusicScrapeResult(String trackUid) => transaction(() async {
    await (delete(
      musicScrapeMeta,
    )..where(($MusicScrapeMetaTable t) => t.trackUid.equals(trackUid))).go();
    await (update(musicTracks)
          ..where(($MusicTracksTable t) => t.trackUid.equals(trackUid)))
        .write(const MusicTracksCompanion(mbRecordingId: Value<String?>(null)));
  });

  Future<MusicMetadataRawSnapshotRow?> getMusicRawSnapshot({
    required String provider,
    required String snapshotKind,
    required String externalId,
  }) =>
      (select(musicMetadataRawSnapshots)..where(
            ($MusicMetadataRawSnapshotsTable t) =>
                t.provider.equals(provider) &
                t.snapshotKind.equals(snapshotKind) &
                t.externalId.equals(externalId),
          ))
          .getSingleOrNull();

  /// 在库曲目里还没有识别结论（或结论早于 [olderThanVersion] 版刮削器）的，按专辑 / 曲序。
  Future<List<MusicTrackRow>> listMusicTracksNeedingScrape({
    required int olderThanVersion,
    int? limit,
  }) async {
    final Expression<bool> fresh = existsQuery(
      select(musicScrapeMeta)..where(
        ($MusicScrapeMetaTable m) =>
            m.trackUid.equalsExp(musicTracks.trackUid) &
            m.scraperVersion.isBiggerOrEqualValue(olderThanVersion),
      ),
    );
    final SimpleSelectStatement<$MusicTracksTable, MusicTrackRow> q =
        select(musicTracks)
          ..where(($MusicTracksTable t) => t.deletedAt.isNull() & fresh.not())
          ..orderBy(<OrderingTerm Function($MusicTracksTable)>[
            ($MusicTracksTable t) => OrderingTerm(expression: t.albumUid),
            ($MusicTracksTable t) => OrderingTerm(expression: t.discNo),
            ($MusicTracksTable t) => OrderingTerm(expression: t.trackNo),
          ]);
    if (limit != null) q.limit(limit);
    return q.get();
  }

  /// 在库曲目里录音 MBID 落在 [recordingIds] 的（「其它版本」里本地有的直接可播）。
  Future<List<MusicTrackRow>> listMusicTracksByRecordingIds(
    Set<String> recordingIds,
  ) async {
    if (recordingIds.isEmpty) return const <MusicTrackRow>[];
    final List<MusicTrackRow> out = <MusicTrackRow>[];
    final List<String> ids = recordingIds.toList();
    for (int i = 0; i < ids.length; i += 400) {
      out.addAll(
        await (select(musicTracks)..where(
              ($MusicTracksTable t) =>
                  t.deletedAt.isNull() &
                  t.mbRecordingId.isIn(
                    ids.sublist(i, (i + 400).clamp(0, ids.length)),
                  ),
            ))
            .get(),
      );
    }
    return out;
  }

  // ── 字段锁 ──

  Future<Set<String>> listMusicLockedFields({
    required String entityKind,
    required String entityUid,
  }) async {
    final List<MusicLockedFieldRow> rows =
        await (select(musicLockedFields)..where(
              ($MusicLockedFieldsTable t) =>
                  t.entityKind.equals(entityKind) &
                  t.entityUid.equals(entityUid),
            ))
            .get();
    return <String>{for (final MusicLockedFieldRow r in rows) r.field};
  }

  /// 把一个实体的锁集合整体换成 [fields]。
  Future<void> setMusicLockedFields({
    required String entityKind,
    required String entityUid,
    required Set<String> fields,
    required int lockedAt,
  }) => transaction(() async {
    await (delete(musicLockedFields)..where(
          ($MusicLockedFieldsTable t) =>
              t.entityKind.equals(entityKind) &
              t.entityUid.equals(entityUid) &
              t.field.isNotIn(fields),
        ))
        .go();
    for (final String f in fields) {
      await into(musicLockedFields).insert(
        MusicLockedFieldsCompanion.insert(
          entityKind: entityKind,
          entityUid: entityUid,
          field: f,
          lockedAt: lockedAt,
        ),
        mode: InsertMode.insertOrIgnore,
      );
    }
  });

  /// 全部专辑行（含没有在库曲目的），数据根迁移改写 `cover_path` 用。
  Future<List<MusicAlbumRow>> listAllMusicAlbumsForPathRebase() =>
      select(musicAlbums).get();

  /// 专辑封面换成刮削下载的本地文件（[coverPath]）。专辑已有目录封面时不动——目录图是
  /// 用户自己放的，优先级最高。返回是否写了。
  Future<bool> setMusicAlbumScrapedCover({
    required String albumUid,
    required String coverPath,
    required int updatedAt,
  }) async {
    final int n =
        await (update(musicAlbums)..where(
              ($MusicAlbumsTable t) =>
                  t.albumUid.equals(albumUid) & t.coverPath.isNull(),
            ))
            .write(
              MusicAlbumsCompanion(
                coverPath: Value<String?>(coverPath),
                updatedAt: Value<int>(updatedAt),
              ),
            );
    return n > 0;
  }

  // ── MV 绑定（music_videos，v130 已建表）──

  Future<List<MusicVideoRow>> listMusicVideos(String trackUid) =>
      (select(musicVideos)
            ..where(($MusicVideosTable t) => t.trackUid.equals(trackUid))
            ..orderBy(<OrderingTerm Function($MusicVideosTable)>[
              ($MusicVideosTable t) => OrderingTerm(
                expression: t.isUserBound,
                mode: OrderingMode.desc,
              ),
              ($MusicVideosTable t) => OrderingTerm(
                expression: t.confidence,
                mode: OrderingMode.desc,
              ),
            ]))
          .get();

  /// 绑定 / 更新一条 MV（按 `(track_uid, kind, ref)` 唯一）。
  Future<void> upsertMusicVideo(MusicVideosCompanion row) =>
      into(musicVideos).insert(
        row,
        onConflict: DoUpdate<$MusicVideosTable, MusicVideoRow>(
          (_) => MusicVideosCompanion(
            offsetMs: row.offsetMs,
            confidence: row.confidence,
            isUserBound: row.isUserBound,
            updatedAt: row.updatedAt,
          ),
          target: <Column>[
            musicVideos.trackUid,
            musicVideos.kind,
            musicVideos.ref,
          ],
        ),
      );

  Future<void> deleteMusicVideo(int id) => (delete(
    musicVideos,
  )..where(($MusicVideosTable t) => t.id.equals(id))).go();
}
