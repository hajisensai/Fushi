// 音乐曲库（v130，docs/specs/2026-10-23-music-module-design.md §10）：扫描批次落库、
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
        // 标签里没有 MBID 的文件刚被按标签冲回 NULL：把识别身份（v133 刮削结论）重放上去。
        if (creditedTracks.isNotEmpty) {
          await _reapplyMusicScrapeOverlaySql(this, creditedTracks.toList());
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

  /// 至少有一首在库曲目的专辑，以及光盘专辑（盘加进曲库、章节还没导入时也要能看到它，
  /// 「章节导入为曲目」的入口就在这张专辑上），按标题排序。
  Future<List<MusicAlbumRow>> listMusicAlbums() {
    final Expression<bool> hasLiveTrack = existsQuery(
      select(musicTracks)..where(
        ($MusicTracksTable t) =>
            t.albumUid.equalsExp(musicAlbums.albumUid) & t.deletedAt.isNull(),
      ),
    );
    return (select(musicAlbums)
          ..where(($MusicAlbumsTable t) => hasLiveTrack | t.discUid.isNotNull())
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

  // ── 光盘专辑（音乐方案 §9.2：演唱会 / MV 合集 DVD·BD 的章节导入为曲目）──

  Future<MusicDiscSourceRow?> getMusicDiscSource(String discUid) =>
      (select(musicDiscSources)
            ..where(($MusicDiscSourcesTable t) => t.discUid.equals(discUid)))
          .getSingleOrNull();

  Future<List<MusicDiscSourceRow>> listMusicDiscSources() =>
      select(musicDiscSources).get();

  /// 把一张盘登记成曲库里的专辑（还没导入章节）。盘已登记时只更新路径 / 卷标（同一张盘
  /// 挪了目录），专辑标题等用户可能改过的不动。
  Future<void> registerMusicDisc({
    required MusicAlbumsCompanion album,
    required MusicDiscSourcesCompanion disc,
  }) => transaction(() async {
    await into(musicDiscSources).insert(
      disc,
      onConflict: DoUpdate<$MusicDiscSourcesTable, MusicDiscSourceRow>(
        (_) => MusicDiscSourcesCompanion(
          path: disc.path,
          volumeId: disc.volumeId,
          hasMenu: disc.hasMenu,
        ),
      ),
    );
    await into(musicAlbums).insert(
      album,
      onConflict: DoUpdate<$MusicAlbumsTable, MusicAlbumRow>(
        (_) => MusicAlbumsCompanion(discUid: album.discUid),
      ),
    );
  });

  /// 一次「章节导入为曲目」整体落库（一个事务）：专辑 / 光盘来源 upsert，曲目 upsert（重新
  /// 导入时清软删标记、不改入库时刻，**也不改已有曲目的标题 / 艺人 / 录音 MBID**——那是
  /// MusicBrainz 结论或用户改过的名字，重新导入只更新盘上的事实：路径、起止、时长、序号），
  /// 这张专辑上一轮导入、这一轮没选的曲目软删（歌单 / 播放记录仍能解析到行）。
  Future<void> writeMusicDiscImport({
    required MusicAlbumsCompanion album,
    required MusicDiscSourcesCompanion disc,
    required List<MusicTracksCompanion> tracks,
    required int deletedAt,
  }) => transaction(() async {
    await into(musicDiscSources).insertOnConflictUpdate(disc);
    // 已有的专辑行只认领光盘来源、刷新时刻：标题 / 艺人 / 封面可能是 MusicBrainz 结论。
    await into(musicAlbums).insert(
      album,
      onConflict: DoUpdate<$MusicAlbumsTable, MusicAlbumRow>(
        (_) => MusicAlbumsCompanion(
          discUid: album.discUid,
          updatedAt: album.updatedAt,
        ),
      ),
    );
    final String albumUid = album.albumUid.value;
    final Set<String> keep = <String>{
      for (final MusicTracksCompanion t in tracks) t.trackUid.value,
    };
    for (final MusicTracksCompanion track in tracks) {
      await into(musicTracks).insert(
        track,
        onConflict: DoUpdate<$MusicTracksTable, MusicTrackRow>(
          (_) => track.copyWith(
            addedAt: const Value<int>.absent(),
            title: const Value<String>.absent(),
            artistCredit: const Value<String?>.absent(),
            mbRecordingId: const Value<String?>.absent(),
            deletedAt: const Value<int?>(null),
          ),
        ),
      );
    }
    await (update(musicTracks)..where(
          ($MusicTracksTable t) =>
              t.albumUid.equals(albumUid) &
              t.deletedAt.isNull() &
              t.trackUid.isNotIn(keep),
        ))
        .write(MusicTracksCompanion(deletedAt: Value<int?>(deletedAt)));
    if (keep.isNotEmpty) {
      await _reapplyMusicScrapeOverlaySql(this, keep.toList());
    }
  });

  /// 读一张音频 CD 落库（一个事务）：这是用户显式「重新读盘 / 识别」，专辑与曲目的名字
  /// 按这一次的结论整行覆盖（入库时刻不动、软删标记清掉）。
  Future<void> writeMusicAudioCd({
    required MusicAlbumsCompanion album,
    required MusicDiscSourcesCompanion disc,
    required List<MusicTracksCompanion> tracks,
  }) => transaction(() async {
    await into(musicDiscSources).insert(
      disc,
      onConflict: DoUpdate<$MusicDiscSourcesTable, MusicDiscSourceRow>(
        (_) => disc.copyWith(addedAt: const Value<int>.absent()),
      ),
    );
    await into(musicAlbums).insert(
      album,
      onConflict: DoUpdate<$MusicAlbumsTable, MusicAlbumRow>(
        (_) => album.copyWith(addedAt: const Value<int>.absent()),
      ),
    );
    for (final MusicTracksCompanion track in tracks) {
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
    if (tracks.isNotEmpty) {
      await _reapplyMusicScrapeOverlaySql(this, <String>[
        for (final MusicTracksCompanion t in tracks) t.trackUid.value,
      ]);
    }
  });

  /// 从曲库移除一张盘：光盘来源与专辑行删掉，它的曲目软删（歌单 / 播放记录仍能解析）。
  Future<void> removeMusicDisc({
    required String discUid,
    required int deletedAt,
  }) => transaction(() async {
    final List<String> albums =
        await (selectOnly(musicAlbums)
              ..addColumns(<Expression<Object>>[musicAlbums.albumUid])
              ..where(musicAlbums.discUid.equals(discUid)))
            .map((TypedResult r) => r.read(musicAlbums.albumUid)!)
            .get();
    if (albums.isNotEmpty) {
      await (update(musicTracks)..where(
            ($MusicTracksTable t) =>
                t.albumUid.isIn(albums) & t.deletedAt.isNull(),
          ))
          .write(MusicTracksCompanion(deletedAt: Value<int?>(deletedAt)));
      await (delete(
        musicAlbums,
      )..where(($MusicAlbumsTable t) => t.albumUid.isIn(albums))).go();
    }
    await (delete(
      musicDiscSources,
    )..where(($MusicDiscSourcesTable t) => t.discUid.equals(discUid))).go();
  });

  /// 用 MusicBrainz 发行结论更新光盘专辑（[album] 里给了的列）并给曲目改名（逐首标题 /
  /// 艺人 / 录音 MBID）。
  Future<void> applyMusicDiscRelease({
    required String albumUid,
    required MusicAlbumsCompanion album,
    required List<
      ({String trackUid, String title, String? artist, String? mbRecordingId})
    >
    names,
  }) => transaction(() async {
    await (update(musicAlbums)
          ..where(($MusicAlbumsTable t) => t.albumUid.equals(albumUid)))
        .write(album);
    for (final ({
          String trackUid,
          String title,
          String? artist,
          String? mbRecordingId,
        })
        n
        in names) {
      await (update(
        musicTracks,
      )..where(($MusicTracksTable t) => t.trackUid.equals(n.trackUid))).write(
        MusicTracksCompanion(
          title: Value<String>(n.title),
          artistCredit: n.artist == null
              ? const Value<String?>.absent()
              : Value<String?>(n.artist),
          mbRecordingId: n.mbRecordingId == null
              ? const Value<String?>.absent()
              : Value<String?>(n.mbRecordingId),
        ),
      );
    }
  });

  Future<List<MusicPlaylistRow>> listMusicPlaylists() =>
      (select(musicPlaylists)
            ..where(($MusicPlaylistsTable t) => t.deletedAt.isNull())
            ..orderBy(<OrderingTerm Function($MusicPlaylistsTable)>[
              ($MusicPlaylistsTable t) => OrderingTerm(expression: t.name),
            ]))
          .get();

  /// 记一次播放（最近播放流）；返回行 id，播放结束时用 [finishMusicPlayEvent] 补时长。
  /// [snapshot] 是播放项快照 + 播放来源（v139）：在线 / 服务器曲目不进曲库，最近播放
  /// 只能靠它显示与重播。
  Future<int> startMusicPlayEvent({
    required String trackUid,
    required int startedAt,
    MusicPlayEventSnapshot? snapshot,
  }) => into(musicPlayEvents).insert(
    MusicPlayEventsCompanion.insert(
      trackUid: trackUid,
      startedAt: startedAt,
      path: Value<String?>(snapshot?.path),
      cueStartMs: Value<int?>(snapshot?.cueStartMs),
      cueEndMs: Value<int?>(snapshot?.cueEndMs),
      title: Value<String?>(snapshot?.title),
      artist: Value<String?>(snapshot?.artist),
      album: Value<String?>(snapshot?.album),
      albumUid: Value<String?>(snapshot?.albumUid),
      durationMs: Value<int?>(snapshot?.durationMs),
      coverPath: Value<String?>(snapshot?.coverPath),
      sourceKind: Value<String?>(snapshot?.sourceKind),
      sourceId: Value<String?>(
        snapshot?.sourceKind == null ? null : snapshot?.sourceId,
      ),
      sourceTitle: Value<String?>(snapshot?.sourceTitle),
      sourceCover: Value<String?>(snapshot?.sourceCover),
    ),
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

  /// 最近播放的曲库曲目（按最近一次开始时刻去重），最多 [limit] 首。
  ///
  /// 只算曲库里还在（未软删）的曲目，且过滤在 SQL 里做：在线插件 / 服务器曲目的播放事件
  /// 不在 music_tracks 里，若先取 [limit] 条再丢，最近一次听的是在线曲时 `limit: 1`
  /// 就什么都拿不到。
  Future<List<MusicTrackRow>> listRecentlyPlayedMusicTracks({
    int limit = 20,
  }) async {
    final Expression<int> lastPlayed = musicPlayEvents.startedAt.max();
    final List<TypedResult> rows =
        await (selectOnly(musicPlayEvents).join(<Join>[
                innerJoin(
                  musicTracks,
                  musicTracks.trackUid.equalsExp(musicPlayEvents.trackUid) &
                      musicTracks.deletedAt.isNull(),
                  useColumns: false,
                ),
              ])
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

  /// 最近播放（按曲目去重，每首取最近一次播放事件），最多 [limit] 首，新的在前。
  ///
  /// 曲库里还在（未软删）的曲目带上 [MusicRecentPlay.track] / [MusicRecentPlay.album]；
  /// 不在曲库的（在线插件 / 服务器曲目、被删的本地曲目）靠事件快照，快照也没有
  /// （v139 前的存量事件）才丢——过滤在 SQL 里做，丢掉的不占 [limit] 名额。
  Future<List<MusicRecentPlay>> listRecentMusicPlays({int limit = 20}) async {
    if (limit <= 0) return const <MusicRecentPlay>[];
    // SQLite 的 bare column：带 MAX() 的分组查询里，其余列取自 MAX 所在那一行。
    final List<QueryRow> rows = await customSelect(
      'SELECT e.* FROM ('
      'SELECT *, MAX(started_at) AS last_at FROM music_play_events '
      'GROUP BY track_uid'
      ') AS e '
      'LEFT JOIN music_tracks AS t '
      'ON t.track_uid = e.track_uid AND t.deleted_at IS NULL '
      'WHERE t.track_uid IS NOT NULL OR e.path IS NOT NULL '
      'ORDER BY e.last_at DESC, e.id DESC LIMIT ?',
      variables: <Variable<Object>>[Variable<int>(limit)],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        musicPlayEvents,
        musicTracks,
      },
    ).get();
    final List<MusicPlayEventRow> events = <MusicPlayEventRow>[
      for (final QueryRow r in rows) musicPlayEvents.map(r.data),
    ];
    if (events.isEmpty) return const <MusicRecentPlay>[];
    final Map<String, MusicTrackRow> tracks = <String, MusicTrackRow>{
      for (final MusicTrackRow t
          in await (select(musicTracks)..where(
                ($MusicTracksTable t) =>
                    t.trackUid.isIn(<String>[
                      for (final MusicPlayEventRow e in events) e.trackUid,
                    ]) &
                    t.deletedAt.isNull(),
              ))
              .get())
        t.trackUid: t,
    };
    final Set<String> albumUids = <String>{
      for (final MusicTrackRow t in tracks.values)
        if (t.albumUid != null) t.albumUid!,
    };
    final Map<String, MusicAlbumRow> albums = albumUids.isEmpty
        ? const <String, MusicAlbumRow>{}
        : <String, MusicAlbumRow>{
            for (final MusicAlbumRow a
                in await (select(musicAlbums)..where(
                      ($MusicAlbumsTable a) => a.albumUid.isIn(albumUids),
                    ))
                    .get())
              a.albumUid: a,
          };
    return <MusicRecentPlay>[
      for (final MusicPlayEventRow e in events)
        MusicRecentPlay(
          event: e,
          track: tracks[e.trackUid],
          album: tracks[e.trackUid]?.albumUid == null
              ? null
              : albums[tracks[e.trackUid]!.albumUid!],
        ),
    ];
  }

  /// 最近播放的来源（专辑 / 歌单 …），按 (sourceKind, sourceId) 去重，最多 [limit] 个，
  /// 新的在前；标题 / 封面取该来源最近一次播放时记下的。[kinds] 非空时只要这些种类。
  Future<List<MusicRecentSource>> listRecentMusicSources({
    int limit = 20,
    Set<String>? kinds,
  }) async {
    if (limit <= 0) return const <MusicRecentSource>[];
    final List<String> kindList = kinds == null
        ? const <String>[]
        : (kinds.toList()..sort());
    if (kinds != null && kindList.isEmpty) return const <MusicRecentSource>[];
    final String kindFilter = kindList.isEmpty
        ? ''
        : 'AND source_kind IN (${List<String>.filled(kindList.length, '?').join(', ')}) ';
    final List<QueryRow> rows = await customSelect(
      'SELECT source_kind, source_id, source_title, source_cover, '
      'MAX(started_at) AS last_at FROM music_play_events '
      'WHERE source_kind IS NOT NULL AND source_id IS NOT NULL '
      '$kindFilter'
      'GROUP BY source_kind, source_id '
      'ORDER BY last_at DESC LIMIT ?',
      variables: <Variable<Object>>[
        for (final String k in kindList) Variable<String>(k),
        Variable<int>(limit),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{musicPlayEvents},
    ).get();
    return <MusicRecentSource>[
      for (final QueryRow r in rows)
        MusicRecentSource(
          kind: r.read<String>('source_kind'),
          id: r.read<String>('source_id'),
          title: r.readNullable<String>('source_title'),
          cover: r.readNullable<String>('source_cover'),
          lastPlayedAt: r.read<int>('last_at'),
        ),
    ];
  }
}

/// 写播放事件时随行落库的播放项快照与播放来源（v139）。来源 [sourceKind] 为 null 时
/// [sourceId] 也不落（来源未知）。
class MusicPlayEventSnapshot {
  const MusicPlayEventSnapshot({
    this.path,
    this.cueStartMs,
    this.cueEndMs,
    this.title,
    this.artist,
    this.album,
    this.albumUid,
    this.durationMs,
    this.coverPath,
    this.sourceKind,
    this.sourceId,
    this.sourceTitle,
    this.sourceCover,
  });

  final String? path;
  final int? cueStartMs;
  final int? cueEndMs;
  final String? title;
  final String? artist;
  final String? album;
  final String? albumUid;
  final int? durationMs;
  final String? coverPath;
  final String? sourceKind;
  final String? sourceId;
  final String? sourceTitle;
  final String? sourceCover;
}

/// 最近播放的一首：该曲目最近一次播放事件（含快照与来源）+ 曲库里的现行（未软删）
/// 行（不在曲库为 null）。
class MusicRecentPlay {
  const MusicRecentPlay({required this.event, this.track, this.album});

  final MusicPlayEventRow event;
  final MusicTrackRow? track;
  final MusicAlbumRow? album;

  String get trackUid => event.trackUid;
  int get lastPlayedAt => event.startedAt;
}

/// 最近播放的一个来源（专辑 / 歌单 …）。
class MusicRecentSource {
  const MusicRecentSource({
    required this.kind,
    required this.id,
    required this.lastPlayedAt,
    this.title,
    this.cover,
  });

  /// 来源种类 wire 值（见 `MusicPlayEvents.sourceKind`）。
  final String kind;
  final String id;
  final String? title;
  final String? cover;
  final int lastPlayedAt;
}
