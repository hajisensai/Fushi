// 音乐曲库（v125，docs/specs/2026-10-23-music-module-design.md §10）：扫描批次落库、
// 软删消失的文件、曲库页查询、播放流。表语义见 music_tables.dart。
part of 'database.dart';

/// 一次扫描批次要落库的全部行（由 Rust 扫描结果在 Dart 侧换算成 companion）。
class MusicScanBatchWrite {
  const MusicScanBatchWrite({
    required this.tracks,
    required this.albums,
    required this.artists,
    required this.credits,
  });

  final List<MusicTracksCompanion> tracks;
  final List<MusicAlbumsCompanion> albums;
  final List<MusicArtistsCompanion> artists;
  final List<MusicTrackCreditsCompanion> credits;
}

mixin _FushiDbMusic on _$FushiDatabase {
  Future<void> _ensureMusicIndexes() async {
    const List<String> stmts = <String>[
      'CREATE INDEX IF NOT EXISTS idx_music_tracks_album '
          'ON music_tracks (album_uid, disc_no, track_no)',
      'CREATE INDEX IF NOT EXISTS idx_music_tracks_source '
          'ON music_tracks (source_id)',
      'CREATE INDEX IF NOT EXISTS idx_music_tracks_path '
          'ON music_tracks (path)',
      'CREATE INDEX IF NOT EXISTS idx_music_track_credits_artist '
          'ON music_track_credits (artist_uid, role)',
      'CREATE INDEX IF NOT EXISTS idx_music_playlist_entries_playlist '
          'ON music_playlist_entries (playlist_uid, position)',
      'CREATE INDEX IF NOT EXISTS idx_music_play_events_track '
          'ON music_play_events (track_uid, started_at)',
      'CREATE INDEX IF NOT EXISTS idx_music_play_events_started '
          'ON music_play_events (started_at)',
    ];
    for (final String stmt in stmts) {
      await customStatement(stmt);
    }
  }

  /// 一个扫描批次整批 upsert（一个事务）。曲目重新出现时清掉软删标记；
  /// [MusicTracks.addedAt] 只在首次插入时写（冲突更新不覆盖入库时刻）。
  /// 一首曲目的署名整组替换：先删该曲目全部旧署名再插新的（标签里删掉的艺人要消失）。
  Future<void> writeMusicScanBatch(MusicScanBatchWrite batch) =>
      transaction(() async {
        for (final MusicArtistsCompanion artist in batch.artists) {
          await into(musicArtists).insert(
            artist,
            onConflict: DoUpdate<$MusicArtistsTable, MusicArtistRow>(
              (_) => MusicArtistsCompanion(
                name: artist.name,
                sortName: artist.sortName,
              ),
            ),
          );
        }
        for (final MusicAlbumsCompanion album in batch.albums) {
          await into(musicAlbums).insert(
            album,
            onConflict: DoUpdate<$MusicAlbumsTable, MusicAlbumRow>(
              (_) => MusicAlbumsCompanion(
                title: album.title,
                titleSort: album.titleSort,
                albumArtistCredit: album.albumArtistCredit,
                releaseDate: album.releaseDate,
                catalogNo: album.catalogNo,
                totalDiscs: album.totalDiscs,
                coverPath: album.coverPath,
                coverTrackUid: album.coverTrackUid,
                mbReleaseId: album.mbReleaseId,
                mbReleaseGroupId: album.mbReleaseGroupId,
                updatedAt: album.updatedAt,
              ),
            ),
          );
        }
        for (final MusicTracksCompanion track in batch.tracks) {
          await into(musicTracks).insert(
            track,
            onConflict: DoUpdate<$MusicTracksTable, MusicTrackRow>(
              (_) => track.copyWith(
                addedAt: const Value<int>.absent(),
                deletedAt: const Value<int?>(null),
              ),
            ),
          );
        }
        final Set<String> creditedTracks = <String>{
          for (final MusicTracksCompanion t in batch.tracks) t.trackUid.value,
        };
        if (creditedTracks.isNotEmpty) {
          await (delete(musicTrackCredits)..where(
                ($MusicTrackCreditsTable t) => t.trackUid.isIn(creditedTracks),
              ))
              .go();
        }
        for (final MusicTrackCreditsCompanion credit in batch.credits) {
          await into(musicTrackCredits).insertOnConflictUpdate(credit);
        }
      });

  /// 扫描收尾：来源 [sourceId] 下本次没见到的曲目（uid 不在 [seenTrackUids]）软删。
  /// 返回新软删的行数。
  Future<int> softDeleteMissingMusicTracks({
    required int sourceId,
    required Set<String> seenTrackUids,
    required int deletedAt,
  }) async {
    final List<String> live =
        await (selectOnly(musicTracks)
              ..addColumns(<Expression<Object>>[musicTracks.trackUid])
              ..where(
                musicTracks.sourceId.equals(sourceId) &
                    musicTracks.deletedAt.isNull(),
              ))
            .map((TypedResult r) => r.read(musicTracks.trackUid)!)
            .get();
    final List<String> missing = live
        .where((String uid) => !seenTrackUids.contains(uid))
        .toList();
    if (missing.isEmpty) return 0;
    return transaction(() async {
      int total = 0;
      for (int i = 0; i < missing.length; i += 500) {
        final List<String> chunk = missing.sublist(
          i,
          (i + 500).clamp(0, missing.length),
        );
        total +=
            await (update(musicTracks)
                  ..where(($MusicTracksTable t) => t.trackUid.isIn(chunk)))
                .write(MusicTracksCompanion(deletedAt: Value<int?>(deletedAt)));
      }
      return total;
    });
  }

  /// 来源 [sourceId] 下在库曲目的（路径, 修改时刻, 大小, uid）。扫描器据此告诉 Rust
  /// 哪些文件没变（跳过标签解析），以及「没变的文件」对应哪些曲目 uid（一个 CUE 整轨
  /// 对应多首）。
  Future<List<({String path, int mtimeAt, int size, String trackUid})>>
  musicTrackFilesOfSource(int sourceId) async {
    final List<MusicTrackRow> rows =
        await (select(musicTracks)..where(
              ($MusicTracksTable t) =>
                  t.sourceId.equals(sourceId) & t.deletedAt.isNull(),
            ))
            .get();
    return <({String path, int mtimeAt, int size, String trackUid})>[
      for (final MusicTrackRow r in rows)
        (
          path: r.path,
          mtimeAt: r.fileMtimeAt,
          size: r.fileSize,
          trackUid: r.trackUid,
        ),
    ];
  }

  /// 需要 EBU R128 现扫的在库曲目（设计 §7.3）：标签里没有曲目增益、也还没扫过。
  Future<List<MusicTrackRow>> listMusicTracksNeedingLoudnessScan({
    int limit = 200,
  }) =>
      (select(musicTracks)
            ..where(
              ($MusicTracksTable t) =>
                  t.deletedAt.isNull() &
                  t.rgTrackGain.isNull() &
                  t.r128ScannedAt.isNull(),
            )
            ..orderBy(<OrderingTerm Function($MusicTracksTable)>[
              ($MusicTracksTable t) => OrderingTerm(expression: t.addedAt),
            ])
            ..limit(limit))
          .get();

  /// 写一首曲目的扫描结果。[gain] / [peak] 为 null = 扫过但测不出（静音 / 解码失败），
  /// 照样记 [scannedAt]，文件变了（重扫时会清掉这个时刻）之前不再重试。只写标签没给的列。
  Future<void> writeMusicTrackLoudness(
    String trackUid, {
    required double? gain,
    required double? peak,
    required int scannedAt,
  }) =>
      (update(musicTracks)..where(
            ($MusicTracksTable t) =>
                t.trackUid.equals(trackUid) & t.rgTrackGain.isNull(),
          ))
          .write(
            MusicTracksCompanion(
              rgTrackGain: Value<double?>(gain),
              rgTrackPeak: Value<double?>(peak),
              r128ScannedAt: Value<int?>(scannedAt),
            ),
          );

  /// 专辑增益补齐：只写该专辑里专辑增益为空的在库曲目（标签带的专辑增益不覆盖）。
  Future<int> writeMusicAlbumLoudness(
    String albumUid, {
    required double gain,
    required double? peak,
  }) =>
      (update(musicTracks)..where(
            ($MusicTracksTable t) =>
                t.albumUid.equals(albumUid) &
                t.deletedAt.isNull() &
                t.rgAlbumGain.isNull(),
          ))
          .write(
            MusicTracksCompanion(
              rgAlbumGain: Value<double?>(gain),
              rgAlbumPeak: Value<double?>(peak),
            ),
          );

  /// 软删一首曲目（远端删除标记 / 用户从曲库移除；不碰磁盘文件）。
  Future<void> softDeleteMusicTrack(
    String trackUid, {
    required int deletedAt,
  }) =>
      (update(musicTracks)..where(
            ($MusicTracksTable t) =>
                t.trackUid.equals(trackUid) & t.deletedAt.isNull(),
          ))
          .write(MusicTracksCompanion(deletedAt: Value<int?>(deletedAt)));

  /// 曲库里的全部在库曲目（软删除外），按专辑 / 碟号 / 轨号 / 标题排序。
  Future<List<MusicTrackRow>> listMusicTracks({String? albumUid}) {
    final SimpleSelectStatement<$MusicTracksTable, MusicTrackRow> q = select(
      musicTracks,
    )..where(($MusicTracksTable t) => t.deletedAt.isNull());
    if (albumUid != null) {
      q.where(($MusicTracksTable t) => t.albumUid.equals(albumUid));
    }
    q.orderBy(<OrderingTerm Function($MusicTracksTable)>[
      ($MusicTracksTable t) => OrderingTerm(expression: t.albumUid),
      ($MusicTracksTable t) => OrderingTerm(expression: t.discNo),
      ($MusicTracksTable t) => OrderingTerm(expression: t.trackNo),
      ($MusicTracksTable t) => OrderingTerm(expression: t.title),
    ]);
    return q.get();
  }

  Future<MusicTrackRow?> getMusicTrack(String trackUid) =>
      (select(musicTracks)
            ..where(($MusicTracksTable t) => t.trackUid.equals(trackUid)))
          .getSingleOrNull();

  /// 至少有一首在库曲目的专辑，按标题排序。
  Future<List<MusicAlbumRow>> listMusicAlbums() {
    final Expression<bool> hasLiveTrack = existsQuery(
      select(musicTracks)..where(
        ($MusicTracksTable t) =>
            t.albumUid.equalsExp(musicAlbums.albumUid) & t.deletedAt.isNull(),
      ),
    );
    return (select(musicAlbums)
          ..where((_) => hasLiveTrack)
          ..orderBy(<OrderingTerm Function($MusicAlbumsTable)>[
            ($MusicAlbumsTable t) => OrderingTerm(
              expression: coalesce(<Expression<String>>[t.titleSort, t.title]),
            ),
          ]))
        .get();
  }

  Future<MusicAlbumRow?> getMusicAlbum(String albumUid) =>
      (select(musicAlbums)
            ..where(($MusicAlbumsTable t) => t.albumUid.equals(albumUid)))
          .getSingleOrNull();

  /// 以 [role]（默认曲目艺人）出现在至少一首在库曲目里的艺人，按排序名。
  Future<List<MusicArtistRow>> listMusicArtists({
    Set<String> roles = const <String>{'artist', 'album_artist'},
  }) {
    final Expression<bool> credited = existsQuery(
      select(musicTrackCredits).join(<Join>[
        innerJoin(
          musicTracks,
          musicTracks.trackUid.equalsExp(musicTrackCredits.trackUid) &
              musicTracks.deletedAt.isNull(),
        ),
      ])..where(
        musicTrackCredits.artistUid.equalsExp(musicArtists.artistUid) &
            musicTrackCredits.role.isIn(roles),
      ),
    );
    return (select(musicArtists)
          ..where((_) => credited)
          ..orderBy(<OrderingTerm Function($MusicArtistsTable)>[
            ($MusicArtistsTable t) => OrderingTerm(
              expression: coalesce(<Expression<String>>[t.sortName, t.name]),
            ),
          ]))
        .get();
  }

  /// 某艺人署名（[roles]）的在库曲目。
  Future<List<MusicTrackRow>> listMusicTracksByArtist(
    String artistUid, {
    Set<String> roles = const <String>{'artist', 'album_artist'},
  }) async {
    final List<TypedResult> rows =
        await (select(musicTracks).join(<Join>[
                innerJoin(
                  musicTrackCredits,
                  musicTrackCredits.trackUid.equalsExp(musicTracks.trackUid),
                ),
              ])
              ..where(
                musicTrackCredits.artistUid.equals(artistUid) &
                    musicTrackCredits.role.isIn(roles) &
                    musicTracks.deletedAt.isNull(),
              )
              ..orderBy(<OrderingTerm>[
                OrderingTerm(expression: musicTracks.albumUid),
                OrderingTerm(expression: musicTracks.discNo),
                OrderingTerm(expression: musicTracks.trackNo),
              ]))
            .get();
    final Map<String, MusicTrackRow> unique = <String, MusicTrackRow>{};
    for (final TypedResult r in rows) {
      final MusicTrackRow t = r.readTable(musicTracks);
      unique.putIfAbsent(t.trackUid, () => t);
    }
    return unique.values.toList();
  }

  Future<List<MusicPlaylistRow>> listMusicPlaylists() =>
      (select(musicPlaylists)
            ..where(($MusicPlaylistsTable t) => t.deletedAt.isNull())
            ..orderBy(<OrderingTerm Function($MusicPlaylistsTable)>[
              ($MusicPlaylistsTable t) => OrderingTerm(expression: t.name),
            ]))
          .get();

  /// 记一次播放（最近播放流）；返回行 id，播放结束时用 [finishMusicPlayEvent] 补时长。
  Future<int> startMusicPlayEvent({
    required String trackUid,
    required int startedAt,
  }) => into(musicPlayEvents).insert(
    MusicPlayEventsCompanion.insert(trackUid: trackUid, startedAt: startedAt),
  );

  Future<void> finishMusicPlayEvent(
    int id, {
    required int listenedMs,
    required bool completed,
  }) =>
      (update(
        musicPlayEvents,
      )..where(($MusicPlayEventsTable t) => t.id.equals(id))).write(
        MusicPlayEventsCompanion(
          listenedMs: Value<int>(listenedMs),
          completed: Value<bool>(completed),
        ),
      );

  /// 最近播放的曲目（按最近一次开始时刻去重），最多 [limit] 首。
  Future<List<MusicTrackRow>> listRecentlyPlayedMusicTracks({
    int limit = 20,
  }) async {
    final Expression<int> lastPlayed = musicPlayEvents.startedAt.max();
    final List<TypedResult> rows =
        await (selectOnly(musicPlayEvents)
              ..addColumns(<Expression<Object>>[
                musicPlayEvents.trackUid,
                lastPlayed,
              ])
              ..groupBy(<Expression<Object>>[musicPlayEvents.trackUid])
              ..orderBy(<OrderingTerm>[
                OrderingTerm(expression: lastPlayed, mode: OrderingMode.desc),
              ])
              ..limit(limit))
            .get();
    final List<String> uids = <String>[
      for (final TypedResult r in rows) r.read(musicPlayEvents.trackUid)!,
    ];
    if (uids.isEmpty) return const <MusicTrackRow>[];
    final Map<String, MusicTrackRow> byUid = <String, MusicTrackRow>{
      for (final MusicTrackRow t
          in await (select(musicTracks)..where(
                ($MusicTracksTable t) =>
                    t.trackUid.isIn(uids) & t.deletedAt.isNull(),
              ))
              .get())
        t.trackUid: t,
    };
    return <MusicTrackRow>[
      for (final String uid in uids)
        if (byUid[uid] != null) byUid[uid]!,
    ];
  }
}
